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

print("[scheduler-bugfix] policy atomicity, incomplete admission estimates, and false-lane rejection passed.")
