--!strict
-- Opt-in destination consumer for outbox events forwarded through Mailbox V2.
-- Call ProcessBatchAsync directly from a worker/maintenance loop. Do not call it
-- from Record:ProcessQueueAsync, because that API holds the Record queue mutex.
local RecordStore = require(script.Parent:WaitForChild("RecordStore"))
local RecordStoreV2Factory = require(script.Parent:WaitForChild("RecordStoreV2"))
local MailboxV2 = (RecordStore :: any).MailboxV2

local OutboxConsumerAdapter = {}

export type EventContext = {
	EventId: string,
	EventType: string,
	PayloadVersion: number,
	CorrelationId: string?,
	CausationId: string?,
	SourceCreatedAt: number,
	DestinationStoreName: string,
	DestinationScope: string,
	DestinationProfileKey: string,
	DestinationUserId: number?,
	MailboxMessageId: string,
	Attempt: number,
}

export type DestinationReducer = (
	current_data: RecordStore.JsonValue,
	payload: RecordStore.JsonValue,
	context: EventContext
) -> (RecordStore.JsonValue?, string?)

export type HandlerDefinition = {
	payload_version: number,
	reduce: DestinationReducer,
}

export type Diagnostic = {
	category: string,
	event_id: string?,
	status: string?,
	message: string?,
}

export type Config = {
	activation_guard: (RecordStore.Record, string) -> (boolean, string?),
	handlers: { [string]: HandlerDefinition },
	on_diagnostic: ((Diagnostic) -> ())?,
}

export type ProcessResult = {
	code: string,
	processed: number?,
	message_id: string?,
	message: string?,
	native_code: string?,
}

export type Processor = {
	GetMailbox: (self: Processor, record: RecordStore.Record) -> (any?, string?, string?),
	ProcessNextAsync: (self: Processor, record: RecordStore.Record) -> ProcessResult,
	ProcessBatchAsync: (self: Processor, record: RecordStore.Record, max_messages: number?) -> ProcessResult,
	PruneInboxReceiptsAsync: (
		self: Processor,
		record: RecordStore.Record,
		older_than_unix: number,
		operation_id: string,
		max_items: number?
	) -> ProcessResult,
	Invalidate: (self: Processor, record: RecordStore.Record) -> (),
}

type NormalizedConfig = {
	activation_guard: (RecordStore.Record, string) -> (boolean, string?),
	handlers: { [string]: HandlerDefinition },
	on_diagnostic: ((Diagnostic) -> ())?,
}

type DestinationEnvelope = {
	source_event_id: string,
	payload_version: number,
	payload: RecordStore.JsonValue,
	correlation_id: string?,
	causation_id: string?,
	source_created_at: number,
	destination_store_name: string,
	destination_scope: string,
	destination_profile_key: string,
	destination_user_id: number?,
}

local MAX_HANDLER_TYPES = 128
local MAX_BATCH_MESSAGES = 16

local function valid_text(value: unknown, maximum: number): boolean
	return type(value) == "string" and value ~= "" and #value <= maximum
end

local function positive_integer(value: unknown): boolean
	return type(value) == "number" and math.isfinite(value)
		and value > 0 and math.floor(value) == value
end

local function positive_version(value: unknown): boolean
	return type(value) == "number" and math.isfinite(value)
		and value >= 1 and math.floor(value) == value
end

local function emit(config: NormalizedConfig, category: string, event_id: string?, status: string?, message: string?)
	local diagnostic: Diagnostic = {
		category = category,
		event_id = event_id,
		status = status,
		message = message,
	}
	if config.on_diagnostic ~= nil then
		local ok = pcall(config.on_diagnostic, table.freeze(diagnostic))
		if not ok then warn("[RecordStoreOutboxConsumerAdapter] diagnostic callback failed") end
	else
		warn("[RecordStoreOutboxConsumerAdapter] " .. category .. " (" .. tostring(status or "unknown") .. ")")
	end
end

