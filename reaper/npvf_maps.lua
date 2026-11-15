--[[ Reading articulation maps: which MIDI chooses each articulation.

     - Cubase / Nuendo / Dorico expression maps (.expressionmap) - what
       BabylonWaves Art Conductor makes for Cubase
     - Logic articulation sets (.plist) - Art Conductor for Logic
     - Reaticulate banks (.reabank) - REAPER's articulation system

     Plain Lua, no REAPER. Returns
       { format = "cubase"|"logic"|"reaticulate", banks = { bank, ... } }
     where each bank is
       { name, group, articulations = { art, ... } }
     and each articulation is
       { name, send = { output, ... }, channel = 1-16 or nil, program = n or nil,
         category = text or nil, include = true|false, dynamics = 1 (velocity) | 2 (CC1) }
     and each output is one of
       { kind = "note", pitch = 0-127, vel = 1-127 }
       { kind = "cc", cc = 0-127, value = 0-127 }
       { kind = "program", value = 0-127 }

     `program` is a Reaticulate articulation's number: how a REAPER part
     using Reaticulate names it (a program change in the item).
]]

local Maps = {}

local function xmlText(s)
  return (s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'")
    :gsub("&#(%d+);", function(n) return utf8.char(tonumber(n)) end)
    :gsub("&#x(%x+);", function(n) return utf8.char(tonumber(n, 16)) end)
    :gsub("&amp;", "&"))
end

-- Long notes are usually played on the mod wheel, short ones by velocity. Only a first guess.
local LONG = { "long", "sus", "legato", "leg ", "leg%.", "^leg", "tremolo", "trem", "trill", "swell", "cresc", "dim%.", "dimin", "flautando", "sul pont", "sul tasto", "harmonic", "vib", "drone", "sordino" }
local SHORT = { "stacc", "spicc", "pizz", "short", "marcato short", "col legno", "bartok", "sfz", "stab", "detache short", "portato", "tenuto short", "rip", "fall" }
function Maps.guessDynamics(name, category)
  local c = (category or ""):lower()
  if c == "short" or c:find("short") then return 1 end
  if c == "long" or c == "legato" or c:find("long") or c:find("trem") or c:find("trill") then return 2 end
  -- the main articulation, before any options added with "+" ("Spic/Stac + ... Legato" is short)
  local n = " " .. ((name or ""):match("^([^+]*)") or ""):lower() .. " "
  for _, w in ipairs(SHORT) do if n:find(w) then return 1 end end
  for _, w in ipairs(LONG) do if n:find(w) then return 2 end end
  return 1
end

local function finish(art)
  art.dynamics = art.dynamics or Maps.guessDynamics(art.name, art.category)
  if art.include == nil then art.include = true end
  return art
end

------------------------------------------------------------------------------
-- Cubase expression maps
------------------------------------------------------------------------------

--- The text of one <member name="..."> element, nested members and all.
local function member(block, name)
  local s = block:find('<member name="' .. name .. '"', 1, true)
  if not s then return nil end
  local depth, i = 0, s
  while true do
    local o = block:find("<member[ >]", i)
    local c = block:find("</member>", i, true)
    if not c then return block:sub(s) end
    if o and o < c then depth = depth + 1; i = o + 7
    else
      depth = depth - 1; i = c + 9
      if depth == 0 then return block:sub(s, c + 8) end
    end
  end
end

