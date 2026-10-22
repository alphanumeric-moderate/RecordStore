--!nocheck
local task = require("@lune/task")
local datetime = require("@lune/datetime")
local process = require("@lune/process")
local Shim = require("./RobloxShim")
local FakeDataStore = require("./FakeDataStore")

local fake = FakeDataStore.new()
Shim.set_service("DataStoreService", fake.service)
local RecordStore = Shim.load()

local STORE = "RecordStore_ProductionAdapterSafety"
local SCOPE = "global"
local function options()
	return {
		schema_version = 1,
		autosave_interval = 1000,
		lease_duration = 180,
		lease_renewal = 60,
		operation_deadline = 2,
		retry_attempts = 1,
		budget_wait = 0.01,
		messaging_enabled = false,
		takeover_enabled = false,
		durable_queue_enabled = false,
	}
end

local function new_record(key)
	return RecordStore.new(STORE, SCOPE, key, options())
end

local function assert_open(record, expected, label)
	local result, message = record:Open({ coins = 10, nested = { marker = "initial" } })
	assert(result == expected, ("%s: expected %s, got %s (%s)"):format(
		label, expected, tostring(result), tostring(message)
	))
end

local function wait_for(predicate, timeout, label)
	local deadline = os.clock() + timeout
	repeat
		if predicate() then
			return true
		end
		task.wait(0.02)
	until os.clock() >= deadline
	assert(predicate(), label .. " timed out")
	return true
end

local function test_budget_exhaustion_never_reaches_the_backend()
	fake.control:set_budget("StandardRead", 0)
	fake.control:set_budget("StandardWrite", 0)
	local record = new_record("budget-recovery")
	local before = fake.control:metrics()
	local result = record:Open({ coins = 1 })
	assert(result ~= "created" and result ~= "loaded",
		"record acquisition succeeded with no request budget")
	local after = fake.control:metrics()
	assert(after.update_calls == before.update_calls,
		"budget exhaustion still issued an UpdateAsync request")
	assert(after.get_calls == before.get_calls,
		"budget exhaustion still issued a GetAsync request")

	fake.control:set_budget("StandardRead", math.huge)
	fake.control:set_budget("StandardWrite", math.huge)
	local retry, retry_message = record:Open({ coins = 1 })
	assert(retry == "created" or retry == "loaded",
		("record did not recover after budgets returned: %s (%s)"):format(tostring(retry), tostring(retry_message)))
	assert(record:Close() == "closed", "budget recovery fixture did not close")
end

local function test_durable_round_trip_preserves_metadata_and_user_ids()
	local record = new_record("metadata-round-trip")
	assert_open(record, "created", "initial production adapter open")
	local update_result, update_message = record:Update(function(data)
		data.coins = 25
		data.nested.marker = "durable"
		return data
	end)
	assert(update_result == "success", tostring(update_message))
	local ids_result, ids_message = record:SetUserIds({ 123456, 654321 })
	assert(ids_result == "success", tostring(ids_message))
	local metadata_result, metadata_message = record:SetMetadata({
		origin = "production-adapter-regression",
		counter = 7,
	})
	assert(metadata_result == "success", tostring(metadata_message))
	local updates_before_cycle = fake.control:metrics().update_calls
	local cyclic_result = record:Update(function(data)
		data.cycle = data
		return data
	end)
	assert(cyclic_result == "validation", "cyclic application data was not rejected")
	assert(fake.control:metrics().update_calls == updates_before_cycle,
		"cyclic application data triggered a durable write")
	local visible_after_cycle = record:Get()
	assert(visible_after_cycle.cycle == nil and visible_after_cycle.coins == 25,
		"rejected cyclic mutation changed canonical in-memory data")
	local save_result, save_message = record:Save("metadata-round-trip")
	assert(save_result == "saved", tostring(save_message))

	local raw = fake.control:get_raw(STORE, SCOPE, "metadata-round-trip")
	assert(type(raw) == "table" and type(raw.data) == "table", "production adapter did not persist an envelope")
	assert(raw.data.coins == 25 and raw.data.nested.marker == "durable",
		"production adapter persisted a stale profile snapshot")
	local info = fake.control:get_key_info(STORE, SCOPE, "metadata-round-trip")
	assert(info ~= nil, "production adapter did not preserve key information")
	local stored_ids = info:GetUserIds()
	assert(#stored_ids == 2 and stored_ids[1] == 123456 and stored_ids[2] == 654321,
		"UpdateAsync did not preserve the requested user IDs")
	local stored_metadata = info:GetMetadata()
	assert(stored_metadata.origin == "production-adapter-regression" and stored_metadata.counter == 7,
		"UpdateAsync did not preserve application metadata")

	assert(record:Close() == "closed", "metadata fixture failed to close")
	local reopen_result, reopen_message = record:Open({ coins = 0, nested = { marker = "default" } })
	assert(reopen_result == "loaded", tostring(reopen_message))
	local loaded = record:Get()
	assert(loaded.coins == 25 and loaded.nested.marker == "durable",
		"data changed after close and reopen through the production adapter")
	assert(record:GetMetadata().origin == "production-adapter-regression",
		"application metadata was lost after reopening")
	assert(record:Close() == "closed", "metadata fixture failed its final close")
