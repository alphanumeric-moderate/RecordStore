--!nocheck
-- Guard that dispatch stays off the diagnostic snapshot path for regular and batchable work.
local Scheduler = require("../src/PlayerDataInitializer/RecordStoreScheduler")
local task = require("@lune/task")

local function run_case(batchable)
	local now_ms = 1_800_000_000_000
	local governor = Scheduler.new({
		now_ms = function() return now_ms end,
		advance_ms = function(milliseconds) now_ms += milliseconds end,
	})
	local dispatcher = Scheduler.new_dispatcher(governor, {
		now_ms = function() return now_ms end,
	})

	governor.Stats = function()
		error("dispatcher hot path must not build a diagnostic Stats snapshot")
	end

	local completed = false
	local options = {
		lane = "normal",
		work_class = "maintenance",
		operation_class = "tracing",
		read_units = 0,
		write_units = 0,
		estimated_bytes = 1024,
		handler_slots = 1,
	}
	if batchable then
		options.batchable = true
		options.batch_size = 1
		options.batch_backlog = 1
		options.batch_window_ms = 0
	end

	local result = dispatcher:Schedule(
		"hot-path-owner",
		if batchable then "batchable-job" else "regular-job",
		function()
			completed = true
			return { code = "success" }
		end,
		options
	)
	assert(result.code == "accepted", "scheduler rejected a valid hot-path fixture")

	for _ = 1, 2000 do
		if completed then break end
		task.wait(0.001)
	end
	assert(completed, "scheduler did not complete valid hot-path fixture")
	dispatcher:Close()
end

local renewal_governor = Scheduler.new({ now_ms = function() return 1_800_000_000_000 end })
renewal_governor:Observe("lease_renewal", true, 100)
renewal_governor:Observe("lease_renewal", true, 200)
renewal_governor:Observe("update_async", true, 80)
renewal_governor.latency_ewma.service = 50
renewal_governor.Stats = function()
	error("lease renewal timing must not build a full diagnostic Stats snapshot")
end
local renewal_advice = renewal_governor:LeaseRenewalAdvice()
assert(renewal_advice.lease_renewal_p95_ms == 200, "renewal advice returned the wrong P95")
assert(renewal_advice.update_async_p95_ms == 80, "renewal advice returned the wrong UpdateAsync P95")
assert(renewal_advice.lease_renewal_ewma_ms == 120, "renewal advice returned the wrong renewal EWMA")
assert(renewal_advice.service_ewma_ms == 50, "renewal advice returned the wrong service EWMA")
assert(renewal_advice.oldest_eligible_age_ms == 0, "empty queue must have zero eligible age")

run_case(false)
run_case(true)
print("[scheduler-hot-path] dispatch and renewal timing avoided full diagnostic snapshots.")
