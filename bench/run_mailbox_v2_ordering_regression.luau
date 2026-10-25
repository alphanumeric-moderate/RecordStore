--!nocheck
local Shim = require("./RobloxShim")
local serde = require("@lune/serde")
local RecordStore = Shim.load()
local MailboxV2 = RecordStore.MailboxV2

local now_ms = 1_800_000_000_000
local guid_counter = 0
local owner = {
	store_name = "MailboxV2OrderingRegression",
	scope = "global",
	profile_key = "profile-1",
	user_id = 123,
}
local active_state = { takeover_requested = false }
local active_record = {
	IsOpen = function() return true end,
	GetState = function() return "active" end,
	GetIdentity = function()
		return {
			store_name = owner.store_name,
			scope = owner.scope,
			profile_key = owner.profile_key,
			user_ids = { 123 },
		}
	end,
	Stats = function() return active_state end,
}

local function clone(value)
	return serde.decode("json", serde.encode("json", value))
end

local function next_guid()
	guid_counter += 1
	return ("mailbox-regression-%d"):format(guid_counter)
end

local function new_mailbox(options, store)
	options = table.clone(options or {})
	store = store or MailboxV2.MockStore()
	options.active_record = active_record
	options.allow_unattested_activation = true
	options.encode = function(value) return serde.encode("json", value) end
	if options.guid == nil then options.guid = next_guid end
	if options.now_ms == nil then options.now_ms = function() return now_ms end end
	options.lease_ms = options.lease_ms or 10000
	options.lease_renewal_horizon_ms = options.lease_renewal_horizon_ms or 40000
	options.max_segments = options.max_segments or 8
	options.segment_max_messages = options.segment_max_messages or 8
	options.dlq_max_segments = options.dlq_max_segments or 8
	options.dlq_segment_max_messages = options.dlq_segment_max_messages or 8
	options.preparation_shard_count = options.preparation_shard_count or 2
	options.preparation_max_entries_per_shard = options.preparation_max_entries_per_shard or 16
	return MailboxV2.new(store, owner, options), store
end

local function enqueue(mailbox, message_type, idempotency_key, ordering_key, priority, available_at)
	local result = mailbox:EnqueueAsync(message_type, { id = idempotency_key }, {
		idempotency_key = idempotency_key,
		ordering_key = ordering_key,
		priority = priority or "normal",
		available_at = available_at or now_ms,
	})
	assert(result.code == "accepted", ("enqueue %s failed: %s %s"):format(
		idempotency_key, tostring(result.code), tostring(result.error)
	))
	assert(type(result.message_id) == "string", "accepted enqueue did not return a canonical message ID")
	return result
end

local function process_one(mailbox, handler)
	return mailbox:ProcessNextAsync(function(payload, message, context)
		return handler(payload, message, context)
	end)
end

local function test_platform_guid_fallback_when_no_callback_is_supplied()
	local store = MailboxV2.MockStore()
	local mailbox = MailboxV2.new(store, owner, {
		allow_unattested_activation = true,
		encode = function(value) return serde.encode("json", value) end,
		now_ms = function() return now_ms end,
	})
	local result = mailbox:EnqueueAsync("platform-guid", { value = 1 }, {
		priority = "normal",
	})
	assert(result.code == "accepted",
		"platform HttpService GUID fallback failed: " .. tostring(result.error))
	assert(type(result.message_id) == "string" and result.message_id ~= "",
		"platform GUID fallback did not produce a message identifier")
end

local function test_injected_clock_and_guid_contracts_fail_closed()
	local now_ok = pcall(function()
		new_mailbox({ now_ms = false })
	end)
	assert(not now_ok, "non-function now_ms option was accepted")
	local guid_ok = pcall(function()
		new_mailbox({ guid = false })
	end)
	assert(not guid_ok, "non-function guid option was accepted")

	local mailbox, store = new_mailbox({
		guid = function() return false end,
	})
	local reads_before, writes_before = store.get_calls, store.update_calls
	local invalid_clock, clock_store = new_mailbox({
		now_ms = function() return math.huge end,
		guid = function() return "valid-clock-test" end,
	})
	local clock_ok = pcall(function() return invalid_clock:_now() end)
	assert(not clock_ok, "non-finite now_ms return value was accepted")
	local no_idempotency = mailbox:EnqueueAsync("invalid-guid", { amount = 1 }, {
		priority = "normal",
	})
	assert(no_idempotency.code == "invalid",
		"malformed GUID result was accepted for a generated idempotency route")
	assert(store.get_calls == reads_before and store.update_calls == writes_before,
		"invalid generated idempotency route performed store operations")

	local good_mailbox, good_store = new_mailbox({
		guid = function() return "valid-token" end,
		strict_ordering_enabled = true,
	})
	local queued = enqueue(good_mailbox, "invalid-claim-guid", "invalid-claim-guid-id", "guid-test-account", "high")
	good_mailbox.options.guid = function() return string.rep("g", 257) end
	local claim, claim_result = good_mailbox:_claim(queued.message_id)
	assert(claim == nil and claim_result.code == "invalid",
		"oversized generated claim token was accepted")
	assert(good_store.values[queued.message_id].state == "ready",
		"invalid generated claim token mutated the durable message")

	local writes_before_renewal = good_store.update_calls
	local renewal = good_mailbox:RenewClaimAsync(queued.message_id, "not-a-claim-token")
	assert(renewal.code == "invalid", "malformed generated renewal identifier was accepted")
	assert(good_store.update_calls == writes_before_renewal,
		"invalid renewal identifier performed a DataStore write")
end

local function test_clock_is_never_called_inside_update_async_transform()
	local backing = MailboxV2.MockStore()
	local inside_transform = false
	local store = {
		GetAsync = function(_, key) return backing:GetAsync(key) end,
		GetAsyncFresh = function(_, key) return backing:GetAsyncFresh(key) end,
		UpdateAsync = function(_, key, transform)
			return backing:UpdateAsync(key, function(raw, key_info)
				inside_transform = true
				local call_ok, value, user_ids, metadata = pcall(transform, raw, key_info)
				inside_transform = false
				if not call_ok then error(value) end
				return value, user_ids, metadata
			end)
		end,
	}
	local mailbox = new_mailbox({
		strict_ordering_enabled = true,
		max_attempts = 1,
		now_ms = function()
			assert(not inside_transform, "clock callback ran inside a DataStore UpdateAsync transform")
			return now_ms
		end,
	}, store)
	local queued = enqueue(mailbox, "clock-safe", "clock-safe-id", "clock-safe-account", "high")
	local dead_letter = process_one(mailbox, function() return false end)
	assert(dead_letter.code == "dead_lettered", "clock-safe fixture did not reach dead letter")
	local replay = mailbox:ReplayDeadLetterAsync(queued.message_id, "clock-safe-replay")
	assert(replay.code == "accepted", "clock-safe replay failed: " .. tostring(replay.error))
