--!nocheck
-- Successful-path scheduler and read-cache benchmark, without fault injection.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Shim = require("./RobloxShim")
local RecordStore = Shim.load()
local MailboxV2 = luau.load(fs.readFile("src/PlayerDataInitializer/RecordStoreMailboxV2.luau"), { debugName = "RecordStoreMailboxV2", environment = Shim.environment })()
local V2 = luau.load(fs.readFile("src/PlayerDataInitializer/RecordStoreV2.luau"), { debugName = "RecordStoreV2", environment = Shim.environment })().new(RecordStore, MailboxV2, { allow_unattested_activation = true })

-- Exercise the actual core request gate with successful callbacks only.
local runtime_code, runtime_error = RecordStore.configure_runtime({
	revision = 2,
	runtime_profile = "balanced",
	server_role = "benchmark",
	adaptive_runtime_enabled = true,
	adaptive_min_concurrent_requests = 1,
	adaptive_max_concurrent_requests = 4,
	critical_request_reserve = 1,
	adaptive_queue_budget_share = 0.2,
})
assert(runtime_code == "success", tostring(runtime_error))
for index = 1, 512 do
	local value, code, message = RecordStore.run_runtime_request("read", function()
		return index
	end, 2, "interactive")
	assert(code == nil and value == index, tostring(code) .. " " .. tostring(message))
end
local runtime_stats = RecordStore.get_runtime_stats()
assert(runtime_stats.active_requests == 0)
assert(runtime_stats.effective_concurrent_requests >= 1 and runtime_stats.effective_concurrent_requests <= 4)
assert(runtime_stats.metrics.reads >= 512)

local now = 1000
local governor = V2.RuntimeGovernor.new({ now_ms = function() return now end, advance_ms = function(ms) now += ms end })
for index = 1, 500 do
	local lane = if index % 10 == 0 then "high" elseif index % 5 == 0 then "background" else "normal"
	assert(governor:Enqueue({ id = "scheduled-" .. index, owner_id = "owner-" .. (index % 73), lane = lane, cost = 1, due_at_ms = 1000 + (index % 3) }).code == "accepted")
end
-- The mock clock is deterministic; advance to the last scheduled due time before draining.
now += 2
local taken = 0
for _ = 1, 500 do if governor:TakeNext() then taken += 1 end end
assert(taken == 500)

local tracer = V2.Tracing.new({ max_events = 512, success_sample_every = 1 })
for index = 1, 500 do
	tracer:Emit({ operation_id = "op-" .. (index % 64), component = "benchmark", operation = "scheduled", result = "success", duration_ms = index % 100 })
end
assert(#tracer:GetOperationTrace("op-1").events > 0)

local reads = 0
local coalescer = V2.ReadCoalescer.new(function(key)
	reads += 1
	return { key = key, value = 42 }
end, { ttl_seconds = 60, max_entries = 128 })
local first_read = coalescer:GetAsync("profile-1")
local second_read = coalescer:GetAsync("profile-1")
assert(first_read.key == "profile-1" and first_read.value == 42)
assert(second_read.key == "profile-1" and second_read.value == 42)
assert(reads == 2, "read coalescer retained a completed result instead of fetching fresh state")
assert(coalescer:Stats().completed_cache_entries == 0)

local payload = { items = {} }
for index = 1, 100 do table.insert(payload.items, { id = index, description = string.rep("record-store", 8) }) end
local size = V2.Maintenance.AssessPayload(payload)
assert(size.estimated_bytes > 0)
assert(V2.Maintenance.ShouldSave({ state = "active", dirty = 0 }).code == "skip")

print("[PASS] RecordStoreV2 governor, trace and read-cache workload.")
Shim.close()
