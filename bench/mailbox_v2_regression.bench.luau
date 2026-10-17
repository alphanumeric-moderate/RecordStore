--!nocheck
-- Deterministic regression suite for the opt-in per-message mailbox v2 prototype.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")

local source = fs.readFile("src/PlayerDataInitializer/RecordStoreMailboxV2.luau")
local chunk = luau.load(source, { debugName = "RecordStoreMailboxV2" })
local MailboxV2 = chunk()

local USER_ID = 987654321
local function make_mailbox(overrides)
	local current_time = 1_000_000
	local guid_counter = 0
	local store = MailboxV2.MockStore()
	local options = {
		now_ms = function()
			return current_time
		end,
		guid = function()
			guid_counter += 1
			return ("test-guid-%08d"):format(guid_counter)
		end,
		encode = function(value)
			return serde.encode("json", value)
		end,
	}
	for key, value in overrides or {} do
		options[key] = value
	end
	local mailbox = MailboxV2.new(store, {
		store_name = "MailboxV2_Test",
		scope = "global",
		profile_key = "player-" .. tostring(USER_ID),
		user_id = USER_ID,
	}, options)
	return mailbox, store, function(delta)
		current_time += delta
	end, function()
		return current_time
	end
end

local function expect_code(result, expected, context)
	assert(result ~= nil, context .. ": missing result")
	assert(result.code == expected,
		("%s: expected %s, got %s (%s)"):format(context, expected, tostring(result.code), tostring(result.error)))
end

