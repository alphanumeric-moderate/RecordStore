--!nocheck
-- Deferred until all PR #56 implementation slices are present.
local Shim = require("./RobloxShim")
local RecordStore = Shim.load()
local Mock = RecordStore.Mock
local ConsumerModule = require(
	game:GetService("ServerScriptService"):WaitForChild("PlayerDataInitializer"):WaitForChild("RecordStoreOutboxConsumerAdapter")
)

local function expect(value, message)
	assert(value, message)
end

local function make_event(event_id, target_key, amount, payload_version)
	return {
		source_event_id = event_id,
		payload_version = payload_version or 1,
		payload = { amount = amount },
		correlation_id = "transfer-correlation-" .. event_id,
		causation_id = "transfer-command-" .. event_id,
		source_created_at = 1000,
		destination_store_name = "OutboxConsumerDestination",
		destination_scope = "global",
		destination_profile_key = target_key,
		destination_user_id = 123456,
	}
end

Mock.reset()
Mock.set_test_clock(function() return 1000 end)

local destination = Mock.new("OutboxConsumerDestination", "global", "destination", {
	schema_version = 1,
	user_ids = { 123456 },
	transactional_operations_enabled = true,
	durable_queue_enabled = true,
	queue_store_name = "OutboxConsumerDestinationQueue",
})
local opened, open_message = destination:Open({
	Balance = 5,
	GrantCount = 0,
	LastEventId = "",
})
expect(opened == "created" or opened == "loaded", "destination profile open failed: " .. tostring(open_message))

local processor = ConsumerModule.new({
	activation_guard = function(record, _operation)
		return record:GetState() == "active" and record:IsOpen(), "destination activation denied"
	end,
	handlers = {
		CreditBalance = {
			payload_version = 1,
			reduce = function(current_data, payload, context)
				if type(current_data) ~= "table" or type(payload) ~= "table"
					or type(payload.amount) ~= "number" or not math.isfinite(payload.amount)
					or payload.amount < 0
				then
					return nil, "credit payload is malformed"
				end
				local next_data = table.clone(current_data)
				next_data.Balance += payload.amount
				next_data.GrantCount += 1
				next_data.LastEventId = context.EventId
				next_data.LastCorrelationId = context.CorrelationId
				return next_data
			end,
		},
	},
})

local mailbox, mailbox_code, mailbox_message = processor:GetMailbox(destination)
expect(mailbox ~= nil and mailbox_code == nil,
	"consumer mailbox creation failed: " .. tostring(mailbox_code) .. " " .. tostring(mailbox_message))
local event = make_event("outbox-event-001", "destination", 30, 1)
local first_enqueue = mailbox:EnqueueAsync("CreditBalance", event, {
	idempotency_key = "transport-message-001",
})
expect(first_enqueue.code == "accepted" and type(first_enqueue.message_id) == "string",
	"first outbox event enqueue failed: " .. tostring(first_enqueue.error))

local first_process = processor:ProcessNextAsync(destination)
expect(first_process.code == "processed",
	"consumer did not process the durable destination message: " .. tostring(first_process.message))
expect(destination:Get().Balance == 35 and destination:Get().GrantCount == 1,
	"destination profile mutation was not committed through the inbox transaction")
expect(destination:Get().LastEventId == "outbox-event-001",
	"destination profile reducer did not receive the source event identity")
expect(destination:Get().LastCorrelationId == "transfer-correlation-outbox-event-001",
	"correlation metadata was not exposed to the destination reducer")

-- A distinct transport message carrying the same source event must be applied
-- as an Inbox duplicate, then acknowledged without repeating the profile mutation.
local duplicate_enqueue = mailbox:EnqueueAsync("CreditBalance", event, {
	idempotency_key = "transport-message-002",
})
expect(duplicate_enqueue.code == "accepted",
	"duplicate source event transport fixture was not enqueued: " .. tostring(duplicate_enqueue.error))
