-- Stands in for ReaImGui's imgui.lua: dofile(path)("0.9") returns the mock.
local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
return function(version)
  assert(version == "0.9", "the scripts ask for ReaImGui's 0.9 API")
  return dofile(HERE .. "../imgui_mock.lua")
end
