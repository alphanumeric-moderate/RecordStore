--!nocheck
-- Regression checks for previously fixed scheduler admission and policy-update bugs.
local Scheduler = require("./RobloxShim").load_scheduler()

local function new_governor()
	return Scheduler.new({ now_ms = function() return 1_800_000_000_000 end })
end

do
	local governor = new_governor()
	local before = governor:Stats().policy
	local accepted = governor:SetPolicy({
		revision = before.revision + 1,
		max_in_flight = 16,
		critical_reserve = 16,
	})
	assert(not accepted, "invalid policy shrink unexpectedly succeeded")

	local after = governor:Stats().policy
	assert(after.revision == before.revision, "rejected policy update advanced its revision")
	assert(after.max_in_flight == before.max_in_flight, "rejected policy update partially changed max_in_flight")
	assert(after.critical_reserve == before.critical_reserve,
		"rejected policy update partially changed critical_reserve")
end

do
	local governor = new_governor()
	local rejected = governor:Admit("maintenance", "update_async", 1, false, false, {
		estimated_bytes = 1024,
		handler_slots = 1,
	})
	assert(rejected.code == "invalid", "partial resource estimate was not rejected")
	local snapshot = governor:Stats()
	assert(snapshot.in_flight == 0, "partial resource estimate consumed global admission")
	assert(snapshot.estimated_bytes_in_flight == 0, "partial resource estimate consumed byte admission")
	assert(snapshot.handler_slots_in_flight == 0, "partial resource estimate consumed handler admission")
	assert(snapshot.active_reservation_tickets == 0, "partial resource estimate created a reservation ticket")
end

do
	local governor = new_governor()
	local rejected = governor:Enqueue({
		id = "bugfix-false-lane",
		owner_id = "bugfix-regression",
		lane = false,
	})
	assert(rejected.code == "invalid", "lane=false was silently normalized")
	assert(governor:Stats().queue_items == 0, "invalid lane left queued work behind")
end


do
	local now = 1_800_000_000_000
	local governor = Scheduler.new({ now_ms = function() return now end })

	local function enqueue_and_complete(id, outcome, options)
		local item_options = {
			id = id,
			owner_id = "history-owner-" .. id,
			lane = "normal",
			work_class = "maintenance",
			operation_class = "update_async",
		}
		if options ~= nil then
			for key, value in pairs(options) do item_options[key] = value end
		end
		local accepted = governor:Enqueue(item_options)
		assert(accepted.code == "accepted", "terminal-history fixture enqueue failed: " .. tostring(accepted.message))
		local selected, status = governor:TakeNext()
		assert(selected ~= nil and selected.id == id,
			("terminal-history fixture selected %s instead of %s (%s)"):format(
				tostring(selected and selected.id), id, tostring(status)))
		local marked, message = governor:MarkCompleted(id, outcome or "success")
		assert(marked, "terminal-history fixture completion failed: " .. tostring(message))
	end

	enqueue_and_complete("terminal-prerequisite", "success")
	local capacity = governor:Stats().policy.queue_capacity
	local retained = governor:Enqueue({
		id = "queued-dependent",
		owner_id = "queued-dependent-owner",
		lane = "normal",
		work_class = "maintenance",
		dependencies = { "terminal-prerequisite" },
		available_at_ms = now + 60_000,
	})
	assert(retained.code == "accepted", "queued dependent did not retain its terminal prerequisite")
	for i = 1, capacity * 2 + 1 do
		enqueue_and_complete("history-prune-queued-" .. tostring(i), "success")
	end
	assert(governor.completed["terminal-prerequisite"] == true,
		"bounded pruning removed a successful prerequisite still referenced by queued work")
	now += 60_001
	local selected, selected_status = governor:TakeNext()
	assert(selected ~= nil and selected.id == "queued-dependent",
		"queued dependent became undispatchable after unrelated terminal-history pruning: "
			.. tostring(selected_status))
	local completed, complete_message = governor:MarkCompleted("queued-dependent", "success")
	assert(completed, tostring(complete_message))
	assert(governor.completed["terminal-prerequisite"] == nil,
		"pruned prerequisite history was not reclaimed after its queued dependent terminated")
	local reused = governor:Enqueue({
		id = "terminal-prerequisite",
		owner_id = "reused-prerequisite-owner",
		lane = "normal",
	})
	assert(reused.code == "accepted", "terminal prerequisite ID was not reusable after its last dependency reference released")
end