local duplicate_process = processor:ProcessNextAsync(destination)
expect(duplicate_process.code == "processed",
	"duplicate source event was not acknowledged after durable inbox reconciliation")
expect(destination:Get().Balance == 35 and destination:Get().GrantCount == 1,
	"duplicate source event mutated destination data more than once")

-- The transport cannot redirect an event to another profile by forging its
-- envelope. The invalid message is kept retryable, and destination data is unchanged.
local forged = make_event("outbox-event-forged-target", "different-profile", 900, 1)
local forged_enqueue = mailbox:EnqueueAsync("CreditBalance", forged, {
	idempotency_key = "transport-forged-target",
})
expect(forged_enqueue.code == "accepted", "forged-target regression fixture enqueue failed")
local forged_process = processor:ProcessNextAsync(destination)
expect(forged_process.code == "retry_scheduled" or forged_process.code == "unknown",
	"consumer acknowledged an event whose exact destination locator did not match")
expect(destination:Get().Balance == 35 and destination:Get().GrantCount == 1,
	"forged destination locator mutated the active profile")

local unsafe_user_event = make_event("outbox-event-unsafe-user", "destination", 800, 1)
unsafe_user_event.destination_user_id = 9007199254740992
local unsafe_user_enqueue = mailbox:EnqueueAsync("CreditBalance", unsafe_user_event, {
	idempotency_key = "transport-unsafe-user",
})
expect(unsafe_user_enqueue.code == "accepted",
	"unsafe-UserId consumer fixture was not enqueued: " .. tostring(unsafe_user_enqueue.error))
local unsafe_user_process = processor:ProcessNextAsync(destination)
expect(unsafe_user_process.code == "retry_scheduled" or unsafe_user_process.code == "unknown",
	"outbox consumer acknowledged an unsafe destination UserId")
expect(destination:Get().Balance == 35 and destination:Get().GrantCount == 1,
	"unsafe destination UserId mutated profile data")

-- Version changes are explicit; an unsupported version is not interpreted by
-- the v1 reducer and never advances the destination Inbox receipt.
local unsupported = make_event("outbox-event-version-002", "destination", 700, 2)
local unsupported_enqueue = mailbox:EnqueueAsync("CreditBalance", unsupported, {
	idempotency_key = "transport-version-002",
})
expect(unsupported_enqueue.code == "accepted", "unsupported-version fixture enqueue failed")
local unsupported_process = processor:ProcessNextAsync(destination)
expect(unsupported_process.code == "retry_scheduled" or unsupported_process.code == "unknown",
	"consumer acknowledged an unsupported payload version")
expect(destination:Get().Balance == 35 and destination:Get().GrantCount == 1,
	"unsupported payload version mutated destination data")

-- Application activation remains an explicit opt-in for every consumer mailbox.
local denied_processor = ConsumerModule.new({
	activation_guard = function() return false, "rollout disabled" end,
	handlers = {
		CreditBalance = {
			payload_version = 1,
			reduce = function(current_data) return table.clone(current_data) end,
		},
	},
})
local denied_mailbox, denied_code = denied_processor:GetMailbox(destination)
expect(denied_mailbox == nil and denied_code == "disabled",
	"consumer was enabled when the application activation guard denied binding")

-- Pruning is explicit, bounded and uses a stable operation ID so an ambiguous
-- pruning response can be retried without corrupting destination profile data.
local pruned = processor:PruneInboxReceiptsAsync(
	destination, os.time() + 1, "outbox-consumer-prune-inbox-001", 16
)
expect(pruned.code == "committed" or pruned.code == "duplicate",
	"bounded Inbox receipt pruning did not reconcile: " .. tostring(pruned.message))
expect(destination:Get().Balance == 35 and destination:Get().GrantCount == 1,
	"Inbox receipt pruning mutated application-owned profile data")

expect(destination:Close() == "closed", "destination profile failed to close")
Mock.reset()
Shim.close()
