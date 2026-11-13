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

local function switchMatches(sw, state, note)
  if not sw or not sw.type or sw.type == "none" then return false end
  if sw.type == "keyswitch" then return state.keyswitch == sw.value end
  if sw.type == "cc" then return state.cc[note.chan] and state.cc[note.chan][sw.cc or 32] == sw.value end
  if sw.type == "program" then return state.program[note.chan] == sw.value end
  if sw.type == "channel" then return note.chan + 1 == sw.value end
  return false
end

--[[ Plan the fix.
     notes:  { id, t, tEnd, pitch, vel, chan, cc1 } - every note in the item(s), keyswitches included
     events: { id, t, kind = "cc"|"program", chan, cc, value } - CCs and program changes
     profiles: the instrument's profiles; `fallback`: the one for notes no switch chose (may be nil)
     Returns { changes = { [noteId] = {...} }, moves = { [eventId or noteId] = newT }, minT, counts, warnings } ]]
function F.plan(notes, events, profiles, fallback, opts)
  local o = {}
  for k, v in pairs(F.DEFAULTS) do o[k] = v end
  for k, v in pairs(opts or {}) do o[k] = v end

  local ksPitch = {}
  for _, p in ipairs(profiles) do
    if p.switch and p.switch.type == "keyswitch" then ksPitch[p.switch.value] = true end
  end
  local function isKeyswitch(n) return ksPitch[n.pitch] or n.pitch <= o.keyswitchMax end

  -- everything in time order; at the same time, switches first
  local timeline = {}
  for _, n in ipairs(notes) do timeline[#timeline + 1] = { t = n.t, note = n, first = isKeyswitch(n) and 0 or 1 } end
  for _, e in ipairs(events) do timeline[#timeline + 1] = { t = e.t, event = e, first = 0 } end
  table.sort(timeline, function(a, b)
    if abs(a.t - b.t) > 1e-9 then return a.t < b.t end
    return a.first < b.first
  end)

  local noneProfile
  for _, p in ipairs(profiles) do if not p.switch or not p.switch.type or p.switch.type == "none" then noneProfile = p end end

  local state = { keyswitch = nil, cc = {}, program = {} }
  local played, keyswitches = {}, {}
  local counts = { fixed = 0, noProfile = 0, outside = 0, moved = 0, velocity = 0, cc11 = 0 }
  for _, item in ipairs(timeline) do
    local e, n = item.event, item.note
    if e then
      if e.kind == "cc" then
        state.cc[e.chan] = state.cc[e.chan] or {}
        state.cc[e.chan][e.cc] = e.value
      elseif e.kind == "program" then
        state.program[e.chan] = e.value
      end
    elseif isKeyswitch(n) then
      if ksPitch[n.pitch] then state.keyswitch = n.pitch end
      keyswitches[#keyswitches + 1] = n
    else
      local chosen
      for _, p in ipairs(profiles) do if switchMatches(p.switch, state, n) then chosen = p; break end end
      chosen = chosen or noneProfile or fallback
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
