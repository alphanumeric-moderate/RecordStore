--!nocheck
local Shim = require("./RobloxShim")
local RecordStore = Shim.load()
local initializer = Shim.environment.game:GetService("ServerScriptService"):WaitForChild("PlayerDataInitializer")
local V1Module = Shim.environment.require(initializer:WaitForChild("RecordStoreV1"))
local V1 = V1Module.new(RecordStore, RecordStore.Mailbox)

local TRACE_COUNT = 40000
local TRACE_CAPACITY = 2048
local CACHE_COUNT = 20000
local CACHE_CAPACITY = 128

local function run_trace_ring()
	local next_id = 0
	local tracer = V1.Tracing.new({
		max_events = TRACE_CAPACITY,
		success_sample_every = 1,
		new_event_id = function()
			next_id += 1
			return string.format("trace-%08d", next_id)
		end,
	})

	for index = 1, TRACE_COUNT do
		local accepted = tracer:Emit({
			operation_id = "operation-" .. tostring(index % 16),
			component = "profile",
			operation = "read",
			result = "unknown",
			duration_ms = index % 100,
			timestamp_unix = 1_800_000_000,
		})
		assert(accepted == true, "trace workload rejected an event")
	end

	local stats = tracer:Stats()
	assert(stats.retained == TRACE_CAPACITY, "trace workload retained an incorrect number of events")
	assert(stats.dropped == TRACE_COUNT - TRACE_CAPACITY, "trace workload dropped an incorrect number of events")

	local local_trace = tracer:GetOperationTrace("operation-1", 256)
	assert(local_trace.code == "success" and #local_trace.events == TRACE_CAPACITY / 16,
		"trace workload query returned an incorrect number of events")

	local first_retained = TRACE_COUNT - TRACE_CAPACITY + 1
	local checksum = 0
	local drained = 0
	while drained < TRACE_CAPACITY do
		local batch = tracer:Drain(math.min(256, TRACE_CAPACITY - drained))
		assert(#batch > 0 and #batch <= 256, "trace workload Drain returned an invalid batch")
		for index, event in ipairs(batch) do
			assert(event.sequence == first_retained + drained + index - 1,
				"trace workload Drain changed retained-event order")
			checksum += event.sequence
		end
		drained += #batch
	end
	assert(drained == TRACE_CAPACITY, "trace workload Drain did not return the full retained window")
	local expected = (first_retained + TRACE_COUNT) * TRACE_CAPACITY / 2
	assert(checksum == expected, "trace workload checksum mismatch")
	assert(tracer:Stats().retained == 0, "trace workload failed to drain its retained events")
	print(string.format("[v1-trace-ring] events=%d capacity=%d dropped=%d checksum=%.0f",
		TRACE_COUNT, TRACE_CAPACITY, stats.dropped, checksum))
end

local function run_read_coalescer()
	local fetch_count = 0
	local cache = V1.ReadCoalescer.new(function(key)
		fetch_count += 1
		return { key = key, payload = { serial = fetch_count } }
	end, {
		ttl_seconds = 60,
		max_entries = CACHE_CAPACITY,
	})

	local checksum = 0
	for index = 1, CACHE_COUNT do
		local key = string.format("entry-%05d", index)
		local value = cache:GetAsync(key, "session-fence")
		assert(value ~= nil and value.key == key and value.payload.serial == index,
			"read-coalescer workload returned incorrect fetched data")
		checksum += value.payload.serial
	end
	assert(fetch_count == CACHE_COUNT, "read-coalescer workload did not fetch each unique key exactly once")

	for index = CACHE_COUNT - CACHE_CAPACITY + 1, CACHE_COUNT do
		local key = string.format("entry-%05d", index)
		local value = cache:GetAsync(key, "session-fence")
		assert(value ~= nil and value.payload.serial == index, "read-coalescer workload missed a retained cache entry")
		value.payload.serial = -index
		local unchanged = cache:GetAsync(key, "session-fence")
		assert(unchanged ~= nil and unchanged.payload.serial == index,
			"read-coalescer workload exposed a cached value to caller mutation")
		checksum += unchanged.payload.serial
	end

	local oldest = cache:GetAsync("entry-00001", "session-fence")
	assert(oldest ~= nil and oldest.payload.serial == CACHE_COUNT + 1,
		"read-coalescer workload did not refresh an evicted entry")
	checksum += oldest.payload.serial

	local stats = cache:Stats()
	assert(stats.entries == CACHE_CAPACITY, "read-coalescer workload exceeded its configured cache capacity")
	assert(stats.evictions == CACHE_COUNT - CACHE_CAPACITY + 1,
		"read-coalescer workload reported an incorrect number of evictions")
	assert(fetch_count == CACHE_COUNT + 1, "read-coalescer workload performed unexpected fetches")

	local expected = CACHE_COUNT * (CACHE_COUNT + 1) / 2
	for index = CACHE_COUNT - CACHE_CAPACITY + 1, CACHE_COUNT do expected += index end
	expected += CACHE_COUNT + 1
	assert(checksum == expected, "read-coalescer workload checksum mismatch")
	print(string.format("[v1-read-coalescer] requests=%d capacity=%d evictions=%d checksum=%.0f",
		CACHE_COUNT, CACHE_CAPACITY, stats.evictions, checksum))
end

return {
	run_trace_ring = run_trace_ring,
	run_read_coalescer = run_read_coalescer,
}
