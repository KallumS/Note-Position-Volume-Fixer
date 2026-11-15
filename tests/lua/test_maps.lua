--[[ Reading articulation maps. lua5.4 tests/lua/test_maps.lua [folder]

     The fixtures in tests/fixtures are written for these tests in each
     format's real layout (the shape of Steinberg's, Apple's and Reaticulate's
     own files), since maps made by others can't go in a public repository.
     Give a folder of real maps (.expressionmap, .plist, .reabank) as the
     argument and every one of them is read as well. ]]

local HERE = arg[0]:match("^(.*[/\\])") or "./"
local Maps = dofile(HERE .. "../../reaper/npvf_maps.lua")
local FIX = HERE .. "../fixtures/"

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1; print("  ok   " .. name) else failed = failed + 1; print("  FAIL " .. name .. "\n       " .. tostring(err)) end
end
local function ok(c, m) if not c then error(m or "assertion failed", 2) end end
local function read(p) local f = assert(io.open(p, "rb")); local s = f:read("a"); f:close(); return s end
local function same(out, want, what)
  ok(#out == #want, what .. ": " .. #out .. " outputs, wanted " .. #want)
  for i, w in ipairs(want) do
    for k, v in pairs(w) do ok(out[i][k] == v, string.format("%s output %d: %s is %s, wanted %s", what, i, k, tostring(out[i][k]), tostring(v))) end
  end
end

print("Cubase expression maps (Art Conductor for Cubase)")

test("names, keyswitches with their velocities, CCs, program changes and channels", function()
  local m = assert(Maps.parse(read(FIX .. "Test Strings.expressionmap"), "Test Strings.expressionmap"))
  ok(m.format == "cubase" and #m.banks == 1 and m.banks[1].name == "Test Strings & Co", "the map's name, unescaped")
  local a = m.banks[1].articulations
  ok(#a == 3, "three articulations; the empty slot is left out: " .. #a)
  ok(a[1].name == "Staccato" and a[1].dynamics == 1 and a[1].include, "staccato, by velocity")
  same(a[1].send, { { kind = "note", pitch = 12, vel = 127 } }, "staccato")
  ok(a[2].name == "Long + Mute" and a[2].dynamics == 2, "long, on CC1")
  same(a[2].send, { { kind = "note", pitch = 13 }, { kind = "note", pitch = 50, vel = 100 }, { kind = "cc", cc = 20, value = 64 } }, "long")
  ok(a[2].channel == nil, "the note changer's channel isn't the output channel")
  same(a[3].send, { { kind = "program", value = 7 } }, "pizzicato")
  ok(a[3].channel == 3, "output channel 2 (from 0) is MIDI channel 3: " .. tostring(a[3].channel))
  ok(Maps.describe(a[2]) == "C#-1 + D2 + CC20 = 64", Maps.describe(a[2]))
end)

print("Logic articulation sets (Art Conductor for Logic)")

test("one output or several; velocity kept for UACC KS; no output not ticked", function()
  local m = assert(Maps.parse(read(FIX .. "Test Strings.plist"), "Test Strings.plist"))
  local a = m.banks[1].articulations
  ok(m.format == "logic" and m.banks[1].name == "Test Strings" and #a == 3)
  same(a[1].send, { { kind = "note", pitch = 0, vel = 1 } }, "UACC KS long")
  ok(a[2].name == "Spiccato & Short" and a[2].dynamics == 1)
  same(a[2].send, { { kind = "cc", cc = 32, value = 42 }, { kind = "note", pitch = 24, vel = 100 } }, "spiccato")
  ok(#a[3].send == 0 and a[3].include == false, "nothing to send: listed but not ticked")
end)

print("Reaticulate banks")

test("every bank, program numbers, outputs and channels, group 1 ticked", function()
  local m = assert(Maps.parse(read(FIX .. "Test Strings.reabank"), "Test Strings.reabank"))
  ok(m.format == "reaticulate" and #m.banks == 2, "two banks")
  local v = m.banks[1]
  ok(v.name == "Violins" and v.group == "Test Library/Strings", "named by n=, grouped by g=: " .. v.name)
  ok(#v.articulations == 4, "four (the hidden one left out): " .. #v.articulations)
  local leg, stac, pizz, sord = table.unpack(v.articulations)
  ok(leg.program == 20 and leg.dynamics == 2 and stac.program == 40 and stac.dynamics == 1, "programs; c=long/short")
  same(leg.send, { { kind = "note", pitch = 12, vel = 127 }, { kind = "note", pitch = 50, vel = 100 } }, "legato")
  same(pizz.send, { { kind = "cc", cc = 32, value = 56 } }, "pizzicato")
  ok(pizz.channel == 3, "@3")
  ok(sord.include == false and sord.group == 2, "group 2 changes another articulation: not measured alone")
  local c = m.banks[2]
  same(c.articulations[1].send, { { kind = "program", value = 5 } }, "cello sustain")
  same(c.articulations[2].send, { { kind = "note", pitch = 14, vel = 90 }, { kind = "cc", cc = 1, value = 127 } }, "cello spiccato")
  ok(c.articulations[2].channel == 2)
  ok(Maps.bestBank(m, "Cellos") == 2 and Maps.bestBank(m, "Test Violins 1") == 1, "the bank named like the instrument")
end)

print("Anything else")

test("a file that is none of them says what to open", function()
  local m, err = Maps.parse("hello", "notes.txt")
  ok(m == nil and err:find("expressionmap") and err:find("reabank"), err)
  local m2, err2 = Maps.parse("<plist><dict><key>Name</key><string>x</string></dict></plist>", "x.plist")
  ok(m2 == nil and err2:find("Logic"), tostring(err2))
end)

test("dynamics are guessed from the main articulation's name", function()
  ok(Maps.guessDynamics("Spic/Stac (XF A)+A-R-T Agile-Soft-Legato") == 1, "spiccato with a legato option is short")
  ok(Maps.guessDynamics("Sustain Con Sordino") == 2 and Maps.guessDynamics("Pizzicato") == 1 and Maps.guessDynamics("Tremolo") == 2)
  ok(Maps.guessDynamics("Mystery", "long") == 2, "Reaticulate's colour says long")
end)

local folder = arg[1]
if folder then
  print("Real maps in " .. folder)
  test("every map in the folder is read", function()
    local files, arts, bad = 0, 0, {}
    local h = io.popen('find "' .. folder .. '" -type f \\( -name "*.expressionmap" -o -name "*.plist" -o -name "*.reabank" \\)')
    for path in h:lines() do
      files = files + 1
      local m, err = Maps.parse(read(path), path)
      if m then for _, b in ipairs(m.banks) do arts = arts + #b.articulations end
      elseif not read(path):find("\n%s*[Bb]ank%s") and path:match("%.reabank$") then -- a bank file with no banks, such as a header
      else bad[#bad + 1] = path .. ": " .. tostring(err) end
    end
    h:close()
    print("       " .. files .. " files, " .. arts .. " articulations")
    ok(#bad == 0, table.concat(bad, "\n       "))
  end)
end

print("\n" .. passed .. " passed, " .. failed .. " failed")
os.exit(failed == 0 and 0 or 1)
