--!nocheck
-- Exercises transaction, inbox and outbox durability through RecordStore.new()
-- using the deterministic DataStore service fake. This is not live Roblox evidence.
local Shim = require("./RobloxShim")
local Fake = Shim.FakeDataStore
local RecordStore = Shim.load_isolated("transaction-inbox-outbox-failure-matrix")
local V2Module = require("../src/PlayerDataInitializer/RecordStoreV2")
local MailboxV2 = require("../src/PlayerDataInitializer/RecordStoreMailboxV2")
local V2 = V2Module.new(RecordStore, MailboxV2)

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

print(("[PASS] %d transaction/inbox/outbox failure-recovery groups using the deterministic DataStore fake."):format(passed))
Shim.close()
