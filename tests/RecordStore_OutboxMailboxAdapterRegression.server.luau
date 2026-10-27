--!nocheck
local Shim = require("./RobloxShim")
local RecordStore = Shim.load()
local Mock = RecordStore.Mock
local AdapterModule = require(
	game:GetService("ServerScriptService"):WaitForChild("PlayerDataInitializer"):WaitForChild("RecordStoreOutboxMailboxAdapter")
)

local function expect(value, message) assert(value, message) end
Mock.reset()
Mock.set_test_clock(function() return 1000 end)

local source = Mock.new("OutboxMailboxAdapterSource", "global", "source", {
	schema_version = 1, transactional_operations_enabled = true, durable_queue_enabled = true,
	queue_store_name = "OutboxMailboxAdapterSourceQueue",
})
local destination = Mock.new("OutboxMailboxAdapterDestination", "global", "destination", {
	schema_version = 1, transactional_operations_enabled = true, durable_queue_enabled = true,
	queue_store_name = "OutboxMailboxAdapterDestinationQueue", user_ids = { 123456 },
})
local source_open, source_open_message = source:Open({ Balance = 100 })
local destination_open, destination_open_message = destination:Open({ Balance = 5 })
expect(source_open == "created" or source_open == "loaded", "source open: " .. tostring(source_open_message))
expect(destination_open == "created" or destination_open == "loaded", "destination open: " .. tostring(destination_open_message))

