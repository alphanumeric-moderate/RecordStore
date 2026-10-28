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

-- Exhausted faults must remain reloadable, and active rules retain their counts.
do
	local active = simulator:InjectFault({ operation = "UpdateAsync", phase = "during_transform",
		key = "unused", action = "transform_replay", times = 2 })
	expect(active, "active rule could not be added after fault exhaustion")
	local replay = Simulator.new({ seed = 777 })
	expect(replay:LoadSerializedFaultScript(simulator:SerializeFaultScript()),
		"partially consumed fault script failed to reload")
	expect(#replay.faults == 1 and replay.faults[1].remaining == 2,
		"serialized faults retained exhausted rules or lost active counts")
end

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

-- Phase-less rules remain pending until a probe can apply their action.
do
	local probe = Simulator.new({ seed = 82 })
	expect(probe:LoadFaultScript({
		{ action = "commit_then_error" },
		{ operation = "UpdateAsync", action = "transform_replay" },
	}), "could not install wildcard-phase faults")
	local calls = 0
	local ok = pcall(function()
		probe:UpdateAsync("a", "wildcard", function()
			calls += 1
			return { value = calls }
		end)
	end)
	expect(not ok and calls == 2 and probe:GetAsyncFresh("a", "wildcard").value == 2,
		"wildcard replay and response loss did not both fire at their applicable probes")
	expect(probe:Stats().counters.faults_consumed == 2, "inapplicable probes consumed faults")
	expect(probe:InjectFault({ action = "ownership_race", concurrent_value = { value = 10 } }),
		"could not inject phase-less ownership race")
	local raced = probe:UpdateAsync("a", "wildcard", function(value) return { value = value.value + 1 } end)
	expect(raced.value == 11, "phase-less ownership race did not replay against the competing write")

	probe:SetAsync("a", "cached", { value = 1 })
	probe:GetAsync("b", "cached")
	probe:SetAsync("a", "cached", { value = 2 })
	probe.now_ms += 6000
	expect(probe:InjectFault({ action = "stale_read" }), "could not inject stale read")
	local before = probe:Stats().counters.faults_consumed
	expect(probe:GetAsyncFresh("b", "cached").value == 2
		and probe:Stats().counters.faults_consumed == before,
		"fresh read consumed a stale-read rule")
	expect(probe:GetAsync("b", "cached").value == 1
		and probe:Stats().counters.faults_consumed == before + 1,
		"cached read did not apply its retained stale-read rule")
end

-- Sorted-map transforms retain their sort key unless they return a replacement.
do
	local sorted = Simulator.new({ seed = 83 }):MemoryStoreService():GetSortedMap("sorted-repair")
	sorted:SetAsync("hint", { n = 1 }, 60, 3)
	local value, sort_key = sorted:UpdateAsync("hint", function(current, current_sort_key)
		expect(current.n == 1 and current_sort_key == 3, "sorted transform lost its input sort key")
		return { n = 2 }, 5
	end, 60)
	expect(value.n == 2 and sort_key == 5, "sorted transform lost its returned sort key")
	sorted:UpdateAsync("hint", function() return { n = 3 } end, 60)
	local range = sorted:GetRangeAsync("Ascending", 10)
	expect(#range == 1 and range[1].sort_key == 5 and range[1].value.n == 3,
		"value-only sorted update removed an entry from range queries")
	expect(not pcall(function()
		sorted:UpdateAsync("hint", function() return { n = 4 }, math.huge end, 60)
	end), "sorted transform accepted a non-finite sort key")
	expect(sorted:GetAsync("hint").n == 3, "rejected sorted update mutated its value")
end
print("[CrashSimulator] applicable faults and sorted-map update regressions passed")
