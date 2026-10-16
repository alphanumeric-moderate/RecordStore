--!strict
--!optimize 2
-- Shared server-side PlayerData controller.
-- Require this ModuleScript from the initializer and gameplay scripts so all
-- callers share one session map and one persistence queue.

local PlayerDataCore = require(script.Parent.PlayerDataCore)

return PlayerDataCore.new()
