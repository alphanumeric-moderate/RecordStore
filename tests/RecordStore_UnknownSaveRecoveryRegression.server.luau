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

	RecordStore.Mock.set_update_commit_then_failures(1)
	RecordStore.Mock.set_get_failures(1)
	local save_result = record:Save("recovery-test")
	assert(save_result == "unknown", "commit followed by read failure must expose an unresolved result")

	local status = record:GetDurabilityStatus()
	assert(status.ownership == "uncertain", "unknown save must mark ownership certainty as uncertain")
	assert(status.durability == "degraded", "unknown save must mark durability as degraded")
	assert(status.pending_operation_id ~= nil, "unknown save must retain the logical operation ID")
	local operation_id = status.pending_operation_id
	assert(status.dirty_watermark > status.durable_watermark, "unconfirmed save must retain a dirty watermark")

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
print("[PASS] Unknown-save recovery retains immutable operation identity, confirms committed writes, retries only the exact base revision, and blocks mutation while ownership is uncertain.")
