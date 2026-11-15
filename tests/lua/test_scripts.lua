--[[ Both REAPER windows, end to end, in the mock REAPER and ReaImGui.

     Measure Libraries: an instrument is added from a track, two
     articulations are listed (a staccato chosen by keyswitch C-1, a long
     chosen by C#-1 with dynamics on CC1 and 40 ms later), and Measure All
     plays them on a new track through the made-up library - the first
     render comes while the "samples are still loading", so it has to wait
     and try again. Then Fix Selected Items fixes a part that switches
     between them.

       lua5.4 tests/lua/test_scripts.lua      (needs node for the renders)
]]

local HERE = arg[0]:match("^(.*[/\\])") or "./"
local REPO = HERE .. "../../"
local P = dofile(HERE .. "reaper_mock.lua")
_G.reaper = P.api
local J = dofile(REPO .. "reaper/npvf_json.lua")
local F = dofile(REPO .. "reaper/npvf_fix.lua")

local tmp = os.tmpname(); os.remove(tmp); os.execute('mkdir -p "' .. tmp .. '"')
P.resource = tmp

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1; print("  ok   " .. name) else failed = failed + 1; print("  FAIL " .. name .. "\n       " .. tostring(err)) end
end
local function ok(c, m) if not c then error(m or "assertion failed", 2) end end
local function near(a, b, tol, m) ok(math.abs(a - b) <= tol, (m or "") .. " expected " .. b .. " ± " .. tol .. ", got " .. tostring(a)) end
local function exists(p) local f = io.open(p, "rb"); if f then f:close() end return f ~= nil end
local function texts(G) local t = {} for _, r in ipairs(G.frame) do if r.kind == "text" then t[#t + 1] = r.label end end return table.concat(t, "\n") end

local CHAIN = table.concat({
  "<FXCHAIN", "SHOW 0", "LASTSEL 0", "DOCKED 0", "BYPASS 0 0 0",
  '<VST "VSTi: Fake Strings (Test)" fake.vst3 0 "" 1234<56> ""', "  ZmFrZXN0YXRl", "  AAAA", ">",
  "FXID {11111111-2222-3333-4444-555555555555}", "WAK 0 0", "BYPASS 0 0 0",
  '<VST "VST: ReaVerbate (Cockos)" reaverbate.dll 0 "" 1919250531<56> ""', "  cmVhdmVyYg==", ">",
  "FXID {AAAAAAAA-2222-3333-4444-555555555555}", "WAK 0 0", ">",
}, "\n")

local src = P.track("Fake Strings", CHAIN)
P.selTracks = { src }
P.articulations = { [13] = { cc1Dynamics = true, extraDelayMs = 40 } }
P.loadSeconds = 4

-- contrast, after Apple: text 7:1 on what it sits on
local function lum(c)
  local function ch(v) v = v / 255; return v <= 0.03928 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4 end
  return 0.2126 * ch((c >> 24) & 255) + 0.7152 * ch((c >> 16) & 255) + 0.0722 * ch((c >> 8) & 255)
end
local function contrast(a, b) local x, y = lum(a), lum(b); if x < y then x, y = y, x end return (x + 0.05) / (y + 0.05) end
local function checkLook(G, where)
  for _, r in ipairs(G.frame) do
    if r.kind == "button" then
      ok(r.text == 0x14171CFF, where .. ": button '" .. r.label .. "' has dark ink")
      ok(r.fill == 0xA9AFBAFF or r.fill == 0xFFF200FF, where .. ": button '" .. r.label .. "' is grey or yellow")
    elseif r.kind == "text" or r.kind == "heading" then
      ok(contrast(r.text, r.bg) >= 7, string.format("%s: '%s' is %.1f:1", where, r.label, contrast(r.text, r.bg)))
    end
  end
end

print("Measure Libraries")
P.scriptPath = REPO .. "reaper/Note Fixer - Measure Libraries.lua"
dofile(P.scriptPath)
local G = IMGUI

test("the window opens in the house colours", function()
  P.frames(1)
  ok(G.title == "Note Fixer - Measure Libraries", G.title)
  ok(G.flags == 1, "the keyboard can drive it")
  checkLook(G, "first frame")
end)

test("an instrument is captured from the selected track", function()
  G.click("Add Instrument From Selected Track"); P.frames(1); P.frames(1)
  ok(texts(G):find("Added Fake Strings"), texts(G))
  local saved = J.decode(io.open(tmp .. "/Data/Note Fixer/Instruments.json"):read("a"))
  ok(#saved == 1 and saved[1].name == "Fake Strings" and saved[1].plugin == "Fake Strings (Test)", "kept on disk")
  ok(saved[1].chain:find("ReaVerbate", 1, true) and saved[1].chain:match("^<FXCHAIN") and saved[1].chain:match(">$"), "the whole chain, nested blocks and all")
end)

test("a track with no instrument says so", function()
  local empty = P.track("Bus")
  P.selTracks = { empty }
  G.click("Add Instrument From Selected Track"); P.frames(1); P.frames(1)
  ok(texts(G):find("no instrument"), texts(G))
  P.selTracks = { src }
  table.remove(P.tracks)
end)

test("articulations and the test are set up from the window", function()
  G.click("Add Articulation"); P.frames(1)
  G.click("Add Articulation"); P.frames(1)
  G.set("arts/1/##n", "Staccato"); G.set("arts/1/##v", "C-1")
  G.set("arts/2/##n", "Long"); G.set("arts/2/##v", "C#-1"); G.set("arts/2/##d", 2)
  G.set("Lowest key", "C3"); G.set("Highest key", "B3"); G.set("Levels", "50, 110"); G.set("Takes", 1)
  G.set("Seconds to load samples", 2)
  P.frames(1); P.frames(1)
  ok(texts(G):find("Each articulation plays 24 notes"), texts(G))
  ok(texts(G):find("2 to measure"), "two articulations to measure")
  checkLook(G, "set up")
end)

test("Measure All plays each articulation on a new track and saves profiles", function()
  G.click("Measure All")
  local sawStop, frames = false, 0
  P.frames(600, function()
    frames = frames + 1
    for _, r in ipairs(G.frame) do if r.kind == "button" and r.label == "Stop" then sawStop = true end end
    return texts(G):find("^Done") or texts(G):find("\nDone")
  end)
  local all = texts(G)
  ok(all:find("Done. 2 profiles saved"), all)
  ok(sawStop, "Stop is offered while it runs")
  ok(all:find("Waiting longer and trying again"), "the first render came too early and was tried again")
  ok(all:find("Fake Strings %- Staccato: 24 of 24 notes"), all)
  ok(all:find("Keys 1.5 dB or more off: E3"), "names the loud key")
  checkLook(G, "after the run")
end)

local folder = tmp .. "/Data/Note Fixer/Profiles/"
local stac = J.decode(io.open(folder .. "Fake Strings - Staccato.json"):read("a") or "")
local long = J.decode(io.open(folder .. "Fake Strings - Long.json"):read("a") or "")

test("the profiles say what they are", function()
  ok(stac.instrument == "Fake Strings" and stac.articulation == "Staccato" and stac.plugin == "Fake Strings (Test)")
  ok(stac.switch.type == "keyswitch" and stac.switch.value == 12 and stac.dynamics == "velocity", "staccato by C-1, velocity")
  ok(long.switch.value == 13 and long.dynamics == "cc1" and long.dbPerVelocity == nil, "long by C#-1, CC1")
  ok(#stac.entries == 24 and #long.entries == 24)
end)

test("each articulation's own delays: the long one 40 ms later, the loud key found in both", function()
  for i, e in ipairs(stac.entries) do
    local l = long.entries[i]
    ok(l.pitch == e.pitch and l.vel == e.vel)
    near(l.delayMs - e.delayMs, 40, 2, "key " .. e.pitch .. " level " .. e.vel)
    if e.pitch == 64 then near(e.deviationDb, 5, 0.6, "staccato E3"); near(l.deviationDb, 5, 0.6, "long E3") end
  end
end)

test("REAPER is left as it was", function()
  ok(#P.tracks == 1 and P.tracks[1] == src, "the test tracks are gone")
  ok(#src.items == 0, "nothing added to the instrument's own track")
  ok(P.accessors == 0, "every audio accessor destroyed")
  for _, r in ipairs(P.renders) do ok(not exists(r.file), "render deleted: " .. r.file) end
  ok(#P.renders == 3, "three renders: one too early, then one per articulation")
  for _, r in ipairs(P.renders) do ok(r.effectsOn[1] == true and r.effectsOn[2] == false, "reverb off, instrument on") end
  ok(P.lastChunk and not P.lastChunk:find("11111111-2222", 1, true), "the copy's effects have new IDs")
  ok(P.lastChunk:find("ZmFrZXN0YXRl", 1, true), "the patch's state went to the new track")
end)

test("measured ones are skipped next time", function()
  P.frames(3)
  ok(texts(G):find("0 to measure"), texts(G))
  G.click("Measure All"); P.frames(2)
  ok(texts(G):find("Nothing to measure"), texts(G))
end)

test("a Cubase expression map brings in the articulations, outputs and all", function()
  P.fileToOpen = REPO .. "tests/fixtures/Test Strings.expressionmap"
  local asked = #P.mb
  G.click("Import Articulations…"); P.frames(1); P.frames(1)
  ok(#P.mb == asked + 1 and P.mb[#P.mb]:find("Replace Fake Strings's 2 articulations"), "asks before replacing: " .. tostring(P.mb[#P.mb]))
  ok(texts(G):find("Imported 3 articulations from Test Strings.expressionmap; 3 ticked"), texts(G))
  ok(texts(G):find("C#-1 + D2 + CC20 = 64", 1, true), "the long one's outputs in words")
  ok(texts(G):find("Program 7, channel 3", 1, true), "pizzicato's program and channel")
  checkLook(G, "after importing")
end)

test("measuring from the map: in-range keyswitches are never played, and more is saved", function()
  G.set("Skip ones already measured", false)
  G.set("Library", "Test Library")
  G.set("Lowest key", "C2"); G.set("Highest key", "B2") -- D2 is the long articulation's second keyswitch
  P.frames(1); P.frames(1)
  G.click("Measure All")
  P.frames(800, function() return texts(G):find("\nDone") or texts(G):find("^Done") end)
  ok(texts(G):find("Done. 3 profiles saved"), texts(G))
  ok(texts(G):find("Plays C2 to B2", 1, true), "the range heard")
  local long = J.decode(io.open(folder .. "Test Library - Fake Strings - Long + Mute.json"):read("a"))
  ok(long.version == 2 and long.library == "Test Library" and long.name == "Test Library - Fake Strings - Long + Mute", "named with its library")
  ok(#long.send == 3 and long.send[2].pitch == 50 and long.dynamics == "cc1" and long.source:find("Cubase expression map"), "outputs and source kept")
  for _, e in ipairs(long.entries) do ok(e.pitch ~= 50, "D2, a keyswitch, was never played as a test note") end
  local ks = {} for _, e in ipairs(long.entries) do ks[#ks + 1] = e.pitch .. "/" .. e.vel end
  ok(#long.entries == 22 and long.test.keyswitchKeysSkipped[3] == 50, "the other 11 keys at both levels: " .. table.concat(ks, " ") .. ", levels " .. J.encode(long.test.levels))
  ok(long.entries[1].startMs < long.entries[1].attackMs and #long.entries[1].takesMs == 1, "start, attack and each take")
  local pizz = J.decode(io.open(folder .. "Test Library - Fake Strings - Pizzicato.json"):read("a"))
  ok(pizz.channel == 3 and pizz.send[1].kind == "program", "pizzicato's channel and program")
  local stac = J.decode(io.open(folder .. "Test Library - Fake Strings - Staccato.json"):read("a"))
  ok(math.abs((long.summary.medianMs - stac.summary.medianMs) - 40) < 3, "the long one is 40 ms later")
  local index = J.decode(io.open(tmp .. "/Data/Note Fixer/Library.json"):read("a"))
  ok(index.kind == "note-position-volume-fixer/library" and #index.profiles == 5, "Library.json lists every profile: " .. #index.profiles)
  local found
  for _, e in ipairs(index.profiles) do if e.file == "Profiles/Test Library - Fake Strings - Long + Mute.json" then found = e end end
  ok(found and found.medianMs == long.summary.medianMs and found.range.low == 48, "with the headline numbers")
end)

test("a Reaticulate file with several instruments asks which one", function()
  P.fileToOpen = REPO .. "tests/fixtures/Test Strings.reabank"
  G.click("Import Articulations…"); P.frames(1); P.frames(1)
  ok(texts(G):find("This file has 2 instruments"), texts(G))
  G.set("arts/##bank", nil)
  G.set("##bank", 2); P.frames(1)
  G.click("Import This One"); P.frames(1); P.frames(1)
  ok(texts(G):find("Imported 2 articulations"), texts(G))
  ok(texts(G):find("Program 5", 1, true) and texts(G):find("Reaticulate 2", 1, true), "the cellos' outputs and program numbers")
  local saved = J.decode(io.open(tmp .. "/Data/Note Fixer/Instruments.json"):read("a"))
  ok(saved[1].articulations[2].program == 2 and saved[1].articulations[2].channel == 2, "kept on disk")
end)

print("Fix Selected Items")

-- a part: staccato (C-1) at the item's very start, then long notes (C#-1) on CC1
local item = P.item(src, 10, 8)
local tk = item.take
local function at(t) return (t - 10) * 2 * 960 end
local function addNote(t, len, pitch, vel) P.api.MIDI_InsertNote(tk, false, false, at(t), at(t + len), 0, pitch, vel, true) end
addNote(10.0, 0.05, 12, 100)
addNote(10.02, 0.2, 64, 110)
addNote(10.5, 0.2, 62, 70)
addNote(12.9, 0.05, 13, 100)
P.api.MIDI_InsertCC(tk, false, false, at(12.95), 0xB0, 0, 1, 50)
addNote(13.0, 0.9, 60, 90)
addNote(14.0, 0.9, 64, 90)
P.api.MIDI_Sort(tk)
item.selected = true
local before = {}
for _, n in ipairs(tk.notes) do before[#before + 1] = { pitch = n.pitch, vel = n.vel, t = select(1, P.noteTime(tk, n)) } end

P.scriptPath = REPO .. "reaper/Note Fixer - Fix Selected Items.lua"
P.deferred = nil
dofile(P.scriptPath)
local G2 = IMGUI

test("the track's instrument is chosen by its name", function()
  P.frames(1)
  ok(G2.title == "Note Fixer - Fix Selected Items")
  local combo
  for _, r in ipairs(G2.frame) do if r.kind == "combo" and r.path == "tracks/1/##inst" then combo = r end end
  ok(combo and combo.preview == "Fake Strings", "chose " .. tostring(combo and combo.preview))
  checkLook(G2, "fix window")
end)

test("Fix Selected Items moves each note by its own articulation's delay", function()
  G2.click("Fix Selected Items"); P.frames(1); P.frames(1)
  ok(texts(G2):find("notes moved"), texts(G2))
  ok(P.undo[#P.undo] == "Note Fixer: fix notes from profiles" and P.undoDepth == 0, "one undo point")
  local after = {}
  for _, n in ipairs(tk.notes) do after[#after + 1] = { pitch = n.pitch, vel = n.vel, t = select(1, P.noteTime(tk, n)) } end
  local function find(list, pitch, near0) for _, x in ipairs(list) do if x.pitch == pitch and math.abs(x.t - near0) < 0.3 then return x end end end
  -- staccato E3: louder key, so a lower velocity, and that velocity's delay
  local e3b, e3 = find(before, 64, 10.02), find(after, 64, 10.0)
  ok(e3.vel < e3b.vel - 10, "E3 velocity " .. e3b.vel .. " -> " .. e3.vel)
  near(e3.t, 10.02 - F.profileAt(stac, 64, e3.vel).delayMs / 1000, 0.001, "E3 lands on its beat")
  -- long C3: CC1 50's delay, velocity untouched, CC11 written
  local c3 = find(after, 60, 13.0)
  near(c3.t, 13.0 - F.profileAt(long, 60, 50).delayMs / 1000, 0.001, "C3 by the long profile at CC1 50")
  ok(c3.vel == 90, "long notes keep their velocity")
  local cc11 = 0
  for _, c in ipairs(tk.ccs) do if c.m2 == 11 then cc11 = cc11 + 1 end end
  ok(cc11 == 2, "a CC11 before each long note: " .. cc11)
end)

test("the item grows to the left to hold a note moved before it, and nothing else shifts", function()
  ok(P.extents == 1, "extended once")
  ok(item.pos < 10 - 0.05, "item now starts at " .. item.pos)
  local cc1
  for _, c in ipairs(tk.ccs) do if c.m2 == 1 then cc1 = c end end
  near(10 + 0, item.pos + (at(10) / 1920 + 0) + (10 - item.pos), 1e-9)
  local t = item.pos + cc1.ppq / 1920
  near(t, 12.95, 1e-6, "the CC1 stays where it was")
  local ks2
  for _, n in ipairs(tk.notes) do if n.pitch == 13 then ks2 = n end end
  ok(item.pos + ks2.sp / 1920 < 12.9 - 0.05, "the C#-1 keyswitch moved ahead of its note")
  local ks1
  for _, n in ipairs(tk.notes) do if n.pitch == 12 then ks1 = n end end
  ok(item.pos + ks1.sp / 1920 < 10.0 - 0.05, "and so did C-1")
end)

test("a track with no instrument chosen is left alone and named", function()
  local other = P.track("Brass")
  local it = P.item(other, 20, 2)
  P.api.MIDI_InsertNote(it.take, false, false, 0, 480, 0, 60, 100, true)
  item.selected, it.selected = false, true
  P.frames(2)
  G2.click("Fix Selected Items"); P.frames(1); P.frames(1)
  ok(texts(G2):find("Left alone, with no instrument chosen: Brass"), texts(G2))
  ok(it.take.notes[1].sp == 0, "untouched")
end)

os.execute('rm -rf "' .. tmp .. '"')
print("\n" .. passed .. " passed, " .. failed .. " failed")
os.exit(failed == 0 and 0 or 1)
