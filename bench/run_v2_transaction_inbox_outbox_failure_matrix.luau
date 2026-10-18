--!nocheck
-- Exercises transaction, inbox and outbox durability through RecordStore.new()
-- using the deterministic DataStore service fake. This is not live Roblox evidence.
local Shim = require("./RobloxShim")
local Fake = Shim.FakeDataStore
local RecordStore = Shim.load_isolated("transaction-inbox-outbox-failure-matrix")
local V2Module = require("../src/PlayerDataInitializer/RecordStoreV2")
local MailboxV2 = require("../src/PlayerDataInitializer/RecordStoreMailboxV2")
local V2 = V2Module.new(RecordStore, MailboxV2, { allow_unattested_activation = true })

local now_ms = 1_800_000_000_000
Fake:Reset()
Fake:SetClock(function() return now_ms end)

local STORE = "RecordStoreTransactionInboxOutboxMatrix"
local SCOPE = "global"
local USER_ID = 654789321
local passed = 0

local function group(name, callback)
	local ok, message = pcall(callback)
	assert(ok, ("[TRANSACTION/INBOX/OUTBOX MATRIX] %s failed: %s"):format(name, tostring(message)))
	passed += 1
end

local function new_record(key)
	return RecordStore.new(STORE, SCOPE, key, {
		schema_version = 1,
		retry_attempts = 2,
		lease_duration = 60,
		lease_renewal = 10,
		operation_deadline = 5,
		user_ids = { USER_ID },
		metadata = { fixture = "transaction-inbox-outbox-failure-matrix" },
		messaging_enabled = false,
		takeover_enabled = false,
		autosave_interval = 3600,
		queue_poll_interval = 3600,
	})
end

local function open_record(key)
	local record = new_record(key)
	local code, message = record:Open({ coins = 0, note = "seed" })
	assert(code == "created" or code == "loaded", tostring(message))
	return record
end

local function increment(field, amount)
	return function(current)
		assert(type(current) == "table", "transaction reducer received non-table data")
		local changed = table.clone(current)
		changed[field] = (changed[field] or 0) + amount
		return changed
	end
end

local function schedule_update_fault(key, mode)
	Fake:ScheduleFault("update", STORE, SCOPE, key, mode, {
		message = "injected " .. mode .. " update fault for " .. key,
	})
end

local function assert_fault_consumed(context)
	assert(Fake:Stats().faults_remaining == 0, context .. ": injected fault was not consumed")
end

group("01 transaction retries before-commit failure exactly once", function()
	local key = "tx-before-commit"
	local record = open_record(key)
	schedule_update_fault(key, "before")
	local code, message = record:TransactAsync(
		"tx-before-1",
		"coins:5",
		increment("coins", 5),
		"request:coins:5"
	)
	assert(code == "success", tostring(message))
	assert_fault_consumed("transaction before-commit")
	assert(record:Get().coins == 5, "transaction retry applied an incorrect in-memory value")
	local duplicate = record:TransactAsync(
		"tx-before-1", "coins:5", increment("coins", 5), "request:coins:5"
	)
	assert(duplicate == "duplicate", "same transaction request was not deduplicated")
	assert(record:Get().coins == 5, "same transaction request applied twice")
	local conflict = record:TransactAsync(
		"tx-before-1", "coins:999", increment("coins", 999), "request:coins:999"
	)
	assert(conflict == "conflict", "reused operation ID with different request was accepted")
	assert(record:Get().coins == 5, "conflicting transaction changed profile data")
end)

group("02 transaction reconciles commit-then-response-loss", function()
	local key = "tx-after-commit"
	local record = open_record(key)
	schedule_update_fault(key, "after")
	local code, message = record:TransactAsync(
		"tx-after-1",
		"coins:7",
		increment("coins", 7),
		"request:coins:7"
	)
	assert(code == "success", tostring(message))
	assert_fault_consumed("transaction commit-then-error")
	assert(record:Get().coins == 7, "ambiguous transaction was not rebased to the committed value")
	local duplicate = record:TransactAsync(
		"tx-after-1", "coins:7", increment("coins", 7), "request:coins:7"
	)
	assert(duplicate == "duplicate", "committed transaction receipt was not durable")
	assert(record:Get().coins == 7, "transaction retry applied a second grant")
end)

