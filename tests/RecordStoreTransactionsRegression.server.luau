--!nocheck
-- Direct regression coverage for the single-profile transaction and outbox APIs.
-- Uses RecordStore.Mock only; it never touches live DataStoreService.

local ServerScriptService = game:GetService("ServerScriptService")
local RecordStore = require(ServerScriptService.RecordStore)

RecordStore.Mock.reset()

local STORE = "RecordStoreTransactionRegression"
local SCOPE = "global"
local USER_ID = 987654321

local function make_record(key, initial_data)
	local record = RecordStore.Mock.new(STORE, SCOPE, key, {
		schema_version = 1,
		retry_attempts = 1,
		user_ids = { USER_ID },
		metadata = { test_marker = "transaction-regression" },
	})
	local opened, message = record:Open(initial_data)
	assert(opened == "created" or opened == "loaded", tostring(message))
	return record
end

local function increment(field, amount)
	return function(current)
		assert(type(current) == "table", "transaction received non-table profile data")
		local next_data = table.clone(current)
		next_data[field] = (next_data[field] or 0) + amount
		return next_data
	end
end

local function count_keys(value)
	local count = 0
	for _ in value or {} do
		count += 1
	end
	return count
end

local record = make_record("player-main", { coins = 0, note = "initial" })

-- A transaction commits the profile mutation and operation receipt together.
local committed, commit_message = record:TransactAsync("tx-grant-1", "grant:100-coins", increment("coins", 100))
assert(committed == "success", tostring(commit_message))
assert(record:Get().coins == 100, "committed transaction did not update in-memory profile data")

local raw = RecordStore.Mock.get_record_raw(STORE, SCOPE, "player-main")
assert(type(raw) == "table" and type(raw.data) == "table", "transaction envelope was not persisted")
assert(raw.data.coins == 100, "transaction data was not persisted")
assert(type(raw.inbox_receipts) == "table" and raw.inbox_receipts["tx-grant-1"] ~= nil,
	"transaction mutation did not persist its receipt in the same profile envelope")

-- A retry with the same operation identity must not apply the mutation twice.
local duplicate = record:TransactAsync("tx-grant-1", "grant:100-coins", increment("coins", 100))
assert(duplicate == "duplicate", "same operation ID and fingerprint was not reported as duplicate")
assert(record:Get().coins == 100, "duplicate transaction applied the grant twice")

-- Reusing an operation ID with another request must fail closed.
local conflict = record:TransactAsync("tx-grant-1", "grant:999-coins", increment("coins", 999))
assert(conflict == "conflict", "operation ID reused with a different fingerprint was not rejected")
assert(record:Get().coins == 100, "conflicting transaction changed profile data")

local invalid_identity = record:TransactAsync("", "invalid", increment("coins", 1))
assert(invalid_identity == "invalid", "empty transaction operation ID was accepted")
local transform_error = record:TransactAsync("tx-transform-error", "throws", function()
	error("expected transaction reducer failure")
end)
assert(transform_error == "validation", "a throwing transaction transform did not fail validation")
assert(record:Get().coins == 100, "failed transaction transform changed profile data")

-- Unflushed ordinary edits must not be silently overwritten by a transaction.
local update_result, update_message = record:Update(function(current)
	local next_data = table.clone(current)
	next_data.note = "changed locally"
	return next_data
end)
assert(update_result == "success", tostring(update_message))
local dirty_transaction = record:TransactAsync("tx-while-dirty", "dirty-profile", increment("coins", 1))
assert(dirty_transaction == "busy", "transaction did not reject unflushed ordinary profile edits")
local save_result, save_message = record:Save("transaction-regression")
assert(save_result == "success" or save_result == "saved", tostring(save_message))

-- Inbox application shares the profile-key receipt boundary and is idempotent.
local inbox_first, inbox_message = record:ApplyInboxAsync("message-1", "message:coins:25", increment("coins", 25))
assert(inbox_first == "success", tostring(inbox_message))
local inbox_duplicate = record:ApplyInboxAsync("message-1", "message:coins:25", increment("coins", 25))
assert(inbox_duplicate == "duplicate", "duplicate inbox message was not recognized")
assert(record:Get().coins == 125, "duplicate inbox delivery applied its effect twice")

local event_main = {
	{
		EventId = "event-main",
		DestinationStoreName = "RecordStoreDestination",
		DestinationScope = "global",
		DestinationProfileKey = "recipient-1",
		MessageType = "reward",
		Data = { coins = 10 },
		},
}
local outbox_commit, outbox_message = record:CommitWithOutboxAsync(
	"tx-outbox-main",
	"source:grant:10",
	increment("coins", 10),
	event_main
)
assert(outbox_commit == "success", tostring(outbox_message))
assert(record:Get().coins == 135, "outbox transaction did not commit profile data")

