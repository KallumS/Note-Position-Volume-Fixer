--[[ Fixing notes from profiles: which articulation each note plays, how late
     its sound will be, and what to change. Plain Lua, no REAPER.

     A port of engine.js's profileAt() and plan() for profiles, with one
     addition the page doesn't have: several profiles for one instrument,
     each note taking the one its articulation switch chose (a keyswitch, a
     CC value, a program change or a MIDI channel).

     Times are seconds. The window turns them into PPQ.
]]

local F = {}

local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local function round(x) return floor(x + 0.5) end
local function clamp(x, lo, hi) return max(lo, min(hi, x)) end

F.DEFAULTS = {
  timing = true,
  strength = 1,          -- 0..1 of the measured delay
  targetMs = 0,          -- land this many ms after the grid
  moveEnds = true,
  volume = "auto",       -- "auto" (velocity, or CC11 for CC1 profiles) | "velocity" | "cc11" | "off"
  toleranceDb = 1,
  dbPerVelocity = nil,   -- nil: the profile's, else 0.25
  cc11Base = 100,
  dbPerCC = 0.3,
  keyswitchMax = -1,     -- notes at or below are keyswitches too, whatever the profiles say
  lookbackSec = 0.125,   -- keyswitches this far before a note move with it
}

--- Delay and loudness deviation for any key and level, between the measured ones (engine.js profileAt).
function F.profileAt(p, pitch, vel)
  local pitches, seen = {}, {}
  for _, e in ipairs(p.entries) do
    if not seen[e.pitch] then seen[e.pitch] = true; pitches[#pitches + 1] = e.pitch end
  end
  table.sort(pitches)
  local first, last = pitches[1], pitches[#pitches]
  local lo, hi = first, last
  for _, q in ipairs(pitches) do if q <= pitch then lo = q end end
  for i = #pitches, 1, -1 do if pitches[i] >= pitch then hi = pitches[i] end end
  if pitch < first then lo, hi = first, first end
  if pitch > last then lo, hi = last, last end
  local function atKey(q)
    local row = {}
    for _, e in ipairs(p.entries) do if e.pitch == q then row[#row + 1] = e end end
    table.sort(row, function(a, b) return a.vel < b.vel end)
    local a, b = row[1], row[#row]
    for _, e in ipairs(row) do if e.vel <= vel then a = e end end
    for i = #row, 1, -1 do if row[i].vel >= vel then b = row[i] end end
    if vel < row[1].vel then a, b = row[1], row[1] end
    if vel > row[#row].vel then a, b = row[#row], row[#row] end
    local f = (b.vel == a.vel) and 0 or (vel - a.vel) / (b.vel - a.vel)
    return a.delayMs + f * (b.delayMs - a.delayMs), a.deviationDb + f * (b.deviationDb - a.deviationDb)
  end
  local dA, vA = atKey(lo)
  local dB, vB = atKey(hi)
  local f = (hi == lo) and 0 or (pitch - lo) / (hi - lo)
  return {
    delayMs = dA + f * (dB - dA),
    deviationDb = (lo == pitch) and vA or ((hi == pitch) and vB or 0),
    outside = pitch < first or pitch > last,
  }
end

--- What a profile needs to be in force, from its outputs (`send`, `channel`, a Reaticulate `program`)
--- or, for profiles saved before 1.1, its single `switch`.
function F.conditions(p)
  local c = { notes = {}, ccs = {}, programs = {}, channel = p.channel, reaticulate = p.program }
  local send = p.send
  if not send and p.switch and p.switch.type then
    local sw = p.switch
    send = {}
    if sw.type == "keyswitch" then send[1] = { kind = "note", pitch = sw.value, vel = sw.vel or 127 }
    elseif sw.type == "cc" then send[1] = { kind = "cc", cc = sw.cc or 32, value = sw.value }
    elseif sw.type == "program" then send[1] = { kind = "program", value = sw.value }
    elseif sw.type == "channel" then c.channel = sw.value end
  end
  for _, o in ipairs(send or {}) do
    if o.kind == "note" then c.notes[#c.notes + 1] = o
    elseif o.kind == "cc" then c.ccs[#c.ccs + 1] = o
    elseif o.kind == "program" then c.programs[#c.programs + 1] = o.value end
  end
  c.count = #c.notes + #c.ccs + #c.programs + (c.channel and 1 or 0)
  return c
end

--[[ Which articulation is in force, as a part plays.

     Keyswitches latch. A map can need several at once (VSL's Synchron
     dimension trees: C0 + F#1 + F6), so the state is a set of keys held "on",
     and pressing a key turns off only the keys it can't be combined with -
     two keys can be combined if some articulation uses both. A key whose
     velocity matters (Spitfire's UACC KS: one key, the velocity chooses) is
     told apart by its velocity. ]]
local function Switches(profiles)
  local S = { conds = {}, velMatters = {}, keyswitchPitch = {} }
  local vels = {}
  for i, p in ipairs(profiles) do
    S.conds[i] = F.conditions(p)
    for _, o in ipairs(S.conds[i].notes) do
      S.keyswitchPitch[o.pitch] = true
      vels[o.pitch] = vels[o.pitch] or {}
      vels[o.pitch][o.vel or 127] = true
    end
  end
  for pitch, set in pairs(vels) do
    local n = 0
    for _ in pairs(set) do n = n + 1 end
    if n > 1 then S.velMatters[pitch] = true end
  end
  function S.key(pitch, vel) return S.velMatters[pitch] and (pitch .. ":" .. (vel or 127)) or tostring(pitch) end
  local together = {}
  for _, c in ipairs(S.conds) do
    for _, a in ipairs(c.notes) do
      for _, b in ipairs(c.notes) do together[S.key(a.pitch, a.vel) .. "|" .. S.key(b.pitch, b.vel)] = true end
    end
  end
  function S.combinable(a, b) return a == b or together[a .. "|" .. b] end
  return S
end
F.Switches = Switches

function F.plan(notes, events, profiles, fallback, opts)
  local o = {}
  for k, v in pairs(F.DEFAULTS) do o[k] = v end
  for k, v in pairs(opts or {}) do o[k] = v end

  local S = Switches(profiles)
  local function isKeyswitch(n) return S.keyswitchPitch[n.pitch] or n.pitch <= o.keyswitchMax end

  -- everything in time order; at the same time, switches first
  local timeline = {}
  for _, n in ipairs(notes) do timeline[#timeline + 1] = { t = n.t, note = n, first = isKeyswitch(n) and 0 or 1 } end
  for _, e in ipairs(events) do timeline[#timeline + 1] = { t = e.t, event = e, first = 0 } end
  table.sort(timeline, function(a, b)
    if abs(a.t - b.t) > 1e-9 then return a.t < b.t end
    return a.first < b.first
  end)

  local noneProfile
  for i, p in ipairs(profiles) do if S.conds[i].count == 0 and not p.program then noneProfile = p end end

  -- `on`: keyswitch keys held on, with when; cc[chan][cc] = {value, t}; program[chan] = {value, t}
  local state = { on = {}, cc = {}, program = {} }
  local played, keyswitches = {}, {}
  local counts = { fixed = 0, noProfile = 0, outside = 0, moved = 0, velocity = 0, cc11 = 0 }

  local function choose(n)
    local best, bestScore, bestT
    for i, p in ipairs(profiles) do
      local c = S.conds[i]
      local score, latest = nil, -math.huge
      -- a Reaticulate articulation chosen by its program number
      local pr = state.program[n.chan]
      if c.reaticulate and pr and pr.value == c.reaticulate then score, latest = 100, pr.t end
      if not score and c.count > 0 then
        local okk = true
        for _, o in ipairs(c.notes) do
          local t = state.on[S.key(o.pitch, o.vel)]
          if not t then okk = false; break end
          latest = max(latest, t)
        end
        for _, o in ipairs(c.ccs) do
          local v = state.cc[n.chan] and state.cc[n.chan][o.cc]
          if not (v and v.value == o.value) then okk = false; break end
          latest = max(latest, v.t)
        end
        for _, val in ipairs(c.programs) do
          if not (pr and pr.value == val) then okk = false; break end
          latest = max(latest, pr.t)
        end
        if c.channel and n.chan + 1 ~= c.channel then okk = false end
        if okk then score = c.count end
      end
      -- the most specific match wins; at a draw, the one chosen last
      if score and (not best or score > bestScore or (score == bestScore and latest > bestT)) then
        best, bestScore, bestT = p, score, latest
      end
    end
    return best
  end

  for _, item in ipairs(timeline) do
    local e, n = item.event, item.note
    if e then
      if e.kind == "cc" then
        state.cc[e.chan] = state.cc[e.chan] or {}
        state.cc[e.chan][e.cc] = { value = e.value, t = e.t }
      elseif e.kind == "program" then
        state.program[e.chan] = { value = e.value, t = e.t }
      end
    elseif isKeyswitch(n) then
      if S.keyswitchPitch[n.pitch] then
        local k = S.key(n.pitch, n.vel)
        for other in pairs(state.on) do if not S.combinable(other, k) then state.on[other] = nil end end
        state.on[k] = n.t
      end
      keyswitches[#keyswitches + 1] = n
    else
      local chosen = choose(n) or noneProfile or fallback
      played[#played + 1] = { note = n, profile = chosen }
    end
  end

  -- notes sounding together can't each have their own CC11
  table.sort(played, function(a, b) return a.note.t < b.note.t end)
  for i, a in ipairs(played) do
    for j = i + 1, #played do
      local b = played[j]
      if b.note.t >= a.note.tEnd - 0.005 and b.note.t - a.note.t >= 0.03 then break end
      a.overlapped, b.overlapped = true, true
    end
  end

  local changes = {}
  for _, pl in ipairs(played) do
    local n, p = pl.note, pl.profile
    local c = { id = n.id, newT = n.t, newTEnd = n.tEnd, newVel = n.vel, cc11 = nil, shiftMs = 0, profile = p and p.name }
    changes[n.id] = c
    if not p then
      counts.noProfile = counts.noProfile + 1
    else
      counts.fixed = counts.fixed + 1
      local cc1Profile = p.dynamics == "cc1"
      local level = cc1Profile and (n.cc1 or 100) or n.vel
      local at = F.profileAt(p, n.pitch, level)
      if at.outside then counts.outside = counts.outside + 1; c.outside = true end
      -- volume first: a new velocity has its own delay
      local target = o.volume
      if target == "auto" then target = cc1Profile and "cc11" or "velocity" end
      if target ~= "off" and abs(at.deviationDb) >= o.toleranceDb then
        if target == "cc11" then
          if not pl.overlapped then
            c.cc11 = clamp(round(o.cc11Base - at.deviationDb / o.dbPerCC), 0, 127)
          end
        else
          local dbv = o.dbPerVelocity or p.dbPerVelocity or 0.25
          c.newVel = clamp(round(n.vel - at.deviationDb / dbv), 1, 127)
        end
      end
      if target == "cc11" and not pl.overlapped and not c.cc11 then c.cc11 = o.cc11Base end
      if c.newVel ~= n.vel then counts.velocity = counts.velocity + 1 end
      if c.cc11 then counts.cc11 = counts.cc11 + 1 end
      if o.timing then
        local delay = cc1Profile and at.delayMs or F.profileAt(p, n.pitch, c.newVel).delayMs
        local shift = -(delay - o.targetMs) / 1000 * o.strength
        if abs(shift) >= 0.0005 then
          c.newT = n.t + shift
          if o.moveEnds then c.newTEnd = n.tEnd + shift end
          if c.newTEnd <= c.newT then c.newTEnd = c.newT + 0.001 end
          c.shiftMs = shift * 1000
          counts.moved = counts.moved + 1
        end
      end
      c.delayMs = at.delayMs
    end
  end

  -- a note moved under the end of the same key's last note: end that note there
  local lanes = {}
  for _, pl in ipairs(played) do
    local k = pl.note.chan * 128 + pl.note.pitch
    lanes[k] = lanes[k] or {}
    table.insert(lanes[k], changes[pl.note.id])
  end
  for _, lane in pairs(lanes) do
    table.sort(lane, function(a, b) return a.newT < b.newT end)
    for i = 1, #lane - 1 do
      if lane[i].newTEnd > lane[i + 1].newT then
        lane[i].newTEnd = max(lane[i].newT + 0.001, lane[i + 1].newT)
        lane[i].trimmed = true
      end
    end
  end

  -- keyswitches (up to lookbackSec before) and CCs and program changes exactly on a note move with it
  local groups = {}
  for _, pl in ipairs(played) do
    local c = changes[pl.note.id]
    local key = pl.note.chan .. ":" .. string.format("%.6f", pl.note.t)
    local g = groups[key]
    local dt = c.newT - pl.note.t
    if not g then groups[key] = { t = pl.note.t, chan = pl.note.chan, dt = min(0, dt) } else g.dt = min(g.dt, dt) end
  end
  local starts = {}
  for _, g in pairs(groups) do if g.dt < 0 then starts[#starts + 1] = g end end
  table.sort(starts, function(a, b) return a.t < b.t end)
  local moves = {}
  local function groupFor(t, chan, reach)
    for _, g in ipairs(starts) do
      if g.chan == chan and g.t >= t - 1e-9 then
        if g.t - t <= reach + 1e-9 then return g end
        return nil
      end
    end
  end
  for _, k in ipairs(keyswitches) do
    local g = groupFor(k.t, k.chan, o.lookbackSec)
    if g then moves[k.id] = { t = k.t + g.dt, tEnd = k.tEnd + g.dt } end
  end
  for _, e in ipairs(events) do
    local g = groupFor(e.t, e.chan, e.kind == "program" and o.lookbackSec or 0)
    if g then moves[e.id] = { t = e.t + g.dt } end
  end

  local minT = math.huge
  for _, c in pairs(changes) do minT = min(minT, c.newT) end
  for _, m in pairs(moves) do minT = min(minT, m.t) end

  local warnings = {}
  if counts.noProfile > 0 then
    warnings[#warnings + 1] = counts.noProfile .. (counts.noProfile == 1 and " note has" or " notes have") ..
      " no profile for its articulation and was left alone. Choose one under When no switch says."
  end
  if counts.outside > 0 then
    warnings[#warnings + 1] = counts.outside .. (counts.outside == 1 and " note is" or " notes are") ..
      " outside the measured keys and used the nearest one."
  end
  return { changes = changes, moves = moves, minT = minT, counts = counts, warnings = warnings, played = played }
end

return F
