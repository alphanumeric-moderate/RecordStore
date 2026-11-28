--!nocheck
-- Profiles first-selection cost at increasing queue depths and readiness ratios.
-- Queue construction is deliberately outside the timed TakeNext interval.
local Scheduler = require("./RobloxShim").load_scheduler()

local QUEUE_SIZES = { 128, 512, 2048, 8192 }
local READY_SCENARIOS = {
	{ name = "all-ready", stride = 1, ready_count = function(count) return count end, expect_selection = true },
	{ name = "quarter-ready", stride = 4, ready_count = function(count) return math.floor(count / 4) end, expect_selection = true },
	{ name = "none-ready", stride = math.huge, ready_count = function(_count) return 0 end, expect_selection = false },
	{ name = "owner-saturated", stride = 1, ready_count = function(count) return count end, owner_saturated = true, expect_selection = false },
	{ name = "dependency-heavy", stride = 2, ready_count = function(count) return math.ceil(count / 2) end, dependency_pairs = true, inheritable = true, expect_selection = true },
	{ name = "non-inheritable-dependency-heavy", stride = 2, ready_count = function(count) return math.ceil(count / 2) end, dependency_pairs = true, expect_selection = true },
}
local ALGORITHMS = { "fifo", "weighted", "deadline", "drr" }
-- Keep the complete policy/workload matrix at small queue depths. Larger queues
-- focus on readiness extremes; 8192-item runs compare FIFO with DRR only.
local REPEATS = 1

local function should_benchmark(algorithm: string, scenario: any, queue_size: number): boolean
	if queue_size <= 512 then
		return true
	end
	if scenario.name ~= "all-ready" and scenario.name ~= "none-ready" then
		return false
	end
	if queue_size == 2048 then
		return true
	end
	return queue_size == 8192 and (algorithm == "fifo" or algorithm == "drr")
end
local NOW_MS = 1_800_000_000_000

local function enqueue_profile_item(
	governor: any,
	id: string,
	owner_id: string,
	available_at_ms: number?,
	lane: string?
)
	local accepted = governor:Enqueue({
		id = id,
		owner_id = owner_id,
		lane = lane or "normal",
		service_class = if lane == "high" then "interactive" else "normal",
		work_class = "profile",
		operation_class = "read",
		read_units = 1,
		write_units = 0,
		estimated_bytes = 1024,
		handler_slots = 1,
		available_at_ms = available_at_ms,
	})
	assert(accepted.code == "accepted",
		("enqueue failed for %s: %s"):format(id, tostring(accepted.message)))
end

local function enqueue_dependent(
	governor: any,
	id: string,
	owner_id: string,
	prerequisite_id: string,
	inheritable: boolean
)
	local accepted = governor:Enqueue({
		id = id,
		owner_id = owner_id,
		lane = "high",
		service_class = if inheritable then "interactive" else "normal",
		work_class = "profile",
		operation_class = "read",
		read_units = 1,
		write_units = 0,
		estimated_bytes = 1024,
		handler_slots = 1,
		dependencies = { prerequisite_id },
	})
	assert(accepted.code == "accepted",
		("dependent enqueue failed for %s: %s"):format(id, tostring(accepted.message)))
end

