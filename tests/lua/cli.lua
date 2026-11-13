--[[ The Lua modules from the command line, for tests/lua_parity.js:

       lua5.4 tests/lua/cli.lua layout  <options.json>          -> the test part
       lua5.4 tests/lua/cli.lua measure <render.wav> <options.json> -> a profile
       lua5.4 tests/lua/cli.lua fix     <input.json>            -> the plan

     Reads float or 16/24-bit PCM WAVs (the tests write float). ]]

local HERE = arg[0]:match("^(.*[/\\])") or "./"
local ROOT = HERE .. "../../reaper/"
local J = dofile(ROOT .. "npvf_json.lua")
local M = dofile(ROOT .. "npvf_measure.lua")
local F = dofile(ROOT .. "npvf_fix.lua")

local function slurp(p) local f = assert(io.open(p, "rb")); local s = f:read("a"); f:close(); return s end

local function readWav(path)
  local b = slurp(path)
  assert(b:sub(1, 4) == "RIFF" and b:sub(9, 12) == "WAVE", "not a WAV")
  local p, fmt, data = 13, nil, nil
  while p + 8 <= #b do
    local id, len = b:sub(p, p + 3), string.unpack("<I4", b, p + 4)
    if id == "fmt " then
      local tag, ch, rate = string.unpack("<I2I2I4", b, p + 8)
      local bits = string.unpack("<I2", b, p + 22)
      fmt = { tag = tag, ch = ch, rate = rate, bits = bits }
    elseif id == "data" then data = { at = p + 8, len = len } end
    p = p + 8 + len + (len % 2)
  end
  local frames = data.len // (fmt.ch * fmt.bits // 8)
  local x, step = {}, fmt.ch * fmt.bits // 8
  local f = fmt.tag == 3 and "<f" or (fmt.bits == 16 and "<i2" or (fmt.bits == 24 and "<i3" or "<i4"))
  local scale = fmt.tag == 3 and 1 or 2 ^ (fmt.bits - 1)
  for i = 0, frames - 1 do
    local s = 0
    for c = 0, fmt.ch - 1 do s = s + string.unpack(f, b, data.at + i * step + c * fmt.bits // 8) / scale end
    x[i + 1] = s / fmt.ch
  end
  return x, fmt.rate
end

local cmd = arg[1]
if cmd == "layout" then
  local o = assert(J.decode(slurp(arg[2])))
  io.write(J.encode(M.testLayout(o)))
elseif cmd == "measure" then
  local x, fs = readWav(arg[2])
  local o = assert(J.decode(slurp(arg[3])))
  local lay = M.testLayout(o.test)
  local function read(t, n)
    local s0 = math.floor(t * fs + 0.5)
    local out = {}
    for i = 1, n do out[i] = x[s0 + i] or 0 end
    return out
  end
  local mo = o.measure or {}
  mo.dynamics = lay.options.dynamics
  local res = M.measure(read, fs, lay.notes, mo)
  local prof = assert(M.learnProfile(res, o.meta))
  io.write(J.encode({ profile = prof, stats = res.stats }))
elseif cmd == "fix" then
  local inp = assert(J.decode(slurp(arg[2])))
  local plan = F.plan(inp.notes, inp.events or {}, inp.profiles, inp.fallback and inp.profiles[inp.fallback], inp.options)
  local out = J.object({})
  for id, c in pairs(plan.changes) do out[tostring(id)] = c end
  local moves = J.object({})
  for id, m in pairs(plan.moves) do moves[tostring(id)] = m end
  io.write(J.encode({ changes = out, moves = moves, counts = plan.counts, warnings = plan.warnings, minT = plan.minT }))
else
  io.stderr:write("usage: cli.lua layout|measure|fix ...\n")
  os.exit(2)
end
