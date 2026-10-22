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

do
	local record = open_test_record("mutation-during-close")
	local update_result, update_message = record:Update(function(data)
		(data :: { [string]: RecordStore.JsonValue }).coins = 20
		return data
	end)
	assert(update_result == "success", update_message)
	local retained_data = record.Data :: { [string]: RecordStore.JsonValue }

	local injected = false
	RecordStore.Mock.set_test_clock(function()
		if not injected then
			injected = true
			retained_data.coins = 30
		end
		return DateTime.now().UnixTimestampMillis / 1000 + 1
	end)
	local close_result, close_message = record:Close()
	RecordStore.Mock.set_test_clock(nil)
	assert(injected, "mock clock did not inject the retained-alias edit during release UpdateAsync")
	assert(close_result == "closed", close_message)
	local durable = RecordStore.Mock.get_record_raw(
		"RecordStore_UnknownSaveRecoveryRegression",
		"global",
		"mutation-during-close"
	) :: { [string]: any }
	assert((durable.data :: { [string]: any }).coins == 20,
		"a retained Record.Data alias mutated during release and changed the durable close snapshot")
end

RecordStore.Mock.reset()

do
	local fake_now = DateTime.now().UnixTimestampMillis / 1000 + 1
	RecordStore.Mock.set_test_clock(function()
		return fake_now
	end)
	local record = open_test_record("renew-commit-then-error")
	local base_revision = record:GetRevision()
	local before = RecordStore.Mock.get_record_raw(
		"RecordStore_UnknownSaveRecoveryRegression",
		"global",
		"renew-commit-then-error"
	) :: { [string]: any }
	local before_lease = (before.session :: { [string]: any }).lease_until
	fake_now += 10

	RecordStore.Mock.set_update_commit_then_failures(1)
	RecordStore.Mock.set_get_failures(100, "hold ambiguous renewal outcome")
	local renew_result = RecordStore.Mock.renew(record)
	assert(renew_result == "unknown", "commit-then-error renewal must remain unknown until authoritative verification")
	local status = record:GetDurabilityStatus()
	local operation_id = status.pending_operation_id
	assert(operation_id ~= nil, "ambiguous renewal must retain its logical operation ID")
	assert(status.ownership == "uncertain", "ambiguous renewal must fence mutation while ownership is uncertain")
	assert(record:GetRevision() == base_revision, "lease renewal must not increment the data revision")

	local committed = RecordStore.Mock.get_record_raw(
		"RecordStore_UnknownSaveRecoveryRegression",
		"global",
		"renew-commit-then-error"
	) :: { [string]: any }
	assert(committed.write_id == operation_id, "ambiguous renewal must commit under its original operation ID")
	assert(committed.revision == base_revision, "ambiguous renewal must not create a data revision")
	assert(((committed.session :: { [string]: any }).lease_until) > before_lease,
		"committed renewal must extend the lease")

	RecordStore.Mock.set_get_failures(0)
	local recovery_result, recovery_message = RecordStore.Mock.reconcile(record)
	assert(recovery_result == "success", recovery_message)
	status = record:GetDurabilityStatus()
	assert(status.ownership == "owned", "verified renewal should restore ownership")
	assert(status.pending_operation_id == nil, "verified renewal must clear its pending operation")
	assert(record:GetRevision() == base_revision, "renewal reconciliation must preserve the data revision")
	local data = record:Get() :: { [string]: RecordStore.JsonValue }
	assert(data.coins == 10, "renewal reconciliation changed profile data")
	assert(record:Close() == "closed", "renewal recovery fixture should close")
end

RecordStore.Mock.reset()

