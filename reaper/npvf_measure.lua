--[[ Measuring a library's test notes: where each one is heard and how loud.

     Plain Lua, no REAPER: the window hands it a function that reads samples,
     and the tests hand it a WAV. A port of src/engine.js's analyse() and
     learnProfile() for notes played one at a time, and kept in step with
     them: tests/lua_parity.js measures the same renders with both and
     compares (decision 0007).

     Times are seconds from the start of the rendered test; sample arrays
     are 1-based Lua tables.
]]

local M = {}

M.DEFAULTS = {
  alignTo = "attack",  -- "attack": where the attack is heard; "start": where any sound begins
  attackDb = 12,       -- the attack is this many dB below the note's first peak
  startDb = 30,        -- the start of the sound, this many dB below it
  maxDelayMs = 400,    -- the latest a note's sound can start
  minRiseDb = 6,       -- a note must rise this much to count as found
  method = "auto",     -- "auto": each note's harmonics, else the whole sound | "harmonics" | "whole"
  dynamics = "velocity", -- what the test's levels are: "velocity" or "cc1"
}

local floor, max, min, abs, log, sin, cos, pi = math.floor, math.max, math.min, math.abs, math.log, math.sin, math.cos, math.pi
local function round(x) return floor(x + 0.5) end
local function log10(x) return log(x, 10) end
local HOP = 0.0005

------------------------------------------------------------------------------
-- Statistics
------------------------------------------------------------------------------

local function minmax(a)
  local lo, hi = math.huge, -math.huge
  for i = 1, #a do if a[i] < lo then lo = a[i] end if a[i] > hi then hi = a[i] end end
  return lo, hi
end
M.minmax = minmax

local function sorted(a) local s = {} for i = 1, #a do s[i] = a[i] end table.sort(s) return s end
function M.median(a)
  if #a == 0 then return 0 / 0 end
  local s = sorted(a)
  local m = #s // 2
  if #s % 2 == 1 then return s[m + 1] end
  return (s[m] + s[m + 1]) / 2