end

local function test_replayed_transform_and_commit_then_error_do_not_duplicate_a_revision()
	local record = new_record("commit-then-error")
	assert_open(record, "created", "commit-then-error open")
	local update_result, update_message = record:Update(function(data)
		data.coins = 30
		return data
	end)
	assert(update_result == "success", tostring(update_message))
	local base_revision = record:GetRevision()
	local before = fake.control:metrics()
	fake.control:replay_next_update(2)
	fake.control:fail_next_update("commit_then_error")
	local save_result, save_message = record:Save("ambiguous-committed-write")
	assert(save_result == "saved", tostring(save_message))

	local raw = fake.control:get_raw(STORE, SCOPE, "commit-then-error")
	assert(raw.revision == base_revision + 1, "ambiguous committed save duplicated or skipped a revision")
	assert(raw.write_id ~= nil and raw.data.coins == 30, "ambiguous committed save lost its operation or snapshot")
	local after = fake.control:metrics()
	assert(after.transform_calls >= before.transform_calls + 3,
		"UpdateAsync transform replay fixture did not actually replay the callback")
	assert(after.fresh_get_calls > before.fresh_get_calls,
		"ambiguous write was not followed by a fresh authoritative read")
	assert(record:GetRevision() == base_revision + 1, "local revision differs from the one confirmed durable revision")
	assert(record:Close() == "closed", "commit-then-error fixture failed to close")
end

local function test_unknown_commit_is_fenced_then_reconciled_without_data_loss()
	local record = new_record("unknown-committed-write")
	assert_open(record, "created", "unknown-commit open")
	local update_result, update_message = record:Update(function(data)
		data.coins = 40
		return data
	end)
	assert(update_result == "success", tostring(update_message))
	local base_revision = record:GetRevision()
	fake.control:fail_next_update("commit_then_error")
	fake.control:fail_next_get(100)
	local save_result = record:Save("unknown-committed-write")
	assert(save_result == "unknown", "commit with lost response and failed verification did not remain unknown")
	local unknown_status = record:GetDurabilityStatus()
	assert(unknown_status.ownership == "uncertain", "unknown commit did not fence uncertain ownership")
	assert(unknown_status.pending_operation_id ~= nil, "unknown commit lost its stable operation ID")
	assert(unknown_status.dirty_watermark > unknown_status.durable_watermark,
		"unknown commit incorrectly marked the new state fully durable")

	local durable_before_reconcile = fake.control:get_raw(STORE, SCOPE, "unknown-committed-write")
	assert(durable_before_reconcile.revision == base_revision + 1,
		"fault fixture failed to commit exactly one durable revision")
	assert(durable_before_reconcile.data.coins == 40, "ambiguous committed snapshot was lost")
	local blocked = record:Update(function(data)
		data.coins = 999
		return data
	end)
	assert(blocked == "fenced", "ordinary mutation was admitted while the save outcome was unknown")

	fake.control:fail_next_get(0)
	wait_for(function()
		local status = record:GetDurabilityStatus()
		return status.ownership == "owned" and status.durability == "clean"
	end, 4, "unknown commit reconciliation")
	local resolved = fake.control:get_raw(STORE, SCOPE, "unknown-committed-write")
	assert(resolved.write_id == unknown_status.pending_operation_id,
		"reconciliation did not confirm the original operation identity")
	assert(resolved.revision == base_revision + 1, "reconciliation duplicated a committed write")
	assert(resolved.data.coins == 40, "reconciliation lost or replaced the committed snapshot")
	assert(record:GetRevision() == base_revision + 1, "confirmed revision did not advance exactly once")
	assert(record:Close() == "closed", "reconciled commit fixture failed to close")
