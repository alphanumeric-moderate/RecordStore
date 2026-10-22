--!nocheck
local Shim = require("./RobloxShim")
local FakeDataStore = require("./FakeDataStore")

local fake = FakeDataStore.new()
Shim.set_service("DataStoreService", fake.service)
local RecordStore = Shim.load()

local STORE = "RecordStore_ProductionAdapterBenchmark"
local SCOPE = "global"
local PROFILE_COUNT = 20
local UPDATE_COUNT = 4

local function options()
	return {
		schema_version = 1,
		autosave_interval = 1000,
		lease_duration = 180,
		lease_renewal = 60,
		operation_deadline = 2,
		retry_attempts = 2,
		budget_wait = 0.01,
		messaging_enabled = false,
		takeover_enabled = false,
		durable_queue_enabled = false,
	}
end

local function make_profile()
	local inventory = table.create(48)
	for index = 1, 48 do
		inventory[index] = {
			Id = ("item-%03d"):format(index),
			Count = index % 7 + 1,
			Stats = { Attack = index % 13, Defense = index % 11 },
		}
	end
	return {
		Coins = 0,
		Level = 1,
		Inventory = inventory,
		Stats = { Wins = 3, Losses = 1, Playtime = 600 },
		Settings = { Music = true, Effects = true },
	}
end

local recovery_checks = 0
for index = 1, PROFILE_COUNT do
	local key = "player-" .. tostring(index)
	local record = RecordStore.new(STORE, SCOPE, key, options())
	local open_result, open_message = record:Open(make_profile())
	assert(open_result == "created", tostring(open_message))

	for step = 1, UPDATE_COUNT do
		local update_result, update_message = record:Update(function(data)
			data.Coins += step * 11
			data.Stats.Playtime += 1
			local inventory = table.clone(data.Inventory)
			local slot = (index * 7 + step) % #inventory + 1
			local item = table.clone(inventory[slot])
			item.Count += 1
			inventory[slot] = item
			data.Inventory = inventory
			return data
		end)
		assert(update_result == "success", tostring(update_message))
	end

	local expected_revision = record:GetRevision() + 1
	local fresh_reads_before = fake.control:metrics().fresh_get_calls
	if index % 5 == 0 then
		fake.control:fail_next_update("commit_then_error")
	end
	local save_result, save_message = record:Save("production-adapter-benchmark")
	assert(save_result == "saved", tostring(save_message))
	local durable = fake.control:get_raw(STORE, SCOPE, key)
	assert(durable.revision == expected_revision, "save created an unexpected revision count")
	assert(durable.data.Coins == UPDATE_COUNT * (UPDATE_COUNT + 1) / 2 * 11,
		"save lost the accumulated profile mutations")
	if index % 5 == 0 then
		assert(fake.control:metrics().fresh_get_calls > fresh_reads_before,
			"ambiguous save did not perform authoritative read-back verification")
		recovery_checks += 1
	end

	assert(record:Close() == "closed", "production adapter close failed")
	local reopen_result, reopen_message = record:Open(make_profile())
	assert(reopen_result == "loaded", tostring(reopen_message))
	assert(record:Get().Coins == durable.data.Coins, "reopen returned a different durable profile")
	assert(record:Close() == "closed", "production adapter final close failed")
end

local metrics = fake.control:metrics()
assert(metrics.active_requests == 0, "benchmark left fake requests in flight")
assert(metrics.max_active_requests <= 4, "production request cap was exceeded")
assert(recovery_checks == math.floor(PROFILE_COUNT / 5), "not all ambiguous-save paths were measured")
print(("[production-adapter-benchmark] profiles=%d updates=%d recovery-checks=%d max-in-flight=%d"):format(
	PROFILE_COUNT,
	PROFILE_COUNT * UPDATE_COUNT,
	recovery_checks,
	metrics.max_active_requests
))
Shim.close()
