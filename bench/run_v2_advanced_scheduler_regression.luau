--!nocheck
-- Deterministic public-surface coverage for V2 advanced scheduler behavior.
local Shim = require("./RobloxShim")
local RecordStore = Shim.load_isolated("v2-advanced-scheduler")
local MailboxV2 = require("../src/PlayerDataInitializer/RecordStoreMailboxV2")
local V2Module = require("../src/PlayerDataInitializer/RecordStoreV2")

local now_ms = 1000
local V2 = V2Module.new(RecordStore, MailboxV2, {
	runtime = {
		now_ms = function() return now_ms end,
		now_unix = function() return math.floor(now_ms / 1000) end,
		advance_ms = function(ms) now_ms += ms end,
	},
	allow_unattested_activation = true,
})
local function new_scheduler()
	return V2.RuntimeGovernor.new({
		now_ms = function() return now_ms end,
		advance_ms = function(ms) now_ms += ms end,
	})
end
local function enqueue(scheduler, item)
	local result = scheduler:Enqueue(item)
	assert(result.code == "accepted", "enqueue failed: " .. tostring(result.code) .. " " .. tostring(result.message))
end
local function take(scheduler, expected_id)
	local item, status = scheduler:TakeNext()
	assert(item ~= nil and status == "success", "expected a selectable item")
	assert(item.id == expected_id, "expected " .. expected_id .. ", got " .. tostring(item and item.id))
	assert(scheduler:MarkCompleted(item.id, "committed"), "failed to complete " .. expected_id)
	return item
end

-- DRR shares service across owner/work-class lanes.
local fair = new_scheduler()
for index = 1, 5 do
	enqueue(fair, { id = "a-" .. index, owner_id = "owner-a", lane = "normal", operation_class = "read" })
	enqueue(fair, { id = "b-" .. index, owner_id = "owner-b", lane = "normal", operation_class = "read" })
