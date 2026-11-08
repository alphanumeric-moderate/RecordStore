--!nocheck
-- Isolated CPU workloads for the optional wake-up acceleration data structures.
-- MessagingService is a local stub; no Roblox network or durable storage is used.
local Acceleration = require("../src/PlayerDataInitializer/RecordStoreAcceleration")

local PENDING_OWNER_COUNT = 512
local PENDING_PASSES = 64
local DEDUP_MESSAGE_COUNT = 10000
local SEEN_EVENT_LIMIT = 2048
local BASE_TIME_MS = 1_800_000_000_000

local function owner_hash(material)
	local first, second = 5381, 1
	for index = 1, #material do
		local byte = string.byte(material, index)
		first = (first * 33 + byte) % 2147483647
		second = (second * 65599 + byte) % 2147483629
	end
	return string.format("%08x%08x", first, second)
end

local function make_acceleration(now_ms)
	local messaging = {}
	function messaging:SubscribeAsync(_topic, _callback)
		return { Disconnect = function() end }
	end
	function messaging:PublishAsync() end

	local acceleration = Acceleration.new({
		messaging_service = messaging,
		server_id = "acceleration-benchmark",
		enabled = true,
		topic_prefix = "AccelerationBenchmark",
		shard_count = 1,
		max_registered_owners = PENDING_OWNER_COUNT,
		max_pending_owners = PENDING_OWNER_COUNT,
		max_callbacks_per_pump = 32,
		max_seen_events = SEEN_EVENT_LIMIT,
		now_ms = function() return now_ms end,
		schedule = function() return true end,
	})
	assert(acceleration:Start(), "acceleration benchmark failed to start")
	return acceleration
end

local function run_pending_queue()
	local checksum = 0
	for pass = 1, PENDING_PASSES do
		local now_ms = BASE_TIME_MS + pass
		local acceleration = make_acceleration(now_ms)
		local handles = table.create(PENDING_OWNER_COUNT)
		local callbacks = 0

		for index = 1, PENDING_OWNER_COUNT do
			local owner = "pending-owner-" .. tostring(index)
			local accepted, handle = acceleration:Register(owner, function()
				callbacks += 1
			end)
			assert(accepted, "pending owner registration failed")
			handles[index] = handle
		end

		for index = 1, PENDING_OWNER_COUNT do
			local owner = "pending-owner-" .. tostring(index)
			local accepted, reason = acceleration:_receive(1, {
				version = 1,
				owner_hash = owner_hash(owner),
				event_id = "pending-event-" .. tostring(pass) .. "-" .. tostring(index),
				reason = "enqueue",
				sender = "remote-server",
				published_at_ms = now_ms,
			})
			assert(accepted and reason == "queued", "pending owner was not queued")
		end

		assert(acceleration:Stats().pending_owners == PENDING_OWNER_COUNT,
			"pending owner queue did not reach its configured capacity")
		for index = 2, PENDING_OWNER_COUNT, 2 do
			handles[index]:Disconnect()
		end
		assert(acceleration:Stats().pending_owners == PENDING_OWNER_COUNT / 2,
			"pending owner cancellation did not unlink exactly half the queue")

		local target_callbacks = PENDING_OWNER_COUNT / 2
		local pump_iterations = 0
		while callbacks < target_callbacks and pump_iterations < PENDING_OWNER_COUNT do
			acceleration:_pump()
			pump_iterations += 1
		end
		assert(callbacks == target_callbacks,
			"pending owner queue dispatched an incorrect callback count")
		local stats = acceleration:Stats()
		assert(stats.pending_owners == 0 and stats.metrics.callbacks_run == target_callbacks,
			"pending owner queue did not drain or miscount callbacks")
		checksum += callbacks + stats.metrics.callbacks_run
		acceleration:Stop()
	end

	assert(checksum == PENDING_PASSES * PENDING_OWNER_COUNT,
		"pending queue benchmark checksum mismatch")
	print(string.format("[acceleration-pending] passes=%d owners=%d cancellations=%d checksum=%d",
		PENDING_PASSES, PENDING_OWNER_COUNT, PENDING_OWNER_COUNT / 2, checksum))
end

local function run_event_dedup()
	local now_ms = BASE_TIME_MS
	local acceleration = make_acceleration(now_ms)
	local checksum = 0
	local owner = "0123456789abcdef"

	for index = 1, DEDUP_MESSAGE_COUNT do
		local accepted, reason = acceleration:_receive(1, {
			version = 1,
			owner_hash = owner,
			event_id = "dedup-event-" .. tostring(index),
			reason = "enqueue",
			sender = "remote-server",
			published_at_ms = now_ms,
		})
		assert(accepted == false and reason == "not_registered",
			"unregistered benchmark owner unexpectedly entered the pending queue")
		checksum += index
	end

	assert(checksum == DEDUP_MESSAGE_COUNT * (DEDUP_MESSAGE_COUNT + 1) / 2,
		"event deduplication benchmark checksum mismatch")
	assert(acceleration:Stats().metrics.received == DEDUP_MESSAGE_COUNT,
		"event deduplication benchmark dropped accepted notification deliveries")
	print(string.format("[acceleration-dedup] messages=%d retained=%d checksum=%d",
		DEDUP_MESSAGE_COUNT, math.min(DEDUP_MESSAGE_COUNT, SEEN_EVENT_LIMIT), checksum))
	acceleration:Stop()
end

return {
	run_pending_queue = run_pending_queue,
	run_event_dedup = run_event_dedup,
}
