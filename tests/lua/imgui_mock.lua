--[[ A ReaImGui 0.9 that records what a frame draws and lets a test press
     buttons and type into fields, for test_scripts.lua.

     Widgets are found by their ID path: the IDs pushed (PushID, BeginTable)
     joined with "/", then the label, e.g. "arts/2/##n" or "Measure All".
     IMGUI.click(path) presses a button on the next frame it is drawn;
     IMGUI.set(path, value) types into a field, ticks a box or (for a combo)
     picks the nth item. Only signatures from ReaImGui 0.9's documentation;
     anything else raises.

     Each frame it records every text and button with the colours in force,
     so the tests can check the house colours and Apple's contrast.
]]

local G = { pending = {}, frame = {}, clipboard = nil, escape = false, closed = false }
local ImGui = { _G = G }
_G.IMGUI = G

local n = 0
local function const(name) n = n + 1; ImGui[name] = n end
for _, c in ipairs({
  "Col_Text", "Col_TextDisabled", "Col_WindowBg", "Col_ChildBg", "Col_PopupBg", "Col_Border", "Col_FrameBg",
  "Col_FrameBgHovered", "Col_FrameBgActive", "Col_TitleBg", "Col_TitleBgActive", "Col_TitleBgCollapsed",
  "Col_Header", "Col_HeaderHovered", "Col_HeaderActive", "Col_Button", "Col_ButtonHovered", "Col_ButtonActive",
  "Col_CheckMark", "Col_SliderGrab", "Col_SliderGrabActive", "Col_Separator", "Col_ScrollbarBg", "Col_ScrollbarGrab",
  "Col_ScrollbarGrabHovered", "Col_ScrollbarGrabActive", "Col_ResizeGrip", "Col_ResizeGripHovered",
  "Col_ResizeGripActive", "Col_TableHeaderBg", "Col_TableRowBg", "Col_TableRowBgAlt", "Col_TableBorderLight",
  "Col_TableBorderStrong", "Col_PlotHistogram", "Col_NavHighlight",
  "StyleVar_FramePadding", "StyleVar_ItemSpacing", "StyleVar_ItemInnerSpacing", "StyleVar_FrameBorderSize",
  "Cond_FirstUseEver", "Key_Escape",
}) do const(c) end
-- flags are bits
ImGui.ConfigFlags_NavEnableKeyboard = 1
ImGui.TableFlags_RowBg, ImGui.TableFlags_BordersInnerH, ImGui.TableFlags_SizingStretchProp = 64, 128, 8192
ImGui.TableColumnFlags_WidthFixed, ImGui.TableColumnFlags_WidthStretch = 16, 8

local ids, colors, vars, fontDepth = {}, {}, 0, 0
local comboPick, comboIndex = nil, 0
local function path(label) local p = table.concat(ids, "/"); return (p ~= "" and (p .. "/") or "") .. label end
local function current(idx)
  for i = #colors, 1, -1 do if colors[i].idx == idx then return colors[i].col end end
