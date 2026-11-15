--[[
 * ReaScript Name: Note Fixer - Measure Libraries
 * Description:    Plays every key of your sample libraries at several
 *                 dynamics, articulation by articulation, and notes down how
 *                 late and how loud each one really sounds. The results are
 *                 profiles that Note Fixer - Fix Selected Items (and the Note
 *                 Position & Volume Fixer page) use to fix your parts.
 *
 * About:          Load a patch on any track, select the track and press Add
 *                 Instrument From Selected Track. List its articulations and
 *                 how each is chosen (keyswitch, CC, program change or MIDI
 *                 channel). Press Measure All: each instrument is played on a
 *                 new track, rendered offline, measured and removed.
 *
 *                 Needs ReaImGui, from the ReaTeam Extensions repository.
 * Author:         Kallum Shah
 * Links:          https://github.com/KallumS/Note-Position-Volume-Fixer
 * Version:        1.1
 * Provides:
 *   npvf_json.lua
 *   npvf_measure.lua
 *   npvf_maps.lua
 *   npvf_fix.lua
 *   npvf_reaper.lua
 *   npvf_ui.lua
--]]

local TITLE = "Note Fixer - Measure Libraries"
local VERSION = "1.1"
local SECTION = "NoteFixerMeasure"

local imgui_path = reaper.ImGui_GetBuiltinPath and (reaper.ImGui_GetBuiltinPath() .. "/imgui.lua")
if not imgui_path then
  reaper.MB("Note Fixer needs the ReaImGui extension.\n\nInstall it with ReaPack, from the ReaTeam Extensions repository.", TITLE, 0)
  return
end
local ImGui = dofile(imgui_path)("0.9")

local HERE = ({ reaper.get_action_context() })[2]:match("^(.*[/\\])")
local J = dofile(HERE .. "npvf_json.lua")
local M = dofile(HERE .. "npvf_measure.lua")
local Maps = dofile(HERE .. "npvf_maps.lua")
local R = dofile(HERE .. "npvf_reaper.lua").init(J)
local U = dofile(HERE .. "npvf_ui.lua")

local ctx

------------------------------------------------------------------------------
-- State
------------------------------------------------------------------------------

local SWITCHES = { "None", "Keyswitch", "CC", "Program change", "MIDI channel" }
local SWITCH_KEYS = { "none", "keyswitch", "cc", "program", "channel" }
local DYNAMICS = { "Velocity", "CC1 (mod wheel)" }

local st = {
  low = "C0", high = "C6", levels = "30, 60, 90, 120", takes = 2,
  wait = 15, leaveOut = true, skip = true, keep = false, align = 1,
}
local SAVED = { "low", "high", "levels", "takes", "wait", "leaveOut", "skip", "keep", "align" }

local ui = {
  instruments = {}, sel = 1, log = {}, status = "", running = false, stop = false,
  progress = 0, message = nil, warn = false,
}