do
	local fake_now = DateTime.now().UnixTimestampMillis / 1000 + 1
	RecordStore.Mock.set_test_clock(function()
		return fake_now
	end)
	local record = open_test_record("expired-lease-no-retry")
	local base_revision = record:GetRevision()
	local updated, update_message = record:Update(function(data)
		(data :: { [string]: RecordStore.JsonValue }).coins = 40
		return data
	end)
	assert(updated == "success", update_message)
	local before = RecordStore.Mock.get_record_raw(
		"RecordStore_UnknownSaveRecoveryRegression",
		"global",
		"expired-lease-no-retry"
	) :: { [string]: any }
	local previous_write_id = before.write_id

	RecordStore.Mock.set_update_failures(1, "unknown", "injected pre-commit failure")
	RecordStore.Mock.set_get_failures(100, "hold save outcome until lease expiry")
	local save_result = record:Save("known-not-committed-after-lease-expiry")
	assert(save_result == "unknown", "unconfirmed write should remain unknown before lease reconciliation")
	local status = record:GetDurabilityStatus()
	local operation_id = status.pending_operation_id
	assert(operation_id ~= nil, "expired-lease fixture must retain the pending operation ID")

	fake_now += 181
	RecordStore.Mock.set_get_failures(0)
	local recovery_result = RecordStore.Mock.reconcile(record)
	assert(recovery_result == "fenced", "reconciliation must fence an expired owner instead of retrying its stale snapshot")
	status = record:GetDurabilityStatus()
	assert(status.ownership == "lost", "expired lease recovery must report lost ownership")
	local durable = RecordStore.Mock.get_record_raw(
		"RecordStore_UnknownSaveRecoveryRegression",
		"global",
		"expired-lease-no-retry"
	) :: { [string]: any }
	assert(durable.write_id == previous_write_id, "expired lease recovery must not perform a stale conditional retry")
	assert(durable.revision == base_revision, "expired lease recovery must not advance durable revision")
	assert((durable.data :: { [string]: any }).coins == 10,
		"expired lease recovery must not persist the uncommitted local snapshot")
end

RecordStore.Mock.reset()

do
	local record = open_test_record("release-commit-then-error")
	local updated, update_message = record:Update(function(data)
		(data :: { [string]: RecordStore.JsonValue }).coins = 20
		return data
	end)
	assert(updated == "success", update_message)
	local base_revision = record:GetRevision()

	RecordStore.Mock.set_update_commit_then_failures(1)
	RecordStore.Mock.set_get_failures(100, "hold ambiguous release outcome")
	local close_result = record:Close()
	assert(close_result == "unknown", "ambiguous release must not claim a confirmed close")
	local status = record:GetDurabilityStatus()
	local operation_id = status.pending_operation_id
	assert(operation_id ~= nil, "ambiguous release must retain its operation ID")
	assert(status.ownership == "uncertain", "ambiguous release must report uncertain ownership")
	assert(record.State == "unknown", "ambiguous release must keep the public state fenced")

	RecordStore.Mock.set_get_failures(0)
	local recovery_result, recovery_message = RecordStore.Mock.reconcile(record)
	assert(recovery_result == "success", recovery_message)
	assert(record.State == "closed", "reconciled committed release must not resurrect the session")
	status = record:GetDurabilityStatus()
	assert(status.pending_operation_id == nil, "confirmed release must clear its pending operation")
	local durable = RecordStore.Mock.get_record_raw(
		"RecordStore_UnknownSaveRecoveryRegression",
		"global",
		"release-commit-then-error"
	) :: { [string]: any }
	assert(durable.write_id == operation_id, "release reconciliation must confirm the original operation ID")
	assert(durable.revision == base_revision + 1, "release reconciliation must not duplicate the release revision")
	assert(durable.session == nil, "confirmed release must remain sessionless")
	assert((durable.data :: { [string]: any }).coins == 20, "release reconciliation lost the captured snapshot")
end

RecordStore.Mock.reset()