group("03 inbox receipt and mutation survive response loss", function()
	local key = "inbox-after-commit"
	local record = open_record(key)
	schedule_update_fault(key, "after")
	local code, message = record:ApplyInboxAsync(
		"message-receipt-1",
		"message:coins:11",
		increment("coins", 11),
		"canonical:message:coins:11"
	)
	assert(code == "success", tostring(message))
	assert_fault_consumed("inbox commit-then-error")
	assert(record:Get().coins == 11, "inbox mutation was lost or applied twice")
	local duplicate = record:ApplyInboxAsync(
		"message-receipt-1",
		"message:coins:11",
		increment("coins", 11),
		"canonical:message:coins:11"
	)
	assert(duplicate == "duplicate", "inbox redelivery was not deduplicated")
	local conflict = record:ApplyInboxAsync(
		"message-receipt-1",
		"message:coins:12",
		increment("coins", 12),
		"canonical:message:coins:12"
	)
	assert(conflict == "conflict", "inbox receipt accepted different request material")
	assert(record:Get().coins == 11, "inbox conflict changed profile data")
end)

group("04 inbox batch is atomic and message-idempotent", function()
	local key = "inbox-batch"
	local record = open_record(key)
	local items = {
		{ message_id = "batch-message-1", message_type = "reward", payload_version = 1, payload = { coins = 3 } },
		{ message_id = "batch-message-2", message_type = "reward", payload_version = 1, payload = { coins = 4 } },
	}
	local function reducer(current, payload)
		local changed = table.clone(current)
		changed.coins = (changed.coins or 0) + payload.coins
		return changed
	end

	local malformed_option_record = open_record("inbox-batch-malformed-limit")
	local malformed_option_result = V2.Inbox.ApplyBatch(
		malformed_option_record, "batch-malformed-limit", items, reducer, { max_batch_items = "not-a-number" }
	)
	assert(malformed_option_result.code == "committed",
		"malformed optional batch limit raised or corrupted the inbox result")
	assert(malformed_option_record:Get().coins == 7,
		"safe default batch limit did not process the bounded valid batch")

	schedule_update_fault(key, "after")
	local first = V2.Inbox.ApplyBatch(record, "batch-operation-1", items, reducer)
	assert(first.code == "committed", tostring(first.message))
	assert_fault_consumed("inbox batch commit-then-error")
	assert(first.applied == 2 and first.duplicates == 0, "initial batch result counters were incorrect")
	assert(record:Get().coins == 7, "initial inbox batch did not apply both messages atomically")

	local retry = V2.Inbox.ApplyBatch(record, "batch-operation-1", items, reducer)
	assert(retry.code == "duplicate", "same batch ID was not deduplicated")
	assert(record:Get().coins == 7, "same batch retry applied its effects twice")

	local repeated_messages = V2.Inbox.ApplyBatch(record, "batch-operation-2", items, reducer)
	assert(repeated_messages.code == "committed", tostring(repeated_messages.message))
	assert(repeated_messages.applied == 0 and repeated_messages.duplicates == 2,
		"new batch ID did not deduplicate already-applied message IDs")
	assert(record:Get().coins == 7, "repeated messages under a new batch ID changed profile data")
end)

