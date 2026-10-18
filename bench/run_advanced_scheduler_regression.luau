--!nocheck
-- PR #33 advanced-scheduler public behavior regression suite.
local Scheduler = require("../src/PlayerDataInitializer/RecordStoreScheduler")
local task = require("@lune/task")

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
local policy = new_scheduler()
local policy_stats = policy:Stats()
assert(not policy:SetPolicy({ revision = policy_stats.policy.revision }), "stale policy revision was accepted")
assert(not policy:SetPolicy({ revision = policy_stats.policy.revision + 1, algorithm = "not-a-policy" }),
	"unknown scheduler algorithm was accepted")
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

-- Expiry is a no-new-start boundary and emits an explicit terminal status.
local expiration = new_scheduler()
enqueue(expiration, { id = "expires-before-start", owner_id = "expiry-owner", lane = "normal", expires_at_ms = now_ms + 1 })
now_ms += 2
local expired, expired_status = expiration:TakeNext()
assert(expired ~= nil and expired_status == "expired", "expired work was silently discarded")
assert(expired.terminal_result.code == "expired", "expiry did not return a typed result")
assert(expiration:Stats().stats.scheduled_expired == 1, "expiry metric did not increment")
assert(expiration:MarkCompleted(expired.id, expired.terminal_result.code), "expired work could not be reconciled")

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

-- Retry rescheduling preserves the logical ID and cannot run before its due time.
local retry_queue = new_scheduler()
enqueue(retry_queue, { id = "stable-retry-id", owner_id = "retry-owner", lane = "normal", work_class = "outbox" })
local retry_first, retry_status = retry_queue:TakeNext()
assert(retry_first ~= nil and retry_status == "success", "retry fixture was not selectable")
local requeued, requeue_error, retry_due = retry_queue:Reschedule(retry_first.id, now_ms + 50)
assert(requeued, "same-ID retry was not requeued: " .. tostring(requeue_error))
assert(retry_queue:Stats().queue_items == 1, "retry changed bounded queue accounting")
assert(retry_queue:TakeNext() == nil, "retry became eligible before its due time")
now_ms = retry_due
local retry_second, retry_second_status = retry_queue:TakeNext()
assert(retry_second ~= nil and retry_second_status == "success" and retry_second.id == retry_first.id and retry_second.is_retry,
	"retry did not preserve its ID and retry marker")
assert(retry_queue:MarkCompleted(retry_second.id, "committed"), "retry did not release scheduler state")
assert(next(retry_queue:Stats().scheduler.active_by_owner) == nil, "completed owner state leaked")

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

-- The async dispatcher reserves a worker slot for lease renewals even while a
-- normal maintenance callback yields. Arbitrary callback exceptions become unknown.
local shared = new_scheduler()
local shared_policy = shared:Stats().policy
assert(shared:SetPolicy({
	revision = shared_policy.revision + 1,
	max_scheduled_in_flight = 2,
	scheduler_critical_reserve = 1,
	max_per_owner_in_flight = 2,
}), "bounded dispatcher policy failed")
local dispatcher = Scheduler.new_dispatcher(shared, { now_ms = function() return now_ms end })
local slow_started, slow_finished = false, false
local renewal_finished, parallel_finished, parallel_during_slow = false, false, false
local slow_job = dispatcher:Schedule("dispatch-owner", "slow-yielding-step", function()
	slow_started = true
	task.wait(0.08)
	slow_finished = true
	return { code = "committed" }
end, { lane = "normal" })
assert(slow_job.code == "accepted", "yielding callback was not accepted")
for _ = 1, 100 do if slow_started then break end; task.wait(0.001) end
assert(slow_started, "dispatcher did not start the first yielding callback")
local renewal_job = dispatcher:Schedule("dispatch-owner", "reserved-lease-renewal", function()
	renewal_finished = not slow_finished
	return { code = "renewed" }
end, {
	lane = "lease_renewal", service_class = "critical", work_class = "lease_renewal",
	operation_class = "lease_renewal", deadline_ms = now_ms + 5000, expires_at_ms = now_ms + 10000,
})
assert(renewal_job.code == "accepted", "lease-renewal lane rejected work")
for _ = 1, 100 do if renewal_finished then break end; task.wait(0.001) end
assert(renewal_finished, "reserved lease renewal waited behind a yielding normal callback")
local parallel_job = dispatcher:Schedule("dispatch-owner", "parallel-normal-step", function()
	parallel_during_slow = not slow_finished
	parallel_finished = true
	return { code = "committed" }
end, { lane = "normal" })
assert(parallel_job.code == "accepted", "parallel callback was not accepted")
for _ = 1, 100 do if parallel_finished and slow_finished then break end; task.wait(0.002) end
assert(parallel_finished and slow_finished, "bounded concurrent dispatcher failed to finish callbacks")
assert(parallel_during_slow, "yielding callbacks did not overlap when capacity allowed")
assert(dispatcher:Stats().max_in_flight >= 2, "dispatcher did not record concurrent work")
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
for _ = 1, 200 do if retry_done then break end; task.wait(0.002) end
assert(retry_done and callback_attempts == 2, "explicit retryable result did not retry exactly once")

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

-- The main RecordStore module resolves the same scheduler through its
-- ModuleScript parent. Runtime scheduling remains opt-in.
local RecordStore = Shim.load()
local initial_snapshot = RecordStore.get_scheduler_snapshot()
assert(initial_snapshot.enabled == false, "advanced core scheduling must start disabled")
local configured, configure_message = RecordStore.configure_scheduler_policy({
	revision = initial_snapshot.policy.revision + 1,
	shadow_enabled = true,
	shadow_sample_rate = 1,
})
assert(configured == "success", "core scheduler rejected policy: " .. tostring(configure_message))
local enabled, enable_message = RecordStore.set_scheduler_enabled(true)
assert(enabled, "core scheduler did not enable: " .. tostring(enable_message))

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
for _ = 1, 300 do
	local stats = core_record:Stats()
	if stats.dirty == 0 and stats.busy == 0 then saved = true; break end
	task.wait(0.002)
end
assert(saved, "core background autosave did not complete through the selector")
local dispatch_snapshot = RecordStore.get_scheduler_snapshot().dispatcher
assert(dispatch_snapshot.accepted >= 2 and dispatch_snapshot.completed >= 2,
	"core background autosave was not represented in scheduler metrics")
local closed_code = core_record:Close()
assert(closed_code == "closed", "scheduler regression fixture failed to close")
assert(RecordStore.set_scheduler_enabled(false), "core scheduling kill switch failed")

print("[PASS] RecordStore advanced scheduling unit and core integration regressions.")
Shim.close()

