--!strict

local ServerScriptService = game:GetService("ServerScriptService")
local RecordStore = require(ServerScriptService.RecordStore)

local function open_test_record(key: string)
	local record = RecordStore.Mock.new("RecordStore_UnknownSaveRecoveryRegression", "global", key, {
		schema_version = 1,
		autosave_interval = 1000,
		lease_duration = 180,
		lease_renewal = 60,
		operation_deadline = 2,
		retry_attempts = 1,
	})
	local result, message = record:Open({ coins = 10, label = "initial" })
	assert(result == "created" or result == "loaded", message)
	return record
end

RecordStore.Mock.reset()

do
	local record = open_test_record("commit-then-error")
	local base_revision = record:GetRevision()
	local update_result, update_message = record:Update(function(data)
		(data :: { [string]: RecordStore.JsonValue }).coins = 20
		return data
	end)
	assert(update_result == "success", update_message)
	local retained_data = record.Data :: { [string]: RecordStore.JsonValue }

	RecordStore.Mock.set_update_commit_then_failures(1)
	RecordStore.Mock.set_get_failures(100, "hold unknown state for alias-fencing assertions")
	local save_result = record:Save("recovery-test")
	assert(save_result == "unknown", "commit followed by read failure must expose an unresolved result")

	local status = record:GetDurabilityStatus()
	assert(status.ownership == "uncertain", "unknown save must mark ownership certainty as uncertain")
	assert(status.durability == "degraded", "unknown save must mark durability as degraded")
	assert(status.pending_operation_id ~= nil, "unknown save must retain the logical operation ID")
	local operation_id = status.pending_operation_id
	assert(status.dirty_watermark > status.durable_watermark, "unconfirmed save must retain a dirty watermark")

	retained_data.coins = 888
	local retained_visible_data = record:Get() :: { [string]: RecordStore.JsonValue }
	assert(retained_visible_data.coins == 20,
		"a Record.Data reference captured before uncertainty must not mutate canonical data afterward")
	local exposed_data = record.Data :: { [string]: RecordStore.JsonValue }
	exposed_data.coins = 999
	local visible_data = record:Get() :: { [string]: RecordStore.JsonValue }
	assert(visible_data.coins == 20,
		"direct mutation through Record.Data must not change canonical data while durability is uncertain")
	assert(record:GetRevision() == base_revision, "unconfirmed save must not claim a new confirmed revision")

	local blocked_result = record:Update(function(data)
		(data :: { [string]: RecordStore.JsonValue }).coins = 30
		return data
	end)
	assert(blocked_result == "fenced", "ordinary mutation must be rejected while ownership is uncertain")

	RecordStore.Mock.set_get_failures(0)
	local recovery_result, recovery_message = RecordStore.Mock.reconcile(record)
	assert(recovery_result == "success", recovery_message)
	local durable = RecordStore.Mock.get_record_raw(
		"RecordStore_UnknownSaveRecoveryRegression",
		"global",
		"commit-then-error"
	) :: { [string]: any }
	assert(durable.write_id == operation_id, "reconciliation must confirm the original write ID")
	assert(durable.revision == base_revision + 1, "committed operation must not be duplicated")
	assert((durable.data :: { [string]: any }).coins == 20, "reconciliation lost the committed snapshot")
	status = record:GetDurabilityStatus()
	assert(status.ownership == "owned", "valid unexpired ownership should be restored after confirmation")
	assert(status.durability == "clean", "confirmed snapshot should advance the durable watermark")
	assert(status.pending_operation_id == nil, "resolved operation must leave the recovery queue")
	assert(record:GetRevision() == base_revision + 1, "confirmed revision was not advanced")
	assert(record:Close() == "closed", "recovered record should close normally")
end

do
	local record = open_test_record("known-not-committed")
	local base_revision = record:GetRevision()
	local update_result, update_message = record:Update(function(data)
		(data :: { [string]: RecordStore.JsonValue }).coins = 40
		return data
	end)
	assert(update_result == "success", update_message)

	RecordStore.Mock.set_update_failures(1, "unknown", "injected pre-commit failure")
	local save_result = record:Save("recovery-test")
	assert(save_result == "unknown", "uncommitted write with unresolved verification should remain unknown")
	local status = record:GetDurabilityStatus()
	local operation_id = status.pending_operation_id
	assert(operation_id ~= nil, "uncommitted unknown save must retain its logical operation ID")

	local recovery_result, recovery_message = RecordStore.Mock.reconcile(record)
	assert(recovery_result == "success", recovery_message)
	local durable = RecordStore.Mock.get_record_raw(
		"RecordStore_UnknownSaveRecoveryRegression",
		"global",
		"known-not-committed"
	) :: { [string]: any }
	assert(durable.write_id == operation_id, "retry must reuse the same logical operation ID")
	assert(durable.revision == base_revision + 1, "recovery retry must commit exactly one revision")
	assert((durable.data :: { [string]: any }).coins == 40, "recovery retry did not persist the retained snapshot")
	assert(record:Close() == "closed", "retried record should close normally")
end

RecordStore.Mock.reset()

do
	local record = open_test_record("mutation-during-save")
	local update_result, update_message = record:Update(function(data)
		(data :: { [string]: RecordStore.JsonValue }).coins = 20
		return data
	end)
	assert(update_result == "success", update_message)

	local injected = false
	RecordStore.Mock.set_test_clock(function()
		if not injected then
			injected = true
			local data = record.Data :: { [string]: RecordStore.JsonValue }
			data.coins = 25
		end
		return DateTime.now().UnixTimestampMillis / 1000 + 1
	end)
	RecordStore.Mock.set_update_commit_then_failures(1)
	RecordStore.Mock.set_get_failures(100, "hold unknown state after injected in-flight mutation")
	local save_result = record:Save("in-flight-mutation")
	RecordStore.Mock.set_test_clock(nil)
	assert(injected, "mock clock did not inject a direct data mutation during UpdateAsync")
	assert(save_result == "unknown", "in-flight commit ambiguity must preserve an unknown result")

	local status = record:GetDurabilityStatus()
	assert(status.ownership == "uncertain", "in-flight mutation fixture did not enter unknown state")
	local local_data = record:Get() :: { [string]: RecordStore.JsonValue }
	assert(local_data.coins == 25, "direct mutation during save was lost before reconciliation")
	assert(record:IsDirty(), "direct mutation during save must remain dirty after an unknown write")

	RecordStore.Mock.set_get_failures(0)
	local recovery_result, recovery_message = RecordStore.Mock.reconcile(record)
	assert(recovery_result == "success", recovery_message)
	local recovered_data = record:Get() :: { [string]: RecordStore.JsonValue }
	assert(recovered_data.coins == 25, "reconciliation overwrote a post-snapshot direct mutation")
	assert(record:IsDirty(), "newer direct mutation must remain dirty after confirming the older snapshot")
	assert(record:Save("persist-in-flight-mutation") == "saved",
		"the retained post-snapshot direct mutation must be saveable after reconciliation")
	local durable = RecordStore.Mock.get_record_raw(
		"RecordStore_UnknownSaveRecoveryRegression",
		"global",
		"mutation-during-save"
	) :: { [string]: any }
	assert((durable.data :: { [string]: any }).coins == 25,
		"the retained post-snapshot mutation was not persisted by the follow-up save")
	assert(record:Close() == "closed", "in-flight mutation recovery fixture should close")
end

RecordStore.Mock.reset()
print("[PASS] Unknown-save recovery retains immutable operation identity, confirms committed writes, retries only the exact base revision, and blocks mutation while ownership is uncertain.")