do
	local now = 1_800_000_000_000
	local governor = Scheduler.new({ now_ms = function() return now end })

	local function complete_one(id)
		local accepted = governor:Enqueue({
			id = id,
			owner_id = "inflight-history-owner-" .. id,
			lane = "normal",
			work_class = "maintenance",
			operation_class = "update_async",
		})
		assert(accepted.code == "accepted", "in-flight terminal-history enqueue failed: " .. tostring(accepted.message))
		local selected, status = governor:TakeNext()
		assert(selected ~= nil and selected.id == id,
			("in-flight terminal-history selected %s instead of %s (%s)"):format(
				tostring(selected and selected.id), id, tostring(status)))
		local marked, message = governor:MarkCompleted(id, "success")
		assert(marked, tostring(message))
	end

	complete_one("inflight-prerequisite")
	local accepted = governor:Enqueue({
		id = "inflight-dependent",
		owner_id = "inflight-dependent-owner",
		lane = "normal",
		work_class = "maintenance",
		dependencies = { "inflight-prerequisite" },
	})
	assert(accepted.code == "accepted", "in-flight dependent enqueue failed: " .. tostring(accepted.message))
	local selected, status = governor:TakeNext()
	assert(selected ~= nil and selected.id == "inflight-dependent",
		"in-flight dependent was not dispatched with a completed prerequisite: " .. tostring(status))
	local capacity = governor:Stats().policy.queue_capacity
	for i = 1, capacity * 2 + 1 do
		complete_one("history-prune-inflight-" .. tostring(i))
	end
	assert(governor.completed["inflight-prerequisite"] == true,
		"bounded pruning removed a successful prerequisite still referenced by in-flight work")
	local marked, message = governor:MarkCompleted("inflight-dependent", "success")
	assert(marked, tostring(message))
	assert(governor.completed["inflight-prerequisite"] == nil,
		"pruned prerequisite history was not reclaimed after its in-flight dependent terminated")
	local reused = governor:Enqueue({
		id = "inflight-prerequisite",
		owner_id = "inflight-prerequisite-reused-owner",
		lane = "normal",
	})
	assert(reused.code == "accepted", "in-flight prerequisite ID was not reusable after dependency-reference release")
end


do
	local now = 1_800_000_000_000
	local governor = Scheduler.new({ now_ms = function() return now end })
	local before = governor:Stats().policy
	local configured, message = governor:SetPolicy({
		revision = before.revision + 1,
		algorithm = "fifo",
		high_burst = 2,
	})
	assert(configured, "could not configure deterministic fairness policy: " .. tostring(message))

	for i = 1, 8 do
		local accepted = governor:Enqueue({
			id = "fair-high-" .. tostring(i),
			owner_id = "fair-high-owner-" .. tostring(i),
			lane = "high",
			work_class = "maintenance",
			operation_class = "update_async",
		})
		assert(accepted.code == "accepted", "sustained high-lane fixture was rejected")
	end
	local background = governor:Enqueue({
		id = "fair-background",
		owner_id = "fair-background-owner",
		lane = "background",
		work_class = "maintenance",
		operation_class = "update_async",
	})
	assert(background.code == "accepted", "background fairness fixture was rejected")

	local background_position
	for position = 1, 3 do
		local selected, status = governor:TakeNext()
		assert(selected ~= nil and status == "success",
			"bounded high-priority flood made no dispatch progress: " .. tostring(status))
		if selected.id == "fair-background" then background_position = position end
		local completed, completion_error = governor:MarkCompleted(selected.id, "success")
		assert(completed, "fairness fixture completion failed: " .. tostring(completion_error))
	end
	assert(background_position == 3,
		"background work did not receive service immediately after the configured high-lane burst")
end

