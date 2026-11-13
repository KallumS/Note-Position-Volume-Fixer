--[[
 * ReaScript Name: Note Fixer - Fix Selected Items
 * Description:    Moves the notes of the selected MIDI items so each one's
 *                 sound lands where it was written, and evens out notes
 *                 the library plays too loud or too quiet, using profiles
 *                 from Note Fixer - Measure Libraries.
 *
 * About:          Select MIDI items, choose each track's instrument, and
 *                 press Fix Selected Items. Each note uses the profile of the
 *                 articulation its keyswitch, CC, program change or MIDI
 *                 channel chose. Undo puts everything back.
 *
 *                 Needs ReaImGui, from the ReaTeam Extensions repository.
 * Author:         Kallum Shah
 * Links:          https://github.com/KallumS/Note-Position-Volume-Fixer
 * Version:        1.0
 * Provides:
 *   npvf_json.lua
 *   npvf_fix.lua
 *   npvf_reaper.lua
 *   npvf_ui.lua
--]]

local TITLE = "Note Fixer - Fix Selected Items"
local SECTION = "NoteFixerFix"

local imgui_path = reaper.ImGui_GetBuiltinPath and (reaper.ImGui_GetBuiltinPath() .. "/imgui.lua")
if not imgui_path then
  reaper.MB("Note Fixer needs the ReaImGui extension.\n\nInstall it with ReaPack, from the ReaTeam Extensions repository.", TITLE, 0)
  return
end
local ImGui = dofile(imgui_path)("0.9")

local HERE = ({ reaper.get_action_context() })[2]:match("^(.*[/\\])")
local J = dofile(HERE .. "npvf_json.lua")
local F = dofile(HERE .. "npvf_fix.lua")
local R = dofile(HERE .. "npvf_reaper.lua").init(J)
local U = dofile(HERE .. "npvf_ui.lua")

local ctx

local VOLUME = { "Automatic", "Velocity", "CC11", "Off" }
local VOLUME_KEYS = { "auto", "velocity", "cc11", "off" }
local VOLUME_TIPS = {
  "Automatic: velocity for profiles measured by velocity, CC11 for profiles measured on CC1.",
  "Velocity: change the velocity of notes that come out too loud or too quiet.",
  "CC11: write one CC11 value before each note instead. Notes that overlap keep their velocity.",
  "Off: leave the volume alone.",
}

local st = { timing = true, strength = 100, target = 0, volume = 1, tolerance = 1.0, ksmax = "" }
local SAVED = { "timing", "strength", "target", "volume", "tolerance", "ksmax" }

local ui = {
  profiles = {}, names = {}, groups = {}, choice = {}, fallback = {},
  message = nil, warn = false, lastScan = 0,
}

