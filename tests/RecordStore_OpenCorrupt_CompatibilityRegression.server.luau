--!strict
-- Mock-only regression tests for RecordStore open corruption compatibility.
-- Place this Script under ServerScriptService and adjust the require path if needed.
-- Uses RecordStore.Mock only; it never reads or writes live DataStore records.

local RecordStore = require(game:GetService("ServerScriptService"):WaitForChild("RecordStore"))

local function assert_opened(result: RecordStore.ResultCode, message: string?, expected: string)
	assert(result == "loaded", ("%s: expected loaded, got %s: %s"):format(expected, result, message or "no message"))
end

-- Case 1: pre-v4 RecordStore_Reconstruction_v2/v3 envelope.
RecordStore.Mock.reset()
do
	local store_name = "RecordStore_CompatibilityRegression"
	local scope = "global"
	local key = "legacy-envelope-test"

	local seed_result, seed_message = RecordStore.Mock.seed_record_raw(store_name, scope, key, {
		__recordStore = "RecordStore",
		format = 1,
		revision = 7,
		fence = "old-string-fence",
		commitId = "old-commit-id",
		deleted = false,
		version = 0,
		data = { Coins = 123, Inventory = { "Sword", "Shield" } },
	})
	assert(seed_result == "success", seed_message or "failed to seed mock legacy record")

	local record = RecordStore.Mock.new(store_name, scope, key, { schema_version = 0 })
	local open_result, open_message = record:Open({ Coins = 0, Inventory = {} })
	assert_opened(open_result, open_message, "legacy envelope")

	local data = record:Get()
	assert(type(data) == "table", "legacy envelope data is not a table")
	assert(data.Coins == 123, "legacy Coins value was not preserved")
	assert(type(data.Inventory) == "table", "legacy Inventory value was not preserved")
	assert(data.Inventory[1] == "Sword" and data.Inventory[2] == "Shield", "legacy Inventory was not preserved")

	local raw = RecordStore.Mock.get_record_raw(store_name, scope, key)
	assert(type(raw) == "table", "no durable mock record after legacy Open")
	assert(raw.__recordStore == nil, "legacy envelope was not migrated")
	assert(raw.implementation_version == 1, "current envelope marker was not written")
	assert(raw.fencing_generation == 2, "expected old string-fence migration to acquire generation 2")
	assert(type(raw.data) == "table" and raw.data.Coins == 123, "migrated legacy data differs from source")
	local close_result, close_message = record:Close()
	assert(close_result == "closed", ("legacy envelope close failed: %s: %s"):format(close_result, close_message or "no message"))
end

-- Case 2: an inactive generation-zero baseline is accepted and fenced to generation 1.
RecordStore.Mock.reset()
do
	local store_name = "RecordStore_CompatibilityRegression"
	local scope = "global"
	local key = "generation-zero-current-test"
	local seed_result, seed_message = RecordStore.Mock.seed_record_raw(store_name, scope, key, {
		implementation_version = 1,
		schema_version = 1,
		revision = 4,
		fencing_generation = 0,
		created_at = 100,
		updated_at = 100,
		data = { Coins = 321, Inventory = { "Bow" } },
		user_ids = {},
		write_id = "generation-zero-baseline",
	})
	assert(seed_result == "success", seed_message or "failed to seed generation-zero baseline")

	local record = RecordStore.Mock.new(store_name, scope, key, { schema_version = 1 })
	local open_result, open_message = record:Open({ Coins = 0, Inventory = {} })
	assert_opened(open_result, open_message, "generation-zero current record")
	local data = record:Get()
	assert(type(data) == "table" and data.Coins == 321, "generation-zero data was not preserved")
	local raw = RecordStore.Mock.get_record_raw(store_name, scope, key)
	assert(type(raw) == "table" and raw.fencing_generation == 1, "generation-zero baseline was not advanced to generation 1")
	assert(type(raw.data) == "table" and raw.data.Coins == 321, "generation-zero durable data differs from source")
	local close_result, close_message = record:Close()
	assert(close_result == "closed", ("generation-zero close failed: %s: %s"):format(close_result, close_message or "no message"))
end

