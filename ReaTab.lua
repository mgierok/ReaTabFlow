-- Existing shortcuts and toolbar buttons run the same action.
local _, filename = reaper.get_action_context()
local directory = filename:match("^(.*[/\\])") or ""
local command = reaper.AddRemoveReaScript(true, 0, directory .. "ReaTabFlow.lua", true)
if command ~= 0 then
  reaper.Main_OnCommand(command, 0)
else
  reaper.MB("Could not load ReaTabFlow.lua from the script directory.", "ReaTabFlow", 0)
end