end
local function record(kind, label, extra)
  local r = { kind = kind, label = label, path = path(label), text = current(ImGui.Col_Text), fill = current(ImGui.Col_Button), bg = G.bg }
  for k, v in pairs(extra or {}) do r[k] = v end
  G.frame[#G.frame + 1] = r
  return r
end
local function take(p)
  local v = G.pending[p]
  G.pending[p] = nil
  return v
end

function G.click(p) G.pending[p] = true end
function G.set(p, v) G.pending[p] = v end
function G.newFrame() G.frame = {} end
--- Texts drawn this frame whose words contain `s`.
function G.find(s)
  local out = {}
  for _, r in ipairs(G.frame) do if r.label and r.label:find(s, 1, true) then out[#out + 1] = r end end
  return out
end

ImGui.CreateContext = function(label, flags) G.flags = flags; return { label = label } end
ImGui.CreateFont = function(family, size) assert(type(size) == "number"); return { family = family, size = size } end
ImGui.Attach = function(_, obj) assert(obj) end
ImGui.SetNextWindowSize = function(_, w, h, cond) end
ImGui.SetNextWindowBgAlpha = function(_, a) end
ImGui.Begin = function(_, name, open, flags)
  G.newFrame()
  G.title = name
  G.bg = current(ImGui.Col_WindowBg)
  assert(#ids == 0, "IDs left pushed from the last frame")
  return true, not G.closed
end
ImGui.End = function(_) assert(#ids == 0, "an ID was pushed and not popped") end
ImGui.PushStyleColor = function(_, idx, col) assert(idx and col, "PushStyleColor needs a colour index and a colour"); colors[#colors + 1] = { idx = idx, col = col } end
ImGui.PopStyleColor = function(_, count) for _ = 1, count or 1 do assert(#colors > 0, "popped a colour that wasn't pushed"); colors[#colors] = nil end end
ImGui.PushStyleVar = function(_, idx, a, b) assert(idx); vars = vars + 1 end
ImGui.PopStyleVar = function(_, count) vars = vars - (count or 1); assert(vars >= 0, "popped a style var that wasn't pushed") end
ImGui.PushFont = function(_, f) assert(f); fontDepth = fontDepth + 1 end
ImGui.PopFont = function(_) fontDepth = fontDepth - 1; assert(fontDepth >= 0) end
ImGui.PushID = function(_, id) ids[#ids + 1] = tostring(id) end
ImGui.PopID = function(_) assert(#ids > 0, "popped an ID that wasn't pushed"); ids[#ids] = nil end

ImGui.Button = function(_, label, w, h)
  record("button", label)
  return take(path(label)) == true
end
ImGui.Checkbox = function(_, label, v)
  record("check", label)
  local nv = take(path(label))
  if nv ~= nil then return true, nv end
  return false, v
end
local function field(kind)
  return function(_, label, v, ...)
    record(kind, label, { value = v })
    local nv = take(path(label))
    if nv ~= nil then return true, nv end
    return false, v
  end
end
ImGui.InputText = field("text")
ImGui.InputInt = field("int")
ImGui.InputDouble = field("double")
ImGui.SliderInt = field("slider")
ImGui.BeginCombo = function(_, label, preview)
  record("combo", label, { preview = preview })
  comboPick = take(path(label))
  comboIndex = 0
  return comboPick ~= nil
end
ImGui.Selectable = function(_, label, selected)
  comboIndex = comboIndex + 1
  return comboIndex == comboPick
end
ImGui.EndCombo = function(_) comboPick = nil end
ImGui.BeginTable = function(_, id, cols, flags) assert(cols > 0); ids[#ids + 1] = id; return true end
ImGui.EndTable = function(_) ids[#ids] = nil end
ImGui.TableSetupColumn = function(_, label, flags, w) end
ImGui.TableHeadersRow = function(_) end
ImGui.TableNextRow = function(_) end
ImGui.TableNextColumn = function(_) return true end
ImGui.Text = function(_, s) record("text", s) end
ImGui.TextWrapped = function(_, s) record("text", s) end
ImGui.SeparatorText = function(_, s) record("heading", s) end
ImGui.SameLine = function(_, x, gap) end
ImGui.Dummy = function(_, w, h) end
ImGui.NewLine = function(_) end
ImGui.AlignTextToFramePadding = function(_) end
ImGui.SetNextItemWidth = function(_, w) end
ImGui.IsItemHovered = function(_) return false end
ImGui.SetTooltip = function(_, s) end
ImGui.CalcTextSize = function(_, s) return #s * 7, 13 end
ImGui.GetItemRectMin = function(_) return 0, 0 end
ImGui.GetItemRectMax = function(_) return 100, 28 end
ImGui.GetWindowDrawList = function(_) return {} end
ImGui.DrawList_AddRectFilled = function(dl, x1, y1, x2, y2, col) G.bars = (G.bars or 0) + 1 end
ImGui.ProgressBar = function(_, f, w, h, overlay) record("progress", overlay, { fraction = f }) end
ImGui.BeginDisabled = function(_, d) G.disabled = d end
ImGui.EndDisabled = function(_) G.disabled = false end
ImGui.SetClipboardText = function(_, s) G.clipboard = s end
ImGui.IsKeyPressed = function(_, key) return key == ImGui.Key_Escape and G.escape end

return setmetatable(ImGui, { __index = function(_, k) error("mock ReaImGui has no " .. tostring(k), 2) end })