local pending, pending_code, pending_message = record:GetOutboxAsync(10)
assert(pending_code == "success", tostring(pending_message))
assert(#pending == 1 and pending[1].EventId == "event-main", "outbox intent was not durably discoverable")
assert(pending[1].State == "pending" and pending[1].Attempts == 0, "new outbox event has an invalid initial state")
assert(pending[1].Data.coins == 10, "outbox payload changed during persistence")

-- Repeating the source transaction must not create another outbox event.
local outbox_duplicate = record:CommitWithOutboxAsync(
	"tx-outbox-main",
	"source:grant:10",
	increment("coins", 10),
	event_main
)
assert(outbox_duplicate == "duplicate", "duplicate outbox transaction was not recognized")
assert(record:Get().coins == 135, "duplicate outbox transaction applied its data mutation twice")
pending, pending_code, pending_message = record:GetOutboxAsync(10)
assert(pending_code == "success", tostring(pending_message))
assert(#pending == 1, "duplicate outbox transaction created an additional event")

-- Event IDs are unique within the source profile, even across distinct operations.
local event_collision, collision_message = record:CommitWithOutboxAsync(
	"tx-outbox-collision",
	"source:collision",
	increment("coins", 999),
	event_main
)
assert(event_collision == "conflict", "a different transaction reused an existing outbox event ID")
assert(record:Get().coins == 135, "outbox event-ID conflict partially applied its profile mutation")

local invalid_outbox_limit, invalid_outbox_limit_code = record:GetOutboxAsync(0)
assert(invalid_outbox_limit_code == "invalid", "outbox accepted an invalid page size")

-- A rejected destination attempt stays pending and can be retried with the same ID.
local failed_count, failed_code, failed_message = record:DispatchOutboxAsync(function(event)
	assert(event.EventId == "event-main", "dispatcher received an unexpected event")
	return false, "destination temporarily unavailable"
end, 1)
assert(failed_count == 0 and failed_code == "success" and failed_message ~= nil,
	"destination rejection was not surfaced as a pending retry")
pending, pending_code, pending_message = record:GetOutboxAsync(10)
assert(pending_code == "success", tostring(pending_message))
assert(#pending == 1 and pending[1].State == "pending" and pending[1].Attempts == 1,
	"rejected outbox event was not retained for retry")

local accepted_calls = 0
local dispatched_count, dispatch_code, dispatch_message = record:DispatchOutboxAsync(function(event)
	accepted_calls += 1
	assert(event.EventId == "event-main", "retry changed the outbox event ID")
	return true, "destination-receipt-main"
end, 1)
assert(dispatched_count == 1 and dispatch_code == "success", tostring(dispatch_message))
assert(accepted_calls == 1, "successful destination dispatcher did not run exactly once in this attempt")
pending, pending_code, pending_message = record:GetOutboxAsync(10)
assert(pending_code == "success", tostring(pending_message))
assert(#pending == 0, "successfully dispatched event remained pending")

-- Create a second pending event, then ensure Save/Close/Open preserve both sidecars.
local event_after_restart = {
	{
		EventId = "event-after-reopen",
		DestinationStoreName = "RecordStoreDestination",
		DestinationScope = "global",
		DestinationProfileKey = "recipient-2",
		MessageType = "reward",
		Data = { coins = 3 },
		},
}
local second_outbox, second_outbox_message = record:CommitWithOutboxAsync(
	"tx-outbox-after-reopen",
	"source:grant:3",
	increment("coins", 3),
	event_after_restart
)
assert(second_outbox == "success", tostring(second_outbox_message))
assert(record:Get().coins == 138, "second outbox transaction data was not committed")

local update_after_tx, update_after_tx_message = record:Update(function(current)
	local next_data = table.clone(current)
	next_data.note = "saved after transaction"
	return next_data
end)
assert(update_after_tx == "success", tostring(update_after_tx_message))
local save_after_tx, save_after_tx_message = record:Save("sidecar-preservation")
assert(save_after_tx == "success" or save_after_tx == "saved", tostring(save_after_tx_message))

raw = RecordStore.Mock.get_record_raw(STORE, SCOPE, "player-main")
assert(raw.inbox_receipts["tx-grant-1"] ~= nil, "ordinary Save dropped transaction receipts")
assert(raw.outbox["event-after-reopen"] ~= nil, "ordinary Save dropped pending outbox intent")
assert(raw.outbox["event-main"] ~= nil and raw.outbox["event-main"].state == "dispatched",
	"ordinary Save dropped dispatched outbox history")

local closed, close_message = record:Close()
assert(closed == "closed", tostring(close_message))
local reopened, reopen_message = record:Open({ coins = -1, note = "should not replace durable data" })
assert(reopened == "loaded", tostring(reopen_message))
assert(record:Get().coins == 138, "close/reopen lost committed profile data")
assert(record:Get().note == "saved after transaction", "close/reopen lost the ordinary saved edit")
assert(record:GetUserIds()[1] == USER_ID, "transaction/lifecycle writes lost associated user IDs")
assert(record:GetMetadata().test_marker == "transaction-regression", "transaction/lifecycle writes lost user metadata")

local replay_after_reopen = record:TransactAsync("tx-grant-1", "grant:100-coins", increment("coins", 100))
assert(replay_after_reopen == "duplicate", "transaction receipt did not survive close/reopen")
assert(record:Get().coins == 138, "post-reopen transaction retry applied its effect twice")
pending, pending_code, pending_message = record:GetOutboxAsync(10)
assert(pending_code == "success", tostring(pending_message))
assert(#pending == 1 and pending[1].EventId == "event-after-reopen",
	"pending outbox intent did not survive close/reopen")

local dispatched_after_reopen, after_reopen_code, after_reopen_message = record:DispatchOutboxAsync(function(event)
	assert(event.EventId == "event-after-reopen", "post-reopen dispatcher received the wrong event")
	return true, "destination-receipt-after-reopen"
end, 1)
assert(dispatched_after_reopen == 1 and after_reopen_code == "success", tostring(after_reopen_message))

-- An injected backend uncertainty is not reported as a committed transaction.
-- The mock's injected failure occurs before persistence, so this case checks that
-- RecordStore does not invent a receipt or mutate data after a known no-write fixture.
local uncertain_record = make_record("before-commit-unknown", { coins = 0 })
RecordStore.Mock.set_update_failures(1, "unknown", "injected failure before persistence")
local uncertain_result = uncertain_record:TransactAsync(
	"tx-unknown",
	"unknown:grant:5",
	increment("coins", 5)
)
assert(uncertain_result == "unknown", "unresolved backend result was not reported as unknown")
local uncertain_raw = RecordStore.Mock.get_record_raw(STORE, SCOPE, "before-commit-unknown")
assert(uncertain_raw.data.coins == 0, "mock pre-commit failure changed persisted profile data")
assert(
	uncertain_raw.inbox_receipts == nil or uncertain_raw.inbox_receipts["tx-unknown"] == nil,
	"mock pre-commit failure persisted a transaction receipt"
)

-- Model the other critical ambiguity: UpdateAsync commits, then the response is lost.
-- In this case the operation result is still unknown, but durable data and its receipt
-- must agree so a later session can deduplicate the same operation ID.
local committed_unknown_record = make_record("after-commit-unknown", { coins = 0 })
RecordStore.Mock.set_update_response_losses(1, "injected response loss after persistence")
local committed_unknown_result = committed_unknown_record:TransactAsync(
	"tx-commit-response-lost",
	"unknown:grant:5",
	increment("coins", 5)
)
assert(committed_unknown_result == "unknown",
	"commit-then-response-loss was incorrectly reported as a confirmed success")
local committed_unknown_raw = RecordStore.Mock.get_record_raw(STORE, SCOPE, "after-commit-unknown")
assert(committed_unknown_raw.data.coins == 5,
	"commit-then-response-loss did not preserve the committed profile mutation")
local committed_receipt = committed_unknown_raw.inbox_receipts["tx-commit-response-lost"]
assert(type(committed_receipt) == "table",
	"commit-then-response-loss persisted the mutation without its transaction receipt")
assert(committed_receipt.request_fingerprint == "unknown:grant:5",
	"commit-then-response-loss persisted a receipt for a different request")
assert(committed_receipt.revision == committed_unknown_raw.revision,
	"commit-then-response-loss persisted a receipt at a different revision")

-- Receipt capacity must abort the next profile mutation instead of partially applying it.
local capacity_record = make_record("receipt-capacity", { count = 0 })
for index = 1, 128 do
	local operation_id = "capacity-" .. tostring(index)
	local status, message = capacity_record:TransactAsync(operation_id, "fp-" .. tostring(index), increment("count", 1))
	assert(status == "success", ("receipt-capacity setup failed at %d: %s %s"):format(index, tostring(status), tostring(message)))
end
assert(capacity_record:Get().count == 128, "receipt-capacity setup lost a committed mutation")
local capacity_result = capacity_record:TransactAsync("capacity-overflow", "fp-overflow", increment("count", 1))
assert(capacity_result == "capacity", "transaction receipt capacity did not apply backpressure")
assert(capacity_record:Get().count == 128, "receipt overflow partially changed profile data")
local capacity_raw = RecordStore.Mock.get_record_raw(STORE, SCOPE, "receipt-capacity")
assert(count_keys(capacity_raw.inbox_receipts) == 128, "receipt capacity exceeded its configured bound")

-- The public Luau signatures name the pruning cutoff *_ms. A cutoff one minute
-- in the past must not delete recently committed receipts or outbox events.
-- These assertions intentionally catch the current seconds-vs-milliseconds bug.
local retention_failures = {}
local function expect_retained(count, code, label)
	if count ~= 0 or code ~= "duplicate" then
		table.insert(retention_failures, ("%s: expected 0 pruned and duplicate/no-op, got count=%s code=%s")
			:format(label, tostring(count), tostring(code)))
	end
end

local function expect_pruned(count, code, label)
	if count ~= 1 or code ~= "success" then
		table.insert(retention_failures, ("%s: expected one pruned and success, got count=%s code=%s")
			:format(label, tostring(count), tostring(code)))
	end
end
local recent_cutoff_ms = DateTime.now().UnixTimestampMillis - 60_000
local receipt_pruned, receipt_prune_code = record:PruneTransactionReceiptsAsync(recent_cutoff_ms, 1)
expect_retained(receipt_pruned, receipt_prune_code, "recent transaction receipt retention")
local outbox_pruned, outbox_prune_code = record:PruneOutboxAsync(recent_cutoff_ms, 1)
expect_retained(outbox_pruned, outbox_prune_code, "recent outbox event retention")

-- A future millisecond cutoff must make old-enough entries eligible, proving both
-- the no-op and deletion paths use the same public time unit.
local future_cutoff_ms = DateTime.now().UnixTimestampMillis + 60_000
local eligible_receipts, eligible_receipts_code = record:PruneTransactionReceiptsAsync(future_cutoff_ms, 1)
expect_pruned(eligible_receipts, eligible_receipts_code, "eligible transaction receipt pruning")
local eligible_outbox, eligible_outbox_code = record:PruneOutboxAsync(future_cutoff_ms, 1)
expect_pruned(eligible_outbox, eligible_outbox_code, "eligible outbox pruning")

-- Retention is based on dispatch time, not creation time: an old event dispatched
-- recently must remain available for the configured post-dispatch retention window.
local fake_now = DateTime.now().UnixTimestampMillis / 1000
RecordStore.Mock.set_test_clock(function()
	return fake_now
end)
local dispatch_time_record = make_record("outbox-dispatch-time", { coins = 0 })
local old_event = {
	{
		EventId = "old-created-recently-dispatched",
		DestinationStoreName = "RecordStoreDestination",
		DestinationScope = "global",
		DestinationProfileKey = "recipient-retention",
		MessageType = "retention-test",
		Data = { value = 1 },
	},
}
local old_event_commit, old_event_message = dispatch_time_record:CommitWithOutboxAsync(
	"tx-old-event",
	"retention-event",
	increment("coins", 1),
	old_event
)
assert(old_event_commit == "success", tostring(old_event_message))
fake_now += 120
local time_dispatch_count, time_dispatch_code, time_dispatch_message =
	dispatch_time_record:DispatchOutboxAsync(function(event)
		assert(event.EventId == "old-created-recently-dispatched", "wrong retention event dispatched")
		return true, "retention-destination-receipt"
	end, 1)
assert(time_dispatch_count == 1 and time_dispatch_code == "success", tostring(time_dispatch_message))
local post_dispatch_cutoff_ms = (fake_now - 10) * 1000
local recently_dispatched_pruned, recently_dispatched_code =
	dispatch_time_record:PruneOutboxAsync(post_dispatch_cutoff_ms, 1)
expect_retained(recently_dispatched_pruned, recently_dispatched_code, "post-dispatch retention")
local old_dispatch_cutoff_ms = (fake_now + 10) * 1000
local old_dispatched_pruned, old_dispatched_code =
	dispatch_time_record:PruneOutboxAsync(old_dispatch_cutoff_ms, 1)
expect_pruned(old_dispatched_pruned, old_dispatched_code, "eligible post-dispatch retention")
RecordStore.Mock.set_test_clock(nil)

RecordStore.Mock.reset()

if #retention_failures > 0 then
	error("[RecordStore transaction regression] " .. table.concat(retention_failures, "; "), 0)
end

print("[PASS] RecordStore transaction/inbox/outbox regression.")
