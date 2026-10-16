--!strict

-- This Script initializes the shared PlayerData module. Gameplay Scripts should
-- require ServerScriptService.PlayerData and call PlayerData.Set(...).
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))

PlayerData:Start()

game:BindToClose(function()
	PlayerData:Shutdown()
end)
