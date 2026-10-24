--!nocheck
local process = require("@lune/process")
local function assert(value, message)
	if not value then
		warn(message or "assertion failed")
		process.exit(1)
	end
	return value
end

local Shim = require("./RobloxShim")
local RecordStore = Shim.load()
local Mock = RecordStore.Mock
local MailboxV2 = RecordStore.MailboxV2

assert(type(Mock.get_session_status_async) == "function", "session status diagnostic API is missing")
assert(type(MailboxV2.MaintenanceAsync) == "function", "mailbox maintenance API is missing")
assert(type(RecordStore.inspect_profile_async) == "function", "Profile Doctor inspection API is missing")
assert(type(Mock.inspect_profile_async) == "function", "mock Profile Doctor inspection API is missing")
assert(type(RecordStore.diff_profile_versions_async) == "function", "Profile Doctor version diff API is missing")
assert(type(Mock.diff_profile_versions_async) == "function", "mock Profile Doctor version diff API is missing")
assert(type(RecordStore.register_migration) == "function", "migration registry API is missing")
assert(type(RecordStore.preview_migration_async) == "function", "migration preview API is missing")
assert(type(Mock.preview_migration_async) == "function", "mock migration preview API is missing")

Mock.reset()
Mock.set_test_clock(function()
	return 1000
end)

local scheduler_enabled, scheduler_enable_message = RecordStore.set_scheduler_enabled(true)
assert(scheduler_enabled, "could not enable scheduler for reserved work-class regression: "
	.. tostring(scheduler_enable_message))
local reserved_scheduler_aliases = {
	{ label = "lease-renewal lane", field = "lane", value = "lease_renewal" },
	{ label = "lease-renewal operation class", field = "operation_class", value = "lease_renewal" },
	{ label = "profile-release operation class", field = "operation_class", value = "profile_release" },
	{ label = "critical operation class", field = "operation_class", value = "critical" },
	{ label = "profile-save operation class", field = "operation_class", value = "profile_save" },
	{ label = "lease-renewal work class", field = "work_class", value = "lease_renewal" },
	{ label = "profile-release work class", field = "work_class", value = "profile_release" },
	{ label = "critical work class", field = "work_class", value = "critical" },
	{ label = "profile-save work class", field = "work_class", value = "profile_save" },
	{ label = "critical service class", field = "service_class", value = "critical" },
}
for index, reserved_alias in ipairs(reserved_scheduler_aliases) do
	local options = {
		lane = "normal",
		work_class = "maintenance",
		operation_class = "update_async",
		service_class = "normal",
	}
	options[reserved_alias.field] = reserved_alias.value
	local scheduled = RecordStore.schedule_work(
		"reserved-alias-owner",
		"reserved-alias-" .. tostring(index),
		function()
			error("reserved scheduler work-class alias bypassed the admission guard")
		end,
		options
	)
	assert(scheduled.code == "invalid", reserved_alias.label .. " bypassed reserved-work validation")
end
RecordStore.set_scheduler_enabled(false)

local function seed_record(key, session, tombstone)
	local envelope = {
		implementation_version = 2,
		schema_version = 1,
		revision = 4,
		fencing_generation = 2,
		created_at = 900,
		updated_at = 950,
		data = if tombstone ~= nil then nil else { value = 12 },
		non_finite_numbers = {},
		user_ids = {},
		tombstone = tombstone,
		write_id = "write-" .. key,
	}
	if session ~= nil then
		envelope.session = session
	end
	local result, message = Mock.seed_record_raw("SessionStatusTest", "global", key, envelope)
	assert(result == "success", tostring(message))
end

local active_session = {
	token = "do-not-return-this-token",
	generation = 2,
	job_id = "job-active",
	place_id = 100,
	acquired_at = 900,
	lease_until = 1100,
}
seed_record("active", active_session)
seed_record("expired", {
	token = "expired-token",
	generation = 2,
	job_id = "job-expired",
	place_id = 100,
	acquired_at = 800,
	lease_until = 900,
})
seed_record("unleased", nil)
seed_record("tombstoned", nil, { deleted_at = 950, generation = 2 })

local status, result, message = Mock.get_session_status_async("SessionStatusTest", "global", "active")
assert(result == "success", tostring(message))
assert(status.Observation == "active_lease_observed")
assert(status.LeaseRemainingSeconds == 100)
assert(status.LeaseAppearsAvailable == false)
assert(status.OwnerJobId == "job-active")
assert(status.Generation == 2)
assert(status.Revision == 4)
assert(status.IsAuthoritativeOwnershipDecision == false)
assert(status.SessionToken == nil, "session token must never be exposed")

local expired, expired_result, expired_message =
	Mock.get_session_status_async("SessionStatusTest", "global", "expired")
assert(expired_result == "success", tostring(expired_message))
assert(expired.Observation == "expired_lease_observed")
assert(expired.LeaseRemainingSeconds == 0)
assert(expired.LeaseAppearsAvailable == true)

local unleased, unleased_result, unleased_message =
	Mock.get_session_status_async("SessionStatusTest", "global", "unleased")
