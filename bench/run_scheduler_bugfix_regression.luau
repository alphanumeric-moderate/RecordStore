--!nocheck
-- Regression checks for previously fixed scheduler admission and policy-update bugs.
local Scheduler = require("../src/PlayerDataInitializer/RecordStoreScheduler")

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

print("[scheduler-bugfix] policy atomicity, incomplete admission estimates, and false-lane rejection passed.")