do
	local now = 1_800_000_000_000
	local governor = Scheduler.new({ now_ms = function() return now end })
	local before = governor:Stats().policy
	local configured, message = governor:SetPolicy({
		revision = before.revision + 1,
		minimum_budget = 2,
	})
	assert(configured, "could not configure low-budget admission fixture: " .. tostring(message))
	assert(governor:ObserveRequestBudgets(1, 1), "low request budgets were rejected")

	local normal = governor:Enqueue({
		id = "low-budget-normal",
		owner_id = "low-budget-normal-owner",
		lane = "normal",
		work_class = "maintenance",
		operation_class = "update_async",
		service_class = "normal",
		read_units = 1,
		write_units = 1,
		estimated_bytes = 1024,
		handler_slots = 1,
	})
	local critical = governor:Enqueue({
		id = "low-budget-critical",
		owner_id = "low-budget-critical-owner",
		lane = "normal",
		work_class = "maintenance",
		operation_class = "update_async",
		service_class = "critical",
		read_units = 1,
		write_units = 1,
		estimated_bytes = 1024,
		handler_slots = 1,
	})
	assert(normal.code == "accepted" and critical.code == "accepted",
		"low-budget fixtures were not accepted into the bounded scheduler")

	local selected, status = governor:TakeNext()
	assert(selected ~= nil and status == "success" and selected.id == "low-budget-critical",
		"low-budget optional work occupied a slot ahead of eligible critical work")
	assert(governor.known["low-budget-normal"].admission_blocked_until_ms == now + 250,
		"noncritical work was not deferred by the configured low-budget threshold")
	assert(governor:Stats().stats.throttled >= 1,
		"low-budget backpressure was not included in throttling diagnostics")
	local completed, completion_error = governor:MarkCompleted(selected.id, "success")
	assert(completed, "critical low-budget fixture completion failed: " .. tostring(completion_error))
end

do
	local now = 1_800_000_000_000
	local governor = Scheduler.new({ now_ms = function() return now end })
	local before = governor:Stats().policy
	local configured, message = governor:SetPolicy({
		revision = before.revision + 1,
		circuit_threshold = 2,
		circuit_cooldown_ms = 100,
	})
	assert(configured, "could not configure circuit-breaker fixture: " .. tostring(message))
	governor:Observe("update_async", false, 5, "throttled", 10)
	governor:Observe("update_async", false, 5, "throttled", 10)
	assert(governor:Stats().circuits.update_async.state == "open",
		"repeated throttling did not open the per-operation circuit")

	local queued = governor:Enqueue({
		id = "circuit-probe",
		owner_id = "circuit-probe-owner",
		lane = "normal",
		work_class = "maintenance",
		operation_class = "update_async",
		read_units = 1,
		write_units = 1,
		estimated_bytes = 1024,
		handler_slots = 1,
	})
	assert(queued.code == "accepted", "circuit-breaker fixture enqueue failed")
	local selected, status = governor:TakeNext()
	assert(selected == nil and status == "empty",
		"work was selected while its operation circuit was cooling down")
	assert(governor.known["circuit-probe"].admission_blocked_until_ms == now + 100,
		"open-circuit work did not retain a bounded retry time")
	assert(governor:NextWakeAt() == now + 100,
		"open-circuit retry was not discoverable by the bounded wake scheduler")

	now += 99
	selected, status = governor:TakeNext()
	assert(selected == nil and status == "empty", "circuit probe ran before its cooldown expired")
	now += 1
	selected, status = governor:TakeNext()
	assert(selected ~= nil and status == "success" and selected.id == "circuit-probe",
		"circuit probe did not resume after the configured cooldown")

	local ticket = governor:Admit("maintenance", "update_async", 1, true, false, {
		read_units = 1, write_units = 1, estimated_bytes = 1024, handler_slots = 1,
	})
	assert(ticket.code == "admitted", "half-open circuit did not admit its single probe")
	governor:Observe("update_async", true, 5, nil, 10)
	assert(governor:Stats().circuits.update_async.state == "closed",
		"successful half-open probe did not close the circuit")
	assert(governor:Release(ticket), "circuit probe admission reservation was not released")
	local completed, completion_error = governor:MarkCompleted(selected.id, "success")
	assert(completed, "circuit probe completion failed: " .. tostring(completion_error))
end

do
	local now = 1_800_000_000_000
	local governor = Scheduler.new({ now_ms = function() return now end })
	local function enqueue(id, lane, deadline)
		local result = governor:Enqueue({
			id = id,
			owner_id = id .. "-owner",
			lane = lane,
			work_class = if lane == "lease_renewal" then "profile_release" else "maintenance",
			operation_class = if lane == "lease_renewal" then "lease_renewal" else "update_async",
			service_class = if lane == "lease_renewal" then "critical" else "normal",
			deadline_ms = deadline,
			read_units = 1,
			write_units = 1,
			estimated_bytes = 1024,
			handler_slots = 1,
		})
		assert(result.code == "accepted", "lease-lane fixture enqueue failed: " .. tostring(result.message))
	end

	enqueue("renewal-late", "lease_renewal", now + 10_000)
	enqueue("renewal-urgent", "lease_renewal", now + 500)
	enqueue("renewal-regular", "normal", now + 100)
	local regular, regular_status = governor:TakeNext("regular")
	assert(regular ~= nil and regular_status == "success" and regular.id == "renewal-regular",
		"regular dispatch consumed reserved lease-renewal work")
	assert(governor:MarkCompleted(regular.id, "success"), "regular lease-lane fixture completion failed")
	local renewal, renewal_status = governor:TakeNext(true)
	assert(renewal ~= nil and renewal_status == "success" and renewal.id == "renewal-urgent",
		"renewal lane did not prefer the smallest remaining lease margin")
	assert(governor:MarkCompleted(renewal.id, "success"), "urgent renewal fixture completion failed")
	local next_renewal, next_status = governor:TakeNext(true)
	assert(next_renewal ~= nil and next_status == "success" and next_renewal.id == "renewal-late",
		"regular renewal stopped making progress after the urgent renewal completed")
	assert(governor:MarkCompleted(next_renewal.id, "success"), "late renewal fixture completion failed")