end

local function test_ordering_is_opt_in_and_input_validation_is_side_effect_free()
	local mailbox, store = new_mailbox({ strict_ordering_enabled = false })
	local reads_before = store.get_calls
	local writes_before = store.update_calls
	local rejected = mailbox:EnqueueAsync("purchase", { amount = 1 }, {
		idempotency_key = "ordering-disabled",
		ordering_key = "account-1",
		priority = "normal",
	})
	assert(rejected.code == "invalid", "ordering_key was accepted without strict_ordering_enabled")
	assert(store.get_calls == reads_before and store.update_calls == writes_before,
		"disabled ordering validation performed a DataStore operation")

	local invalid_priority = mailbox:EnqueueAsync("purchase", { amount = 1 }, {
		idempotency_key = "invalid-priority",
		priority = "critical",
	})
	assert(invalid_priority.code == "invalid", "caller-selected internal priority tier was accepted")
	assert(store.get_calls == reads_before and store.update_calls == writes_before,
		"invalid priority validation performed a DataStore operation")

	local invalid_false_priority = mailbox:EnqueueAsync("purchase", { amount = 1 }, {
		idempotency_key = "invalid-false-priority",
		priority = false,
	})
	assert(invalid_false_priority.code == "invalid", "false priority silently fell back to normal")
	assert(store.get_calls == reads_before and store.update_calls == writes_before,
		"false priority validation performed a DataStore operation")

	local invalid_available_time = mailbox:EnqueueAsync("purchase", { amount = 1 }, {
		idempotency_key = "invalid-available-time",
		available_at = false,
	})
	assert(invalid_available_time.code == "invalid", "false available_at silently fell back to the current time")
	assert(store.get_calls == reads_before and store.update_calls == writes_before,
		"invalid available_at validation performed a DataStore operation")

	local invalid_burst_ok = pcall(function()
		new_mailbox({ high_priority_burst = false })
	end)
	assert(not invalid_burst_ok, "false high_priority_burst silently fell back to the default")

	local wrong_type = mailbox:EnqueueAsync("purchase", { amount = 1 }, {
		idempotency_key = "invalid-order-type",
		ordering_key = 42,
	})
	assert(wrong_type.code == "invalid", "non-string ordering_key was accepted")
	assert(store.get_calls == reads_before and store.update_calls == writes_before,
		"invalid ordering_key validation performed a DataStore operation")

	local store_without_fresh = {
		GetAsync = function() return nil end,
		UpdateAsync = function(_, _, transform) return transform(nil) end,
	}
	local ok = pcall(function()
		new_mailbox({ strict_ordering_enabled = true }, store_without_fresh)
	end)
	assert(not ok, "strict ordering accepted an adapter without uncached authoritative reads")
end

local function test_producer_idempotency_conflict_and_preparation_response_loss()
	local backing = MailboxV2.MockStore()
	local route = nil
	local lost_route_write = false
	local store = {
		GetAsync = function(_, key) return backing:GetAsync(key) end,
		GetAsyncFresh = function(_, key) return backing:GetAsyncFresh(key) end,
		UpdateAsync = function(_, key, transform)
			if key == route and not lost_route_write then
				lost_route_write = true
				backing:FailNextUpdate("after")
			end
			return backing:UpdateAsync(key, transform)
		end,
		RemoveAsync = function(_, key) return backing:RemoveAsync(key) end,
	}
	local mailbox = new_mailbox({ strict_ordering_enabled = true }, store)
	local route_error
	route, route_error = mailbox:_route_key("producer-crash-window")
	assert(route ~= nil, tostring(route_error))

	local options = {
		idempotency_key = "producer-crash-window",
		ordering_key = "producer-crash-account",
		priority = "normal",
		available_at = now_ms,
	}
	local first = mailbox:EnqueueAsync("purchase", { sku = "item-A" }, options)
	assert(lost_route_write, "test did not inject response loss on the canonical preparation write")
	assert(first.code == "unknown",
		"ambiguous canonical preparation write was not exposed as unknown: " .. tostring(first.code))

	local recovery = mailbox:RecoverAsync()
	assert(recovery.code == "success",
		"bounded preparation recovery failed after canonical response loss: " .. tostring(recovery.error))
	local delivery, delivery_result = mailbox:GetDeliveryAsync(route)
	assert(delivery_result.code == "success" and delivery ~= nil,
		"recovered producer receipt could not be read: " .. tostring(delivery_result.error))
	assert(delivery.State == "ready", "recovered producer receipt did not reach ready")

	local duplicate = mailbox:EnqueueAsync("purchase", { sku = "item-A" }, options)
	assert(duplicate.code == "duplicate", "same producer request was not idempotent: " .. tostring(duplicate.code))
	assert(duplicate.message_id == route, "duplicate producer request returned a different message ID")

	local conflict = mailbox:EnqueueAsync("purchase", { sku = "item-B" }, options)
	assert(conflict.code == "conflict", "reused producer key with a changed payload was not rejected")
	local queue, queue_result = mailbox:GetQueueAsync()
	assert(queue_result.code == "success", "queue could not be read after producer recovery")
	local route_count = 0
	for _, message in ipairs(queue) do
		if message.Id == route then route_count += 1 end
	end
	assert(route_count == 1, "response-loss recovery or duplicate enqueue created multiple active placements")
end