local function normalize_config(value: unknown): NormalizedConfig
	if type(value) ~= "table" then error("config must be a table", 3) end
	local fields = value :: { [string]: unknown }
	for key in pairs(fields) do
		if key ~= "activation_guard" and key ~= "handlers" and key ~= "on_diagnostic" then
			error("unsupported outbox consumer adapter option: " .. tostring(key), 3)
		end
	end
	if type(fields.activation_guard) ~= "function" then
		error("activation_guard is required; destination consumption must be explicitly enabled", 3)
	end
	if type(fields.handlers) ~= "table" then error("handlers must be a table keyed by event type", 3) end
	if fields.on_diagnostic ~= nil and type(fields.on_diagnostic) ~= "function" then
		error("on_diagnostic must be a function when provided", 3)
	end
	local handlers: { [string]: HandlerDefinition } = {}
	local count = 0
	for event_type, raw_handler in pairs(fields.handlers :: { [string]: unknown }) do
		count += 1
		if count > MAX_HANDLER_TYPES then error("handlers exceeds the maximum of 128 event types", 3) end
		if not valid_text(event_type, 100) or type(raw_handler) ~= "table" then
			error("handler entries require valid event type keys and table definitions", 3)
		end
		local definition = raw_handler :: { [string]: unknown }
		if not positive_version(definition.payload_version) or type(definition.reduce) ~= "function" then
			error("each handler needs a positive payload_version and a non-yielding reduce function", 3)
		end
		for field in pairs(definition) do
			if field ~= "payload_version" and field ~= "reduce" then
				error("unsupported handler field: " .. tostring(field), 3)
			end
		end
		handlers[event_type] = table.freeze({
			payload_version = definition.payload_version :: number,
			reduce = definition.reduce :: DestinationReducer,
		})
	end
	if count == 0 then error("at least one destination event handler must be configured", 3) end
	return table.freeze({
		activation_guard = fields.activation_guard :: (RecordStore.Record, string) -> (boolean, string?),
		handlers = table.freeze(handlers),
		on_diagnostic = fields.on_diagnostic :: ((Diagnostic) -> ())?,
	})
end

local function validate_record(record: RecordStore.Record): ({ [string]: unknown }?, string?)
	if type(record) ~= "table" or type(record.GetState) ~= "function"
		or type(record.IsOpen) ~= "function" or type(record.GetIdentity) ~= "function"
		or type(record.GetMailboxOwner) ~= "function" or type(record.CreateMailboxStoreAdapter) ~= "function"
	then
		return nil, "destination must be a Record with identity and Mailbox V2 adapter APIs"
	end
	local ok, state, is_open, identity = pcall(function()
		return record:GetState(), record:IsOpen(), record:GetIdentity()
	end)
	if not ok or state ~= "active" or is_open ~= true or type(identity) ~= "table" then
		return nil, "destination Record is not actively owned"
	end
	if not valid_text(identity.store_name, 50) or type(identity.scope) ~= "string"
		or #identity.scope > 50 or not valid_text(identity.profile_key, 50)
	then
		return nil, "destination Record identity is malformed"
	end
	if type(identity.user_ids) ~= "table" then return nil, "destination UserIds could not be verified" end
	return identity, nil
end

