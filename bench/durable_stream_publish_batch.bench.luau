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
local metrics = fake.control:metrics()
print(string.format(
	"[durable-stream-batch] events=%d batch=%d elapsed=%.6f updates=%d updates_per_event=%.4f",
	event_count,
	batch_size,
	elapsed,
	metrics.update_calls,
	metrics.update_calls / event_count
))
Shim.close()