local function build_queue(algorithm: string, count: number, scenario: any)
	local governor = Scheduler.new({
		now_ms = function() return NOW_MS end,
	})
	local policy = governor:Stats().policy
	local blocker_count = if scenario.owner_saturated then 16 else 0
	local configured, configure_message = governor:SetPolicy({
		revision = policy.revision + 1,
		algorithm = algorithm,
		queue_capacity = math.max(count, blocker_count),
		max_per_owner_in_flight = 1,
	})
	assert(configured, "scheduler policy rejected: " .. tostring(configure_message))

	if scenario.owner_saturated then
		for owner_index = 1, blocker_count do
			enqueue_profile_item(governor,
				("blocker-%s-%d"):format(algorithm, owner_index),
				"held-owner-" .. tostring(owner_index),
				nil
			)
		end
		local blocked_owners = {}
		for _ = 1, blocker_count do
			local selected, status = governor:TakeNext(false)
			assert(selected ~= nil and status == "success",
				"could not occupy an owner in-flight slot for the saturated case")
			assert(string.sub(selected.owner_id, 1, 11) == "held-owner-"
				and blocked_owners[selected.owner_id] ~= true,
				"blocker selection did not occupy a distinct configured owner")
			blocked_owners[selected.owner_id] = true
		end
	end

	local expected_ready = 0
	for index = 1, count do
		local ready = if scenario.dependency_pairs then index % 2 == 1
			else scenario.stride == 1 or (scenario.stride ~= math.huge and index % scenario.stride == 0)
		if ready then expected_ready += 1 end
		local owner_id = if scenario.owner_saturated
			then "held-owner-" .. tostring((index - 1) % blocker_count + 1)
			elseif scenario.dependency_pairs
				then "dependency-owner-" .. tostring(math.floor((index + 1) / 2))
			else "owner-" .. tostring((index - 1) % 64 + 1)
		local item_id = algorithm .. "-" .. tostring(count) .. "-" .. scenario.name .. "-" .. tostring(index)
		if scenario.dependency_pairs then
			local prerequisite_index = if index % 2 == 1 then index else index - 1
			local prerequisite_id = algorithm .. "-" .. tostring(count) .. "-" .. scenario.name .. "-prerequisite-" .. tostring(math.floor((prerequisite_index + 1) / 2))
			if index % 2 == 1 then
				enqueue_profile_item(governor, prerequisite_id, owner_id, nil, "background")
			else
				enqueue_dependent(governor, item_id, owner_id, prerequisite_id, scenario.inheritable == true)
			end
		else
			enqueue_profile_item(
				governor,
				item_id,
				owner_id,
				if ready then nil else NOW_MS + 60_000
			)
		end
	end
	assert(governor:Stats().queue_items == count, "scheduler queue size differs from the requested depth")
	return governor, expected_ready
end

local result_count = 0
for _, algorithm in ipairs(ALGORITHMS) do
	for _, scenario in ipairs(READY_SCENARIOS) do
		for _, queue_size in ipairs(QUEUE_SIZES) do
			if should_benchmark(algorithm, scenario, queue_size) then
				local total_seconds = 0
				for repeat_index = 1, REPEATS do
					local governor, expected_ready = build_queue(algorithm, queue_size, scenario)
					local start = os.clock()
					local selected, status = governor:TakeNext(false)
					local elapsed = os.clock() - start
					total_seconds += elapsed

					if scenario.expect_selection then
						assert(expected_ready > 0 and selected ~= nil and status == "success",
							"ready workload failed to select an item")
						assert((selected.available_at_ms or 0) <= NOW_MS,
							"selector returned an item that was not ready")
						if scenario.dependency_pairs then
							assert(selected.lane == "background" and #(selected.dependencies or {}) == 0,
								"dependency-heavy workload selected a blocked dependent")
						end
						assert(expected_ready == scenario.ready_count(queue_size),
							"scenario readiness diagnostic differs from the built queue")
						assert(governor:Stats().queue_items == queue_size - 1,
							"successful selection did not remove exactly one queue item")
					else
						assert(selected == nil and status == "empty",
							"fully blocked workload unexpectedly selected an item")
						assert(governor:Stats().queue_items == queue_size,
							"blocked selection changed the queue")
					end
				end
				result_count += 1
				print(string.format(
					"[scheduler-backlog] algorithm=%s scenario=%s queue=%d ready=%d repeats=%d take_next_ms=%.4f",
					algorithm,
					scenario.name,
					queue_size,
					scenario.ready_count(queue_size),
					REPEATS,
					total_seconds / REPEATS * 1000
				))
			end
		end
	end
end

assert(result_count == 60,
	"scheduler backlog matrix did not complete its 60 expected workloads")
print(string.format("[scheduler-backlog] completed=%d", result_count))