end

do
	local governor = new_governor()
	local prerequisite_id = "terminal-failed-prerequisite"
	local accepted = governor:Enqueue({
		id = prerequisite_id,
		owner_id = "terminal-failed-prerequisite-owner",
		lane = "normal",
		work_class = "maintenance",
	})
	assert(accepted.code == "accepted", "failed prerequisite fixture was not accepted")
	local selected, status = governor:TakeNext()
	assert(selected ~= nil and selected.id == prerequisite_id and status == "success",
		"failed prerequisite fixture was not dispatched")
	local marked, message = governor:MarkCompleted(prerequisite_id, "permanent_failure")
	assert(marked, "failed prerequisite fixture could not be terminalized: " .. tostring(message))
	assert(governor.failed[prerequisite_id] == "permanent_failure",
		"failed prerequisite was not retained in terminal history")

	local dependent = governor:Enqueue({
		id = "dependent-of-terminal-failure",
		owner_id = "dependent-of-terminal-failure-owner",
		lane = "normal",
		work_class = "maintenance",
		dependencies = { prerequisite_id },
	})
	assert(dependent.code == "accepted",
		"dependent enqueue rejected a retained terminal failure: " .. tostring(dependent.message))
	local terminal, terminal_status = governor:TakeNext()
	assert(terminal ~= nil and terminal.id == "dependent-of-terminal-failure"
		and terminal_status == "dependency_failed",
		"dependent of an already-failed prerequisite did not terminate as dependency_failed")
	assert(terminal.terminal_result.dependency_id == prerequisite_id
		and terminal.terminal_result.dependency_code == "permanent_failure",
		"dependent terminal result did not preserve the failed prerequisite identity and reason")

	local missing = governor:Enqueue({
		id = "dependent-of-missing-prerequisite",
		owner_id = "dependent-of-missing-prerequisite-owner",
		lane = "normal",
		work_class = "maintenance",
		dependencies = { "never-enqueued-prerequisite" },
	})
	assert(missing.code == "invalid",
		"dependency validation accepted a prerequisite with no retained or active history")
end

do
	local governor = new_governor()
	local scratch = governor.selection_scratch.active_lane_keys
	assert(type(scratch) == "table", "DRR cleanup scratch table was not initialized")
	for index = 1, 2 do
		local accepted = governor:Enqueue({
			id = "drr-scratch-reuse-" .. tostring(index),
			owner_id = "drr-scratch-reuse-owner",
			lane = "normal",
			work_class = "drr-scratch-reuse",
		})
		assert(accepted.code == "accepted", "DRR scratch reuse fixture enqueue failed")
	end

	local first, first_status = governor:TakeNext()
	assert(first ~= nil and first_status == "success", "first DRR scratch fixture was not selected")
	assert(next(governor.drr_deficit) ~= nil, "DRR fixture did not populate a lane deficit")
	assert(governor:MarkCompleted(first.id, "success"), "first DRR scratch fixture did not complete")
	assert(governor.selection_scratch.active_lane_keys == scratch,
		"MarkCompleted replaced its reusable active-lane scratch table")
	assert(next(governor.drr_deficit) ~= nil,
		"DRR deficit was cleared while another queued item still owned the lane")

	local second, second_status = governor:TakeNext()
	assert(second ~= nil and second_status == "success", "second DRR scratch fixture was not selected")
	assert(governor:MarkCompleted(second.id, "success"), "second DRR scratch fixture did not complete")
	assert(governor.selection_scratch.active_lane_keys == scratch,
		"MarkCompleted replaced its reusable active-lane scratch table")
	assert(next(governor.drr_deficit) == nil,
		"DRR deficit remained after its final queued and in-flight lane item completed")