end
local owner_order = {}
for _ = 1, 10 do
	local item, status = fair:TakeNext()
	assert(item ~= nil and status == "success", "DRR unexpectedly had no eligible work")
	owner_order[#owner_order + 1] = item.owner_id
	assert(fair:MarkCompleted(item.id, "committed"), "DRR selection did not release the owner slot")
end
local owner_a, owner_b = 0, 0
for _, owner in ipairs(owner_order) do
	if owner == "owner-a" then owner_a += 1 else owner_b += 1 end
end
assert(owner_a == 5 and owner_b == 5, "DRR did not provide equal service to equal-weight owners")
for index = 2, #owner_order do
	assert(owner_order[index] ~= owner_order[index - 1], "DRR did not rotate between equally weighted owners")
end

local weighted_cost = new_scheduler()
enqueue(weighted_cost, { id = "large", owner_id = "large-owner", lane = "normal", operation_class = "update_async", read_units = 8, write_units = 8 })
enqueue(weighted_cost, { id = "small", owner_id = "small-owner", lane = "normal", operation_class = "read" })
take(weighted_cost, "small")
take(weighted_cost, "large")

-- Deadline is advisory; work remains executable when its SLO is overdue.
local deadline = new_scheduler()
enqueue(deadline, { id = "no-deadline", owner_id = "same-owner", work_class = "maintenance", lane = "normal" })
enqueue(deadline, { id = "tight-deadline", owner_id = "same-owner", work_class = "maintenance", lane = "normal", deadline_ms = now_ms + 5 })
local picked = deadline:TakeNext()
assert(picked ~= nil and picked.id == "tight-deadline", "lower deadline slack was not preferred within a lane")
assert(deadline:MarkCompleted(picked.id, "committed"), "deadline selection did not complete")
now_ms += 20
local overdue = deadline:TakeNext()
assert(overdue ~= nil and overdue.id == "no-deadline", "eligible work was lost after deadline scheduling")
assert(deadline:MarkCompleted(overdue.id, "committed"), "overdue queue item did not release")

local expiration = new_scheduler()
enqueue(expiration, { id = "expires-before-start", owner_id = "expiry-owner", lane = "normal", expires_at_ms = now_ms + 1 })
now_ms += 2
local expired, expired_status = expiration:TakeNext()
assert(expired ~= nil and expired_status == "expired", "expired scheduled work was silently discarded")
assert(expired.terminal_result.code == "expired", "expiry did not return a typed terminal result")
assert(expiration:Stats().stats.scheduled_expired == 1, "expiry metric did not increment")
assert(expiration:MarkCompleted(expired.id, expired.terminal_result.code), "expired item could not be reconciled")

-- Dependencies are validated and only successful outcomes unlock dependents.
local dependencies = new_scheduler()
assert(dependencies:Enqueue({ id = "missing-dependent", owner_id = "x", dependencies = { "missing" } }).code == "invalid",
	"missing dependency was silently accepted")
assert(dependencies:Enqueue({ id = "self-cycle", owner_id = "x", dependencies = { "self-cycle" } }).code == "invalid",
	"self dependency cycle was silently accepted")
enqueue(dependencies, { id = "prerequisite", owner_id = "flow-owner", lane = "background" })
enqueue(dependencies, { id = "dependent", owner_id = "flow-owner", lane = "high", dependencies = { "prerequisite" } })
take(dependencies, "prerequisite")
take(dependencies, "dependent")

local failed_flow = new_scheduler()
enqueue(failed_flow, { id = "failing-step", owner_id = "flow-owner", lane = "normal" })
enqueue(failed_flow, { id = "must-not-run", owner_id = "flow-owner", lane = "high", dependencies = { "failing-step" } })
local failing = failed_flow:TakeNext()
assert(failing ~= nil and failing.id == "failing-step", "failed workflow selected the dependent first")
assert(failed_flow:MarkCompleted(failing.id, "unknown"), "unknown prerequisite outcome did not terminalize")
local blocked, blocked_status = failed_flow:TakeNext()
assert(blocked ~= nil and blocked_status == "dependency_failed", "dependent work did not return dependency_failed")
assert(blocked.terminal_result.dependency_code == "unknown", "dependency failure did not retain prerequisite outcome")

-- Due-time heap handles ordering and stale replacement entries.
local due = new_scheduler()
assert(due:ScheduleDue("late", now_ms + 100, "late-value"))
assert(due:ScheduleDue("early", now_ms + 10, "early-value"))
assert(due:NextDueAt() == now_ms + 10, "due heap did not expose the earliest wake")
assert(due:ScheduleDue("replace", now_ms + 1, "stale-value"))
assert(due:ScheduleDue("replace", now_ms + 200, "new-value"))
assert(due:NextDueAt() == now_ms + 10, "due replacement hid an earlier unrelated wake")
now_ms += 10
local popped = due:PopDue(1)
assert(#popped == 1 and popped[1].id == "early", "due heap returned the wrong due item")
assert(due:NextDueAt() == now_ms + 90, "due heap surfaced a stale replaced timer")

-- Per-owner concurrency does not block another owner.
local per_owner = new_scheduler()
local base_policy = per_owner:Stats().policy
local policy_ok = per_owner:SetPolicy({ revision = base_policy.revision + 1, max_per_owner_in_flight = 1 })
assert(policy_ok, "scheduler rejected a valid per-owner concurrency policy")
enqueue(per_owner, { id = "owner-one-a", owner_id = "one", lane = "normal" })
enqueue(per_owner, { id = "owner-one-b", owner_id = "one", lane = "normal" })
enqueue(per_owner, { id = "owner-two", owner_id = "two", lane = "normal" })
local first = per_owner:TakeNext()
assert(first ~= nil, "bounded concurrency fixture had no first item")
local second = per_owner:TakeNext()
assert(second ~= nil, "another owner did not retain a selectable item")
local owner_one_first = if first.owner_id == "one" then first else second
local owner_two_first = if first.owner_id == "two" then first else second
assert(owner_one_first.owner_id == "one" and owner_two_first.owner_id == "two",
	"the scheduler failed to expose both owners before a second item from one owner")
assert(per_owner:TakeNext() == nil, "the configured per-owner in-flight cap was exceeded")
per_owner:MarkCompleted(first.id, "committed")
per_owner:MarkCompleted(second.id, "committed")
take(per_owner, "owner-one-b")

-- Shadow mode is opt-in and cannot mutate the actual selection queue.
local shadow = new_scheduler()
local shadow_policy = shadow:Stats().policy
local shadow_ok = shadow:SetPolicy({
	revision = shadow_policy.revision + 1,
	algorithm = "drr",
	shadow_algorithm = "fifo",
	shadow_enabled = true,
	shadow_sample_rate = 1,
})
assert(shadow_ok, "valid shadow policy was rejected")
enqueue(shadow, { id = "oldest", owner_id = "shadow-owner", work_class = "maintenance", lane = "normal" })
now_ms += 1
enqueue(shadow, { id = "deadline-first", owner_id = "shadow-owner", work_class = "maintenance", lane = "normal", deadline_ms = now_ms + 1 })
local before_shadow = shadow:Stats().queue_items
local comparison = shadow:ShadowDecision()
assert(comparison.candidate_count == 2 and comparison.same_choice == false,
	"shadow scheduler did not compare alternate policy against active policy")
assert(shadow:Stats().queue_items == before_shadow, "shadow scheduler mutated the real queue")
local selected, selected_status = shadow:TakeNext()
assert(selected ~= nil and selected_status == "success", "real scheduler stopped after shadow sampling")
assert(shadow:Stats().stats.shadow_samples >= 2, "shadow sampling was not recorded")

-- Retry rescheduling retains the logical ID, honors cooldown and is not runnable early.
local retry_queue = new_scheduler()
enqueue(retry_queue, { id = "stable-retry-id", owner_id = "retry-owner", lane = "normal", work_class = "outbox" })
local retry_first, retry_status = retry_queue:TakeNext()
assert(retry_first ~= nil and retry_status == "success", "retry fixture was not selectable")
local requeued, requeue_error, retry_due = retry_queue:Reschedule(retry_first.id, now_ms + 50)
assert(requeued, "same-ID retry was not requeued: " .. tostring(requeue_error))
assert(retry_queue:Stats().queue_items == 1, "retry requeue changed bounded queue accounting")
assert(retry_queue:TakeNext() == nil, "retry became eligible before its due time")
now_ms = retry_due
local retry_second, retry_second_status = retry_queue:TakeNext()
assert(retry_second ~= nil and retry_second_status == "success" and retry_second.id == retry_first.id and retry_second.is_retry,
	"retry did not preserve its logical ID and retry state")
assert(retry_queue:MarkCompleted(retry_second.id, "committed"), "retry did not release scheduler state")
assert(next(retry_queue:Stats().scheduler.active_by_owner) == nil, "completed owner state leaked")

-- A high-priority dependent grants only a bounded scheduling boost to a ready
-- background prerequisite. The business lane and item identity stay unchanged.
local inheritance = new_scheduler()
enqueue(inheritance, { id = "ready-prerequisite", owner_id = "workflow-owner", work_class = "saga", lane = "background" })
local inheritance_policy = inheritance:Stats().policy
enqueue(inheritance, { id = "urgent-dependent", owner_id = "workflow-owner", work_class = "saga", lane = "high",
	dependencies = { "ready-prerequisite" } })
local inherited, inherited_status = inheritance:TakeNext()
assert(inherited ~= nil and inherited_status == "success" and inherited.id == "ready-prerequisite",
	"dependency inheritance selected work out of order")
assert(inherited.lane == "background" and inherited.inherited_lane == "normal",
	"priority inheritance changed the durable/original lane or failed to raise temporary urgency")
assert(inherited.inherited_until_ms <= now_ms + inheritance_policy.priority_inheritance_max_ms,
	"priority inheritance exceeded its duration bound")
assert(inheritance:MarkCompleted(inherited.id, "committed"), "inherited prerequisite did not complete")
take(inheritance, "urgent-dependent")

-- Deadline boosts are bounded. After the configured urgent streak the selector
-- returns the oldest queued item in that owner's lane rather than chasing slack.
local urgent = new_scheduler()
local urgent_policy = urgent:Stats().policy
assert(urgent:SetPolicy({ revision = urgent_policy.revision + 1, urgent_deadline_burst = 2 }), "urgent burst policy was rejected")
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

-- Shared dispatch runs yielding work concurrently and reserves a slot for
-- claim-lease renewal rather than letting long handlers block renewals.
local shared = V2.RuntimeGovernor.get_shared()
local shared_policy = shared:Stats().policy
local applied_policy, applied_message = V2.ApplySchedulerPolicy({
	revision = shared_policy.revision + 1,
	max_scheduled_in_flight = 2,
	scheduler_critical_reserve = 1,
	max_per_owner_in_flight = 2,
})
assert(applied_policy == "success", "bounded dispatcher policy failed: " .. tostring(applied_message))
local slow_started, slow_finished = false, false
local renewal_finished, parallel_finished, parallel_during_slow = false, false, false
local slow_job = V2.ScheduleMaintenance("dispatch-owner", "slow-yielding-step", function()
	slow_started = true
	task.wait(0.08)
	slow_finished = true
	return { code = "committed" }
end, { lane = "normal", on_complete = function() end })
assert(slow_job.code == "accepted", "yielding maintenance callback was not scheduled")
for _ = 1, 100 do
	if slow_started then break end
	task.wait(0.001)
end
assert(slow_started, "dispatcher did not start the first yielding callback")
local renewal_job = V2.ScheduleMaintenance("dispatch-owner", "reserved-lease-renewal", function()
	renewal_finished = not slow_finished
	return { code = "renewed" }
end, {
	lane = "lease_renewal",
	service_class = "critical",
	work_class = "lease_renewal",
	operation_class = "lease_renewal",
	deadline_ms = now_ms + 5000,
	expires_at_ms = now_ms + 10000,
	on_complete = function() end,
})
assert(renewal_job.code == "accepted", "lease-renewal lane did not accept work")
for _ = 1, 100 do
	if renewal_finished then break end
	task.wait(0.001)
end
assert(renewal_finished, "reserved lease renewal waited behind a yielding normal callback")
local parallel_job = V2.ScheduleMaintenance("dispatch-owner", "parallel-normal-step", function()
	parallel_during_slow = not slow_finished
	parallel_finished = true
	return { code = "committed" }
end, { lane = "normal", on_complete = function() end })
assert(parallel_job.code == "accepted", "parallel maintenance callback was not scheduled")
for _ = 1, 100 do
	if parallel_finished and slow_finished then break end
	task.wait(0.002)
end
assert(parallel_finished and slow_finished, "bounded concurrent dispatcher failed to finish callbacks")
assert(parallel_during_slow, "yielding scheduled callbacks did not overlap when capacity allowed")
assert(V2.GetSchedulerDispatchStats().max_in_flight >= 2, "dispatcher did not report concurrent active work")

local bad_algorithm = shadow:SetPolicy({ revision = shadow:Stats().policy.revision + 1, algorithm = "imaginary" })
assert(not bad_algorithm, "unsupported active scheduler algorithm was accepted")
local bad_cost = shadow:Enqueue({ id = "excess-cost", owner_id = "cost-owner", lane = "normal", read_units = 64, write_units = 64 })
assert(bad_cost.code == "invalid", "cost above configured safe bound was accepted")

print("[PASS] RecordStoreV2 advanced scheduler DRR, deadlines, expiry, dependencies, due heap and shadow selection.")
Shim.close()
