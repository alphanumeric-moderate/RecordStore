--!nocheck
-- PR #33 advanced-scheduler public behavior regression suite.
local Scheduler = require("../src/PlayerDataInitializer/RecordStoreScheduler")
local task = require("@lune/task")
local Shim = require("./RobloxShim")

local now_ms = 1_800_000_000_000
local function new_scheduler(options)
	options = options or {}
	options.now_ms = function() return now_ms end
	options.advance_ms = function(ms) now_ms += ms end
	return Scheduler.new(options)
end

local function enqueue(scheduler, item)
	local result = scheduler:Enqueue(item)
	assert(result.code == "accepted", "enqueue failed: " .. tostring(result.code) .. " " .. tostring(result.message))
end

local function take(scheduler, expected_id)
	local item, status = scheduler:TakeNext()
	assert(item ~= nil and status == "success", "expected a selectable item")
	assert(item.id == expected_id, "expected " .. expected_id .. ", got " .. tostring(item and item.id))
	assert(scheduler:MarkCompleted(item.id, "committed"), "selected work did not complete")
	return item
end

-- Revisioned policy changes must reject stale and malformed revisions.
do
local policy = new_scheduler()
local policy_stats = policy:Stats()
assert(not policy:SetPolicy({ revision = policy_stats.policy.revision }), "stale policy revision was accepted")
assert(not policy:SetPolicy({ revision = policy_stats.policy.revision + 1, algorithm = "not-a-policy" }),
	"unknown scheduler algorithm was accepted")
local bounded_buffer_ok = policy:SetPolicy({
	revision = policy_stats.policy.revision + 1,
	mode = "bounded_buffer",
})
assert(not bounded_buffer_ok, "unsupported bounded_buffer mode was accepted")
local good_policy, policy_error = policy:SetPolicy({
	revision = policy_stats.policy.revision + 1,
	max_scheduled_in_flight = 4,
	scheduler_critical_reserve = 1,
	max_per_owner_in_flight = 2,
})
assert(good_policy, "valid policy was rejected: " .. tostring(policy_error))

-- DRR shares service across equally weighted owner/work-class lanes.
local fair = new_scheduler()
for index = 1, 5 do
	enqueue(fair, { id = "a-" .. index, owner_id = "owner-a", lane = "normal", work_class = "normal", operation_class = "read" })
	enqueue(fair, { id = "b-" .. index, owner_id = "owner-b", lane = "normal", work_class = "normal", operation_class = "read" })
