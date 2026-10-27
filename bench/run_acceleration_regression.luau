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

-- Canonical owner identities must be stable across table insertion order, while
-- arrays, objects and scalar types remain separate routing identities.
do
	local simulator, publisher, receiver = make_pair()
	local callbacks = {}
	local owner = { store = "Profiles", keys = { "scope", "player" }, flags = { enabled = true } }
	subscribe(receiver, owner, callbacks)
	local reordered = { flags = { enabled = true }, keys = { "scope", "player" }, store = "Profiles" }
	expect(receiver:Register(reordered, function() end) == false,
		"equivalent table identities registered twice")
	expect(publisher:Publish(reordered, "enqueue").code == "scheduled", "canonical owner could not publish")
	simulator:RunUntil(25, 20)
	expect(#callbacks == 1, "equivalent owner identity routed to a different callback")
	local distinct = { { "scope", "player" }, { ["1"] = "scope", ["2"] = "player" }, 1, "1", true, "true" }
	for _, identity in ipairs(distinct) do
		expect(receiver:Register(identity, function() end) == true, "distinct owner types collided")
	end
end

do
	local _, publisher, receiver = make_pair()
	local cyclic = {}; cyclic.self = cyclic
	local deep = {}; local leaf = deep
	for _ = 1, 34 do leaf.child = {}; leaf = leaf.child end
	for _, identity in {
		"", string.rep("x", 1025), math.huge, 0 / 0, cyclic, deep,
		{ [2] = "sparse" }, { [1] = "mixed", named = true }, { callback = function() end },
	} do
		local before = receiver:Stats().registered_owners
		expect(receiver:Register(identity, function() end) == false
			and receiver:Stats().registered_owners == before, "invalid owner consumed registration capacity")
		expect(publisher:Publish(identity, "enqueue").code == "invalid", "invalid owner was published")
	end
	for _, reason in { "", "future_reason", string.rep("x", 33), false, 1 } do
		expect(publisher:Publish("valid-owner", reason).code == "invalid", "unsupported wake reason was published")
	end
	expect(publisher:Stats().metrics.published == 0, "invalid publications reached messaging")
	expect(receiver:Register(string.rep("x", 1024), function() end) == true,
		"owner at the exact byte limit was rejected")
end

-- Disconnect must cancel queued work and release capacity. A replacement
-- registration must not receive work queued for its previous callback.
do
	local simulator, publisher, receiver = make_pair({ receiver_options = { max_registered_owners = 1 } })
	local old_events, new_events = {}, {}
	local handle = subscribe(receiver, "reused-owner", old_events)
	expect(receiver:Register("other-owner", function() end) == false, "registration capacity was exceeded")
	publisher:Publish("reused-owner", "enqueue")
	simulator:RunUntil(0, 20)
	expect(receiver:Stats().pending_owners == 1, "disconnect fixture did not queue a callback")
	handle:Disconnect(); handle:Disconnect()
	expect(handle.Connected == false and receiver:Stats().registered_owners == 0
		and receiver:Stats().pending_owners == 0, "disconnect was not idempotent or leaked owner capacity")
	subscribe(receiver, "reused-owner", new_events)
	simulator:RunUntil(25, 20)
	expect(#old_events == 0 and #new_events == 0, "disconnected owner's queued work reached a callback")
	publisher:Publish("reused-owner", "retry")
	simulator:RunUntil(50, 20)
	expect(#new_events == 1 and new_events[1] == "retry", "replacement registration did not receive new work")
end

do
	local simulator, publisher, receiver = make_pair({ receiver_options = { max_callbacks_per_pump = 1 } })
	local callbacks = {}
	subscribe(receiver, "coalesced-owner", callbacks)
	expect(receiver:Register("throwing-owner", function() error("injected callback failure") end) == true,
		"throwing callback could not register")
	publisher:Publish("throwing-owner", "enqueue")
	publisher:Publish("coalesced-owner", "enqueue")
	publisher:Publish("coalesced-owner", "reconcile")
	simulator:RunUntil(0, 20)
	expect(receiver:Stats().pending_owners == 2 and receiver:Stats().metrics.coalesced == 1,
		"repeated owner hints did not coalesce")
	simulator:RunUntil(25, 20)
	expect(#callbacks == 1 and callbacks[1] == "reconcile"
		and receiver:Stats().pending_owners == 0 and receiver:Stats().metrics.callback_errors == 1
		and receiver:Stats().metrics.callbacks_run == 1,
		"callback failure prevented later pumps or coalescing lost the newest reason")
	local snapshot = receiver:Stats()
	snapshot.metrics.callback_errors = 999
	expect(receiver:Stats().metrics.callback_errors == 1, "Stats exposed mutable metric state")
end

-- Subscription failure must roll back partial setup, allowing a clean retry.
-- Use only a local MessagingService stub, with no network or real subscriptions.
do
	local attempts, disconnected = 0, 0
	local fail = true
	local messaging = {}
	function messaging:SubscribeAsync(_topic, _callback)
		attempts += 1
		if fail and attempts == 2 then error("injected subscription failure") end
		return { Disconnect = function() disconnected += 1 end }
	end
	function messaging:PublishAsync() end
	local instance = Acceleration.new({ messaging_service = messaging, server_id = "unit-server",
		enabled = true, shard_count = 3, now_ms = function() return 0 end })
	expect(instance:Publish("owner", "enqueue").code == "disabled", "publishing before Start performed work")
	expect(instance:Start() == false and attempts == 2 and disconnected == 1
		and instance:Stats().running == false and instance:Stats().metrics.subscribe_errors == 1,
		"partial subscription failure leaked an active connection")
	fail = false
	expect(instance:Start() == true and attempts == 5, "Start did not recover from subscription failure")
	expect(instance:Start() == true and attempts == 5, "repeated Start duplicated subscriptions")
	instance:Stop(); instance:Stop()
	expect(disconnected == 4 and instance:Publish("owner", "enqueue").code == "disabled",
		"repeated Stop leaked subscriptions or allowed publication")
end

-- Remote hints remain best effort if the local scheduler rejects a callback.
for _, throws in { false, true } do
	local simulator, publisher, receiver = make_pair({ receiver_options = { schedule = function()
		if throws then error("injected scheduler failure") end
		return false
	end } })
	local callbacks = {}
	subscribe(receiver, "unscheduled-owner", callbacks)
	expect(publisher:Publish("unscheduled-owner", "enqueue").code == "scheduled",
		"receiver scheduler failure changed the publisher outcome")
	simulator:RunUntil(25, 20)
	expect(#callbacks == 0 and receiver:Stats().pending_owners == 0,
		"scheduler failure retained undeliverable work or invoked a callback")
end

-- Optional MemoryStore hints can wake a receiver when MessagingService fails.
-- All provider methods below are local stubs; the scheduled pumps run explicitly.
do
	local rows, pumps, events = {}, {}, {}
	local reads, fail_reads, fail_writes = 0, false, false
	local map = {}
	function map:SetAsync(key, message, ttl, score)
		expect(ttl == 30 and score == 100, "memory hint lost its TTL or millisecond score")
		if fail_writes then error("injected MemoryStore write failure") end
		rows[key] = message
	end
	function map:GetRangeAsync(_direction, maximum)
		reads += 1
		if fail_reads then error("injected MemoryStore read failure") end
		local page = {}
		for key, value in pairs(rows) do
			if #page == maximum then break end
			table.insert(page, { key = key, value = value })
		end
		return page
	end
	function map:RemoveAsync(key) rows[key] = nil end
	local messaging = {
		SubscribeAsync = function() return { Disconnect = function() end } end,
		PublishAsync = function() error("injected MessagingService failure") end,
	}
	local function new_instance(server_id)
		return Acceleration.new({
			server_id = server_id, enabled = true, messaging_service = messaging,
			enable_memory_store = true, max_memory_hint_slots = 2,
			memory_store_service = { GetSortedMap = function() return map end },
			now_ms = function() return 100 end,
			schedule = function(delay, callback)
				if delay == 25 then table.insert(pumps, callback) end
				return true
			end,
		})
	end
	local publisher, receiver = new_instance("memory-publisher"), new_instance("memory-receiver")
	expect(publisher:Start() and receiver:Start(), "memory hint fixture failed to start")
	subscribe(receiver, "memory-owner", events)
	for _, maximum in { 0, 3, 1.5, math.huge, 0 / 0, "1" } do
		expect(receiver:PollMemoryHints(maximum).code == "invalid" and reads == 0,
			"invalid memory poll bound reached the provider")
	end
	expect(publisher:Publish("memory-owner", "enqueue").code == "scheduled"
		and publisher:Stats().metrics.publish_errors == 1, "MemoryStore fallback was lost after messaging failure")
	local polled = receiver:PollMemoryHints()
	expect(polled.code == "success" and polled.processed == 1 and next(rows) == nil and #pumps == 1,
		"memory hint was not queued and removed in the bounded default poll")
	pumps[1]()
	expect(#events == 1 and events[1] == "enqueue", "MemoryStore fallback did not wake the registered owner")
	rows.invalid = { shard = 0, version = 99 }
	expect(receiver:PollMemoryHints(1).processed == 0 and next(rows) == nil and #events == 1,
		"malformed memory hint was delivered or retained to starve later polls")
	fail_reads = true
	expect(receiver:PollMemoryHints(2).code == "unknown" and receiver:Stats().metrics.memory_poll_errors == 1,
		"failed MemoryStore read was treated as an empty successful poll")
	fail_writes = true
	expect(publisher:Publish("memory-owner", "retry").code == "unavailable"
		and publisher:Stats().metrics.memory_write_errors == 1,
		"loss of both hint providers was reported as scheduled")
	publisher:Stop(); receiver:Stop()
end

print("[Acceleration] identity, lifecycle, coalescing, capacity, MemoryStore fallback and advisory failure regressions passed")