end

do
	local now = 1_800_000_000_000
	local governor = Scheduler.new({ now_ms = function() return now end })
	local accepted = governor:Enqueue({
		id = "terminal-scan-simple-item",
		owner_id = "terminal-scan-simple-owner",
		lane = "normal",
		work_class = "maintenance",
	})
	assert(accepted.code == "accepted", "terminal-scan simple item was not accepted")
	assert(governor.terminal_preflight_count == 0,
		"simple non-expiring, non-batchable work was unnecessarily marked for terminal preflight")
	assert(governor.terminal_preflight_policy_revision == governor.policy.revision,
		"terminal-preflight scan revision did not start aligned with the active policy")

	local prior_policy = governor:Stats().policy
	local updated, update_message = governor:SetPolicy({
		revision = prior_policy.revision + 1,
		mode = "read_only",
	})
	assert(updated, "terminal-preflight policy invalidation failed: " .. tostring(update_message))
	assert(governor.terminal_preflight_policy_revision == nil,
		"policy update did not invalidate the terminal-preflight scan revision")
	local rejected, rejected_status = governor:TakeNext()
	assert(rejected ~= nil and rejected.id == "terminal-scan-simple-item"
		and rejected_status == "admission_rejected"
		and rejected.terminal_result.code == "read_only",
		"skipping unnecessary terminal sweeps caused a policy change to bypass terminal admission")
	assert(governor.terminal_preflight_count == 0,
		"terminal admission removal did not release its preflight candidate count")
	local empty, empty_status = governor:TakeNext()
	assert(empty == nil and empty_status == "empty", "terminal-preflight empty queue did not remain empty")
	assert(governor.terminal_preflight_policy_revision == governor.policy.revision,
		"complete policy-revision sweep did not restore the preflight fast path")
end

do
	local now = 1_800_000_000_000
	local governor = Scheduler.new({ now_ms = function() return now end })
	local prior_policy = governor:Stats().policy
	local configured, configure_error = governor:SetPolicy({
		revision = prior_policy.revision + 1,
		mode = "read_only",
	})
	assert(configured, "post-policy enqueue setup failed: " .. tostring(configure_error))

	local accepted = governor:Enqueue({
		id = "terminal-scan-enqueued-after-policy",
		owner_id = "terminal-scan-after-policy-owner",
		lane = "normal",
		work_class = "maintenance",
	})
	assert(accepted.code == "accepted", "simple work enqueued after policy change was not accepted")
	local item = governor.known["terminal-scan-enqueued-after-policy"]
	assert(governor.terminal_preflight_count == 1
		and governor.terminal_preflight_items[item] == true,
		"enqueue did not index a simple item rejected by the current policy")
	local rejected, rejected_status = governor:TakeNext()
	assert(rejected == item and rejected_status == "admission_rejected"
		and rejected.terminal_result.code == "read_only",
		"simple work enqueued after the policy change bypassed terminal admission")
	assert(governor.terminal_preflight_count == 0,
		"post-policy admission rejection retained a terminal-preflight candidate")
end


