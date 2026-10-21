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
	options.guid = next_guid
	options.now_ms = function() return now_ms end
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

test_ordering_is_opt_in_and_input_validation_is_side_effect_free()
test_recordstore_installs_shared_scheduler_for_v2_claim_renewal()
test_priority_never_overtakes_an_earlier_ordered_message()
test_delayed_predecessor_blocks_later_high_priority_work()
test_retrying_predecessor_blocks_same_key_successor()
test_claim_update_fails_closed_if_order_sequence_changes_after_arbitration()
test_dead_letter_replay_gets_a_new_ordering_sequence_and_recovers_from_stale_reads()
test_order_slot_mismatch_fails_closed()
test_corrupt_ordering_index_fails_closed()
test_stale_cache_cannot_bypass_claim_metadata_validation()
test_corrupt_ready_message_metadata_fails_closed()
test_high_priority_burst_does_not_starve_background_messages()
test_clock_skew_cannot_break_ordering_under_adversarial_sort_keys()
test_priority_burst_policy_is_bounded_and_configurable()

print("[MailboxV2] ordering, replay recovery, stale-read resistance, deterministic priority fairness, and input validation regressions passed.")
Shim.close()
