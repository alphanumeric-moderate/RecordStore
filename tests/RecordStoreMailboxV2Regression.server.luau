--!strict
local HttpService = game:GetService("HttpService")
local ServerScriptService = game:GetService("ServerScriptService")
local MailboxV2 = require(ServerScriptService:WaitForChild("RecordStoreMailboxV2"))

local now_ms = 1_000_000
local guid_counter = 0
local function guid(): string
	guid_counter += 1
	return string.format("studio-guid-%08d", guid_counter)
end
local owner = {
	store_name = "MailboxV2_StudioTest",
	scope = "global",
	profile_key = "player-987654321",
	user_id = 987654321,
}
local options = {
	now_ms = function(): number
		return now_ms
	end,
	guid = guid,
	encode = function(value: unknown): string
		return HttpService:JSONEncode(value)
	end,
}
local store = MailboxV2.MockStore()
local mailbox = MailboxV2.new(store, owner, options)
local first = mailbox:EnqueueAsync("grant", { coins = 100 }, { idempotency_key = "studio-receipt-1" })
assert(first.code == "accepted", first.error)
now_ms += 100
local duplicate = mailbox:EnqueueAsync("grant", { coins = 100 }, { idempotency_key = "studio-receipt-1" })
assert(duplicate.code == "duplicate", duplicate.error)
assert(first.message_id == duplicate.message_id, "same idempotency key changed route")
local conflict = mailbox:EnqueueAsync("grant", { coins = 101 }, { idempotency_key = "studio-receipt-1" })
assert(conflict.code == "conflict", "different request reused a producer key")
local ordered = mailbox:EnqueueAsync("ordered", {}, { idempotency_key = "studio-order", ordering_key = "player" })
assert(ordered.code == "invalid", "unimplemented ordering_key was accepted")
local calls = 0
local lost = mailbox:ProcessNextAsync(function()
	calls += 1
	store:FailNextUpdate("after")
	return true
end)
assert(lost.code == "unknown", "commit-then-error was not reported unknown")
local recovered = mailbox:RecoverAsync()
assert(recovered.code == "success", recovered.error)
assert(calls == 1, "ack recovery invoked handler again")
local delivery, status = mailbox:GetDeliveryAsync(first.message_id)
assert(status.code == "success", status.error)
assert(delivery ~= nil and delivery.State == "acknowledged", "acknowledgement was not recovered")
print("[PASS] RecordStoreMailboxV2 Studio boundary regression.")