do
	local governor = new_governor()
	local initial_policy = governor:Stats().policy
	local configured, configure_error = governor:SetPolicy({
		revision = initial_policy.revision + 1,
		queue_capacity = 32,
	})
	assert(configured, "queue-compaction policy setup failed: " .. tostring(configure_error))
	local empty, empty_status = governor:TakeNext()
	assert(empty == nil and empty_status == "empty",
		"queue-compaction setup did not complete its policy revision sweep")

	local expected = {}
	for index = 1, 32 do
		local id = "terminal-policy-compaction-original-" .. tostring(index)
		local accepted = governor:Enqueue({
			id = id,
			owner_id = id .. "-owner",
			lane = "normal",
			work_class = "maintenance",
		})
		assert(accepted.code == "accepted", "queue-compaction original item was not accepted")
		expected[id] = true
	end
	for index = 1, 24 do
		local selected, status = governor:TakeNext()
		assert(selected ~= nil and status == "success",
			"queue-compaction fixture could not dispatch its initial work")
		assert(governor:MarkCompleted(selected.id, "success"),
			"queue-compaction fixture could not complete its initial work")
		expected[selected.id] = nil
	end
	assert(governor.queue_count == 8 and governor.queue_tail == 32,
		"queue-compaction fixture did not retain eight sparse queue slots")

	local latest_id = "terminal-policy-compaction-newest"
	local latest = governor:Enqueue({
		id = latest_id,
		owner_id = latest_id .. "-owner",
		lane = "normal",
		work_class = "maintenance",
	})
	assert(latest.code == "accepted", "queue-compaction newest item was not accepted")
	expected[latest_id] = true
	assert(governor.queue_count == 9 and governor.queue_tail == 33,
		"queue-compaction fixture did not extend the sparse queue beyond capacity")

	local active_policy = governor:Stats().policy
	local read_only, read_only_error = governor:SetPolicy({
		revision = active_policy.revision + 1,
		mode = "read_only",
	})
	assert(read_only, "queue-compaction read-only policy update failed: " .. tostring(read_only_error))

	local rejected_count = 0
	local compacted = false
	while rejected_count < 9 do
		local rejected, rejected_status = governor:TakeNext()
		assert(rejected ~= nil and rejected_status == "admission_rejected"
			and rejected.terminal_result.code == "read_only",
			"policy revision sweep skipped queued work after queue storage compaction")
		assert(expected[rejected.id] == true,
			"policy revision sweep rejected an unexpected or duplicate work item")
		expected[rejected.id] = nil
		rejected_count += 1
		if rejected.id == latest_id then
			compacted = true
			assert(governor.queue_count == 8 and governor.queue_tail == 8,
				"terminal removal did not compact the sparse queue as expected")
		end
	end
	assert(compacted, "newest terminal item did not exercise queue compaction")
	assert(next(expected) == nil, "policy revision sweep left queued work unchecked")
	assert(governor.terminal_preflight_policy_revision == governor.policy.revision,
		"policy revision sweep did not restore its fast-path revision after compaction")
	local none, none_status = governor:TakeNext()
	assert(none == nil and none_status == "empty",
		"policy revision sweep left an item dispatchable after read-only rejection")
end


do
	local now = 1_800_000_000_000
	local governor = Scheduler.new({ now_ms = function() return now end })
	local accepted = governor:Enqueue({
		id = "terminal-scan-expiring-item",
		owner_id = "terminal-scan-expiring-owner",
		lane = "normal",
		work_class = "maintenance",
		expires_at_ms = now + 100,
	})
	assert(accepted.code == "accepted", "expiring terminal-scan item was not accepted")
	assert(governor.terminal_preflight_count == 1,
		"expiring work was omitted from terminal preflight")
	now += 100
	local expired, expired_status = governor:TakeNext()
	assert(expired ~= nil and expired.id == "terminal-scan-expiring-item" and expired_status == "expired",
		"terminal-preflight optimization lost expiry handling")
	assert(governor.terminal_preflight_count == 0,
		"expired item did not release its terminal-preflight candidate count")
end

do
	local now = 1_800_000_000_000
	local governor = Scheduler.new({ now_ms = function() return now end })
	local accepted = governor:Enqueue({
		id = "terminal-scan-caller-flag",
		owner_id = "terminal-scan-caller-flag-owner",
		lane = "normal",
		work_class = "maintenance",
		expires_at_ms = now + 100,
		needs_terminal_preflight = true,
	})
	assert(accepted.code == "accepted", "caller-controlled terminal-preflight flag fixture was not accepted")
	assert(governor.terminal_preflight_count == 1,
		"caller-supplied internal flag undercounted terminal-preflight candidates")
	now += 100
	local expired, expired_status = governor:TakeNext()
	assert(expired ~= nil and expired.id == "terminal-scan-caller-flag" and expired_status == "expired",
		"caller-supplied internal flag bypassed expiry preflight")
	assert(governor.terminal_preflight_count == 0,
		"caller-flag expiry did not release its terminal-preflight candidate")
end

do
	local governor = new_governor()
	local prerequisite = governor:Enqueue({
		id = "terminal-scan-pending-prerequisite",
		owner_id = "terminal-scan-pending-owner",
		lane = "normal",
		work_class = "maintenance",
	})
	assert(prerequisite.code == "accepted", "pending prerequisite fixture was not accepted")
	local dependent = governor:Enqueue({
		id = "terminal-scan-resolved-dependent",
		owner_id = "terminal-scan-dependent-owner",
		lane = "normal",
		work_class = "maintenance",
		dependencies = { "terminal-scan-pending-prerequisite" },
	})
	assert(dependent.code == "accepted", "dependent fixture was not accepted")
	assert(governor.terminal_preflight_count == 1,
		"unresolved dependency was omitted from terminal preflight")

	local selected, status = governor:TakeNext()
	assert(selected ~= nil and selected.id == "terminal-scan-pending-prerequisite" and status == "success",
		"ready prerequisite was not dispatched ahead of its dependent")
	assert(governor:MarkCompleted(selected.id, "success"),
		"pending prerequisite fixture did not complete")
	local resolved, resolved_status = governor:TakeNext()
	assert(resolved ~= nil and resolved.id == "terminal-scan-resolved-dependent" and resolved_status == "success",
		"dependent did not become ready after prerequisite success")
	assert(governor.terminal_preflight_count == 0,
		"successfully resolved dependency continued forcing terminal-preflight scans")
	assert(governor:MarkCompleted(resolved.id, "success"),
		"resolved dependent fixture did not complete")