do
	local record = open_test_record("release-known-not-committed")
	local updated, update_message = record:Update(function(data)
		(data :: { [string]: RecordStore.JsonValue }).coins = 30
		return data
	end)
	assert(updated == "success", update_message)
	local base_revision = record:GetRevision()

	RecordStore.Mock.set_update_failures(1, "unknown", "injected pre-commit release failure")
	RecordStore.Mock.set_get_failures(100, "hold release verification until retry")
	local close_result = record:Close()
	assert(close_result == "unknown", "unverified pre-commit release must remain unknown")
	local status = record:GetDurabilityStatus()
	local operation_id = status.pending_operation_id
	assert(operation_id ~= nil, "uncommitted release must retain its logical operation ID")

	RecordStore.Mock.set_get_failures(0)
	local recovery_result, recovery_message = RecordStore.Mock.reconcile(record)
	assert(recovery_result == "success", recovery_message)
	assert(record.State == "closed", "reconciled release retry must close the session")
	local durable = RecordStore.Mock.get_record_raw(
		"RecordStore_UnknownSaveRecoveryRegression",
		"global",
		"release-known-not-committed"
	) :: { [string]: any }
	assert(durable.write_id == operation_id, "release retry must reuse the original operation ID")
	assert(durable.revision == base_revision + 1, "release retry must commit exactly one revision")
	assert(durable.session == nil, "release retry must relinquish the session")
	assert((durable.data :: { [string]: any }).coins == 30, "release retry must persist its retained snapshot")
end

RecordStore.Mock.reset()

do
	local fake_now = DateTime.now().UnixTimestampMillis / 1000 + 1
	RecordStore.Mock.set_test_clock(function()
		return fake_now
	end)
	local record = open_test_record("release-after-takeover")
	local updated, update_message = record:Update(function(data)
		(data :: { [string]: RecordStore.JsonValue }).coins = 20
		return data
	end)
	assert(updated == "success", update_message)
	local base_revision = record:GetRevision()

	RecordStore.Mock.set_update_failures(1, "unknown", "injected pre-commit release failure")
	RecordStore.Mock.set_get_failures(100, "hold release verification before ownership replacement")
	local close_result = record:Close()
	assert(close_result == "unknown", "uncommitted release with failed verification must remain unknown")
	local status = record:GetDurabilityStatus()
	assert(status.pending_operation_id ~= nil, "unknown release must retain its operation identity")

	local winner_write_id = "00000000-0000-4000-8000-000000000001"
	local winner_session_token = "00000000-0000-4000-8000-000000000002"
	local winner = RecordStore.Mock.get_record_raw(
		"RecordStore_UnknownSaveRecoveryRegression",
		"global",
		"release-after-takeover"
	) :: { [string]: any }
	winner.fencing_generation += 1
	winner.revision = base_revision + 1
	winner.updated_at = fake_now + 1
	winner.data = { coins = 77, label = "new-owner" }
	winner.write_id = winner_write_id
	local winner_session = winner.session :: { [string]: any }
	winner_session.token = winner_session_token
	winner_session.generation = winner.fencing_generation
	winner_session.lease_until = fake_now + 180
	local seed_result, seed_message = RecordStore.Mock.seed_record_raw(
		"RecordStore_UnknownSaveRecoveryRegression",
		"global",
		"release-after-takeover",
		winner
	)
	assert(seed_result == "success", seed_message)

	RecordStore.Mock.set_get_failures(0)
	local recovery_result = RecordStore.Mock.reconcile(record)
	assert(recovery_result == "fenced", "old release operation must fence after a replacement owner appears")
	assert(record.State == "fenced", "stale releasing record must not become active after takeover")
	local durable = RecordStore.Mock.get_record_raw(
		"RecordStore_UnknownSaveRecoveryRegression",
		"global",
		"release-after-takeover"
	) :: { [string]: any }
	assert(durable.write_id == winner_write_id, "stale release must not overwrite the replacement owner's operation")
	assert(durable.fencing_generation == winner.fencing_generation,
		"stale release must not roll back the replacement fencing generation")
	assert((durable.data :: { [string]: any }).coins == 77,
		"stale release must not overwrite the replacement owner's data")
	assert(((durable.session :: { [string]: any }).token) == winner_session_token,
		"stale release must not remove the replacement owner's session")
end

RecordStore.Mock.reset()
print("[PASS] Unknown-save and release recovery retain operation identity, fence public mutation, preserve in-flight edits, and refuse stale-owner writes.")
