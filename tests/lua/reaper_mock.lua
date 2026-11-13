--[[ A REAPER that records instead of doing, for test_scripts.lua.

     Written from the ReaScript API's documented signatures (REAPER 7), not
     from what the scripts expect: a mock shaped by the code agrees with the
     code's bugs. (Good Idea's tests/reaper_mock.lua says the same, and is
     where the idea comes from.) Anything not here raises.

     The instrument: "Apply track/take FX to items as new take" (40209) on a
     MIDI item renders it with the made-up library in tests/synth.js, through
     tests/lua/render_cli.js, so the scripts measure real audio. An
     instrument "still loading its samples" (P.loadSeconds after its chunk was
     set) renders silence.

     Two deliberate unknowns are played pessimistically:
     - MIDI_SetItemExtents keeps events' PPQ, so their times move with the
       item's start. The scripts must place everything again afterwards.
     - A take accessor's time is from the item's start.
]]

local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
local P = {
  tracks = {}, selTracks = {}, now = 1000.0, tempo = 120, ext = {}, deferred = nil,
  loadSeconds = 0, articulations = {}, renders = {}, undo = {}, mb = {}, mbAnswer = 6,
  guid = 0, commands = {}, extents = 0,
}
local PPQ = 960
local function qps() return P.tempo / 60 end

local function readWav(path)
  local f = assert(io.open(path, "rb"))
  local b = f:read("a")
  f:close()
  local p, rate, ch, data = 13, 48000, 1, nil
  while p + 8 <= #b do
    local id, len = b:sub(p, p + 3), string.unpack("<I4", b, p + 4)
    if id == "fmt " then ch, rate = string.unpack("<I2I4", b, p + 10) elseif id == "data" then data = { at = p + 8, len = len } end
    p = p + 8 + len + (len % 2)
  end
  local x = {}
  for i = 0, data.len // (4 * ch) - 1 do x[i + 1] = string.unpack("<f", b, data.at + i * 4 * ch) end
  return x, rate
end