local _, commit_status, commit_message = source:CommitWithOutboxAsync(
	"transfer:source-001", "CreditBalance", { amount = 30, destination = "destination" },
	{ {
		target_store = "OutboxMailboxAdapterDestination", target_scope = "global", target_key = "destination",
		target_user_id = 123456, type = "CreditBalance", payload_version = 1,
		data = { amount = 30 }, correlation_id = "transfer-correlation-001", causation_id = "transfer-command-001",
	} },
	function(data, command)
		local updated = table.clone(data)
		updated.Balance -= command.amount
		return updated, { debited = command.amount }
	end
)
expect(commit_status == "committed", "source transaction: " .. tostring(commit_message))
expect(source:Get().Balance == 70, "source debit and outbox intent did not commit together")
local events, read_status, read_message = source:GetOutboxAsync(1)
expect(read_status == "success" and #events == 1, "outbox read: " .. tostring(read_message))
local event = events[1]
local diagnostics = {}
local adapter = AdapterModule.new({
	get_record = function(candidate)
		if candidate.DestinationStoreName == "OutboxMailboxAdapterDestination"
			and candidate.DestinationScope == "global" and candidate.DestinationProfileKey == "destination"
		then return destination end
		return nil
	end,
	activation_guard = function(record, _operation) return record:GetState() == "active" and record:IsOpen() end,
	on_diagnostic = function(diagnostic) table.insert(diagnostics, diagnostic) end,
})
source:Close()
local delivered_count, dispatch_status, dispatch_message = source:DispatchOutboxAsync(adapter.Dispatch, 1)
expect(dispatch_status == "success", "outbox dispatch: " .. tostring(dispatch_status) .. " " .. tostring(dispatch_message))
expect(delivered_count == 1, "destination acceptance was not acknowledged")
local raw = Mock.get_record_raw("OutboxMailboxAdapterSource", "global", "source")
local stored_event = raw.sidecars.outbox_events[event.EventId]
expect(stored_event.state == "delivered", "source event not marked delivered")
expect(type(stored_event.destination_receipt_id) == "string" and stored_event.destination_receipt_id ~= "",
	"destination receipt ID was not stored")
local mailbox = adapter:GetMailbox(destination)
expect(mailbox ~= nil, "destination mailbox was not cached")
local receipt_id = string.gsub(stored_event.destination_receipt_id, "^mailbox:", "")
local delivery, delivery_result = mailbox:GetDeliveryAsync(receipt_id)
expect(delivery ~= nil and delivery_result.code == "success", "durable destination receipt could not be read")
expect(delivery.Type == "CreditBalance", "wrong destination message type")
expect(delivery.Data.source_event_id == event.EventId and delivery.Data.payload_version == 1,
	"source event identity/version was not preserved")
expect(delivery.Data.payload.amount == 30, "destination payload changed")
local duplicate_ok, duplicate_receipt = adapter.Dispatch(event)
expect(duplicate_ok and duplicate_receipt == stored_event.destination_receipt_id, "duplicate retry changed receipt")
local queue, queue_status, queue_message = destination:GetQueueAsync()
expect(queue_status == "success", "destination queue read: " .. tostring(queue_message))
local duplicate_count = 0
for _, item in ipairs(queue) do
	if item.Data and item.Data.source_event_id == event.EventId then duplicate_count += 1 end
end
expect(duplicate_count == 1, "duplicate retry created multiple destination messages")

local wrong_target = AdapterModule.new({
	get_record = function() return source end,
	activation_guard = function() return true end,
	on_diagnostic = function(diagnostic) table.insert(diagnostics, diagnostic) end,
})
expect(not wrong_target.Dispatch(event), "wrong destination record was accepted")
local denied = AdapterModule.new({
	get_record = function() return destination end,
	activation_guard = function() return false, "rollout disabled" end,
	on_diagnostic = function(diagnostic) table.insert(diagnostics, diagnostic) end,
})
expect(not denied.Dispatch(event), "explicit rollout denial was ignored")
expect(diagnostics[#diagnostics].category == "destination_mailbox_unavailable", "rollout denial was not diagnosed")

local malformed_time = table.clone(event)
malformed_time.CreatedAt = math.huge
expect(not adapter.Dispatch(malformed_time), "outbox adapter accepted a non-finite event timestamp")
expect(diagnostics[#diagnostics].category == "invalid_event", "invalid timestamp was not rejected before destination lookup")
local malformed_time_type = table.clone(event)
malformed_time_type.CreatedAt = "not-a-timestamp"
local malformed_time_call_ok, malformed_time_dispatched = pcall(function()
	return adapter.Dispatch(malformed_time_type)
end)
expect(malformed_time_call_ok and malformed_time_dispatched == false,
	"outbox adapter threw instead of rejecting a string timestamp")
expect(diagnostics[#diagnostics].category == "invalid_event", "string timestamp was not diagnosed")
local malformed_trace = table.clone(event)
malformed_trace.CorrelationId = {}
expect(not adapter.Dispatch(malformed_trace), "outbox adapter accepted non-string correlation metadata")
expect(diagnostics[#diagnostics].category == "invalid_event", "invalid trace metadata was not diagnosed")
local malformed_attempts = table.clone(event)
malformed_attempts.Attempts = "0"
local malformed_attempts_call_ok, malformed_attempts_dispatched = pcall(function()
	return adapter.Dispatch(malformed_attempts)
end)
expect(malformed_attempts_call_ok and malformed_attempts_dispatched == false,
	"outbox adapter threw instead of rejecting a string attempt counter")
expect(diagnostics[#diagnostics].category == "invalid_event", "string attempt counter was not diagnosed")
local non_dispatchable = table.clone(event)
non_dispatchable.State = "delivered"
expect(not adapter.Dispatch(non_dispatchable), "outbox adapter dispatched an event outside pending/unknown state")
expect(diagnostics[#diagnostics].category == "invalid_event", "invalid dispatch state was not diagnosed")
local missing_payload = table.clone(event)
missing_payload.Payload = nil
expect(not adapter.Dispatch(missing_payload), "outbox adapter accepted an event with no payload")

local unsafe_destination_user = table.clone(event)
unsafe_destination_user.DestinationUserId = 9007199254740992
expect(not adapter.Dispatch(unsafe_destination_user),
	"outbox mailbox adapter accepted a destination UserId beyond the safe-integer range")
expect(diagnostics[#diagnostics].category == "invalid_event",
	"unsafe destination UserId was not rejected at the outbox adapter boundary")

destination:Close()
Mock.reset()
Shim.close()
