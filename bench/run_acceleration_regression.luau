--!nocheck
-- Wake-up acceleration regressions. Hints are intentionally best-effort; durable
-- mailbox polling must recover work regardless of notification outcomes. This is
-- written for the final verification phase and has not yet been executed.
local Simulator = require("./DeterministicCrashSimulator")
local Acceleration = require("../src/PlayerDataInitializer/RecordStoreV2Acceleration")

local function expect(value, message)
	assert(value, message)
end

local function make_pair(options)
	options = options or {}
	local simulator = Simulator.new({
		seed = options.seed or 773,
		cache_ttl_ms = 0,
		initial_budget = 1000,
	})
	local function schedule_for(server_id)
		return function(delay_ms, callback)
			local event = simulator:ScheduleAfter(
				server_id, delay_ms, "acceleration-regression", "wake-callback",
				function() callback() end
			)
			return event ~= nil
		end
	end
	local function new_instance(server_id, extra)
		local selected = {
			messaging_service = simulator:MessagingService(server_id),
			server_id = server_id,
			enabled = true,
			topic_prefix = "AccelRegression",
			shard_count = 4,
			coalesce_window_ms = options.coalesce_window_ms or 25,
			max_pending_owners = options.max_pending_owners or 8,
			max_registered_owners = 8,
			max_callbacks_per_pump = 4,
			now_ms = function() return simulator:Now(server_id) end,
			schedule = schedule_for(server_id),
		}
		for key, value in pairs(extra or {}) do selected[key] = value end
		return Acceleration.new(selected)
	end
	local publisher = new_instance("server-a", options.publisher_options)
	local receiver = new_instance("server-b", options.receiver_options)
	local publisher_started = publisher:Start()
	local receiver_started = receiver:Start()
	expect(publisher_started == true, "publisher acceleration failed to start")
	expect(receiver_started == true, "receiver acceleration failed to start")
	return simulator, publisher, receiver
end

