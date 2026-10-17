--!nocheck
-- Deterministic regression suite for the opt-in per-message mailbox v2 prototype.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")

local source = fs.readFile("src/PlayerDataInitializer/RecordStoreMailboxV2.luau")
local chunk = luau.load(source, { debugName = "RecordStoreMailboxV2" })
local MailboxV2 = chunk()

local USER_ID = 987654321
local function active_record_for(owner)
	local ids = if owner.user_id ~= nil then { owner.user_id } else {}
	return {
		GetIdentity = function()
			return {
				store_name = owner.store_name,
				scope = owner.scope,
				profile_key = owner.profile_key,
				user_ids = ids,
			}
		end,
		IsOpen = function() return true end,
		GetState = function() return "active" end,
		Stats = function() return { state = "active", takeover_requested = 0, busy = 0, queue_busy = 0 } end,
	}
end
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
		allow_unattested_activation = true,
	}
	for key, value in overrides or {} do
		options[key] = value
	end
	local owner = {
		store_name = "MailboxV2_Test",
		scope = "global",
		profile_key = "player-" .. tostring(USER_ID),
		user_id = USER_ID,
	}
	options.active_record = active_record_for(owner)
	local mailbox = MailboxV2.new(store, owner, options)
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

-- A failure before the reservation write must not create a ghost message;
-- retrying the same request may then create exactly one accepted message.
do
	local mailbox, store = make_mailbox()
	store:FailNextUpdate("before")
	local interrupted = mailbox:EnqueueAsync("prepare_recovery", { value = 11 }, {
		idempotency_key = "prepare-before-commit",
	})
	expect_code(interrupted, "unknown", "preparation write failed before commit")
	local retry = mailbox:EnqueueAsync("prepare_recovery", { value = 11 }, {
		idempotency_key = "prepare-before-commit",
	})
	expect_code(retry, "accepted", "retry after pre-commit failure")
	assert(retry.message_id == interrupted.message_id, "pre-commit retry changed the message route")
	local duplicate = mailbox:EnqueueAsync("prepare_recovery", { value = 11 }, {
		idempotency_key = "prepare-before-commit",
	})
	expect_code(duplicate, "duplicate", "post-retry preparation deduplication")
	local queue, queue_result = mailbox:GetQueueAsync()
	expect_code(queue_result, "success", "queue after pre-commit recovery")
	assert(#queue == 1, "pre-commit retry created multiple logical messages")
end

-- If the reservation commit succeeds but its response is lost, recovery may
-- confirm it by read-back in the same call. The accepted state must survive a fresh
-- mailbox object, and retrying the same request must not create another message.
do
	local mailbox, store = make_mailbox()
	store:FailNextUpdate("after")
	local interrupted = mailbox:EnqueueAsync("prepare_recovery", { value = 22 }, {
		idempotency_key = "prepare-after-commit",
	})
	expect_code(interrupted, "accepted", "reservation response loss reconciled by read-back")
	assert(type(interrupted.message_id) == "string", "confirmed enqueue omitted its stable route")
	local restart_owner = {
		store_name = "MailboxV2_Test",
		scope = "global",
		profile_key = "player-" .. tostring(USER_ID),
		user_id = USER_ID,
	}
	local fresh_mailbox = MailboxV2.new(store, restart_owner, {
		active_record = active_record_for(restart_owner),
		now_ms = function() return 1_000_000 end,
		guid = function() return "restart-guid" end,
		encode = function(value) return serde.encode("json", value) end,
		allow_unattested_activation = true,
	})
	local delivery, delivery_result = fresh_mailbox:GetDeliveryAsync(interrupted.message_id)
	expect_code(delivery_result, "success", "preparation status after restart")
	assert(delivery ~= nil and delivery.State == "ready",
		"committed preparation was not complete and discoverable after response loss")
	local retried = fresh_mailbox:EnqueueAsync("prepare_recovery", { value = 22 }, {
		idempotency_key = "prepare-after-commit",
	})
	expect_code(retried, "duplicate", "retry after response-loss reconciliation")
	assert(retried.message_id == interrupted.message_id, "restart retry changed the reserved message ID")
	local queue, queue_result = fresh_mailbox:GetQueueAsync()
	expect_code(queue_result, "success", "queue after preparation restart recovery")
	assert(#queue == 1, "restart recovery created multiple logical messages")
end

-- Verify claim lease margin against the response-time clock, then reclaim the
-- expired uncertain claim without claiming the prior handler had no side effects.
do
	local mailbox, store, advance = make_mailbox({
		lease_ms = 1000,
		clock_skew_grace_ms = 1,
		retry_base_ms = 100,
		retry_max_ms = 1000,
	})
	store.advance_time = advance
	local enqueued = mailbox:EnqueueAsync("lease_margin", { value = 5 }, {
		idempotency_key = "lease-margin-delayed-response",
	})
	expect_code(enqueued, "accepted", "lease margin fixture enqueue")
	local handler_calls = 0
	store:DelayUpdateForKey(enqueued.message_id, 900)
	local delayed_claim = mailbox:ProcessNextAsync(function()
		handler_calls += 1
		return true
	end)
	expect_code(delayed_claim, "unknown", "claim response leaves insufficient verified lease")
	assert(handler_calls == 0, "handler ran without a sufficient verified claim lease margin")
	local persisted_claim = store.values[enqueued.message_id]
	assert(type(persisted_claim) == "table" and type(persisted_claim.claim_token) == "string",
		"delayed claim did not preserve its durable fencing token")
	local stale_claim_token = persisted_claim.claim_token

	advance(200)
	local recovered = mailbox:RecoverAsync()
	expect_code(recovered, "success", "recover expired uncertain claim")
	local stale_ack = mailbox:_complete_claim(enqueued.message_id, stale_claim_token)
	expect_code(stale_ack, "conflict", "stale claim token fenced after lease recovery")
	advance(500)
	local retried = mailbox:ProcessNextAsync(function(payload, message)
		handler_calls += 1
		assert(message.Id == enqueued.message_id, "claim retry changed the message identity")
		assert(payload.value == 5, "claim retry changed the payload")
		return true
	end)
	expect_code(retried, "processed", "process reclaimed claim")
	assert(handler_calls == 1, "recovered claim invoked the handler an unexpected number of times")
	local delivery, delivery_result = mailbox:GetDeliveryAsync(enqueued.message_id)
	expect_code(delivery_result, "success", "recovered claim status")
	assert(delivery ~= nil and delivery.State == "acknowledged",
		"recovered claim did not reach an acknowledged terminal state")
end

-- Exhaustively inject one before-commit and one commit-then-response-loss failure at
-- each UpdateAsync boundary observed in a successful enqueue. After simulated process
-- restart, recovery plus an idempotent retry must yield exactly one ready message.
do
	local probe, probe_store = make_mailbox()
	local probe_result = probe:EnqueueAsync("fault_matrix", { probe = true }, {
		idempotency_key = "fault-matrix-probe",
	})
	expect_code(probe_result, "accepted", "fault-matrix successful baseline")
	local write_boundaries = probe_store.update_calls
	assert(write_boundaries >= 4, "fault-matrix baseline did not exercise expected durable write phases")

	for _, mode in { "before", "after" } do
		for target_call = 1, write_boundaries do
			local mailbox, store = make_mailbox()
			local idempotency_key = ("fault-matrix-%s-%02d"):format(mode, target_call)
			local payload = { value = target_call, mode = mode }
			store:FailUpdateAt(target_call, mode)
			local first = mailbox:EnqueueAsync("fault_matrix", payload, {
				idempotency_key = idempotency_key,
			})
			assert(first.code == "accepted" or first.code == "unknown",
				("fault-matrix initial result at call %d/%s was %s: %s"):format(
					target_call, mode, tostring(first.code), tostring(first.error)
				))
			assert(type(first.message_id) == "string", "fault-matrix failure omitted stable message identity")

			local restart_owner = {
				store_name = "MailboxV2_Test",
				scope = "global",
				profile_key = "player-" .. tostring(USER_ID),
				user_id = USER_ID,
			}
			local restarted = MailboxV2.new(store, restart_owner, {
				active_record = active_record_for(restart_owner),
				now_ms = function() return 1_000_000 end,
				guid = function() return "fault-matrix-restart" end,
				encode = function(value) return serde.encode("json", value) end,
			allow_unattested_activation = true,
			})
			local recovery = restarted:RecoverAsync()
			if recovery.code == "unknown" then
				-- A committed recovery step may itself have an ambiguous response;
				-- a second pass must settle the durable state after the one-shot fault.
				recovery = restarted:RecoverAsync()
			end
			expect_code(recovery, "success", ("fault-matrix recovery call %d/%s"):format(target_call, mode))
			local retried = restarted:EnqueueAsync("fault_matrix", payload, {
				idempotency_key = idempotency_key,
			})
			assert(retried.code == "accepted" or retried.code == "duplicate",
				("fault-matrix retry at call %d/%s was %s: %s"):format(
					target_call, mode, tostring(retried.code), tostring(retried.error)
				))
			assert(retried.message_id == first.message_id, "fault-matrix retry changed canonical message ID")
			local queue, queue_result = restarted:GetQueueAsync()
			expect_code(queue_result, "success", ("fault-matrix queue call %d/%s"):format(target_call, mode))
			assert(#queue == 1, ("fault-matrix created %d logical messages at call %d/%s"):format(
				#queue, target_call, mode
			))
			assert(queue[1].Id == first.message_id, "fault-matrix queue contains a different message")
		end
	end
end

print("[PASS] MailboxV2 idempotency, status lookup, priority, ack recovery, retry/DLQ/replay, expiry uncertainty, capacity recovery, transform replay, and preparation failure recovery.")