end

local function test_uncommitted_unknown_write_retries_the_original_operation()
	local record = new_record("unknown-uncommitted-write")
	assert_open(record, "created", "unknown-uncommitted open")
	local update_result, update_message = record:Update(function(data)
		data.coins = 50
		return data
	end)
	assert(update_result == "success", tostring(update_message))
	local base_revision = record:GetRevision()
	fake.control:fail_next_update("before_commit")
	fake.control:fail_next_get(100)
	local save_result = record:Save("unknown-uncommitted-write")
	assert(save_result == "unknown", "failed write with unavailable verification did not remain unknown")
	local status = record:GetDurabilityStatus()
	local operation_id = status.pending_operation_id
	assert(operation_id ~= nil, "uncommitted unknown write lost its operation identity")
	local before = fake.control:get_raw(STORE, SCOPE, "unknown-uncommitted-write")
	assert(before.revision == base_revision, "before-commit fault changed durable revision")
	assert(before.data.coins == 10, "before-commit fault overwrote durable data")

	fake.control:fail_next_get(0)
	wait_for(function()
		local durability = record:GetDurabilityStatus()
		return durability.ownership == "owned" and durability.durability == "clean"
	end, 4, "unknown uncommitted write reconciliation")
	local after = fake.control:get_raw(STORE, SCOPE, "unknown-uncommitted-write")
	assert(after.write_id == operation_id, "reconciliation generated a new operation ID")
	assert(after.revision == base_revision + 1, "reconciliation failed to commit exactly once")
	assert(after.data.coins == 50, "reconciliation did not commit the retained snapshot")
	assert(record:Close() == "closed", "reconciled uncommitted fixture failed to close")
end

local function test_stale_fence_cannot_overwrite_a_replacement_owner()
	local record = new_record("stale-owner-fence")
	assert_open(record, "created", "stale-owner open")
	local update_result, update_message = record:Update(function(data)
		data.coins = 60
		return data
	end)
	assert(update_result == "success", tostring(update_message))

	local replacement = fake.control:get_raw(STORE, SCOPE, "stale-owner-fence")
	local replacement_generation = replacement.fencing_generation + 1
	local replacement_revision = replacement.revision + 1
	replacement.fencing_generation = replacement_generation
	replacement.revision = replacement_revision
	replacement.updated_at = datetime.now().unixTimestampMillis / 1000
	replacement.write_id = "external-replacement-owner-write"
	replacement.session = {
		token = "replacement-owner-token",
		generation = replacement_generation,
		job_id = "replacement-server",
		place_id = 999,
		acquired_at = replacement.updated_at,
		lease_until = replacement.updated_at + 600,
	}
	replacement.data = { coins = 777, nested = { marker = "replacement-owner" } }
	fake.control:replace_raw(STORE, SCOPE, "stale-owner-fence", replacement)

	local stale_save = record:Save("stale-owner-must-not-write")
	assert(stale_save == "fenced", "stale owner was not fenced by the replacement generation")
	local durable = fake.control:get_raw(STORE, SCOPE, "stale-owner-fence")
	assert(durable.write_id == "external-replacement-owner-write",
		"stale save replaced the newer owner's operation ID")
	assert(durable.fencing_generation == replacement_generation,
		"stale save rolled back the fencing generation")
	assert(durable.revision == replacement_revision, "stale save changed the replacement revision")
	assert(durable.data.coins == 777 and durable.data.nested.marker == "replacement-owner",
		"stale save overwrote the replacement owner's profile")
	assert(durable.session.token == "replacement-owner-token",
		"stale save modified the replacement session token")
end

