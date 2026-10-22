--!nocheck
-- Paired workload comparing inline work while disabled with dispatch through the enabled scheduler.
-- This measures local scheduler-dispatch overhead, not real Roblox DataStore latency.
local Shim = require("./RobloxShim")
local task = require("@lune/task")
local RecordStore = Shim.load()

local JOB_COUNT = 128
local COMPUTE_STEPS = 512
local MAX_WAIT_ITERATIONS = 6000

local function run_job(index)
	local value = index
	for step = 1, COMPUTE_STEPS do
		value = (value * 33 + step) % 10_000_019
	end
	return value
end

local function run(enabled)
	RecordStore.Mock.reset()
	local set_ok, set_message = RecordStore.set_scheduler_enabled(enabled)
	assert(set_ok, tostring(set_message))
	assert(RecordStore.get_scheduler_snapshot().enabled == enabled,
		"requested scheduler state did not match active rollout state")

	local completed = 0
	local checksum = 0

	local function finish_job(index)
		checksum += run_job(index)
		completed += 1
		return { code = "success" }
	end

	if not enabled then
		for index = 1, JOB_COUNT do
			finish_job(index)
		end
	else
		for index = 1, JOB_COUNT do
			local job_index = index
			local result = RecordStore.schedule_work(
				"overhead-owner-" .. tostring(job_index),
				"overhead-job-" .. tostring(job_index),
				function()
					return finish_job(job_index)
				end,
				{
					lane = "normal",
					work_class = "maintenance",
					operation_class = "tracing",
					read_units = 0,
					write_units = 0,
					estimated_bytes = 1024,
					handler_slots = 1,
				}
			)
			assert(result.code == "accepted",
				"scheduler rejected paired benchmark work: " .. tostring(result.code))
		end

		for _ = 1, MAX_WAIT_ITERATIONS do
			if completed == JOB_COUNT then break end
			task.wait(0.001)
		end
	end

	assert(completed == JOB_COUNT,
		string.format("workload completed %d of %d jobs", completed, JOB_COUNT))
	assert(checksum > 0, "workload checksum was not updated")
	print(string.format("[scheduler-overhead] mode=%s jobs=%d checksum=%d",
		if enabled then "enabled-dispatch" else "disabled-inline", completed, checksum))

	RecordStore.set_scheduler_enabled(false)
	RecordStore.Mock.reset()
	Shim.close()
end

return { run = run }