local function saveState()
  local parts = {}
  for _, k in ipairs(SAVED) do parts[#parts + 1] = k .. "=" .. tostring(st[k]) end
  reaper.SetExtState(SECTION, "state", table.concat(parts, ";"), true)
end
local function loadState()
  local blob = reaper.GetExtState(SECTION, "state")
  for pair in (blob or ""):gmatch("[^;]+") do
    local k, v = pair:match("^(%w+)=(.*)$")
    if k and st[k] ~= nil then
      if type(st[k]) == "number" then st[k] = tonumber(v) or st[k]
      elseif type(st[k]) == "boolean" then st[k] = (v == "true")
      else st[k] = v end
    end
  end
  ui.instruments = R.loadInstruments()
end
local function saveInstruments()
  local ok, err = R.saveInstruments(ui.instruments)
  if not ok then ui.message, ui.warn = "Couldn't save the instrument list: " .. tostring(err), true end
end

local STOP = {} -- raised inside the run when Stop is pressed mid-measurement

local function say(text, warn) ui.message, ui.warn = text, warn end
local function log(text, warn) ui.log[#ui.log + 1] = { text = text, warn = warn } end

--- The test settings, checked. Returns options or nil, what to fix.
local function testOptions()
  local low, high = U.parseNote(st.low), U.parseNote(st.high)
  if not low or not high or high < low then return nil, "Write the keys as note names, such as C0 and C6, lowest first." end
  local levels, seen = {}, {}
  for n in st.levels:gmatch("%d+") do
    n = tonumber(n)
    if n >= 1 and n <= 127 and not seen[n] then seen[n] = true; levels[#levels + 1] = n end
  end
  table.sort(levels)
  if #levels == 0 then return nil, "Write at least one level between 1 and 127." end
  return { low = low, high = high, levels = levels, takes = math.max(1, math.min(8, st.takes)) }
end

--- A hand-made articulation's single switch (Switch, Value, CC columns).
local function switchOf(a)
  local t = SWITCH_KEYS[a.switch or 1]
  if t == "none" then return nil end
  local v
  if t == "keyswitch" then v = U.parseNote(a.value) else v = tonumber(a.value) end
  if not v then return nil, t end
  return { type = t, value = v, cc = t == "cc" and (tonumber(a.cc) or 32) or nil }
end

--- What chooses an articulation: its outputs and channel - from a map as imported, or from its single switch.
local function outputsOf(a)
  if a.send then return a.send, a.channel end
  local sw, bad = switchOf(a)
  if bad then return nil, nil, bad end
  if not sw then return {}, nil end
  if sw.type == "keyswitch" then return { { kind = "note", pitch = sw.value, vel = 100 } }, nil end
  if sw.type == "cc" then return { { kind = "cc", cc = sw.cc, value = sw.value } }, nil end
  if sw.type == "program" then return { { kind = "program", value = sw.value } }, nil end
  return {}, sw.value -- MIDI channel
end

--- Every key this instrument's articulations use as a keyswitch: the test never plays them.
local function keyswitchKeys(inst)
  local keys = {}
  for _, a in ipairs(inst.articulations) do
    local send = outputsOf(a)
    for _, o in ipairs(send or {}) do if o.kind == "note" then keys[o.pitch] = true end end
  end
  return keys
end

------------------------------------------------------------------------------
-- The run: a coroutine, resumed every frame, so the window stays alive
------------------------------------------------------------------------------

local function wait(seconds, what)
  local untilT = reaper.time_precise() + seconds
  while reaper.time_precise() < untilT do
    if ui.stop then return false end
    ui.status = what .. string.format(" (%d s)", math.ceil(untilT - reaper.time_precise()))
    coroutine.yield()
  end
  return true
end

local function jobs(opts)
  local list = {}
  for _, inst in ipairs(ui.instruments) do
    if inst.include ~= false then
      local arts = inst.articulations
      if #arts == 0 then arts = { { name = "", switch = 1, dynamics = 1 } } end
      local todo = {}
      for _, a in ipairs(arts) do
        local path = R.profilePath(inst.name, a.name, inst.library)
        if a.include ~= false and not (st.skip and R.readFile(path)) then todo[#todo + 1] = a end
      end
      if #todo > 0 then list[#list + 1] = { inst = inst, arts = todo } end
    end
  end
  return list
end

local function run()
  local opts, err = testOptions()
  if not opts then say(err, true); return end
  local list = jobs(opts)
  local total = 0
  for _, j in ipairs(list) do total = total + #j.arts end
  if total == 0 then say("Nothing to measure: every articulation already has a profile. Untick Skip ones already measured to measure them again.", false); return end
  ui.log, ui.running, ui.stop, ui.progress = {}, true, false, 0
  say(nil)
  local at = reaper.GetProjectLength(0) + 10
  local done, saved, leftovers = 0, 0, {}
  local track, render
  local function cleanup()
    if render then local f = R.discardRender(render, st.keep); if f then leftovers[#leftovers + 1] = f end; render = nil end
    if track then reaper.DeleteTrack(track); track = nil end
  end
  local co = coroutine.create(function()
    for _, j in ipairs(list) do
      local inst = j.inst
      ui.status = "Putting " .. inst.name .. " on a new track"
      coroutine.yield()
      local tr, e = R.makeTestTrack(inst, st.leaveOut)
      if not tr then log(e, true) else
        track = tr
        if not wait(st.wait, "Waiting for " .. inst.name .. " to load its samples") then break end
        for _, a in ipairs(j.arts) do
          if ui.stop then break end
          local label = inst.name .. (a.name ~= "" and (" - " .. a.name) or "")
          local send, outChannel, bad = outputsOf(a)
          if bad then
            log(label .. ": its " .. SWITCHES[a.switch] .. " has no value, so it was skipped.", true)
          else
            local cc1 = (a.dynamics or 1) == 2
            local layout = M.testLayout({
              low = opts.low, high = opts.high, levels = opts.levels, takes = opts.takes,
              send = send, outChannel = outChannel, skip = keyswitchKeys(inst), dynamics = cc1 and "cc1" or "velocity",
            })
            local res, fs
            for attempt = 1, 2 do
              ui.status = "Rendering " .. label
              coroutine.yield()
              local rnd, re = R.renderTest(track, layout, at)
              if not rnd then log(label .. ": " .. re, true); break end
              render, fs = rnd, rnd.fs
              local slice = reaper.time_precise()
              local got = M.measure(render.read, render.fs, layout.notes,
                { alignTo = st.align == 2 and "start" or "attack", dynamics = cc1 and "cc1" or "velocity" },
                function(i, n)
                  if ui.stop then error(STOP) end
                  ui.status = "Measuring " .. label .. string.format(": note %d of %d", i, n)
                  ui.progress = (done + i / n) / total
                  if reaper.time_precise() - slice > 0.05 then coroutine.yield(); slice = reaper.time_precise() end
                end)
              local left = R.discardRender(render, st.keep)
              if left then leftovers[#leftovers + 1] = left end
              render = nil
              if not res or got.stats.found > res.stats.found then res = got end
              -- Mostly silent the first time: perhaps still loading. (Keys outside a patch's range are silent too,
              -- so a second try that hears no more is taken as the patch's range.)
              if ui.stop or res.stats.found >= res.stats.notes * 0.8 then break end
              if attempt == 1 then
                log(label .. ": only " .. res.stats.found .. " of " .. res.stats.notes .. " notes were heard. Waiting longer and trying again.", true)
                if not wait(st.wait, "Waiting for " .. inst.name .. " to load its samples") then break end
              end
            end
            if res and not ui.stop then
              if res.stats.found < 6 then
                log(label .. ": only " .. res.stats.found .. " of " .. res.stats.notes .. " notes were heard, so no profile was saved. " ..
                  "Check the articulation's switch, the key range, and that the patch makes sound on its own.", true)
              else
                local testOpts = {}
                for k, v in pairs(layout.options) do if k ~= "skip" then testOpts[k] = v end end
                local skipped = {}
                for k in pairs(layout.options.skip or {}) do skipped[#skipped + 1] = k end
                table.sort(skipped)
                testOpts.keyswitchKeysSkipped = skipped
                -- profiles before 1.1 had one `switch`: still written where one output says it all, for older scripts
                local legacy
                if #send == 1 and not outChannel then
                  local o = send[1]
                  legacy = o.kind == "note" and { type = "keyswitch", value = o.pitch, vel = o.vel }
                    or o.kind == "cc" and { type = "cc", cc = o.cc, value = o.value } or { type = "program", value = o.value }
                elseif #send == 0 and outChannel then legacy = { type = "channel", value = outChannel } end
                local prof = M.learnProfile(res, {
                  instrument = inst.name, library = inst.library, articulation = a.name, plugin = inst.plugin, switch = legacy,
                  send = send, outChannel = outChannel, program = a.program, category = a.category, source = a.source,
                  test = testOpts, sampleRate = fs, measuredBy = TITLE .. " " .. VERSION,
                })
                local path, we = R.saveProfile(prof)
                if path then
                  saved = saved + 1
                  local odd = {}
                  for _, k in ipairs(prof.summary.offKeys) do odd[#odd + 1] = U.noteName(k) end
                  local range = prof.range.low <= prof.range.high and (" Plays " .. U.noteName(prof.range.low) .. " to " .. U.noteName(prof.range.high) .. ".") or ""
                  log(string.format("%s: %d of %d notes, heard %.0f to %.0f ms late.%s%s", label, res.stats.found, res.stats.notes,
                    res.stats.minMs, res.stats.maxMs, range,
                    #odd > 0 and (" Keys 1.5 dB or more off: " .. table.concat(odd, ", ", 1, math.min(#odd, 12)) .. (#odd > 12 and "…" or "") .. ".") or ""))
                else
                  log(label .. ": couldn't save the profile: " .. tostring(we), true)
                end
              end
            end
          end
          done = done + 1
          ui.progress = done / total
        end
        reaper.DeleteTrack(track)
        track = nil
      end
      if ui.stop then break end
    end
  end)
  ui.co = co
  ui.finish = function(errText)
    cleanup()
    ui.running, ui.co = false, nil
    if errText then log("Stopped by an error: " .. errText, true) end
    local msg = (ui.stop and "Stopped. " or "Done. ") .. saved .. (saved == 1 and " profile" or " profiles") .. " saved to " .. R.profileFolder() .. "."
    if #leftovers > 0 then msg = msg .. " " .. #leftovers .. " test renders couldn't be deleted; they are in the project's media folder." end
    say(msg, errText ~= nil)
    ui.status = ""
    reaper.UpdateArrange()
  end
end

local function step()
  if not ui.co then return end
  local ok, err = coroutine.resume(ui.co)
  if not ok then ui.finish(err ~= STOP and tostring(err) or nil)
  elseif coroutine.status(ui.co) == "dead" then ui.finish() end
end

------------------------------------------------------------------------------
-- The window
------------------------------------------------------------------------------

local function playerHint(plugin)
  local p = (plugin or ""):lower()
  if p:find("sine") then return "SINE: choose how articulations switch in the instrument's settings (keyswitch, CC, program change or MIDI channel), then match it here." end
  if p:find("kontakt") then return "Kontakt: most libraries switch with keyswitches; some use a CC or MIDI channels. The library's manual lists them." end
  if p:find("spitfire") or p:find("bbc") or p:find("labs") then return "Spitfire: with UACC on, CC32 chooses the articulation (the manual lists the values); keyswitches also work." end
  if p:find("engine") then return "Engine: keyswitches or program changes, as the instrument is set up." end
  if p:find("synchron") or p:find("vienna") or p:find("vsl") then return "Synchron Player: keyswitches or CCs, as the preset's Dimension Tree is set up." end
  return nil
end

local function instrumentsSection()
  U.heading(1, "Instruments")
  U.dim("Load a patch on any track, select that track, and add it. Each test plays the instrument on a new track, which is removed afterwards.")
  if U.button("Add Instrument From Selected Track", false, "Add Instrument From Selected Track: remembers the selected track's instrument and the patch loaded in it.") then
    local inst, e = R.captureSelectedTrack()
    if inst then
      table.insert(ui.instruments, inst)
      ui.sel = #ui.instruments
      saveInstruments()
      say("Added " .. inst.name .. ". Now list its articulations.", false)
    else
      say(e, true)
    end
  end
  if #ui.instruments == 0 then return end
  local flags = ImGui.TableFlags_RowBg | ImGui.TableFlags_BordersInnerH | ImGui.TableFlags_SizingStretchProp
  if ImGui.BeginTable(ctx, "instruments", 5, flags) then
    ImGui.TableSetupColumn(ctx, "Measure", ImGui.TableColumnFlags_WidthFixed, 70)
    ImGui.TableSetupColumn(ctx, "Name", ImGui.TableColumnFlags_WidthStretch, 3)
    ImGui.TableSetupColumn(ctx, "Plug-in", ImGui.TableColumnFlags_WidthStretch, 2)
    ImGui.TableSetupColumn(ctx, "Articulations", ImGui.TableColumnFlags_WidthFixed, 100)
    ImGui.TableSetupColumn(ctx, "", ImGui.TableColumnFlags_WidthFixed, 150)
    ImGui.TableHeadersRow(ctx)
    local remove
    for i, inst in ipairs(ui.instruments) do
      ImGui.PushID(ctx, i)
      ImGui.TableNextRow(ctx)
      ImGui.TableNextColumn(ctx)
      local c, v = U.check("##inc", inst.include ~= false, "Measure: include this instrument when you press Measure All.")
      if c then inst.include = v; saveInstruments() end
      ImGui.TableNextColumn(ctx)
      local ch, name = U.text("##name", inst.name, -1, "Name: what its profiles are called. Name it after the patch.")
      if ch and name ~= "" then inst.name = name; saveInstruments() end
      ImGui.TableNextColumn(ctx)
      ImGui.Text(ctx, inst.plugin or "")
      ImGui.TableNextColumn(ctx)
      ImGui.Text(ctx, tostring(#inst.articulations))
      ImGui.TableNextColumn(ctx)
      if U.button("Edit", i == ui.sel, "Edit: show this instrument's articulations below.") then ui.sel = i end
      ImGui.SameLine(ctx)
      if U.button("Remove", false, "Remove: forget this instrument. Its profiles stay.") then remove = i end
      ImGui.PopID(ctx)
    end
    ImGui.EndTable(ctx)
    if remove and reaper.MB("Remove " .. ui.instruments[remove].name .. " from the list? Profiles already measured are kept.", TITLE, 4) == 6 then
      table.remove(ui.instruments, remove)
      ui.sel = math.min(ui.sel, #ui.instruments)
      saveInstruments()
    end
  end
end

--- Bring in a map's articulations: keyswitches and the rest, names, and a guess at dynamics.
local function importBank(inst, map, bankIndex, path)
  local bank = map.banks[bankIndex]
  if #inst.articulations > 0 and reaper.MB("Replace " .. inst.name .. "'s " .. #inst.articulations ..
      " articulations with the " .. #bank.articulations .. " in " .. (bank.name ~= "" and bank.name or "this map") .. "?", TITLE, 4) ~= 6 then
    return
  end
  local file = path:match("([^/\\]+)$") or path
  local source = ({ cubase = "Cubase expression map", logic = "Logic articulation set", reaticulate = "Reaticulate bank" })[map.format] .. ": " .. file ..
    (#map.banks > 1 and (" (" .. bank.name .. ")") or "")
  inst.articulations = {}
  for _, art in ipairs(bank.articulations) do
    table.insert(inst.articulations, {
      name = art.name, send = art.send, channel = art.channel, program = art.program, category = art.category,
      include = art.include, dynamics = art.dynamics, source = source, imported = true,
    })
  end
  if (not inst.library or inst.library == "") and bank.group then inst.library = bank.group:match("^([^/]+)") end
  saveInstruments()
  local on = 0
  for _, a in ipairs(inst.articulations) do if a.include then on = on + 1 end end
  say("Imported " .. #inst.articulations .. " articulations from " .. file .. "; " .. on ..
    " ticked to measure. Check each one's dynamics: velocity for short notes, CC1 for long notes on the mod wheel.", false)
end

local function importMap(inst)
  local path = R.askForFile("Import articulations (Cubase .expressionmap, Logic .plist, Reaticulate .reabank)", "")
  if not path then return end
  local text = R.readFile(path)
  if not text then say("Couldn't read " .. path .. ".", true); return end
  local map, err = Maps.parse(text, path)
  if not map then say(err, true); return end
  if #map.banks == 1 then importBank(inst, map, 1, path)
  else ui.pending = { map = map, path = path, bank = Maps.bestBank(map, inst.name) } end
end

local function articulationsSection()
  local inst = ui.instruments[ui.sel]
  if not inst then return end
  U.heading(2, "Articulations of " .. inst.name)
  local hint = playerHint(inst.plugin)
  if hint then U.dim(hint) end
  local c, v = U.text("Library", inst.library or "", 260, "Library: the collection it comes from, such as Spitfire BBC Symphony Orchestra. Profiles are named and filed with it.")
  if c then inst.library = v; saveInstruments() end
  if U.button("Import Articulations…", false, "Import Articulations: read the keyswitches (and CCs, program changes and channels) from a BabylonWaves Art Conductor map for Cubase or Logic, any Cubase expression map, Logic articulation set or Reaticulate bank.") then
    importMap(inst)
  end
  ImGui.SameLine(ctx, 0, 20)
  if U.button("Tick All", false, "Tick All: measure every articulation.") then for _, a in ipairs(inst.articulations) do a.include = true end saveInstruments() end
  ImGui.SameLine(ctx, 0, 12)
  if U.button("Untick All", false, "Untick All: measure none, then tick the ones you want.") then for _, a in ipairs(inst.articulations) do a.include = false end saveInstruments() end

  if ui.pending then
    local names = {}
    for i, b in ipairs(ui.pending.map.banks) do names[i] = b.name .. " (" .. #b.articulations .. ")" end
    U.dim("This file has " .. #names .. " instruments. Choose the one for " .. inst.name .. ".")
    local p = U.combo("##bank", names, ui.pending.bank, 360, "Instrument: which of the file's banks to import.")
    if p then ui.pending.bank = p end
    ImGui.SameLine(ctx, 0, 12)
    if U.button("Import This One", false, "Import This One: bring in the chosen bank's articulations.") then
      local pend = ui.pending
      ui.pending = nil
      importBank(inst, pend.map, pend.bank, pend.path)
    end
    ImGui.SameLine(ctx, 0, 12)
    if U.button("Cancel", false, "Cancel: import nothing.") then ui.pending = nil end
  end

  U.dim("Keyswitches are note names (middle C is C3). Long notes whose dynamics come from the mod wheel should use CC1 for dynamics. With none listed, the patch is measured as it is.")
  local remove
  local flags = ImGui.TableFlags_RowBg | ImGui.TableFlags_BordersInnerH | ImGui.TableFlags_SizingStretchProp
  if #inst.articulations > 0 and ImGui.BeginTable(ctx, "arts", 7, flags) then
    ImGui.TableSetupColumn(ctx, "Measure", ImGui.TableColumnFlags_WidthFixed, 70)
    ImGui.TableSetupColumn(ctx, "Name", ImGui.TableColumnFlags_WidthStretch, 3)
    ImGui.TableSetupColumn(ctx, "Switch", ImGui.TableColumnFlags_WidthFixed, 170)
    ImGui.TableSetupColumn(ctx, "Value", ImGui.TableColumnFlags_WidthFixed, 90)
    ImGui.TableSetupColumn(ctx, "CC", ImGui.TableColumnFlags_WidthFixed, 90)
    ImGui.TableSetupColumn(ctx, "Dynamics", ImGui.TableColumnFlags_WidthFixed, 170)
    ImGui.TableSetupColumn(ctx, "", ImGui.TableColumnFlags_WidthFixed, 90)
    ImGui.TableHeadersRow(ctx)
    for i, a in ipairs(inst.articulations) do
      ImGui.PushID(ctx, i)
      ImGui.TableNextRow(ctx)
      ImGui.TableNextColumn(ctx)
      c, v = U.check("##m", a.include ~= false, "Measure: include this articulation when you press Measure All.")
      if c then a.include = v; saveInstruments() end
      ImGui.TableNextColumn(ctx)
      c, v = U.text("##n", a.name, -1, "Name: the articulation, as you'd like the profile called.")
      if c then a.name = v; saveInstruments() end
      ImGui.TableNextColumn(ctx)
      if a.send then
        -- from a map: shown in words, across the Switch, Value and CC columns
        ImGui.AlignTextToFramePadding(ctx)
        ImGui.Text(ctx, Maps.describe(a) .. (a.program and ("  (Reaticulate " .. a.program .. ")") or ""))
        U.tip("Switch: what the map sends to choose it" .. (a.source and (", from " .. a.source) or "") .. ".")
        ImGui.TableNextColumn(ctx)
        ImGui.TableNextColumn(ctx)
      else
        local p = U.combo("##s", SWITCHES, a.switch or 1, -1, "Switch: how the patch chooses this articulation.")
        if p then a.switch = p; saveInstruments() end
        ImGui.TableNextColumn(ctx)
        local t = SWITCH_KEYS[a.switch or 1]
        if t ~= "none" then
          c, v = U.text("##v", a.value or "", -1, t == "keyswitch" and "Value: the keyswitch, such as C-1." or (t == "channel" and "Value: the MIDI channel, 1 to 16." or "Value: the number sent, 0 to 127."))
          if c then a.value = v; saveInstruments() end
          if switchOf(a) == nil then ImGui.SameLine(ctx, 0, 4); U.warn("?") end
        end
        ImGui.TableNextColumn(ctx)
        if t == "cc" then
          c, v = U.text("##cc", a.cc or "32", -1, "CC: the controller number. Spitfire's UACC is 32.")
          if c then a.cc = v; saveInstruments() end
        end
      end
      ImGui.TableNextColumn(ctx)
      local p = U.combo("##d", DYNAMICS, a.dynamics or 1, -1, "Dynamics: what the test steps through - velocity for short notes, CC1 for long notes played on the mod wheel.")
      if p then a.dynamics = p; saveInstruments() end
      ImGui.TableNextColumn(ctx)
      if U.button("Remove", false, "Remove this articulation.") then remove = i end
      ImGui.PopID(ctx)
    end
    ImGui.EndTable(ctx)
  end
  if remove then table.remove(inst.articulations, remove); saveInstruments() end
  if U.button("Add Articulation", false, "Add Articulation: a row for one more articulation of this patch.") then
    table.insert(inst.articulations, { name = "Articulation " .. (#inst.articulations + 1), switch = 2, value = "", cc = "32", dynamics = 1, include = true })
    saveInstruments()
  end
end

local function testSection()
  U.heading(3, "The test")
  local c, v
  c, v = U.text("Lowest key", st.low, 70, "Lowest key: the first key played, such as C0.")
  if c then st.low = v; saveState() end
  ImGui.SameLine(ctx, 0, 20)
  c, v = U.text("Highest key", st.high, 70, "Highest key: the last key played, such as C6.")
  if c then st.high = v; saveState() end
  ImGui.SameLine(ctx, 0, 20)
  c, v = U.text("Levels", st.levels, 150, "Levels: the velocities (or CC1 values) played on every key.")
  if c then st.levels = v; saveState() end
  ImGui.SameLine(ctx, 0, 20)
  c, v = U.int("Takes", st.takes, 1, 8, 100, "Takes: how many times each note is played. Two or more catch round robins.")
  if c then st.takes = v; saveState() end
  c, v = U.int("Seconds to load samples", st.wait, 0, 600, 110, "Seconds to load samples: how long to wait after loading an instrument before playing it. Big patches need longer.")
  if c then st.wait = v; saveState() end
  ImGui.SameLine(ctx, 0, 20)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, "Line up")
  ImGui.SameLine(ctx)
  local p = U.choice("align", { "The Attack", "The Start of Any Sound" }, st.align,
    { "The attack: where the note is heard, 12 dB below its first peak.", "The start of any sound: the first sound the sample makes." })
  if p then st.align = p; saveState() end
  c, v = U.check("Leave out effects after the instrument", st.leaveOut, "Leave out effects after the instrument: reverb and the like are switched off while measuring.")
  if c then st.leaveOut = v; saveState() end
  ImGui.SameLine(ctx, 0, 20)
  c, v = U.check("Skip ones already measured", st.skip, "Skip ones already measured: articulations with a profile already are left out, so a stopped run can carry on.")
  if c then st.skip = v; saveState() end
  ImGui.SameLine(ctx, 0, 20)
  c, v = U.check("Keep the test renders", st.keep, "Keep the test renders: leave the rendered audio in the project's media folder.")
  if c then st.keep = v; saveState() end
  local opts, err = testOptions()
  if not opts then U.warn(err) else
    local per = M.testSeconds(opts)
    -- which articulations still need measuring: looked up now and then, not every frame
    if not ui.countAt or reaper.time_precise() - ui.countAt > 2 then
      ui.count = 0
      for _, j in ipairs(jobs(opts)) do ui.count = ui.count + #j.arts end
      ui.countAt = reaper.time_precise()
    end
    local count = ui.count
    local total = per * count
    U.dim(string.format("Each articulation plays %d notes, %d:%02d of audio. %d to measure: %d h %02d min of audio, which REAPER renders faster than it plays.",
      (opts.high - opts.low + 1) * #opts.levels * opts.takes, per // 60, math.floor(per % 60), count, total // 3600, math.floor(total % 3600 / 60)))
  end
end

local function runSection()
  U.heading(4, "Measure")
  if ui.running then
    if U.button("Stop", false, "Stop: finish the note being measured, remove the test track and stop.") then ui.stop = true end
  else
    if U.button("Measure All", false, "Measure All: play, render and measure every ticked instrument's articulations, one after another.") then run() end
  end
  ImGui.SameLine(ctx, 0, 20)
  if U.button("Copy Profiles Folder", false, "Copy Profiles Folder: puts the folder's location on the clipboard.") then
    ImGui.SetClipboardText(ctx, R.profileFolder())
    say("Copied " .. R.profileFolder(), false)
  end
  if reaper.CF_ShellExecute then
    ImGui.SameLine(ctx, 0, 12)
    if U.button("Show Profiles Folder", false, "Show Profiles Folder: opens it in Finder or Explorer.") then reaper.CF_ShellExecute(R.profileFolder()) end
  end
  if ui.running then
    ImGui.ProgressBar(ctx, ui.progress, -1, 0, string.format("%d%%", math.floor(ui.progress * 100)))
    ImGui.TextWrapped(ctx, ui.status)
  end
  if ui.message then if ui.warn then U.warn(ui.message) else ImGui.TextWrapped(ctx, ui.message) end end
  for _, l in ipairs(ui.log) do if l.warn then U.warn(l.text) else U.dim(l.text) end end
end

local function frame()
  ImGui.BeginDisabled(ctx, ui.running)
  instrumentsSection()
  articulationsSection()
  testSection()
  ImGui.EndDisabled(ctx)
  runSection()
end

local function loop()
  step()
  ImGui.SetNextWindowSize(ctx, 900, 820, ImGui.Cond_FirstUseEver)
  ImGui.SetNextWindowBgAlpha(ctx, 1.0)
  U.pushTheme()
  local visible, open = ImGui.Begin(ctx, TITLE, true)
  if visible then
    frame()
    ImGui.End(ctx)
  end
  U.popTheme()
  if open and not (ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) and not ui.running) then
    reaper.defer(loop)
  elseif ui.running then
    ui.stop = true
    while ui.co do step() end
  end
end

local function main()
  loadState()
  ctx = ImGui.CreateContext(TITLE, ImGui.ConfigFlags_NavEnableKeyboard)
  U.init(ImGui, ctx)
  reaper.defer(loop)
end

main()