local function test_future_implementation_envelope_is_never_rewritten()
	local key = "future-implementation-envelope"
	local now = datetime.now().unixTimestampMillis / 1000
	local future = {
		implementation_version = 999,
		schema_version = 1,
		revision = 12,
		fencing_generation = 7,
		created_at = now - 60,
		updated_at = now,
		data = { coins = 711 },
		user_ids = { 123456 },
		write_id = "future-implementation-write",
	}
	fake.control:replace_raw(STORE, SCOPE, key, future)
	local before_info = fake.control:get_key_info(STORE, SCOPE, key)
	local record = new_record(key)
	local result = record:Open({ coins = 0 })
	assert(result == "future_schema", "unsupported implementation version was not rejected")
	local after = fake.control:get_raw(STORE, SCOPE, key)
	local after_info = fake.control:get_key_info(STORE, SCOPE, key)
	assert(after.implementation_version == 999 and after.revision == 12,
		"unsupported implementation envelope was rewritten")
	assert(after.write_id == "future-implementation-write" and after.data.coins == 711,
		"unsupported implementation data was overwritten")
	assert(before_info.Version == after_info.Version,
		"unsupported implementation envelope created a new durable version")
end

local function test_oversized_profile_is_rejected_before_any_durable_write()
	local record = new_record("oversized-profile")
	local before = fake.control:metrics()
	local open_result, open_message = record:Open({
		coins = 1,
		oversized = string.rep("x", 4_194_400),
	})
	assert(open_result == "validation",
		("oversized profile was not rejected by validation: %s (%s)"):format(
			tostring(open_result), tostring(open_message)
		))
	local after = fake.control:metrics()
	assert(after.update_calls == before.update_calls,
		"oversized profile attempted a DataStore write before validation")
	assert(fake.control:get_raw(STORE, SCOPE, "oversized-profile") == nil,
		"oversized profile created a partial durable envelope")
end

local function test_concurrent_production_adapter_work_stays_within_global_request_cap()
	fake.control:set_delay(0.003)
	local count = 16
	local records = {}
	for index = 1, count do
		records[index] = new_record("parallel-" .. tostring(index))
	end

	local completed = 0
	local failures = {}
	for index, record in ipairs(records) do
		task.spawn(function()
			local ok, failure = pcall(function()
				local open_result, open_message = record:Open({
					coins = index,
					nested = { index = index },
				})
				assert(open_result == "created" or open_result == "loaded", tostring(open_message))
				local update_result, update_message = record:Update(function(data)
					data.coins += 100
					return data
				end)
				assert(update_result == "success", tostring(update_message))
				local save_result, save_message = record:Save("parallel-save")
				assert(save_result == "saved", tostring(save_message))
				assert(record:Close() == "closed", "parallel record did not close")
			end)
			if not ok then
				failures[#failures + 1] = tostring(index) .. ": " .. tostring(failure)
			end
			completed += 1
		end)
	end

	wait_for(function() return completed == count end, 8, "parallel production adapter stress")
	assert(#failures == 0, "parallel adapter failures: " .. table.concat(failures, " | "))
	local metrics = fake.control:metrics()
	assert(metrics.max_active_requests <= 4,
		("global request cap exceeded: maximum in-flight requests was %d"):format(metrics.max_active_requests))
	assert(metrics.active_requests == 0, "production adapter left requests marked in flight")
	for index = 1, count do
		local raw = fake.control:get_raw(STORE, SCOPE, "parallel-" .. tostring(index))
		assert(type(raw) == "table" and type(raw.data) == "table", "parallel record disappeared")
		assert(raw.data.coins == index + 100, "parallel saved value was lost or overwritten")
	end
	fake.control:set_delay(0)
end

local suite_ok, suite_error = pcall(function()
	test_budget_exhaustion_never_reaches_the_backend()
	test_durable_round_trip_preserves_metadata_and_user_ids()
	test_replayed_transform_and_commit_then_error_do_not_duplicate_a_revision()
	test_unknown_commit_is_fenced_then_reconciled_without_data_loss()
	test_uncommitted_unknown_write_retries_the_original_operation()
	test_stale_fence_cannot_overwrite_a_replacement_owner()
	test_future_implementation_envelope_is_never_rewritten()
	test_oversized_profile_is_rejected_before_any_durable_write()
	test_concurrent_production_adapter_work_stays_within_global_request_cap()

	local metrics = fake.control:metrics()
	assert(metrics.active_requests == 0, "test suite ended with in-flight fake requests")
	print(("[production-adapter-safety] requests=%d transforms=%d max-in-flight=%d passed"):format(
		metrics.get_calls + metrics.update_calls,
		metrics.transform_calls,
		metrics.max_active_requests
	))
end)

if not suite_ok then
	warn("[production-adapter-safety] FAIL: " .. tostring(suite_error))
	process.exit(1)
end

Shim.close()
