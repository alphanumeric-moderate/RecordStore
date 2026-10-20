--!nocheck
-- Fixed synthetic workload for the server-local advanced scheduler.
-- This measures local selection cost only, not Roblox DataStore request latency.
local Scheduler = require("../src/PlayerDataInitializer/RecordStoreScheduler")

local ITEM_COUNT = 256
local OWNER_COUNT = 16
local now_ms = 1_800_000_000_000

local function run_algorithm(algorithm)
	local start_ms = now_ms
	local governor = Scheduler.new({
		now_ms = function() return now_ms end,
	})
	local policy = governor:Stats().policy
	local ok, message = governor:SetPolicy({
		revision = policy.revision + 1,
		algorithm = algorithm,
		max_per_owner_in_flight = 4,
		drr_quantum = 4,
		max_item_cost = 64,
	})
	assert(ok, tostring(message))
	for index = 1, ITEM_COUNT do
		local owner = "owner-" .. tostring((index - 1) % OWNER_COUNT)
		local lane = if index % 29 == 0 then "high" elseif index % 5 == 0 then "background" else "normal"
		local service_class = if index % 17 == 0 then "critical"
			elseif index % 7 == 0 then "interactive"
			elseif index % 5 == 0 then "bulk" else "normal"
		local cost = if index % 11 == 0 then 8 else if index % 3 == 0 then 4 else 1
		local accepted = governor:Enqueue({
			id = algorithm .. "-" .. tostring(index),
			owner_id = owner,
			lane = lane,
			service_class = service_class,
			work_class = if index % 2 == 0 then "profile" else "maintenance",
			operation_class = if index % 4 == 0 then "update_async" else "read",
			read_units = cost,
			write_units = if index % 4 == 0 then 1 else 0,
			estimated_bytes = 512 + index % 2048,
			handler_slots = 1,
			deadline_ms = if index % 13 == 0 then now_ms + index * 3 else nil,
		})
		assert(accepted.code == "accepted", "scheduler refused benchmark work")
	end
	local selected = 0
	local selected_by_owner, last_selected_by_owner = {}, {}
	local max_owner_gap_ms = 0
	while true do
		local item = governor:TakeNext(false)
		if item == nil then break end
		selected += 1
		local owner = item.owner_id
		selected_by_owner[owner] = (selected_by_owner[owner] or 0) + 1
		local previous_owner_selection = last_selected_by_owner[owner]
		if previous_owner_selection ~= nil then
			max_owner_gap_ms = math.max(max_owner_gap_ms, now_ms - previous_owner_selection)
		end
		last_selected_by_owner[owner] = now_ms
		assert(governor:MarkCompleted(item.id, "committed"))
		-- Deterministic virtual service time makes queue wait percentiles and
		-- per-owner service gaps observable, unlike a zero-duration drain.
		now_ms += math.max(1, item.admission_cost or item.cost or 1) * 40
	end
	assert(selected == ITEM_COUNT, algorithm .. " selected an incomplete workload")
	local stats = governor:Stats()
	assert(stats.queue_items == 0, algorithm .. " left queued work behind")
	for owner_index = 0, OWNER_COUNT - 1 do
		local owner = "owner-" .. tostring(owner_index)
		assert(selected_by_owner[owner] == ITEM_COUNT / OWNER_COUNT,
			algorithm .. " provided unequal completion counts for " .. owner)
	end
	local elapsed_ms = now_ms - start_ms
	assert(stats.scheduler.queue_wait_p50_ms > 0, algorithm .. " did not measure virtual queue wait")
	assert(stats.scheduler.queue_wait_p95_ms >= stats.scheduler.queue_wait_p50_ms
		and stats.scheduler.queue_wait_p99_ms >= stats.scheduler.queue_wait_p95_ms,
		algorithm .. " reported inconsistent queue wait percentiles")
	assert(stats.scheduler.queue_wait_p99_ms < elapsed_ms,
		algorithm .. " queue-wait p99 exceeded the total virtual workload duration")
	assert(max_owner_gap_ms < elapsed_ms * 0.75,
		algorithm .. " starved an owner for most of the virtual workload")
	print(string.format(
		"[scheduler-bench] algorithm=%s selected=%d elapsed_ms=%d wait_p50_ms=%d wait_p95_ms=%d wait_p99_ms=%d max_owner_gap_ms=%d",
		algorithm, selected, elapsed_ms,
		stats.scheduler.queue_wait_p50_ms, stats.scheduler.queue_wait_p95_ms,
		stats.scheduler.queue_wait_p99_ms, max_owner_gap_ms
	))
	return stats
end

local function run_all()
	local baseline = run_algorithm("fifo")
	local weighted = run_algorithm("weighted")
	local deadline = run_algorithm("deadline")
	local drr = run_algorithm("drr")
	assert(baseline.stats.completed == ITEM_COUNT)
	assert(weighted.stats.completed == ITEM_COUNT)
	assert(deadline.stats.completed == ITEM_COUNT)
	assert(drr.stats.completed == ITEM_COUNT)
end

return {
	run = run_algorithm,
	run_all = run_all,
}