-- Case 3: corrupt current version is repaired from a valid historical generation-zero baseline.
RecordStore.Mock.reset()
do
	local store_name = "RecordStore_CompatibilityRegression"
	local scope = "global"
	local key = "generation-zero-history-test"
	local valid_baseline = {
		implementation_version = 1,
		schema_version = 1,
		revision = 9,
		fencing_generation = 0,
		created_at = 100,
		updated_at = 100,
		data = { Coins = 456, Inventory = { "Staff" } },
		user_ids = {},
		write_id = "historical-generation-zero-baseline",
	}
	local seed_result, seed_message = RecordStore.Mock.seed_record_raw(store_name, scope, key, valid_baseline)
	assert(seed_result == "success", seed_message or "failed to seed historical baseline")

	local corrupt_current = table.clone(valid_baseline)
	corrupt_current.fencing_generation = "invalid"
	corrupt_current.write_id = "corrupt-current-version"
	local corrupt_result, corrupt_message = RecordStore.Mock.seed_record_raw(store_name, scope, key, corrupt_current)
	assert(corrupt_result == "success", corrupt_message or "failed to seed corrupt current version")

	local record = RecordStore.Mock.new(store_name, scope, key, { schema_version = 1 })
	local open_result, open_message = record:Open({ Coins = 0, Inventory = {} })
	assert_opened(open_result, open_message, "historical generation-zero recovery")
	local data = record:Get()
	assert(type(data) == "table" and data.Coins == 456, "historical Coins value was not recovered")
	assert(type(data.Inventory) == "table" and data.Inventory[1] == "Staff", "historical Inventory was not recovered")
	local raw = RecordStore.Mock.get_record_raw(store_name, scope, key)
	assert(type(raw) == "table" and raw.fencing_generation == 1, "recovered record was not fenced to generation 1")
	assert(type(raw.data) == "table" and raw.data.Coins == 456, "recovered durable data differs from history")
	local close_result, close_message = record:Close()
	assert(close_result == "closed", ("recovered record close failed: %s: %s"):format(close_result, close_message or "no message"))
end

-- Case 4: migrate the previous `generation` / `payload` / `last_operation_id` envelope.
-- Its `format` field is the string marker `"RecordStore"`, not numeric version 1.
-- The current durable record's diagnostic showed no `lease` key, so this path
-- is safe to migrate. The production parser intentionally rejects this layout
-- when a legacy lease is present because it cannot safely reconstruct its token.
RecordStore.Mock.reset()
do
	local store_name = "RecordStore_CompatibilityRegression"
	local scope = "global"
	local key = "previous-envelope-shape-test"
	local seed_result, seed_message = RecordStore.Mock.seed_record_raw(store_name, scope, key, {
		implementation_version = 1,
		format = "RecordStore",
		schema_version = 1,
		revision = 13,
		generation = 7,
		created_at = 100,
		updated_at = 200,
		deleted = false,
		payload = { Coins = 789, Inventory = { "LegacySword" } },
		last_operation_id = "legacy-write-13",
		last_owner_job_id = "old-job",
		last_owner_place_id = 123,
		first_session_timestamp = 100,
		session_load_count = 4,
		user_ids = {},
	})
	assert(seed_result == "success", seed_message or "failed to seed previous envelope shape")

	local record = RecordStore.Mock.new(store_name, scope, key, { schema_version = 1 })
	local open_result, open_message = record:Open({ Coins = 0, Inventory = {} })
	assert_opened(open_result, open_message, "previous envelope shape")
	local data = record:Get()
	assert(type(data) == "table" and data.Coins == 789, "previous envelope Coins value was not preserved")
	assert(type(data.Inventory) == "table" and data.Inventory[1] == "LegacySword", "previous envelope Inventory was not preserved")
	local raw = RecordStore.Mock.get_record_raw(store_name, scope, key)
	assert(type(raw) == "table" and raw.fencing_generation == 8, "legacy generation was not advanced to 8")
	assert(type(raw.data) == "table" and raw.data.Coins == 789, "legacy payload was not migrated to data")
	assert(raw.write_id ~= "legacy-write-13", "open did not write a new canonical envelope")
	local close_result, close_message = record:Close()
	assert(close_result == "closed", ("previous envelope close failed: %s: %s"):format(close_result, close_message or "no message"))
end

-- Case 5: never migrate an older envelope whose ownership lease is still present.
RecordStore.Mock.reset()
do
	local store_name = "RecordStore_CompatibilityRegression"
	local scope = "global"
	local key = "previous-envelope-with-lease-test"
	local seed_result, seed_message = RecordStore.Mock.seed_record_raw(store_name, scope, key, {
		implementation_version = 1,
		format = "RecordStore",
		schema_version = 1,
		revision = 14,
		generation = 8,
		created_at = 100,
		updated_at = 200,
		deleted = false,
		payload = { Coins = 999 },
		last_operation_id = "legacy-write-14",
		lease = { expires_at = 300 },
	})
	assert(seed_result == "success", seed_message or "failed to seed legacy lease fixture")
	local record = RecordStore.Mock.new(store_name, scope, key, { schema_version = 1, retry_attempts = 1 })
	local open_result, open_message = record:Open({ Coins = 0 })
	assert(open_result == "corrupt", ("legacy lease fixture must fail closed, got %s: %s"):format(open_result, open_message or "no message"))
	assert(string.find(open_message or "", "ownership state cannot be verified", 1, true) ~= nil, "legacy lease rejection did not explain the safety reason")
	local raw = RecordStore.Mock.get_record_raw(store_name, scope, key)
	assert(type(raw) == "table" and raw.generation == 8 and raw.payload ~= nil, "legacy lease record was modified despite refusing migration")