local function saveState()
  local parts = {}
  for _, k in ipairs(SAVED) do parts[#parts + 1] = k .. "=" .. tostring(st[k]) end
  reaper.SetExtState(SECTION, "state", table.concat(parts, ";"), true)
end
local function loadState()
  for pair in (reaper.GetExtState(SECTION, "state") or ""):gmatch("[^;]+") do
    local k, v = pair:match("^(%w+)=(.*)$")
    if k and st[k] ~= nil then
      if type(st[k]) == "number" then st[k] = tonumber(v) or st[k]
      elseif type(st[k]) == "boolean" then st[k] = (v == "true")
      else st[k] = v end
    end
  end
end

local function say(text, warn) ui.message, ui.warn = text, warn end

local function loadProfiles()
  ui.profiles, ui.names = R.loadProfiles()
end

--- The instrument a track most likely plays: the one named like it.
local function guess(trackName)
  local t = (trackName or ""):lower()
  if t == "" then return nil end
  local best, bestLen
  for _, n in ipairs(ui.names) do
    local l = n:lower()
    if l == t then return n end
    if (t:find(l, 1, true) or l:find(t, 1, true)) and (not bestLen or #l > bestLen) then best, bestLen = n, #l end
  end
  return best
end

local function scan()
  ui.groups = R.selectedMidiByTrack()
  for _, g in ipairs(ui.groups) do
    if ui.choice[g.track] == nil then ui.choice[g.track] = guess(g.name) or false end
  end
end

local function artLabel(p) return (p.articulation and p.articulation ~= "") and p.articulation or p.name end

local function fix()
  scan()
  if #ui.groups == 0 then say("Select one or more MIDI items first.", true); return end
  local ksmax = U.parseNote(st.ksmax) or -1
  local opts = {
    timing = st.timing, strength = st.strength / 100, targetMs = st.target,
    volume = VOLUME_KEYS[st.volume], toleranceDb = st.tolerance, keyswitchMax = ksmax,
  }
  local totals = { moved = 0, velocity = 0, cc11 = 0, fixed = 0 }
  local warnings, skipped = {}, {}
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  for gi, g in ipairs(ui.groups) do
    local inst = ui.choice[g.track]
    local profiles = inst and ui.profiles[inst]
    if not profiles then
      skipped[#skipped + 1] = (g.name ~= "" and g.name or ("Track " .. gi))
    else
      local fb = ui.fallback[g.track]
      local fallback = (fb and fb > 0) and profiles[fb] or (#profiles == 1 and profiles[1] or nil)
      for ii, it in ipairs(g.items) do
        local notes, events = R.readTake(it.take, ii * 1000000)
        local plan = F.plan(notes, events, profiles, fallback, opts)
        R.writeTake(it.item, it.take, notes, events, plan)
        for k in pairs(totals) do totals[k] = totals[k] + (plan.counts[k] or 0) end
        for _, w in ipairs(plan.warnings) do warnings[#warnings + 1] = w end
      end
    end
  end
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Note Fixer: fix notes from profiles", -1)
  local parts = {}
  if totals.moved > 0 then parts[#parts + 1] = totals.moved .. (totals.moved == 1 and " note moved" or " notes moved") end
  if totals.velocity > 0 then parts[#parts + 1] = totals.velocity .. (totals.velocity == 1 and " velocity changed" or " velocities changed") end
  if totals.cc11 > 0 then parts[#parts + 1] = totals.cc11 .. " CC11 values written" end
  local msg = (#parts > 0 and table.concat(parts, ", ") .. "." or "Nothing needed changing.") .. " Undo puts it back."
  if #skipped > 0 then msg = msg .. " Left alone, with no instrument chosen: " .. table.concat(skipped, ", ") .. "." end
  local seen = {}
  for _, w in ipairs(warnings) do if not seen[w] then seen[w] = true; msg = msg .. " " .. w end end
  say(msg, #skipped > 0 or #warnings > 0)
end

------------------------------------------------------------------------------
-- The window
------------------------------------------------------------------------------

local function itemsSection()
  U.heading(1, "Selected items")
  if #ui.names == 0 then
    U.warn("No profiles yet. Measure your libraries with Note Fixer - Measure Libraries first; profiles go to " .. R.profileFolder() .. ".")
  end
  if #ui.groups == 0 then
    U.dim("Select one or more MIDI items in the arrange view.")
    return
  end
  local items = { "Choose an instrument" }
  for _, n in ipairs(ui.names) do items[#items + 1] = n end
  local flags = ImGui.TableFlags_RowBg | ImGui.TableFlags_BordersInnerH | ImGui.TableFlags_SizingStretchProp
  if ImGui.BeginTable(ctx, "tracks", 3, flags) then
    ImGui.TableSetupColumn(ctx, "Track", ImGui.TableColumnFlags_WidthStretch, 2)
    ImGui.TableSetupColumn(ctx, "Instrument", ImGui.TableColumnFlags_WidthStretch, 3)
    ImGui.TableSetupColumn(ctx, "When no switch says", ImGui.TableColumnFlags_WidthStretch, 3)
    ImGui.TableHeadersRow(ctx)
    for gi, g in ipairs(ui.groups) do
      ImGui.PushID(ctx, gi)
      ImGui.TableNextRow(ctx)
      ImGui.TableNextColumn(ctx)
      ImGui.AlignTextToFramePadding(ctx)
      ImGui.Text(ctx, (g.name ~= "" and g.name or "Unnamed track") .. string.format(" (%d %s)", #g.items, #g.items == 1 and "item" or "items"))
      ImGui.TableNextColumn(ctx)
      local cur = 1
      for i, n in ipairs(ui.names) do if n == ui.choice[g.track] then cur = i + 1 end end
      local p = U.combo("##inst", items, cur, -1, "Instrument: the profiles to use for this track's notes.")
      if p then ui.choice[g.track] = p > 1 and ui.names[p - 1] or false; ui.fallback[g.track] = nil end
      ImGui.TableNextColumn(ctx)
      local profiles = ui.choice[g.track] and ui.profiles[ui.choice[g.track]]
      if profiles then
        local arts = { "Leave those notes alone" }
        for _, pr in ipairs(profiles) do arts[#arts + 1] = artLabel(pr) end
        local fb = ui.fallback[g.track] or (#profiles == 1 and 1 or 0)
        local q = U.combo("##fb", arts, fb + 1, -1,
          "When no switch says: the articulation for notes with no keyswitch, CC, program change or channel before them that matches a profile.")
        if q then ui.fallback[g.track] = q - 1 end
      end
      ImGui.PopID(ctx)
    end
    ImGui.EndTable(ctx)
  end
end

local function settingsSection()
  U.heading(2, "What to fix")
  local c, v = U.check("Move notes", st.timing, "Move notes: so each note's sound lands where it was written.")
  if c then st.timing = v; saveState() end
  ImGui.SameLine(ctx, 0, 20)
  ImGui.SetNextItemWidth(ctx, 160)
  c, v = U.edged(function() return ImGui.SliderInt(ctx, "Strength", st.strength, 0, 100, "%d%%") end)
  U.tip("Strength: how much of each note's measured delay to take away.")
  if c then st.strength = v; saveState() end
  ImGui.SameLine(ctx, 0, 20)
  c, v = U.int("Land after the grid (ms)", st.target, -50, 100, 110, "Land after the grid: put the sound this many ms after the written note instead of on it.")
  if c then st.target = v; saveState() end
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, "Even out volume with")
  ImGui.SameLine(ctx)
  local p = U.choice("vol", VOLUME, st.volume, VOLUME_TIPS)
  if p then st.volume = p; saveState() end
  c, v = U.number("Leave alone within (dB)", st.tolerance, 0, 12, 0.5, "%.1f", 110, "Leave alone within: differences smaller than this aren't corrected.")
  if c then st.tolerance = v; saveState() end
  ImGui.SameLine(ctx, 0, 20)
  c, v = U.text("Keyswitches at or below", st.ksmax, 70, "Keyswitches at or below: notes this low are treated as keyswitches, never moved on their own, as well as those the profiles name. Leave empty for none.")
  if c then st.ksmax = v; saveState() end
  if st.ksmax ~= "" and not U.parseNote(st.ksmax) then U.warn("Write the key as a note name, such as B0 (middle C is C3), or leave it empty.") end
end

local function frame()
  if reaper.time_precise() - ui.lastScan > 0.5 then scan(); ui.lastScan = reaper.time_precise() end
  itemsSection()
  settingsSection()
  U.heading(3, "Fix")
  if U.button("Fix Selected Items", false, "Fix Selected Items: move and even out the notes of every selected MIDI item. Undo puts them back.") then fix() end
  ImGui.SameLine(ctx, 0, 20)
  if U.button("Reload Profiles", false, "Reload Profiles: read the profiles folder again, after measuring more.") then
    loadProfiles()
    say("Found " .. #ui.names .. (#ui.names == 1 and " instrument." or " instruments."), false)
  end
  if ui.message then if ui.warn then U.warn(ui.message) else ImGui.TextWrapped(ctx, ui.message) end end
end

local function loop()
  ImGui.SetNextWindowSize(ctx, 760, 560, ImGui.Cond_FirstUseEver)
  ImGui.SetNextWindowBgAlpha(ctx, 1.0)
  U.pushTheme()
  local visible, open = ImGui.Begin(ctx, TITLE, true)
  if visible then
    frame()
    ImGui.End(ctx)
  end
  U.popTheme()
  if open and not ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then reaper.defer(loop) end
end

local function main()
  loadState()
  loadProfiles()
  ctx = ImGui.CreateContext(TITLE, ImGui.ConfigFlags_NavEnableKeyboard)
  U.init(ImGui, ctx)
  scan()
  reaper.defer(loop)
end

main()
