--[[ The profiles folder's naming and its index, Library.json. Plain Lua, no
     REAPER: the REAPER scripts and the Mac app both use it, so both write the
     same files (docs/profile-format.md). ]]

local L = {}

function L.safeName(s)
  s = tostring(s or ""):gsub('[\\/:%*%?"<>|%c]+', "-"):gsub("^%s+", ""):gsub("%s+$", "")
  return s ~= "" and s or "Untitled"
end

--- "<Library> - <Instrument> - <Articulation>.json", the library left out when there is none.
function L.profileFileName(instrument, articulation, library)
  local n = L.safeName(instrument) .. ((articulation and articulation ~= "") and (" - " .. L.safeName(articulation)) or "")
  if library and library ~= "" then n = L.safeName(library) .. " - " .. n end
  return n .. ".json"
end

function L.isProfile(p)
  return type(p) == "table" and p.kind == "note-position-volume-fixer/profile" and type(p.entries) == "table" and #p.entries > 0
end

--- One line of the index for a profile saved as Profiles/<file>.
function L.indexEntry(file, p)
  local sum = p.summary or {}
  return {
    file = "Profiles/" .. file, name = p.name, library = p.library, instrument = p.instrument,
    articulation = p.articulation, plugin = p.plugin, dynamics = p.dynamics or "velocity",
    send = p.send, channel = p.channel, program = p.program, created = p.created, version = p.version or 1,
    measuredIn = p.measuredIn, range = p.range, medianMs = sum.medianMs, minMs = sum.minMs, maxMs = sum.maxMs,
    roundRobinSpreadMs = sum.roundRobinSpreadMs, offKeys = sum.offKeys,
  }
end

--- The index from { { file = "x.json", profile = {...} }, ... } (anything not a profile is left out).
function L.index(files, now)
  local list = {}
  for _, f in ipairs(files) do
    if L.isProfile(f.profile) then list[#list + 1] = L.indexEntry(f.file, f.profile) end
  end
  table.sort(list, function(a, b) return a.file < b.file end)
  return {
    kind = "note-position-volume-fixer/library", version = 1,
    updated = now or os.date("!%Y-%m-%dT%H:%M:%SZ"), profiles = list,
  }
end

return L