end
local median = M.median
function M.stdev(a)
  if #a < 2 then return 0 end
  local m = 0
  for i = 1, #a do m = m + a[i] end
  m = m / #a
  local v = 0
  for i = 1, #a do v = v + (a[i] - m) ^ 2 end
  return math.sqrt(v / (#a - 1))
end

local function solve(Mx, v)
  local n = #v
  local A = {}
  for i = 1, n do A[i] = {} for j = 1, n do A[i][j] = Mx[i][j] end A[i][n + 1] = v[i] end
  for c = 1, n do
    local piv = c
    for r = c + 1, n do if abs(A[r][c]) > abs(A[piv][c]) then piv = r end end
    A[c], A[piv] = A[piv], A[c]
    local d = A[c][c]
    if abs(d) < 1e-12 then return nil end
    for r = 1, n do
      if r ~= c then
        local f = A[r][c] / d
        for k = c, n + 1 do A[r][k] = A[r][k] - f * A[c][k] end
      end
    end
  end
  local out = {}
  for i = 1, n do out[i] = A[i][n + 1] / A[i][i] end
  return out
end

--- Least squares that a few loud or quiet notes can't drag (Huber weights), as in engine.js.
function M.robustFit(X, y)
  local n, p = #y, #X[1]
  local w, beta, scale = {}, nil, 1
  for i = 1, n do w[i] = 1 end
  for _ = 1, 30 do
    local Mx, v = {}, {}
    for a = 1, p do Mx[a] = {} for b = 1, p do Mx[a][b] = 0 end v[a] = 0 end
    for i = 1, n do
      local xi, wi = X[i], w[i]
      for a = 1, p do
        v[a] = v[a] + wi * xi[a] * y[i]
        for b = 1, p do Mx[a][b] = Mx[a][b] + wi * xi[a] * xi[b] end
      end
    end
    for a = 2, p do Mx[a][a] = Mx[a][a] + 1e-6 end
    local nb = solve(Mx, v)
    if not nb then break end
    beta = nb
    local r, ar = {}, {}
    for i = 1, n do
      local f = 0
      for a = 1, p do f = f + X[i][a] * beta[a] end
      r[i] = y[i] - f
      ar[i] = abs(r[i])
    end
    scale = max(0.3, 1.4826 * median(ar))
    local k = 1.345 * scale
    for i = 1, n do w[i] = abs(r[i]) <= k and 1 or k / abs(r[i]) end
  end
  return beta, scale
end

------------------------------------------------------------------------------
-- Filters and envelopes
------------------------------------------------------------------------------

local function norm(b0, b1, b2, a0, a1, a2)
  return { b0 = b0 / a0, b1 = b1 / a0, b2 = b2 / a0, a1 = a1 / a0, a2 = a2 / a0 }
end

local function run(x, n, c, y)
  local b0, b1, b2, a1, a2 = c.b0, c.b1, c.b2, c.a1, c.a2
  local x1, x2, y1, y2 = 0, 0, 0, 0
  for i = 1, n do
    local xn = x[i]
    local yn = b0 * xn + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
    x2, x1, y2, y1 = x1, xn, y1, yn
    y[i] = yn
  end
  return y
end

local function runBack(y, n, c)
  local b0, b1, b2, a1, a2 = c.b0, c.b1, c.b2, c.a1, c.a2
  local x1, x2, y1, y2 = 0, 0, 0, 0
  for i = n, 1, -1 do
    local xn = y[i]
    local yn = b0 * xn + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
    x2, x1, y2, y1 = x1, xn, y1, yn
    y[i] = yn
  end
  return y
end

--- ITU-R BS.1770 K-weighting at any sample rate.
function M.kWeight(x, n, fs)
  local w0 = 2 * pi * 1681.974450955533 / fs
  local A = 10 ^ (3.999843853973347 / 40)
  local alpha = sin(w0) / (2 * 0.7071752369554196)
  local cs, sa = cos(w0), 2 * math.sqrt(A) * alpha
  local shelf = norm(A * ((A + 1) + (A - 1) * cs + sa), -2 * A * ((A - 1) + (A + 1) * cs), A * ((A + 1) + (A - 1) * cs - sa),
    (A + 1) - (A - 1) * cs + sa, 2 * ((A - 1) - (A + 1) * cs), (A + 1) - (A - 1) * cs - sa)
  w0 = 2 * pi * 38.13547087602444 / fs
  alpha = sin(w0) / (2 * 0.5003270373238773)
  cs = cos(w0)
  local hp = norm((1 + cs) / 2, -(1 + cs), (1 + cs) / 2, 1 + alpha, -2 * cs, 1 - alpha)
  local y = run(x, n, shelf, {})
  return run(y, n, hp, y)
end

local function bandpass(fc, q, fs)
  local w0 = 2 * pi * fc / fs
  local alpha, cs = sin(w0) / (2 * q), cos(w0)
  return norm(alpha, 0, -alpha, 1 + alpha, -2 * cs, 1 - alpha)
end

--- Power in a note's harmonics, each band-passed forwards and backwards (no delay).
function M.harmonicPower(x, n, fs, f0)
  local pow = {}
  for i = 1, n do pow[i] = 0 end
  local bw = max(f0 * 0.5, 20)
  local bands = 0
  for h = 1, 12 do
    local fc = h * f0
    if fc > min(10000, fs * 0.45) or bands >= 8 then break end
    bands = bands + 1
    local c = bandpass(fc, fc / bw, fs)
    local y = runBack(run(x, n, c, {}), n, c)
    for i = 1, n do local v = y[i]; pow[i] = pow[i] + v * v end
  end
  return pow
end

--- Mean power in a centred window every `hop` seconds over samples [s0, s1) (0-based, as in engine.js).
function M.envelope(sig, len, fs, hop, win, s0, s1, squared)
  s0 = max(0, s0 or 0)
  s1 = min(len, s1 or len)
  local nfr = max(0, floor((s1 - s0) / (hop * fs)))
  local half = max(1, round(win * fs / 2))
  local lin, db = {}, {}
  local lo = max(0, s0 - half)
  local hi, sum = lo, 0
  for k = 0, nfr - 1 do
    local c = s0 + round(k * hop * fs)
    local a, b = max(0, c - half), min(len, c + half)
    while hi < b do local v = sig[hi + 1]; sum = sum + (squared and v or v * v); hi = hi + 1 end
    while lo < a do local v = sig[lo + 1]; sum = sum - (squared and v or v * v); lo = lo + 1 end
    local v = max(0, sum) / max(1, b - a)
    lin[k + 1] = v
    db[k + 1] = 10 * log10(v + 1e-12)
  end
  return { lin = lin, db = db, t0 = s0 / fs, hop = hop, n = nfr }
end

------------------------------------------------------------------------------
-- One note
------------------------------------------------------------------------------

--- Find one note's onset in [a, b] seconds of an envelope; a port of engine.js findOnset.
function M.findOnset(env, a, b, limit, o)
  local n = env.n
  if n == 0 then return nil end
  local e, lin = env.db, env.lin
  local function fr(t) return min(n - 1, max(0, round((t - env.t0) / env.hop))) end
  local function E(k) return e[k + 1] end
  local ka, kb = fr(a), fr(b)
  if kb <= ka then return nil end
  local d = max(1, round(0.005 / env.hop))
  local ks, best = -1, -math.huge
  for k = ka, kb do
    local r = E(min(n - 1, k + d)) - E(max(0, k - d))
    if r > best then best, ks = r, k end
  end
  if ks < 0 then return nil end
  local kLim = min(fr(limit), ks + round(0.15 / env.hop))
  local kp, pv = ks, E(ks)
  for k = ks, kLim do
    if E(k) > pv then pv, kp = E(k), k elseif E(k) < pv - 3 then break end
  end
  local kb0 = max(0, ks - round(0.06 / env.hop))
  local base = math.huge
  for k = kb0, ks do base = min(base, E(k)) end

  -- what was already sounding, projected forward as a steady decay and taken away
  local p0, p1 = max(0, ks - round(0.06 / env.hop)), ks - round(0.015 / env.hop)
  local slope, icept = 0, base
  if p1 - p0 >= 8 then
    local sx, sy, sxx, sxy, m = 0, 0, 0, 0, 0
    for k = p0, p1 do sx = sx + k; sy = sy + E(k); sxx = sxx + k * k; sxy = sxy + k * E(k); m = m + 1 end
    local den = m * sxx - sx * sx
    slope = den ~= 0 and (m * sxy - sx * sy) / den or 0
    icept = (sy - slope * sx) / m
    if slope > 0 then slope = 0; icept = sy / m end
  elseif p1 >= p0 then
    local sy = 0
    for k = p0, p1 do sy = sy + E(k) end
    icept = sy / (p1 - p0 + 1)
  end
  local function tail(k) return 10 ^ ((icept + slope * k) / 10) end
  local own = {}
  local ownPeak, kOwnPeak = 0, kp
  for k = kb0, max(kp, kb0) do
    local v = max(0, lin[k + 1] - tail(k))
    own[k] = v
    if k >= ks and v > ownPeak then ownPeak, kOwnPeak = v, k end
  end
  if ownPeak <= 0 then
    return { onset = env.t0 + ks * env.hop, peakDb = pv, baseDb = base, riseDb = 0, slope = best, atEdge = true, peakTime = env.t0 + ks * env.hop }
  end
  local ownPeakDb = 10 * log10(ownPeak)
  local rise = ownPeakDb - (icept + slope * ks)
  local drop = o.alignTo == "start" and o.startDb or o.attackDb
  local function thrAt(k) return max(ownPeak * 10 ^ (-drop / 10), 0.5 * tail(k)) end
  local k = kOwnPeak
  while k > kb0 and own[k - 1] >= thrAt(k - 1) do k = k - 1 end
  local t = env.t0 + k * env.hop
  if k > kb0 then
    local a0, a1 = own[k - 1] - thrAt(k - 1), own[k] - thrAt(k)
    if a1 > a0 then t = env.t0 + (k - 1 + (-a0) / (a1 - a0)) * env.hop end
  end
  return {
    onset = t, peakDb = ownPeakDb, baseDb = base, riseDb = max(rise, ownPeakDb - base), slope = best,
    peakTime = env.t0 + kOwnPeak * env.hop, atEdge = (ks == ka or ks == kb),
  }
end

--- Loudest 50 ms of [t0, t1], in dB.
function M.loudness(env, t0, t1)
  local n = env.n
  local k0 = max(0, round((t0 - env.t0) / env.hop))
  local k1 = min(n, round((t1 - env.t0) / env.hop))
  if k1 - k0 < 1 then return -math.huge end
  local L = min(k1 - k0, max(1, round(0.05 / env.hop)))
  local lin = env.lin
  local sum = 0
  for k = k0, k0 + L - 1 do sum = sum + lin[k + 1] end
  local best = sum
  for k = k0 + L, k1 - 1 do
    sum = sum + lin[k + 1] - lin[k - L + 1]
    if sum > best then best = sum end
  end
  return 10 * log10(best / L + 1e-12)
end

------------------------------------------------------------------------------
-- The test part
------------------------------------------------------------------------------

M.TEST_DEFAULTS = {
  low = 24, high = 96,         -- C0 to C6 (middle C is C3)
  levels = { 30, 60, 90, 120 }, -- velocities, or CC1 values when dynamics = "cc1"
  takes = 2,
  dynamics = "velocity",       -- "velocity" | "cc1"
  velocity = 100,              -- the velocity of every note when dynamics = "cc1"
  cc1 = 100,                   -- CC1 held during a velocity test
  spacing = 1.0,               -- seconds from one note to the next
  noteLength = 0.25,           -- seconds each note is held
  lead = 2.0,                  -- seconds before the first note (the switch goes in here)
  channel = 0,                 -- 0-15
  switch = nil,                -- { type = "keyswitch"|"cc"|"program"|"channel", value = n, cc = n }
}

--- What to play: events and the notes to measure, in seconds. Notes on a key go up the range, then the next level.
function M.testLayout(opts)
  local o = {}
  for k, v in pairs(M.TEST_DEFAULTS) do o[k] = v end
  for k, v in pairs(opts or {}) do o[k] = v end
  local ev, notes = {}, {}
  local chan = o.channel
  local sw = o.switch
  if sw and sw.type == "channel" then chan = max(0, min(15, (sw.value or 1) - 1)) end
  if sw and sw.type == "keyswitch" then
    ev[#ev + 1] = { t = o.lead / 2, kind = "note", chan = chan, pitch = sw.value, vel = 100, len = 0.125 }
  elseif sw and sw.type == "cc" then
    ev[#ev + 1] = { t = o.lead / 2, kind = "cc", chan = chan, cc = sw.cc or 32, value = sw.value }
  elseif sw and sw.type == "program" then
    ev[#ev + 1] = { t = o.lead / 2, kind = "program", chan = chan, value = sw.value }
  end
  if o.dynamics ~= "cc1" then ev[#ev + 1] = { t = o.lead / 4, kind = "cc", chan = chan, cc = 1, value = o.cc1 } end
  local t = o.lead
  for _, level in ipairs(o.levels) do
    for p = o.low, o.high do
      for _ = 1, o.takes do
        local vel = level
        if o.dynamics == "cc1" then
          vel = o.velocity
          ev[#ev + 1] = { t = t - min(0.25, o.spacing / 4), kind = "cc", chan = chan, cc = 1, value = level }
        end
        ev[#ev + 1] = { t = t, kind = "note", chan = chan, pitch = p, vel = vel, len = o.noteLength }
        notes[#notes + 1] = { t = t, tEnd = t + o.noteLength, pitch = p, vel = vel, level = level }
        t = t + o.spacing
      end
    end
  end
  return { events = ev, notes = notes, length = t + 1.5, options = o }
end

function M.testSeconds(opts)
  local o = {}
  for k, v in pairs(M.TEST_DEFAULTS) do o[k] = v end
  for k, v in pairs(opts or {}) do o[k] = v end
  return o.lead + (o.high - o.low + 1) * #o.levels * o.takes * o.spacing + 1.5
end

local function measureNote(read, fs, note, nextT, o, whole)
  local maxDelay = o.maxDelayMs / 1000
  local gap = nextT and (nextT - note.t) or math.huge
  local a = note.t - 0.01
  local b = min(note.t + maxDelay, note.t + gap / 2)
  local limit = nextT and (nextT - 0.005) or (note.t + maxDelay + 0.3)
  local segA = a - 0.22
  local segB = min(max(limit, b) + 0.45, b + 0.6) + 0.1
  local n = max(1, round((segB - segA) * fs))
  local x = read(segA, n)
  local s0 = round(0.1 * fs)
  local s1 = n - round(0.1 * fs)
  local kw = M.kWeight(x, n, fs)
  local benv = M.envelope(kw, n, fs, HOP, 0.003, s0, s1)
  benv.t0 = benv.t0 + segA
  local env, on
  if whole then
    env, on = benv, "whole sound"
  else
    local f0 = 440 * 2 ^ ((note.pitch - 69) / 12)
    local pow = M.harmonicPower(x, n, fs, f0)
    env = M.envelope(pow, n, fs, HOP, max(0.003, 0.5 / f0), s0, s1, true)
    env.t0 = env.t0 + segA
    on = "harmonics"
  end
  local r = M.findOnset(env, a, b, limit, o)
  local res = { measuredOn = on, found = false }
  if not (r and r.riseDb >= o.minRiseDb and r.slope >= 1) then return res, env end
  res.found = true
  res.onset = r.onset
  res.delay = r.onset - note.t
  res.atEdge = r.atEdge
  if not whole then
    local k = min(benv.n - 1, max(0, round((r.peakTime - benv.t0) / benv.hop)))
    res.harmonicShareDb = r.peakDb - benv.db[k + 1]
  end
  return res, env
end

--[[ Measure every test note. `read(t, n)` returns n mono samples starting t
     seconds into the render (zeros outside it). `yield`, if given, is called
     after each note with (done, total) - the window passes coroutine.yield so
     REAPER stays responsive.
     Returns { notes, stats, model, warnings }. ]]
function M.measure(read, fs, notes, opts, yield)
  local o = {}
  for k, v in pairs(M.DEFAULTS) do o[k] = v end
  for k, v in pairs(opts or {}) do o[k] = v end
  local total = #notes
  local results = {}
  local function pass(whole)
    for i, nt in ipairs(notes) do
      local nextT = notes[i + 1] and notes[i + 1].t or nil
      local r, env = measureNote(read, fs, nt, nextT, o, whole)
      results[i] = r
      r._env = env
      if yield then yield(i, total) end
    end
  end
  pass(o.method == "whole")
  if o.method == "auto" then
    local found, shares = 0, {}
    for _, r in ipairs(results) do
      if r.found then found = found + 1; shares[#shares + 1] = r.harmonicShareDb end
    end
    local share = median(shares)
    if found < #notes / 2 or share < -12 then
      local keep = results
      results = {}
      pass(true)
      local again = 0
      for _, r in ipairs(results) do if r.found then again = again + 1 end end
      if not (share < -12 or again > found) then results = keep end
    end
  end

  -- loudness: from the onset to the note's end, the next onset, or 400 ms
  for i, r in ipairs(results) do
    local nt = notes[i]
    if r.found then
      local stop = r.onset + min(0.4, max(0.05, nt.tEnd - nt.t))
      local nx = results[i + 1]
      if nx and nx.found then stop = min(stop, nx.onset) elseif notes[i + 1] then stop = min(stop, notes[i + 1].t) end
      stop = max(stop, r.onset + 0.01)
      r.loudDb = M.loudness(r._env, r.onset, stop)
    end
  end
  for _, r in ipairs(results) do r._env = nil end

  -- expected loudness from the level and the key
  local found = {}
  for i, r in ipairs(results) do
    r.pitch, r.vel, r.level, r.t = notes[i].pitch, notes[i].vel, notes[i].level, notes[i].t
    if r.found and r.loudDb > -math.huge then found[#found + 1] = r end
  end
  local model = { fitted = false, terms = {} }
  local warnings = {}
  if #found >= 6 then
    local function varies(key)
      local v = {}
      for i, r in ipairs(found) do v[i] = r[key] end
      return M.stdev(v) > 2
    end
    local lo, hi = math.huge, -math.huge
    for _, r in ipairs(found) do lo = min(lo, r.pitch); hi = max(hi, r.pitch) end
    local terms = { { name = "level", f = function() return 1 end } }
    if o.dynamics == "cc1" then
      if varies("level") then terms[#terms + 1] = { name = "CC1", f = function(r) return r.level end } end
    elseif varies("vel") then
      terms[#terms + 1] = { name = "velocity", f = function(r) return r.vel end }
    end
    if hi - lo >= 3 then terms[#terms + 1] = { name = "pitch", f = function(r) return (r.pitch - 60) / 12 end } end
    if hi - lo >= 12 and #found >= 12 then terms[#terms + 1] = { name = "pitch²", f = function(r) return ((r.pitch - 60) / 12) ^ 2 end } end
    local X, y = {}, {}
    for i, r in ipairs(found) do
      X[i] = {}
      for j, t in ipairs(terms) do X[i][j] = t.f(r) end
      y[i] = r.loudDb
    end
    local beta, scale = M.robustFit(X, y)
    if beta then
      model.fitted, model.scaleDb = true, scale
      for j, t in ipairs(terms) do
        model.terms[j] = { name = t.name, coef = beta[j] }
        if t.name == "velocity" and beta[j] >= 0.05 and beta[j] <= 1.5 then model.dbPerVelocity = beta[j] end
      end
      for i, r in ipairs(found) do
        local e = 0
        for j = 1, #terms do e = e + X[i][j] * beta[j] end
        r.expectedDb, r.deviationDb = e, r.loudDb - e
      end
    end
  else
    warnings[#warnings + 1] = "Fewer than six notes were found, too few to judge which are too loud or too quiet."
  end

  -- worth a look
  for _, r in ipairs(results) do
    if r.found then
      local same = {}
      for _, q in ipairs(results) do if q ~= r and q.found and q.pitch == r.pitch then same[#same + 1] = q.delay end end
      r.check = r.atEdge or (#same >= 2 and abs(r.delay - median(same)) > 0.015)
    end
  end

  local delays = {}
  for _, r in ipairs(found) do delays[#delays + 1] = r.delay end
  return {
    notes = results, model = model, warnings = warnings, options = o,
    stats = {
      notes = #notes, found = #found,
      medianMs = median(delays) * 1000,
      minMs = (#delays > 0 and select(1, minmax(delays)) or 0 / 0) * 1000,
      maxMs = (#delays > 0 and select(2, minmax(delays)) or 0 / 0) * 1000,
    },
  }
end

local function r2(x) return floor(x * 100 + 0.5) / 100 end

--- A profile in the same format the page reads (engine.js checkProfile), plus where it came from.
function M.learnProfile(result, meta)
  meta = meta or {}
  local groups, order = {}, {}
  for _, r in ipairs(result.notes) do
    if r.found then
      local k = r.pitch .. ":" .. r.level
      if not groups[k] then groups[k] = {}; order[#order + 1] = k end
      local g = groups[k]
      g[#g + 1] = r
    end
  end
  local entries = {}
  for _, k in ipairs(order) do
    local g = groups[k]
    local d, l, dev = {}, {}, {}
    for i, r in ipairs(g) do d[i] = r.delay; l[i] = r.loudDb; dev[i] = r.deviationDb or 0 end
    entries[#entries + 1] = {
      pitch = g[1].pitch, vel = g[1].level,
      delayMs = r2(median(d) * 1000), loudDb = r2(median(l)), deviationDb = r2(median(dev)),
      spreadMs = r2((select(2, minmax(d)) - select(1, minmax(d))) * 1000), takes = #g,
    }
  end
  table.sort(entries, function(a, b) return a.pitch < b.pitch or (a.pitch == b.pitch and a.vel < b.vel) end)
  if #entries == 0 then return nil, "No test notes were found in the render." end
  local notFound = {}
  for _, r in ipairs(result.notes) do if not r.found then notFound[#notFound + 1] = { pitch = r.pitch, vel = r.level } end end
  local name = meta.name or ((meta.instrument or "Untitled") .. (meta.articulation and meta.articulation ~= "" and (" - " .. meta.articulation) or ""))
  return {
    kind = "note-position-volume-fixer/profile", version = 1,
    name = name, instrument = meta.instrument, articulation = meta.articulation, plugin = meta.plugin,
    switch = meta.switch, dynamics = result.options.dynamics or "velocity",
    created = meta.created or os.date("!%Y-%m-%dT%H:%M:%SZ"),
    measuredIn = meta.measuredIn or "REAPER",
    alignTo = result.options.alignTo,
    dbPerVelocity = result.model.dbPerVelocity,
    notFound = notFound,
    entries = entries,
  }
end

return M