local function validate_envelope(
	payload: unknown,
	message: { [string]: unknown },
	record_identity: { [string]: unknown }
): (DestinationEnvelope?, string?)
	if type(payload) ~= "table" then return nil, "outbox event envelope must be a table" end
	local fields = payload :: { [string]: unknown }
	local event_id = fields.source_event_id
	local event_version = fields.payload_version
	local source_created_at = fields.source_created_at
	local destination_store_name = fields.destination_store_name
	local destination_scope = fields.destination_scope
	local destination_profile_key = fields.destination_profile_key
	local destination_user_id = fields.destination_user_id
	if not valid_text(event_id, 256) or not positive_version(event_version)
		or fields.payload == nil or type(source_created_at) ~= "number"
		or not math.isfinite(source_created_at) or source_created_at < 0
		or not valid_text(destination_store_name, 50)
		or type(destination_scope) ~= "string" or #destination_scope > 50
		or not valid_text(destination_profile_key, 50)
		or (destination_user_id ~= nil and not positive_integer(destination_user_id))
	then
		return nil, "outbox event identity, payload version, timestamp or destination is malformed"
	end
	if fields.correlation_id ~= nil and not valid_text(fields.correlation_id, 256) then
		return nil, "correlation_id must be a non-empty string of at most 256 bytes"
	end
	if fields.causation_id ~= nil and not valid_text(fields.causation_id, 256) then
		return nil, "causation_id must be a non-empty string of at most 256 bytes"
	end
	local event_type = message.Type
	if not valid_text(event_type, 100) then return nil, "Mailbox V2 event type is malformed" end
	if destination_store_name ~= record_identity.store_name
		or destination_scope ~= record_identity.scope
		or destination_profile_key ~= record_identity.profile_key
	then
		return nil, "event destination locator does not match this active profile"
	end
	if destination_user_id ~= nil then
		local found = false
		for _, user_id in ipairs(record_identity.user_ids :: { unknown }) do
			if user_id == destination_user_id then found = true; break end
		end
		if not found then return nil, "event destination UserId does not belong to this profile" end
	end
	return {
		source_event_id = event_id :: string,
		payload_version = event_version :: number,
		payload = fields.payload :: RecordStore.JsonValue,
		correlation_id = if fields.correlation_id ~= nil then fields.correlation_id :: string else nil,
		causation_id = if fields.causation_id ~= nil then fields.causation_id :: string else nil,
		source_created_at = source_created_at :: number,
		destination_store_name = destination_store_name :: string,
		destination_scope = destination_scope :: string,
		destination_profile_key = destination_profile_key :: string,
		destination_user_id = destination_user_id :: number?,
	}, nil
end

