--!nocheck
local Scheduler = require("./RobloxShim").load_scheduler()

local ITERATIONS = 50000
local governor = Scheduler.new({
	now_ms = function()
		return 1_800_000_000_000
	end,
})

for sample = 1, ITERATIONS do
	governor:Observe("update_async", true, sample % 100 + 1)
end

local stats = governor:Stats()
local update_stats = stats.latency_percentiles_by_operation.update_async
assert(update_stats.count == 256, "operation latency window exceeded its capacity")
assert(update_stats.p95_ms >= 1 and update_stats.p95_ms <= 100, "invalid operation latency percentile")