end

print("[scheduler-acceptance] bounded fairness, low-budget reserve, throttle recovery, and lease-margin isolation passed.")

do
	local now = 1_800_000_000_000
	local governor = Scheduler.new({ now_ms = function() return now end })
	local older = governor:Enqueue({
		id = "terminal-index-older-expiry",
		owner_id = "terminal-index-older-owner",
		lane = "normal",
		work_class = "maintenance",
		expires_at_ms = now + 100,
	})
	assert(older.code == "accepted", "older terminal-index candidate was not accepted")
	for index = 1, 32 do
		local accepted = governor:Enqueue({
			id = "terminal-index-ordinary-" .. tostring(index),
			owner_id = "terminal-index-ordinary-owner-" .. tostring(index),
			lane = "normal",
			work_class = "maintenance",
		})
		assert(accepted.code == "accepted", "ordinary terminal-index fixture was not accepted")
	end
	local newer = governor:Enqueue({
		id = "terminal-index-newer-expiry",
		owner_id = "terminal-index-newer-owner",
		lane = "normal",
		work_class = "maintenance",
		expires_at_ms = now + 100,
	})
	assert(newer.code == "accepted", "newer terminal-index candidate was not accepted")
	assert(governor.terminal_preflight_count == 2,
		"terminal-index candidate count included ordinary work or omitted expiring work")
	local order = governor.terminal_preflight_order
	assert(type(order) == "table" and governor.terminal_preflight_tail == 2
		and order[1] == governor.known["terminal-index-older-expiry"]
		and order[2] == governor.known["terminal-index-newer-expiry"],
		"ordered preflight index did not exclude ordinary work or preserve queue order")

	now += 100
	local first_expired, first_status = governor:TakeNext()
	assert(first_expired ~= nil and first_expired.id == "terminal-index-newer-expiry"
		and first_status == "expired",
		"candidate-only preflight changed newest-first expiry terminalization")
	assert(governor.terminal_preflight_count == 1
		and order[1] == governor.known["terminal-index-older-expiry"]
		and order[2] == nil,
		"terminal candidate removal did not unlink exactly the expired item")
	local second_expired, second_status = governor:TakeNext()
	assert(second_expired ~= nil and second_expired.id == "terminal-index-older-expiry"
		and second_status == "expired",
		"candidate-only preflight skipped the remaining expiry candidate")
	assert(governor.terminal_preflight_count == 0,
		"terminal candidate index retained items after all expiry work terminated")
end

do
	local now = 1_800_000_000_000
	local governor = Scheduler.new({ now_ms = function() return now end })
	local function enqueue(id, expiry)
		local accepted = governor:Enqueue({
			id = id,
			owner_id = id .. "-owner",
			lane = "normal",
			work_class = "maintenance",
			due_at_ms = now + 150,
			expires_at_ms = expiry,
		})
		assert(accepted.code == "accepted", "policy-rebuild fixture was not accepted: " .. id)
	end
	enqueue("terminal-index-rebuild-older", now + 200)
	enqueue("terminal-index-rebuild-ordinary", nil)
	enqueue("terminal-index-rebuild-newer", now + 200)
	local before = governor:Stats().policy
	local updated, update_error = governor:SetPolicy({
		revision = before.revision + 1,
		mode = before.mode,
	})
	assert(updated, "terminal-index policy revision update failed: " .. tostring(update_error))
	local empty, empty_status = governor:TakeNext()
	assert(empty == nil and empty_status == "empty",
		"future-due policy-rebuild fixture unexpectedly dispatched work")
	local order = governor.terminal_preflight_order
	assert(governor.terminal_preflight_policy_revision == governor.policy.revision
		and governor.terminal_preflight_count == 2
		and governor.terminal_preflight_tail == 2
		and order[1] == governor.known["terminal-index-rebuild-older"]
		and order[2] == governor.known["terminal-index-rebuild-newer"],
		"full policy-revision sweep did not rebuild the candidate index in queue order")
	now += 200
	local newer, newer_status = governor:TakeNext()
	assert(newer ~= nil and newer.id == "terminal-index-rebuild-newer" and newer_status == "expired",
		"rebuilt candidate index did not retain newest-first expiry order")
	local older, older_status = governor:TakeNext()
	assert(older ~= nil and older.id == "terminal-index-rebuild-older" and older_status == "expired",
		"rebuilt candidate index lost its earlier expiry")
