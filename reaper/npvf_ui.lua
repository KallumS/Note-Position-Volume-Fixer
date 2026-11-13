--[[ The look both windows share: the house colours and the family's widgets,
     after Good Idea (reascripts/Good Idea.lua), which has the reasons.

     U.init(ImGui, ctx) once; then U.pushTheme()/U.popTheme() around Begin
     and End, and the widgets in between.
]]

local U = {}
local ImGui, ctx

-- The house scheme (Good Idea's docs/COLOUR.md): every grey blue-shifted,
-- R < G < B; light controls with dark ink; yellow only for what is chosen.
U.THEME = {
  { "Col_Text", 0xDDE1E7FF },
  { "Col_TextDisabled", 0xBFC5CEFF },
  { "Col_WindowBg", 0x23272EFF },
  { "Col_ChildBg", 0x1A1D23FF },
  { "Col_PopupBg", 0x2A2F37FF },
  { "Col_Border", 0x3A404AFF },
  { "Col_FrameBg", 0x1A1D23FF },
  { "Col_FrameBgHovered", 0x22262DFF },
  { "Col_FrameBgActive", 0x2A2F37FF },
  { "Col_TitleBg", 0x1B1F25FF },
  { "Col_TitleBgActive", 0x23272EFF },
  { "Col_TitleBgCollapsed", 0x1B1F25FF },
  { "Col_Header", 0x3A404AFF },
  { "Col_HeaderHovered", 0x3A404AFF },
  { "Col_HeaderActive", 0x22262DFF },
  { "Col_Button", 0xA9AFBAFF },
  { "Col_ButtonHovered", 0xC0C6CFFF },
  { "Col_ButtonActive", 0x8F96A2FF },
  { "Col_CheckMark", 0xFFF200FF },
  { "Col_SliderGrab", 0xA9AFBAFF },
  { "Col_SliderGrabActive", 0xFFF200FF },
  { "Col_Separator", 0x3A404AFF },
  { "Col_ScrollbarBg", 0x1A1D23FF },
  { "Col_ScrollbarGrab", 0x6D7581FF },
  { "Col_ScrollbarGrabHovered", 0x8A919CFF },
  { "Col_ScrollbarGrabActive", 0xA9AFBAFF },
  { "Col_ResizeGrip", 0x6D7581FF },
  { "Col_ResizeGripHovered", 0x8A919CFF },
  { "Col_ResizeGripActive", 0xA9AFBAFF },
  { "Col_TableHeaderBg", 0x2A2F37FF },
  { "Col_TableRowBg", 0x23272EFF },
  { "Col_TableRowBgAlt", 0x1E2228FF },
  { "Col_TableBorderLight", 0x3A404AFF },
  { "Col_TableBorderStrong", 0x3A404AFF },
  { "Col_PlotHistogram", 0xA9AFBAFF },
  { "Col_NavHighlight", 0xF2F4F7FF },
}
U.SELECTED = 0xFFF200FF
U.INK = 0x14171CFF
U.DIM = 0xB0B6C0FF
U.WARN = 0xFF9E96FF
U.EDGE = 0x8A919CFF

local font

function U.init(imgui, context)
  ImGui, ctx = imgui, context
  font = ImGui.CreateFont("sans-serif", 13)
  ImGui.Attach(ctx, font)
end

local function shade(col, amount)
  local r, g, b, a = (col >> 24) & 255, (col >> 16) & 255, (col >> 8) & 255, col & 255
  local function f(c) return math.floor((amount > 0 and c + (255 - c) * amount or c * (1 + amount)) + 0.5) end
  return (f(r) << 24) | (f(g) << 16) | (f(b) << 8) | a
end
U.shade = shade

local VARS = 3
function U.pushTheme()
  for _, c in ipairs(U.THEME) do ImGui.PushStyleColor(ctx, ImGui[c[1]], c[2]) end
  ImGui.PushFont(ctx, font)
  -- Apple's Mac control: 28 points tall (a 13-point line, 7.5 above and below), about 12 between.
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 8, 7.5)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, 12, 12)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemInnerSpacing, 8, 6)
end
function U.popTheme()
  ImGui.PopStyleVar(ctx, VARS)
  ImGui.PopFont(ctx)
  ImGui.PopStyleColor(ctx, #U.THEME)
end

--- Wrapped into lines of about 64 characters, for tooltips.
function U.lines(text)
  local out = {}
  for para in (text .. "\n"):gmatch("(.-)\n") do
    local line = ""
    for word in para:gmatch("%S+") do
      local longer = (line == "") and word or (line .. " " .. word)
      if line ~= "" and (utf8.len(longer) or #longer) > 64 then out[#out + 1] = line; line = word else line = longer end
    end
    out[#out + 1] = line
  end
  return table.concat(out, "\n")
end

function U.tip(text)
  if text and ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, U.lines(text)) end
end

local function width(label) return select(1, ImGui.CalcTextSize(ctx, (label:gsub("##.*$", "")))) + 16 end

--- A grey button with dark ink; a chosen one is yellow with a bar under its words (not colour alone).
function U.button(label, selected, tip)
  local pushed = 1
  if selected then
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, U.SELECTED)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, shade(U.SELECTED, 0.18))
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, shade(U.SELECTED, -0.18))
    pushed = 4
  end
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, U.INK)
  local hit = ImGui.Button(ctx, label, width(label), 0)
  ImGui.PopStyleColor(ctx, pushed)
  if selected then
    local x1 = ImGui.GetItemRectMin(ctx)
    local x2, y2 = ImGui.GetItemRectMax(ctx)
    ImGui.DrawList_AddRectFilled(ImGui.GetWindowDrawList(ctx), x1 + 8, y2 - 5, x2 - 8, y2 - 3, U.INK)
  end
  U.tip(tip)
  return hit
