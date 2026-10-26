--!nocheck
-- Deterministic crash simulator coverage for cache freshness, ambiguous commits,
-- transform replay, process epochs, and lossy messaging hints. Do not run until
-- every remaining implementation and regression slice has been added.
local Simulator = require("./DeterministicCrashSimulator")

local function expect(value, message)
	assert(value, message)
end

local simulator = Simulator.new({
	seed = 41021,
	cache_ttl_ms = 5000,
	initial_budget = 1000,
})

-- A stale cached read remains stale, while a fresh read reaches the authoritative key.
simulator:SetAsync("server-a", "profile-key", { kills = 1 }, { 101 }, {})
local cached, cache_info = simulator:GetAsync("server-b", "profile-key")
expect(cached.kills == 1 and cache_info ~= nil, "initial cached read failed")
simulator:SetAsync("server-a", "profile-key", { kills = 2 }, { 101 }, {})
local stale = simulator:GetAsync("server-b", "profile-key")
local fresh = simulator:GetAsyncFresh("server-b", "profile-key")
expect(stale.kills == 1, "simulator unexpectedly invalidated a remote server cache")
expect(fresh.kills == 2, "fresh read returned stale profile data")

-- UpdateAsync may commit even when the caller receives an error. Reconciliation
-- must read the committed state instead of blindly retrying a second increment.
local injected, injected_message = simulator:InjectFault({
	operation = "UpdateAsync",
	phase = "after_commit",
	key = "profile-key",
	server = "server-a",
	action = "commit_then_error",
})
expect(injected == true, "could not install the commit-then-error fault: " .. tostring(injected_message))
local call_ok = pcall(function()
	simulator:UpdateAsync("server-a", "profile-key", function(raw)
		return { kills = raw.kills + 1 }
	end)
end)
expect(not call_ok, "commit-then-error fault did not reach the caller as an error")
local committed = simulator:GetAsyncFresh("server-b", "profile-key")
expect(committed.kills == 3, "ambiguous UpdateAsync response did not preserve the committed value")

-- UpdateAsync may replay a transformer. The durable mutation must still apply
-- once; the transform invocation counter exposes replay to the scenario.
local replayed, replay_message = simulator:InjectFault({
	operation = "UpdateAsync",
	phase = "during_transform",
	key = "profile-key",
	server = "server-a",
	action = "transform_replay",
})
expect(replayed == true, "could not install transform-replay fault: " .. tostring(replay_message))
local next_value, transform_info = simulator:UpdateAsync("server-a", "profile-key", function(raw)
	return { kills = raw.kills + 1 }
end)
expect(next_value.kills == 4 and transform_info ~= nil,
	"transform replay applied an incorrect durable result")
expect(simulator:Stats().counters.transform_replays >= 1,
	"simulator did not account for an UpdateAsync transform replay")

-- Crashes clear process-local state and invalidate queued callbacks without
-- rolling back already committed DataStore data.
local local_state = simulator:LocalState("server-a")
local_state.temporary_cache = "must disappear"
local callback_ran = false
local scheduled, schedule_error = simulator:ScheduleAfter(
	"server-a", 50, "crash-test", "stale-callback", function()
		callback_ran = true
	end
)
expect(scheduled ~= nil, "could not schedule crash-bound callback: " .. tostring(schedule_error))
local crashed, crash_message = simulator:Crash("server-a", "regression process restart")
expect(crashed == true, "simulated process crash failed: " .. tostring(crash_message))
expect(next(simulator:LocalState("server-a")) == nil, "process-local cache survived simulated crash")
local stale_event = simulator:RunNext()
expect(stale_event.code == "dropped" and not callback_ran,
	"callback from an old process epoch ran after crash")
expect(simulator:GetAsyncFresh("server-b", "profile-key").kills == 4,
	"process crash discarded a committed durable value")

-- Best-effort hints can be dropped, duplicated, delayed, or expired independently
-- of durable queue state. The store remains authoritative and fresh reads can recover.
local durable_store_a = simulator:DataStore("DurableMailboxRegression", "global", "server-a")
local durable_store_b = simulator:DataStore("DurableMailboxRegression", "global", "server-b")
durable_store_a:UpdateAsync("mailbox", function(old)
	old = old or { pending = {} }
	local next_queue = { pending = table.clone(old.pending) }
	table.insert(next_queue.pending, "message-1")
	return next_queue
end)

local messaging_a = simulator:MessagingService("server-a")
local messaging_b = simulator:MessagingService("server-b")
local received = {}
local connection = messaging_b:SubscribeAsync("mailbox-hints", function(envelope)
	received[#received + 1] = envelope.Data.message_id
end)
expect(connection ~= nil, "simulator messaging subscription failed")

local dropped, dropped_message = simulator:InjectFault({
	operation = "PublishAsync",
	phase = "before_publish",
	server = "server-a",
	action = "drop_hint",
})
expect(dropped == true, "could not install dropped-hint fault: " .. tostring(dropped_message))
local dropped_result = messaging_a:PublishAsync("mailbox-hints", { message_id = "drop-me" })
expect(dropped_result.code == "published" and #received == 0,
	"dropped best-effort hint was delivered or treated as a durable write failure")
local durable_queue = durable_store_b:GetAsyncFresh("mailbox")
expect(#durable_queue.pending == 1 and durable_queue.pending[1] == "message-1",
	"lost hint destroyed the durable queue item")
durable_store_b:UpdateAsync("mailbox", function(old)
	return { pending = {} }
end)
expect(#durable_store_b:GetAsyncFresh("mailbox").pending == 0,
	"fresh durable polling could not recover and acknowledge a message after its hint was lost")

local duplicated, duplicate_message = simulator:InjectFault({
	operation = "PublishAsync",
	phase = "before_publish",
	server = "server-a",
	action = "duplicate_hint",
})
expect(duplicated == true, "could not install duplicate-hint fault: " .. tostring(duplicate_message))
messaging_a:PublishAsync("mailbox-hints", { message_id = "duplicate-me" })
local duplicate_delivery = simulator:RunUntil(simulator.now_ms, 20)
expect(duplicate_delivery.code == "success" and #received == 2,
	"duplicate hint was not delivered twice for the idempotency scenario")

local delayed, delayed_message = simulator:InjectFault({
	operation = "PublishAsync",
	phase = "before_publish",
	server = "server-a",
	action = "delay_hint",
	delay_ms = 100,
})
expect(delayed == true, "could not install delayed-hint fault: " .. tostring(delayed_message))
messaging_a:PublishAsync("mailbox-hints", { message_id = "delayed-me" })
local before_delivery = #received
simulator:RunUntil(simulator.now_ms + 25, 20)
expect(#received == before_delivery, "delayed hint arrived before its configured delay")
simulator:RunUntil(simulator.now_ms + 100, 20)
expect(received[#received] == "delayed-me", "delayed hint was not delivered after virtual time advanced")

local expired, expired_message = simulator:InjectFault({
	operation = "PublishAsync",
	phase = "before_publish",
	server = "server-a",
	action = "expire_hint",
})
expect(expired == true, "could not install expired-hint fault: " .. tostring(expired_message))
local before_expired = #received
messaging_a:PublishAsync("mailbox-hints", { message_id = "stale-me" })
simulator:RunUntil(simulator.now_ms, 20)
expect(#received == before_expired, "expired best-effort hint was delivered")
expect(simulator:Stats().counters.events_dropped >= 1,
	"simulator did not account for dropped or expired asynchronous hints")

connection:Disconnect()
