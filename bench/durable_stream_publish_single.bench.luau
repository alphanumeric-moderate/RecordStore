--!nocheck
local FakeDataStore = require("./FakeDataStore")
local Shim = require("./RobloxShim")
local DurableStreams = Shim.load().DurableStreams

local fake = FakeDataStore.new()
local store = fake.service:GetDataStore("DurableStreamPublishSingleBench", "global")
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
local started = os.clock()
for index = 1, event_count do
	local result = stream:PublishAsync("benchmark-route", "event-" .. tostring(index), {
		kind = "bench.event",
		value = index,
		nested = { active = true, source = "single" },
	})
	assert(result.code == "committed", "single publish failed: " .. tostring(result.message))
end
local elapsed = os.clock() - started
local metrics = fake.control:metrics()
print(string.format(
	"[durable-stream-single] events=%d elapsed=%.6f updates=%d updates_per_event=%.4f",
	event_count,
	elapsed,
	metrics.update_calls,
	metrics.update_calls / event_count
))
Shim.close()
