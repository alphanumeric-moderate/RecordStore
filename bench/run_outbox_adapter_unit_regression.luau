--!nocheck
-- Usage (from the repository root): lune run bench/run_outbox_adapter_unit_regression.luau
-- Isolate adapter decisions from the durable protocols covered by the Mock suites.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Shim = require("./RobloxShim")

local function expect(value, message)
	assert(value, message)
end

local function clone(value)
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, child in pairs(value) do copy[key] = clone(child) end
	return copy
end

local function load_adapter(name, core, v2)
	local environment = table.clone(Shim.environment)
	environment.script = { Parent = { WaitForChild = function(_self, module_name) return module_name end } }
	environment.require = function(module_name)
		if module_name == "RecordStore" then return core end
		if module_name == "RecordStoreV2" then return v2 end
		error("unexpected adapter dependency: " .. tostring(module_name))
	end
	return luau.load(fs.readFile("src/PlayerDataInitializer/" .. name .. ".luau"), {
		debugName = name, environment = environment,
	})()
end

local function make_destination()
	local record = {
		state = "active", is_open = true, storage_calls = 0,
		identity = { store_name = "Destination", scope = "global", profile_key = "player-123", user_ids = { 123 } },
	}
	function record:GetState() return self.state end
	function record:IsOpen() return self.is_open end
	function record:GetIdentity() return self.identity end
	function record:GetMailboxOwner() return { store_name = "Destination", scope = "global", profile_key = "player-123" } end
	function record:CreateMailboxStoreAdapter() self.storage_calls += 1; return {}, "success" end
	function record:BindMailboxV2Async() return "success" end
	return record
end

local function make_producer()
	local f = { record = make_destination(), diagnostics = {}, lookups = 0, allowed = true, creates = 0 }
	f.event = {
		EventId = "event-1", EventType = "CreditBalance", PayloadVersion = 1,
		Payload = { amount = 30, metadata = { tag = "original" } },
		DestinationStoreName = "Destination", DestinationScope = "global", DestinationProfileKey = "player-123",
		DestinationUserId = 123, CorrelationId = "correlation-1", CausationId = "command-1",
		CreatedAt = 1000, Attempts = 0, State = "pending",
	}
	f.mailbox = { enqueue_calls = 0, read_calls = 0 }
	function f.mailbox:EnqueueAsync(event_type, payload, options)
		self.enqueue_calls += 1
		expect(options.idempotency_key == f.event.EventId, "producer did not use the stable source event ID")
		self.snapshot = { Id = "message-1", Type = event_type, Data = clone(payload) }
		return { code = "accepted", message_id = "message-1" }
	end
	function f.mailbox:GetDeliveryAsync(message_id)
		self.read_calls += 1
		expect(message_id == "message-1", "producer read a different destination receipt")
		return clone(self.snapshot), { code = "success" }
	end
	local core = { MailboxV2 = { new = function() f.creates += 1; return f.mailbox end } }
	f.module = load_adapter("RecordStoreOutboxMailboxAdapter", core)
	f.config = {
		get_record = function() f.lookups += 1; return f.record end,
		activation_guard = function()
			if f.guard_error then error("injected activation failure") end
			return f.allowed, "rollout disabled"
		end,
		on_diagnostic = function(diagnostic)
			expect(table.isfrozen(diagnostic), "diagnostic exposed mutable state")
			table.insert(f.diagnostics, diagnostic)
		end,
	}
	f.adapter = f.module.new(f.config)
	return f
end

