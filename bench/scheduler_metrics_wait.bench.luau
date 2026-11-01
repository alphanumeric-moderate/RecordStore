--!nocheck
local Scheduler = require("./RobloxShim").load_scheduler()

local ITERATIONS = 5000
local now_ms = 1_800_000_000_000
local governor = Scheduler.new({
	now_ms = function()
		return now_ms
	end,
})

for sample = 1, ITERATIONS do
	now_ms += 1
	local result = governor:Enqueue({
		id = "wait-" .. tostring(sample),
		owner_id = "wait-owner",
		lane = "normal",
		work_class = "normal",
		operation_class = "read",
		service_class = "normal",
	})
	assert(result.code == "accepted")
	now_ms += 1
	local item, status = governor:TakeNext()
	assert(item ~= nil and status == "success")
	assert(governor:MarkCompleted(item.id, "committed"))
end

local stats = governor:Stats()
assert(stats.scheduler.queue_wait_p50_ms == 1)
