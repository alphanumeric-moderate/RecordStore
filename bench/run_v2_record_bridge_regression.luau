--!nocheck
-- End-to-end contract tests for the opt-in Record -> MailboxV2 bridge.
-- Runs with Lune mocks only; it does not prove live Roblox service behavior.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local Shim = require("./RobloxShim")
local RecordStore = Shim.load()

local mailbox_chunk = luau.load(fs.readFile("src/PlayerDataInitializer/RecordStoreMailboxV2.luau"), {
	debugName = "RecordStoreMailboxV2",
	environment = Shim.environment,
})
local MailboxV2 = mailbox_chunk()
RecordStore.Mock.reset()

local STORE = "RecordStoreV2BridgeRegression"
local SCOPE = "global"
local USER_ID = 987654321
local handler_calls = {}
local record = RecordStore.Mock.new(STORE, SCOPE, "player-bridge", {
	schema_version = 1,
	retry_attempts = 1,
	user_ids = { USER_ID },
	on_queue_message = function(message_type, data, attempts, message_id, sender_job_id, created_at)
		table.insert(handler_calls, {
			message_type = message_type,
			data = data,
			attempts = attempts,
			message_id = message_id,
			sender_job_id = sender_job_id,
			created_at = created_at,
		})
		if message_type == "fail" then return false, "expected failure for dead-letter bridge test" end
		return true
	end,
})
local opened, open_message = record:Open({ coins = 0 })
assert(opened == "created" or opened == "loaded", tostring(open_message))

-- A Record bridge must reject a producer-only mailbox before queue migration.
local detached_mailbox = MailboxV2.new(MailboxV2.MockStore(), {
	store_name = STORE,
	scope = SCOPE,
	profile_key = "player-bridge",
	user_id = USER_ID,
}, {
	encode = function(value) return serde.encode("json", value) end,
	now_ms = function() return 1_000_000 end,
	guid = function() return "detached-bridge-guid" end,
})
local detached_bind, detached_bind_message = record:BindMailboxV2Async(detached_mailbox)
assert(detached_bind == "conflict", "bridge must reject a mailbox without this active Record")
assert(string.find(detached_bind_message or "", "exact active Record", 1, true) ~= nil,
	"producer-only binding failure did not explain the active Record requirement")

-- The binder must not strand already-persisted legacy queue entries in the old backend.
local legacy_enqueue, legacy_message = record:EnqueueAsync("legacy", { value = 1 })
assert(legacy_enqueue == "enqueued", tostring(legacy_message))
-- Processing must be fenced when no active session object is supplied.
local detached = MailboxV2.new(MailboxV2.MockStore(), {
	store_name = STORE,
	scope = SCOPE,
	profile_key = "detached-owner",
}, {
	encode = function(value) return serde.encode("json", value) end,
	now_ms = function() return 1_000_000 end,
	guid = function() return "detached-v2-guid" end,
})
assert(detached:EnqueueAsync("detached", { value = 1 }, { idempotency_key = "detached-1" }).code == "accepted")
local detached_process = detached:ProcessNextAsync(function() return true end)
assert(detached_process.code == "fenced", "V2 worker processed messages without an active Record session")

