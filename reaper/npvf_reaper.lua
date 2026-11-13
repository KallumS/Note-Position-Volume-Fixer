--[[ Everything that touches REAPER (but not the window): capturing an
     instrument, making a test track, rendering the test part, reading the
     render, cleaning up, and reading and writing the notes of selected items.

     Calls are the documented ReaScript API (REAPER 7). Nothing here has been
     run inside REAPER from where it was written: tests/lua/reaper_mock.lua
     stands in for it, written from the same documented signatures.
]]

local R = {}
local J -- set by R.init

function R.init(json) J = json; return R end

R.APPLY_FX = 40209 -- Item: Apply track/take FX to items as new take

------------------------------------------------------------------------------
-- Files
------------------------------------------------------------------------------

local SEP = package.config:sub(1, 1)
function R.folder()
  local p = reaper.GetResourcePath() .. SEP .. "Data" .. SEP .. "Note Fixer"
  reaper.RecursiveCreateDirectory(p .. SEP .. "Profiles", 0)
  return p
end
function R.profileFolder() return R.folder() .. SEP .. "Profiles" end

function R.safeName(s)
  s = tostring(s or ""):gsub('[\\/:%*%?"<>|%c]+', "-"):gsub("^%s+", ""):gsub("%s+$", "")
  return s ~= "" and s or "Untitled"
end

