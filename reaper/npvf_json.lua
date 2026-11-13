--[[ JSON for profiles and the test list. Plain Lua, no REAPER.

     Objects are Lua tables with string keys, arrays are tables with 1..n.
     An empty table is written as an array unless it is marked with
     J.object(t). Numbers are written with up to 10 significant digits, which
     keeps profiles readable and is far finer than anything measured.
]]

local J = {}

local OBJ = setmetatable({}, { __mode = "k" })
function J.object(t) OBJ[t] = true; return t end

local ESC = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function isArray(t)
  if OBJ[t] then return false end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
    n = math.max(n, k)
  end
  return n == #t
end

local function encode(v, out, indent, depth)
  local tv = type(v)
  if tv == "nil" then out[#out + 1] = "null"
  elseif tv == "boolean" then out[#out + 1] = v and "true" or "false"
  elseif tv == "number" then
    if v ~= v or v == math.huge or v == -math.huge then out[#out + 1] = "null"
    elseif v % 1 == 0 and math.abs(v) < 1e15 then out[#out + 1] = string.format("%d", v)
    else
      local s = string.format("%.10g", v)
      out[#out + 1] = s
    end
  elseif tv == "string" then
    out[#out + 1] = '"' .. v:gsub('[%c"\\]', function(c) return ESC[c] or string.format("\\u%04x", c:byte()) end) .. '"'
  elseif tv == "table" then
    local nl = indent and ("\n" .. string.rep(indent, depth + 1)) or ""
    local close = indent and ("\n" .. string.rep(indent, depth)) or ""
    if isArray(v) then
      if #v == 0 then out[#out + 1] = "[]"; return end
      out[#out + 1] = "["
      for i, x in ipairs(v) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = nl
        encode(x, out, indent, depth + 1)
      end
      out[#out + 1] = close .. "]"
    else
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = tostring(k) end
      table.sort(keys)
      if #keys == 0 then out[#out + 1] = "{}"; return end
      out[#out + 1] = "{"
      for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = nl
        encode(k, out, indent, depth + 1)
        out[#out + 1] = indent and ": " or ":"
        local x = v[k]
        if x == nil then x = v[tonumber(k)] end
        encode(x, out, indent, depth + 1)
      end
      out[#out + 1] = close .. "}"
    end
  else
    error("can't write a " .. tv .. " as JSON")
  end
end

--- `indent` (e.g. " ") pretty-prints; leave it out for one line.
function J.encode(v, indent)
  local out = {}
  encode(v, out, indent, 0)
  return table.concat(out)
end

function J.decode(s)
  local i = 1
  local function fail(msg) error("JSON: " .. msg .. " at character " .. i, 0) end
  local function ws() i = s:find("[^ \t\r\n]", i) or (#s + 1) end
  local value
  local function str()
    i = i + 1
    local parts = {}
    while true do
      local j = s:find('["\\]', i)
      if not j then fail("unterminated string") end
      parts[#parts + 1] = s:sub(i, j - 1)
      if s:sub(j, j) == '"' then i = j + 1; break end
      local c = s:sub(j + 1, j + 1)
      local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
      if map[c] then parts[#parts + 1] = map[c]; i = j + 2
      elseif c == "u" then
        local code = tonumber(s:sub(j + 2, j + 5), 16)
        if not code then fail("bad \\u escape") end
        i = j + 6
        if code >= 0xD800 and code <= 0xDBFF and s:sub(i, i + 1) == "\\u" then
          local lo = tonumber(s:sub(i + 2, i + 5), 16)
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            code = 0x10000 + (code - 0xD800) * 0x400 + (lo - 0xDC00)
            i = i + 6
          end
        end
        parts[#parts + 1] = utf8.char(code)
      else fail("bad escape") end
    end
    return table.concat(parts)
  end
  function value()
    ws()
    local c = s:sub(i, i)
    if c == "{" then
      i = i + 1
      local t = J.object({})
      ws()
      if s:sub(i, i) == "}" then i = i + 1; return t end
      while true do
        ws()
        if s:sub(i, i) ~= '"' then fail("expected a name") end
        local k = str()
        ws()
        if s:sub(i, i) ~= ":" then fail("expected :") end
        i = i + 1
        t[k] = value()
        ws()
        local d = s:sub(i, i)
        i = i + 1
        if d == "}" then return t end
        if d ~= "," then fail("expected , or }") end
      end
    elseif c == "[" then
      i = i + 1
      local t = {}
      ws()
      if s:sub(i, i) == "]" then i = i + 1; return t end
      while true do
        t[#t + 1] = value()
        ws()
        local d = s:sub(i, i)
        i = i + 1
        if d == "]" then return t end
        if d ~= "," then fail("expected , or ]") end
      end
    elseif c == '"' then return str()
    elseif s:sub(i, i + 3) == "true" then i = i + 4; return true
    elseif s:sub(i, i + 4) == "false" then i = i + 5; return false
    elseif s:sub(i, i + 3) == "null" then i = i + 4; return nil
    else
      local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
      if not num or num == "" then fail("unexpected " .. (c == "" and "end" or c)) end
      i = i + #num
      return tonumber(num) or fail("bad number")
    end
  end
  local ok, res = pcall(value)
  if not ok then return nil, res end
  ws()
  if i <= #s then return nil, "JSON: extra text at character " .. i end
  return res
end

return J
