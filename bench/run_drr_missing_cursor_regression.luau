--!strict

type ScheduledItem = {
	id: string,
	owner_id: string,
	lane: string,
	work_class: string,
	service_class: string,
	operation_class: string,
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
	MarkCompleted: (self: Governor, id: string, outcome: string) -> (boolean, string?),
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

local raw_governor = scheduler_module.new({
	now_ms = function()
		return 1_800_000_000_000
	end,
})
expect(type(raw_governor) == "table", "scheduler constructor did not return a table")
local governor_table = raw_governor :: { [string]: unknown }
for _, method_name in { "SetPolicy", "Stats", "Enqueue", "TakeNext", "MarkCompleted" } do
	expect(type(governor_table[method_name]) == "function", "scheduler method is missing: " .. method_name)
end
local governor = raw_governor :: Governor

local function enqueue(owner_id: string, id: string)
	local result = governor:Enqueue({
		id = id,
		owner_id = owner_id,
		lane = "normal",
		work_class = "missing-cursor",
		service_class = "normal",
		operation_class = "read",
	})
	expect(result.code == "accepted", "scheduler rejected " .. id .. ": " .. tostring(result.message))
end

local function take(expected_id: string): ScheduledItem
	local item, status = governor:TakeNext(false)
	expect(item ~= nil and status == "success", "expected a selectable item " .. expected_id)
	local selected = item :: ScheduledItem
	expect(selected.id == expected_id, "expected " .. expected_id .. ", got " .. selected.id)
	return selected
end

local initial_stats = governor:Stats()
local configured, configure_message = governor:SetPolicy({
	revision = initial_stats.policy.revision + 1,
	algorithm = "drr",
})
expect(configured, "DRR policy was rejected: " .. tostring(configure_message))

enqueue("owner-b", "cursor-b")
local cursor_item = take("cursor-b")
expect(governor:MarkCompleted(cursor_item.id, "committed"), "cursor lane did not complete")

enqueue("owner-a", "cursor-a")
enqueue("owner-c", "cursor-c")
expect(governor:Stats().queue_items == 2, "live lanes on both sides of the drained cursor were not retained")

local first_live = take("cursor-a")
expect(governor:Stats().queue_items == 1, "first-live-lane selection removed an unexpected item")
expect(governor:MarkCompleted(first_live.id, "committed"), "first live DRR lane did not complete")
local second_live = take("cursor-c")
expect(governor:MarkCompleted(second_live.id, "committed"), "second live DRR lane did not complete")

print("[drr-missing-cursor] two live lanes straddling a stale cursor selected the first lexical lane.")