local function readFile(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end
local function writeFile(p, s)
  local tmp = p .. ".part"
  local f, err = io.open(tmp, "wb")
  if not f then return false, err end
  f:write(s)
  f:close()
  os.remove(p)
  local ok, e2 = os.rename(tmp, p)
  return ok, e2
end
R.readFile, R.writeFile = readFile, writeFile

function R.profilePath(instrument, articulation)
  local n = R.safeName(instrument) .. ((articulation and articulation ~= "") and (" - " .. R.safeName(articulation)) or "")
  return R.profileFolder() .. SEP .. n .. ".json"
end

function R.saveProfile(p)
  local path = R.profilePath(p.instrument or p.name, p.articulation)
  local ok, err = writeFile(path, J.encode(p, " "))
  if not ok then return nil, err end
  return path
end

--- Every profile in the folder, grouped by instrument: { [instrument] = { profiles... } }, plus a sorted list of names.
function R.loadProfiles()
  local dir = R.profileFolder()
  local by, names = {}, {}
  local i = 0
  while true do
    local f = reaper.EnumerateFiles(dir, i)
    if not f then break end
    i = i + 1
    if f:lower():match("%.json$") then
      local p = J.decode(readFile(dir .. SEP .. f) or "")
      if type(p) == "table" and p.kind == "note-position-volume-fixer/profile" and type(p.entries) == "table" and #p.entries > 0 then
        local inst = p.instrument or p.name
        if not by[inst] then by[inst] = {}; names[#names + 1] = inst end
        table.insert(by[inst], p)
      end
    end
  end
  table.sort(names, function(a, b) return a:lower() < b:lower() end)
  for _, list in pairs(by) do table.sort(list, function(a, b) return (a.articulation or a.name) < (b.articulation or b.name) end) end
  return by, names
end

function R.loadInstruments()
  local s = readFile(R.folder() .. SEP .. "Instruments.json")
  if not s then return {} end
  local t = J.decode(s)
  return type(t) == "table" and t or {}
end
function R.saveInstruments(list) return writeFile(R.folder() .. SEP .. "Instruments.json", J.encode(list, " ")) end

------------------------------------------------------------------------------
-- Track chunks
------------------------------------------------------------------------------

--- The <FXCHAIN ...> block of a track's chunk, nested blocks and all.
function R.fxChainBlock(chunk)
  local out, depth, inside = {}, 0, false
  for line in (chunk .. "\n"):gmatch("([^\n]*)\n") do
    local trimmed = line:match("^%s*(.-)%s*$")
    if not inside and trimmed:match("^<FXCHAIN") then inside, depth = true, 0 end
    if inside then
      out[#out + 1] = line
      if trimmed:sub(1, 1) == "<" then depth = depth + 1 elseif trimmed == ">" then depth = depth - 1 end
      if depth == 0 then break end
    end
  end
  return inside and table.concat(out, "\n") or nil
end

--- A track chunk with its FX chain replaced; each FX gets a new ID so two tracks never share one.
function R.withFxChain(chunk, block)
  local old = R.fxChainBlock(chunk)
  if old then
    local s, e = chunk:find(old, 1, true)
    chunk = chunk:sub(1, s - 1) .. chunk:sub(e + 2)
  end
  block = block:gsub("FXID %b{}", function() return "FXID " .. reaper.genGuid("") end)
  local at = chunk:match("^.*()\n%s*>%s*$")
  if not at then return nil end
  return chunk:sub(1, at) .. block .. chunk:sub(at)
end

--- The selected track's instrument, ready to recreate on a fresh track: { name, plugin, chain } or nil, reason.
function R.captureSelectedTrack()
  local tr = reaper.GetSelectedTrack(0, 0)
  if not tr then return nil, "Select the track with the instrument first." end
  if reaper.TrackFX_GetInstrument(tr) < 0 then return nil, "The selected track has no instrument on it." end
  local ok, chunk = reaper.GetTrackStateChunk(tr, "", false)
  if not ok then return nil, "REAPER didn't give the track's settings." end
  local block = R.fxChainBlock(chunk)
  if not block then return nil, "The selected track has no effects chain." end
  local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
  local _, plugin = reaper.TrackFX_GetFXName(tr, reaper.TrackFX_GetInstrument(tr), "")
  plugin = (plugin or ""):gsub("^%w+: ", "")
  return { name = (name ~= "" and name) or plugin, plugin = plugin, chain = block, articulations = {} }
end

------------------------------------------------------------------------------
-- A test
------------------------------------------------------------------------------

--- A new track at the end of the project, playing the captured instrument. Effects after the instrument can be left out.
function R.makeTestTrack(inst, leaveOutEffects)
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, false)
  local tr = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "Note Fixer test: " .. inst.name, true)
  local _, chunk = reaper.GetTrackStateChunk(tr, "", false)
  local newChunk = R.withFxChain(chunk, inst.chain)
  if not newChunk or not reaper.SetTrackStateChunk(tr, newChunk, false) then
    reaper.DeleteTrack(tr)
    return nil, "Couldn't put " .. inst.name .. " on a new track."
  end
  local instIdx = reaper.TrackFX_GetInstrument(tr)
  if instIdx < 0 then
    reaper.DeleteTrack(tr)
    return nil, inst.name .. "'s plug-in didn't load. Is it still installed?"
  end
  if leaveOutEffects then
    for i = instIdx + 1, reaper.TrackFX_GetCount(tr) - 1 do reaper.TrackFX_SetEnabled(tr, i, false) end
  end
  return tr
end

--- Write the test part into a new item at `at` seconds and render it through the track. Returns the render.
function R.renderTest(tr, layout, at)
  local item = reaper.CreateNewMIDIItemInProj(tr, at, at + layout.length, false)
  if not item then return nil, "Couldn't make the test item." end
  local take = reaper.GetActiveTake(item)
  local function ppq(t) return reaper.MIDI_GetPPQPosFromProjTime(take, at + t) end
  for _, e in ipairs(layout.events) do
    if e.kind == "note" then
      reaper.MIDI_InsertNote(take, false, false, ppq(e.t), ppq(e.t + e.len), e.chan, e.pitch, e.vel, true)
    elseif e.kind == "cc" then
      reaper.MIDI_InsertCC(take, false, false, ppq(e.t), 0xB0, e.chan, e.cc, e.value)
    elseif e.kind == "program" then
      reaper.MIDI_InsertCC(take, false, false, ppq(e.t), 0xC0, e.chan, e.value, 0)
    end
  end
  reaper.MIDI_Sort(take)
  reaper.SelectAllMediaItems(0, false)
  reaper.SetMediaItemSelected(item, true)
  reaper.Main_OnCommand(R.APPLY_FX, 0)
  local audio = reaper.GetActiveTake(item)
  if not audio or reaper.TakeIsMIDI(audio) then
    reaper.DeleteTrackMediaItem(tr, item)
    return nil, "REAPER didn't render the test to audio."
  end
  local src = reaper.GetMediaItemTake_Source(audio)
  local fs = reaper.GetMediaSourceSampleRate(src)
  if not fs or fs <= 0 then fs = 48000 end
  local nch = math.max(1, reaper.GetMediaSourceNumChannels(src))
  local acc = reaper.CreateTakeAudioAccessor(audio)
  local file = reaper.GetMediaSourceFileName(src, "")
  local render = { track = tr, item = item, take = audio, accessor = acc, fs = fs, channels = nch, file = file }
  --- n mono samples from t seconds into the item (zeros before it)
  function render.read(t, n)
    local out = {}
    local skip = 0
    if t < 0 then skip = math.min(n, math.floor(-t * fs + 0.5)); for i = 1, skip do out[i] = 0 end; t = 0 end
    local want = n - skip
    if want <= 0 then return out end
    local buf = reaper.new_array(want * nch)
    reaper.GetAudioAccessorSamples(acc, fs, nch, t, want, buf)
    local v = buf.table(1, want * nch)
    for i = 0, want - 1 do
      local s = 0
      for c = 1, nch do s = s + (v[i * nch + c] or 0) end
      out[skip + i + 1] = s / nch
    end
    return out
  end
  return render
end

--- Remove the test item, and its rendered file unless kept. Returns a file that couldn't be deleted, if any.
function R.discardRender(render, keepFile)
  if render.accessor then reaper.DestroyAudioAccessor(render.accessor); render.accessor = nil end
  reaper.DeleteTrackMediaItem(render.track, render.item)
  if not keepFile and render.file and render.file ~= "" then
    if not os.remove(render.file) then return render.file end
  end
end

------------------------------------------------------------------------------
-- Fixing selected items
------------------------------------------------------------------------------

--- Selected MIDI items, grouped by track: { { track, name, items = { {item, take} } } }
function R.selectedMidiByTrack()
  local groups, byTrack = {}, {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take = reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then
      local tr = reaper.GetMediaItem_Track(item)
      local g = byTrack[tr]
      if not g then
        local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
        g = { track = tr, name = name, items = {} }
        byTrack[tr] = g
        groups[#groups + 1] = g
      end
      g.items[#g.items + 1] = { item = item, take = take }
    end
  end
  return groups
end

--- One take's notes and CC/program events, in seconds, with ids that find them again.
function R.readTake(take, base)
  local _, nn, nc = reaper.MIDI_CountEvts(take)
  local notes, events, cc1 = {}, {}, {}
  for i = 0, nc - 1 do
    local _, _, _, ppq, msg, chan, m2, m3 = reaper.MIDI_GetCC(take, i)
    local t = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq)
    if msg == 0xB0 then
      events[#events + 1] = { id = base + 500000 + i, idx = i, t = t, kind = "cc", chan = chan, cc = m2, value = m3 }
      if m2 == 1 then cc1[#cc1 + 1] = { t = t, chan = chan, v = m3 } end
    elseif msg == 0xC0 then
      events[#events + 1] = { id = base + 500000 + i, idx = i, t = t, kind = "program", chan = chan, value = m2 }
    end
  end
  table.sort(cc1, function(a, b) return a.t < b.t end)
  for i = 0, nn - 1 do
    local _, _, _, sp, ep, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
    local t = reaper.MIDI_GetProjTimeFromPPQPos(take, sp)
    local level
    for _, c in ipairs(cc1) do if c.chan == chan and c.t <= t + 1e-9 then level = c.v elseif c.t > t + 1e-9 then break end end
    notes[#notes + 1] = { id = base + i, idx = i, t = t, tEnd = reaper.MIDI_GetProjTimeFromPPQPos(take, ep), pitch = pitch, vel = vel, chan = chan, cc1 = level }
  end
  return notes, events
end

--- Write a plan back into one take. Extends the item to the left if a note now starts before it.
function R.writeTake(item, take, notes, events, plan)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local ccTimes = {}
  for _, e in ipairs(events) do ccTimes[e.idx] = e end
  local start = pos
  for _, n in ipairs(notes) do
    local c, m = plan.changes[n.id], plan.moves[n.id]
    start = math.min(start, (c and c.newT) or (m and m.t) or n.t)
  end
  for _, e in ipairs(events) do local m = plan.moves[e.id]; if m then start = math.min(start, m.t) end end
  if start < pos - 1e-9 then
    -- Everything is placed again from its time afterwards, so it doesn't matter how REAPER re-anchors the events.
    reaper.MIDI_SetItemExtents(item, reaper.TimeMap2_timeToQN(0, start), reaper.TimeMap2_timeToQN(0, pos + len))
  end
  local function ppq(t) return reaper.MIDI_GetPPQPosFromProjTime(take, t) end
  for _, n in ipairs(notes) do
    local c, m = plan.changes[n.id], plan.moves[n.id]
    local t, tEnd, vel = n.t, n.tEnd, n.vel
    if c then t, tEnd, vel = c.newT, c.newTEnd, c.newVel elseif m then t, tEnd = m.t, m.tEnd or n.tEnd end
    reaper.MIDI_SetNote(take, n.idx, nil, nil, ppq(t), ppq(tEnd), nil, nil, vel, true)
  end
  for _, e in ipairs(events) do
    local m = plan.moves[e.id]
    reaper.MIDI_SetCC(take, e.idx, nil, nil, ppq(m and m.t or e.t), nil, nil, nil, nil, true)
  end
  reaper.MIDI_Sort(take)
  -- one CC11 a note, a tick before it so it arrives first
  for _, n in ipairs(notes) do
    local c = plan.changes[n.id]
    if c and c.cc11 then reaper.MIDI_InsertCC(take, false, false, math.max(0, ppq(c.newT) - 1), 0xB0, n.chan, 11, c.cc11) end
  end
  reaper.MIDI_Sort(take)
end

return R