function Maps.parseExpressionMap(text)
  if not text:find("<InstrumentMap", 1, true) then return nil, "This isn't a Cubase expression map." end
  local mapName = xmlText(text:match('<InstrumentMap>%s*<string name="name" value="(.-)"') or "")
  local slotsStart = text:find('<member name="slots"', 1, true)
  if not slotsStart then return nil, "The expression map has no articulations." end
  local slots = member(text, "slots")
  local arts = {}
  local starts = {}
  for p in slots:gmatch('()<obj class="PSoundSlot"') do starts[#starts + 1] = p end
  for i, p in ipairs(starts) do
    local block = slots:sub(p, (starts[i + 1] or #slots + 1) - 1)
    local nameMember = member(block, "name") or ""
    local name = xmlText(nameMember:match('value="(.-)"') or "")
    local msgs = member(block, "midiMessages") or ""
    local send = {}
    for ev in msgs:gmatch('<obj class="POutputEvent".-</obj>') do
      local status = tonumber(ev:match('name="status" value="(-?%d+)"'))
      local d1 = tonumber(ev:match('name="data1" value="(-?%d+)"'))
      local d2 = tonumber(ev:match('name="data2" value="(-?%d+)"'))
      if status and d1 and d1 >= 0 then
        local kind = status & 0xF0
        if kind == 0x90 then send[#send + 1] = { kind = "note", pitch = d1, vel = (d2 and d2 > 0) and d2 or 127 }
        elseif kind == 0xB0 then send[#send + 1] = { kind = "cc", cc = d1, value = d2 or 0 }
        elseif kind == 0xC0 then send[#send + 1] = { kind = "program", value = d1 } end
      end
    end
    -- the action's own output channel: what's left once the note changer and messages are taken out
    local action = block:match('<obj class="PSlotMidiAction".*') or ""
    local nc = member(action, "noteChanger")
    if nc then action = action:gsub(nc:gsub("%p", "%%%0"), "", 1) end
    if msgs ~= "" then action = action:gsub(msgs:gsub("%p", "%%%0"), "", 1) end
    local ch = tonumber(action:match('<int name="channel" value="(-?%d+)"') or "-1")
    local empty = (#send == 0 and (ch or -1) < 0)
    if name ~= "" and not (empty and name:lower() == "empty") then
      arts[#arts + 1] = finish({
        name = name, send = send, channel = (ch and ch >= 0) and (ch + 1) or nil,
        include = not empty,
      })
    end
  end
  return { format = "cubase", banks = { { name = mapName, articulations = arts } } }
end

------------------------------------------------------------------------------
-- Logic articulation sets (XML property lists)
------------------------------------------------------------------------------

local function parsePlist(text)
  local i = 1
  local function skip() i = text:find("<", i, true) or #text + 1 end
  local value
  function value()
    skip()
    while text:sub(i, i + 1) == "<?" or text:sub(i, i + 1) == "<!" do i = (text:find(">", i, true) or #text) + 1; skip() end
    local tag, selfClose, after = text:match("^<(%w+)[^>]-(/?)>()", i)
    if not tag then return nil end
    i = after
    if tag == "plist" then local v = value(); return v end
    if selfClose == "/" then
      if tag == "true" then return true elseif tag == "false" then return false elseif tag == "dict" then return {} elseif tag == "array" then return {} end
      return nil
    end
    if tag == "dict" then
      local t = {}
      while true do
        skip()
        if text:sub(i, i + 6) == "</dict>" then i = i + 7; return t end
        local k, a2 = text:match("^<key>(.-)</key>()", i)
        if not k then return t end
        i = a2
        t[xmlText(k)] = value()
      end
    elseif tag == "array" then
      local t = {}
      while true do
        skip()
        if text:sub(i, i + 7) == "</array>" then i = i + 8; return t end
        local v = value()
        if v == nil then return t end
        t[#t + 1] = v
      end
    else
      local close = text:find("</" .. tag .. ">", i, true) or #text + 1
      local raw = text:sub(i, close - 1)
      i = close + #tag + 3
      if tag == "integer" or tag == "real" then return tonumber(raw) end
      return xmlText(raw)
    end
  end
  return value()
end
Maps.parsePlist = parsePlist

function Maps.parseLogic(text)
  local root = parsePlist(text)
  if type(root) ~= "table" or type(root.Articulations) ~= "table" then return nil, "This isn't a Logic articulation set." end
  local arts = {}
  for _, a in ipairs(root.Articulations) do
    local outs = a.Output
    if type(outs) == "table" and outs.Status then outs = { outs } end
    local send, ch = {}, nil
    for _, o in ipairs(type(outs) == "table" and outs or {}) do
      local st = (o.Status or ""):lower()
      if o.Channel and tonumber(o.Channel) and tonumber(o.Channel) >= 1 then ch = tonumber(o.Channel) end
      if st == "note on" and o.MB1 then send[#send + 1] = { kind = "note", pitch = o.MB1, vel = (o.ValueLow and o.ValueLow > 0) and o.ValueLow or 127 }
      elseif st == "controller" and o.MB1 then send[#send + 1] = { kind = "cc", cc = o.MB1, value = o.ValueLow or 0 }
      elseif st:find("program") then send[#send + 1] = { kind = "program", value = o.ValueLow or o.MB1 or 0 } end
    end
    if a.Name and a.Name ~= "" then
      arts[#arts + 1] = finish({ name = a.Name, send = send, channel = ch, include = #send > 0 or ch ~= nil })
    end
  end
  return { format = "logic", banks = { { name = root.Name or "", articulations = arts } } }
end

------------------------------------------------------------------------------
-- Reaticulate banks
------------------------------------------------------------------------------

local function props(line)
  local p = {}
  for k, v in line:gmatch('(%w+)=([^"%s]%S*)') do p[k] = v end
  for k, v in line:gmatch('(%w+)="([^"]*)"') do p[k] = v end
  return p
end

--- Reaticulate's output spec, e.g. "note:24/note:36,100/cc:32,42/program:5/note@3:24".
function Maps.reaticulateOutputs(spec)
  local send, ch = {}, nil
  for part in (spec or ""):gmatch("[^/]+") do
    local kind = part:match("^%-?([%a%-]+)")
    local chan = part:match("@(%d+)")
    local args = {}
    for a in (part:match(":([^@%%]+)") or ""):gmatch("[^,]+") do args[#args + 1] = tonumber(a) end
    if chan then ch = tonumber(chan) end
    if (kind == "note" or kind == "note-hold" or kind == "note-on") and args[1] then
      send[#send + 1] = { kind = "note", pitch = args[1], vel = args[2] or 127 }
    elseif kind == "cc" and args[1] then
      send[#send + 1] = { kind = "cc", cc = args[1], value = args[2] or 0 }
    elseif kind == "program" and args[1] then
      send[#send + 1] = { kind = "program", value = args[1] }
    end
  end
  return send, ch
end

function Maps.parseReaticulate(text)
  local banks, bank, meta = {}, nil, {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("\r$", ""):match("^%s*(.-)%s*$")
    if line:match("^[Bb][Aa][Nn][Kk]%s") then
      local _, _, name = line:match("^%a+%s+([%d%*]+)%s+([%d%*]+)%s+(.*)$")
      bank = { name = meta.n or name or "", group = meta.g, articulations = {} }
      banks[#banks + 1] = bank
      meta = {}
    elseif line:sub(1, 3) == "//!" then
      for k, v in pairs(props(line)) do meta[k] = v end
    elseif line ~= "" and line:sub(1, 2) ~= "//" then
      local program, name = line:match("^(%d+)%s+(.*)$")
      if bank and program then
        local send, ch = Maps.reaticulateOutputs(meta.o)
        local group = tonumber(meta.g or "1") or 1
        local hidden = meta.f and meta.f:find("hidden")
        if not hidden then
          bank.articulations[#bank.articulations + 1] = finish({
            name = name, send = send, channel = ch, program = tonumber(program), category = meta.c,
            -- other groups (vibrato on/off, mutes) change the one chosen in group 1: not measured alone
            include = group == 1 and (#send > 0 or ch ~= nil), group = group,
          })
        end
      end
      meta = {}
    else
      -- a blank line or plain comment between a bank's metadata and its Bank line keeps the metadata
    end
  end
  if #banks == 0 then return nil, "This isn't a Reaticulate bank file." end
  return { format = "reaticulate", banks = banks }
end

------------------------------------------------------------------------------

--- Read any of the three, by content (the file name is only a hint).
function Maps.parse(text, filename)
  local f = (filename or ""):lower()
  if text:find("<InstrumentMap", 1, true) then return Maps.parseExpressionMap(text) end
  if text:find("<plist", 1, true) or f:match("%.plist$") then return Maps.parseLogic(text) end
  if f:match("%.reabank$") or text:find("\n%s*[Bb]ank%s+[%d%*]+%s+[%d%*]+") or text:match("^%s*[Bb]ank%s") then return Maps.parseReaticulate(text) end
  return nil, "Open a Cubase expression map (.expressionmap), a Logic articulation set (.plist) or a Reaticulate bank (.reabank)."
end

--- In words: "C-1 + C0", "CC32 = 42", "Program 5", "on channel 3".
local NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }
local function noteName(p) return NAMES[p % 12 + 1] .. (p // 12 - 2) end
function Maps.describe(art)
  local parts = {}
  for _, o in ipairs(art.send or {}) do
    if o.kind == "note" then parts[#parts + 1] = noteName(o.pitch) .. ((o.vel and o.vel ~= 127 and o.vel ~= 100) and (" vel " .. o.vel) or "")
    elseif o.kind == "cc" then parts[#parts + 1] = "CC" .. o.cc .. " = " .. o.value
    elseif o.kind == "program" then parts[#parts + 1] = "Program " .. o.value end
  end
  local s = table.concat(parts, " + ")
  if art.channel then s = (s ~= "" and (s .. ", ") or "") .. "channel " .. art.channel end
  return s ~= "" and s or "nothing"
end

--- The bank whose name best fits `name` (an instrument or track), else the first.
function Maps.bestBank(map, name)
  local n = (name or ""):lower()
  local best, score = 1, -1
  for i, b in ipairs(map.banks) do
    local bn = (b.name or ""):lower()
    local s = 0
    if bn == n then s = 1000 end
    for w in n:gmatch("%w+") do if #w > 1 and bn:find(w, 1, true) then s = s + #w end end
    if s > score then best, score = i, s end
  end
  return best
end

return Maps
