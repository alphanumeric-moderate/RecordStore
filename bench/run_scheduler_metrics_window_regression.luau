--!nocheck
local Scheduler = require("./RobloxShim").load_scheduler()
local task = require("@lune/task")

local now_ms = 1_800_000_000_000

local function new_scheduler()
	return Scheduler.new({
		now_ms = function()
			return now_ms
		end,
	})
end

local latency = new_scheduler()
for sample = 1, 300 do
	latency:Observe("update_async", true, sample)
end
local latency_stats = latency:Stats()
local update_stats = latency_stats.latency_percentiles_by_operation.update_async
assert(update_stats.count == 256, "operation latency window did not retain exactly 256 samples")
assert(update_stats.p50_ms == 172, "operation latency p50 changed after window wrap")
assert(update_stats.p95_ms == 288, "operation latency p95 changed after window wrap")
assert(update_stats.p99_ms == 298, "operation latency p99 changed after window wrap")

local renewal_advice = new_scheduler()
for sample = 1, 300 do
	renewal_advice:Observe("lease_renewal", true, sample)
end
assert(renewal_advice:LeaseRenewalAdvice().lease_renewal_p95_ms == 288,
	"lease advice did not use the most recent latency samples")

local queue = new_scheduler()
for sample = 1, 300 do
	now_ms += sample
	local enqueue_result = queue:Enqueue({
		id = "wait-" .. tostring(sample),
		owner_id = "wait-owner",
		lane = "normal",
		work_class = "normal",
		operation_class = "read",
		service_class = "normal",
	})
	assert(enqueue_result.code == "accepted", "queue-wait sample fixture was rejected")
	now_ms += sample
	local item, status = queue:TakeNext()
	assert(item ~= nil and status == "success" and item.id == "wait-" .. tostring(sample),
		"queue-wait sample fixture was not selected")
	assert(queue:MarkCompleted(item.id, "committed"), "queue-wait sample fixture did not complete")
end

local queue_stats = queue:Stats()
assert(queue_stats.scheduler.queue_wait_p50_ms == 172, "queue-wait p50 changed after window wrap")
assert(queue_stats.scheduler.queue_wait_p95_ms == 288, "queue-wait p95 changed after window wrap")
assert(queue_stats.scheduler.queue_wait_p99_ms == 298, "queue-wait p99 changed after window wrap")

local lane_stats = nil
for _, bucket in pairs(queue_stats.scheduler.by_lane_class) do
	if bucket.lane == "normal" and bucket.work_class == "normal" and bucket.service_class == "normal" then
		lane_stats = bucket
		break
	end
end
assert(lane_stats ~= nil and lane_stats.selected == 300, "lane wait history was not populated")
assert(lane_stats.p50_ms == 172 and lane_stats.p95_ms == 288 and lane_stats.p99_ms == 298,
	"lane wait percentiles changed after window wrap")

local dispatcher = Scheduler.new_dispatcher(new_scheduler(), {
	now_ms = function()
		return now_ms
	end,
})
for index = 1, 300 do
	local completed = false
	local result = dispatcher:Schedule(
		"batch-owner",
		"batch-" .. tostring(index),
		function()
			return { code = "success", processed_count = 1 }
		end,
		{
			lane = "normal",
			work_class = "maintenance",
			operation_class = "tracing",
			service_class = "normal",
			read_units = 0,
			write_units = 0,
			estimated_bytes = 1024,
			handler_slots = 1,
			batchable = true,
			batch_size = 1,
			batch_backlog = 1,
			batch_window_ms = 0,
			on_complete = function()
				completed = true
			end,
		}
	)
	assert(result.code == "accepted", "batch utilization fixture was rejected")
	for _ = 1, 200 do
		if completed then break end
		task.wait(0.001)
	end
	assert(completed, "batch utilization fixture did not finish")
end

local dispatcher_stats = dispatcher:Stats()
assert(dispatcher_stats.batch_utilization.samples == 256,
	"batch utilization window did not retain exactly 256 samples")
assert(dispatcher_stats.batch_utilization.average == 1,
	"batch utilization average changed after window wrap")
assert(dispatcher_stats.batch_utilization.p50 == 1
	and dispatcher_stats.batch_utilization.p95 == 1
	and dispatcher_stats.batch_utilization.p99 == 1,
	"batch utilization percentiles changed after window wrap")
dispatcher:Close()

print("[scheduler-metrics-window] bounded histories retained the newest 256 samples and preserved percentiles.")