local legacy_mailbox = MailboxV2.new(MailboxV2.MockStore(), {
	store_name = STORE,
	scope = SCOPE,
	profile_key = "player-bridge",
	user_id = USER_ID,
}, {
	active_record = record,
	now_ms = function() return 1_000_000 end,
	guid = function() return "v2-bridge-guid" end,
	sender_job_id = "bridge-server",
	encode = function(value) return serde.encode("json", value) end,
	max_attempts = 1,
})
local blocked_bind, blocked_message = record:BindMailboxV2Async(legacy_mailbox)
assert(blocked_bind == "busy", "binding must refuse a non-empty legacy queue")
assert(string.find(blocked_message or "", "legacy queue", 1, true) ~= nil, "binding refusal did not explain the migration blocker")
local legacy_queue, legacy_queue_code, legacy_queue_message = record:GetQueueAsync()
assert(legacy_queue_code == "success" and #legacy_queue == 1, tostring(legacy_queue_message))
local legacy_process, legacy_process_message = record:ProcessQueueAsync(1)
assert(legacy_process == "processed", tostring(legacy_process_message))
assert(#handler_calls == 1 and handler_calls[1].message_type == "legacy", "legacy message was not drained through the existing API")

local bound, bind_message = record:BindMailboxV2Async(legacy_mailbox)
assert(bound == "success", tostring(bind_message))

-- Record.EnqueueAsync -> V2 canonical row -> Record.GetQueueAsync returns the same logical message.
local enqueued, enqueue_message = record:EnqueueAsync("grant", { coins = 25 }, {
	idempotency_key = "bridge-grant-1",
	priority = "high",
})
assert(enqueued == "enqueued", tostring(enqueue_message))
local duplicate, duplicate_message = record:EnqueueAsync("grant", { coins = 25 }, {
	idempotency_key = "bridge-grant-1",
	priority = "high",
})
assert(duplicate == "duplicate", tostring(duplicate_message))
local queue, queue_code, queue_message = record:GetQueueAsync()
assert(queue_code == "success", tostring(queue_message))
assert(#queue == 1, "Record.GetQueueAsync did not expose the V2 row")
assert(queue[1].Type == "grant" and queue[1].Id ~= "", "V2 queue projection changed message identity/type")
assert(queue[1].Data.coins == 25 and queue[1].SenderJobId == "bridge-server", "V2 queue projection changed payload or sender")
local v2_id = queue[1].Id

local processed, processed_message = record:ProcessQueueAsync(4)
assert(processed == "processed", tostring(processed_message))
assert(#handler_calls == 2, "Record.ProcessQueueAsync did not invoke the V2 message handler once")
assert(handler_calls[2].message_type == "grant" and handler_calls[2].data.coins == 25, "legacy handler signature was not preserved")
assert(handler_calls[2].message_id == v2_id and handler_calls[2].sender_job_id == "bridge-server",
	"V2 message metadata was not mapped to the legacy handler signature")
local empty_queue, empty_code, empty_message = record:GetQueueAsync()
assert(empty_code == "success" and #empty_queue == 0, tostring(empty_message))

-- Dead-letter views bridge safely, but legacy lock-token mutations must not touch the V2 DLQ.
local failed, failed_message = record:EnqueueAsync("fail", { item = "x" }, { idempotency_key = "bridge-fail-1" })
assert(failed == "enqueued", tostring(failed_message))
local failed_process, failed_process_message = record:ProcessQueueAsync(1)
assert(failed_process == "processed", tostring(failed_process_message))
local dead_letters, dlq_code, dlq_message = record:GetDeadLettersAsync()
assert(dlq_code == "success", tostring(dlq_message))
assert(#dead_letters == 1 and dead_letters[1].Type == "fail", "Record.GetDeadLettersAsync did not expose the V2 dead letter")
assert(dead_letters[1].LockToken == nil and dead_letters[1].LockedUntil == nil,
	"V2 dead-letter view incorrectly invented legacy lock-token semantics")
local claim, claim_code = record:ClaimDeadLetterAsync(dead_letters[1].Id)
assert(claim == nil and claim_code == "invalid", "legacy ClaimDeadLetterAsync did not fail closed for V2")
local replay_code = record:ReplayDeadLetterAsync(dead_letters[1].Id, "legacy-lock-token")
assert(replay_code == "invalid", "legacy ReplayDeadLetterAsync unexpectedly used V2 DLQ semantics")
local discard_code = record:DiscardDeadLetterAsync(dead_letters[1].Id, "legacy-lock-token")
assert(discard_code == "invalid", "legacy DiscardDeadLetterAsync unexpectedly used V2 DLQ semantics")

local direct_dlq, next_cursor, direct_result = legacy_mailbox:GetDeadLettersAsync(nil, 100)
assert(direct_result.code == "success" and #direct_dlq == 1 and next_cursor == nil,
	"direct V2 dead-letter pagination failed")

print("[PASS] Record/MailboxV2 binding, legacy queue drain guard, enqueue/read/process bridge, and DLQ semantic fencing.")
