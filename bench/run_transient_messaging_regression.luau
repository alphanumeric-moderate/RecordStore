--!nocheck
local initializer = game:GetService("ServerScriptService"):WaitForChild("PlayerDataInitializer")
local RecordStore = require(initializer:WaitForChild("RecordStore"))
local TransientMessaging = RecordStore.TransientMessaging
local HttpService = game:GetService("HttpService")

local function new_bus()
	local subscriptions = {}
	local state = {
		publish_calls = 0,
		subscribe_calls = 0,
		last_topic = nil,
		fail_after_publish = 0,
		fail_subscribe = 0,
		duplicate_next = false,
	}
	local service = {}
	function service:PublishAsync(topic, data)
		assert(type(topic) == "string" and #topic <= 80, "physical MessagingService topic exceeded 80 bytes")
		state.publish_calls += 1
		state.last_topic = topic
		for _, entry in ipairs(subscriptions[topic] or {}) do
			if entry.connected then
				entry.callback({ Data = data, Sent = 1234 })
				if state.duplicate_next then entry.callback({ Data = data, Sent = 1234 }) end
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
		function connection:Disconnect() entry.connected = false end
		return connection
	end
	local control = {}
	function control:fail_after_publish(count) state.fail_after_publish = count end
	function control:fail_subscribe(count) state.fail_subscribe = count end
	function control:duplicate_next() state.duplicate_next = true end
	function control:state() return state end
	return service, control
end

local bus, control = new_bus()
local sender = assert(TransientMessaging.new(bus, HttpService, { namespace = "game-events", server_id = "server-a" }))
local receiver = assert(TransientMessaging.new(bus, HttpService, { namespace = "game-events", server_id = "server-b" }))

local wakeups = {}
local wrong_partition = 0
local wake_subscription = receiver:SubscribeStreamWakeups("game.events", 2, function(payload, context)
	wakeups[#wakeups + 1] = { payload = payload, context = context }
end)
local wrong_subscription = receiver:SubscribeStreamWakeups("game.events", 1, function() wrong_partition += 1 end)
assert(wake_subscription.code == "subscribed" and wrong_subscription.code == "subscribed")
local wake = sender:PublishStreamWakeup("game.events", 2, 50)
assert(wake.code == "published" and #wakeups == 1 and wakeups[1].payload.sequence == 50)
assert(wakeups[1].payload.stream == "game.events" and wakeups[1].payload.partition == 2 and wrong_partition == 0)
assert(wakeups[1].context.sender == "server-a" and wakeups[1].context.message_id == wake.message_id)
assert(#control:state().last_topic <= 80 and string.find(control:state().last_topic, "game.events", 1, true) == nil)

local before_duplicate = #wakeups
control:duplicate_next()
local duplicated = sender:PublishStreamWakeup("game.events", 2, 51)
assert(duplicated.code == "published" and #wakeups == before_duplicate + 2,
	"the advisory transport must tolerate duplicate delivery")

local before_unknown = #wakeups
control:fail_after_publish(1)
local unknown = sender:PublishStreamWakeup("game.events", 2, 52)
assert(unknown.code == "unknown" and #wakeups == before_unknown + 1,
	"a lost publish response must remain unknown even if the hint was delivered")

local calls_before_limit = control:state().publish_calls
local small_limit = assert(TransientMessaging.new(bus, HttpService, {
	namespace = "limited", server_id = "server-a", max_message_bytes = 128,
}))
assert(small_limit:PublishStreamWakeup("event", 1, 1).code == "capacity")
assert(control:state().publish_calls == calls_before_limit, "oversized wake-up was sent")
assert(sender:PublishStreamWakeup("game.events", 0, 1).code == "invalid")
assert(sender:PublishStreamWakeup("game.events", 2, math.huge).code == "invalid")

control:fail_subscribe(1)
assert(sender:SubscribeStreamWakeups("unavailable", 1, function() end).code == "unknown")
local before_disconnect = #wakeups
wake_subscription.subscription:Disconnect()
sender:PublishStreamWakeup("game.events", 2, 53)
assert(#wakeups == before_disconnect, "disconnected subscription still received hints")

receiver:Close()
assert(receiver:SubscribeStreamWakeups("closed", 1, function() end).code == "closed")
sender:Close()
small_limit:Close()
assert(sender:PublishStreamWakeup("game.events", 2, 54).code == "closed")

print("[PASS] transient stream wake-up routing, hashed topic names, duplicate/unknown delivery, validation, and lifecycle")