group("05 outbox intent commits atomically and dispatch response loss recovers", function()
	local key = "outbox-single"
	local record = open_record(key)
	local events = {
		{
			EventId = "outbox-event-single",
			DestinationStoreName = "RecordStoreDestination",
			DestinationScope = SCOPE,
			DestinationProfileKey = "recipient-single",
			MessageType = "reward",
			Data = { coins = 13 },
		},
	}

	schedule_update_fault(key, "after")
	local code, message = record:CommitWithOutboxAsync(
		"outbox-transaction-1", "coins:13", increment("coins", 13), events, "request:outbox:13"
	)
	assert(code == "success", tostring(message))
	assert_fault_consumed("outbox transaction commit-then-error")
	assert(record:Get().coins == 13, "outbox transaction data was not committed")
	local duplicate = record:CommitWithOutboxAsync(
		"outbox-transaction-1", "coins:13", increment("coins", 13), events, "request:outbox:13"
	)
	assert(duplicate == "duplicate", "outbox transaction retry did not deduplicate")
	assert(record:Get().coins == 13, "duplicate outbox transaction changed profile data")

	local pending, read_code, read_message = record:GetOutboxAsync(10)
	assert(read_code == "success", tostring(read_message))
	assert(#pending == 1 and pending[1].EventId == "outbox-event-single",
		"committed outbox intent was not durably discoverable")
	assert(pending[1].State == "pending" and pending[1].Data.coins == 13,
		"committed outbox event had invalid state or payload")

	local dispatch_calls = 0
	schedule_update_fault(key, "after")
	local dispatched, dispatch_code, dispatch_message = record:DispatchOutboxAsync(function(event)
		dispatch_calls += 1
		assert(event.EventId == "outbox-event-single", "dispatcher received a different event ID")
		return true, "destination-receipt-single"
	end, 1)
	assert(dispatch_code == "success", tostring(dispatch_message))
	assert_fault_consumed("outbox acknowledgement commit-then-error")
	assert(dispatched == 1 and dispatch_calls == 1,
		"dispatch reconciliation returned the wrong count or repeated the callback")
	local empty, empty_code, empty_message = record:GetOutboxAsync(10)
	assert(empty_code == "success", tostring(empty_message))
	assert(#empty == 0, "confirmed outbox dispatch remained pending")
end)

group("06 batched outbox dispatch retries source write without repeating callbacks", function()
	local key = "outbox-batch"
	local record = open_record(key)
	local events = {
		{
			EventId = "outbox-event-batch-1",
			DestinationStoreName = "RecordStoreDestination",
			DestinationScope = SCOPE,
			DestinationProfileKey = "recipient-batch-1",
			MessageType = "reward",
			Data = { coins = 2 },
		},
		{
			EventId = "outbox-event-batch-2",
			DestinationStoreName = "RecordStoreDestination",
			DestinationScope = SCOPE,
			DestinationProfileKey = "recipient-batch-2",
			MessageType = "reward",
			Data = { coins = 3 },
		},
	}
	local code, message = record:CommitWithOutboxAsync(
		"outbox-batch-transaction", "coins:5", increment("coins", 5), events, "request:outbox:batch"
	)
	assert(code == "success", tostring(message))
	assert(record:Get().coins == 5, "batch fixture transaction did not commit")

	local callback_ids = {}
	schedule_update_fault(key, "before")
	local dispatched, dispatch_code, dispatch_message = record:DispatchOutboxBatchAsync(function(event)
		table.insert(callback_ids, event.EventId)
		return true, "receipt:" .. event.EventId
	end, 2)
	assert(dispatch_code == "success", tostring(dispatch_message))
	assert_fault_consumed("batched outbox before-commit")
	assert(dispatched == 2 and #callback_ids == 2, "batch dispatch did not confirm both events")
	assert(callback_ids[1] ~= callback_ids[2], "batch dispatcher invoked the same event ID twice")
	local pending, read_code, read_message = record:GetOutboxAsync(10)
	assert(read_code == "success", tostring(read_message))
	assert(#pending == 0, "batch-dispatched events remained pending")
end)

group("08 outbox helper inputs fail closed", function()
	local dispatch = V2.Outbox.DispatchBatches(nil, nil, "invalid", "invalid")
	assert(dispatch.code == "invalid" and dispatch.dispatched == 0,
		"outbox batch dispatch did not reject missing record/dispatcher")
	local prune_outbox = V2.Outbox.PruneBatches(nil, "invalid", "invalid", "invalid")
	assert(prune_outbox.code == "invalid" and prune_outbox.pruned == 0,
		"outbox retention helper did not reject malformed inputs")
	local prune_receipts = V2.Outbox.PruneTransactionReceiptsBatches(nil, "invalid", "invalid", "invalid")
	assert(prune_receipts.code == "invalid" and prune_receipts.pruned == 0,
		"transaction receipt retention helper did not reject malformed inputs")
end)

group("09 inbox/outbox stats are exact for one durable envelope", function()
	local key = "sidecar-stats"
	local record = open_record(key)
	local inbox_code, inbox_message = record:ApplyInboxAsync(
		"stats-inbox-receipt", "stats-inbox:v1", increment("coins", 2), "stats-inbox:canonical"
	)
	assert(inbox_code == "success", tostring(inbox_message))

	local events = {
		{
			EventId = "stats-outbox-event-1",
			DestinationStoreName = "RecordStoreDestination",
			DestinationScope = SCOPE,
			DestinationProfileKey = "stats-recipient-1",
			MessageType = "reward",
			Data = { coins = 1 },
		},
		{
			EventId = "stats-outbox-event-2",
			DestinationStoreName = "RecordStoreDestination",
			DestinationScope = SCOPE,
			DestinationProfileKey = "stats-recipient-2",
			MessageType = "reward",
			Data = { coins = 2 },
		},
	}
	local commit_code, commit_message = record:CommitWithOutboxAsync(
		"stats-outbox-commit", "stats-outbox:v1", increment("coins", 3), events, "stats-outbox:request"
	)
	assert(commit_code == "success", tostring(commit_message))

	local inbox_stats, inbox_code = record:GetInboxStatsAsync()
	assert(inbox_code == "success", tostring(inbox_code))
	assert(inbox_stats.consistency == "single_envelope_read"
		and inbox_stats.completeness == "complete_for_observed_envelope"
		and inbox_stats.exactness == "exact_for_observed_envelope"
		and type(inbox_stats.observed_at) == "number",
		"inbox stats omitted snapshot scope or observation metadata")
	assert(inbox_stats.receipt_count >= 1 and type(inbox_stats.oldest_receipt_age_seconds) == "number",
		"inbox stats omitted durable receipt count or age")

	local pending_stats, outbox_code = record:GetOutboxStatsAsync()
	assert(outbox_code == "success", tostring(outbox_code))
	assert(pending_stats.pending_count == 2 and pending_stats.dispatched_count == 0
		and pending_stats.total_count == 2,
		"outbox stats returned wrong pending/dispatched counts")
	assert(type(pending_stats.oldest_pending_created_at) == "number"
		and type(pending_stats.oldest_pending_age_seconds) == "number",
		"outbox stats omitted oldest pending event age")

	local dispatched, dispatch_code, dispatch_message = record:DispatchOutboxAsync(function()
		return true, "stats-destination-receipt"
	end, 1)
	assert(dispatch_code == "success" and dispatched == 1, tostring(dispatch_message))
	local mixed_stats, mixed_code = RecordStore.get_outbox_stats_async(STORE, SCOPE, key)
	assert(mixed_code == "success", tostring(mixed_code))
	assert(mixed_stats.pending_count == 1 and mixed_stats.dispatched_count == 1
		and mixed_stats.total_count == 2,
		"module-level outbox stats did not report the mixed terminal states")
	assert(mixed_stats.max_dispatch_attempts >= 1 and type(mixed_stats.revision) == "number",
		"outbox stats omitted attempts or envelope revision")

	local module_inbox, module_inbox_code = RecordStore.get_inbox_stats_async(STORE, SCOPE, key)
	assert(module_inbox_code == "success" and module_inbox.receipt_count == inbox_stats.receipt_count,
		"module-level inbox stats differed from the active Record view")
	local invalid_stats, invalid_code = RecordStore.get_outbox_stats_async("", SCOPE, key)
	assert(invalid_code == "invalid" and next(invalid_stats) == nil,
		"module-level stats accepted an invalid store identity")

	local before_updates = Fake:Stats().calls.update
	local before_reads = Fake:Stats().calls.get
	local no_side_effect_stats, no_side_effect_code = record:GetOutboxStatsAsync()
	assert(no_side_effect_code == "success" and type(no_side_effect_stats.observed_at) == "number",
		"read-only outbox stats failed")
	local after_stats = Fake:Stats()
	assert(after_stats.calls.update == before_updates and after_stats.calls.get == before_reads + 1,
		"outbox stats mutated storage or performed more than one profile-key read")

	Fake:ScheduleFault("get", STORE, SCOPE, key, "before")
	local failed_record_stats, failed_record_code = record:GetInboxStatsAsync()
	assert(failed_record_code == "unknown" and next(failed_record_stats) == nil,
		"active Record inbox stats hid an unknown read outcome")
	Fake:ScheduleFault("get", STORE, SCOPE, key, "before")
	local failed_module_stats, failed_module_code = RecordStore.get_outbox_stats_async(STORE, SCOPE, key)
	assert(failed_module_code == "unknown" and next(failed_module_stats) == nil,
		"module-level outbox stats hid an unknown read outcome")

	record:Close()
end)

group("07 consumer reducers cannot modify RecordStore reserved sidecars", function()
	Fake:Reset()
	local record = open_record("reserved-sidecar-guard")
	local sidecar_key = "__recordstore_v2_test_sidecar"
	local seed_code, seed_message = record:TransactAsync(
		"seed-reserved-sidecar",
		"seed-reserved-sidecar:v1",
		function(current)
			local next_data = table.clone(current)
			next_data[sidecar_key] = { value = "must survive" }
			return next_data
		end,
		"seed-reserved-sidecar:v1"
	)
	assert(seed_code == "success", tostring(seed_message))
	local removal = V2.Transactions.Run(record, "consumer-remove-sidecar", { kind = "remove-reserved" }, function(current)
		local next_data = table.clone(current)
		next_data[sidecar_key] = nil
		next_data.coins += 1
		return next_data
	end)
	assert(removal.code == "invalid", "consumer reducer was allowed to remove a reserved sidecar")
	assert(record:Get().coins == 0 and record:Get()[sidecar_key].value == "must survive",
		"rejected sidecar removal mutated profile state")
	local insertion = V2.Transactions.Run(record, "consumer-add-sidecar", { kind = "add-reserved" }, function(current)
		local next_data = table.clone(current)
		next_data["__recordstore_v2_injected_sidecar"] = { injected = true }
		next_data.coins += 1
		return next_data
	end)
	assert(insertion.code == "invalid", "consumer reducer was allowed to create a reserved sidecar")
	assert(record:Get().coins == 0 and record:Get().__recordstore_v2_injected_sidecar == nil,
		"rejected sidecar insertion mutated profile state")
	local normal = V2.Transactions.Run(record, "consumer-normal-update", { kind = "safe-update" }, increment("coins", 2))
	assert(normal.code == "committed", "ordinary consumer mutation was rejected while preserving reserved fields")
	assert(record:Get().coins == 2 and record:Get()[sidecar_key].value == "must survive",
		"ordinary mutation failed to preserve a reserved sidecar")

	local migrations = V2.Migrations.new()
	local registered, register_error = migrations:Register(
		"reserved-sidecar-guard", 0, 1, "migration-reserved-sidecar", "revision-1",
		function(current)
			local changed = table.clone(current)
			changed[sidecar_key] = nil
			return changed
		end
	)
	assert(registered, tostring(register_error))
	local preview = migrations:Preview(record, "reserved-sidecar-guard", 1)
	assert(preview.code == "invalid",
		"migration preview accepted a transform that removes an internal reserved sidecar")
	local reserved_field_preview = migrations:Preview(record, "reserved-sidecar-guard", 1, { schema_field = sidecar_key })
	assert(reserved_field_preview.code == "invalid",
		"migration preview allowed a consumer-selected reserved sidecar as its schema marker")
	local reserved_field_migration = migrations:MigrateAsync(record, "reserved-sidecar-guard", 1, { schema_field = sidecar_key })
	assert(reserved_field_migration.code == "invalid",
		"migration execution allowed a consumer-selected reserved sidecar as its schema marker")
	assert(record:Get().coins == 2 and record:Get()[sidecar_key].value == "must survive",
		"rejected migration preview/execution mutated the active profile")
end)

print(("[PASS] %d transaction/inbox/outbox failure-recovery groups using the deterministic DataStore fake."):format(passed))
Shim.close()