function OutboxConsumerAdapter.new(config: Config): Processor
	local normalized = normalize_config(config)
	local RecordStoreV2 = RecordStoreV2Factory.new(RecordStore, MailboxV2)
	local mailboxes = (setmetatable({}, { __mode = "k" }) :: any)

	local function resolve_mailbox(record: RecordStore.Record): (any?, string?, string?)
		local cached = mailboxes[record]
		if cached ~= nil then
			local _, identity_error = validate_record(record)
			if identity_error ~= nil then return nil, "fenced", identity_error end
			return cached, nil, nil
		end
		local identity, identity_error = validate_record(record)
		if identity == nil then return nil, "fenced", identity_error end
		local guard_ok, allowed, guard_message = pcall(normalized.activation_guard, record, "bind")
		if not guard_ok then return nil, "unknown", "activation guard raised: " .. tostring(allowed) end
		if allowed ~= true then return nil, "disabled", guard_message or "destination consumption was denied" end
		local store, store_code, store_message = record:CreateMailboxStoreAdapter()
		if store == nil or store_code ~= "success" then
			return nil, store_code or "unknown", store_message or "could not create destination mailbox storage"
		end
		local function mailbox_guard(operation: string): (boolean, string?)
			local valid, validation_message = validate_record(record)
			if valid == nil then return false, validation_message end
			local call_ok, decision, reason = pcall(normalized.activation_guard, record, operation)
			if not call_ok then return false, "activation guard raised: " .. tostring(decision) end
			return decision == true, reason
		end
		local owner_ok, owner = pcall(function() return record:GetMailboxOwner() end)
		if not owner_ok or type(owner) ~= "table" then return nil, "fenced", "destination mailbox owner could not be read" end
		local create_ok, mailbox = pcall(function()
			return MailboxV2.new(store, owner, {
				active_record = record,
				activation_guard = mailbox_guard,
				sender_job_id = game.JobId,
			})
		end)
		if not create_ok or type(mailbox) ~= "table" then
			return nil, "invalid", "could not create destination consumer mailbox: " .. tostring(mailbox)
		end
		mailboxes[record] = mailbox
		return mailbox, nil, nil
	end

	local function process_event(
		record: RecordStore.Record,
		identity: { [string]: unknown },
		payload: unknown,
		snapshot: { [string]: unknown },
		handler_context: unknown
	): (boolean, string?)
		local event, event_error = validate_envelope(payload, snapshot, identity)
		if event == nil then
			emit(normalized, "destination_event_rejected", nil, "invalid", event_error)
			return false, event_error or "event envelope validation failed"
		end
		local handler = normalized.handlers[snapshot.Type :: string]
		if handler == nil then
			emit(normalized, "destination_handler_missing", event.source_event_id, "unsupported",
				"no destination handler is registered for this event type")
			return false, "no destination handler is registered for this event type"
		end
		if event.payload_version ~= handler.payload_version then
			emit(normalized, "destination_payload_version_unsupported", event.source_event_id, "unsupported",
				"destination handler payload version does not match the event version")
			return false, "destination handler payload version does not match the event version"
		end
		if type(snapshot.Id) ~= "string" or snapshot.Id == ""
			or type(snapshot.Attempts) ~= "number" or not math.isfinite(snapshot.Attempts)
			or snapshot.Attempts < 0 or math.floor(snapshot.Attempts) ~= snapshot.Attempts
		then
			return false, "Mailbox V2 message snapshot is malformed"
		end
		if type(handler_context) == "table" then
			local context_methods = handler_context :: { [string]: unknown }
			if type(context_methods.is_cancelled) == "function" then
				local ok, cancelled = pcall(context_methods.is_cancelled)
				if not ok or cancelled == true then
					return false, "destination message claim was cancelled before application"
				end
			end
		end
		local event_context: EventContext = table.freeze({
			EventId = event.source_event_id,
			EventType = snapshot.Type :: string,
			PayloadVersion = event.payload_version,
			CorrelationId = event.correlation_id,
			CausationId = event.causation_id,
			SourceCreatedAt = event.source_created_at,
			DestinationStoreName = event.destination_store_name,
			DestinationScope = event.destination_scope,
			DestinationProfileKey = event.destination_profile_key,
			DestinationUserId = event.destination_user_id,
			MailboxMessageId = snapshot.Id,
			Attempt = snapshot.Attempts,
		})
		local function reducer(current_data: RecordStore.JsonValue?, stored_envelope: RecordStore.JsonValue, _inbox_message: any)
			if type(current_data) ~= "table" or type(stored_envelope) ~= "table" then
				return nil, "destination Inbox requires table profile data and a table event envelope"
			end
			local stored_fields = stored_envelope :: { [string]: unknown }
			if stored_fields.source_event_id ~= event.source_event_id
				or stored_fields.payload_version ~= event.payload_version
				or stored_fields.destination_store_name ~= event.destination_store_name
				or stored_fields.destination_scope ~= event.destination_scope
				or stored_fields.destination_profile_key ~= event.destination_profile_key
			then
				return nil, "stored inbox envelope identity changed before application"
			end
			return handler.reduce(
				current_data :: RecordStore.JsonValue,
				stored_fields.payload :: RecordStore.JsonValue,
				event_context
			)
		end
		local inbox_result = RecordStoreV2.Inbox.ApplyAsync(record, {
			message_id = event.source_event_id,
			message_type = snapshot.Type,
			payload_version = event.payload_version,
			payload = payload :: RecordStore.JsonValue,
		}, reducer)
		if type(inbox_result) ~= "table" or type(inbox_result.code) ~= "string" then
			emit(normalized, "destination_inbox_unknown", event.source_event_id, "unknown",
				"Inbox returned no structured transaction result")
			return false, "destination Inbox outcome is unresolved"
		end
		if inbox_result.code ~= "committed" and inbox_result.code ~= "duplicate" then
			emit(normalized, "destination_inbox_not_confirmed", event.source_event_id,
				tostring(inbox_result.code), tostring(inbox_result.message or "Inbox transaction was not confirmed"))
			return false, tostring(inbox_result.message or ("Inbox returned " .. inbox_result.code))
		end
		if type(handler_context) == "table" then
			local context_methods = handler_context :: { [string]: unknown }
			if type(context_methods.is_cancelled) == "function" then
				local ok, cancelled = pcall(context_methods.is_cancelled)
				if not ok or cancelled == true then
					emit(normalized, "destination_claim_cancelled_after_commit", event.source_event_id, "unknown",
						"destination mutation committed but the mailbox claim was cancelled; retry will deduplicate via Inbox")
					return false, "Inbox committed but mailbox claim ownership is uncertain"
				end
			end
		end
		return true, nil
	end

	local processor: Processor = {
		GetMailbox = function(_self, record)
			return resolve_mailbox(record)
		end,
		ProcessNextAsync = function(_self, record)
			local identity, identity_error = validate_record(record)
			if identity == nil then return { code = "fenced", message = identity_error } end
			local mailbox, mailbox_code, mailbox_message = resolve_mailbox(record)
			if mailbox == nil then return { code = mailbox_code or "unknown", message = mailbox_message } end
			local ok, result = pcall(function()
				return mailbox:ProcessNextAsync(function(payload, snapshot, handler_context)
					if type(snapshot) ~= "table" then return false, "Mailbox V2 returned a malformed snapshot" end
					return process_event(record, identity, payload, snapshot, handler_context)
				end)
			end)
			if not ok or type(result) ~= "table" or type(result.code) ~= "string" then
				local detail = if ok then "Mailbox V2 consumer returned no structured result" else tostring(result)
				emit(normalized, "destination_consumer_unknown", nil, "unknown", detail)
				return { code = "unknown", message = detail }
			end
			local row = result :: { [string]: unknown }
			return {
				code = row.code :: string,
				processed = if row.code == "processed" then 1 else 0,
				message_id = if type(row.message_id) == "string" then row.message_id else nil,
				message = if type(row.error) == "string" then row.error
					elseif type(row.message) == "string" then row.message else nil,
				native_code = row.code :: string,
			}
		end,
		ProcessBatchAsync = function(self, record, max_messages)
			local maximum = if max_messages == nil then 8 else max_messages
			if type(maximum) ~= "number" or not math.isfinite(maximum)
				or math.floor(maximum) ~= maximum or maximum < 1 or maximum > MAX_BATCH_MESSAGES
			then
				return { code = "invalid", processed = 0, message = "max_messages must be an integer from 1 to 16" }
			end
			local processed = 0
			for _ = 1, maximum do
				local result = self:ProcessNextAsync(record)
				if result.code == "empty" then
					return { code = "completed", processed = processed }
				end
				if result.code == "processed" or result.code == "duplicate" then
					processed += 1
				elseif result.code == "expired" or result.code == "discarded" then
					continue
				else
					return {
						code = result.code,
						processed = processed,
						message_id = result.message_id,
						message = result.message,
						native_code = result.native_code,
					}
				end
			end
			return {
				code = "incomplete",
				processed = processed,
				message = "message cap reached; resume on the next worker iteration",
			}
		end,
		PruneInboxReceiptsAsync = function(_self, record, older_than_unix, operation_id, max_items)
			local identity, identity_error = validate_record(record)
			if identity == nil then return { code = "fenced", message = identity_error } end
			if type(older_than_unix) ~= "number" or not math.isfinite(older_than_unix) or older_than_unix < 0 then
				return { code = "invalid", message = "older_than_unix must be a finite non-negative Unix timestamp" }
			end
			if not valid_text(operation_id, 256) then
				return { code = "invalid", message = "operation_id must be a stable non-empty string of at most 256 bytes" }
			end
			local maximum = if max_items == nil then 16 else max_items
			if type(maximum) ~= "number" or not math.isfinite(maximum)
				or math.floor(maximum) ~= maximum or maximum < 1 or maximum > MAX_BATCH_MESSAGES
			then
				return { code = "invalid", message = "max_items must be an integer from 1 to 16" }
			end
			local ok, result = pcall(function()
				return RecordStoreV2.Inbox.PruneReceipts(record, older_than_unix, maximum, operation_id)
			end)
			if not ok or type(result) ~= "table" or type(result.code) ~= "string" then
				local detail = if ok then "Inbox receipt pruning returned no structured result" else tostring(result)
				emit(normalized, "destination_inbox_prune_unknown", nil, "unknown", detail)
				return { code = "unknown", message = detail }
			end
			local row = result :: { [string]: unknown }
			return {
				code = row.code :: string,
				processed = if type(row.pruned) == "number" then row.pruned else nil,
				message = if type(row.message) == "string" then row.message else nil,
				native_code = row.code :: string,
			}
		end,
		Invalidate = function(_self, record)
			mailboxes[record] = nil
		end,
	}
	return table.freeze(processor)
end

return table.freeze({
	new = OutboxConsumerAdapter.new,
})