-- A receipt is acknowledged only after a matching durable read-back, for both
-- first delivery and idempotent retries (including unknown source outcomes).
for _, enqueue_code in { "accepted", "duplicate" } do
	local f = make_producer()
	f.event.State = "unknown"
	local enqueue = f.mailbox.EnqueueAsync
	function f.mailbox:EnqueueAsync(...)
		local result = enqueue(self, ...)
		result.code = enqueue_code
		return result
	end
	local accepted, receipt = f.adapter.Dispatch(f.event)
	expect(accepted == true and receipt == "mailbox:message-1", "verified destination receipt was not acknowledged")
	expect(f.mailbox.read_calls == 1 and f.creates == 1, "producer skipped durable receipt verification")
	local payload = f.mailbox.snapshot.Data
	expect(payload.source_event_id == f.event.EventId and payload.payload_version == 1
		and payload.payload.amount == 30 and payload.payload.metadata.tag == "original"
		and payload.correlation_id == "correlation-1" and payload.causation_id == "command-1"
		and payload.source_created_at == 1000 and payload.destination_store_name == "Destination"
		and payload.destination_scope == "global" and payload.destination_profile_key == "player-123"
		and payload.destination_user_id == 123, "producer lost payload, destination or tracing metadata")
	expect(f.adapter:GetMailbox(f.record) == f.mailbox, "producer did not cache the bound mailbox")
	f.allowed = false
	expect(f.adapter.Dispatch(f.event) == false and f.mailbox.enqueue_calls == 1,
		"cached mailbox bypassed a revoked activation guard")
end

local invalid_events = {
	{ field = "EventId", value = "" }, { field = "EventId", value = string.rep("e", 257) },
	{ field = "EventType", value = string.rep("t", 101) },
	{ field = "PayloadVersion", value = 0 }, { field = "PayloadVersion", value = 1.5 },
	{ field = "Payload" }, { field = "DestinationStoreName", value = string.rep("s", 51) },
	{ field = "DestinationScope", value = string.rep("s", 51) }, { field = "DestinationProfileKey", value = "" },
	{ field = "DestinationUserId", value = 9007199254740992 }, { field = "DestinationUserId", value = 0 },
	{ field = "CorrelationId", value = string.rep("c", 257) }, { field = "CausationId", value = {} },
	{ field = "CreatedAt", value = -1 }, { field = "CreatedAt", value = 0 / 0 },
	{ field = "Attempts", value = 0.5 }, { field = "Attempts", value = math.huge },
	{ field = "State", value = "delivered" },
}
for _, case in ipairs(invalid_events) do
	local f = make_producer()
	f.event[case.field] = case.value
	local ok, dispatched = pcall(f.adapter.Dispatch, f.event)
	expect(ok and dispatched == false and f.lookups == 0 and f.creates == 0,
		"invalid event reached destination lookup/storage: " .. case.field)
	expect(f.diagnostics[1].category == "invalid_event", "invalid event was not diagnosed: " .. case.field)
end
do
	local f = make_producer()
	f.event.Payload = false
	f.event.DestinationScope = ""
	f.record.identity.scope = ""
	f.event.CreatedAt = 0
	expect(f.adapter.Dispatch(f.event) == true, "valid false payload/empty scope/zero timestamp was rejected")
end

for _, mismatch in { "store_name", "scope", "profile_key", "user_ids", "state", "is_open" } do
	local f = make_producer()
	if mismatch == "user_ids" then f.record.identity.user_ids = { 456 }
	elseif mismatch == "state" then f.record.state = "unknown"
	elseif mismatch == "is_open" then f.record.is_open = false
	else f.record.identity[mismatch] = "wrong" end
	expect(f.adapter.Dispatch(f.event) == false and f.record.storage_calls == 0,
		"producer wrote to an unowned/mismatched destination: " .. mismatch)
end

