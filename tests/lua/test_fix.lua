-- Choosing each note's articulation, and what moves with it. lua5.4 tests/lua/test_fix.lua
local HERE = arg[0]:match("^(.*[/\\])") or "./"
local ROOT = HERE .. "../../reaper/"
local J = dofile(ROOT .. "npvf_json.lua")
local F = dofile(ROOT .. "npvf_fix.lua")
local M = dofile(ROOT .. "npvf_measure.lua")

local passed, failed = 0, 0
local function test(name, fn)
  local okk, err = pcall(fn)
  if okk then passed = passed + 1; print("  ok   " .. name) else failed = failed + 1; print("  FAIL " .. name .. "\n       " .. tostring(err)) end
end
local function ok(c, m) if not c then error(m or "assertion failed", 2) end end
local function near(a, b, tol, m) ok(math.abs(a - b) <= tol, (m or "") .. " expected " .. b .. " ± " .. tol .. ", got " .. tostring(a)) end

-- a profile: the same delay on every key, louder on key 64
local function profile(name, delay, sw, extra)
  local entries = {}
  for p = 48, 84 do
    for _, v in ipairs({ 40, 120 }) do
      entries[#entries + 1] = { pitch = p, vel = v, delayMs = delay + (v == 40 and 20 or 0), deviationDb = p == 64 and 4 or 0, loudDb = -20 }
    end
  end
  local prof = { kind = "note-position-volume-fixer/profile", name = name, entries = entries, switch = sw, dynamics = "velocity", dbPerVelocity = 0.25 }
  for k, v in pairs(extra or {}) do prof[k] = v end
  return prof
end
local stac = profile("Staccato", 50, { type = "keyswitch", value = 24 })
local leg = profile("Legato", 120, { type = "keyswitch", value = 25 })
local id = 0
local function note(t, pitch, vel, len, chan) id = id + 1; return { id = id, t = t, tEnd = t + (len or 0.25), pitch = pitch, vel = vel or 120, chan = chan or 0 } end

print("Articulations")

test("each note takes the profile its keyswitch chose", function()
  local ks1, a, ks2, b = note(1, 24, 100, 0.1), note(2, 60), note(2.9, 25, 100, 0.05), note(3, 62)
  local plan = F.plan({ ks1, a, ks2, b }, {}, { stac, leg }, nil, {})
  ok(plan.changes[a.id].profile == "Staccato" and plan.changes[b.id].profile == "Legato")
  near(plan.changes[a.id].shiftMs, -50, 1e-9)
  near(plan.changes[b.id].shiftMs, -120, 1e-9)
  ok(not plan.changes[ks1.id], "keyswitches aren't fixed")
  ok(not plan.moves[ks1.id], "a keyswitch long before stays")
  near(plan.moves[ks2.id].t, 2.9 - 0.12, 1e-9, "a keyswitch just before moves with its note")
end)

test("before any switch, the fallback profile; without one, left alone", function()
  local a = note(1, 60)
  local plan = F.plan({ a }, {}, { stac, leg }, nil, {})
  ok(plan.counts.noProfile == 1 and plan.changes[a.id].newT == 1, "left alone")
  ok(plan.warnings[1]:find("no profile"), plan.warnings[1])
  plan = F.plan({ a }, {}, { stac, leg }, leg, {})
  near(plan.changes[a.id].shiftMs, -120, 1e-9, "fallback")
end)

test("CC switches (Spitfire's UACC on CC32), program changes and channels", function()
  local uacc1 = profile("Long", 100, { type = "cc", cc = 32, value = 1 })
  local uacc42 = profile("Spiccato", 40, { type = "cc", cc = 32, value = 42 })
  local a, b = note(2, 60), note(3, 60)
  local ev = { { id = 101, t = 1, kind = "cc", chan = 0, cc = 32, value = 42 }, { id = 102, t = 3, kind = "cc", chan = 0, cc = 32, value = 1 } }
  local plan = F.plan({ a, b }, ev, { uacc1, uacc42 }, nil, {})
  ok(plan.changes[a.id].profile == "Spiccato" and plan.changes[b.id].profile == "Long", "by CC value")
  near(plan.moves[102].t, 3 - 0.1, 1e-9, "a CC exactly on the note moves with it")
  ok(not plan.moves[101], "a CC before it stays")
  local pg = profile("Pizz", 30, { type = "program", value = 5 })
  local c = note(5, 60)
  plan = F.plan({ c }, { { id = 103, t = 4.95, kind = "program", chan = 0, value = 5 } }, { pg }, nil, {})
  ok(plan.changes[c.id].profile == "Pizz", "program")
  near(plan.moves[103].t, 4.95 - 0.03, 1e-9, "a program change just before moves with it")
  local ch2 = profile("Trem", 80, { type = "channel", value = 2 })
  local d, e = note(6, 60, 120, 0.25, 1), note(7, 60, 120, 0.25, 0)
  plan = F.plan({ d, e }, {}, { ch2 }, stac, {})
  ok(plan.changes[d.id].profile == "Trem" and plan.changes[e.id].profile == "Staccato", "channel 2, else fallback")
end)

print("Changes")

test("the loud key gets a lower velocity, and that velocity's delay", function()
  local a = note(1, 64, 120)
  local plan = F.plan({ a }, {}, { stac }, stac, {})
  local c = plan.changes[a.id]
  ok(c.newVel == 104, "4 dB at 0.25 dB a step: " .. c.newVel)
  near(c.shiftMs, -(50 + 20 * (120 - 104) / 80), 1e-9, "delay at velocity 104")
end)

test("CC1 profiles: looked up by CC1, fixed with CC11, not where notes overlap", function()
  local long = profile("Long", 100, nil, { dynamics = "cc1" })
  local a, b, c = note(1, 64, 90, 0.5), note(3, 64, 90, 2), note(3.5, 67, 90, 1)
  a.cc1, b.cc1, c.cc1 = 40, 40, 40
  local plan = F.plan({ a, b, c }, {}, { long }, nil, {})
  near(plan.changes[a.id].shiftMs, -120, 1e-9, "CC1 40's delay")
  ok(plan.changes[a.id].newVel == 90, "velocity untouched")
  ok(plan.changes[a.id].cc11 == 87, "CC11 down 4 dB: " .. tostring(plan.changes[a.id].cc11))
  ok(plan.changes[b.id].cc11 == nil and plan.changes[c.id].cc11 == nil, "overlapping notes get none")
end)

test("a note moved under the same key's previous note ends it there", function()
  local a, b = note(1, 60, 120, 1), note(2, 60, 40, 0.5)
  local plan = F.plan({ a, b }, {}, { stac }, stac, { volume = "off" })
  ok(plan.changes[a.id].newTEnd <= plan.changes[b.id].newT + 1e-9, "trimmed")
end)

test("strength, where to land, and timing off", function()
  local a = note(1, 60)
  near(F.plan({ a }, {}, { stac }, stac, { strength = 0.5 }).changes[a.id].shiftMs, -25, 1e-9)
  near(F.plan({ a }, {}, { stac }, stac, { targetMs = 10 }).changes[a.id].shiftMs, -40, 1e-9)
  ok(F.plan({ a }, {}, { stac }, stac, { timing = false }).changes[a.id].shiftMs == 0)
  ok(F.plan({ a }, {}, { stac }, stac, {}).minT < 1)
end)

test("between measured keys, delays are interpolated and no key's fault is borrowed", function()
  local p = { entries = { { pitch = 60, vel = 100, delayMs = 40, deviationDb = 3 }, { pitch = 64, vel = 100, delayMs = 80, deviationDb = -2 } } }
  local at = F.profileAt(p, 62, 100)
  near(at.delayMs, 60, 1e-9)
  ok(at.deviationDb == 0 and not at.outside)
  ok(F.profileAt(p, 70, 100).outside)
end)

print("Files")

test("JSON round trip, with names that need escaping", function()
  local t = { name = 'Violins "1" \\ Spiccato', n = 0.1 + 0.2, list = { 1, 2, 3 }, empty = J.object({}), deep = { { a = true } } }
  local back = assert(J.decode(J.encode(t, " ")))
  ok(back.name == t.name and back.list[3] == 3 and back.deep[1].a == true, "values")
  near(back.n, 0.3, 1e-9)
  ok(J.encode(J.object({})) == "{}" and J.encode({}) == "[]")
  local bad, err = J.decode("{\"a\": }")
  ok(bad == nil and err:find("JSON"), "a broken file says so")
  ok(J.decode('"caf\\u00e9"') == "café", "unicode")
end)

test("how long a test takes", function()
  near(M.testSeconds({ low = 24, high = 96, levels = { 30, 60, 90, 120 }, takes = 2 }), 2 + 73 * 8 + 1.5, 1e-9)
end)

print("\n" .. passed .. " passed, " .. failed .. " failed")
os.exit(failed == 0 and 0 or 1)
