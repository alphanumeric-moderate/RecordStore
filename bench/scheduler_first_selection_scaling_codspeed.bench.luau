--!strict

type ScheduledItem = {
	id: string,
	owner_id: string,
	lane: string,
	work_class: string,
	service_class: string,
	operation_class: string,
	available_at_ms: number?,
}

type EnqueueResult = {
	code: string,
	message: string?,
}

type GovernorStats = {
	policy: {
		revision: number,
	},
	queue_items: number,
}

type Governor = {
	SetPolicy: (self: Governor, patch: { [string]: unknown }) -> (boolean, string?),
	Stats: (self: Governor) -> GovernorStats,
	Enqueue: (self: Governor, item: ScheduledItem) -> EnqueueResult,
	TakeNext: (self: Governor, renewal_mode: boolean?) -> (ScheduledItem?, string),
}

type SchedulerModule = {
	new: (options: { now_ms: () -> number }) -> unknown,
}

local function expect(condition: boolean, message: string)
	if not condition then error(message, 2) end
end

local shim_value: unknown = require("./RobloxShim")
expect(type(shim_value) == "table", "RobloxShim did not return a table")
local shim = shim_value :: { [string]: unknown }
local load_scheduler_value = shim.load_scheduler
expect(type(load_scheduler_value) == "function", "RobloxShim.load_scheduler is unavailable")
local load_scheduler = load_scheduler_value :: () -> unknown

local module_value = load_scheduler()
expect(type(module_value) == "table", "embedded scheduler module is invalid")
local module_table = module_value :: { [string]: unknown }
expect(type(module_table.new) == "function", "embedded scheduler constructor is unavailable")
local scheduler_module = module_value :: SchedulerModule

local NOW_MS = 1_800_000_000_000
local QUEUE_SIZES = { 512, 2048, 8192 }
local ALGORITHMS = { "fifo", "drr" }
local READY_STRIDE = 4

local function build_queue(algorithm: string, queue_size: number): (Governor, number)
	local raw_governor = scheduler_module.new({
		now_ms = function()
			return NOW_MS
		end,
	})
	expect(type(raw_governor) == "table", "scheduler constructor did not return a table")
	local governor_table = raw_governor :: { [string]: unknown }
	for _, method_name in { "SetPolicy", "Stats", "Enqueue", "TakeNext" } do
		expect(type(governor_table[method_name]) == "function", "scheduler method is missing: " .. method_name)
	end
	local governor = raw_governor :: Governor
	local current_policy = governor:Stats().policy
	local configured, configure_message = governor:SetPolicy({
		revision = current_policy.revision + 1,
		algorithm = algorithm,
		queue_capacity = queue_size,
		max_per_owner_in_flight = 16,
	})
	expect(configured, "scheduler policy rejected: " .. tostring(configure_message))

	local ready_count = 0
	for index = 1, queue_size do
		local ready = index % READY_STRIDE == 0
		if ready then ready_count += 1 end
		local available_at = if ready then nil else NOW_MS + 60_000
		local owner_id = "owner-" .. tostring((index - 1) % 64 + 1)
		local result = governor:Enqueue({
			id = algorithm .. "-" .. tostring(queue_size) .. "-" .. tostring(index),
			owner_id = owner_id,
			lane = "normal",
			work_class = "profile",
			service_class = "normal",
			operation_class = "read",
			available_at_ms = available_at,
		})
		expect(result.code == "accepted",
			"queue construction failed at " .. tostring(index) .. ": " .. tostring(result.message))
	end
	expect(governor:Stats().queue_items == queue_size, "scheduler queue does not match requested depth")
	return governor, ready_count
end

local completed = 0
for _, algorithm in ALGORITHMS do
	for _, queue_size in QUEUE_SIZES do
		local governor, expected_ready = build_queue(algorithm, queue_size)
		local start = os.clock()
		local selected, status = governor:TakeNext(false)
		local elapsed_ms = (os.clock() - start) * 1000
		expect(selected ~= nil and status == "success", "high-depth ready queue failed to select work")
		local item = selected :: ScheduledItem
		expect(item.available_at_ms == nil or item.available_at_ms <= NOW_MS,
			"selector returned a future-blocked item")
		expect(expected_ready == math.floor(queue_size / READY_STRIDE),
			"ready-item count differs from constructed queue")
		expect(governor:Stats().queue_items == queue_size - 1,
			"selection did not remove exactly one queued item")
		completed += 1
		print(string.format(
			"[scheduler-first-selection] algorithm=%s queue=%d ready=%d take_next_ms=%.4f",
			algorithm,
			queue_size,
			expected_ready,
			elapsed_ms
		))
	end
end

expect(completed == #ALGORITHMS * #QUEUE_SIZES, "high-depth scheduler subset was incomplete")
print(string.format("[scheduler-first-selection] completed=%d", completed))
