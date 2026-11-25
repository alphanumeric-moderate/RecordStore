--!nocheck
local initializer = game:GetService("ServerScriptService"):WaitForChild("PlayerDataInitializer")
local TransientMessaging = require(initializer:WaitForChild("RecordStoreTransientMessaging"))
local HttpService = game:GetService("HttpService")

local function new_bus()
	local subscriptions = {}
	local state = {
		publish_calls = 0,
		subscribe_calls = 0,
		last_topic = nil,
		last_data = nil,
		fail_after_publish = 0,
		fail_subscribe = 0,
		duplicate_next = false,
	}
	local service = {}
	function service:PublishAsync(topic, data)
		assert(type(topic) == "string" and #topic <= 80, "physical MessagingService topic exceeded 80 bytes")
		state.publish_calls += 1
		state.last_topic = topic
		state.last_data = data
		for _, entry in ipairs(subscriptions[topic] or {}) do
			if entry.connected then
				entry.callback({ Data = data, Sent = 1234 })
				if state.duplicate_next then
					entry.callback({ Data = data, Sent = 1234 })
				end
			end
		end
		state.duplicate_next = false
		if state.fail_after_publish > 0 then
			state.fail_after_publish -= 1
			error("injected publish response loss after delivery", 0)
		end
	end
	function service:SubscribeAsync(topic, callback)
		state.subscribe_calls += 1
		if state.fail_subscribe > 0 then
			state.fail_subscribe -= 1
			error("injected subscribe failure", 0)
		end
		local entry = { callback = callback, connected = true }
		subscriptions[topic] = subscriptions[topic] or {}
		table.insert(subscriptions[topic], entry)
		local connection = {}
		function connection:Disconnect()
			entry.connected = false
		end
		return connection
	end
	local control = {}
	function control:fail_after_publish(count)
		state.fail_after_publish = count
	end
	function control:fail_subscribe(count)
		state.fail_subscribe = count
	end
	function control:duplicate_next()
		state.duplicate_next = true
	end
	function control:state()
		return state
	end
	return service, control
end

local bus, control = new_bus()
local sender = assert(TransientMessaging.new(bus, HttpService, {
	namespace = "game-events",
	server_id = "server-a",
}))
local receiver = assert(TransientMessaging.new(bus, HttpService, {
	namespace = "game-events",
	server_id = "server-b",
}))

local received = {}
local topic_subscription = receiver:SubscribeAsync("round.completed", function(payload, context)
	received[#received + 1] = { payload = payload, context = context }
end)
assert(topic_subscription.code == "subscribed", "broadcast subscription failed")

local publish = sender:PublishAsync("round.completed", { round = 10, kind = "completed" })
assert(publish.code == "published" and publish.message_id ~= nil, "broadcast publish failed")
assert(#received == 1 and received[1].payload.round == 10, "broadcast payload was not delivered")
assert(received[1].context.sender == "server-a" and received[1].context.message_id == publish.message_id,
	"broadcast context did not preserve sender and message identity")
assert(#control:state().last_topic <= 80 and string.find(control:state().last_topic, "round.completed", 1, true) == nil,
	"logical topic must be hashed before reaching MessagingService")

local duplicate_count = #received
control:duplicate_next()
local duplicated = sender:PublishAsync("round.completed", { round = 11 })
assert(duplicated.code == "published" and #received == duplicate_count + 2,
	"transport must surface duplicates rather than pretending to provide exactly-once delivery")

local direct_seen = {}
local direct_subscription = receiver:SubscribeServerAsync(function(payload, context)
	direct_seen[#direct_seen + 1] = { payload = payload, context = context }
end)
assert(direct_subscription.code == "subscribed", "directed server subscription failed")
local direct = sender:SendToServerAsync("server-b", { command = "refresh" })
assert(direct.code == "published" and #direct_seen == 1, "server-directed message was not delivered")
assert(direct_seen[1].payload.command == "refresh" and direct_seen[1].context.target == "server-b",
	"directed message target was not preserved")

local wakeups = {}
local wrong_partition = 0
local wake_subscription = receiver:SubscribeStreamWakeups("game.events", 2, function(payload)
	wakeups[#wakeups + 1] = payload
end)
local wrong_wake_subscription = receiver:SubscribeStreamWakeups("game.events", 1, function()
	wrong_partition += 1
end)
assert(wake_subscription.code == "subscribed" and wrong_wake_subscription.code == "subscribed",
	"stream wakeup subscriptions failed")
local wake = sender:PublishStreamWakeup("game.events", 2, 50)
assert(wake.code == "published" and #wakeups == 1 and wakeups[1].sequence == 50 and wrong_partition == 0,
	"stream wakeup did not route to the exact stream partition")

local received_before_unknown = #received
control:fail_after_publish(1)
local uncertain = sender:PublishAsync("round.completed", { round = 12 })
assert(uncertain.code == "unknown" and #received == received_before_unknown + 1,
	"lost publish response must remain unknown even if a subscriber already observed it")

local calls_before_oversized = control:state().publish_calls
local small_limit = assert(TransientMessaging.new(bus, HttpService, {
	namespace = "limited",
	server_id = "server-a",
	max_message_bytes = 128,
}))
local oversized = small_limit:PublishAsync("topic", { data = string.rep("x", 512) })
assert(oversized.code == "capacity" and control:state().publish_calls == calls_before_oversized,
	"oversized message must be rejected before a service request")

local cyclic = {}
cyclic.self = cyclic
local invalid_payload = sender:PublishAsync("round.completed", cyclic)
assert(invalid_payload.code == "invalid", "cyclic payload was accepted")

control:fail_subscribe(1)
local failed_subscribe = sender:SubscribeAsync("unavailable", function() end)
assert(failed_subscribe.code == "unknown", "subscription failure was not exposed")

local before_disconnect = #received
topic_subscription.subscription:Disconnect()
local after_disconnect = sender:PublishAsync("round.completed", { round = 13 })
assert(after_disconnect.code == "published" and #received == before_disconnect,
	"disconnected subscription still received messages")

receiver:Close()
local post_close = receiver:SubscribeAsync("closed", function() end)
assert(post_close.code == "closed", "closed client accepted new subscriptions")
sender:Close()
small_limit:Close()

print("[PASS] transient topic publish/subscribe, directed server routing, stream wakeup hints, size limits, uncertainty, duplicates, and subscription lifecycle")
