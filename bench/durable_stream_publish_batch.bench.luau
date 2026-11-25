--!nocheck
local FakeDataStore = require("./FakeDataStore")
local Shim = require("./RobloxShim")
local DurableStreams = Shim.load_durable_streams()

local fake = FakeDataStore.new()
local store = fake.service:GetDataStore("DurableStreamPublishBatchBench", "global")
local client, client_error = DurableStreams.new(store, {
	max_segment_messages = 64,
	max_segment_bytes = 262144,
	max_payload_bytes = 4096,
	max_batch_messages = 16,
})
assert(client ~= nil, client_error)
local stream, stream_error = client:OpenStreamAsync("bench.events", 1)
assert(stream ~= nil, stream_error)

local event_count = 1024
local batch_size = 16
local started = os.clock()
for first = 1, event_count, batch_size do
	local events = table.create(batch_size)
	for offset = 0, batch_size - 1 do
		local index = first + offset
		events[offset + 1] = {
			event_id = "event-" .. tostring(index),
			producer_id = "benchmark-publisher",
			producer_sequence = index,
			payload = {
				kind = "bench.event",
				value = index,
				nested = { active = true, source = "batch" },
			},
		}
	end
	local result = stream:PublishBatchAsync("benchmark-route", events)
	assert(result.code == "committed", "batch publish failed: " .. tostring(result.message))
end
local elapsed = os.clock() - started
local before_retry = fake.control:metrics().update_calls
local historical_retry = stream:PublishAsync(
	"benchmark-route",
	"event-1",
	{ kind = "bench.event", value = 1, nested = { active = true, source = "batch" } },
	"benchmark-publisher",
	1
)
local after_retry = fake.control:metrics().update_calls
assert(historical_retry.code == "committed" and historical_retry.duplicate == true, "historical producer retry failed")
assert(after_retry == before_retry, "historical producer retry issued an extra DataStore write")
local metrics = fake.control:metrics()
print(string.format(
	"[durable-stream-batch] events=%d batch=%d elapsed=%.6f updates=%d updates_per_event=%.4f historical_retry_writes=%d",
	event_count,
	batch_size,
	elapsed,
	metrics.update_calls,
	metrics.update_calls / event_count,
	after_retry - before_retry
))
Shim.close()