end

RecordStore.Mock.reset()

do
	local store_name = "RecordStore_UpdateSaveReopenRegression"
	local scope = "global"
	local key = "updated-kills-reopen-test"
	local record = RecordStore.Mock.new(store_name, scope, key, { schema_version = 1 })
	local open_result, open_message = record:Open({ Kills = 100 })
	assert(open_result == "created" or open_result == "loaded", ("initial open failed: %s: %s"):format(open_result, open_message or "no message"))
	local update_result, update_message = record:Update(function(data)
		assert(type(data) == "table", "update data is not a table")
		return { Kills = 250 }
	end)
	assert(update_result == "success", ("Kills update failed: %s: %s"):format(update_result, update_message or "no message"))
	local save_result, save_message = record:Save()
	assert(save_result == "saved", ("save failed: %s: %s"):format(save_result, save_message or "no message"))
	local close_result, close_message = record:Close()
	assert(close_result == "closed", ("close failed: %s: %s"):format(close_result, close_message or "no message"))
	local reopen_result, reopen_message = record:Open({ Kills = 0 })
	assert(reopen_result == "loaded", ("reopen failed: %s: %s"):format(reopen_result, reopen_message or "no message"))
	local data = record:Get()
	assert(type(data) == "table" and data.Kills == 250, "updated Kills value did not survive save, close, and reopen")
	local final_close_result, final_close_message = record:Close()
	assert(final_close_result == "closed", ("final close failed: %s: %s"):format(final_close_result, final_close_message or "no message"))
end

RecordStore.Mock.reset()
do
	local store_name = "RecordStore_CloseExternalMutationRegression"
	local scope = "global"
	local key = "direct-data-close-test"
	local record = RecordStore.Mock.new(store_name, scope, key, { schema_version = 1 })
	local open_result, open_message = record:Open({ Kills = 100 })
	assert(open_result == "created" or open_result == "loaded", ("initial direct-mutation open failed: %s: %s"):format(open_result, open_message or "no message"))
	assert(type(record.Data) == "table", "public Data table is unavailable")
	record.Data.Kills = 300
	local close_result, close_message = record:Close()
	assert(close_result == "closed", ("close did not capture direct Data mutation: %s: %s"):format(close_result, close_message or "no message"))
	local reopen_result, reopen_message = record:Open({ Kills = 0 })
	assert(reopen_result == "loaded", ("direct-mutation reopen failed: %s: %s"):format(reopen_result, reopen_message or "no message"))
	local data = record:Get()
	assert(type(data) == "table" and data.Kills == 300, "direct Data mutation made before close did not survive reopen")
	local final_close_result, final_close_message = record:Close()
	assert(final_close_result == "closed", ("final direct-mutation close failed: %s: %s"):format(final_close_result, final_close_message or "no message"))
end

RecordStore.Mock.reset()
do
	local store_name = "RecordStore_ValidatorInputIsolationRegression"
	local record = RecordStore.Mock.new(store_name, "global", "validator-input-test", {
		schema_version = 1,
		validator = function(value)
			if type(value) == "table" and value.Kills == 300 then
				value.Kills = 999
			end
			return true
		end,
	})
	local open_result, open_message = record:Open({ Kills = 100 })
	assert(open_result == "created" or open_result == "loaded", ("validator-isolation open failed: %s: %s"):format(open_result, open_message or "no message"))
	record.Data.Kills = 300
	local data = record:Get()
	assert(type(data) == "table" and data.Kills == 300, "validator mutation leaked into RecordStore state during external Data validation")
end

RecordStore.Mock.reset()
RecordStore.Mock.reset()
do
	local record = RecordStore.Mock.new("RecordStore_ChangeEventDiffRegression", "global", "nested-change", { schema_version = 1 })
	local open_result, open_message = record:Open({ Alpha = { Value = 1 }, Beta = 2 })
	assert(open_result == "created" or open_result == "loaded", open_message)
	local events: { RecordStore.ChangeEvent } = {}
	local subscription, subscribe_result, subscribe_message = record:SubscribeChanges(function(event)
		events[#events + 1] = event
	end)
	assert(subscription ~= nil and subscribe_result == "success", subscribe_message)
	local update_result, update_message = record:Update(function(_data)
		return { Alpha = { Value = 3 }, Beta = 2 }
	end)
	assert(update_result == "success", update_message)
	task.wait()
	assert(#events == 1, ("expected one nested change event, got %d"):format(#events))
	assert(#events[1].Path == 2 and events[1].Path[1] == "Alpha" and events[1].Path[2] == "Value", "nested change event path changed")
	assert(events[1].OldValue == 1 and events[1].NewValue == 3, "nested change event values changed")
	subscription:Disconnect()
	assert(record:Close() == "closed", "change-event test record did not close")
end

RecordStore.Mock.reset()

print("[PASS] Corruption compatibility, save/reopen persistence, close mutation capture, and validator input isolation.")