-- Idempotency must be stable when available_at is omitted; time is not part of the caller request.
do
	local mailbox, store, advance = make_mailbox()
	local first = mailbox:EnqueueAsync("purchase_grant", { coins = 25 }, {
		idempotency_key = "purchase-receipt-1",
	})
	expect_code(first, "accepted", "initial enqueue")
	assert(type(first.message_id) == "string" and #first.message_id <= 50, "route id violates DataStore key limit")
	advance(500)
	local duplicate = mailbox:EnqueueAsync("purchase_grant", { coins = 25 }, {
		idempotency_key = "purchase-receipt-1",
	})
	expect_code(duplicate, "duplicate", "same request retry")
	assert(first.message_id == duplicate.message_id, "idempotent retry changed the canonical message ID")
	local conflict = mailbox:EnqueueAsync("purchase_grant", { coins = 26 }, {
		idempotency_key = "purchase-receipt-1",
	})
	expect_code(conflict, "conflict", "same key different payload")
	local queue, queue_result = mailbox:GetQueueAsync()
	expect_code(queue_result, "success", "queue read")
	assert(#queue == 1, "idempotent enqueue created more than one logical message")
	local delivery, delivery_result = mailbox:GetDeliveryAsync(first.message_id)
	expect_code(delivery_result, "success", "delivery status")
	assert(delivery ~= nil and delivery.State == "ready", "accepted message is not queryable")
	for key in store.values do
		assert(#key <= 50, "DataStore key exceeded 50 characters")
		assert(string.find(key, tostring(USER_ID), 1, true) ~= nil,
			"user-associated route omitted UserId from the key: " .. key)
	end
	local rejected_order = mailbox:EnqueueAsync("ordered", {}, {
		idempotency_key = "ordered-1",
		ordering_key = "per-player",
	})
	expect_code(rejected_order, "invalid", "ordering feature gate")
end

-- Priority is only selection policy; high-priority work should be attempted first.
do
	local mailbox = make_mailbox()
	assert(mailbox:EnqueueAsync("background", { name = "background" }, {
		idempotency_key = "priority-background", priority = "background",
	}).code == "accepted")
	assert(mailbox:EnqueueAsync("urgent", { name = "high" }, {
		idempotency_key = "priority-high", priority = "high",
	}).code == "accepted")
	local seen = {}
	local first = mailbox:ProcessNextAsync(function(payload)
		table.insert(seen, payload.name)
		return true
	end)
	expect_code(first, "processed", "process high priority")
	assert(seen[1] == "high", "background message ran before a high-priority message")
	local second = mailbox:ProcessNextAsync(function(payload)
		table.insert(seen, payload.name)
		return true
	end)
	expect_code(second, "processed", "process background priority")
	assert(seen[2] == "background", "second eligible message was not processed")
end

-- A lost response after claim -> acknowledging must not re-run the handler.
do
	local mailbox, store = make_mailbox()
	local enqueued = mailbox:EnqueueAsync("ack_test", { value = 1 }, {
		idempotency_key = "ack-loss-1",
	})
	expect_code(enqueued, "accepted", "ack fixture enqueue")
	local handler_calls = 0
	local processed = mailbox:ProcessNextAsync(function()
		handler_calls += 1
		store:FailNextUpdate("after")
		return true
	end)
	expect_code(processed, "unknown", "ambiguous acknowledgement")
	assert(handler_calls == 1, "handler fixture was not called exactly once before reconciliation")
	local recovered = mailbox:RecoverAsync()
	expect_code(recovered, "success", "ack recovery")
	assert(handler_calls == 1, "recovery re-ran a handler after acknowledging was committed")
	local delivery, status = mailbox:GetDeliveryAsync(enqueued.message_id)
	expect_code(status, "success", "acknowledged delivery status")
	assert(delivery ~= nil and delivery.State == "acknowledged", "ack recovery did not finish acknowledgement")
end

-- Retry is bounded. The final failed attempt moves to DLQ; replay creates a new placement generation.
do
	local mailbox, _, advance = make_mailbox({ max_attempts = 2, retry_base_ms = 100, retry_max_ms = 1000 })
	local enqueued = mailbox:EnqueueAsync("retry_test", { id = "retry" }, {
		idempotency_key = "retry-1",
	})
	expect_code(enqueued, "accepted", "retry fixture enqueue")
	local first = mailbox:ProcessNextAsync(function()
		return false, "temporary failure"
	end)
	expect_code(first, "retry_scheduled", "first failure retry")
	advance(100_000)
	local second = mailbox:ProcessNextAsync(function()
		return false, "second failure"
	end)
	expect_code(second, "dead_lettered", "attempt cap sends item to DLQ")
	local dead_letters, _, list_result = mailbox:GetDeadLettersAsync(nil, 10)
	expect_code(list_result, "success", "dead letter listing")
	assert(#dead_letters == 1 and dead_letters[1].Id == enqueued.message_id, "DLQ entry missing or duplicated")
	local replay = mailbox:ReplayDeadLetterAsync(enqueued.message_id, "replay-op-1")
	expect_code(replay, "accepted", "dead letter replay")
	local replayed = mailbox:GetQueueAsync()
	assert(#replayed == 1 and replayed[1].ReplayCount == 1, "replay did not produce an eligible new placement")
	local completed = mailbox:ProcessNextAsync(function()
		return true
	end)
	expect_code(completed, "processed", "process replayed item")
	local delivery, delivery_result = mailbox:GetDeliveryAsync(enqueued.message_id)
	expect_code(delivery_result, "success", "post-replay status")
	assert(delivery ~= nil and delivery.State == "acknowledged", "replayed item was not acknowledged")
end

-- Expiry after a claim does not prove a side effect was absent.
do
	local mailbox, _, advance, now = make_mailbox()
	local expiry = now() + 20
	local enqueued = mailbox:EnqueueAsync("expiry_test", { value = 7 }, {
		idempotency_key = "expiry-1",
		expires_at = expiry,
	})
	expect_code(enqueued, "accepted", "expiry fixture enqueue")
	local side_effects = 0
	local result = mailbox:ProcessNextAsync(function()
		side_effects += 1
		advance(50)
		return false, "handler timed out after starting"
	end)
	expect_code(result, "expired", "expiry during a claimed handler")
	assert(side_effects == 1, "expiry fixture did not start handler")
	local delivery, status = mailbox:GetDeliveryAsync(enqueued.message_id)
	expect_code(status, "success", "expired status read")
	assert(delivery ~= nil and delivery.State == "expired", "expired terminal state missing")
	assert(delivery.EffectOutcome == "handler_failed_or_unknown", "expiry falsely claimed no side effect occurred")
end

-- Once a preparation reservation commits, a full active index is a visible preparing/unknown state.
-- Recovery must resume it after an older terminal row releases capacity.
do
	local mailbox, _, _, _ = make_mailbox({
		max_segments = 1,
		segment_max_messages = 1,
		max_attempts = 2,
	})
	local first = mailbox:EnqueueAsync("capacity", { n = 1 }, { idempotency_key = "capacity-first" })
	expect_code(first, "accepted", "capacity first enqueue")
	local pending = mailbox:EnqueueAsync("capacity", { n = 2 }, { idempotency_key = "capacity-second" })
	expect_code(pending, "unknown", "capacity blocked after reservation")
	local preparing, preparing_result = mailbox:GetDeliveryAsync(pending.message_id)
	expect_code(preparing_result, "preparing", "capacity blocked status")
	assert(preparing ~= nil and preparing.CapacityBlocked == true, "durable pending intent was reported absent or not blocked")
	local consumed = mailbox:ProcessNextAsync(function()
		return true
	end)
	expect_code(consumed, "processed", "free active capacity")
	local recovered = mailbox:RecoverAsync()
	expect_code(recovered, "success", "resume capacity-blocked preparation")
	local delivery, delivery_result = mailbox:GetDeliveryAsync(pending.message_id)
	expect_code(delivery_result, "success", "resumed capacity status")
	assert(delivery ~= nil and delivery.State == "ready", "prepared message did not resume after capacity recovery")
end

-- The fake store can replay UpdateAsync transforms and inject a committed write with a lost response.
do
	local mailbox, store = make_mailbox()
	store:ReplayNextUpdate()
	local result = mailbox:EnqueueAsync("replayed_transform", { safe = true }, {
		idempotency_key = "update-replay-1",
	})
	expect_code(result, "accepted", "UpdateAsync callback replay")
	local status, status_result = mailbox:GetDeliveryAsync(result.message_id)
	expect_code(status_result, "success", "post-replay callback status")
	assert(status ~= nil and status.State == "ready", "replayed UpdateAsync created an invalid state")
end

print("[PASS] MailboxV2 idempotency, status lookup, priority, ack recovery, retry/DLQ/replay, expiry uncertainty, capacity recovery, and transform replay.")
