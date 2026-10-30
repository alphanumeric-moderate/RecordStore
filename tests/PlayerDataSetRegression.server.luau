--!strict
-- Safe PlayerData.Set integration regression. RecordStore.Mock is injected so
-- this test never reads or writes live DataStoreService records.

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local RecordStore = require(ServerScriptService.RecordStore)
local PlayerDataCore = require(ServerScriptService.PlayerDataCore)

local zero_dirty_age_ok = pcall(function()
	PlayerDataCore.new({
		RecordStore = RecordStore.Mock,
		MaxDirtyAgeSeconds = 0,
	})
end)
assert(not zero_dirty_age_ok,
	"PlayerDataCore must reject MaxDirtyAgeSeconds = 0 instead of silently using its default")
local mock_record_store: any = table.clone(RecordStore.Mock)
local mock_record_store_new = RecordStore.Mock.new
local captured_record_options: { [string]: any }? = nil
local scheduler_enabled = false
local scheduler_policy: { [string]: any } = {
	revision = 1,
	algorithm = "drr",
	shadow_algorithm = "weighted",
	shadow_enabled = false,
	shadow_sample_rate = 0,
}
local scheduler_rollout: { [string]: any } = {
	revision = 1,
	percent = 100,
	salt = "recordstore-scheduler-v1",
}

mock_record_store.new = function(name: string, scope: string, key: string, options: { [string]: any })
	captured_record_options = table.clone(options)
	return mock_record_store_new(name, scope, key, options)
end
mock_record_store.get_scheduler_snapshot = function()
	return {
		enabled = scheduler_enabled,
		policy = table.clone(scheduler_policy),
		rollout = table.clone(scheduler_rollout),
	}
end
mock_record_store.configure_scheduler_policy = function(patch: { [string]: any })
	assert(type(patch.revision) == "number" and patch.revision > scheduler_policy.revision)
	for key, value in pairs(patch) do
		scheduler_policy[key] = value
	end
	return "success", nil
end
mock_record_store.configure_scheduler_rollout = function(patch: { [string]: any })
	assert(patch.revision == scheduler_rollout.revision + 1)
	for key, value in pairs(patch) do
		scheduler_rollout[key] = value
	end
	return "success", nil
end
mock_record_store.set_scheduler_enabled = function(enabled: boolean)
	scheduler_enabled = enabled
	return true, nil
end

local controller = PlayerDataCore.new({
	RecordStore = mock_record_store,
})

