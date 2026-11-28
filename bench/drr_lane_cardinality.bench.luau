--!strict
-- Measures DRR first-selection cost across queue depth and distinct lane cardinality.
-- Queue construction is intentionally outside the timed TakeNext interval.

type ScheduledItem = {
	id: string,
	owner_id: string,
	lane: string,
	work_class: string,
	service_class: string,
	operation_class: string,
	cost: number,
}

type EnqueueResult = {
	code: string,
	message: string?,
}

type Governor = {
	SetPolicy: (self: Governor, patch: { [string]: unknown }) -> (boolean, string?),
	Enqueue: (self: Governor, item: ScheduledItem) -> unknown,
	TakeNext: (self: Governor, renewal_mode: boolean?) -> (unknown, string),
	MarkCompleted: (self: Governor, id: string, outcome: string) -> (boolean, string?),
}

type SchedulerModule = {
	new: (options: { now_ms: () -> number }) -> unknown,
}

type ShimModule = {
	load_scheduler: () -> unknown,
}

local shim_value: unknown = require("./RobloxShim")
if type(shim_value) ~= "table" then
	error("RobloxShim did not return a table")
end
local shim_fields = shim_value :: { [string]: unknown }
if type(shim_fields.load_scheduler) ~= "function" then
	error("RobloxShim does not expose load_scheduler")
end
local shim = shim_value :: ShimModule
local scheduler_value = shim.load_scheduler()
if type(scheduler_value) ~= "table" then
	error("embedded scheduler module is invalid")
end
local scheduler_fields = scheduler_value :: { [string]: unknown }
if type(scheduler_fields.new) ~= "function" then
	error("embedded scheduler module does not expose new")
end
local scheduler_module = scheduler_value :: SchedulerModule

local NOW_MS = 1_800_000_000_000
local QUEUE_SIZES = { 128, 512, 2048, 8192 }
local LANE_COUNTS = { 1, 8, 64, 512, 2048 }
local SAMPLE_COUNT = 5

local function build_governor(queue_size: number, lane_count: number): Governor
	local raw_governor = scheduler_module.new({
		now_ms = function()
			return NOW_MS
		end,
	})
	if type(raw_governor) ~= "table" then
		error("scheduler constructor did not return a table")
	end
	local governor_fields = raw_governor :: { [string]: unknown }
	for _, method_name in { "SetPolicy", "Enqueue", "TakeNext", "MarkCompleted" } do
		if type(governor_fields[method_name]) ~= "function" then
			error("scheduler instance is missing method " .. method_name)
		end
	end
	local governor = raw_governor :: Governor
	local configured, configure_error = governor:SetPolicy({
		revision = 2,
		algorithm = "drr",
		queue_capacity = queue_size,
		drr_quantum = 4,
		max_item_cost = 32,
	})
	if not configured then
		error("DRR benchmark policy was rejected: " .. tostring(configure_error))
	end

	for index = 1, queue_size do
		local lane_index = (index - 1) % lane_count + 1
		local raw_result = governor:Enqueue({
			id = "drr-lane-cardinality-" .. tostring(index),
			owner_id = "lane-owner-" .. string.format("%04d", lane_index),
			lane = "normal",
			work_class = "critical",
			service_class = "best_effort",
			operation_class = "tracing",
			cost = 1,
		})
		if type(raw_result) ~= "table" then
			error("DRR benchmark enqueue did not return a result")
		end
		local result = raw_result :: { [string]: unknown }
		if result.code ~= "accepted" then
			error("DRR benchmark enqueue failed: " .. tostring(result.message))
		end
	end
	return governor
end

local function median(values: { number }): number
	table.sort(values)
	return values[math.floor((#values + 1) / 2)]
end

local result_count = 0
for _, queue_size in QUEUE_SIZES do
	for _, requested_lanes in LANE_COUNTS do
		if requested_lanes <= queue_size then
			local samples: { number } = {}
			for sample_index = 1, SAMPLE_COUNT do
				local governor = build_governor(queue_size, requested_lanes)
				local started = os.clock()
				local raw_selected, status = governor:TakeNext(false)
				local elapsed_us = (os.clock() - started) * 1_000_000
				if type(raw_selected) ~= "table" or status ~= "success" then
					error("DRR benchmark failed to select a ready item")
				end
				local selected = raw_selected :: { [string]: unknown }
				if type(selected.id) ~= "string" then
					error("DRR benchmark selection returned an invalid item identity")
				end
				if not governor:MarkCompleted(selected.id, "committed") then
					error("DRR benchmark selected item did not complete")
				end
				samples[sample_index] = elapsed_us
			end
			result_count += 1
			print(string.format(
				"[drr-lane-cardinality] queue=%d distinct_lanes=%d samples=%d median_take_next_us=%.3f",
				queue_size,
				requested_lanes,
				SAMPLE_COUNT,
				median(samples)
			))
		end
	end
end

assert(result_count == 17, "DRR lane-cardinality matrix did not complete every valid shape")
print(string.format("[drr-lane-cardinality] completed=%d", result_count))