end

--- One of several choices, side by side. Returns the index chosen this frame.
function U.choice(id, labels, current, tips)
  local picked
  ImGui.PushID(ctx, id)
  for i, l in ipairs(labels) do
    if i > 1 then ImGui.SameLine(ctx, 0, 1) end
    ImGui.PushID(ctx, i)
    if U.button(l, i == current, tips and tips[i]) then picked = i end
    ImGui.PopID(ctx)
  end
  ImGui.PopID(ctx)
  return picked
end

--- Fields, tick boxes and sliders with an edge 3:1 on the ground.
function U.edged(draw)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameBorderSize, 1)
  ImGui.PushStyleColor(ctx, ImGui.Col_Border, U.EDGE)
  local a, b = draw()
  ImGui.PopStyleColor(ctx, 1)
  ImGui.PopStyleVar(ctx, 1)
  return a, b
end

function U.check(label, value, tip)
  local c, v = U.edged(function() return ImGui.Checkbox(ctx, label, value) end)
  U.tip(tip)
  return c, v
end

function U.text(label, value, w, tip)
  ImGui.SetNextItemWidth(ctx, w or 120)
  local c, v = U.edged(function() return ImGui.InputText(ctx, label, value) end)
  U.tip(tip)
  return c, v
end

function U.int(label, value, lo, hi, w, tip)
  ImGui.SetNextItemWidth(ctx, w or 110)
  local c, v = U.edged(function() return ImGui.InputInt(ctx, label, value, 1, 10) end)
  if c then v = math.max(lo, math.min(hi, v)) end
  U.tip(tip)
  return c, v
end

function U.number(label, value, lo, hi, step, fmt, w, tip)
  ImGui.SetNextItemWidth(ctx, w or 120)
  local c, v = U.edged(function() return ImGui.InputDouble(ctx, label, value, step, step * 10, fmt) end)
  if c then v = math.max(lo, math.min(hi, v)) end
  U.tip(tip)
  return c, v
end

--- A drop-down. `items` are labels; returns the index chosen this frame.
function U.combo(label, items, current, w, tip)
  ImGui.SetNextItemWidth(ctx, w or 200)
  local picked
  local open = U.edged(function() return ImGui.BeginCombo(ctx, label, items[current] or "") end)
  if open then
    for i, it in ipairs(items) do
      if ImGui.Selectable(ctx, it .. "##" .. i, i == current) then picked = i end
    end
    ImGui.EndCombo(ctx)
  end
  U.tip(tip)
  return picked
end

function U.dim(text)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, U.DIM)
  ImGui.TextWrapped(ctx, text)
  ImGui.PopStyleColor(ctx, 1)
end

function U.warn(text)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, U.WARN)
  ImGui.TextWrapped(ctx, text)
  ImGui.PopStyleColor(ctx, 1)
end

function U.heading(n, text)
  ImGui.Dummy(ctx, 1, 4)
  ImGui.SeparatorText(ctx, (n and (n .. "  ") or "") .. text)
end

--- Note names with middle C as C3 (Ableton, Cubase; REAPER can be set either way).
local NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }
function U.noteName(p) return NAMES[p % 12 + 1] .. (p // 12 - 2) end
function U.parseNote(s)
  local l, acc, oct = tostring(s or ""):match("^%s*([A-Ga-g])%s*([#b]?)%s*(-?%d+)%s*$")
  if not l then return nil end
  local base = ({ c = 0, d = 2, e = 4, f = 5, g = 7, a = 9, b = 11 })[l:lower()]
  local p = base + (acc == "#" and 1 or acc == "b" and -1 or 0) + (tonumber(oct) + 2) * 12
  if p < 0 or p > 127 then return nil end
  return p
end

return U
