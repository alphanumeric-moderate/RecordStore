--!nocheck
local Shim = require("./RobloxShim")
local RecordStore = Shim.load()
local initializer = Shim.environment.game:GetService("ServerScriptService"):WaitForChild("PlayerDataInitializer")
local V2Module = Shim.environment.require(initializer:WaitForChild("RecordStoreV2"))
local V2 = V2Module.new(RecordStore, RecordStore.MailboxV2)

local function expect(value, message)
	assert(value, message)
end

local trace_id = 0
local tracer = V2.Tracing.new({
	max_events = 16,
	success_sample_every = 1,
	new_event_id = function()
		trace_id += 1
		return string.format("ring-event-%04d", trace_id)
	end,
})

for index = 1, 40 do
	local accepted, message = tracer:Emit({
		operation_id = "ring-operation",
		component = "profile",
		operation = "read",
		result = "unknown",
		duration_ms = index,
		timestamp_unix = 1_700_000_000,
	})
	expect(accepted == true, "trace ring rejected event " .. tostring(index) .. ": " .. tostring(message))
end

local stats = tracer:Stats()
expect(stats.retained == 16 and stats.capacity == 16 and stats.dropped == 24 and stats.emitted == 40,
	"trace ring did not retain the newest capacity-sized window")

local latest = tracer:GetOperationTrace("ring-operation", 16)
expect(latest.code == "success" and #latest.events == 16, "trace query did not return the retained window")
for index, event in ipairs(latest.events) do
	expect(event.sequence == index + 24, "trace query changed chronological order after wraparound")
end

local first_drain = tracer:Drain(5)
expect(#first_drain == 5, "trace Drain returned an incorrect first batch size")
for index, event in ipairs(first_drain) do
	expect(event.sequence == index + 24, "trace Drain changed oldest-first order")
end

local second_drain = tracer:Drain()
expect(#second_drain == 11, "trace Drain did not return the remaining entries")
for index, event in ipairs(second_drain) do
	expect(event.sequence == index + 29, "trace Drain lost order after a partial drain")
end
expect(tracer:Stats().retained == 0, "trace ring retained drained entries")

for index = 41, 60 do
	local accepted = tracer:Emit({
		operation_id = "ring-operation",
		component = "profile",
		operation = "read",
		result = "unknown",
		duration_ms = index,
		timestamp_unix = 1_700_000_001,
	})
	expect(accepted == true, "trace ring failed after becoming empty")
end

stats = tracer:Stats()
expect(stats.retained == 16 and stats.dropped == 28 and stats.emitted == 60,
	"trace ring counters changed after reuse")
latest = tracer:GetOperationTrace("ring-operation", 16)
expect(#latest.events == 16, "trace ring did not retain its newest window after reuse")
for index, event in ipairs(latest.events) do
	expect(event.sequence == index + 44, "trace ring reused slots in the wrong chronological order")
end

local fetch_count = 0
local coalescer = V2.ReadCoalescer.new(function(key)
	fetch_count += 1
	return {
		key = key,
		nested = { serial = fetch_count },
	}
end, {
	ttl_seconds = 60,
	max_entries = 4,
})

local first = coalescer:GetAsync("shared", "fence-a")
expect(first.key == "shared" and first.nested.serial == 1, "read coalescer did not return the fetched value")
first.nested.serial = -1
local cached = coalescer:GetAsync("shared", "fence-a")
expect(cached.nested.serial == 1 and fetch_count == 1,
	"read coalescer exposed its cached snapshot to caller mutation")

local fenced = coalescer:GetAsync("shared", "fence-b")
expect(fenced.nested.serial == 2 and fetch_count == 2,
	"read coalescer did not isolate cache entries by fence key")
expect(coalescer:Invalidate("shared", "fence-a") == true, "read coalescer failed to invalidate a key")
local refreshed = coalescer:GetAsync("shared", "fence-a")
expect(refreshed.nested.serial == 3 and fetch_count == 3,
	"read coalescer returned an invalidated snapshot")

local eviction_fetches = 0
local eviction = V2.ReadCoalescer.new(function(key)
	eviction_fetches += 1
	return { key = key, serial = eviction_fetches }
end, {
	ttl_seconds = 60,
	max_entries = 4,
})

for _, key in { "a", "b", "c", "d" } do
	expect(eviction:GetAsync(key) ~= nil, "read coalescer failed to insert " .. key)
	task.wait(0.002)
end
expect(eviction:Stats().entries == 4, "read coalescer did not reach configured capacity")
expect(eviction:Invalidate("b") == true, "read coalescer could not remove a non-root expiry entry")
expect(eviction:Stats().entries == 3, "read coalescer count did not update after invalidation")
expect(eviction:GetAsync("e") ~= nil, "read coalescer failed after non-root heap removal")
expect(eviction:GetAsync("f") ~= nil, "read coalescer failed to trigger capacity eviction")
expect(eviction:Stats().entries == 4 and eviction:Stats().evictions == 1,
	"read coalescer capacity accounting changed after expiry heap repair")

local before_oldest_read = eviction_fetches
local reloaded_oldest = eviction:GetAsync("a")
expect(reloaded_oldest ~= nil and eviction_fetches == before_oldest_read + 1,
	"read coalescer did not evict the earliest-expiring cache entry")
local cached_oldest = eviction:GetAsync("a")
expect(cached_oldest.serial == reloaded_oldest.serial and eviction_fetches == before_oldest_read + 1,
	"read coalescer failed to cache the reloaded entry")

local clear_ok = eviction:Clear()
expect(clear_ok == true and eviction:Stats().entries == 0 and eviction:Stats().in_flight == 0,
	"read coalescer Clear did not reset cache state")

local ttl_zero_calls = 0
local no_ttl = V2.ReadCoalescer.new(function()
	ttl_zero_calls += 1
	return { serial = ttl_zero_calls }
end, {
	ttl_seconds = 0,
	max_entries = 2,
})
no_ttl:GetAsync("instant")
no_ttl:GetAsync("instant")
expect(ttl_zero_calls == 2, "zero-TTL read coalescer retained an expired entry")

print("[v2-service-structures] trace ring wraparound/drain and read-coalescer isolation/eviction passed")