end

do
	local now = 1_800_000_000_000
	local governor = Scheduler.new({ now_ms = function() return now end })
	local accepted = governor:Enqueue({
		id = "terminal-index-rescheduled",
		owner_id = "terminal-index-rescheduled-owner",
		lane = "normal",
		work_class = "maintenance",
		expires_at_ms = now + 100,
	})
	assert(accepted.code == "accepted", "rescheduled terminal-index fixture was not accepted")
	local item = governor.known["terminal-index-rescheduled"]
	assert(governor.terminal_preflight_count == 1 and governor.terminal_preflight_order[1] == item,
		"new expiring work was not added to the ordered preflight index")
	local selected, selected_status = governor:TakeNext()
	assert(selected == item and selected_status == "success",
		"unexpired terminal-index item was not selected")
	assert(governor.terminal_preflight_count == 0 and governor.terminal_preflight_order[1] == nil,
		"selection did not unlink the in-flight item from terminal preflight")
	local rescheduled, reschedule_error = governor:Reschedule(item.id, now + 50)
	assert(rescheduled, "terminal-index item could not be requeued: " .. tostring(reschedule_error))
	assert(governor.terminal_preflight_count == 1 and governor.terminal_preflight_order[2] == item,
		"retry requeue did not append the item back to the ordered preflight index")
	now += 100
	local expired, expired_status = governor:TakeNext()
	assert(expired == item and expired_status == "expired",
		"requeued candidate was not terminalized at its original expiry")
	assert(governor.terminal_preflight_count == 0,
		"requeued candidate remained in terminal preflight after expiry")
end

do
	local now = 1_800_000_000_000
	local governor = Scheduler.new({ now_ms = function() return now end })
	local stable = governor:Enqueue({
		id = "terminal-index-churn-stable",
		owner_id = "terminal-index-churn-stable-owner",
		lane = "normal",
		work_class = "maintenance",
		expires_at_ms = now + 1000,
	})
	assert(stable.code == "accepted", "stable terminal-index churn candidate was not accepted")
	local stable_item = governor.known["terminal-index-churn-stable"]

	for index = 1, 96 do
		local id = "terminal-index-churn-" .. tostring(index)
		local accepted = governor:Enqueue({
			id = id,
			owner_id = id .. "-owner",
			lane = "normal",
			work_class = "maintenance",
			expires_at_ms = now + 1,
		})
		assert(accepted.code == "accepted", "terminal-index churn candidate was not accepted")
		now += 1
		local expired, expired_status = governor:TakeNext()
		assert(expired ~= nil and expired.id == id and expired_status == "expired",
			"newest terminal-index churn candidate was not expired")
	end

	assert(governor.terminal_preflight_count == 1
		and governor.terminal_preflight_items[stable_item] == true
		and governor.terminal_preflight_order[1] == stable_item
		and governor.terminal_preflight_positions[stable_item] ~= nil,
		"terminal-index churn lost the long-lived candidate")
	assert(governor.terminal_preflight_tail <= 64,
		"terminal-index tombstones grew beyond the bounded compaction threshold")
	local indexed_count = 0
	for item in pairs(governor.terminal_preflight_items) do
		indexed_count += 1
		local position = governor.terminal_preflight_positions[item]
		assert(position ~= nil and governor.terminal_preflight_order[position] == item,
			"terminal-index churn left an item without a reciprocal order position")
	end
	assert(indexed_count == governor.terminal_preflight_count,
		"terminal-index churn left its item set and count inconsistent")
	for position = 1, governor.terminal_preflight_tail do
		local item = governor.terminal_preflight_order[position]
		if item ~= nil then
			assert(governor.terminal_preflight_items[item] == true
				and governor.terminal_preflight_positions[item] == position,
				"terminal-index churn left a stale or mismatched order entry")
		end
	end
end

print("[scheduler-bugfix] policy atomicity, incomplete admission estimates, and false-lane rejection passed.")