local producer_failures = {
	{ name = "lookup throws", category = "destination_unavailable", rejects = true,
		setup = function(f) f.config.get_record = function() error("lookup failure") end end },
	{ name = "lookup missing", category = "destination_unavailable", rejects = true,
		setup = function(f) f.config.get_record = function() return nil end end },
	{ name = "guard throws", category = "destination_mailbox_unavailable",
		setup = function(f) f.guard_error = true end },
	{ name = "binding unknown", category = "destination_mailbox_unavailable",
		setup = function(f) f.record.BindMailboxV2Async = function() return "unknown", "response lost" end end },
	{ name = "enqueue throws", category = "destination_enqueue_unknown",
		setup = function(f) f.mailbox.EnqueueAsync = function() error("enqueue failure") end end },
	{ name = "enqueue malformed", category = "destination_enqueue_unknown",
		setup = function(f) f.mailbox.EnqueueAsync = function() return nil end end },
	{ name = "enqueue unknown", category = "destination_enqueue_unknown",
		setup = function(f) f.mailbox.EnqueueAsync = function() return { code = "unknown" } end end },
	{ name = "enqueue rejected", category = "destination_enqueue_rejected", rejects = true,
		setup = function(f) f.mailbox.EnqueueAsync = function() return { code = "full", error = "capacity" } end end },
	{ name = "accepted without receipt", category = "destination_receipt_missing",
		setup = function(f) f.mailbox.EnqueueAsync = function() return { code = "accepted" } end end },
	{ name = "read throws", category = "destination_receipt_unverified",
		setup = function(f) f.mailbox.GetDeliveryAsync = function() error("read failure") end end },
	{ name = "read unknown", category = "destination_receipt_unverified",
		setup = function(f) f.mailbox.GetDeliveryAsync = function() return nil, { code = "unknown" } end end },
}
for _, case in ipairs(producer_failures) do
	local f = make_producer()
	case.setup(f)
	f.adapter = f.module.new(f.config)
	local ok, dispatched = pcall(f.adapter.Dispatch, f.event)
	if case.rejects then
		expect(ok and dispatched == false, "definitive rejection was not returned: " .. case.name)
	else
		expect(not ok, "unresolved destination outcome was acknowledged or made a definitive rejection: " .. case.name)
	end
	expect(f.diagnostics[#f.diagnostics].category == case.category, "wrong failure diagnostic: " .. case.name)
end

-- A message ID alone cannot prove that a duplicate destination receipt belongs
-- to this exact event. Check nested payload differences and extra fields too.
for _, mutation in {
	function(snapshot) snapshot.Id = "other-message" end,
	function(snapshot) snapshot.Type = "OtherEvent" end,
	function(snapshot) snapshot.Data.source_event_id = "other-event" end,
	function(snapshot) snapshot.Data.payload.metadata.tag = "tampered" end,
	function(snapshot) snapshot.Data.payload.metadata.extra = true end,
	function(snapshot) snapshot.Data.payload.metadata = nil end,
} do
	local f = make_producer()
	local read = f.mailbox.GetDeliveryAsync
	function f.mailbox:GetDeliveryAsync(id)
		local snapshot, result = read(self, id)
		mutation(snapshot)
		return snapshot, result
	end
	expect(not pcall(f.adapter.Dispatch, f.event), "producer acknowledged a conflicting durable receipt")
	expect(f.diagnostics[1].category == "destination_receipt_conflict", "conflicting receipt was not diagnosed")
	expect(f.event.Payload.metadata.tag == "original" and f.event.Payload.metadata.extra == nil,
		"receipt verification changed the original source event")
end

local function make_consumer()
	local f = { record = make_destination(), diagnostics = {}, inbox_calls = 0, reducer_calls = 0, data = { Balance = 5 } }
	f.envelope = {
		source_event_id = "event-1", payload_version = 1, payload = { amount = 30 },
		source_created_at = 1000, destination_store_name = "Destination", destination_scope = "global",
		destination_profile_key = "player-123", destination_user_id = 123,
		correlation_id = "correlation-1", causation_id = "command-1",
	}
	f.snapshot = { Id = "message-1", Type = "CreditBalance", Attempts = 1 }
	f.mailbox = { process_calls = 0 }
	function f.mailbox:ProcessNextAsync(handler)
		self.process_calls += 1
		if f.native_results then return table.remove(f.native_results, 1) end
		local handled = handler(f.envelope, f.snapshot, f.context)
		return { code = if handled then "processed" else "retry_scheduled", message_id = f.snapshot.Id }
	end
	local core = { MailboxV2 = { new = function() return f.mailbox end } }
	local inbox = {
		ApplyAsync = function(record, message, reducer)
			expect(record == f.record and message.message_id == "event-1", "Inbox lost destination/source identity")
			f.inbox_calls += 1
			if f.inbox_result then return f.inbox_result end
			local data = reducer(clone(f.data), message.payload)
			if data == nil then return { code = "invalid" } end
			f.data = data
			return { code = "committed" }
		end,
		PruneReceipts = function(record, cutoff, maximum, operation_id)
			f.prune_args = { record, cutoff, maximum, operation_id }
			if f.prune_error then error("prune response lost") end
			return f.prune_result or { code = "committed", pruned = 3 }
		end,
	}
	local v2 = { new = function(supplied_core, mailbox)
		expect(supplied_core == core and mailbox == core.MailboxV2, "consumer used a different core/mailbox")
		return { Inbox = inbox }
	end }
	f.module = load_adapter("RecordStoreOutboxConsumerAdapter", core, v2)
	f.config = {
		activation_guard = function() return true end,
		handlers = { CreditBalance = { payload_version = 1, reduce = function(current, payload, context)
			f.reducer_calls += 1
			f.event_context = context
			current.Balance += payload.amount
			return current
		end } },
		on_diagnostic = function(diagnostic) table.insert(f.diagnostics, diagnostic) end,
	}
	f.processor = f.module.new(f.config)
	return f
end

do
	local f = make_consumer()
	-- Caller mutation after construction must not replace the registered handler.
	f.config.handlers.CreditBalance.payload_version = 2
	f.config.handlers.CreditBalance.reduce = function() error("mutated caller configuration was used") end
	local result = f.processor:ProcessNextAsync(f.record)
	expect(result.code == "processed" and result.processed == 1 and result.message_id == "message-1"
		and f.data.Balance == 35 and f.reducer_calls == 1, "valid consumer event was not committed")
	local context = f.event_context
	expect(table.isfrozen(context) and context.EventId == "event-1" and context.EventType == "CreditBalance"
		and context.PayloadVersion == 1 and context.SourceCreatedAt == 1000 and context.Attempt == 1
		and context.MailboxMessageId == "message-1" and context.CorrelationId == "correlation-1"
		and context.CausationId == "command-1" and context.DestinationUserId == 123
		and context.DestinationStoreName == "Destination" and context.DestinationScope == "global"
		and context.DestinationProfileKey == "player-123", "consumer lost immutable event context")
end

for _, case in {
	{ field = "source_event_id", value = "" }, { field = "payload_version", value = 2 },
	{ field = "payload" }, { field = "source_created_at", value = math.huge },
	{ field = "destination_store_name", value = "OtherStore" },
	{ field = "destination_scope", value = "other" }, { field = "destination_profile_key", value = "other" },
	{ field = "destination_user_id", value = 456 }, { field = "destination_user_id", value = 9007199254740992 },
	{ field = "correlation_id", value = "" }, { field = "causation_id", value = {} },
} do
	local f = make_consumer()
	f.envelope[case.field] = case.value
	expect(f.processor:ProcessNextAsync(f.record).code == "retry_scheduled"
		and f.inbox_calls == 0 and f.reducer_calls == 0 and f.data.Balance == 5,
		"invalid/unsupported envelope reached Inbox or a reducer: " .. case.field)
end
for _, change in {
	function(f) f.snapshot.Type = "UnregisteredType" end,
	function(f) f.snapshot.Id = "" end,
	function(f) f.snapshot.Attempts = 0.5 end,
	function(f) f.context = { is_cancelled = function() return true end } end,
	function(f) f.context = { is_cancelled = function() error("claim check failed") end } end,
} do
	local f = make_consumer()
	change(f)
	expect(f.processor:ProcessNextAsync(f.record).code == "retry_scheduled" and f.inbox_calls == 0,
		"invalid message or cancelled claim reached Inbox")
end

for _, code in { "duplicate", "unknown", "conflict", "fenced" } do
	local f = make_consumer()
	f.inbox_result = { code = code }
	local result = f.processor:ProcessNextAsync(f.record)
	expect(result.code == (if code == "duplicate" then "processed" else "retry_scheduled")
		and f.inbox_calls == 1 and f.reducer_calls == 0, "consumer mishandled Inbox outcome " .. code)
end
do
	local f = make_consumer()
	local checks = 0
	f.context = { is_cancelled = function() checks += 1; return checks > 1 end }
	expect(f.processor:ProcessNextAsync(f.record).code == "retry_scheduled" and f.data.Balance == 35,
		"claim cancellation after commit was acknowledged or lost the committed mutation")
	f.inbox_result = { code = "duplicate" }
	f.context = nil
	expect(f.processor:ProcessNextAsync(f.record).code == "processed" and f.reducer_calls == 1,
		"retry after post-commit cancellation did not acknowledge the Inbox duplicate")
end

-- Batch limits bound work and preserve the first incomplete/unknown outcome.
for _, maximum in { 0, 17, 1.5, math.huge, 0 / 0, "2" } do
	local f = make_consumer()
	local result = f.processor:ProcessBatchAsync(f.record, maximum)
	expect(result.code == "invalid" and result.processed == 0 and f.mailbox.process_calls == 0,
		"invalid batch bound performed consumer work")
end
for _, maximum in { 1, 16 } do
	local f = make_consumer()
	f.native_results = table.create(maximum, { code = "processed" })
	local result = f.processor:ProcessBatchAsync(f.record, maximum)
	expect(result.code == "incomplete" and result.processed == maximum and f.mailbox.process_calls == maximum,
		"batch did not stop at its exact message cap")
end
do
	local f = make_consumer()
	f.native_results = { { code = "processed" }, { code = "duplicate" }, { code = "empty" } }
	local result = f.processor:ProcessBatchAsync(f.record)
	expect(result.code == "completed" and result.processed == 2 and f.mailbox.process_calls == 3,
		"batch did not count duplicates or stop when empty")
	f.native_results = { { code = "processed" }, { code = "unknown", message_id = "uncertain", error = "lost response" }, { code = "processed" } }
	result = f.processor:ProcessBatchAsync(f.record, 3)
	expect(result.code == "unknown" and result.processed == 1 and result.message_id == "uncertain"
		and result.message == "lost response" and #f.native_results == 1,
		"batch advanced past or lost an unresolved outcome")
end

do
	local f = make_consumer()
	local result = f.processor:PruneInboxReceiptsAsync(f.record, 1000, "prune-1")
	expect(result.code == "committed" and result.processed == 3
		and f.prune_args[1] == f.record and f.prune_args[2] == 1000
		and f.prune_args[3] == 16 and f.prune_args[4] == "prune-1",
		"pruning lost its default bound, cutoff or stable operation identity")
	for _, args in { { -1, "prune-1", 1 }, { math.huge, "prune-1", 1 }, { 1000, "", 1 },
		{ 1000, string.rep("p", 257), 1 }, { 1000, "prune-1", 0 }, { 1000, "prune-1", 17 } } do
		f.prune_args = nil
		expect(f.processor:PruneInboxReceiptsAsync(f.record, table.unpack(args)).code == "invalid"
			and f.prune_args == nil, "invalid pruning parameters reached Inbox")
	end
	f.prune_error = true
	expect(f.processor:PruneInboxReceiptsAsync(f.record, 1000, "prune-1", 1).code == "unknown",
		"pruning exception did not remain unresolved")
	f.record.state = "unknown"
	f.prune_args = nil
	expect(f.processor:PruneInboxReceiptsAsync(f.record, 1000, "prune-1", 1).code == "fenced"
		and f.prune_args == nil, "pruning continued after ownership became uncertain")
end

print("[OutboxAdapters] durable receipt verification, failure classification, consumer admission, cancellation and bounded work passed")
