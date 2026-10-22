--!nocheck
-- Paired local CPU workload for the full diagnostic snapshot and renewal-only advice.
local Scheduler = require("../src/PlayerDataInitializer/RecordStoreScheduler")

local SAMPLE_COUNT = 256
local OPERATION_COUNT = 12
local ITERATIONS = 512
local now_ms = 1_800_000_000_000

local function make_governor()
	local governor = Scheduler.new({
		now_ms = function() return now_ms end,
	})
	for operation_index = 1, OPERATION_COUNT do
		local operation = if operation_index == 1 then "lease_renewal"
			elseif operation_index == 2 then "update_async"
			elseif operation_index == 3 then "read"
			else "synthetic_operation_" .. tostring(operation_index)
		for sample_index = 1, SAMPLE_COUNT do
			local latency_ms = (operation_index * 17 + sample_index * 13) % 500 + 1
			governor:Observe(operation, true, latency_ms, nil, 1024)
		end
	end
	return governor
end

local function run(mode)
	local governor = make_governor()
	local checksum = 0
	if mode == "snapshot" then
		for _ = 1, ITERATIONS do
			local stats = governor:Stats()
			checksum += stats.latency_percentiles_by_operation.lease_renewal.p95_ms
		end
	else
		for _ = 1, ITERATIONS do
			local advice = governor:LeaseRenewalAdvice()
			checksum += advice.lease_renewal_p95_ms
		end
	end
	assert(checksum > 0, mode .. " benchmark did not consume the measured result")
	print(string.format("[lease-renewal-advice] mode=%s iterations=%d samples_per_operation=%d checksum=%d",
		mode, ITERATIONS, SAMPLE_COUNT, checksum))
end

return { run = run }
