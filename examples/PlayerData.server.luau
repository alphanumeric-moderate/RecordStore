--!strict

local PlayerDataCore = require(script.Parent.PlayerDataCore)

local controller = PlayerDataCore.new()
controller:Start()

game:BindToClose(function()
	controller:Shutdown()
end)
