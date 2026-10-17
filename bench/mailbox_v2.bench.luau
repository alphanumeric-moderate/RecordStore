--!nocheck
-- CodSpeed workload: end-to-end enqueue, priority selection, claim, and acknowledgement on an isolated mock.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local MailboxV2 = luau.load(fs.readFile("src/PlayerDataInitializer/RecordStoreMailboxV2.luau"), {
	debugName = "RecordStoreMailboxV2",
})()

local MESSAGES = 12
local function run_workload()
	local now = 5_000_000
	local guid = 0
	local store = MailboxV2.MockStore()
	local mailbox = MailboxV2.new(store, {
		store_name = "MailboxV2_CodSpeed",
		scope = "global",
		profile_key = "benchmark-owner",
		user_id = 135792468,
	}, {
		now_ms = function()
			return now
		end,
		guid = function()
			guid += 1
			return ("bench-guid-%08d"):format(guid)
		end,
		encode = function(value)
			return serde.encode("json", value)
		end,
	})
	for index = 1, MESSAGES do
		local result = mailbox:EnqueueAsync("bench_message", {
			sequence = index,
			payload = string.rep("x", index * 16),
		}, {
			idempotency_key = "bench-" .. tostring(index),
			priority = if index % 4 == 0 then "high" elseif index % 2 == 0 then "background" else "normal",
		})
		assert(result.code == "accepted", "enqueue failed: " .. tostring(result.code) .. " " .. tostring(result.error))
	end
	local completed = 0
	for _ = 1, MESSAGES do
		local result = mailbox:ProcessNextAsync(function()
			completed += 1
			return true
		end)
		assert(result.code == "processed", "processing failed: " .. tostring(result.code))
	end
	assert(completed == MESSAGES, "workload dropped accepted messages")
end

for _ = 1, 2 do
	run_workload()
end
print("[PASS] MailboxV2 end-to-end CodSpeed workload.")