end
local owner_order, owner_a, owner_b = {}, 0, 0
for _ = 1, 10 do
	local item, status = fair:TakeNext()
	assert(item ~= nil and status == "success", "DRR unexpectedly had no eligible work")
	owner_order[#owner_order + 1] = item.owner_id
	if item.owner_id == "owner-a" then owner_a += 1 else owner_b += 1 end
	assert(fair:MarkCompleted(item.id, "committed"), "DRR selection did not release owner capacity")
end
assert(owner_a == 5 and owner_b == 5, "DRR did not provide equal service to equal-weight owners")
for index = 2, #owner_order do
	assert(owner_order[index] ~= owner_order[index - 1], "DRR did not rotate equally weighted owners")
end

-- Multi-dimensional cost prevents a large UpdateAsync estimate from winning by item count.
local weighted_cost = new_scheduler()
enqueue(weighted_cost, { id = "large", owner_id = "large-owner", lane = "normal", operation_class = "update_async", read_units = 8, write_units = 8 })
enqueue(weighted_cost, { id = "small", owner_id = "small-owner", lane = "normal", operation_class = "read" })
take(weighted_cost, "small")
take(weighted_cost, "large")

-- DRR cost must match the actual adaptive batch size admitted for execution.
local adaptive_drr = new_scheduler()
local adaptive_drr_policy = adaptive_drr:Stats().policy
adaptive_drr:Observe("outbox_dispatch", true, adaptive_drr_policy.batch_latency_ceiling_ms)
enqueue(adaptive_drr, {
	id = "adaptive-batch",
	owner_id = "owner-a",
	lane = "normal",
	work_class = "shared",
	operation_class = "outbox_dispatch",
	batchable = true,
	batch_size = 16,
	batch_backlog = 16,
	read_units = 1,
	write_units = 1,
	estimated_bytes = 16384,
})
enqueue(adaptive_drr, {
	id = "single-item",
	owner_id = "owner-b",
	lane = "normal",
	work_class = "shared",
	operation_class = "read",
	read_units = 1,
	write_units = 0,
	estimated_bytes = 16384,
})
local adaptive_first, adaptive_status = adaptive_drr:TakeNext()
assert(adaptive_first ~= nil and adaptive_status == "success" and adaptive_first.id == "adaptive-batch",
	"DRR charged the requested batch size instead of the latency-capped batch size")
assert(adaptive_first.admission_batch_size == 1,
	"adaptive DRR fixture did not actually select a one-item batch")
assert(adaptive_drr:MarkCompleted(adaptive_first.id, "committed"),
	"adaptive DRR selected work could not complete")

-- Governor reservation tickets are single-use and cannot be forged by mutating ticket data.
local ticket_governor = new_scheduler()
local ticket_policy = ticket_governor:Stats().policy
assert(ticket_governor:SetPolicy({
	revision = ticket_policy.revision + 1,
	max_in_flight = 2,
	critical_reserve = 0,
}), "single-use reservation policy was rejected")
local ticket_dimensions = { read_units = 0, write_units = 0, estimated_bytes = 1024, handler_slots = 1 }
local reservation_a = ticket_governor:Admit("maintenance", "tracing", 1, false, false, ticket_dimensions)
local reservation_b = ticket_governor:Admit("maintenance", "tracing", 1, false, false, ticket_dimensions)
assert(reservation_a.code == "admitted" and reservation_b.code == "admitted",
	"ticket fixture could not consume its two-slot capacity")
assert(ticket_governor:Stats().active_reservation_tickets == 2, "active reservation tickets were not recorded")
assert(ticket_governor:Release(reservation_a), "first reservation release failed")
assert(not ticket_governor:Release(reservation_a), "duplicate reservation release was accepted")
reservation_a.cost = 0
reservation_a.read_units = 0
local reservation_c = ticket_governor:Admit("maintenance", "tracing", 1, false, false, ticket_dimensions)
assert(reservation_c.code == "admitted", "released reservation slot could not be reused")
local reservation_d = ticket_governor:Admit("maintenance", "tracing", 1, false, false, ticket_dimensions)
assert(reservation_d.code == "capacity", "duplicate release undercounted in-flight work")
assert(ticket_governor:Stats().in_flight == 2 and ticket_governor:Stats().active_reservation_tickets == 2,
	"reservation accounting diverged from the live ticket set")
assert(ticket_governor:Release(reservation_b) and ticket_governor:Release(reservation_c),
	"remaining reservation tickets were not released")
assert(ticket_governor:Stats().in_flight == 0 and ticket_governor:Stats().active_reservation_tickets == 0,
	"reservation capacity remained allocated after all live tickets were released")

-- Releasing the last ticket for a caller-defined work class must not retain a dead class key.
local bounded_work_classes = new_scheduler()
for index = 1, 128 do
	local class_name = "custom-work-class-" .. tostring(index)
	local reservation = bounded_work_classes:Admit(
		class_name, "tracing", 1, false, false,
		{ read_units = 0, write_units = 0, estimated_bytes = 1024, handler_slots = 1 }
	)
	assert(reservation.code == "admitted", "unique work-class reservation was rejected")
	assert(bounded_work_classes:Release(reservation), "unique work-class reservation was not released")
end
local work_class_snapshot = bounded_work_classes:Stats()
local retained_work_class_count = 0
for _ in pairs(work_class_snapshot.classes) do retained_work_class_count += 1 end
assert(retained_work_class_count == 0,
	"released custom work classes remained in the governor accounting map")

-- Queue wait and operation latency percentiles are exposed per bounded dimensions.
local latency_metrics = new_scheduler()
enqueue(latency_metrics, {
	id = "metrics-save",
	owner_id = "metrics-owner",
	lane = "normal",
	work_class = "profile_save",
	operation_class = "update_async",
	service_class = "critical",
})
now_ms += 25
take(latency_metrics, "metrics-save")
latency_metrics:Observe("update_async", true, 4)
latency_metrics:Observe("update_async", true, 100)
local latency_snapshot = latency_metrics:Stats()
local save_wait_bucket = nil
for _, bucket in pairs(latency_snapshot.scheduler.by_lane_class) do
	if bucket.lane == "normal" and bucket.work_class == "profile_save" and bucket.service_class == "critical" then
		save_wait_bucket = bucket
		break
	end
end
assert(save_wait_bucket ~= nil and save_wait_bucket.selected == 1,
	"per-lane/work-class wait histogram was not populated")
assert(save_wait_bucket.p50_ms == 25 and save_wait_bucket.p95_ms == 25 and save_wait_bucket.p99_ms == 25,
	"queue wait percentiles did not reflect the observed critical save delay")
assert(latency_snapshot.latency_percentiles_by_operation.update_async.p50_ms == 4
	and latency_snapshot.latency_percentiles_by_operation.update_async.p95_ms == 100,
	"operation latency tail percentiles were not recorded")

-- Caller-controlled operation labels must not create unbounded long-lived telemetry state.
local bounded_operation_metrics = new_scheduler()
for index = 1, 128 do
	local operation_kind = "unique-operation-" .. tostring(index)
	for _ = 1, 5 do
		bounded_operation_metrics:Observe(operation_kind, false, index, "transient", index)
	end
end
-- Built-in persistence classes retain their own circuit/budget observations even after custom labels overflow.
bounded_operation_metrics:Observe("lease_renewal", true, 7, nil, 7)
bounded_operation_metrics:Observe("profile_release", true, 8, nil, 8)
bounded_operation_metrics:Observe("service", false, 99999, "transient", 1)
local bounded_metrics_snapshot = bounded_operation_metrics:Stats()
assert(bounded_metrics_snapshot.latency_ewma.lease_renewal == 7
	and bounded_metrics_snapshot.last_budget_by_kind.lease_renewal == 7,
	"core lease-renewal telemetry was collapsed into the overflow bucket")
assert(bounded_metrics_snapshot.latency_ewma.profile_release == 8
	and bounded_metrics_snapshot.last_budget_by_kind.profile_release == 8,
	"core profile-release telemetry was collapsed into the overflow bucket")
assert(bounded_metrics_snapshot.latency_ewma.service == nil
	and bounded_metrics_snapshot.last_budget_by_kind.service == nil,
	"custom operation label collided with internal service-latency telemetry")
local function metric_key_count(values)
	local count = 0
	for _ in pairs(values) do count += 1 end
	return count
end
assert(metric_key_count(bounded_metrics_snapshot.latency_ewma) <= 32,
	"operation EWMA retained an unbounded number of caller-controlled labels")
assert(metric_key_count(bounded_metrics_snapshot.last_budget_by_kind) <= 32,
	"operation budget observations retained an unbounded number of caller-controlled labels")
assert(metric_key_count(bounded_metrics_snapshot.circuits) <= 32,
	"circuit-breaker state retained an unbounded number of caller-controlled labels")
assert(metric_key_count(bounded_metrics_snapshot.latency_percentiles_by_operation) <= 32,
	"operation latency percentile state exceeded its cardinality bound")

-- Deadline slack affects selection but does not turn an SLO into an expiry.
local deadline = new_scheduler()
enqueue(deadline, { id = "no-deadline", owner_id = "same-owner", lane = "normal" })
enqueue(deadline, { id = "tight-deadline", owner_id = "same-owner", lane = "normal", deadline_ms = now_ms + 5 })
local picked = deadline:TakeNext()
assert(picked ~= nil and picked.id == "tight-deadline", "lower deadline slack was not preferred within a lane")
assert(deadline:MarkCompleted(picked.id, "committed"), "deadline selection did not complete")
now_ms += 20
local overdue = deadline:TakeNext()
assert(overdue ~= nil and overdue.id == "no-deadline", "eligible work was lost after a deadline passed")
assert(deadline:MarkCompleted(overdue.id, "committed"), "overdue item did not release scheduler capacity")

-- Availability is a hard no-start boundary even if due_at_ms is earlier.
local availability = new_scheduler()
local availability_at = now_ms + 100
enqueue(availability, {
	id = "availability-lower-bound",
	owner_id = "availability-owner",
	lane = "normal",
	due_at_ms = now_ms,
	available_at_ms = availability_at,
	deadline_ms = now_ms + 50,
})
assert(availability:TakeNext() == nil, "scheduler selected work before available_at_ms")
now_ms = availability_at
take(availability, "availability-lower-bound")

-- A missed advisory deadline must not rewrite a future availability time.
local scheduled_availability = new_scheduler()
local scheduled_dispatcher = Scheduler.new_dispatcher(scheduled_availability, {
	now_ms = function() return now_ms end,
})
local dispatcher_available_at = now_ms + 100
local callback_started_before_availability = false
local scheduled_boundary = scheduled_dispatcher:Schedule(
	"availability-owner",
	"deadline-before-availability",
	function()
		callback_started_before_availability = true
		return { code = "committed" }
	end,
	{
		lane = "normal",
		available_at_ms = dispatcher_available_at,
		deadline_ms = now_ms + 50,
	}
)
scheduled_dispatcher:Close()
assert(scheduled_boundary.code == "accepted", "deadline/availability work was rejected")
assert(scheduled_boundary.due_at_ms == dispatcher_available_at,
	"deadline moved scheduled work ahead of its availability boundary")
assert(not callback_started_before_availability,
	"callback executed before its availability boundary")

-- Expiry is a no-new-start boundary and emits an explicit terminal status.
local expiration = new_scheduler()
enqueue(expiration, { id = "expires-before-start", owner_id = "expiry-owner", lane = "normal", expires_at_ms = now_ms + 1 })
now_ms += 2
local expired, expired_status = expiration:TakeNext()
assert(expired ~= nil and expired_status == "expired", "expired work was silently discarded")
assert(expired.terminal_result.code == "expired", "expiry did not return a typed result")
assert(expiration:Stats().stats.scheduled_expired == 1, "expiry metric did not increment")
assert(expiration:MarkCompleted(expired.id, expired.terminal_result.code), "expired work could not be reconciled")

-- Expiry wakes earlier than availability and accepted work is never evicted
-- to make room when the bounded local queue is full.
local early_expiry = new_scheduler()
enqueue(early_expiry, {
	id = "expiry-before-availability",
	owner_id = "expiry-owner",
	lane = "background",
	due_at_ms = now_ms + 100,
	expires_at_ms = now_ms + 20,
})
assert(early_expiry:NextWakeAt() == now_ms + 20,
	"dispatcher wake was scheduled after an earlier expiry boundary")
local capacity = new_scheduler()
local capacity_policy = capacity:Stats().policy
assert(capacity:SetPolicy({
	revision = capacity_policy.revision + 1,
	queue_capacity = 2,
}), "bounded queue capacity policy was rejected")
enqueue(capacity, { id = "capacity-1", owner_id = "owner-1", lane = "normal" })
enqueue(capacity, { id = "capacity-2", owner_id = "owner-2", lane = "normal" })
local capacity_rejected = capacity:Enqueue({ id = "capacity-3", owner_id = "owner-3", lane = "normal" })
assert(capacity_rejected.code == "capacity", "full scheduler queue did not apply explicit backpressure")
assert(capacity:Stats().queue_items == 2, "queue capacity overflow evicted or silently accepted work")

-- A completion must refer to known dispatched/terminal work; it cannot forge or orphan dependencies.
local completion_guard = new_scheduler()
assert(not completion_guard:MarkCompleted("ghost-completion", "committed"),
	"unknown work ID was allowed to manufacture a completed prerequisite")
local phantom_dependent = completion_guard:Enqueue({
	id = "dependent-on-ghost", owner_id = "ghost-owner", dependencies = { "ghost-completion" },
})
assert(phantom_dependent.code == "invalid",
	"dependency was accepted after completion of an unknown work ID")
enqueue(completion_guard, { id = "still-queued", owner_id = "queued-owner" })
assert(not completion_guard:MarkCompleted("still-queued", "committed"),
	"queued work was allowed to complete before it was selected")
local guarded_item, guarded_status = completion_guard:TakeNext()
assert(guarded_item ~= nil and guarded_item.id == "still-queued" and guarded_status == "success",
	"rejecting premature completion orphaned the queued item")
assert(completion_guard:MarkCompleted(guarded_item.id, "committed"),
	"selected work could not complete after the premature completion was rejected")

-- Terminal IDs remain reserved while dependency history retains their outcome.
local completed_identity = new_scheduler()
enqueue(completed_identity, { id = "reused-completed-id", owner_id = "identity-owner" })
take(completed_identity, "reused-completed-id")
local duplicate_completed_id = completed_identity:Enqueue({
	id = "reused-completed-id", owner_id = "identity-owner",
})
assert(duplicate_completed_id.code == "duplicate",
	"completed work ID was reused while its dependency result was still retained")

local failed_identity = new_scheduler()
enqueue(failed_identity, { id = "reused-failed-id", owner_id = "identity-owner" })
local failed_identity_item, failed_identity_status = failed_identity:TakeNext()
assert(failed_identity_item ~= nil and failed_identity_status == "success")
assert(failed_identity:MarkCompleted(failed_identity_item.id, "unknown"))
local duplicate_failed_id = failed_identity:Enqueue({
	id = "reused-failed-id", owner_id = "identity-owner",
})
assert(duplicate_failed_id.code == "duplicate",
	"failed work ID was reused while its dependency result was still retained")


-- Dependency terminal history must survive pruning while referenced by queued or in-flight work.
do
	local queued_history = new_scheduler()
	local policy = queued_history:Stats().policy
	local configured, policy_error = queued_history:SetPolicy({
		revision = policy.revision + 1,
		queue_capacity = 2,
	})
	assert(configured, "small bounded history policy was rejected: " .. tostring(policy_error))
	enqueue(queued_history, { id = "queued-history-prerequisite", owner_id = "history-owner" })
	take(queued_history, "queued-history-prerequisite")
	enqueue(queued_history, {
		id = "queued-history-dependent",
		owner_id = "history-owner",
		available_at_ms = now_ms + 60000,
		dependencies = { "queued-history-prerequisite" },
	})
	for index = 1, 8 do
		local id = "queued-history-noise-" .. index
		enqueue(queued_history, { id = id, owner_id = "noise-" .. index })
		take(queued_history, id)
	end
	assert(queued_history.completed["queued-history-prerequisite"] == true,
		"queued dependency lost its prerequisite outcome during history pruning")
	assert(#queued_history.completed_order <= queued_history:Stats().policy.queue_capacity * 2,
		"completed-history order grew beyond its configured bound while outcomes were referenced")
	now_ms += 60000
	take(queued_history, "queued-history-dependent")
	for index = 1, 8 do
		local id = "reclaim-history-noise-" .. index
		enqueue(queued_history, { id = id, owner_id = "reclaim-" .. index })
		take(queued_history, id)
	end
	assert(queued_history.completed["queued-history-prerequisite"] == nil,
		"completed history outlived its retention order after its last dependent ended")
end

do
	local inflight_history = new_scheduler()
	local policy = inflight_history:Stats().policy
	local configured, policy_error = inflight_history:SetPolicy({
		revision = policy.revision + 1,
		queue_capacity = 2,
	})
	assert(configured, "small in-flight history policy was rejected: " .. tostring(policy_error))
	enqueue(inflight_history, { id = "inflight-history-prerequisite", owner_id = "history-owner" })
	take(inflight_history, "inflight-history-prerequisite")
	enqueue(inflight_history, {
		id = "inflight-history-dependent",
		owner_id = "history-owner",
		dependencies = { "inflight-history-prerequisite" },
	})
	local dependent_item, dependent_status = inflight_history:TakeNext()
	assert(dependent_item ~= nil and dependent_item.id == "inflight-history-dependent"
		and dependent_status == "success", "dependent work did not become in-flight")
	for index = 1, 8 do
		local id = "inflight-history-noise-" .. index
		enqueue(inflight_history, { id = id, owner_id = "inflight-noise-" .. index })
		take(inflight_history, id)
	end
	assert(inflight_history.completed["inflight-history-prerequisite"] == true,
		"in-flight dependency lost its prerequisite result before a retry")
	assert(#inflight_history.completed_order <= inflight_history:Stats().policy.queue_capacity * 2,
		"in-flight dependencies caused completed-history order to grow beyond its configured bound")
	local rescheduled, reschedule_error = inflight_history:Reschedule(dependent_item.id, now_ms)
	assert(rescheduled, "dependent work could not be rescheduled: " .. tostring(reschedule_error))
	local retried_item, retry_status = inflight_history:TakeNext()
	assert(retried_item ~= nil and retried_item.id == dependent_item.id and retry_status == "success",
		"retry became permanently ineligible after its prerequisite aged out")
	assert(inflight_history:MarkCompleted(retried_item.id, "committed"),
		"retried dependent could not complete")
	assert(inflight_history.completed["inflight-history-prerequisite"] == nil,
		"pending completed history was not reclaimed when its final dependent completed")
end

-- Dependencies cannot bypass a missing, failed or unknown prerequisite.
local dependencies = new_scheduler()
assert(dependencies:Enqueue({ id = "missing-dependent", owner_id = "x", dependencies = { "missing" } }).code == "invalid",
	"missing dependency was accepted")
assert(dependencies:Enqueue({ id = "self-cycle", owner_id = "x", dependencies = { "self-cycle" } }).code == "invalid",
	"self dependency was accepted")
enqueue(dependencies, { id = "prerequisite", owner_id = "workflow-owner", lane = "background" })
enqueue(dependencies, { id = "dependent", owner_id = "workflow-owner", lane = "high", dependencies = { "prerequisite" } })
take(dependencies, "prerequisite")
take(dependencies, "dependent")
local failed_flow = new_scheduler()
enqueue(failed_flow, { id = "failing-step", owner_id = "flow-owner", lane = "normal" })
enqueue(failed_flow, { id = "must-not-run", owner_id = "flow-owner", lane = "high", dependencies = { "failing-step" } })
local failing = failed_flow:TakeNext()
assert(failing ~= nil and failing.id == "failing-step", "workflow dependency was selected out of order")
assert(failed_flow:MarkCompleted(failing.id, "unknown"), "unknown prerequisite outcome did not terminalize")
local blocked, blocked_status = failed_flow:TakeNext()
assert(blocked ~= nil and blocked_status == "dependency_failed", "dependent work did not return dependency_failed")
assert(blocked.terminal_result.dependency_code == "unknown", "dependency failure lost the prerequisite outcome")
assert(failed_flow:MarkCompleted(blocked.id, blocked.terminal_result.code), "failed dependency did not reconcile")

-- Due-time scheduling is ordered, bounded, and replacement-safe.
local due = new_scheduler()
assert(due:ScheduleDue("late", now_ms + 100, "late-value"))
assert(due:ScheduleDue("early", now_ms + 10, "early-value"))
assert(due:NextDueAt() == now_ms + 10, "due heap did not expose the earliest wake")
assert(due:ScheduleDue("replace", now_ms + 1, "stale-value"))
assert(due:ScheduleDue("replace", now_ms + 200, "new-value"))
assert(due:NextDueAt() == now_ms + 10, "replacing one due entry hid an earlier wake")
now_ms += 10
local popped = due:PopDue(1)
assert(#popped == 1 and popped[1].id == "early", "due heap returned the wrong item")
assert(due:NextDueAt() == now_ms + 90, "due heap exposed a stale replaced timer")

-- Queue wake scheduling uses a bounded event heap and ignores cancelled/stale entries.
local wake_events = new_scheduler()
enqueue(wake_events, {
	id = "wake-later",
	owner_id = "wake-owner-later",
	lane = "normal",
	due_at_ms = now_ms + 100,
	expires_at_ms = now_ms + 300,
})
enqueue(wake_events, {
	id = "wake-early",
	owner_id = "wake-owner-early",
	lane = "background",
	due_at_ms = now_ms + 20,
	expires_at_ms = now_ms + 40,
})
assert(wake_events:NextWakeAt() == now_ms + 20,
	"wake event heap did not select the earliest eligible due boundary")
assert(wake_events:Stats().scheduler.wake_heap_items >= 4,
	"queue due and expiry boundaries were not indexed in the local wake heap")
local cancelled_wake, cancelled_wake_error = wake_events:CancelQueued("wake-early")
assert(cancelled_wake ~= nil and cancelled_wake_error == nil,
	"future queued work could not be cancelled")
assert(wake_events:MarkCompleted(cancelled_wake.id, "cancelled"),
	"cancelled wake entry did not terminalize")
assert(wake_events:NextWakeAt() == now_ms + 100,
	"cancelled/stale wake event hid the next live queue boundary")
now_ms += 101
assert(wake_events:NextWakeAt() == now_ms + 199,
	"expiry boundary disappeared after its due event had passed")
assert(wake_events:Stats().scheduler.wake_heap_items <= wake_events:Stats().policy.queue_capacity * 4,
	"wake event heap exceeded its bounded compaction threshold")

-- Per-owner in-flight caps cannot prevent a different owner from making progress.
local per_owner = new_scheduler()
local owner_policy = per_owner:Stats().policy
local per_owner_ok, per_owner_error = per_owner:SetPolicy({
	revision = owner_policy.revision + 1,
	max_per_owner_in_flight = 1,
})
assert(per_owner_ok, "per-owner policy was rejected: " .. tostring(per_owner_error))
enqueue(per_owner, { id = "owner-one-a", owner_id = "one", lane = "normal" })
enqueue(per_owner, { id = "owner-one-b", owner_id = "one", lane = "normal" })
enqueue(per_owner, { id = "owner-two", owner_id = "two", lane = "normal" })
local first = per_owner:TakeNext()
assert(first ~= nil, "bounded concurrency fixture had no first item")
local second = per_owner:TakeNext()
assert(second ~= nil, "another owner did not retain a selectable item")
assert(first.owner_id ~= second.owner_id, "per-owner concurrency cap was exceeded")
assert(per_owner:TakeNext() == nil, "the configured per-owner in-flight cap was exceeded")
assert(per_owner:MarkCompleted(first.id, "committed"))
assert(per_owner:MarkCompleted(second.id, "committed"))
take(per_owner, "owner-one-b")

-- Across owners, renewal selection must prefer the least remaining lease slack
-- even while both renewals are outside the generic five-second urgent window.
local renewal_deadlines = new_scheduler()
enqueue(renewal_deadlines, {
	id = "renewal-later-slack",
	owner_id = "a-later",
	lane = "lease_renewal",
	work_class = "lease_renewal",
	service_class = "critical",
	deadline_ms = now_ms + 30000,
})
enqueue(renewal_deadlines, {
	id = "renewal-lower-slack",
	owner_id = "z-sooner",
	lane = "lease_renewal",
	work_class = "lease_renewal",
	service_class = "critical",
	deadline_ms = now_ms + 8000,
})
local safest_renewal = renewal_deadlines:TakeNext(true)
assert(safest_renewal ~= nil and safest_renewal.id == "renewal-lower-slack",
	"DRR chose by owner lane instead of remaining lease slack across renewals")
assert(renewal_deadlines:MarkCompleted(safest_renewal.id, "renewed"))
local second_safest_renewal = renewal_deadlines:TakeNext(true)
assert(second_safest_renewal ~= nil and second_safest_renewal.id == "renewal-later-slack",
	"remaining lease renewal became unreachable after the most urgent renewal completed")
assert(renewal_deadlines:MarkCompleted(second_safest_renewal.id, "renewed"))

-- One owner/claim cannot hold more than one active renewal, even if its
-- general work concurrency limit is larger.
local renewal_cap = new_scheduler()
local renewal_policy = renewal_cap:Stats().policy
assert(renewal_cap:SetPolicy({
	revision = renewal_policy.revision + 1,
	max_per_owner_in_flight = 4,
}), "renewal cap policy was rejected")
enqueue(renewal_cap, { id = "renewal-a", owner_id = "one-claim", lane = "lease_renewal", work_class = "lease_renewal" })
enqueue(renewal_cap, { id = "renewal-b", owner_id = "one-claim", lane = "lease_renewal", work_class = "lease_renewal" })
local active_renewal = renewal_cap:TakeNext(true)
assert(active_renewal ~= nil and active_renewal.id == "renewal-a", "first renewal was not selected")
assert(renewal_cap:TakeNext(true) == nil, "a second renewal started concurrently for the same owner")
assert(renewal_cap:MarkCompleted(active_renewal.id, "renewed"))
local next_renewal = renewal_cap:TakeNext(true)
assert(next_renewal ~= nil and next_renewal.id == "renewal-b", "second renewal did not proceed after the first completed")
assert(renewal_cap:MarkCompleted(next_renewal.id, "renewed"))

-- Deadline selection must not indefinitely starve aging best-effort work
-- while newer critical work is continuously admitted.
local deadline_fairness = new_scheduler()
local deadline_fairness_policy = deadline_fairness:Stats().policy
assert(deadline_fairness:SetPolicy({
	revision = deadline_fairness_policy.revision + 1,
	algorithm = "deadline",
	urgent_deadline_burst = 2,
}), "deadline fairness policy was rejected")
enqueue(deadline_fairness, {
	id = "aging-best-effort",
	owner_id = "aging-owner",
	lane = "normal",
	work_class = "maintenance",
	service_class = "best_effort",
})
for index = 1, 4 do
	enqueue(deadline_fairness, {
		id = "critical-stream-" .. tostring(index),
		owner_id = "critical-owner",
		lane = "normal",
		work_class = "profile",
		service_class = "critical",
	})
end
local best_effort_selected_at = nil
for index = 1, 100 do
	local selected = deadline_fairness:TakeNext()
	assert(selected ~= nil, "deadline fairness workload ran out of ready work")
	if selected.id == "aging-best-effort" then
		best_effort_selected_at = index
		assert(deadline_fairness:MarkCompleted(selected.id, "committed"))
		break
	end
	assert(selected.service_class == "critical", "unexpected class selected before best-effort service")
	assert(deadline_fairness:MarkCompleted(selected.id, "committed"))
	now_ms += 1000
	enqueue(deadline_fairness, {
		id = "critical-stream-refill-" .. tostring(index),
		owner_id = "critical-owner",
		lane = "normal",
		work_class = "profile",
		service_class = "critical",
	})
end
assert(best_effort_selected_at ~= nil and best_effort_selected_at <= 24,
	"deadline selection starved old best-effort work under a continuous critical stream")

-- Shadow comparison is read-only; real selection remains authoritative.
local shadow = new_scheduler()
local shadow_policy = shadow:Stats().policy
assert(shadow:SetPolicy({
	revision = shadow_policy.revision + 1,
	algorithm = "drr",
	shadow_algorithm = "fifo",
	shadow_enabled = true,
	shadow_sample_rate = 1,
}), "valid shadow policy was rejected")
enqueue(shadow, { id = "oldest", owner_id = "shadow-owner", work_class = "maintenance", lane = "normal" })
now_ms += 1
enqueue(shadow, { id = "deadline-first", owner_id = "shadow-owner", work_class = "maintenance", lane = "normal", deadline_ms = now_ms + 1 })
local before_shadow = shadow:Stats().queue_items
local comparison = shadow:ShadowDecision()
assert(comparison.candidate_count == 2 and comparison.same_choice == false, "shadow policy did not compare choices")
assert(shadow:Stats().queue_items == before_shadow, "shadow selector mutated the real queue")
local real_choice, real_status = shadow:TakeNext()
assert(real_choice ~= nil and real_status == "success", "real selector failed after shadow sampling")
assert(shadow:MarkCompleted(real_choice.id, "committed"))
assert(shadow:Stats().stats.shadow_samples >= 1, "shadow sample metric was not recorded")

-- Shadow decisions must evaluate batchable items using a detached state snapshot.
local shadow_batch = new_scheduler()
local shadow_batch_policy = shadow_batch:Stats().policy
assert(shadow_batch:SetPolicy({
	revision = shadow_batch_policy.revision + 1,
	algorithm = "drr",
	shadow_algorithm = "fifo",
	shadow_enabled = true,
	shadow_sample_rate = 1,
}), "batch shadow policy was rejected")
enqueue(shadow_batch, {
	id = "shadow-batch-candidate",
	owner_id = "shadow-batch-owner",
	lane = "normal",
	work_class = "outbox_dispatch",
	operation_class = "outbox_dispatch",
	batchable = true,
	batch_size = 4,
	batch_backlog = 4,
})
local shadow_batch_queue_before = shadow_batch:Stats().queue_items
local shadow_batch_decision = shadow_batch:ShadowDecision()
assert(shadow_batch_decision.candidate_count == 1,
	"shadow selector did not inspect the batchable candidate")
assert(shadow_batch:Stats().queue_items == shadow_batch_queue_before,
	"batch shadow sampling mutated the actual queue")
take(shadow_batch, "shadow-batch-candidate")

-- Shadow priority inheritance must operate on the same cloned objects in queue and known.
local shadow_inheritance = new_scheduler()
local shadow_prerequisite_due = now_ms + 50
enqueue(shadow_inheritance, {
	id = "shadow-delayed-prerequisite",
	owner_id = "shadow-inheritance-owner",
	lane = "background",
	due_at_ms = shadow_prerequisite_due,
})
enqueue(shadow_inheritance, {
	id = "shadow-ready-ordinary",
	owner_id = "shadow-ordinary-owner",
	lane = "normal",
})
enqueue(shadow_inheritance, {
	id = "shadow-high-dependent",
	owner_id = "shadow-dependent-owner",
	lane = "high",
	dependencies = { "shadow-delayed-prerequisite" },
})
assert(shadow_inheritance.known["shadow-delayed-prerequisite"].inherited_lane == nil,
	"future prerequisite was promoted before it became eligible")
now_ms = shadow_prerequisite_due
local inherited_recommendation = shadow_inheritance:ShadowNext("deadline")
assert(inherited_recommendation ~= nil and inherited_recommendation.id == "shadow-delayed-prerequisite",
	"shadow selector failed to apply priority inheritance when a delayed prerequisite became ready")
assert(shadow_inheritance.known["shadow-delayed-prerequisite"].inherited_lane == nil,
	"shadow priority inheritance mutated the live prerequisite state")
assert(shadow_inheritance:Stats().queue_items == 3,
	"shadow priority inheritance altered the live queue")

-- Retry rescheduling preserves the logical ID and cannot run before its due time.
local retry_queue = new_scheduler()
enqueue(retry_queue, { id = "stable-retry-id", owner_id = "retry-owner", lane = "normal", work_class = "outbox" })
local retry_first, retry_status = retry_queue:TakeNext()
assert(retry_first ~= nil and retry_status == "success", "retry fixture was not selectable")
local requeued, requeue_error, retry_due = retry_queue:Reschedule(retry_first.id, now_ms + 50)
assert(requeued, "same-ID retry was not requeued: " .. tostring(requeue_error))
assert(retry_queue:NextQueuedDueAt() == retry_due,
	"queued due-time heap retained the prior deadline after same-ID reschedule")
assert(retry_queue:Stats().queue_items == 1, "retry changed bounded queue accounting")
assert(retry_queue:TakeNext() == nil, "retry became eligible before its due time")
now_ms = retry_due
local retry_second, retry_second_status = retry_queue:TakeNext()
assert(retry_second ~= nil and retry_second_status == "success" and retry_second.id == retry_first.id and retry_second.is_retry,
	"retry did not preserve its ID and retry marker")
assert(retry_queue:MarkCompleted(retry_second.id, "committed"), "retry did not release scheduler state")
assert(next(retry_queue:Stats().scheduler.active_by_owner) == nil, "completed owner state leaked")

-- Explicit throttled retries respect retry_after_ms, use the class-specific backoff,
-- and report attempt classes without retrying an uncertain outcome.
local typed_retry_governor = new_scheduler()
local typed_retry_dispatcher = Scheduler.new_dispatcher(typed_retry_governor, {
	now_ms = function() return now_ms end,
})
local typed_retry_attempts, typed_retry_completion = 0, nil
local typed_retry_start = now_ms
local typed_retry_job = typed_retry_dispatcher:Schedule(
	"typed-retry-owner", "throttled-safe-operation", function()
		typed_retry_attempts += 1
		if typed_retry_attempts == 1 then
			return { code = "retryable", retry_class = "throttled", retry_after_ms = 400 }
		end
		return { code = "committed" }
	end,
	{
		work_class = "maintenance",
		operation_class = "tracing",
		read_units = 0,
		write_units = 0,
		estimated_bytes = 1024,
		handler_slots = 1,
		mutating = false,
		max_retries = 1,
		retry_delay_ms = 50,
		retry_jitter_percent = 0,
		on_complete = function(result) typed_retry_completion = result end,
	}
)
assert(typed_retry_job.code == "accepted", "throttled retry fixture was rejected")
for _ = 1, 100 do
	if typed_retry_dispatcher:Stats().retries >= 1 then break end
	task.wait(0.001)
end
assert(typed_retry_dispatcher:Stats().retries == 1, "throttled result did not enter the bounded retry queue")
local typed_retry_due = typed_retry_governor:Stats().scheduler.next_due_at_ms
assert(typed_retry_due ~= nil and typed_retry_due >= typed_retry_start + 400,
	"retry ignored the server/request retry-after delay")
now_ms = typed_retry_due + 1
typed_retry_dispatcher:Kick()
for _ = 1, 100 do
	if typed_retry_completion ~= nil then break end
	task.wait(0.001)
end
assert(typed_retry_attempts == 2 and type(typed_retry_completion) == "table"
	and typed_retry_completion.code == "committed",
	"typed throttled retry did not resume after the due boundary")
assert(typed_retry_dispatcher:Stats().outcome_classes.throttled >= 1
	and typed_retry_dispatcher:Stats().outcome_classes.success >= 1,
	"typed retry outcomes were not counted")
typed_retry_dispatcher:Close()

-- A contradictory permanent/unknown retry class is terminal and must not replay.
local unsafe_retry_governor = new_scheduler()
local unsafe_retry_dispatcher = Scheduler.new_dispatcher(unsafe_retry_governor, {
	now_ms = function() return now_ms end,
})
local unsafe_retry_attempts, unsafe_retry_completion = 0, nil
local unsafe_retry_job = unsafe_retry_dispatcher:Schedule(
	"unsafe-retry-owner", "permanent-outcome", function()
		unsafe_retry_attempts += 1
		return { code = "retryable", retry_class = "permanent" }
	end,
	{
		work_class = "maintenance",
		operation_class = "tracing",
		read_units = 0,
		write_units = 0,
		estimated_bytes = 1024,
		handler_slots = 1,
		mutating = false,
		max_retries = 3,
		on_complete = function(result) unsafe_retry_completion = result end,
	}
)
assert(unsafe_retry_job.code == "accepted", "permanent class fixture was rejected")
for _ = 1, 100 do
	if unsafe_retry_completion ~= nil then break end
	task.wait(0.001)
end
assert(unsafe_retry_attempts == 1 and type(unsafe_retry_completion) == "table"
	and unsafe_retry_completion.code == "retry_rejected",
	"permanent-class work was blindly replayed")
assert(unsafe_retry_dispatcher:Stats().outcome_classes.permanent >= 1,
	"permanent outcome class was not measured")
unsafe_retry_dispatcher:Close()

end

do
-- A high-priority workflow may temporarily raise a ready prerequisite's urgency,
-- but cannot change the prerequisite's original lane or business identity.
local inheritance = new_scheduler()
enqueue(inheritance, { id = "ready-prerequisite", owner_id = "workflow-owner", work_class = "saga", lane = "background" })
local inheritance_policy = inheritance:Stats().policy
enqueue(inheritance, { id = "urgent-dependent", owner_id = "workflow-owner", work_class = "saga", lane = "high", dependencies = { "ready-prerequisite" } })
local inherited, inherited_status = inheritance:TakeNext()
assert(inherited ~= nil and inherited_status == "success" and inherited.id == "ready-prerequisite",
	"dependency inheritance selected downstream work before its prerequisite")
assert(inherited.lane == "background" and inherited.inherited_lane == "normal",
	"priority inheritance changed durable lane or failed to boost scheduling lane")
assert(inherited.inherited_until_ms <= now_ms + inheritance_policy.priority_inheritance_max_ms,
	"priority inheritance exceeded its configured lifetime")
assert(inheritance:MarkCompleted(inherited.id, "committed"))
take(inheritance, "urgent-dependent")

-- Cancelling a dependent must clear inheritance even if its prerequisite is in flight.
local cancelled_inheritance = new_scheduler()
enqueue(cancelled_inheritance, {
	id = "inflight-inherited-prerequisite",
	owner_id = "cancelled-workflow-owner",
	work_class = "saga",
	lane = "background",
})
enqueue(cancelled_inheritance, {
	id = "cancelled-high-dependent",
	owner_id = "cancelled-workflow-owner",
	work_class = "saga",
	lane = "high",
	dependencies = { "inflight-inherited-prerequisite" },
})
local running_prerequisite, running_status = cancelled_inheritance:TakeNext()
assert(running_prerequisite ~= nil and running_status == "success"
	and running_prerequisite.id == "inflight-inherited-prerequisite"
	and running_prerequisite.inherited_lane == "normal",
	"inherited prerequisite was not dispatched before dependent cancellation")
local cancelled_dependent, cancel_error = cancelled_inheritance:CancelQueued("cancelled-high-dependent")
assert(cancelled_dependent ~= nil and cancel_error == nil, "queued dependent could not be cancelled")
assert(cancelled_inheritance:MarkCompleted("cancelled-high-dependent", "cancelled"),
	"cancelled dependent did not terminalize")
assert(cancelled_inheritance.known["inflight-inherited-prerequisite"].inherited_lane == nil,
	"cancelling a dependent left inherited urgency on its in-flight prerequisite")
assert(cancelled_inheritance.known["inflight-inherited-prerequisite"].inherited_from == nil,
	"cancelling a dependent left a stale inheritance source on its prerequisite")
assert(cancelled_inheritance:MarkCompleted("inflight-inherited-prerequisite", "retryable"),
	"in-flight prerequisite could not release after dependent cancellation")

-- Priority inheritance must be reevaluated when a prerequisite becomes ready later.
local delayed_inheritance = new_scheduler()
local prerequisite_ready_at = now_ms + 100
enqueue(delayed_inheritance, {
	id = "delayed-prerequisite",
	owner_id = "delayed-workflow-owner",
	work_class = "saga",
	lane = "background",
	available_at_ms = prerequisite_ready_at,
})
enqueue(delayed_inheritance, {
	id = "delayed-urgent-dependent",
	owner_id = "delayed-workflow-owner",
	work_class = "saga",
	lane = "high",
	dependencies = { "delayed-prerequisite" },
})
assert(delayed_inheritance:TakeNext() == nil,
	"delayed prerequisite started before its availability time")
now_ms = prerequisite_ready_at
local delayed_prerequisite, delayed_status = delayed_inheritance:TakeNext()
assert(delayed_prerequisite ~= nil and delayed_status == "success"
	and delayed_prerequisite.id == "delayed-prerequisite"
	and delayed_prerequisite.inherited_lane == "normal",
	"priority inheritance was not applied when the prerequisite became ready")
assert(delayed_inheritance:MarkCompleted(delayed_prerequisite.id, "committed"))
take(delayed_inheritance, "delayed-urgent-dependent")

-- Urgent-deadline selection is bounded so deadlines do not starve older lane work.
local urgent = new_scheduler()
local urgent_policy = urgent:Stats().policy
assert(urgent:SetPolicy({ revision = urgent_policy.revision + 1, urgent_deadline_burst = 2 }), "urgent-burst policy was rejected")
enqueue(urgent, { id = "oldest-urgent-lane", owner_id = "urgent-owner", work_class = "interactive", lane = "normal", deadline_ms = now_ms + 4500 })
now_ms += 1
enqueue(urgent, { id = "near-deadline-1", owner_id = "urgent-owner", work_class = "interactive", lane = "normal", deadline_ms = now_ms + 300 })
now_ms += 1
enqueue(urgent, { id = "near-deadline-2", owner_id = "urgent-owner", work_class = "interactive", lane = "normal", deadline_ms = now_ms + 200 })
now_ms += 1
enqueue(urgent, { id = "near-deadline-3", owner_id = "urgent-owner", work_class = "interactive", lane = "normal", deadline_ms = now_ms + 100 })
take(urgent, "near-deadline-3")
take(urgent, "near-deadline-2")
take(urgent, "oldest-urgent-lane")
take(urgent, "near-deadline-1")

-- A strict reserved slot remains unused by normal work and remains available to
-- Deadline-preferred algorithms must not monopolize service after the urgent burst.
for _, algorithm in ipairs({"weighted", "deadline"}) do
	local bounded_urgent = new_scheduler()
	local bounded_policy = bounded_urgent:Stats().policy
	assert(bounded_urgent:SetPolicy({
		revision = bounded_policy.revision + 1,
		algorithm = algorithm,
		urgent_deadline_burst = 2,
	}), algorithm .. " urgent-burst policy was rejected")
	enqueue(bounded_urgent, {
		id = algorithm .. "-oldest",
		owner_id = algorithm .. "-owner",
		lane = "normal",
		deadline_ms = now_ms + 4500,
	})
	enqueue(bounded_urgent, {
		id = algorithm .. "-tight-1",
		owner_id = algorithm .. "-owner",
		lane = "normal",
		deadline_ms = now_ms + 300,
	})
	enqueue(bounded_urgent, {
		id = algorithm .. "-tight-2",
		owner_id = algorithm .. "-owner",
		lane = "normal",
		deadline_ms = now_ms + 200,
	})
	enqueue(bounded_urgent, {
		id = algorithm .. "-tight-3",
		owner_id = algorithm .. "-owner",
		lane = "normal",
		deadline_ms = now_ms + 100,
	})
	enqueue(bounded_urgent, {
		id = algorithm .. "-tight-4",
		owner_id = algorithm .. "-owner",
		lane = "normal",
		deadline_ms = now_ms + 50,
	})
	take(bounded_urgent, algorithm .. "-tight-4")
	take(bounded_urgent, algorithm .. "-tight-3")
	take(bounded_urgent, algorithm .. "-oldest")
	take(bounded_urgent, algorithm .. "-tight-2")
end

-- a lease renewal even while a normal callback is yielding.
local shared = new_scheduler()
local shared_policy = shared:Stats().policy
assert(shared:SetPolicy({
	revision = shared_policy.revision + 1,
	max_scheduled_in_flight = 2,
	scheduler_critical_reserve = 1,
	max_per_owner_in_flight = 2,
}), "reserved dispatcher policy failed")
local dispatcher = Scheduler.new_dispatcher(shared, { now_ms = function() return now_ms end })
local slow_started, slow_finished = false, false
local renewal_finished, blocked_normal_finished = false, false
local slow_job = dispatcher:Schedule("dispatch-owner", "slow-yielding-step", function()
	slow_started = true
	task.wait(0.08)
	slow_finished = true
	return { code = "committed" }
end, { lane = "normal" })
assert(slow_job.code == "accepted", "yielding callback was not accepted")
for _ = 1, 100 do if slow_started then break end; task.wait(0.001) end
assert(slow_started, "dispatcher did not start the first yielding callback")
local blocked_normal = dispatcher:Schedule("dispatch-owner", "must-not-use-reserve", function()
	blocked_normal_finished = true
	return { code = "committed" }
end, { lane = "normal" })
assert(blocked_normal.code == "accepted", "bounded normal callback was rejected")
task.wait(0.015)
assert(not blocked_normal_finished, "ordinary work consumed the reserved lease-renewal slot")
local renewal_job = dispatcher:Schedule("dispatch-owner", "reserved-lease-renewal", function()
	renewal_finished = not slow_finished
	return { code = "renewed" }
end, {
	lane = "lease_renewal", service_class = "critical", work_class = "lease_renewal",
	operation_class = "lease_renewal", deadline_ms = now_ms + 5000,
})
assert(renewal_job.code == "accepted", "lease-renewal lane rejected work")
for _ = 1, 100 do if renewal_finished then break end; task.wait(0.001) end
assert(renewal_finished, "reserved lease renewal waited behind a yielding normal callback")
assert(not blocked_normal_finished, "normal work took the reserve after the renewal finished")
for _ = 1, 150 do if slow_finished and blocked_normal_finished then break end; task.wait(0.002) end
assert(slow_finished and blocked_normal_finished, "queued normal work did not run after capacity became available")
assert(dispatcher:Stats().max_in_flight == 2, "reserved dispatcher exceeded its bounded concurrency")

-- Non-reserved concurrency still allows two normal callbacks to overlap when
-- policy explicitly permits two normal slots plus one reserved slot.
local parallel_governor = new_scheduler()
local parallel_policy = parallel_governor:Stats().policy
assert(parallel_governor:SetPolicy({
	revision = parallel_policy.revision + 1,
	max_scheduled_in_flight = 3,
	scheduler_critical_reserve = 1,
	max_per_owner_in_flight = 3,
}), "parallel dispatcher policy failed")
local parallel_dispatcher = Scheduler.new_dispatcher(parallel_governor, { now_ms = function() return now_ms end })
local first_normal_started, first_normal_finished = false, false
local second_normal_started, overlapped = false, false
local first_normal = parallel_dispatcher:Schedule("parallel-owner", "normal-one", function()
	first_normal_started = true
	task.wait(0.06)
	first_normal_finished = true
	return { code = "committed" }
end, { lane = "normal" })
assert(first_normal.code == "accepted")
for _ = 1, 100 do if first_normal_started then break end; task.wait(0.001) end
assert(first_normal_started, "first parallel normal callback did not start")
local second_normal = parallel_dispatcher:Schedule("parallel-owner", "normal-two", function()
	second_normal_started = true
	overlapped = not first_normal_finished
	return { code = "committed" }
end, { lane = "normal" })
assert(second_normal.code == "accepted")
for _ = 1, 100 do if second_normal_started and first_normal_finished then break end; task.wait(0.002) end
assert(second_normal_started and first_normal_finished and overlapped, "permitted normal concurrency did not overlap")
assert(parallel_dispatcher:Stats().max_in_flight >= 2, "dispatcher did not report bounded concurrency")
parallel_dispatcher:Close()
local callback_attempts = 0
local retry_done = false
local retry_job = dispatcher:Schedule("retry-owner", "retryable-callback", function()
	callback_attempts += 1
	return if callback_attempts == 1 then { code = "retryable" } else { code = "committed" }
end, {
	lane = "normal", work_class = "maintenance", max_retries = 2,
	retry_delay_ms = 10, retry_jitter_percent = 0,
	on_complete = function(result) retry_done = result.code == "committed" end,
})
assert(retry_job.code == "accepted", "retry callback was not accepted")
for _ = 1, 100 do
	if callback_attempts >= 1 then break end
	task.wait(0.001)
end
assert(callback_attempts == 1, "explicit retryable callback did not run initially")
-- This test injects a mock clock. Wall-clock delay alone must not advance its
-- retry deadline; advance the mock clock explicitly and wake the dispatcher.
task.wait(0.02)
assert(callback_attempts == 1, "retry ran before the mock clock reached retry_due_at_ms")
now_ms += 11
dispatcher:Kick()
for _ = 1, 200 do if retry_done then break end; task.wait(0.002) end
assert(retry_done and callback_attempts == 2, "explicit retryable result did not retry exactly once")

-- Retry-token exhaustion must defer without executing or busy-spinning a retry.
local token_governor = new_scheduler()
local token_policy = token_governor:Stats().policy
assert(token_governor:SetPolicy({
	revision = token_policy.revision + 1,
	retry_token_capacity = 1,
	retry_tokens_per_second = 0,
}), "retry-token exhaustion policy was rejected")
local consumed_token = token_governor:AcquireRetryToken("maintenance")
assert(consumed_token, "retry-token fixture could not consume its only token")
local token_dispatcher = Scheduler.new_dispatcher(token_governor, { now_ms = function() return now_ms end })
local gated_attempts, gated_done = 0, false
local gated_job = token_dispatcher:Schedule("retry-gate-owner", "retry-token-gate", function()
	gated_attempts += 1
	return if gated_attempts == 1 then { code = "retryable" } else { code = "committed" }
end, {
	lane = "normal", work_class = "maintenance", max_retries = 2,
	retry_delay_ms = 10, retry_jitter_percent = 0,
	on_complete = function(result) gated_done = result.code == "committed" end,
})
assert(gated_job.code == "accepted", "retry-token test work was not accepted")
for _ = 1, 100 do if gated_attempts >= 1 then break end; task.wait(0.001) end
assert(gated_attempts == 1, "initial callback did not execute exactly once")
task.wait(0.03)
assert(gated_attempts == 1, "retry executed without a retry token")
assert(token_governor:Stats().queue_items == 1, "token-deferred retry was removed from the queue")
local depleted_policy = token_governor:Stats().policy
assert(token_governor:SetPolicy({
	revision = depleted_policy.revision + 1,
	retry_tokens_per_second = 128,
}), "retry-token refill policy was rejected")
now_ms += 60001
token_dispatcher:Kick()
for _ = 1, 100 do if gated_done then break end; task.wait(0.002) end
assert(gated_done and gated_attempts == 2, "deferred retry did not run after token admission")
token_dispatcher:Close()

local thrown_attempts = 0
local thrown_done = false
local thrown_job = dispatcher:Schedule("error-owner", "unknown-callback", function()
	thrown_attempts += 1
	error("ambiguous external effect")
end, {
	lane = "normal", max_retries = 4,
	on_complete = function(result) thrown_done = result.code == "unknown" end,
})
assert(thrown_job.code == "accepted", "throwing callback was not accepted")
for _ = 1, 100 do if thrown_done then break end; task.wait(0.002) end
assert(thrown_done and thrown_attempts == 1, "unknown callback outcome was automatically replayed")

-- Batching delay is opt-in, bounded by policy, and never merges distinct callbacks.
local batch_governor = new_scheduler()
local batch_policy = batch_governor:Stats().policy
assert(batch_governor:SetPolicy({ revision = batch_policy.revision + 1, batch_window_ms = 10 }), "batch window policy failed")
local batch_dispatcher = Scheduler.new_dispatcher(batch_governor, { now_ms = function() return now_ms end })
local batched_calls = 0
local batch_job = batch_dispatcher:Schedule("batch-owner", "explicit-batch-callback", function()
	batched_calls += 1
	return { code = "committed" }
end, { batchable = true, batch_window_ms = 10, work_class = "outbox_dispatch" })
assert(batch_job.code == "accepted" and batch_job.due_at_ms >= now_ms + 10, "opt-in batch window was not respected")
assert(batched_calls == 0, "batchable callback bypassed its configured formation window")
now_ms += 10
batch_dispatcher:Kick()
for _ = 1, 100 do if batched_calls == 1 then break end; task.wait(0.001) end
assert(batched_calls == 1, "due batch callback did not execute")
dispatcher:Close()
batch_dispatcher:Close()

-- Batch sizing is applied to the explicitly batchable callback itself; it does not
-- merge independent business callbacks. High service latency should collapse to one.
local adaptive_batch_governor = new_scheduler()
local adaptive_batch_policy = adaptive_batch_governor:Stats().policy
assert(adaptive_batch_governor:SetPolicy({
	revision = adaptive_batch_policy.revision + 1,
	max_batch = 8,
	batch_window_ms = 10,
	batch_latency_ceiling_ms = 40,
}), "adaptive batch policy was rejected")
adaptive_batch_governor:Observe("outbox_dispatch", true, 100)
local adaptive_batch_dispatcher = Scheduler.new_dispatcher(adaptive_batch_governor, {
	now_ms = function() return now_ms end,
})
local chosen_batch_size = nil
local adaptive_batch_job = adaptive_batch_dispatcher:Schedule(
	"adaptive-batch-owner", "bounded-outbox-batch", function(batch_size)
		chosen_batch_size = batch_size
		return { code = "committed" }
	end,
	{
		batchable = true,
		batch_size = 8,
		batch_backlog = 8,
		batch_window_ms = 0,
		operation_class = "outbox_dispatch",
		work_class = "outbox_dispatch",
		read_units = 1,
		write_units = 1,
		estimated_bytes = 16384,
		handler_slots = 1,
	}
)
assert(adaptive_batch_job.code == "accepted", "adaptive batch callback was rejected")
for _ = 1, 100 do if chosen_batch_size ~= nil then break end; task.wait(0.001) end
assert(chosen_batch_size == 1,
	"batchable callback did not receive the latency-capped batch size")
assert(adaptive_batch_dispatcher:Stats().batch_calls == 1,
	"adaptive batch invocation was not measured")
assert(adaptive_batch_dispatcher:Stats().max_batch_size == 1,
	"adaptive batch metrics did not record the bounded selected size")
-- The service-latency EWMA needs repeated healthy observations before a
-- previously slow lane should permit larger batches again.
for _ = 1, 8 do adaptive_batch_governor:Observe("outbox_dispatch", true, 1) end
local backlog_limited_size = nil
local backlog_limited_job = adaptive_batch_dispatcher:Schedule(
	"adaptive-batch-owner", "backlog-limited-batch", function(batch_size)
		backlog_limited_size = batch_size
		return { code = "processed", processed_count = batch_size }
	end,
	{
		batchable = true,
		batch_size = 8,
		batch_backlog = 3,
		batch_window_ms = 0,
		operation_class = "outbox_dispatch",
		work_class = "outbox_dispatch",
		read_units = 1,
		write_units = 1,
		estimated_bytes = 16384,
		handler_slots = 1,
	}
)
assert(backlog_limited_job.code == "accepted", "backlog-limited batch callback was rejected")
for _ = 1, 100 do if backlog_limited_size ~= nil then break end; task.wait(0.001) end
assert(backlog_limited_size == 3, "batch selector exceeded the declared eligible backlog")
assert(adaptive_batch_dispatcher:Stats().batch_calls == 2,
	"adaptive batch metrics omitted the backlog-limited callback")
local adaptive_batch_snapshot = adaptive_batch_dispatcher:Stats()
assert(adaptive_batch_snapshot.batch_items_requested == 4,
	"adaptive batch metrics reported the wrong selected item total")
assert(adaptive_batch_snapshot.batch_items_processed == 3,
	"adaptive batch metrics did not account for the actual processed item count")
assert(adaptive_batch_snapshot.batch_utilization.samples == 1
	and adaptive_batch_snapshot.batch_utilization.average == 1
	and adaptive_batch_snapshot.batch_utilization.p95 == 1,
	"batch utilization percentiles did not represent the completed backlog-limited batch")
adaptive_batch_dispatcher:Close()

end

-- Operation admission must cap estimated request work, not just callback count.
do
local admission_governor = new_scheduler()
local admission_policy = admission_governor:Stats().policy
assert(admission_governor:SetPolicy({
	revision = admission_policy.revision + 1,
	max_in_flight = 1,
	critical_reserve = 0,
	max_scheduled_in_flight = 2,
	scheduler_critical_reserve = 0,
	max_per_owner_in_flight = 2,
}), "request admission policy was rejected")
local admission_dispatcher = Scheduler.new_dispatcher(admission_governor, {
	now_ms = function() return now_ms end,
})
local first_admission_finished = false
local second_admission_started = false
local admission_overlapped = false
local first_admission_job = admission_dispatcher:Schedule(
	"admission-owner", "first-cost-unit", function()
		task.wait(0.03)
		first_admission_finished = true
		return { code = "committed" }
	end,
	{ operation_class = "tracing", work_class = "interactive" }
)
assert(first_admission_job.code == "accepted", "first request-admission job was rejected")
local second_admission_job = admission_dispatcher:Schedule(
	"admission-owner", "second-cost-unit", function()
		second_admission_started = true
		admission_overlapped = not first_admission_finished
		return { code = "committed" }
	end,
	{ operation_class = "tracing", work_class = "maintenance" }
)
assert(second_admission_job.code == "accepted", "second request-admission job was rejected")
for _ = 1, 200 do
	if second_admission_started then break end
	task.wait(0.002)
end
assert(second_admission_started and first_admission_finished,
	"request admission left eligible work stuck after capacity was released")
assert(not admission_overlapped,
	"estimated request concurrency exceeded the governor's max_in_flight budget")
assert(admission_governor:Stats().in_flight == 0,
	"request admission leaked its in-flight reservation")
admission_dispatcher:Close()

-- A job whose scalar cost exceeds its work-class cap must terminate instead of
-- remaining queued forever as if capacity might eventually free up.
local impossible_governor = new_scheduler()
local impossible_dispatcher = Scheduler.new_dispatcher(impossible_governor, {
	now_ms = function() return now_ms end,
})
local impossible_callback_ran, impossible_completion = false, nil
local impossible_job = impossible_dispatcher:Schedule(
	"impossible-cost-owner", "over-class-cap", function()
		impossible_callback_ran = true
		return { code = "committed" }
	end,
	{
		operation_class = "tracing",
		work_class = "maintenance",
		cost = 9,
		mutating = false,
		on_complete = function(result) impossible_completion = result end,
	}
)
assert(impossible_job.code == "accepted", "impossible-cost fixture did not reach scheduler admission")
for _ = 1, 100 do if impossible_completion ~= nil then break end; task.wait(0.001) end
assert(not impossible_callback_ran, "job above its work-class cap was executed")
assert(type(impossible_completion) == "table" and impossible_completion.code == "capacity",
	"job above its work-class cap did not receive a terminal capacity result")
assert(impossible_governor:Stats().queue_items == 0,
	"impossible admission remained queued forever")
impossible_dispatcher:Close()

-- StandardRead and StandardWrite reservations are independent because UpdateAsync
-- consumes both request budgets while a read-only operation consumes only StandardRead.
local dimensions_governor = new_scheduler()
local dimensions_policy = dimensions_governor:Stats().policy
assert(dimensions_governor:SetPolicy({
	revision = dimensions_policy.revision + 1,
	max_in_flight = 16,
	critical_reserve = 0,
	max_read_units_in_flight = 2,
	max_write_units_in_flight = 1,
	read_critical_reserve = 0,
	write_critical_reserve = 0,
	max_estimated_bytes_in_flight = 65536,
	max_handler_slots_in_flight = 3,
	max_scheduled_in_flight = 3,
	scheduler_critical_reserve = 0,
	max_per_owner_in_flight = 3,
}), "multi-dimensional admission policy was rejected")
local dimensions_dispatcher = Scheduler.new_dispatcher(dimensions_governor, {
	now_ms = function() return now_ms end,
})
local first_update_started, first_update_finished = false, false
local queued_update_started, read_only_started = false, false
local second_write_overlapped = false
local first_update = dimensions_dispatcher:Schedule(
	"dimension-owner", "slow-update-async", function()
		first_update_started = true
		task.wait(0.06)
		first_update_finished = true
		return { code = "committed" }
	end,
	{ operation_class = "update_async", read_units = 1, write_units = 1, estimated_bytes = 8, handler_slots = 1 }
)
assert(first_update.code == "accepted", "dimension-limited UpdateAsync was rejected")
for _ = 1, 100 do if first_update_started then break end; task.wait(0.001) end
assert(first_update_started, "first UpdateAsync did not start")
local second_update = dimensions_dispatcher:Schedule(
	"dimension-owner", "queued-update-async", function()
		queued_update_started = true
		second_write_overlapped = not first_update_finished
		return { code = "committed" }
	end,
	{ operation_class = "update_async", read_units = 1, write_units = 1, estimated_bytes = 8, handler_slots = 1 }
)
local parallel_read = dimensions_dispatcher:Schedule(
	"dimension-owner", "read-during-update", function()
		read_only_started = true
		return { code = "committed" }
	end,
	{ operation_class = "read", read_units = 1, write_units = 0, estimated_bytes = 8, handler_slots = 1, mutating = false }
)
assert(second_update.code == "accepted" and parallel_read.code == "accepted",
	"dimension-limited jobs were rejected at enqueue")
for _ = 1, 100 do if read_only_started then break end; task.wait(0.001) end
assert(read_only_started, "StandardWrite saturation incorrectly blocked an independently admitted read")
assert(not queued_update_started, "two UpdateAsync operations shared one StandardWrite reservation")
for _ = 1, 150 do
	if queued_update_started and first_update_finished then break end
	task.wait(0.002)
end
assert(queued_update_started and first_update_finished and not second_write_overlapped,
	"deferred UpdateAsync did not start after the write reservation was released")
local dimension_snapshot = dimensions_governor:Stats()
assert(dimension_snapshot.read_units_in_flight == 0 and dimension_snapshot.write_units_in_flight == 0,
	"read/write request reservations leaked after callbacks completed")
assert(dimension_snapshot.estimated_bytes_in_flight == 0 and dimension_snapshot.handler_slots_in_flight == 0,
	"byte/handler reservations leaked after callbacks completed")
dimensions_dispatcher:Close()

end

-- The scheduler's degraded modes must apply to real callbacks, not only direct governor calls.
do
local read_only_governor = new_scheduler()
local read_only_policy = read_only_governor:Stats().policy
assert(read_only_governor:SetPolicy({
	revision = read_only_policy.revision + 1,
	mode = "read_only",
}), "read-only policy was rejected")
local read_only_dispatcher = Scheduler.new_dispatcher(read_only_governor, {
	now_ms = function() return now_ms end,
})
local mutating_callback_ran, mutating_completion = false, nil
local read_only_mutation = read_only_dispatcher:Schedule(
	"read-only-owner", "blocked-mutation", function()
		mutating_callback_ran = true
		return { code = "committed" }
	end,
	{
		operation_class = "tracing",
		work_class = "maintenance",
		on_complete = function(result) mutating_completion = result end,
	}
)
assert(read_only_mutation.code == "accepted", "read-only mutation fixture was not queued")
for _ = 1, 100 do
	if mutating_completion ~= nil then break end
	task.wait(0.001)
end
assert(type(mutating_completion) == "table" and mutating_completion.code == "read_only",
	"read-only policy did not return its typed terminal result")
assert(not mutating_callback_ran, "mutating work ran under read-only policy")
local read_only_read_ran = false
local read_only_read = read_only_dispatcher:Schedule(
	"read-only-owner", "allowed-read", function()
		read_only_read_ran = true
		return { code = "committed" }
	end,
	{ operation_class = "tracing", work_class = "maintenance", mutating = false }
)
assert(read_only_read.code == "accepted", "read-only work fixture was not queued")
for _ = 1, 100 do
	if read_only_read_ran then break end
	task.wait(0.001)
end
assert(read_only_read_ran, "explicitly non-mutating work was blocked in read-only mode")
assert(read_only_governor:Stats().stats.rejected >= 1, "read-only rejection was not measured")
read_only_dispatcher:Close()

-- Budget backpressure retains work and resumes after a fresh budget observation.
local budget_governor = new_scheduler()
budget_governor:Observe("tracing", true, 1, nil, 0)
local budget_dispatcher = Scheduler.new_dispatcher(budget_governor, {
	now_ms = function() return now_ms end,
})
local budget_callback_ran = false
local budget_job = budget_dispatcher:Schedule(
	"budget-owner", "budget-delayed-work", function()
		budget_callback_ran = true
		return { code = "committed" }
	end,
	{ operation_class = "tracing", work_class = "maintenance", mutating = false }
)
assert(budget_job.code == "accepted", "budget-delayed work was rejected before queueing")
assert(not budget_callback_ran, "work executed below the configured request-budget minimum")
assert(budget_governor:Stats().queue_items == 1, "budget-backpressured work was removed from the queue")
budget_governor:Observe("tracing", true, 1, nil, 3)
now_ms += 251
budget_dispatcher:Kick()
for _ = 1, 100 do
	if budget_callback_ran then break end
	task.wait(0.001)
end
assert(budget_callback_ran, "work did not resume after budget recovery")
assert(budget_governor:Stats().stats.throttled >= 1, "budget backpressure was not measured")
budget_dispatcher:Close()

-- The live governor consumes a fresh StandardRead/StandardWrite budget snapshot,
-- and critical persistence may use its explicit reserve while background reads defer.
local live_request_budget = 1
local live_budget_governor = Scheduler.new({
	now_ms = function() return now_ms end,
	get_request_budgets = function()
		return { read = live_request_budget, write = live_request_budget }
	end,
})
local live_budget_policy = live_budget_governor:Stats().policy
assert(live_budget_governor:SetPolicy({
	revision = live_budget_policy.revision + 1,
	minimum_budget = 2,
}), "live budget policy was rejected")
local live_budget_dispatcher = Scheduler.new_dispatcher(live_budget_governor, {
	now_ms = function() return now_ms end,
})
local deferred_read_ran, critical_renewal_ran = false, false
local live_deferred_read = live_budget_dispatcher:Schedule(
	"live-budget-owner", "budget-constrained-read", function()
		deferred_read_ran = true
		return { code = "committed" }
	end,
	{ operation_class = "read", work_class = "maintenance", read_units = 1, write_units = 0, mutating = false }
)
assert(live_deferred_read.code == "accepted", "budget-constrained read was rejected at enqueue")
assert(not deferred_read_ran, "noncritical read executed below the live StandardRead threshold")
assert(live_budget_governor:Stats().request_budgets.read == 1,
	"dispatcher did not publish the fresh StandardRead budget snapshot")
local live_critical_renewal = live_budget_dispatcher:Schedule(
	"live-budget-owner", "critical-lease-renewal", function()
		critical_renewal_ran = true
		return { code = "renewed" }
	end,
	{
		lane = "lease_renewal",
		service_class = "critical",
		work_class = "profile_release",
		operation_class = "lease_renewal",
	}
)
assert(live_critical_renewal.code == "accepted", "critical renewal was rejected at enqueue")
for _ = 1, 100 do if critical_renewal_ran then break end; task.wait(0.001) end
assert(critical_renewal_ran, "critical lease renewal could not use its protected admission path")
live_request_budget = 8
now_ms += 251
live_budget_dispatcher:Kick()
for _ = 1, 100 do if deferred_read_ran then break end; task.wait(0.001) end
assert(deferred_read_ran, "noncritical read did not resume after request budget recovery")
assert(live_budget_governor:Stats().request_budgets.read == 8,
	"dispatcher did not refresh request budget after the recovery observation")
live_budget_dispatcher:Close()

-- Closing a dispatcher drains callbacks and cancels its outstanding wake timer.
local closing_governor = new_scheduler()
local closing_dispatcher = Scheduler.new_dispatcher(closing_governor, {
	now_ms = function() return now_ms end,
})
local closing_callback_ran, closing_completion = false, nil
local schedule_during_close = nil
local closing_job = closing_dispatcher:Schedule(
	"closing-owner", "future-callback", function()
		closing_callback_ran = true
		return { code = "committed" }
	end,
	{
		lane = "background",
		due_at_ms = now_ms + 60000,
		on_complete = function(result)
			closing_completion = result
			schedule_during_close = closing_dispatcher:Schedule(
				"closing-owner", "work-created-by-close-callback", function()
					error("work was admitted while the dispatcher was closing")
				end
			)
		end,
	}
)
assert(closing_job.code == "accepted", "future close fixture was rejected")
closing_dispatcher:Close()
assert(not closing_callback_ran, "closing dispatcher executed a future callback")
assert(type(closing_completion) == "table" and closing_completion.code == "cancelled",
	"closing dispatcher did not provide the cancellation result")
assert(type(schedule_during_close) == "table" and schedule_during_close.code == "closed",
	"completion callback was able to add work during dispatcher close")
assert(closing_governor:Stats().queue_items == 0, "closing dispatcher retained queued work")
assert(closing_dispatcher:Stats().closed, "dispatcher close state was not published")

end

do
-- The main RecordStore module resolves the same scheduler through its
-- ModuleScript parent. Runtime scheduling remains opt-in.
local RecordStore = Shim.load()
local initial_snapshot = RecordStore.get_scheduler_snapshot()
assert(initial_snapshot.enabled == false, "advanced core scheduling must start disabled")
local disabled_job = RecordStore.schedule_work("integration-owner", "must-stay-disabled", function()
	error("scheduled callback ran while advanced scheduling was disabled")
end, { lane = "normal" })
assert(disabled_job.code == "disabled", "public scheduled work bypassed the opt-in gate")

-- Rollout is revisioned per server: requested opt-in must not activate a server
-- outside the canary cohort, and increasing the cohort must activate it immediately.
local initial_rollout = initial_snapshot.rollout
assert(type(initial_rollout) == "table", "scheduler snapshot omitted the rollout cohort")
assert(initial_rollout.percent == 100 and initial_rollout.revision >= 1,
	"default rollout must preserve explicit opt-in behavior")
local excluded_code, excluded_message = RecordStore.configure_scheduler_rollout({
	revision = initial_rollout.revision + 1,
	percent = 0,
	salt = "rollout-regression-wave",
})
assert(excluded_code == "success", "scheduler rejected a valid zero-percent rollout: " .. tostring(excluded_message))
local stale_rollout_code = RecordStore.configure_scheduler_rollout({
	revision = initial_rollout.revision,
	percent = 50,
	salt = "rollout-regression-wave",
})
assert(stale_rollout_code == "invalid", "stale rollout revision was accepted")
local invalid_percent_code = RecordStore.configure_scheduler_rollout({
	revision = initial_rollout.revision + 2,
	percent = 101,
	salt = "rollout-regression-wave",
})
assert(invalid_percent_code == "invalid", "out-of-range rollout percentage was accepted")
local invalid_salt_code = RecordStore.configure_scheduler_rollout({
	revision = initial_rollout.revision + 2,
	percent = 50,
	salt = string.rep("x", 129),
})
assert(invalid_salt_code == "invalid", "oversized rollout salt was accepted")
assert(RecordStore.set_scheduler_enabled(true), "scheduler enable request was rejected")
local excluded_snapshot = RecordStore.get_scheduler_snapshot()
assert(excluded_snapshot.rollout.cohort_bucket >= 0 and excluded_snapshot.rollout.cohort_bucket < 100,
	"server cohort bucket was outside the [0, 100) range")
assert(excluded_snapshot.rollout.cohort_included == false and excluded_snapshot.enabled == false,
	"zero-percent canary activated the new scheduler")
local stable_bucket = excluded_snapshot.rollout.cohort_bucket
assert(RecordStore.get_scheduler_snapshot().rollout.cohort_bucket == stable_bucket,
	"server cohort bucket was not stable across snapshot reads")
local restored_code, restored_message = RecordStore.configure_scheduler_rollout({
	revision = excluded_snapshot.rollout.revision + 1,
	percent = 100,
	salt = "rollout-regression-wave",
})
assert(restored_code == "success", "scheduler rejected a valid full rollout: " .. tostring(restored_message))
local full_rollout = RecordStore.get_scheduler_snapshot()
assert(full_rollout.rollout.cohort_included == true, "100-percent rollout excluded a server")
assert(full_rollout.enabled == true,
	"raising rollout percentage did not activate the already-opted-in cohort")
local configured, configure_message = RecordStore.configure_scheduler_policy({
	revision = initial_snapshot.policy.revision + 1,
	shadow_enabled = true,
	shadow_sample_rate = 1,
})
assert(configured == "success", "core scheduler rejected policy: " .. tostring(configure_message))
local enabled, enable_message = RecordStore.set_scheduler_enabled(true)
assert(enabled, "core scheduler did not enable: " .. tostring(enable_message))

local reserved_lane_callback_ran = false
local reserved_lane_job = RecordStore.schedule_work(
	"integration-owner",
	"public-reserved-renewal-lane",
	function()
		reserved_lane_callback_ran = true
		return { code = "renewed" }
	end,
	{ lane = "lease_renewal", service_class = "critical" }
)
assert(reserved_lane_job.code == "invalid",
	"public schedule_work API allowed application callbacks into the reserved renewal lane")
assert(not reserved_lane_callback_ran,
	"public reserved renewal callback ran despite being rejected")

local reserved_operation_callback_ran = false
local reserved_operation_job = RecordStore.schedule_work(
	"integration-owner",
	"public-reserved-renewal-operation",
	function()
		reserved_operation_callback_ran = true
		return { code = "renewed" }
	end,
	{ lane = "normal", operation_class = "lease_renewal" }
)
assert(reserved_operation_job.code == "invalid",
	"generic scheduled work was allowed to share the internal lease-renewal circuit")
assert(not reserved_operation_callback_ran,
	"generic reserved renewal operation callback ran despite being rejected")

local reserved_release_callback_ran = false
local reserved_release_job = RecordStore.schedule_work(
	"integration-owner",
	"public-reserved-profile-release-operation",
	function()
		reserved_release_callback_ran = true
		return { code = "released" }
	end,
	{ lane = "normal", operation_class = "profile_release" }
)
-- If this guard regresses, drain the mistakenly accepted callback before asserting so
-- the regression fails immediately rather than leaving background scheduler work alive.
RecordStore.set_scheduler_enabled(false)
for _ = 1, 200 do
	if RecordStore.get_scheduler_snapshot().dispatcher.in_flight == 0 then break end
	task.wait(0.001)
end
RecordStore.set_scheduler_enabled(true)
assert(reserved_release_job.code == "invalid",
	"generic scheduled work was allowed to share the internal profile-release circuit")
assert(not reserved_release_callback_ran,
	"generic reserved profile-release callback ran despite being rejected")


local function assert_reserved_work_class_rejected(work_class)
	local callback_ran = false
	local job = RecordStore.schedule_work(
		"integration-owner",
		"public-reserved-work-class-" .. work_class,
		function()
			callback_ran = true
			return { code = "success" }
		end,
		{ lane = "normal", work_class = work_class }
	)
	if job.code ~= "invalid" then
		RecordStore.set_scheduler_enabled(false)
		for _ = 1, 200 do
			if RecordStore.get_scheduler_snapshot().dispatcher.in_flight == 0 then break end
			task.wait(0.001)
		end
		RecordStore.set_scheduler_enabled(true)
	end
	assert(job.code == "invalid",
		"public schedule_work API accepted reserved work_class " .. work_class)
	assert(not callback_ran,
		"public scheduled callback ran with reserved work_class " .. work_class)
end

assert_reserved_work_class_rejected("lease_renewal")
assert_reserved_work_class_rejected("profile_release")

-- The public API must not let generic work claim the governor's critical reserve.
local privileged_service_class_callback_ran = false
local privileged_service_class_job = RecordStore.schedule_work(
	"integration-owner",
	"public-critical-service-class",
	function()
		privileged_service_class_callback_ran = true
		return { code = "success" }
	end,
	{ lane = "normal", work_class = "ordinary-work", service_class = "critical" }
)
if privileged_service_class_job.code ~= "invalid" then
	RecordStore.set_scheduler_enabled(false)
	for _ = 1, 200 do
		if RecordStore.get_scheduler_snapshot().dispatcher.in_flight == 0 then break end
		task.wait(0.001)
	end
	RecordStore.set_scheduler_enabled(true)
end
assert(privileged_service_class_job.code == "invalid",
	"public schedule_work allowed arbitrary work to claim critical service-class admission")
assert(not privileged_service_class_callback_ran,
	"public critical service-class callback ran despite being rejected")

local public_callback_ran = false
local public_job = RecordStore.schedule_work("integration-owner", "public-scheduler-api", function()
	public_callback_ran = true
	return { code = "success" }
end, { lane = "normal", work_class = "integration-test" })
assert(public_job.code == "accepted", "public schedule_work API rejected bounded work")
for _ = 1, 200 do
	if public_callback_ran then break end
	task.wait(0.001)
end
assert(public_callback_ran, "public scheduled callback did not run")
assert(RecordStore.get_scheduler_snapshot().dispatcher.completed >= 1,
	"public scheduler API did not publish completion metrics")

-- Public trace replay is isolated: it cannot mutate the live server queue.
local delayed_callback_ran = false
local delayed_job = RecordStore.schedule_work("integration-owner", "delayed-replay-safety", function()
	delayed_callback_ran = true
	return { code = "success" }
end, {
	lane = "normal",
	work_class = "integration-test",
	due_at_ms = os.clock() * 1000 + 40,
})
assert(delayed_job.code == "accepted", "delayed scheduler fixture was rejected")
local queue_before_replay = RecordStore.get_scheduler_snapshot().governor.queue_items
local replay_result = RecordStore.replay_scheduler_trace({
	{ kind = "enqueue", item = { id = "sandbox-trace-item", owner_id = "trace-owner", lane = "normal" } },
	{ kind = "take" },
})
assert(replay_result[1] == "sandbox-trace-item", "isolated trace replay returned the wrong decision")
assert(RecordStore.get_scheduler_snapshot().governor.queue_items == queue_before_replay,
	"trace replay mutated the live scheduler queue")
for _ = 1, 200 do
	if delayed_callback_ran then break end
	task.wait(0.001)
end
assert(delayed_callback_ran, "future-due live work was lost after isolated trace replay")

-- A dirty mock Record is autosaved through the selector when explicitly enabled.
local core_record = RecordStore.Mock.new("SchedulerRegression", "global", "scheduler-player", {
	schema_version = 1,
	autosave_interval = 0.05,
})
local open_code, open_message = core_record:Open({ coins = 0 })
assert(open_code == "created" or open_code == "loaded", tostring(open_message))
local update_code = core_record:Update(function(current)
	local changed = table.clone(current)
	changed.coins += 1
	return changed
end)
assert(update_code == "success", "mock Record update failed")
local saved = false
-- The RecordStore mock runs its background selector on a one-second cadence.
-- Allow multiple ticks instead of timing this integration assertion below one tick.
local save_deadline = os.clock() + 3
while not saved and os.clock() < save_deadline do
	local stats = core_record:Stats()
	if stats.dirty == 0 and stats.busy == 0 then saved = true; break end
	task.wait(0.002)
end
assert(saved, "core background autosave did not complete through the selector within three seconds")
local dispatch_snapshot = RecordStore.get_scheduler_snapshot().dispatcher
assert(dispatch_snapshot.accepted >= 3 and dispatch_snapshot.completed >= 3,
	"public, delayed, and core background work were not represented in scheduler metrics")
local closed_code = core_record:Close()
assert(closed_code == "closed", "scheduler regression fixture failed to close")

-- Disabling the scheduler immediately cancels queued future work and releases its callback.
local cancelled_callback_ran = false
local cancellation_result: any = nil
local future_kill_switch_job = RecordStore.schedule_work(
	"integration-owner",
	"future-work-cancelled-by-kill-switch",
	function()
		cancelled_callback_ran = true
		return { code = "success" }
	end,
	{
		lane = "normal",
		due_at_ms = os.clock() * 1000 + 60000,
		on_complete = function(result) cancellation_result = result end,
	}
)
assert(future_kill_switch_job.code == "accepted", "future kill-switch fixture was rejected")
assert(RecordStore.set_scheduler_enabled(false), "core scheduling kill switch failed")
assert(type(cancellation_result) == "table" and cancellation_result.code == "cancelled",
	"disabling the scheduler did not notify completion for queued work")
assert(RecordStore.get_scheduler_snapshot().governor.queue_items == 0,
	"disabling the scheduler left queued work retained")
assert(not cancelled_callback_ran, "future work executed after the scheduler kill switch")
assert(RecordStore.set_scheduler_enabled(true), "scheduler could not be re-enabled after a kill-switch drain")
assert(RecordStore.set_scheduler_enabled(false), "scheduler kill switch could not be re-applied")
local disabled_after_kill = RecordStore.schedule_work("integration-owner", "must-stay-disabled-after-kill", function()
	error("scheduled callback ran after the scheduler kill switch")
end, { lane = "normal" })
assert(disabled_after_kill.code == "disabled", "public scheduler API ignored the kill switch")

end

print("[PASS] RecordStore advanced scheduling unit and core integration regressions.")
Shim.close()