local function subscribe(receiver, owner, events)
	local accepted, handle = receiver:Register(owner, function(reason)
		events[#events + 1] = reason
	end)
	expect(accepted == true, "owner registration failed: " .. tostring(handle))
	return handle
end

local function inject(simulator, fault)
	local ok, message = simulator:InjectFault(fault)
	expect(ok == true, "fault injection failed: " .. tostring(message))
end

-- Lost MessagingService hints do not remove the durable mailbox entry. A normal
-- periodic poll can still read and acknowledge it without an acceleration callback.
do
	local simulator, publisher, receiver = make_pair({ seed = 774 })
	local callbacks = {}
	subscribe(receiver, "durable-owner", callbacks)
	local writer = simulator:DataStore("AccelerationDurableMailbox", "global", "server-a")
	local reader = simulator:DataStore("AccelerationDurableMailbox", "global", "server-b")
	writer:UpdateAsync("queue", function()
		return { pending = { "message-durable-1" } }
	end)

	inject(simulator, {
		operation = "PublishAsync",
		phase = "before_publish",
		server = "server-a",
		action = "drop_hint",
	})
	local result = publisher:Publish("durable-owner", "enqueue")
	expect(result.code == "scheduled", "dropped hint was incorrectly reported as durable-write failure")
	simulator:RunUntil(simulator.now_ms, 20)
	expect(#callbacks == 0, "a deliberately dropped hint reached the wake callback")

	local queue = reader:GetAsyncFresh("queue")
	expect(type(queue) == "table" and #queue.pending == 1
		and queue.pending[1] == "message-durable-1",
		"durable polling could not observe work after the wake-up hint was lost")
	reader:UpdateAsync("queue", function(current)
		return { pending = {} }
	end)
	expect(#reader:GetAsyncFresh("queue").pending == 0,
		"durable polling did not complete its independent recovery path")
	expect(simulator:Stats().counters.dropped_hints == 1,
		"simulator did not record the lost acceleration hint")
end

-- Duplicate publications may be delivered, but event-ID deduplication keeps one
-- owner callback for a duplicated hint.
do
	local simulator, publisher, receiver = make_pair({ seed = 775 })
	local callbacks = {}
	subscribe(receiver, "duplicate-owner", callbacks)
	inject(simulator, {
		operation = "PublishAsync",
		phase = "before_publish",
		server = "server-a",
		action = "duplicate_hint",
	})
	local result = publisher:Publish("duplicate-owner", "enqueue")
	expect(result.code == "scheduled", "duplicate-hint publish failed")
	local ran = simulator:RunUntil(25, 20)
	expect(ran.code == "success", "duplicate delivery schedule did not drain")
	expect(#callbacks == 1, "duplicate hint triggered the owner callback more than once")
	expect(receiver:Stats().metrics.seen_duplicates == 1,
		"duplicate event was not counted by the receiver")
end

-- Delayed hints remain advisory: no callback runs before delivery/coalescing,
-- then the registered owner is woken after virtual time advances.
do
	local simulator, publisher, receiver = make_pair({ seed = 776 })
	local callbacks = {}
	subscribe(receiver, "delayed-owner", callbacks)
	inject(simulator, {
		operation = "PublishAsync",
		phase = "before_publish",
		server = "server-a",
		action = "delay_hint",
		delay_ms = 100,
	})
	local result = publisher:Publish("delayed-owner", "retry")
	expect(result.code == "scheduled", "delayed-hint publish failed")
	simulator:RunUntil(99, 20)
	expect(#callbacks == 0, "delayed hint arrived before the configured deadline")
	simulator:RunUntil(125, 20)
	expect(#callbacks == 1 and callbacks[1] == "retry",
		"delayed hint did not wake the registered owner after virtual time advanced")
end

-- A stale/expired notification is discarded; the durable queue remains the
-- recovery mechanism instead of trusting event delivery time.
do
	local simulator, publisher, receiver = make_pair({ seed = 777 })
	local callbacks = {}
	subscribe(receiver, "stale-owner", callbacks)
	inject(simulator, {
		operation = "PublishAsync",
		phase = "before_publish",
		server = "server-a",
		action = "expire_hint",
	})
	local result = publisher:Publish("stale-owner", "reconcile")
	expect(result.code == "scheduled", "expired-hint publish did not complete as best effort")
	simulator:RunUntil(simulator.now_ms, 20)
	expect(#callbacks == 0, "expired hint was delivered to the owner")
	expect(simulator:Stats().counters.events_dropped >= 1,
		"expired asynchronous notification was not accounted as dropped")
end

-- Stop invalidates both in-flight deliveries and scheduled coalescing pumps.
do
	local simulator, publisher, receiver = make_pair({ seed = 778 })
	local callbacks = {}
	subscribe(receiver, "stopped-owner", callbacks)
	local result = publisher:Publish("stopped-owner", "enqueue")
	expect(result.code == "scheduled", "stop-boundary publish failed")
	simulator:RunUntil(0, 20)
	expect(receiver:Stats().pending_owners == 1,
		"local owner callback was not queued before Stop")
	receiver:Stop()
	simulator:RunUntil(25, 20)
	expect(#callbacks == 0, "stale local wake callback ran after Stop")
	expect(receiver:Stats().running == false, "Stop did not mark acceleration inactive")
end

-- Capacity is bounded and observable; overload drops the hint instead of growing
-- an unbounded local queue, while unrelated durable polling remains available.
do
	local simulator, publisher, receiver = make_pair({
		seed = 779,
		max_pending_owners = 1,
	})
	local first_callbacks, second_callbacks = {}, {}
	subscribe(receiver, "capacity-owner-a", first_callbacks)
	subscribe(receiver, "capacity-owner-b", second_callbacks)
	expect(publisher:Publish("capacity-owner-a", "enqueue").code == "scheduled",
		"first capacity fixture publish failed")
	expect(publisher:Publish("capacity-owner-b", "enqueue").code == "scheduled",
		"second capacity fixture publish failed")
	simulator:RunUntil(0, 20)
	expect(receiver:Stats().pending_owners == 1,
		"pending owner queue exceeded its configured capacity")
	expect(receiver:Stats().metrics.dropped_at_capacity == 1,
		"capacity rejection was not counted")
	simulator:RunUntil(25, 20)
	expect(#first_callbacks == 1 and #second_callbacks == 0,
		"capacity-limited queue dispatched an unexpected owner")
end