assert(unleased_result == "success", tostring(unleased_message))
assert(unleased.Observation == "no_session")
assert(unleased.LeaseAppearsAvailable == true)

local tombstoned, tombstoned_result, tombstoned_message =
	Mock.get_session_status_async("SessionStatusTest", "global", "tombstoned")
assert(tombstoned_result == "success", tostring(tombstoned_message))
assert(tombstoned.Observation == "tombstoned")
assert(tombstoned.LeaseAppearsAvailable == false, "tombstones must not be reported as available")

local missing, missing_result = Mock.get_session_status_async("SessionStatusTest", "global", "missing")
assert(missing_result == "not_found")
assert(missing.Observation == "not_found")
assert(missing.LeaseAppearsAvailable == true)

local invalid, invalid_result = Mock.get_session_status_async("", "global", "active")
assert(invalid == nil and invalid_result == "invalid")

Mock.set_get_failures(1, "injected read failure")
local unreadable, unreadable_result = Mock.get_session_status_async("SessionStatusTest", "global", "active")
assert(unreadable == nil and unreadable_result == "unknown", "read failures must not look like an unowned profile")

local store = MailboxV2.MockStore()
local mailbox = MailboxV2.new(store, {
	store_name = "PlayerData",
	scope = "global",
	profile_key = "maintenance-owner",
}, {
	encode = function(value)
		return game:GetService("HttpService"):JSONEncode(value)
	end,
	activation_guard = function()
		return true, nil
	end,
})
local report, maintenance_result = mailbox:MaintenanceAsync()
assert(maintenance_result.code == "success", tostring(maintenance_result.error))
assert(report.recovery.code == "success")
assert(report.reclaim.code == "empty")
assert(report.stats.ready == 0)
assert(report.consistency == "bounded_non_linearizable")

local inspection, inspection_result, inspection_message =
	Mock.inspect_profile_async("SessionStatusTest", "global", "active")
assert(inspection_result == "success", tostring(inspection_message))
assert(inspection.Classification == "active_session")
assert(inspection.Consistency == "point_in_time_non_authoritative")
assert(inspection.DataNodeCount == 2, "inspection should report bounded data node count")
assert(inspection.DataDepth == 1, "inspection should report maximum data depth")
assert(inspection.ProfileKey == "active")

local missing_inspection, missing_inspection_result =
	Mock.inspect_profile_async("SessionStatusTest", "global", "missing")
assert(missing_inspection_result == "not_found")
assert(missing_inspection.Classification == "missing")

local malformed_seed_result = Mock.seed_record_raw("ProfileDoctorTest", "global", "future", {
	implementation_version = 999,
	schema_version = 1,
	revision = 1,
	fencing_generation = 1,
	created_at = 1,
	updated_at = 1,
	data = {},
	non_finite_numbers = {},
	user_ids = {},
	write_id = "future-write",
})
assert(malformed_seed_result == "success")
local future_inspection, future_result =
	Mock.inspect_profile_async("ProfileDoctorTest", "global", "future")
assert(future_result == "future_schema")
assert(future_inspection.Classification == "future_schema")

local doctor_record = Mock.new("ProfileDoctorTest", "global", "profile", {
	schema_version = 1,
	autosave_interval = 1000,
	lease_duration = 180,
	lease_renewal = 60,
})
local doctor_open, doctor_open_message = doctor_record:Open({
	coins = 10,
	nested = { label = "before" },
})
assert(doctor_open == "created" or doctor_open == "loaded", tostring(doctor_open_message))
local before_history, before_history_result, before_history_message =
	Mock.list_versions_async("ProfileDoctorTest", "global", "profile", Enum.SortDirection.Descending, nil, nil, 100)