local test_ok, test_error = pcall(function()
	assert(controller:Start(), "PlayerData controller failed to start")
	assert(scheduler_enabled, "PlayerDataCore did not enable the advanced scheduler")
	assert(scheduler_policy.algorithm == "drr", "PlayerDataCore did not configure DRR scheduling")
	assert(scheduler_policy.shadow_algorithm == "weighted", "PlayerDataCore did not configure weighted shadow scheduling")
	assert(scheduler_policy.shadow_enabled == true and scheduler_policy.shadow_sample_rate == 0.1,
		"PlayerDataCore did not enable 10% scheduler shadow comparisons")
	assert(scheduler_rollout.percent == 100 and scheduler_rollout.salt == "playerdatacore-scheduler-v1",
		"PlayerDataCore did not configure its scheduler rollout")
	local record_options = captured_record_options
	assert(record_options ~= nil, "PlayerDataCore did not create a RecordStore session")
	assert(record_options.messaging_enabled == true, "RecordStore session messaging must be enabled")
	assert(record_options.takeover_enabled == true, "RecordStore session takeover must be enabled")
	assert(record_options.durable_queue_enabled == false,
		"the legacy queue must remain disabled without a PlayerDataCore queue handler")
	assert(record_options.transactional_operations_enabled == false,
		"transactions must remain disabled until the reconciliation race is fixed")

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

	local recovery_record = RecordStore.Mock.new(
		"PlayerData_Test1",
		"global",
		"Player_" .. tostring(player.UserId),
		{ schema_version = 1 }
	)
	local flush_deadline = os.clock() + 5
	while os.clock() < flush_deadline do
		local stats = recovery_record:Stats()
		if not recovery_record:IsDirty() and stats.busy == 0 and stats.queue_busy == 0 then
			break
		end
		task.wait(0.05)
	end
	assert(not recovery_record:IsDirty(), "PlayerData changes did not become durable before recovery test")
	local user_ids_result, user_ids_message = recovery_record:SetUserIds({ player.UserId })
	assert(user_ids_result == "success", user_ids_message)
	RecordStore.Mock.set_update_commit_then_failures(1)
	RecordStore.Mock.set_get_failures(1)
	local unknown_result = recovery_record:Save("playerdata-mutation-backpressure")
	assert(unknown_result == "unknown", "injected uncertain save did not enter unknown state")
	RecordStore.Mock.set_get_failures(100, "hold unknown state for mutation test")
	local current_status = recovery_record:GetDurabilityStatus()
	assert(current_status.ownership == "uncertain", "mutation fixture did not retain uncertain ownership")
	local live_player_data_values = player:FindFirstChild("PlayerDataValues")
	assert(live_player_data_values ~= nil and live_player_data_values.Parent == player,
		"test could not find the live PlayerDataValues folder")
	local live_kills_backing = live_player_data_values:FindFirstChild("kills")
	assert(live_kills_backing ~= nil and live_kills_backing:IsA("NumberValue"),
		"test could not find the live kills backing value")
	local backing_value = live_kills_backing :: NumberValue
	assert(live_player_data_values:FindFirstChild("kills") == backing_value,
		"test must mutate the live RecordStore-managed kills backing value")
	local previous_kills = backing_value.Value
	local observed_uncertain_change = false
	local change_connection = backing_value.Changed:Connect(function()
		if recovery_record.State == "unknown" then observed_uncertain_change = true end
	end)
	backing_value.Value = previous_kills + 1
	task.wait(0.05)
	change_connection:Disconnect()
	assert(observed_uncertain_change, "backing value did not emit a change while ownership remained uncertain")
	assert(backing_value.Value == previous_kills,
		"PlayerData backing value mutation must be reverted while record ownership is uncertain")
	local blocked_set = controller.Set(player, "kills", previous_kills + 2)
	assert(not blocked_set, "PlayerData.Set must reject mutation while record ownership is uncertain")
	RecordStore.Mock.set_get_failures(0)
	local recovery_result, recovery_message = RecordStore.Mock.reconcile(recovery_record)
	assert(recovery_result == "success", recovery_message)

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

	local legacy_record = RecordStore.Mock.get_record_raw(
		"PlayerData_Test1",
		"global",
		"Player_" .. tostring(player.UserId)
	) :: { [string]: any }
	local legacy_data = legacy_record.data :: { [string]: any }
	legacy_data.admin = nil
	legacy_record.data = legacy_data
	local seed_result, seed_message = RecordStore.Mock.seed_record_raw(
		"PlayerData_Test1",
		"global",
		"Player_" .. tostring(player.UserId),
		legacy_record
	)
	assert(seed_result == "success", seed_message)

	local deferred_callbacks: { () -> () } = {}
	local controlled_task: any = {
		spawn = task.spawn,
		wait = task.wait,
		defer = function(callback: (...any) -> (), ...: any)
			local args = table.pack(...)
			deferred_callbacks[#deferred_callbacks + 1] = function()
				callback(table.unpack(args, 1, args.n))
			end
			return nil
		end,
	}
	local pressure_controller = PlayerDataCore.new({
		RecordStore = RecordStore.Mock,
		DurabilityMode = "read_only_on_risk",
		MaxDirtyAgeSeconds = 0.5,
		task = controlled_task,
	})
	player:SetAttribute("PlayerDataLoadStatus", "NotLoaded")
	assert(pressure_controller:Start(), "durability backpressure controller failed to start")
	local pressure_load_deadline = os.clock() + 10
	while os.clock() < pressure_load_deadline
		and player:GetAttribute("PlayerDataLoadStatus") ~= "Loaded"
	do
		task.wait(0.05)
	end
	assert(player:GetAttribute("PlayerDataLoadStatus") == "Loaded",
		"durability backpressure controller failed to reload the test player")

	local pressure_values = player:FindFirstChild("PlayerDataValues")
	assert(pressure_values ~= nil, "durability backpressure values folder is missing")
	local pressure_kills_instance = pressure_values:FindFirstChild("kills")
	assert(pressure_kills_instance ~= nil and pressure_kills_instance:IsA("NumberValue"),
		"durability backpressure kills value is missing")
	local pressure_kills = pressure_kills_instance :: NumberValue
	local pressure_baseline = pressure_kills.Value
	local first_buffered_ok, first_buffered_message = pressure_controller.Set(
		player, "kills", pressure_baseline + 1
	)
	assert(first_buffered_ok, first_buffered_message)
	assert(pressure_kills.Value == pressure_baseline + 1,
		"the first mutation should be accepted into the pending buffer")

	task.wait(0.6)
	local stale_buffer_set_ok, stale_buffer_set_message = pressure_controller.Set(
		player, "kills", pressure_baseline + 2
	)
	assert(not stale_buffer_set_ok,
		"Set must reject additional mutations after pending PlayerData changes exceed the dirty-age limit")
	assert(string.find(tostring(stale_buffer_set_message), "pending PlayerData changes", 1, true) ~= nil,
		"Set should identify pending-buffer age as the backpressure reason")

	pressure_kills.Value = pressure_baseline + 3
	task.wait(0.05)
	assert(pressure_kills.Value == pressure_baseline + 1,
		"Value.Changed must restore a mutation after pending PlayerData changes exceed the dirty-age limit")
	assert(pressure_controller:Shutdown(), "durability backpressure controller failed to shut down")

	local pressure_verification = RecordStore.Mock.new(
		"PlayerData_Test1",
		"global",
		"Player_" .. tostring(player.UserId),
		{ schema_version = 1 }
	)
	local pressure_open_result, pressure_open_message = pressure_verification:Open({})
	assert(pressure_open_result == "loaded" or pressure_open_result == "created", pressure_open_message)
	local pressure_persisted = pressure_verification:Get() :: { [string]: RecordStore.JsonValue }
	assert(pressure_persisted.kills == pressure_baseline + 1,
		"backpressure must preserve and flush the earlier accepted pending mutation")
	assert(pressure_persisted.admin == false,
		"read-only flush must first persist the already-accepted dirty schema-normalization snapshot")
	local pressure_close_result, pressure_close_message = pressure_verification:Close()
	assert(pressure_close_result == "closed" or pressure_close_result == "fenced", pressure_close_message)
end)

controller:Shutdown()
if not test_ok then
	error(tostring(test_error), 0)
end

print("[PlayerData.Set] integration regression passed")