local function test_priority_never_overtakes_an_earlier_ordered_message()
	local mailbox = new_mailbox({ strict_ordering_enabled = true })
	local earlier = enqueue(mailbox, "earlier", "priority-earlier", "account-alpha", "background")
	local later = enqueue(mailbox, "later", "priority-later", "account-alpha", "high")
	enqueue(mailbox, "unrelated", "priority-unrelated", nil, "high")

	local executed = {}
	for _ = 1, 3 do
		local result = process_one(mailbox, function(_, message)
			executed[#executed + 1] = message.Type
			return true
		end)
		assert(result.code == "processed", "eligible ordered work did not process: " .. tostring(result.code))
	end
	local positions = {}
	for index, message_type in ipairs(executed) do positions[message_type] = index end
	assert(positions.earlier ~= nil and positions.later ~= nil and positions.earlier < positions.later,
		"high-priority work overtook an earlier message sharing its ordering_key")
	assert(earlier.message_id ~= later.message_id, "different idempotency keys shared a canonical message ID")
end

local function test_delayed_predecessor_blocks_later_high_priority_work()
	local mailbox = new_mailbox({ strict_ordering_enabled = true })
	local later_at = now_ms + 500
	enqueue(mailbox, "delayed", "delayed-predecessor", "account-delayed", "background", later_at)
	enqueue(mailbox, "urgent", "delayed-successor", "account-delayed", "high", now_ms)
	local invoked = 0
	local result = process_one(mailbox, function()
		invoked += 1
		return true
	end)
	assert(result.code == "empty" and invoked == 0,
		"later high-priority message bypassed an earlier unavailable message on the same key")

	now_ms = later_at
	local first = process_one(mailbox, function(_, message)
		assert(message.Type == "delayed", "delayed predecessor was not processed first")
		invoked += 1
		return true
	end)
	assert(first.code == "processed", "delayed predecessor failed after becoming eligible")
	local second = process_one(mailbox, function(_, message)
		assert(message.Type == "urgent", "ordered successor did not follow its predecessor")
		invoked += 1
		return true
	end)
	assert(second.code == "processed" and invoked == 2, "ordered successor did not complete")
end

local function test_dead_letter_replay_gets_a_new_ordering_sequence_and_recovers_from_stale_reads()
	local backing = MailboxV2.MockStore()
	local stale_reads = {}
	local store = {
		GetAsync = function(_, key)
			if stale_reads[key] ~= nil then return clone(stale_reads[key]) end
			return backing:GetAsync(key)
		end,
		GetAsyncFresh = function(_, key) return backing:GetAsyncFresh(key) end,
		UpdateAsync = function(_, key, transform) return backing:UpdateAsync(key, transform) end,
	}
	local mailbox = new_mailbox({ strict_ordering_enabled = true, max_attempts = 1 }, store)
	local replay_source = enqueue(mailbox, "replay-source", "replay-source-id", "replay-account", "high")
	enqueue(mailbox, "middle", "replay-middle-id", "replay-account", "normal")
	enqueue(mailbox, "tail", "replay-tail-id", "replay-account", "normal")

	local initial = process_one(mailbox, function(_, message)
		assert(message.Id == replay_source.message_id, "high-priority source was not attempted first")
		return false
	end)
	assert(initial.code == "dead_lettered", "failed source did not enter the dead-letter state")

	local ordering_route = mailbox:_ordering_route("replay-account")
	local stale_ordering_state = clone(backing:GetAsyncFresh(ordering_route))
	local replay = mailbox:ReplayDeadLetterAsync(replay_source.message_id, "replay-operation-one")
	assert(replay.code == "accepted", "dead-letter replay was not accepted: " .. tostring(replay.code))
	stale_reads[ordering_route] = stale_ordering_state

	local replay_order = {}
	for _ = 1, 3 do
		local result = process_one(mailbox, function(_, message)
			replay_order[#replay_order + 1] = message.Type
			return true
		end)
		assert(result.code == "processed", "replayed ordered work did not process: " .. tostring(result.code))
	end
	assert(replay_order[1] == "middle" and replay_order[2] == "tail" and replay_order[3] == "replay-source",
		"replayed message bypassed older queued messages or a stale ordering index was trusted")
	local final_record = backing:GetAsyncFresh(replay_source.message_id)
	assert(final_record.state == "acknowledged", "replayed source did not reach its durable terminal state")
	assert(final_record.ordering_sequence > stale_ordering_state.next_sequence - 1,
		"replayed source did not receive a fresh per-key sequence")
end

local function test_order_slot_mismatch_fails_closed()
	local mailbox, store = new_mailbox({ strict_ordering_enabled = true })
	local queued = enqueue(mailbox, "tampered", "tampered-id", "tamper-account", "high")
	local canonical = store.values[queued.message_id]
	assert(type(canonical) == "table", "test could not find the canonical message row")
	canonical.ordering_sequence += 100
	local invoked = false
	local result = process_one(mailbox, function()
		invoked = true
		return true
	end)
	assert(result.code == "empty" and not invoked, "message with a forged ordering_sequence was dispatched")
	assert(canonical.state == "ready", "ordering mismatch changed canonical message state")
end

local function test_corrupt_existing_ordering_slot_fails_closed()
	local mailbox, store = new_mailbox({ strict_ordering_enabled = true })
	local ordering_key = "corrupt-existing-slot-account"
	local route = "mailbox-route-existing-slot"
	local initial_sequence, initial_error = mailbox:_ensure_ordering_slot(route, ordering_key)
	assert(initial_sequence == 1 and initial_error == nil, "could not create an ordering-slot fixture")
	local ordering_route = mailbox:_ordering_route(ordering_key)
	assert(type(store.values[ordering_route]) == "table", "ordering-slot fixture was not persisted")

	store.values[ordering_route].next_sequence = initial_sequence
	local reused_sequence, reuse_error = mailbox:_ensure_ordering_slot(route, ordering_key)
	assert(reused_sequence == nil and reuse_error ~= nil,
		"existing sequence was reused when next_sequence did not exceed it")

	store.values[ordering_route].next_sequence = initial_sequence + 1
	local replay_sequence, replay_error = mailbox:_reserve_replay_ordering_slot(
		route, ordering_key, "corrupt-existing-replay-operation"
	)
	assert(replay_sequence == initial_sequence + 1 and replay_error == nil,
		"could not create an idempotent replay reservation fixture")
	store.values[ordering_route].next_sequence = replay_sequence
	local reused_replay, reused_replay_error = mailbox:_reserve_replay_ordering_slot(
		route, ordering_key, "corrupt-existing-replay-operation"
	)
	assert(reused_replay == nil and reused_replay_error ~= nil,
		"existing replay slot was reused when next_sequence did not exceed it")

	store.values[ordering_route].next_sequence = 0 / 0
	local nonfinite_sequence, nonfinite_error = mailbox:_ensure_ordering_slot(route, ordering_key)
	assert(nonfinite_sequence == nil and nonfinite_error ~= nil,
		"existing sequence was reused with a non-finite next_sequence")
	local nonfinite_replay, nonfinite_replay_error = mailbox:_reserve_replay_ordering_slot(
		route, ordering_key, "corrupt-existing-replay-operation"
	)
	assert(nonfinite_replay == nil and nonfinite_replay_error ~= nil,
		"existing replay slot was reused with a non-finite next_sequence")
end

local function test_corrupt_ordering_index_fails_closed()
	local mailbox, store = new_mailbox({ strict_ordering_enabled = true })
	local queued = enqueue(mailbox, "corrupt-index", "corrupt-index-id", "corrupt-index-account", "high")
	local ordering_route = mailbox:_ordering_route("corrupt-index-account")
	local ordering = store.values[ordering_route]
	assert(type(ordering) == "table" and type(ordering.routes) == "table",
		"corrupt-index fixture could not locate the ordering row")
	ordering.routes["forged-duplicate-sequence"] = ordering.routes[queued.message_id]
	local invoked = false
	local result = process_one(mailbox, function()
		invoked = true
		return true
	end)
	assert(result.code == "empty" and not invoked,
		"duplicate durable sequence in the ordering index did not fail closed")
	assert(store.values[queued.message_id].state == "ready",
		"corrupt order index mutated the canonical message before verification")

	local second_mailbox, second_store = new_mailbox({ strict_ordering_enabled = true })
	local second = enqueue(second_mailbox, "corrupt-counter", "corrupt-counter-id", "corrupt-counter-account", "high")
	local second_order_route = second_mailbox:_ordering_route("corrupt-counter-account")
	second_store.values[second_order_route].next_sequence = 0 / 0
	local second_invoked = false
	local second_result = process_one(second_mailbox, function()
		second_invoked = true
		return true
	end)
	assert(second_result.code == "empty" and not second_invoked,
		"non-finite ordering counter did not fail closed")
	assert(second_store.values[second.message_id].state == "ready",
		"corrupt ordering counter mutated the canonical message")
end

local function test_stale_cache_cannot_bypass_claim_metadata_validation()
	local backing = MailboxV2.MockStore()
	local target_route = nil
	local cached_record = nil
	local serve_stale = false
	local store = {
		GetAsync = function(_, key)
			if serve_stale and key == target_route then return clone(cached_record) end
			return backing:GetAsync(key)
		end,
		GetAsyncFresh = function(_, key) return backing:GetAsyncFresh(key) end,
		UpdateAsync = function(_, key, transform) return backing:UpdateAsync(key, transform) end,
	}
	local mailbox = new_mailbox({ strict_ordering_enabled = true }, store)
	local queued = enqueue(mailbox, "cached-snapshot", "cached-snapshot-id", nil, "normal")
	target_route = queued.message_id
	cached_record = clone(backing.values[target_route])
	serve_stale = true
	backing.values[target_route].priority = "critical"

	local claimed, result = mailbox:_claim(target_route)
	assert(claimed == nil and result.code == "corrupt",
		"stale GetAsync snapshot let malformed canonical priority through claim validation")
	assert(backing.values[target_route].state == "ready",
		"invalid canonical metadata was mutated by a claim despite the stale cache")

	local second_backing = MailboxV2.MockStore()
	local second_target = nil
	local mutate_key_on_claim = false
	local mutated = false
	local second_store = {
		GetAsync = function(_, key) return second_backing:GetAsync(key) end,
		GetAsyncFresh = function(_, key) return second_backing:GetAsyncFresh(key) end,
		UpdateAsync = function(_, key, transform)
			if mutate_key_on_claim and not mutated and key == second_target then
				mutated = true
				local current = second_backing.values[key]
				assert(type(current) == "table", "unkeyed race fixture lost its canonical row")
				current.ordering_key = "raced-in-key"
				current.ordering_sequence = 1
			end
			return second_backing:UpdateAsync(key, transform)
		end,
	}
	local second_mailbox = new_mailbox({ strict_ordering_enabled = true }, second_store)
	local second = enqueue(second_mailbox, "unkeyed-race", "unkeyed-race-id", nil, "high")
	second_target = second.message_id
	mutate_key_on_claim = true
	local claimed_after_race, second_result = second_mailbox:_claim(second_target)
	assert(mutated and claimed_after_race == nil and second_result.code == "busy",
		"claim committed after canonical ordering metadata changed from nil to a key")
	assert(second_backing.values[second_target].state == "ready",
		"ordering metadata race mutated the canonical message")
end

local function test_corrupt_ready_message_metadata_fails_closed()
	local mailbox, store = new_mailbox({ strict_ordering_enabled = true })
	local malformed_priority = enqueue(mailbox, "malformed-priority", "malformed-priority-id", nil, "normal")
	store.values[malformed_priority.message_id].priority = "critical"
	local priority_handler_invoked = false
	local priority_result = process_one(mailbox, function()
		priority_handler_invoked = true
		return true
	end)
	assert(priority_result.code == "corrupt" and not priority_handler_invoked,
		"corrupt priority metadata reached a message handler")

	local second_mailbox, second_store = new_mailbox({ strict_ordering_enabled = true })
	local malformed_time = enqueue(second_mailbox, "malformed-time", "malformed-time-id", nil, "normal")
	second_store.values[malformed_time.message_id].created_at = 0 / 0
	local time_handler_invoked = false
	local time_result = process_one(second_mailbox, function()
		time_handler_invoked = true
		return true
	end)
	assert(time_result.code == "corrupt" and not time_handler_invoked,
		"non-finite creation time reached the priority comparator or handler")

	local third_mailbox, third_store = new_mailbox({ strict_ordering_enabled = true })
	local malformed_counter = enqueue(third_mailbox, "malformed-counter", "malformed-counter-id", nil, "normal")
	third_store.values[malformed_counter.message_id].attempts = -1
	local counter_handler_invoked = false
	local counter_result = process_one(third_mailbox, function()
		counter_handler_invoked = true
		return true
	end)
	assert(counter_result.code == "corrupt" and not counter_handler_invoked,
		"negative retry accounting reached a message handler")
end

local function test_future_message_version_fails_closed()
	local mailbox, store = new_mailbox({ strict_ordering_enabled = true })
	local queued = enqueue(mailbox, "future-schema", "future-schema-id", nil, "normal")
	store.values[queued.message_id].version = 3

	local delivery, delivery_result = mailbox:GetDeliveryAsync(queued.message_id)
	assert(delivery == nil and delivery_result.code == "unsupported_schema",
		"public delivery read treated a future message version as a v2 envelope")

	local queue, queue_result = mailbox:GetQueueAsync()
	assert(#queue == 0 and queue_result.code == "unsupported_schema",
		"public queue read exposed a future-version message as a v2 entry")

	local claimed, claim_result = mailbox:_claim(queued.message_id)
	assert(claimed == nil and claim_result.code == "unsupported_schema",
		"claim attempted to process a message from an unsupported schema version")
	assert(store.values[queued.message_id].version == 3 and store.values[queued.message_id].state == "ready",
		"unsupported message schema was rewritten during fail-closed validation")

	local ack_mailbox, ack_store = new_mailbox()
	local acknowledging = enqueue(ack_mailbox, "future-ack-schema", "future-ack-schema-id", nil, "normal")
	ack_store.values[acknowledging.message_id].version = 3
	ack_store.values[acknowledging.message_id].state = "acknowledging"
	ack_store.values[acknowledging.message_id].claim_token = "future-claim-token"
	local ack_result = ack_mailbox:_finish_acknowledgement(acknowledging.message_id, "future-claim-token")
	assert(ack_result.code == "unsupported_schema"
		and ack_store.values[acknowledging.message_id].state == "acknowledging",
		"acknowledgement recovery mutated a future-version canonical message")

	local dlq_mailbox, dlq_store = new_mailbox()
	local dead_lettering = enqueue(dlq_mailbox, "future-dlq-schema", "future-dlq-schema-id", nil, "normal")
	dlq_store.values[dead_lettering.message_id].version = 3
	dlq_store.values[dead_lettering.message_id].state = "dead_lettering"
	local dlq_result = dlq_mailbox:_finish_dead_letter(dead_lettering.message_id)
	assert(dlq_result.code == "unsupported_schema"
		and dlq_store.values[dead_lettering.message_id].state == "dead_lettering",
		"dead-letter recovery mutated a future-version canonical message")
end

local function test_future_message_version_cannot_confirm_duplicate_producer_receipt()
	local mailbox, store = new_mailbox()
	local producer_key = "future-producer-v3-id"
	local queued = enqueue(mailbox, "future-producer", producer_key, nil, "normal")
	local canonical = store.values[queued.message_id]
	assert(type(canonical) == "table", "producer fixture omitted its canonical record")
	canonical.version = 3
	store.values[queued.message_id] = canonical
	local writes_before_retry = store.update_calls

	local retry = mailbox:EnqueueAsync("future-producer", { id = producer_key }, {
		idempotency_key = producer_key,
		priority = "normal",
		available_at = now_ms,
	})
	assert(retry.code == "unsupported_schema",
		"V2 producer retry acknowledged a future-version canonical record as a duplicate")
	assert(store.update_calls == writes_before_retry,
		"future-version producer receipt triggered a canonical or index write")
	assert(store.values[queued.message_id].version == 3
		and store.values[queued.message_id].state == "ready",
		"future-version producer record was modified by V2 compatibility handling")
end

local function test_high_priority_burst_does_not_starve_background_messages()
	local mailbox = new_mailbox({ strict_ordering_enabled = true })
	for index = 1, 7 do
		enqueue(mailbox, "high-" .. index, "burst-high-" .. index, nil, "high")
	end
	enqueue(mailbox, "background", "burst-background", nil, "background")
	local executed = {}
	for _ = 1, 5 do
		local result = process_one(mailbox, function(_, message)
			executed[#executed + 1] = message.Type
			return true
		end)
		assert(result.code == "processed", "priority fairness fixture did not process: " .. tostring(result.code))
	end
	local background_position = nil
	for index, message_type in ipairs(executed) do
		if message_type == "background" then background_position = index; break end
	end
	assert(background_position ~= nil and background_position <= 5,
		"sustained high-priority work starved a background message beyond the configured burst")
end

local function test_retrying_predecessor_blocks_same_key_successor()
	local mailbox = new_mailbox({
		strict_ordering_enabled = true,
		retry_base_ms = 1000,
		retry_max_ms = 1000,
	})
	enqueue(mailbox, "retrying-predecessor", "retrying-predecessor-id", "retry-account", "background")
	enqueue(mailbox, "high-successor", "retrying-successor-id", "retry-account", "high")
	local attempts = 0
	local first = process_one(mailbox, function(_, message)
		assert(message.Type == "retrying-predecessor", "high-priority successor bypassed the retrying predecessor")
		attempts += 1
		return false
	end)
	assert(first.code == "retry_scheduled", "failed ordered predecessor did not schedule a retry")

	local invoked_successor = false
	local blocked = process_one(mailbox, function(_, message)
		if message.Type == "high-successor" then invoked_successor = true end
		return true
	end)
	assert(blocked.code == "empty" and not invoked_successor,
		"same-key successor ran while its predecessor was waiting for retry")

	now_ms += 60000
	local retried = process_one(mailbox, function(_, message)
		assert(message.Type == "retrying-predecessor", "retry did not reclaim the ordered predecessor")
		attempts += 1
		return true
	end)
	assert(retried.code == "processed" and attempts == 2,
		"ordered predecessor did not reach a terminal state after retry")
	local successor = process_one(mailbox, function(_, message)
		assert(message.Type == "high-successor", "successor was not dispatched after predecessor became terminal")
		invoked_successor = true
		return true
	end)
	assert(successor.code == "processed" and invoked_successor,
		"same-key successor remained blocked after the predecessor completed")
end

local function test_claim_update_fails_closed_if_order_sequence_changes_after_arbitration()
	local backing = MailboxV2.MockStore()
	local claim_route = nil
	local intercept_claim = false
	local intercept_done = false
	local store = {
		GetAsync = function(_, key) return backing:GetAsync(key) end,
		GetAsyncFresh = function(_, key) return backing:GetAsyncFresh(key) end,
		UpdateAsync = function(_, key, transform)
			if intercept_claim and not intercept_done and key == claim_route then
				intercept_done = true
				local current = backing.values[key]
				assert(type(current) == "table", "claim-race fixture lost the canonical message")
				current.ordering_sequence += 100
			end
			return backing:UpdateAsync(key, transform)
		end,
	}
	local mailbox = new_mailbox({ strict_ordering_enabled = true }, store)
	local queued = enqueue(mailbox, "raced-claim", "raced-claim-id", "race-account", "high")
	claim_route = queued.message_id
	intercept_claim = true
	local handler_invoked = false
	local result = process_one(mailbox, function()
		handler_invoked = true
		return true
	end)
	local canonical = backing:GetAsyncFresh(queued.message_id)
	assert(intercept_done, "race injector did not run between ordering arbitration and claim commit")
	assert(result.code == "empty" and not handler_invoked,
		"claim ran after its durable ordering sequence changed concurrently")
	assert(canonical.state == "ready" and canonical.ordering_sequence ~= nil,
		"raced claim did not leave the canonical message recoverable")
end

local function test_clock_skew_cannot_break_ordering_under_adversarial_sort_keys()
	local mailbox, store = new_mailbox({ strict_ordering_enabled = true })
	local first = enqueue(mailbox, "first", "skew-first", "skew-account", "normal")
	local second = enqueue(mailbox, "second", "skew-second", "skew-account", "normal")
	local unrelated = enqueue(mailbox, "unrelated", "skew-unrelated", nil, "normal")
	local first_record = store.values[first.message_id]
	local second_record = store.values[second.message_id]
	local unrelated_record = store.values[unrelated.message_id]
	assert(first_record and second_record and unrelated_record, "clock-skew fixture could not locate canonical rows")
	first_record.created_at = now_ms - 1000
	second_record.created_at = now_ms - 3000
	unrelated_record.created_at = now_ms - 2000

	local executed = {}
	for _ = 1, 3 do
		local result = process_one(mailbox, function(_, message)
			executed[#executed + 1] = message.Type
			return true
		end)
		assert(result.code == "processed", "clock-skew fixture did not process all rows")
	end
	local positions = {}
	for index, message_type in ipairs(executed) do positions[message_type] = index end
	assert(positions.first < positions.second,
		"clock skew caused a later message to overtake its earlier ordering_key predecessor")
end

local function test_priority_burst_policy_is_bounded_and_configurable()
	local invalid_policy_ok = pcall(function()
		new_mailbox({ high_priority_burst = 33 })
	end)
	assert(not invalid_policy_ok, "high_priority_burst above its hard bound was accepted")

	local mailbox = new_mailbox({ high_priority_burst = 2 })
	for index = 1, 5 do
		enqueue(mailbox, "custom-high-" .. index, "custom-high-" .. index, nil, "high")
	end
	enqueue(mailbox, "custom-background", "custom-background", nil, "background")
	local executed = {}
	for _ = 1, 3 do
		local result = process_one(mailbox, function(_, message)
			executed[#executed + 1] = message.Type
			return true
		end)
		assert(result.code == "processed", "custom priority burst fixture failed to process")
	end
	assert(executed[3] == "custom-background",
		"configurable burst failed to serve background work after two high-priority claims")
end

local function test_acknowledgement_response_loss_recovers_without_redelivery()
	local backing = MailboxV2.MockStore()
	local route = nil
	local fail_next_route_update = false
	local store = {
		GetAsync = function(_, key) return backing:GetAsync(key) end,
		GetAsyncFresh = function(_, key) return backing:GetAsyncFresh(key) end,
		UpdateAsync = function(_, key, transform)
			if fail_next_route_update and key == route then
				fail_next_route_update = false
				backing:FailNextUpdate("after")
			end
			return backing:UpdateAsync(key, transform)
		end,
		RemoveAsync = function(_, key) return backing:RemoveAsync(key) end,
	}
	local mailbox = new_mailbox({ strict_ordering_enabled = true }, store)
	local queued = enqueue(mailbox, "ack-response-loss", "ack-response-loss-id", "ack-account", "high")
	route = queued.message_id
	local handler_calls = 0
	local first = process_one(mailbox, function()
		handler_calls += 1
		fail_next_route_update = true
		return true
	end)
	assert(first.code == "unknown" or first.code == "processed",
		"response-loss acknowledgement returned an unexpected status: " .. tostring(first.code))
	local before_recovery = backing:GetAsyncFresh(route)
	assert(before_recovery.state == "acknowledging" or before_recovery.state == "acknowledged",
		"response-loss did not leave a recoverable acknowledgement state")
	local recovered = mailbox:RecoverAsync()
	assert(recovered.code == "success", "acknowledgement recovery failed: " .. tostring(recovered.error))
	local durable = backing:GetAsyncFresh(route)
	assert(durable.state == "acknowledged" and durable.effect_outcome == "handler_succeeded",
		"recovery did not reconcile the acknowledged terminal state")
	local delivery, delivery_result = mailbox:GetDeliveryAsync(route)
	assert(delivery_result.code == "success" and delivery.State == "acknowledged",
		"acknowledgement terminal state was not visible through the public API")
	local retried = process_one(mailbox, function()
		handler_calls += 1
		return true
	end)
	assert(retried.code == "empty" and handler_calls == 1,
		"recovered acknowledgement redelivered a successfully handled message")
end

local function test_dead_letter_transition_response_loss_recovers_once()
	local backing = MailboxV2.MockStore()
	local route = nil
	local fail_next_route_update = false
	local store = {
		GetAsync = function(_, key) return backing:GetAsync(key) end,
		GetAsyncFresh = function(_, key) return backing:GetAsyncFresh(key) end,
		UpdateAsync = function(_, key, transform)
			if fail_next_route_update and key == route then
				fail_next_route_update = false
				backing:FailNextUpdate("after")
			end
			return backing:UpdateAsync(key, transform)
		end,
		RemoveAsync = function(_, key) return backing:RemoveAsync(key) end,
	}
	local mailbox = new_mailbox({
		strict_ordering_enabled = true,
		max_attempts = 1,
		retry_base_ms = 1000,
		retry_max_ms = 1000,
	}, store)
	local queued = enqueue(mailbox, "dlq-response-loss", "dlq-response-loss-id", "dlq-account", "high")
	route = queued.message_id
	local handler_calls = 0
	local first = process_one(mailbox, function()
		handler_calls += 1
		fail_next_route_update = true
		return false, "injected handler failure"
	end)
	assert(first.code == "unknown" or first.code == "dead_lettered",
		"response-loss dead-letter transition returned an unexpected status: " .. tostring(first.code))
	local before_recovery = backing:GetAsyncFresh(route)
	assert(before_recovery.state == "dead_lettering" or before_recovery.state == "dead_lettered",
		"response loss did not leave a recoverable dead-letter state")
	local recovered = mailbox:RecoverAsync()
	assert(recovered.code == "success", "dead-letter recovery failed: " .. tostring(recovered.error))
	local durable = backing:GetAsyncFresh(route)
	assert(durable.state == "dead_lettered", "dead-letter recovery did not reach its terminal state")
	local entries, _, result = mailbox:GetDeadLettersAsync(nil, 8)
	assert(result.code == "success", "dead-letter index could not be read: " .. tostring(result.error))
	local copies = 0
	for _, entry in ipairs(entries) do if entry.Id == route then copies += 1 end end
	assert(copies == 1, "dead-letter response-loss recovery duplicated the DLQ entry")
	assert(handler_calls == 1, "dead-letter recovery reran a completed handler")
end

local function test_expired_claim_is_recovered_and_retried_at_least_once()
	local mailbox, backing = new_mailbox({
		strict_ordering_enabled = true,
		lease_ms = 10000,
		lease_renewal_horizon_ms = 40000,
		retry_base_ms = 1000,
		retry_max_ms = 1000,
	})
	local queued = enqueue(mailbox, "expired-claim", "expired-claim-id", "expired-account", "high")
	local handler_calls = 0
	local first = process_one(mailbox, function()
		handler_calls += 1
		now_ms += 20000
		return true
	end)
	assert(first.code ~= "processed", "expired claim was acknowledged after its lease elapsed")
	local claimed = backing:GetAsyncFresh(queued.message_id)
	assert(claimed.state == "claimed", "expired claim was not left for explicit recovery")
	local recovered = mailbox:RecoverAsync()
	assert(recovered.code == "success", "expired claim recovery failed: " .. tostring(recovered.error))
	local ready = backing:GetAsyncFresh(queued.message_id)
	assert(ready.state == "ready", "expired claim was not returned to a retryable state")
	now_ms += 60000
	local second = process_one(mailbox, function()
		handler_calls += 1
		return true
	end)
	assert(second.code == "processed" and handler_calls == 2,
		"expired handler outcome was not retried with at-least-once semantics")
	local completed = backing:GetAsyncFresh(queued.message_id)
	assert(completed.state == "acknowledged", "retry did not finish acknowledgement")
end

local function test_competing_mailbox_instances_cannot_claim_the_same_message()
	local first_mailbox, backing = new_mailbox({ strict_ordering_enabled = true })
	local second_mailbox = new_mailbox({ strict_ordering_enabled = true }, backing)
	local queued = enqueue(first_mailbox, "competing-claim", "competing-claim-id", nil, "high")
	local first_claim, first_result = first_mailbox:_claim(queued.message_id)
	assert(type(first_claim) == "table" and first_claim.state == "claimed",
		"first mailbox did not acquire the claim: " .. tostring(first_result.code))
	local second_claim, second_result = second_mailbox:_claim(queued.message_id)
	assert(second_claim == nil and second_result.code ~= "claimed",
		"second mailbox instance acquired a live claim: " .. tostring(second_result.code))
	local durable = backing:GetAsyncFresh(queued.message_id)
	assert(durable.state == "claimed" and durable.claim_token == first_claim.claim_token,
		"competing claim changed the authoritative owner token")
end

local function test_mailbox_capacity_is_bounded_and_reported()
	local mailbox = new_mailbox({
		max_segments = 1,
		segment_max_messages = 1,
		preparation_shard_count = 1,
		preparation_max_entries_per_shard = 4,
	})
	local first = enqueue(mailbox, "capacity-one", "capacity-one-id", nil, "normal")
	local second = mailbox:EnqueueAsync("capacity-two", { value = 2 }, {
		idempotency_key = "capacity-two-id",
		priority = "normal",
		available_at = now_ms,
	})
	assert(second.code == "capacity" or second.code == "unknown",
		"mailbox capacity exhaustion returned unsafe success: " .. tostring(second.code))
	local recovery = mailbox:RecoverAsync()
	assert(recovery.code == "success",
		"capacity-blocked preparation was not safely recoverable: " .. tostring(recovery.code))
	if second.code == "unknown" then
		assert(type(recovery.message) == "table" and recovery.message.capacity_blocked_preparations == 1,
			"ambiguous capacity rejection was not exposed in recovery metadata")
	end
	local queue, queue_result = mailbox:GetQueueAsync()
	assert(queue_result.code == "success" and #queue == 1 and queue[1].Id == first.message_id,
		"capacity exhaustion created an extra active placement")
	local stats, stats_result = mailbox:GetStatsAsync()
	assert(stats_result.code == "success" and stats.active_capacity <= 1,
		"mailbox stats exceeded the configured active capacity")
end

local function test_mailbox_maintenance_reports_bounded_state_and_fails_closed()
	local mailbox = new_mailbox({
		max_segments = 1,
		segment_max_messages = 2,
		preparation_shard_count = 1,
		preparation_max_entries_per_shard = 4,
	})
	local queued = enqueue(mailbox, "maintenance-ready", "maintenance-ready-id", nil, "normal")
	local report, maintenance_result = mailbox:MaintenanceAsync()
	assert(maintenance_result.code == "success" and report.complete == true,
		"mailbox maintenance did not finish its bounded recovery/reclaim/status sequence")
	assert(type(report.recovery) == "table" and report.recovery.code == "success",
		"mailbox maintenance omitted recovery evidence")
	assert(type(report.reclaim) == "table"
		and (report.reclaim.code == "success" or report.reclaim.code == "empty"),
		"mailbox maintenance omitted bounded reclamation evidence")
	assert(type(report.stats) == "table"
		and report.stats.consistency == "bounded_non_linearizable"
		and report.stats.completeness.global_snapshot == false,
		"mailbox maintenance misrepresented its bounded status snapshot")
	assert(report.stats.active_capacity == 2 and report.stats.ready == 1,
		"mailbox maintenance capacity/readiness report was inconsistent with the observed queue")
	assert(queued.message_id ~= nil, "maintenance fixture did not retain a canonical message ID")

	local denied_store = MailboxV2.MockStore()
	local denied_mailbox = MailboxV2.new(denied_store, owner, {
		active_record = active_record,
		activation_guard = function() return false, "maintenance not enabled" end,
		encode = function(value) return serde.encode("json", value) end,
	})
	local denied_report, denied_result = denied_mailbox:MaintenanceAsync()
	assert(denied_result.code == "disabled" and denied_report.complete ~= true,
		"mailbox maintenance reported completion after activation was denied")
	assert(denied_store.get_calls == 0 and denied_store.update_calls == 0,
		"denied mailbox maintenance touched the backing store")
end

local function test_recordstore_installs_shared_scheduler_for_v2_claim_renewal()
	RecordStore.Mock.reset()
	local renewal_calls = 0
	local record = RecordStore.Mock.new("MailboxV2SchedulerIntegration", "global", "profile-scheduler", {
		schema_version = 1,
		durable_queue_enabled = true,
		queue_store_name = "MailboxV2SchedulerIntegrationQueue",
		autosave_interval = 1000,
		lease_duration = 180,
		lease_renewal = 60,
		on_queue_message_async = function(_, payload, _, _, _, _, context)
			assert(type(context) == "table" and type(context.renew_lease_async) == "function",
				"V2 core did not pass a renewable handler context")
			local renewal = context.renew_lease_async()
			assert(type(renewal) == "table" and renewal.code == "renewed",
				"V2 claim renewal did not complete through the shared scheduler: " .. tostring(renewal and renewal.code))
			assert(context.is_cancelled() == false, "successful renewal unexpectedly cancelled the handler")
			renewal_calls += 1
			return true
		end,
	})
	local open_result, open_message = record:Open({ value = 0 })
	assert(open_result == "created" or open_result == "loaded", "integration Record open failed: " .. tostring(open_message))

	local adapter, adapter_code, adapter_message = record:CreateMailboxStoreAdapter()
	assert(adapter_code == "success" and type(adapter) == "table",
		"core mailbox adapter creation failed: " .. tostring(adapter_message))
	local mailbox = MailboxV2.new(adapter, record:GetMailboxOwner(), {
		active_record = record,
		encode = function(value) return serde.encode("json", value) end,
		activation_guard = function() return true end,
		strict_ordering_enabled = true,
		lease_ms = 10000,
		lease_renewal_horizon_ms = 40000,
	})
	local enabled, enable_message = RecordStore.set_scheduler_enabled(true)
	assert(enabled, "shared scheduler could not be enabled: " .. tostring(enable_message))
	local enabled_snapshot = RecordStore.get_scheduler_snapshot()
	assert(enabled_snapshot.enabled == true,
		"shared scheduler request was not activated: " .. serde.encode("json", enabled_snapshot.rollout))
	local bind_result, bind_message = record:BindMailboxV2Async(mailbox)
	assert(bind_result == "success", "core did not bind the V2 mailbox: " .. tostring(bind_message))
	local bound_snapshot = RecordStore.get_scheduler_snapshot()
	assert(bound_snapshot.enabled == true,
		"mailbox binding unexpectedly disabled the shared scheduler: " .. serde.encode("json", bound_snapshot.rollout))

	local enqueue_result, enqueue_message = record:EnqueueAsync("update", { value = 1 }, {
		idempotency_key = "scheduler-renewal-integration",
		ordering_key = "profile-value",
		priority = "high",
	})
	assert(enqueue_result == "enqueued", "bound Record could not enqueue an ordered message: " .. tostring(enqueue_message))
	local process_result, process_message = record:ProcessQueueAsync(1)
	assert(process_result == "processed", "Record did not process a V2 message: " .. tostring(process_message))
	assert(renewal_calls == 1, "V2 handler did not exercise the shared scheduler's lease-renewal callback")

	local disabled, disable_message = RecordStore.set_scheduler_enabled(false)
	assert(disabled, "scheduler kill switch could not be restored: " .. tostring(disable_message))
	assert(record:Close() == "closed", "integration Record did not close cleanly")
	RecordStore.Mock.reset()
end

test_platform_guid_fallback_when_no_callback_is_supplied()
test_injected_clock_and_guid_contracts_fail_closed()
test_clock_is_never_called_inside_update_async_transform()
test_ordering_is_opt_in_and_input_validation_is_side_effect_free()
test_recordstore_installs_shared_scheduler_for_v2_claim_renewal()
test_producer_idempotency_conflict_and_preparation_response_loss()
test_priority_never_overtakes_an_earlier_ordered_message()
test_delayed_predecessor_blocks_later_high_priority_work()
test_retrying_predecessor_blocks_same_key_successor()
test_claim_update_fails_closed_if_order_sequence_changes_after_arbitration()
test_dead_letter_replay_gets_a_new_ordering_sequence_and_recovers_from_stale_reads()
test_order_slot_mismatch_fails_closed()
test_corrupt_existing_ordering_slot_fails_closed()
test_corrupt_ordering_index_fails_closed()
test_stale_cache_cannot_bypass_claim_metadata_validation()
test_corrupt_ready_message_metadata_fails_closed()
test_future_message_version_fails_closed()
test_future_message_version_cannot_confirm_duplicate_producer_receipt()
test_high_priority_burst_does_not_starve_background_messages()
test_clock_skew_cannot_break_ordering_under_adversarial_sort_keys()
test_priority_burst_policy_is_bounded_and_configurable()
test_acknowledgement_response_loss_recovers_without_redelivery()
test_dead_letter_transition_response_loss_recovers_once()
test_expired_claim_is_recovered_and_retried_at_least_once()
test_competing_mailbox_instances_cannot_claim_the_same_message()
test_mailbox_capacity_is_bounded_and_reported()
test_mailbox_maintenance_reports_bounded_state_and_fails_closed()

print("[MailboxV2] ordering, claim/ack recovery, bounded capacity, maintenance reporting, stale-read resistance, and idempotency regressions passed.")
Shim.close()