assert(before_history_result == "success", tostring(before_history_message))
assert(before_history ~= nil and #before_history >= 1, "Profile Doctor fixture has no original version")
local before_version = before_history[1].Version

local doctor_update, doctor_update_message = doctor_record:Update(function(data)
	(data :: { [string]: any }).coins = 20
	(data :: { [string]: any }).nested.label = "after"
	return data
end)
assert(doctor_update == "success", tostring(doctor_update_message))
local doctor_save, doctor_save_message = doctor_record:Save("profile-doctor-diff")
assert(doctor_save == "saved", tostring(doctor_save_message))
local after_history, after_history_result, after_history_message =
	Mock.list_versions_async("ProfileDoctorTest", "global", "profile", Enum.SortDirection.Descending, nil, nil, 100)
assert(after_history_result == "success", tostring(after_history_message))
assert(after_history ~= nil and #after_history >= 2, "Profile Doctor fixture did not create a new version")
local after_version = after_history[1].Version
assert(after_version ~= before_version, "Profile Doctor fixture reused the same version")

local diff, diff_result, diff_message = Mock.diff_profile_versions_async(
	"ProfileDoctorTest", "global", "profile", before_version, after_version, {
		max_nodes = 100,
		max_changes = 20,
		max_depth = 16,
	}
)
assert(diff_result == "success", tostring(diff_message))
assert(diff.Consistency == "bounded_historical_diff")
assert(diff.Truncated == false)
local changed_paths = {}
for _, change in ipairs(diff.Changes) do
	changed_paths[change.Path] = change.Kind
	assert(change.BeforeValue == nil and change.AfterValue == nil,
		"Profile Doctor version diffs must not expose raw values by default")
end
assert(changed_paths["$.coins"] == "changed", "Profile Doctor missed the changed scalar path")
assert(changed_paths["$.nested.label"] == "changed", "Profile Doctor missed the nested changed path")

local bounded_diff, bounded_result, bounded_message = Mock.diff_profile_versions_async(
	"ProfileDoctorTest", "global", "profile", before_version, after_version, {
		max_nodes = 100,
		max_changes = 1,
		max_depth = 16,
	}
)
assert(bounded_result == "success", tostring(bounded_message))
assert(#bounded_diff.Changes <= 1)
assert(bounded_diff.Truncated == true, "diff must report truncation when the change cap is reached")

local migration_record = Mock.new("MigrationTest", "global", "profile", {
	schema_version = 1,
	autosave_interval = 1000,
	lease_duration = 180,
	lease_renewal = 60,
})
local migration_open, migration_open_message = migration_record:Open({
	coins = 10,
	nested = { label = "before" },
})
assert(migration_open == "created" or migration_open == "loaded", tostring(migration_open_message))
local migration_before = Mock.get_record_raw("MigrationTest", "global", "profile")
local migration_before_revision = migration_record:GetRevision()

local migration_1_to_2 = {
	id = "migration-test-v1-v2",
	from_version = 1,
	to_version = 2,
	implementation_revision = "test-implementation-1",
	compatible_schema_min = 1,
	compatible_schema_max = 3,
	transform = function(_from_version, data)
		local next_data = table.clone(data)
		next_data.coins += 5
		next_data.nested = table.clone(next_data.nested)
		next_data.nested.label = "middle"
		return next_data
	end,
}
local migration_2_to_3 = {
	id = "migration-test-v2-v3",
	from_version = 2,
	to_version = 3,
	implementation_revision = "test-implementation-1",
	compatible_schema_min = 1,
	compatible_schema_max = 3,
	transform = function(_from_version, data)
		local next_data = table.clone(data)
		next_data.coins += 7
		next_data.nested = table.clone(next_data.nested)
		next_data.nested.label = "after"
		next_data.schema_marker = 3
		return next_data
	end,
}
local migration_register_1, migration_register_1_message =
	RecordStore.register_migration("MigrationTest", migration_1_to_2)
assert(migration_register_1 == "success", tostring(migration_register_1_message))
local migration_register_2, migration_register_2_message =
	RecordStore.register_migration("MigrationTest", migration_2_to_3)
assert(migration_register_2 == "success", tostring(migration_register_2_message))
local duplicate_registration, duplicate_message =
	RecordStore.register_migration("MigrationTest", migration_1_to_2)
assert(duplicate_registration == "duplicate", tostring(duplicate_message))

local invalid_backward = table.clone(migration_2_to_3)
invalid_backward.id = "migration-test-v3-v2"
invalid_backward.from_version = 3
invalid_backward.to_version = 2
assert(RecordStore.register_migration("MigrationTest", invalid_backward) == "invalid",
	"registry must reject backwards migration edges")

local ambiguous_registration = table.clone(migration_2_to_3)
ambiguous_registration.id = "migration-test-v1-v3-ambiguous"
ambiguous_registration.from_version = 1
ambiguous_registration.to_version = 3
local ambiguous_result, ambiguous_message =
	RecordStore.register_migration("MigrationTest", ambiguous_registration)
assert(ambiguous_result == "conflict",
	("registry must reject a second route between already connected schema versions, got %s: %s"):format(
		tostring(ambiguous_result), tostring(ambiguous_message)))

local preview, preview_result, preview_message = Mock.preview_migration_async(
	"MigrationTest", "global", "profile", 3, {
		max_nodes = 100,
		max_depth = 16,
		max_changes = 20,
	}
)
assert(preview_result == "success", tostring(preview_message))
assert(preview.Consistency == "read_only_non_authoritative_preview")
assert(preview.SourceSchemaVersion == 1 and preview.TargetSchemaVersion == 3)
assert(#preview.Steps == 2)
assert(preview.TargetDataNodeCount ~= nil and preview.TargetDataNodeCount > 0)
assert(preview.Truncated == false)
local preview_paths = {}
for _, change in ipairs(preview.Changes) do
	preview_paths[change.Path] = change.Kind
	assert(change.BeforeValue == nil and change.AfterValue == nil,
		"migration preview must not expose raw profile values")
end
assert(preview_paths["$.coins"] == "changed")
assert(preview_paths["$.nested.label"] == "changed")
assert(preview_paths["$.schema_marker"] == "added")

local preview_gap, preview_gap_result =
	Mock.preview_migration_async("MigrationTest", "global", "profile", 4)
assert(preview_gap == nil and preview_gap_result == "migration",
	"preview must reject a target with no unique registered migration path")
local migration_after = Mock.get_record_raw("MigrationTest", "global", "profile")
assert(migration_after.schema_version == migration_before.schema_version,
	"dry-run migration preview modified the durable schema version")
assert(migration_after.revision == migration_before.revision,
	"dry-run migration preview modified the durable revision")
assert((migration_after.data :: { [string]: any }).coins == (migration_before.data :: { [string]: any }).coins,
	"dry-run migration preview modified durable profile data")
assert(migration_record:GetRevision() == migration_before_revision,
	"dry-run migration preview mutated the live mock Record")


local transactional_record = Mock.new("TransactionTest", "global", "profile", {
	schema_version = 1,
	transactional_operations_enabled = true,
})
local transactional_open, transactional_open_message = transactional_record:Open({
	coins = 10,
	inventory = {},
})
assert(transactional_open == "success" or transactional_open == "created",
	"transaction open status=" .. tostring(transactional_open) .. " message=" .. tostring(transactional_open_message))

local transact_result, transact_status, transact_message = transactional_record:TransactAsync(
	"reward:daily:test",
	function(data)
		local next_data = table.clone(data)
		next_data.coins += 100
		return next_data, { coins_granted = 100 }
	end,
	{ request = { kind = "daily_reward", amount = 100 }, receipt_retention_seconds = 3600 }
)
assert(transact_status == "committed", "TransactAsync status=" .. tostring(transact_status) .. " message=" .. tostring(transact_message))
assert(transact_result.coins_granted == 100)
assert(type(transactional_record:Get()) == "table",
	"transaction must persist reducer data rather than the validator success flag")
assert(transactional_record:Get().coins == 110)

local duplicate_result, duplicate_status, duplicate_message = transactional_record:TransactAsync(
	"reward:daily:test",
	function()
		error("duplicate transaction reducer must not run")
	end,
	{ request = { amount = 100, kind = "daily_reward" }, receipt_retention_seconds = 3600 }
)
assert(duplicate_status == "duplicate", "duplicate TransactAsync status=" .. tostring(duplicate_status) .. " message=" .. tostring(duplicate_message))
assert(duplicate_result.coins_granted == 100)
assert(transactional_record:Get().coins == 110, "duplicate transaction reapplied its reducer")

local conflict_result, conflict_status = transactional_record:TransactAsync(
	"reward:daily:test",
	function(data)
		local next_data = table.clone(data)
		next_data.coins += 1000
		return next_data, { coins_granted = 1000 }
	end,
	{ request = { kind = "daily_reward", amount = 1000 }, receipt_retention_seconds = 3600 }
)
assert(conflict_result == nil and conflict_status == "conflict")
assert(transactional_record:Get().coins == 110, "conflicting transaction mutated profile data")

local inbox_result, inbox_status, inbox_message = transactional_record:ApplyInboxAsync(
	"mail:award:test",
	"CoinAward",
	{ amount = 7 },
	function(data, payload)
		local next_data = table.clone(data)
		next_data.coins += payload.amount
		return next_data, { applied = payload.amount }
	end
)
assert(inbox_status == "committed", "ApplyInboxAsync status=" .. tostring(inbox_status) .. " message=" .. tostring(inbox_message))
assert(inbox_result.applied == 7)
local inbox_duplicate, inbox_duplicate_status = transactional_record:ApplyInboxAsync(
	"mail:award:test",
	"CoinAward",
	{ amount = 7 },
	function()
		error("duplicate inbox reducer must not run")
	end
)
assert(inbox_duplicate_status == "duplicate" and inbox_duplicate.applied == 7)
assert(transactional_record:Get().coins == 117, "duplicate inbox delivery reapplied a profile mutation")

local inbox_conflict, inbox_conflict_status = transactional_record:ApplyInboxAsync(
	"mail:award:test",
	"CoinAward",
	{ amount = 9 },
	function(data, payload)
		local next_data = table.clone(data)
		next_data.coins += payload.amount
		return next_data
	end
)
assert(inbox_conflict == nil and inbox_conflict_status == "conflict")
assert(transactional_record:Get().coins == 117, "conflicting inbox message mutated profile data")

local outbox_result, outbox_status, outbox_message = transactional_record:CommitWithOutboxAsync(
	"gift:operation:test",
	"GiftCoins",
	{ amount = 3, recipient = "recipient" },
	{
		{
			target_store = "TransactionTest",
			target_scope = "global",
			target_key = "recipient",
			type = "CoinGift",
			payload_version = 1,
			data = { amount = 3 },
		},
	},
	function(data, command)
		local next_data = table.clone(data)
		next_data.coins -= command.amount
		return next_data, { queued = true }
	end
)
assert(outbox_status == "committed", "CommitWithOutboxAsync status=" .. tostring(outbox_status) .. " message=" .. tostring(outbox_message))
assert(outbox_result.queued == true)
assert(transactional_record:Get().coins == 114)
local durable_transaction = Mock.get_record_raw("TransactionTest", "global", "profile")
assert(durable_transaction.implementation_version == 3, "transaction did not opt into envelope v3")
assert(type(durable_transaction.sidecars) == "table", "transaction did not persist durable sidecars")
assert(durable_transaction.sidecars.transaction_receipts["reward:daily:test"] ~= nil)
assert(durable_transaction.sidecars.inbox_receipts["mail:award:test"] ~= nil)
local outbox_count = 0
for _, event in pairs(durable_transaction.sidecars.outbox_events) do
	outbox_count += 1
	assert(event.event_type == "CoinGift")
	assert(event.payload_version == 1)
	assert(event.state == "pending")
end
assert(outbox_count == 1, "outbox intent and profile mutation did not commit together")


local pending_outbox_events, pending_outbox_status, pending_outbox_message = transactional_record:GetOutboxAsync()
assert(pending_outbox_status == "success", "GetOutboxAsync status=" .. tostring(pending_outbox_status)
	.. " message=" .. tostring(pending_outbox_message))
assert(#pending_outbox_events == 1, "GetOutboxAsync must return the committed pending event")
local pending_outbox_event = pending_outbox_events[1]
assert(pending_outbox_event.EventId ~= "")
assert(pending_outbox_event.EventType == "CoinGift")
assert(pending_outbox_event.PayloadVersion == 1)
assert(pending_outbox_event.Payload.amount == 3)
assert(pending_outbox_event.DestinationProfileKey == "recipient")
assert(pending_outbox_event.State == "pending")
assert(pending_outbox_event.DestinationReceiptId == nil)

local closed_result = transactional_record:Close()
assert(transactional_record:GetState() == "closed",
	"outbox delivery test must dispatch without an open profile session")
local before_outbox_dispatch = Mock.get_record_raw("TransactionTest", "global", "profile")
Mock.set_update_commit_then_failures(1, "outbox receipt update response lost after durable commit")
local outbox_dispatch_calls = 0
local outbox_delivered_count, outbox_dispatch_status, outbox_dispatch_message =
	transactional_record:DispatchOutboxAsync(function(event)
		outbox_dispatch_calls += 1
		assert(event.EventId == pending_outbox_event.EventId, "dispatcher received a different event ID")
		assert(event.EventType == "CoinGift")
		return true, "mailbox-receipt:" .. event.EventId
	end)
assert(outbox_dispatch_status == "success", "DispatchOutboxAsync status="
	.. tostring(outbox_dispatch_status) .. " message=" .. tostring(outbox_dispatch_message))
assert(outbox_delivered_count == 1, "ambiguous outbox metadata write was not reconciled")
assert(outbox_dispatch_calls == 1, "dispatcher callback should execute once for this batch")
local after_outbox_dispatch = Mock.get_record_raw("TransactionTest", "global", "profile")
local delivered_outbox_event = after_outbox_dispatch.sidecars.outbox_events[pending_outbox_event.EventId]
assert(delivered_outbox_event.state == "delivered")
assert(delivered_outbox_event.attempts == 1)
assert(delivered_outbox_event.destination_receipt_id == "mailbox-receipt:" .. pending_outbox_event.EventId)
assert(type(delivered_outbox_event.delivered_at) == "number")
assert(after_outbox_dispatch.revision == before_outbox_dispatch.revision,
	"sidecar delivery metadata must not increment the profile data revision")
assert(after_outbox_dispatch.updated_at == before_outbox_dispatch.updated_at,
	"sidecar delivery metadata must not alter the profile data timestamp")
assert(after_outbox_dispatch.write_id == before_outbox_dispatch.write_id,
	"sidecar delivery metadata must preserve the profile write ID")
assert(after_outbox_dispatch.data.coins == before_outbox_dispatch.data.coins,
	"sidecar delivery metadata must preserve profile data")
local remaining_outbox_events, remaining_outbox_status = transactional_record:GetOutboxAsync()
assert(remaining_outbox_status == "success" and #remaining_outbox_events == 0,
	"confirmed events must no longer appear in the pending outbox")

local no_prune_count, no_prune_status = transactional_record:PruneOutboxAsync(delivered_outbox_event.delivered_at)
assert(no_prune_count == 0 and no_prune_status == "duplicate",
	"retention cutoff is exclusive and must not prune at the exact delivery timestamp")
local invalid_prune_count, invalid_prune_status = transactional_record:PruneOutboxAsync(math.huge)
assert(invalid_prune_count == 0 and invalid_prune_status == "invalid",
	"outbox retention timestamps must be finite Unix seconds")
local pruned_count, prune_status, prune_message = transactional_record:PruneOutboxAsync(
	delivered_outbox_event.delivered_at + 1
)
assert(prune_status == "success" and pruned_count == 1,
	"PruneOutboxAsync did not remove the eligible delivered event: " .. tostring(prune_message))
local after_outbox_prune = Mock.get_record_raw("TransactionTest", "global", "profile")
assert(after_outbox_prune.sidecars.outbox_events[pending_outbox_event.EventId] == nil)
assert(after_outbox_prune.sidecars.transaction_receipts["reward:daily:test"] ~= nil,
	"outbox cleanup must not remove transaction idempotency receipts")
assert(after_outbox_prune.revision == before_outbox_dispatch.revision)
assert(after_outbox_prune.data.coins == before_outbox_dispatch.data.coins)
local invalid_outbox_events, invalid_outbox_status = transactional_record:GetOutboxAsync(0)
assert(#invalid_outbox_events == 0 and invalid_outbox_status == "invalid",
	"outbox reads must reject a zero-size batch")

local outbox_retry_record = Mock.new("OutboxRetryTest", "global", "profile", {
	schema_version = 1,
	transactional_operations_enabled = true,
})
local outbox_retry_open, outbox_retry_open_message = outbox_retry_record:Open({ coins = 5 })
assert(outbox_retry_open == "success" or outbox_retry_open == "created",
	"outbox retry profile open status=" .. tostring(outbox_retry_open)
		.. " message=" .. tostring(outbox_retry_open_message))
local retry_commit_result, retry_commit_status, retry_commit_message = outbox_retry_record:CommitWithOutboxAsync(
	"gift:retry:test",
	"GiftCoins",
	{ amount = 2, recipient = "retry-recipient" },
	{
		{
			target_store = "OutboxDestination",
			target_scope = "global",
			target_key = "retry-recipient",
			type = "CoinGift",
			payload_version = 1,
			data = { amount = 2 },
		},
	},
	function(data, command)
		local next_data = table.clone(data)
		next_data.coins -= command.amount
		return next_data, { queued = true }
	end
)
assert(retry_commit_status == "committed", "retry outbox commit status="
	.. tostring(retry_commit_status) .. " message=" .. tostring(retry_commit_message))
assert(retry_commit_result.queued == true)
local retry_events, retry_events_status = outbox_retry_record:GetOutboxAsync()
assert(retry_events_status == "success" and #retry_events == 1)
local retry_event_id = retry_events[1].EventId
local unknown_delivery_count, unknown_delivery_status = outbox_retry_record:DispatchOutboxAsync(function(event)
	assert(event.EventId == retry_event_id, "unknown delivery retry changed the stable event ID")
	error("transport disconnected after request submission")
end)
assert(unknown_delivery_count == 0 and unknown_delivery_status == "unknown",
	"dispatcher exceptions must produce an unknown delivery outcome")
local unknown_delivery_raw = Mock.get_record_raw("OutboxRetryTest", "global", "profile")
local unknown_delivery_event = unknown_delivery_raw.sidecars.outbox_events[retry_event_id]
assert(unknown_delivery_event.state == "unknown" and unknown_delivery_event.attempts == 1,
	"ambiguous delivery must stay recoverable with an attempt count")

local rejected_count, rejected_status = outbox_retry_record:DispatchOutboxAsync(function(event)
	assert(event.EventId == retry_event_id, "rejected delivery changed the stable event ID")
	return false, "destination temporarily unavailable"
end)
assert(rejected_count == 0 and rejected_status == "retry_exhausted",
	"a definitive destination refusal must leave the event retryable")
local rejected_raw = Mock.get_record_raw("OutboxRetryTest", "global", "profile")
local rejected_event = rejected_raw.sidecars.outbox_events[retry_event_id]
assert(rejected_event.state == "pending" and rejected_event.attempts == 2)
assert(rejected_event.last_error == "destination temporarily unavailable")

local retry_delivered_count, retry_delivered_status = outbox_retry_record:DispatchOutboxAsync(function(event)
	assert(event.EventId == retry_event_id, "successful retry changed the stable event ID")
	return true, "destination-receipt:retry"
end)
assert(retry_delivered_count == 1 and retry_delivered_status == "success")
local retry_delivered_raw = Mock.get_record_raw("OutboxRetryTest", "global", "profile")
local retry_delivered_event = retry_delivered_raw.sidecars.outbox_events[retry_event_id]
assert(retry_delivered_event.state == "delivered")
assert(retry_delivered_event.attempts == 3)
assert(retry_delivered_event.destination_receipt_id == "destination-receipt:retry")


local reducer_yield_record = Mock.new("TransactionYieldTest", "global", "profile", {
	schema_version = 1,
	transactional_operations_enabled = true,
})
local reducer_yield_open = reducer_yield_record:Open({ coins = 1 })
assert(reducer_yield_open == "success" or reducer_yield_open == "created",
	"yield-test profile open status=" .. tostring(reducer_yield_open))
local yield_result, yield_status = reducer_yield_record:TransactAsync(
	"yielding-operation",
	function(data)
		coroutine.yield()
		return data
	end,
	{ request = { action = "yield" } }
)
assert(yield_result == nil and yield_status == "validation",
	"yielding transaction reducers must abort before durable mutation")
assert(reducer_yield_record:Get().coins == 1)

local disabled_record = Mock.new("TransactionDisabledTest", "global", "profile", { schema_version = 1 })
local disabled_open = disabled_record:Open({ coins = 1 })
assert(disabled_open == "success" or disabled_open == "created",
	"disabled-test profile open status=" .. tostring(disabled_open))
local disabled_result, disabled_status = disabled_record:TransactAsync(
	"disabled-operation",
	function(data) return data end,
	{ request = { action = "disabled" } }
)
assert(disabled_result == nil and disabled_status == "disabled",
	"transaction APIs must remain disabled unless explicitly opted in")

local ambiguous_record = Mock.new("TransactionAmbiguousTest", "global", "profile", {
	schema_version = 1,
	transactional_operations_enabled = true,
})
local ambiguous_open = ambiguous_record:Open({ coins = 4 })
assert(ambiguous_open == "success" or ambiguous_open == "created",
	"ambiguous-test profile open status=" .. tostring(ambiguous_open))
Mock.set_update_commit_then_failures(1, "transaction response lost after durable commit")
local ambiguous_result, ambiguous_status, ambiguous_message = ambiguous_record:TransactAsync(
	"ambiguous-operation",
	function(data)
		local next_data = table.clone(data)
		next_data.coins += 2
		return next_data, { coins_granted = 2 }
	end,
	{ request = { action = "ambiguous", amount = 2 } }
)
assert(ambiguous_status == "committed", "ambiguous TransactAsync status=" .. tostring(ambiguous_status) .. " message=" .. tostring(ambiguous_message))
assert(ambiguous_result.coins_granted == 2)
assert(ambiguous_record:Get().coins == 6,
	"commit-then-response-loss must reconcile from the durable receipt without applying twice")



local receipt_test_now = 1000
Mock.set_test_clock(function()
	return receipt_test_now
end)

local function exercise_receipt_capacity_and_retention(kind)
	local prefix = if kind == "inbox" then "InboxReceiptCapacity" else "TransactionReceiptCapacity"
	local store_name = prefix
	local record = Mock.new(store_name, "global", "profile", {
		schema_version = 1,
		transactional_operations_enabled = true,
	})
	local opened, open_message = record:Open({ count = 0 })
	assert(opened == "success" or opened == "created",
		prefix .. " open status=" .. tostring(opened) .. " message=" .. tostring(open_message))

	local function execute(operation_id, request)
		local function reducer(data)
			local next_data = table.clone(data)
			next_data.count += 1
			return next_data
		end
		if kind == "inbox" then
			return record:ApplyInboxAsync(
				operation_id,
				"ReceiptCapacityMessage",
				request,
				reducer,
				{ receipt_retention_seconds = 1 }
			)
		end
		return record:TransactAsync(operation_id, reducer, {
			request = request,
			receipt_retention_seconds = 1,
		})
	end

	local successful_count = 0
	local last_operation_id = nil
	local last_request = nil
	local reached_capacity = false
	for index = 1, 258 do
		local operation_id = (if kind == "inbox" then "i" else "t") .. tostring(index)
		local request = { index = index }
		local _, status, message = execute(operation_id, request)
		if status == "committed" then
			successful_count += 1
			last_operation_id = operation_id
			last_request = request
		elseif status == "capacity" then
			reached_capacity = true
			break
		else
			error(prefix .. " expected commit or capacity, got " .. tostring(status)
				.. ": " .. tostring(message))
		end
	end
	assert(reached_capacity, prefix .. " never reported receipt capacity")
	assert(successful_count > 0 and successful_count < 258,
		prefix .. " receipt-capacity boundary was not reached")

	local before_overflow = Mock.get_record_raw(store_name, "global", "profile")
	local before_data = record:Get()
	assert(before_data.count == successful_count, prefix .. " successful receipt count disagrees with profile data")
	local _, overflow_status = execute("overflow-" .. kind, { index = 9999 })
	assert(overflow_status == "capacity", prefix .. " did not preserve capacity backpressure")
	local after_overflow = Mock.get_record_raw(store_name, "global", "profile")
	assert(after_overflow.revision == before_overflow.revision,
		prefix .. " capacity failure changed the durable revision")
	assert(after_overflow.data.count == before_overflow.data.count,
		prefix .. " capacity failure mutated profile data")

	local _, duplicate_status = execute(last_operation_id, last_request)
	assert(duplicate_status == "duplicate",
		prefix .. " full capacity must still honor an unexpired idempotency receipt")
	assert(record:Get().count == successful_count,
		prefix .. " duplicate receipt applied the reducer a second time")

	receipt_test_now += 2
	local _, after_expiry_status, after_expiry_message = execute(
		"after-expiry-" .. kind,
		{ index = 10000 }
	)
	assert(after_expiry_status == "committed",
		prefix .. " did not reclaim expired receipts: " .. tostring(after_expiry_message))
	local after_expiry = Mock.get_record_raw(store_name, "global", "profile")
	local collection = if kind == "inbox"
		then after_expiry.sidecars.inbox_receipts
		else after_expiry.sidecars.transaction_receipts
	local retained_count = 0
	for _ in pairs(collection) do retained_count += 1 end
	assert(retained_count == 1,
		prefix .. " expiry cleanup should retain only the newly committed receipt")
	assert(after_expiry.data.count == successful_count + 1,
		prefix .. " expiry cleanup did not apply exactly one new operation")
	assert(after_expiry.revision == before_overflow.revision + 1,
		prefix .. " capacity/retention recovery advanced the wrong revision")
	record:Close()
end

exercise_receipt_capacity_and_retention("transaction")
exercise_receipt_capacity_and_retention("inbox")

local outbox_batch_record = Mock.new("OutboxBatchLimitTest", "global", "profile", {
	schema_version = 1,
	transactional_operations_enabled = true,
})
local outbox_batch_open, outbox_batch_open_message = outbox_batch_record:Open({ coins = 0 })
assert(outbox_batch_open == "created" or outbox_batch_open == "loaded" or outbox_batch_open == "success",
	"outbox batch-limit profile open status=" .. tostring(outbox_batch_open)
		.. " message=" .. tostring(outbox_batch_open_message))
local outbox_batch_before = Mock.get_record_raw("OutboxBatchLimitTest", "global", "profile")
local oversized_batch = {}
for index = 1, 17 do
	oversized_batch[index] = {
		target_store = "OutboxBatchDestination",
		target_scope = "global",
		target_key = "recipient-" .. tostring(index),
		type = "BatchLimitCheck",
		payload_version = 1,
		data = { index = index },
	}
end
local oversized_reducer_calls = 0
local oversized_result, oversized_status = outbox_batch_record:CommitWithOutboxAsync(
	"outbox-batch-over-limit",
	"BatchLimitCheck",
	{ count = #oversized_batch },
	oversized_batch,
	function(data)
		oversized_reducer_calls += 1
		local next_data = table.clone(data)
		next_data.coins += 1
		return next_data
	end
)
assert(oversized_result == nil and oversized_status == "invalid",
	"outbox batch exceeding 16 events must be rejected")
assert(oversized_reducer_calls == 0, "outbox batch validation failure invoked the reducer")
local outbox_batch_after = Mock.get_record_raw("OutboxBatchLimitTest", "global", "profile")
assert(outbox_batch_after.revision == outbox_batch_before.revision,
	"rejected outbox batch advanced the durable revision")
assert(outbox_batch_after.data.coins == outbox_batch_before.data.coins,
	"rejected outbox batch mutated profile data")
local outbox_batch_sidecars = outbox_batch_after.sidecars
assert(outbox_batch_sidecars == nil or next(outbox_batch_sidecars.outbox_events) == nil,
	"rejected outbox batch wrote outbox entries")
outbox_batch_record:Close()

local sidecar_record = Mock.new("OutboxSidecarSaturationTest", "global", "profile", {
	schema_version = 1,
	transactional_operations_enabled = true,
})
local sidecar_open, sidecar_open_message = sidecar_record:Open({ grants = 0 })
assert(sidecar_open == "created" or sidecar_open == "loaded" or sidecar_open == "success",
	"outbox sidecar profile open status=" .. tostring(sidecar_open)
		.. " message=" .. tostring(sidecar_open_message))
local sidecar_payload = string.rep("x", 1500)
local sidecar_success_count = 0
local sidecar_capacity_reached = false
for index = 1, 20 do
	local commit_key = "sidecar-saturation-" .. tostring(index)
	local before_attempt = Mock.get_record_raw("OutboxSidecarSaturationTest", "global", "profile")
	local _, status, message = sidecar_record:CommitWithOutboxAsync(
		commit_key,
		"SidecarSaturation",
		{ index = index },
		{
			{
				target_store = "OutboxSidecarDestination",
				target_scope = "global",
				target_key = "recipient",
				type = "LargePayload",
				payload_version = 1,
				data = sidecar_payload,
			},
		},
		function(data)
			local next_data = table.clone(data)
			next_data.grants += 1
			return next_data
		end
	)
	if status == "committed" then
		sidecar_success_count += 1
	elseif status == "capacity" then
		sidecar_capacity_reached = true
		local after_rejection = Mock.get_record_raw("OutboxSidecarSaturationTest", "global", "profile")
		assert(after_rejection.revision == before_attempt.revision,
			"sidecar saturation rejection advanced the durable revision")
		assert(after_rejection.data.grants == before_attempt.data.grants,
			"sidecar saturation rejection mutated profile data")
		assert(string.find(message or "", "encoded-size limit", 1, true) ~= nil,
			"sidecar saturation must report the encoded-size boundary: " .. tostring(message))
		break
	else
		error("outbox sidecar saturation returned unexpected status " .. tostring(status)
			.. ": " .. tostring(message))
	end
end
assert(sidecar_capacity_reached, "sidecar saturation did not enforce the encoded-size limit")
assert(sidecar_success_count > 0 and sidecar_success_count < 20,
	"sidecar saturation boundary was not reached between commits")
local sidecar_raw = Mock.get_record_raw("OutboxSidecarSaturationTest", "global", "profile")
local sidecar_entries = 0
for _ in pairs(sidecar_raw.sidecars.outbox_events) do sidecar_entries += 1 end
assert(sidecar_entries == sidecar_success_count,
	"sidecar capacity failure persisted an event without a committed receipt")
sidecar_record:Close()

Mock.reset()
Shim.close()
