--!nocheck
-- Successful-path benchmark for fixed-shard advisory wakeups and bounded local candidate registration.
-- It intentionally does not inject dropped/duplicated messages or storage failures in this phase.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Shim = require("./RobloxShim")
Shim.load()
local Acceleration = luau.load(
	fs.readFile("src/PlayerDataInitializer/RecordStoreV2Acceleration.luau"),
	{ debugName = "RecordStoreV2Acceleration" }
)()

local messages = {}
local memory = {}
local messaging = {
	SubscribeAsync = function(_, topic, callback)
		return { topic = topic, callback = callback, Disconnect = function() end }
	end,
	PublishAsync = function(_, topic, payload)
		table.insert(messages, { topic = topic, payload = payload })
		return true
	end,
}
local memory_map = {
	SetAsync = function(_, key, value, ttl)
		memory[key] = { value = value, ttl = ttl }
		return true
	end,
	GetAsync = function(_, key)
		local entry = memory[key]
		return if entry ~= nil then entry.value else nil
	end,
}
local now = 1_000_000
local wakeups = Acceleration.new({
	messaging_service = messaging,
	memory_map = memory_map,
	shard_count = 16,
	max_registrations = 256,
	max_candidates = 256,
	now_ms = function() return now end,
	guid = function() now += 1; return "bench-event-" .. tostring(now) end,
})

local callbacks = 0
for index = 1, 192 do
	local identity = "RecordStore:global:player-" .. tostring(index)
	local shard, owner_digest = wakeups:ShardFor(identity)
	assert(type(shard) == "number" and shard >= 1 and shard <= 16)
	assert(type(owner_digest) == "string" and #owner_digest == 32)
	assert(wakeups:Register(identity, function() callbacks += 1 end))
	assert(wakeups:Wake(identity, "manual"))
	local published = wakeups:Publish(identity, "enqueue")
	assert(published.code == "scheduled" and published.durable == false)
end

assert(wakeups:Stats().registrations == 192)
assert(wakeups:Stats().candidate_count <= 256)
print("[PASS] RecordStoreV2 fixed-shard acceleration successful-path workload.")
Shim.close()
