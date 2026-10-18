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
assert(first ~= nil and first.owner_id == "one", "unexpected first owner in bounded concurrency fixture")
local second = per_owner:TakeNext()
assert(second ~= nil and second.owner_id == "two", "owner cap did not preserve another owner's opportunity")
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

local bad_algorithm = shadow:SetPolicy({ revision = shadow:Stats().policy.revision + 1, algorithm = "imaginary" })
assert(not bad_algorithm, "unsupported active scheduler algorithm was accepted")
local bad_cost = shadow:Enqueue({ id = "excess-cost", owner_id = "cost-owner", lane = "normal", read_units = 64, write_units = 64 })
assert(bad_cost.code == "invalid", "cost above configured safe bound was accepted")

print("[PASS] RecordStoreV2 advanced scheduler DRR, deadlines, expiry, dependencies, due heap and shadow selection.")
Shim.close()
