--!strict
-- Safe PlayerData.Set integration regression. RecordStore.Mock is injected so
-- this test never reads or writes live DataStoreService records.

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local RecordStore = require(ServerScriptService.RecordStore)
local PlayerDataCore = require(ServerScriptService.PlayerDataCore)
local controller = PlayerDataCore.new({
	RecordStore = RecordStore.Mock,
})

local test_ok, test_error = pcall(function()
	assert(controller:Start(), "PlayerData controller failed to start")

	local player = Players:GetPlayers()[1]
	if player == nil then
		player = Players.PlayerAdded:Wait()
	end

	local deadline = os.clock() + 20
	while os.clock() < deadline do
		local status = player:GetAttribute("PlayerDataLoadStatus")
		if status == "Loaded" then
			break
		end
		assert(status ~= "Failed", "PlayerData failed to load the test player")
		assert(player.Parent == Players, "test player left before loading completed")
		task.wait(0.05)
	end
	assert(
		player:GetAttribute("PlayerDataLoadStatus") == "Loaded",
		"timed out waiting for PlayerData to load"
	)

	local set_kills, kills_error = controller.Set(player, "kills", 12500124)
	assert(set_kills, kills_error)
	local player_data_values = player:FindFirstChild("PlayerDataValues")
	assert(player_data_values ~= nil, "PlayerDataValues folder was not created")
	local kills_backing = player_data_values:FindFirstChild("kills")
	assert(kills_backing ~= nil and kills_backing:IsA("NumberValue"), "kills backing value is missing")
	assert((kills_backing :: NumberValue).Value == 12500124, "Set did not update the kills backing value")

	local equipped_ok, equipped_error = controller.Set(player, "equipped", "Hi")
	assert(equipped_ok, equipped_error)
	local leaderstats = player:FindFirstChild("leaderstats")
	assert(leaderstats ~= nil, "leaderstats folder was not created")
	local kills_display = leaderstats:FindFirstChild("Kills")
	local equipped_display = leaderstats:FindFirstChild("Equipped")
	assert(kills_display ~= nil and kills_display:IsA("StringValue"), "formatted Kills display is not a StringValue")
	assert(equipped_display ~= nil and equipped_display:IsA("StringValue"), "Equipped display is missing")
	assert((equipped_display :: StringValue).Value == "Hi", "Set did not update the Equipped display")

	local admin_ok, admin_error = controller.Set(player, "admin", true)
	assert(admin_ok, admin_error)
	local invalid_type_ok = controller.Set(player, "admin", "true")
	assert(not invalid_type_ok, "Set accepted a string for the boolean admin field")
	local unknown_key_ok = controller.Set(player, "missing", 1)
	assert(not unknown_key_ok, "Set accepted an unknown data field")

	local display_deadline = os.clock() + 3
	while os.clock() < display_deadline and (kills_display :: StringValue).Value ~= "12.5M" do
		task.wait(0.05)
	end
	assert((kills_display :: StringValue).Value == "12.5M", "formatted Kills display did not refresh")

	-- Shutdown flushes pending edits before closing; reopen the same mock key to
	-- verify the public API's writes actually reached the persistent record.
	assert(controller:Shutdown(), "PlayerData controller failed to shut down")
	local verification_record = RecordStore.Mock.new(
		"PlayerData_Test1",
		"global",
		"Player_" .. tostring(player.UserId),
		{ schema_version = 1 }
	)
	local open_result, open_message = verification_record:Open({})
	assert(open_result == "loaded" or open_result == "created", open_message)
	local persisted = verification_record:Get()
	assert(persisted.kills == 12500124, "kills was not persisted")
	assert(persisted.equipped == "Hi", "equipped was not persisted")
	assert(persisted.admin == true, "non-leaderstat admin field was not persisted")
	local close_result, close_message = verification_record:Close()
	assert(close_result == "closed" or close_result == "fenced", close_message)
end)

controller:Shutdown()
if not test_ok then
	error(tostring(test_error), 0)
end

print("[PlayerData.Set] integration regression passed")