-- the effects named in an FXCHAIN block: lines like <VST "VSTi: Name (Maker)" ...
local function parseChain(block)
  local fx = {}
  for line in block:gmatch("[^\n]+") do
    local name = line:match('^%s*<[A-Z0-9]+%s+"([^"]*)"')
    if name and not line:match("^%s*<FXCHAIN") then
      fx[#fx + 1] = { name = name, instrument = name:match("^%w+i: ") ~= nil, enabled = true }
    end
  end
  return fx
end

local function chainOf(chunk)
  local s = chunk:find("<FXCHAIN", 1, true)
  if not s then return nil end
  local depth, out = 0, {}
  for line in (chunk:sub(s) .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = line
    local t = line:match("^%s*(.-)%s*$")
    if t:sub(1, 1) == "<" then depth = depth + 1 elseif t == ">" then depth = depth - 1 end
    if depth == 0 then break end
  end
  return table.concat(out, "\n")
end

function P.track(name, chain)
  local t = { name = name or "", items = {}, fx = {}, chain = chain, loadedAt = -math.huge }
  if chain then t.fx = parseChain(chain) end
  P.tracks[#P.tracks + 1] = t
  return t
end

function P.item(track, pos, len)
  local item = { track = track, pos = pos, len = len, selected = false }
  item.take = { item = item, midi = true, notes = {}, ccs = {} }
  track.items[#track.items + 1] = item
  return item
end

local function timeOf(take, ppq) return take.item.pos + ppq / PPQ / qps() end
local function ppqOf(take, t) return (t - take.item.pos) * qps() * PPQ end
function P.noteTime(take, n) return timeOf(take, n.sp), timeOf(take, n.ep) end

local function indexOf(tr) for i, t in ipairs(P.tracks) do if t == tr then return i end end end

local function render(item)
  local tr, take = item.track, item.take
  local inst
  for _, f in ipairs(tr.fx) do if f.instrument then inst = f; break end end
  if not inst then return end
  local notes, ccs = {}, {}
  for _, n in ipairs(take.notes) do
    notes[#notes + 1] = string.format('{"t":%.9f,"len":%.9f,"pitch":%d,"vel":%d,"chan":%d}', n.sp / PPQ / qps(), (n.ep - n.sp) / PPQ / qps(), n.pitch, n.vel, n.chan)
  end
  for _, c in ipairs(take.ccs) do
    if c.msg == 0xB0 then ccs[#ccs + 1] = string.format('{"t":%.9f,"cc":%d,"value":%d,"chan":%d}', c.ppq / PPQ / qps(), c.m2, c.m3, c.chan) end
  end
  local arts = {}
  for k, v in pairs(P.articulations) do
    arts[#arts + 1] = string.format('"%d":{"cc1Dynamics":%s,"extraDelayMs":%s}', k, v.cc1Dynamics and "true" or "false", v.extraDelayMs or 0)
  end
  local silent = (P.now - tr.loadedAt) < P.loadSeconds
  local json = string.format('{"notes":[%s],"ccs":[%s],"length":%.9f,"silent":%s,"articulations":{%s}}',
    table.concat(notes, ","), table.concat(ccs, ","), item.len, silent and "true" or "false", table.concat(arts, ","))
  P.renderCount = (P.renderCount or 0) + 1
  local base = P.resource .. "/render" .. P.renderCount
  local f = assert(io.open(base .. ".json", "w")); f:write(json); f:close()
  assert(os.execute(string.format('node "%srender_cli.js" "%s.json" "%s.wav"', HERE, base, base)), "render failed")
  os.remove(base .. ".json")
  P.renders[#P.renders + 1] = { file = base .. ".wav", silent = silent, effectsOn = (function()
    local on = {}
    for _, fx in ipairs(tr.fx) do on[#on + 1] = fx.enabled end
    return on
  end)() }
  local audio = { item = item, midi = false, src = { file = base .. ".wav" } }
  item.takes = item.takes or { take }
  item.takes[#item.takes + 1] = audio
  item.take = audio
end

local api = {
  -- tracks
  CountTracks = function(_) return #P.tracks end,
  GetTrack = function(_, i) return P.tracks[i + 1] end,
  InsertTrackAtIndex = function(i, _) table.insert(P.tracks, i + 1, { name = "", items = {}, fx = {}, loadedAt = -math.huge }) end,
  DeleteTrack = function(tr) local i = indexOf(tr); if i then table.remove(P.tracks, i); tr.deleted = true end end,
  GetSelectedTrack = function(_, i) return P.selTracks[i + 1] end,
  GetSetMediaTrackInfo_String = function(tr, parm, val, set)
    assert(parm == "P_NAME", "mock has only P_NAME")
    if set then tr.name = val end
    return true, tr.name
  end,
  -- boolean retval, string str
  GetTrackStateChunk = function(tr, _, _)
    return true, '<TRACK {' .. tostring(indexOf(tr)) .. '}\nNAME "' .. tr.name .. '"\nPEAKCOL 16576\n' .. (tr.chain and (tr.chain .. "\n") or "") .. ">"
  end,
  SetTrackStateChunk = function(tr, chunk, _)
    local block = chainOf(chunk)
    assert(chunk:match("^<TRACK") and chunk:match("\n>%s*$"), "a track chunk must stay a track chunk")
    tr.chain = block
    tr.fx = block and parseChain(block) or {}
    tr.loadedAt = P.now
    P.lastChunk = chunk
    return true
  end,
  TrackFX_GetInstrument = function(tr) for i, f in ipairs(tr.fx) do if f.instrument then return i - 1 end end return -1 end,
  TrackFX_GetCount = function(tr) return #tr.fx end,
  -- boolean retval, string buf
  TrackFX_GetFXName = function(tr, i, _) local f = tr.fx[i + 1]; return f ~= nil, f and f.name or "" end,
  TrackFX_SetEnabled = function(tr, i, on) tr.fx[i + 1].enabled = on end,

  -- items and takes
  GetProjectLength = function(_)
    local e = 0
    for _, t in ipairs(P.tracks) do for _, it in ipairs(t.items) do e = math.max(e, it.pos + it.len) end end
    return e
  end,
  CreateNewMIDIItemInProj = function(tr, s, e, _) return P.item(tr, s, e - s) end,
  DeleteTrackMediaItem = function(tr, item)
    for i, it in ipairs(tr.items) do if it == item then table.remove(tr.items, i); item.deleted = true; return true end end
    return false
  end,
  GetActiveTake = function(item) return item.take end,
  TakeIsMIDI = function(take) return take.midi end,
  SelectAllMediaItems = function(_, sel) for _, t in ipairs(P.tracks) do for _, it in ipairs(t.items) do it.selected = sel end end end,
  SetMediaItemSelected = function(item, sel) item.selected = sel end,
  CountSelectedMediaItems = function(_)
    local n = 0
    for _, t in ipairs(P.tracks) do for _, it in ipairs(t.items) do if it.selected then n = n + 1 end end end
    return n
  end,
  GetSelectedMediaItem = function(_, i)
    for _, t in ipairs(P.tracks) do for _, it in ipairs(t.items) do if it.selected then if i == 0 then return it end i = i - 1 end end end
  end,
  GetMediaItem_Track = function(item) return item.track end,
  GetMediaItemInfo_Value = function(item, parm)
    if parm == "D_POSITION" then return item.pos end
    if parm == "D_LENGTH" then return item.len end
    error("mock has no item parm " .. parm)
  end,
  Main_OnCommand = function(cmd, _)
    P.commands[#P.commands + 1] = cmd
    if cmd == 40209 then
      for _, t in ipairs(P.tracks) do for _, it in ipairs(t.items) do if it.selected and it.take.midi then render(it) end end end
    else
      error("mock has no command " .. cmd)
    end
  end,

  -- audio
  GetMediaItemTake_Source = function(take) return take.src end,
  GetMediaSourceSampleRate = function(_) return 48000 end,
  GetMediaSourceNumChannels = function(_) return 2 end,
  -- string filenamebuf
  GetMediaSourceFileName = function(src, _) return src.file end,
  CreateTakeAudioAccessor = function(take) P.accessors = (P.accessors or 0) + 1; return { take = take } end,
  DestroyAudioAccessor = function(_) P.accessors = P.accessors - 1 end,
  new_array = function(size)
    local a = { data = {}, size = size }
    a.table = function(offs, n) local out = {} for i = 1, n do out[i] = a.data[offs + i - 1] or 0 end return out end
    a.clear = function() a.data = {} end
    return a
  end,
  -- integer: 1 audio, 0 silence, -1 error
  GetAudioAccessorSamples = function(acc, sr, nch, t, n, buf)
    local src = acc.take.src
    if not src.data then src.data, src.rate = readWav(src.file) end
    assert(sr == src.rate, "asked for another sample rate")
    assert(n * nch <= buf.size, "buffer too small")
    local s0 = math.floor(t * sr + 0.5)
    for i = 0, n - 1 do
      local v = src.data[s0 + i + 1] or 0
      for c = 1, nch do buf.data[i * nch + c] = v end
    end
    return 1
  end,

  -- MIDI: PPQ from the item's start, 960 a quarter, one tempo
  MIDI_GetPPQPosFromProjTime = function(take, t) return ppqOf(take, t) end,
  MIDI_GetProjTimeFromPPQPos = function(take, ppq) return timeOf(take, ppq) end,
  -- boolean
  MIDI_InsertNote = function(take, sel, muted, sp, ep, chan, pitch, vel, _)
    take.notes[#take.notes + 1] = { sp = sp, ep = ep, chan = chan, pitch = pitch, vel = vel, sel = sel, muted = muted }
    return true
  end,
  MIDI_InsertCC = function(take, sel, muted, ppq, msg, chan, m2, m3)
    take.ccs[#take.ccs + 1] = { ppq = ppq, msg = msg, chan = chan, m2 = m2, m3 = m3 }
    return true
  end,
  MIDI_Sort = function(take)
    table.sort(take.notes, function(a, b) return a.sp < b.sp end)
    table.sort(take.ccs, function(a, b) return a.ppq < b.ppq end)
  end,
  -- boolean retval, integer notecnt, integer ccevtcnt, integer textsyxevtcnt
  MIDI_CountEvts = function(take) return true, #take.notes, #take.ccs, 0 end,
  -- boolean retval, boolean selected, boolean muted, number startppqpos, number endppqpos, integer chan, integer pitch, integer vel
  MIDI_GetNote = function(take, i)
    local n = take.notes[i + 1]
    if not n then return false end
    return true, n.sel or false, n.muted or false, n.sp, n.ep, n.chan, n.pitch, n.vel
  end,
  -- boolean retval, boolean selected, boolean muted, number ppqpos, integer chanmsg, integer chan, integer msg2, integer msg3
  MIDI_GetCC = function(take, i)
    local c = take.ccs[i + 1]
    if not c then return false end
    return true, false, false, c.ppq, c.msg, c.chan, c.m2, c.m3
  end,
  MIDI_SetNote = function(take, i, sel, muted, sp, ep, chan, pitch, vel, _)
    local n = assert(take.notes[i + 1], "no note " .. i)
    if sel ~= nil then n.sel = sel end
    if muted ~= nil then n.muted = muted end
    if sp then n.sp = sp end
    if ep then n.ep = ep end
    if chan then n.chan = chan end
    if pitch then n.pitch = pitch end
    if vel then n.vel = vel end
    return true
  end,
  MIDI_SetCC = function(take, i, _, _, ppq, msg, chan, m2, m3, _)
    local c = assert(take.ccs[i + 1], "no CC " .. i)
    if ppq then c.ppq = ppq end
    if msg then c.msg = msg end
    if chan then c.chan = chan end
    if m2 then c.m2 = m2 end
    if m3 then c.m3 = m3 end
    return true
  end,
  MIDI_SetItemExtents = function(item, startQN, endQN)
    P.extents = P.extents + 1
    item.pos = startQN / qps()
    item.len = endQN / qps() - item.pos
    return true
  end,
  TimeMap2_timeToQN = function(_, t) return t * qps() end,

  -- files, state, time, UI
  GetResourcePath = function() return P.resource end,
  RecursiveCreateDirectory = function(path, _) os.execute('mkdir -p "' .. path .. '"'); return 1 end,
  EnumerateFiles = function(path, i)
    local list = {}
    local h = io.popen('ls -1 "' .. path .. '" 2>/dev/null')
    for l in h:lines() do list[#list + 1] = l end
    h:close()
    return list[i + 1]
  end,
  genGuid = function(_) P.guid = P.guid + 1; return string.format("{00000000-0000-0000-0000-%012d}", P.guid) end,
  time_precise = function() return P.now end,
  defer = function(fn) P.deferred = fn end,
  get_action_context = function() return false, P.scriptPath, 0, 0, -1, -1, -1 end,
  ImGui_GetBuiltinPath = function() return HERE .. "imgui" end,
  MB = function(msg, title, kind) P.mb[#P.mb + 1] = msg; return kind == 4 and P.mbAnswer or 1 end,
  GetExtState = function(sec, key) return P.ext[sec .. "/" .. key] or "" end,
  SetExtState = function(sec, key, v, _) P.ext[sec .. "/" .. key] = v end,
  Undo_BeginBlock = function() P.undoDepth = (P.undoDepth or 0) + 1 end,
  Undo_EndBlock = function(desc, _) P.undoDepth = P.undoDepth - 1; P.undo[#P.undo + 1] = desc end,
  PreventUIRefresh = function(n) P.refresh = (P.refresh or 0) + n end,
  UpdateArrange = function() end,
}

-- Extension functions a script may only test for: nil (not installed) unless a test sets P.sws.
local OPTIONAL = { CF_ShellExecute = function(path) P.shell = path end }
setmetatable(api, { __index = function(_, k)
  if OPTIONAL[k] ~= nil then return P.sws and OPTIONAL[k] or nil end
  error("mock REAPER has no " .. tostring(k), 2)
end })
P.api = api

--- Run deferred frames until `done()` or `max` frames, a second of REAPER time each.
function P.frames(max, done)
  for i = 1, max do
    local fn = P.deferred
    if not fn then return i end
    P.deferred = nil
    fn()
    P.now = P.now + 1
    if done and done() then return i end
  end
  return max
end

return P
