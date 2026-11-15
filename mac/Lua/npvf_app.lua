--[[ What the Mac app asks of the shared Lua: the same measuring, map reading
     and profile files as the REAPER scripts (reaper/npvf_*.lua, copied into
     the app beside this file). Everything goes in and out as JSON text, so
     the Swift side never touches a Lua table. The C bridge
     (mac/Sources/NPVFBridge) calls npvf_dispatch and npvf_measure. ]]

local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
local J = dofile(HERE .. "npvf_json.lua")
local M = dofile(HERE .. "npvf_measure.lua")
local Maps = dofile(HERE .. "npvf_maps.lua")
local L = dofile(HERE .. "npvf_library.lua")

local App = {}

-- JSON arrays of keys become the { [pitch] = true } sets the Lua wants.
local function keySet(list)
  if type(list) ~= "table" then return nil end
  local s = {}
  for _, k in ipairs(list) do s[k] = true end
  return s
end

--- The test part: { events, notes, length, options } in seconds.
function App.layout(opts)
  opts.skip = keySet(opts.skipKeys)
  opts.skipKeys = nil
  local lay = M.testLayout(opts)
  lay.options.skip = nil
  lay.options.keyswitchKeysSkipped = opts.skip and (function()
    local k = {}
    for p in pairs(opts.skip) do k[#k + 1] = p end
    table.sort(k)
    return k
  end)() or nil
  lay.seconds = M.testSeconds(opts)
  return lay
end

function App.testSeconds(opts)
  opts.skip = keySet(opts.skipKeys)
  return { seconds = M.testSeconds(opts) }
end

--- A map file's banks and articulations, with each one described in words.
function App.parseMap(a)
  local map, err = Maps.parse(a.text or "", a.filename)
  if not map then error(err, 0) end
  for _, b in ipairs(map.banks) do
    for _, art in ipairs(b.articulations) do art.describe = Maps.describe(art) end
    b.best = nil
  end
  map.best = Maps.bestBank(map, a.name or "")
  return map
end

function App.describe(art) return { text = Maps.describe(art) } end
function App.profileFileName(a) return { file = L.profileFileName(a.instrument, a.articulation, a.library) } end
function App.index(a) return L.index(a.files or {}, a.now) end
function App.guessDynamics(a) return { dynamics = Maps.guessDynamics(a.name, a.category) } end

--- JSON in, JSON out. Errors come back as { "error": "..." }.
function npvf_dispatch(fn, argsJson)
  local f = App[fn]
  if not f then return J.encode({ error = "no such call: " .. tostring(fn) }) end
  local args, perr = J.decode(argsJson or "{}")
  if perr then return J.encode({ error = perr }) end
  local ok, res = pcall(f, args or {})
  if not ok then return J.encode({ error = tostring(res) }) end
  return J.encode(res)
end

--[[ Measure a render. `req`: { layout = what App.layout gave, measure = options
     (alignTo, dynamics...), meta = for the profile (instrument, library,
     articulation, plugin, send, outChannel, program, category, source,
     measuredBy, sampleRate) }. `read(t, n)` gives samples, `progress(i, n)`
     raises to stop. Returns { profile, stats, warnings } or { error }. ]]
function npvf_measure(reqJson, read, fs, progress)
  local req, perr = J.decode(reqJson)
  if perr then return J.encode({ error = perr }) end
  local ok, res = pcall(function()
    local lay = req.layout
    local mo = req.measure or {}
    mo.dynamics = lay.options.dynamics
    local r = M.measure(read, fs, lay.notes, mo, progress)
    local out = { stats = r.stats, warnings = r.warnings }
    if r.stats.found >= 6 then
      local meta = req.meta or {}
      meta.test = lay.options
      meta.sampleRate = fs
      meta.measuredIn = meta.measuredIn or "Note Fixer for Mac"
      local prof, why = M.learnProfile(r, meta)
      out.profile = prof
      if prof then out.file = L.profileFileName(prof.instrument, prof.articulation, prof.library) else out.why = why end
    end
    return out
  end)
  if not ok then return J.encode({ error = tostring(res) }) end
  return J.encode(res, " ")
end

return App
