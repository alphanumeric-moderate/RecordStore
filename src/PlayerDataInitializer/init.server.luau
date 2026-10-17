--!strict
--!optimize 2

local player_data = require(script.PlayerData)
local started = player_data:Start()

assert(started, "[PlayerDataInitializer] Controller is already started or shutting down")

game:BindToClose(function()
	player_data:Shutdown()
end)
