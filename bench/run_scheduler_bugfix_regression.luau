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

print("[scheduler-acceptance] bounded fairness, low-budget reserve, throttle recovery, and lease-margin isolation passed.")

print("[scheduler-bugfix] policy atomicity, incomplete admission estimates, and false-lane rejection passed.")
