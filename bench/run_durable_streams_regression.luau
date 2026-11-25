--!nocheck
local FakeDataStore = require("./FakeDataStore")
local initializer = game:GetService("ServerScriptService"):WaitForChild("PlayerDataInitializer")
local DurableStreams = require(initializer:WaitForChild("RecordStoreDurableStreams"))

local now = 1000
local fake = FakeDataStore.new({ cache_seconds = 120 })
local store = fake.service:GetDataStore("DurableStreamsRegression", "global")
local client, client_error = DurableStreams.new(store, {
	max_segment_messages = 2,
	max_segment_bytes = 4096,
	max_payload_bytes = 1024,
	max_batch_messages = 2,
	now = function()
		return now
	end,
})
assert(client ~= nil, client_error)

local stream, open_error = client:OpenStreamAsync("application.events", 2)
assert(stream ~= nil, open_error)
local partition = stream:GetPartition("tenant-a")
assert(partition == stream:GetPartition("tenant-a"), "partition routing must be stable")

local mismatch, mismatch_error = client:OpenStreamAsync("application.events", 3)
assert(mismatch == nil and string.find(mismatch_error, "configuration_conflict", 1, true),
	"partition count changes must fail closed")

local first = stream:PublishAsync("tenant-a", "event-1", { kind = "created", value = 10 })
local second = stream:PublishAsync("tenant-a", "event-2", { kind = "updated", value = 20 })
local third = stream:PublishAsync("tenant-a", "event-3", { kind = "deleted", value = 30 })
assert(first.code == "committed" and first.sequence == 1, "first append failed")
assert(second.code == "committed" and second.sequence == 2, "second append failed")
assert(third.code == "committed" and third.sequence == 3 and third.segment == 2, "segment rollover failed")

local duplicate = stream:PublishAsync("tenant-a", "event-3", { kind = "deleted", value = 30 })
assert(duplicate.code == "committed" and duplicate.duplicate == true, "same-segment duplicate was not recognized")
local conflict = stream:PublishAsync("tenant-a", "event-3", { kind = "different", value = 30 })
assert(conflict.code == "conflict", "event identity conflict was not rejected")
local invalid = stream:PublishAsync("tenant-a", "event-invalid", { value = math.huge })
assert(invalid.code == "invalid", "non-finite payload was accepted")

local analytics_registration = stream:RegisterConsumerGroupAsync("analytics", "earliest", true)
assert(analytics_registration.code == "registered" or analytics_registration.code == "exists", "consumer group registration failed")

local analytics, analytics_error = stream:ClaimConsumerAsync("analytics", partition, "worker-a", 30)
assert(analytics.code == "claimed", analytics_error)
local blocked = stream:ClaimConsumerAsync("analytics", partition, "worker-b", 30)
assert(blocked.code == "busy", "a concurrent consumer must not take an active lease")

local seen = {}
for _ = 1, 5 do
	local outcome = stream:ConsumeBatchAsync(analytics.claim, function(messages, context)
		assert(context.stream == "application.events" and context.group == "analytics")
		for _, message in ipairs(messages) do
			seen[#seen + 1] = message.event_id
		end
		return true
	end, 1)
	if outcome.code == "idle" then break end
	assert(outcome.code == "committed", "consume/checkpoint failed: " .. tostring(outcome.message))
end
assert(#seen == 3 and seen[1] == "event-1" and seen[2] == "event-2" and seen[3] == "event-3",
	"consumer did not preserve partition order")
local idle = stream:ConsumeBatchAsync(analytics.claim, function()
	error("idle consumers must not invoke handlers")
end, 1)
assert(idle.code == "idle", "empty active segment must report idle")
local renewed = stream:RenewConsumerAsync(analytics.claim)
assert(renewed.code == "renewed", "consumer lease renewal failed")
local released = stream:ReleaseConsumerAsync(analytics.claim)
assert(released.code == "released", "consumer lease release failed")

local retry_registration = stream:RegisterConsumerGroupAsync("retry", "earliest", true)
assert(retry_registration.code == "registered" or retry_registration.code == "exists", "consumer group registration failed")

local retry_claim = stream:ClaimConsumerAsync("retry", partition, "retry-worker", 30)
assert(retry_claim.code == "claimed")
local rejected = stream:ConsumeBatchAsync(retry_claim.claim, function()
	return false, "temporary application failure"
end, 2)
assert(rejected.code == "retryable", "unaccepted handler batch was checkpointed")
local accepted = stream:ConsumeBatchAsync(retry_claim.claim, function(messages)
	assert(messages[1].event_id == "event-1", "failed handler advanced the cursor")
	return true
end, 2)
assert(accepted.code == "committed" and accepted.count == 2, "batch consume did not checkpoint once")

fake.control:fail_next_update("before_commit")
local uncertain = stream:PublishAsync("tenant-a", "event-4", { kind = "queued", value = 40 })
assert(uncertain.code == "unknown", "pre-commit write failure must remain uncertain")
local recovered = stream:PublishAsync("tenant-a", "event-4", { kind = "queued", value = 40 })
assert(recovered.code == "committed" and recovered.sequence == 4, "same event ID retry failed after proven absence")

fake.control:fail_next_update("commit_then_error")
local committed_unknown = stream:PublishAsync("tenant-a", "event-5", { kind = "queued", value = 50 })
assert(committed_unknown.code == "committed" and committed_unknown.reconciled == true,
	"commit-then-error was not reconciled from the durable segment")

fake.control:replay_next_update(3)
local replayed = stream:PublishAsync("tenant-a", "event-6", { kind = "queued", value = 60 })
assert(replayed.code == "committed", "UpdateAsync transform replay changed append outcome")

local fenced_registration = stream:RegisterConsumerGroupAsync("fenced", "earliest", true)
assert(fenced_registration.code == "registered" or fenced_registration.code == "exists", "consumer group registration failed")

local old_claim = stream:ClaimConsumerAsync("fenced", partition, "old-worker", 5)
assert(old_claim.code == "claimed")
local early_takeover = stream:ClaimConsumerAsync("fenced", partition, "new-worker", 5)
assert(early_takeover.code == "busy", "lease was stolen before expiry")
now += 6
local new_claim = stream:ClaimConsumerAsync("fenced", partition, "new-worker", 5)
assert(new_claim.code == "claimed" and new_claim.generation > old_claim.generation,
	"expired lease takeover did not increment the fencing generation")
local stale_handler_called = false
local stale = stream:ConsumeBatchAsync(old_claim.claim, function()
	stale_handler_called = true
	return true
end, 1)
assert(stale.code == "fenced", "stale consumer advanced a cursor after takeover")
assert(not stale_handler_called, "an expired claim must not start another handler batch")
local current = stream:ConsumeBatchAsync(new_claim.claim, function(messages)
	assert(messages[1].event_id == "event-1", "stale consumer advanced the durable cursor")
	return true
end, 1)
assert(current.code == "committed", "new fenced owner could not resume")

local restarted_client = DurableStreams.new(store, {
	max_segment_messages = 2,
	max_segment_bytes = 4096,
	max_payload_bytes = 1024,
	max_batch_messages = 2,
	now = function()
		return now
	end,
})
local restarted_stream, restart_error = restarted_client:OpenStreamAsync("application.events", 2)
assert(restarted_stream ~= nil, restart_error)
local restart_registration = restarted_stream:RegisterConsumerGroupAsync("restart", "earliest", true)
assert(restart_registration.code == "registered" or restart_registration.code == "exists", "consumer group registration failed")

local restart_claim = restarted_stream:ClaimConsumerAsync("restart", partition, "restart-worker", 30)
assert(restart_claim.code == "claimed")
local restart_seen = {}
for _ = 1, 8 do
	local outcome = restarted_stream:ConsumeBatchAsync(restart_claim.claim, function(messages)
		for _, message in ipairs(messages) do
			restart_seen[#restart_seen + 1] = message.event_id
		end
		return true
	end, 2)
	if outcome.code == "idle" then break end
	assert(outcome.code == "committed", "restarted consumer failed: " .. tostring(outcome.message))
end
assert(#restart_seen == 6, "reopened stream did not recover every committed event")
assert(restart_seen[1] == "event-1" and restart_seen[6] == "event-6", "reopened stream order changed")

local rollover_client, rollover_client_error = DurableStreams.new(store, {
	max_segment_messages = 1,
	max_segment_bytes = 4096,
	max_payload_bytes = 1024,
	max_batch_messages = 1,
	now = function()
		return now
	end,
})
assert(rollover_client ~= nil, rollover_client_error)
local rollover_stream, rollover_stream_error = rollover_client:OpenStreamAsync("application.rollover.recovery", 1)
assert(rollover_stream ~= nil, rollover_stream_error)
local rollover_partition = rollover_stream:GetPartition("tenant-rollover")
local warmed_head, warmed_head_error = rollover_stream:_ReadHead(rollover_partition)
assert(warmed_head ~= nil, warmed_head_error)

local original_update = store.UpdateAsync
local fail_head_update = true
store.UpdateAsync = function(self, key, transform)
	if fail_head_update and string.sub(key, 1, 4) == "rs2h" then
		fail_head_update = false
		error("injected crash-window head update failure")
	end
	return original_update(self, key, transform)
end
local rollover_first = rollover_stream:PublishAsync("tenant-rollover", "rollover-1", { value = 1 })
store.UpdateAsync = original_update
assert(rollover_first.code == "committed" and rollover_first.rollover_pending == true,
	"segment append must remain committed when only the head update is uncertain")

local rollover_consumer_registration = rollover_stream:RegisterConsumerGroupAsync("rollover-consumer", "earliest", true)
assert(rollover_consumer_registration.code == "registered" or rollover_consumer_registration.code == "exists", "consumer group registration failed")

local rollover_claim = rollover_stream:ClaimConsumerAsync("rollover-consumer", rollover_partition, "rollover-worker", 30)
assert(rollover_claim.code == "claimed")
local first_rollover_delivery = rollover_stream:ConsumeBatchAsync(rollover_claim.claim, function(messages)
	assert(messages[1].event_id == "rollover-1")
	return true
end, 1)
assert(first_rollover_delivery.code == "committed", "consumer failed to process the sealed segment")
local repaired_rollover = rollover_stream:ConsumeBatchAsync(rollover_claim.claim, function()
	error("empty next segment must not invoke the handler")
end, 1)
assert(repaired_rollover.code == "idle" and repaired_rollover.rollover_repaired == true,
	"consumer did not repair a sealed segment's unadvanced partition head")
local rollover_second = rollover_stream:PublishAsync("tenant-rollover", "rollover-2", { value = 2 })
assert(rollover_second.code == "committed" and rollover_second.sequence == 2 and rollover_second.segment == 2,
	"publisher did not continue from the repaired partition head")
local second_rollover_delivery = rollover_stream:ConsumeBatchAsync(rollover_claim.claim, function(messages)
	assert(messages[1].event_id == "rollover-2")
	return true
end, 1)
assert(second_rollover_delivery.code == "committed", "consumer did not resume after rollover repair")

local retention_client, retention_client_error = DurableStreams.new(store, {
	max_segment_messages = 1,
	max_segment_bytes = 4096,
	max_payload_bytes = 1024,
	max_batch_messages = 1,
	max_retained_segments = 2,
	min_segment_age_seconds = 5,
	max_segment_age_seconds = 20,
	now = function()
		return now
	end,
})
assert(retention_client ~= nil, retention_client_error)
local retention_stream, retention_open_error = retention_client:OpenStreamAsync("application.retention", 1)
assert(retention_stream ~= nil, retention_open_error)
local retention_partition = retention_stream:GetPartition("tenant-retention")
local protected_group = retention_stream:RegisterConsumerGroupAsync("slow-reader", "earliest", true)
assert(protected_group.code == "registered")
local expiring_group = retention_stream:RegisterConsumerGroupAsync("expiring-reader", "earliest", false)
assert(expiring_group.code == "registered")

local retention_first = retention_stream:PublishAsync("tenant-retention", "retention-1", { value = 1 })
local retention_second = retention_stream:PublishAsync("tenant-retention", "retention-2", { value = 2 })
assert(retention_first.code == "committed" and retention_second.code == "committed")
local retention_blocked = retention_stream:PublishAsync("tenant-retention", "retention-3", { value = 3 })
assert(retention_blocked.code == "capacity", "hard retained-segment limit must apply backpressure")
local blocked_prune = retention_stream:PruneAsync(retention_partition, 1)
assert(blocked_prune.code == "blocked", "protected lagging consumer must pin a segment before minimum age/ack")

local latest_group = retention_stream:RegisterConsumerGroupAsync("latest-reader", "latest", false)
assert(latest_group.code == "registered", "latest start position registration failed")
local slow_claim = retention_stream:ClaimConsumerAsync("slow-reader", retention_partition, "slow-worker", 30)
assert(slow_claim.code == "claimed")
local consume_first = retention_stream:ConsumeBatchAsync(slow_claim.claim, function(messages)
	assert(messages[1].event_id == "retention-1")
	return true
end, 1)
assert(consume_first.code == "committed", "protected reader failed to advance past first segment")

now += 6
fake.control:fail_next_remove(1)
local interrupted_prune = retention_stream:PruneAsync(retention_partition, 1)
assert(interrupted_prune.code == "unknown" and interrupted_prune.retained_segment == 2
	and interrupted_prune.cleanup_pending == true,
	"retention floor must commit before an idempotent deletion can fail")
local pruned = retention_stream:PruneAsync(retention_partition, 1)
assert(pruned.code == "pruned" and pruned.removed == 1 and pruned.retained_segment == 2,
	"resumed cleanup did not reclaim the already-expired segment")
local expired_before_forced = retention_stream:ClaimConsumerAsync("expiring-reader", retention_partition, "expired-early-worker", 30)
assert(expired_before_forced.code == "expired" and expired_before_forced.earliest_segment == 2,
	"non-protected consumer must receive an explicit retention gap")
local forced_group = retention_stream:RegisterConsumerGroupAsync("forced-reader", { segment = 2, offset = 1 }, true)
assert(forced_group.code == "registered", "explicit position registration failed")
local retention_third = retention_stream:PublishAsync("tenant-retention", "retention-3", { value = 3 })
assert(retention_third.code == "committed" and retention_third.sequence == 3 and retention_third.segment == 3,
	"publisher did not resume after safe reclamation")

local latest_claim = retention_stream:ClaimConsumerAsync("latest-reader", retention_partition, "latest-worker", 30)
assert(latest_claim.code == "claimed")
local latest_seen = {}
local latest_outcome = retention_stream:ConsumeBatchAsync(latest_claim.claim, function(messages)
	for _, message in ipairs(messages) do
		latest_seen[#latest_seen + 1] = message.event_id
	end
	return true
end, 1)
assert(latest_outcome.code == "committed" and #latest_seen == 1 and latest_seen[1] == "retention-3",
	"latest start position must not replay earlier events")

local forced_claim_before_expiry = retention_stream:ClaimConsumerAsync("forced-reader", retention_partition, "forced-worker", 30)
assert(forced_claim_before_expiry.code == "claimed")
now += 21
local expired_prune = retention_stream:PruneAsync(retention_partition, 1)
assert(expired_prune.code == "pruned" and expired_prune.removed == 1 and expired_prune.retained_segment == 3
	and expired_prune.forced_expiry == true,
	"maximum age must explicitly expire a lagging retention-protected consumer's segment")
local forced_claim = retention_stream:ClaimConsumerAsync("forced-reader", retention_partition, "forced-worker-new", 30)
assert(forced_claim.code == "expired" and forced_claim.earliest_segment == 3,
	"forced expiry must return an explicit retention-gap result")
local expired_delivery = retention_stream:ConsumeBatchAsync(
	slow_claim.claim,
	function()
		error("retention gaps must not invoke a handler")
	end,
	1
)
assert(expired_delivery.code == "expired" and expired_delivery.earliest_sequence == 3,
	"an already-claimed slow consumer must observe retention expiry without a silent cursor jump")

local missing_confirmation = retention_stream:RemoveConsumerGroupAsync("expiring-reader", false)
assert(missing_confirmation.code == "invalid", "consumer-group deletion must require explicit confirmation")
fake.control:fail_next_remove(1)
local interrupted_group_remove = retention_stream:RemoveConsumerGroupAsync("expiring-reader", true)
assert(interrupted_group_remove.code == "cleanup_pending", "group removal must expose partial cleanup")
local removing_claim = retention_stream:ClaimConsumerAsync("expiring-reader", retention_partition, "removed-worker", 30)
assert(removing_claim.code == "removed", "a group marked for removal must not accept new claims")
local removed_group = retention_stream:RemoveConsumerGroupAsync("expiring-reader", true)
assert(removed_group.code == "removed" and removed_group.cleanup_pending == false,
	"confirmed consumer-group removal did not resume after a deletion failure")

local batch_client, batch_client_error = DurableStreams.new(store, {
	max_segment_messages = 4,
	max_segment_bytes = 4096,
	max_payload_bytes = 1024,
	max_batch_messages = 4,
	now = function()
		return now
	end,
})
assert(batch_client ~= nil, batch_client_error)
local batch_stream, batch_stream_error = batch_client:OpenStreamAsync("application.batch.events", 2)
assert(batch_stream ~= nil, batch_stream_error)
local warm = batch_stream:PublishAsync("tenant-b", "batch-warm", { value = 0 })
assert(warm.code == "committed", "batch stream warm-up append failed")
local metrics_before_batch = fake.control:metrics()
local batched = batch_stream:PublishBatchAsync("tenant-b", {
	{ event_id = "batch-1", payload = { value = 1 } },
	{ event_id = "batch-2", payload = { value = 2 } },
})
local metrics_after_batch = fake.control:metrics()
assert(batched.code == "committed" and batched.count == 2, "multi-event append failed")
assert(#batched.items == 2 and batched.items[1].sequence == 2 and batched.items[2].sequence == 3,
	"batch append did not assign a contiguous sequence range")
assert(metrics_after_batch.update_calls - metrics_before_batch.update_calls == 1,
	"one append batch must commit through one DataStore UpdateAsync")

local duplicate_batch = batch_stream:PublishBatchAsync("tenant-b", {
	{ event_id = "batch-1", payload = { value = 1 } },
	{ event_id = "batch-2", payload = { value = 2 } },
})
assert(duplicate_batch.code == "committed" and duplicate_batch.duplicate == true,
	"retrying the same active-segment batch must reconcile as duplicate")
local conflicting_batch = batch_stream:PublishBatchAsync("tenant-b", {
	{ event_id = "batch-1", payload = { value = 999 } },
	{ event_id = "batch-3", payload = { value = 3 } },
})
assert(conflicting_batch.code == "conflict", "batch event identity conflict was not rejected")


local idempotency_client, idempotency_client_error = DurableStreams.new(store, {
	max_segment_messages = 1,
	max_segment_bytes = 4096,
	max_payload_bytes = 1024,
	max_batch_messages = 1,
	max_retained_segments = 8,
	min_segment_age_seconds = 0,
	max_segment_age_seconds = 1,
	now = function()
		return now
	end,
})
assert(idempotency_client ~= nil, idempotency_client_error)
local idempotency_stream, idempotency_stream_error = idempotency_client:OpenStreamAsync("application.permanent-idempotency", 1)
assert(idempotency_stream ~= nil, idempotency_stream_error)
local idempotency_partition = idempotency_stream:GetPartition("producer-route")
local permanent_first = idempotency_stream:PublishBatchAsync("producer-route", {
	{ event_id = "stable-event-1", producer_id = "stable-producer", producer_sequence = 1, payload = { value = 1 } },
})
assert(permanent_first.code == "committed", "first producer sequence failed")
local permanent_second = idempotency_stream:PublishBatchAsync("producer-route", {
	{ event_id = "stable-event-2", producer_id = "stable-producer", producer_sequence = 2, payload = { value = 2 } },
})
assert(permanent_second.code == "committed", "second producer sequence failed")
now += 2
local permanent_prune = idempotency_stream:PruneAsync(idempotency_partition, 4)
assert(permanent_prune.code == "pruned" and permanent_prune.removed >= 1,
	"producer idempotency fixture did not delete the original event segment")
local updates_before_permanent_retry = fake.control:metrics().update_calls
local permanent_retry = idempotency_stream:PublishBatchAsync("producer-route", {
	{ event_id = "stable-event-1", producer_id = "stable-producer", producer_sequence = 1, payload = { value = 1 } },
})
local updates_after_permanent_retry = fake.control:metrics().update_calls
assert(permanent_retry.code == "committed" and permanent_retry.duplicate == true,
	"producer sequence retry appended again after its original segment was deleted")
assert(updates_after_permanent_retry == updates_before_permanent_retry,
	"historical producer retry must resolve from the rollover checkpoint without another write")

local producer_state = idempotency_stream:GetProducerSequenceAsync("producer-route", "stable-producer")
assert(producer_state.code == "ok" and producer_state.sequence == 2 and producer_state.next_sequence == 3,
	"producer sequence checkpoint was not carried through segment rollover and pruning")

local latest_sequence_conflict = idempotency_stream:PublishBatchAsync("producer-route", {
	{ event_id = "stable-event-2", producer_id = "stable-producer", producer_sequence = 2, payload = { value = 999 } },
})
assert(latest_sequence_conflict.code == "conflict",
	"reusing the latest producer sequence with changed content must be rejected")

local producer_gap = idempotency_stream:PublishBatchAsync("producer-route", {
	{ event_id = "stable-event-4", producer_id = "stable-producer", producer_sequence = 4, payload = { value = 4 } },
})
assert(producer_gap.code == "conflict",
	"producer sequence gaps must not be accepted")

local permanent_third = idempotency_stream:PublishBatchAsync("producer-route", {
	{ event_id = "stable-event-3", producer_id = "stable-producer", producer_sequence = 3, payload = { value = 3 } },
})
assert(permanent_third.code == "committed", "producer did not resume at its next durable sequence")

local stale_producer_retry = idempotency_stream:PublishBatchAsync("producer-route", {
	{ event_id = "stable-event-2", producer_id = "stable-producer", producer_sequence = 2, payload = { value = 2 } },
})
assert(stale_producer_retry.code == "committed" and stale_producer_retry.duplicate == true,
	"an older producer sequence was not deduplicated after a later sequence committed")

print("[durable-streams] partition append, rollover, integrity, consumer fencing, batch checkpoint, replay and recovery passed")
