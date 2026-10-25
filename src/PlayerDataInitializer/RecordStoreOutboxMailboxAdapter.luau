--!strict
local RecordStore = require(script.Parent:WaitForChild("RecordStore"))
local HttpService = game:GetService("HttpService")
local MailboxV2 = (RecordStore :: any).MailboxV2

local OutboxMailboxAdapter = {}

export type ActivationGuard = (
	record: RecordStore.Record,
	operation: string
) -> (boolean, string?)

export type Diagnostic = {
	category: string,
	event_id: string?,
	status: string?,
	message: string?,
}

export type Config = {
	get_record: (event: RecordStore.OutboxEvent) -> RecordStore.Record?,
	activation_guard: ActivationGuard,
	on_diagnostic: ((diagnostic: Diagnostic) -> ())?,
	encode: ((unknown) -> string)?,
}

type Mailbox = any

export type Processor = {
	Dispatch: RecordStore.OutboxDispatcher,
	GetMailbox: (self: Processor, record: RecordStore.Record) -> Mailbox?,
}

type NormalizedConfig = {
	get_record: (event: RecordStore.OutboxEvent) -> RecordStore.Record?,
	activation_guard: ActivationGuard,
	on_diagnostic: ((diagnostic: Diagnostic) -> ())?,
	encode: (unknown) -> string,
}

local function normalize_config(config: unknown): NormalizedConfig
	if type(config) ~= "table" then error("config must be a table", 3) end
	local fields = config :: { [string]: unknown }
	for name in pairs(fields) do
		if name ~= "get_record" and name ~= "activation_guard"
			and name ~= "on_diagnostic" and name ~= "encode"
		then
			error("unsupported outbox mailbox adapter option: " .. tostring(name), 3)
		end
	end
	if type(fields.get_record) ~= "function" then error("get_record must resolve an active destination profile", 3) end
	if type(fields.activation_guard) ~= "function" then error("activation_guard is required; Mailbox V2 remains opt-in", 3) end
	if fields.on_diagnostic ~= nil and type(fields.on_diagnostic) ~= "function" then error("on_diagnostic must be a function", 3) end
	if fields.encode ~= nil and type(fields.encode) ~= "function" then error("encode must be a function", 3) end
	local encode = fields.encode or function(value) return HttpService:JSONEncode(value) end
	return table.freeze({
		get_record = fields.get_record :: (event: RecordStore.OutboxEvent) -> RecordStore.Record?,
		activation_guard = fields.activation_guard :: ActivationGuard,
		on_diagnostic = fields.on_diagnostic :: ((diagnostic: Diagnostic) -> ())?,
		encode = encode :: (unknown) -> string,
	})
end

local function emit(config: NormalizedConfig, category: string, event_id: string?, status: string?, message: string?)
	local diagnostic: Diagnostic = { category = category, event_id = event_id, status = status, message = message }
	if config.on_diagnostic ~= nil then
		local ok = pcall(config.on_diagnostic, table.freeze(diagnostic))
		if not ok then warn("[RecordStoreOutboxMailboxAdapter] diagnostic callback failed") end
	else
		warn("[RecordStoreOutboxMailboxAdapter] " .. category .. " (" .. tostring(status or "unknown") .. ")")
	end
end

local function positive_integer(value: unknown): boolean
	return type(value) == "number" and math.isfinite(value) and value > 0 and math.floor(value) == value
end

local function validate_destination(record: RecordStore.Record, event: RecordStore.OutboxEvent): (boolean, string?)
	local call_ok, state, is_open, identity = pcall(function()
		return record:GetState(), record:IsOpen(), record:GetIdentity()
	end)
	if not call_ok or state ~= "active" or is_open ~= true or type(identity) ~= "table" then
		return false, "destination profile is not actively owned"
	end
	if identity.store_name ~= event.DestinationStoreName
		or identity.scope ~= event.DestinationScope
		or identity.profile_key ~= event.DestinationProfileKey
	then
		return false, "resolved profile does not match the durable event destination"
	end
	if event.DestinationUserId ~= nil then
		if not positive_integer(event.DestinationUserId) or type(identity.user_ids) ~= "table" then
			return false, "destination UserId metadata is invalid"
		end
		local found = false
		for _, user_id in ipairs(identity.user_ids :: { unknown }) do
			if user_id == event.DestinationUserId then found = true; break end
		end
		if not found then return false, "destination profile does not own the event UserId" end
	end
	return true, nil
end

local function validate_event(event: RecordStore.OutboxEvent): (boolean, string?)
	if type(event) ~= "table" or type(event.EventId) ~= "string" or event.EventId == "" or #event.EventId > 256
		or type(event.EventType) ~= "string" or event.EventType == "" or #event.EventType > 100
		or type(event.PayloadVersion) ~= "number" or not math.isfinite(event.PayloadVersion)
		or math.floor(event.PayloadVersion) ~= event.PayloadVersion or event.PayloadVersion < 1
		or event.Payload == nil
		or type(event.DestinationStoreName) ~= "string" or event.DestinationStoreName == "" or #event.DestinationStoreName > 50
		or type(event.DestinationScope) ~= "string" or #event.DestinationScope > 50
		or type(event.DestinationProfileKey) ~= "string" or event.DestinationProfileKey == "" or #event.DestinationProfileKey > 50
		or (event.DestinationUserId ~= nil and not positive_integer(event.DestinationUserId))
		or (event.CorrelationId ~= nil and (type(event.CorrelationId) ~= "string" or #event.CorrelationId > 256))
		or (event.CausationId ~= nil and (type(event.CausationId) ~= "string" or #event.CausationId > 256))
		or type(event.CreatedAt) ~= "number" or not math.isfinite(event.CreatedAt) or event.CreatedAt < 0
		or type(event.Attempts) ~= "number" or not math.isfinite(event.Attempts)
		or math.floor(event.Attempts) ~= event.Attempts or event.Attempts < 0
		or (event.State ~= "pending" and event.State ~= "unknown")
	then
		return false, "outbox event identity, destination, payload, metadata, or dispatch state is invalid"
	end
	return true, nil
end

function OutboxMailboxAdapter.new(config: Config): Processor
	local normalized = normalize_config(config)
	local mailboxes = (setmetatable({}, { __mode = "k" }) :: any)

	local function resolve_mailbox(record: RecordStore.Record, event: RecordStore.OutboxEvent): (Mailbox?, string?, string?)
		local valid, validation_error = validate_destination(record, event)
		if not valid then return nil, "fenced", validation_error end

		local guard_ok, allowed, guard_message = pcall(normalized.activation_guard, record, "bind")
		if not guard_ok then return nil, "unknown", "Mailbox V2 activation guard raised: " .. tostring(allowed) end
		if allowed ~= true then return nil, "disabled", tostring(guard_message or "Mailbox V2 activation was denied") end

		local cached = mailboxes[record]
		if cached ~= nil then return cached, nil, nil end

		local store, store_code, store_message = record:CreateMailboxStoreAdapter()
		if store == nil or store_code ~= "success" then
			return nil, store_code, store_message or "could not create the destination mailbox store adapter"
		end

		local function mailbox_guard(operation: string): (boolean, string?)
			local call_ok, result, message = pcall(normalized.activation_guard, record, operation)
			if not call_ok then return false, "Mailbox V2 activation guard raised: " .. tostring(result) end
			return result == true, message
		end
		local mailbox_options: any = {
			active_record = record,
			activation_guard = mailbox_guard,
			encode = normalized.encode,
			sender_job_id = game.JobId,
		}
		local create_ok, mailbox = pcall(function()
			return MailboxV2.new(store, record:GetMailboxOwner(), mailbox_options)
		end)
		if not create_ok or type(mailbox) ~= "table" then
			return nil, "invalid", "could not create destination mailbox: " .. tostring(mailbox)
		end

		local bind_code, bind_message = record:BindMailboxV2Async(mailbox)
		if bind_code ~= "success" then
			return nil, bind_code, bind_message or "Record rejected the destination Mailbox V2 binding"
		end
		mailboxes[record] = mailbox
		return mailbox, nil, nil
	end

	local function dispatch(event: RecordStore.OutboxEvent): (boolean, string?)
		local valid, validation_error = validate_event(event)
		if not valid then
			emit(normalized, "invalid_event", nil, "invalid", validation_error)
			return false, validation_error
		end

		local lookup_ok, record = pcall(normalized.get_record, event)
		if not lookup_ok or record == nil then
			emit(normalized, "destination_unavailable", event.EventId, "not_found", "destination profile is unavailable")
			return false, "destination profile is unavailable"
		end

		local mailbox, mailbox_code, mailbox_error = resolve_mailbox(record, event)
		if mailbox == nil then
			emit(normalized, "destination_mailbox_unavailable", event.EventId, mailbox_code, mailbox_error)
			if mailbox_code == "unknown" then
				error("destination mailbox creation/binding outcome is unresolved: " .. tostring(mailbox_error), 0)
			end
			return false, mailbox_error or ("destination mailbox unavailable: " .. tostring(mailbox_code))
		end

		local payload: RecordStore.JsonValue = {
			source_event_id = event.EventId,
			payload_version = event.PayloadVersion,
			payload = event.Payload,
			correlation_id = event.CorrelationId,
			causation_id = event.CausationId,
			source_created_at = event.CreatedAt,
		}
		local call_ok, result = pcall(function()
			return mailbox:EnqueueAsync(event.EventType, payload, { idempotency_key = event.EventId })
		end)
		if not call_ok or type(result) ~= "table" or type(result.code) ~= "string" then
			local detail = if call_ok then "destination mailbox returned no structured result" else tostring(result)
			emit(normalized, "destination_enqueue_unknown", event.EventId, "unknown", detail)
			error("destination mailbox enqueue outcome is unresolved; retry the same event ID: " .. detail, 0)
		end

		local result_row = result :: { [string]: unknown }
		if result_row.code == "accepted" or result_row.code == "duplicate" then
			local message_id = result_row.message_id
			if type(message_id) ~= "string" or message_id == "" then
				emit(normalized, "destination_receipt_missing", event.EventId, "unknown", "accepted enqueue omitted its durable message ID")
				error("destination mailbox accepted an event without a durable message ID", 0)
			end
			return true, "mailbox:" .. message_id
		end
		if result_row.code == "unknown" then
			emit(normalized, "destination_enqueue_unknown", event.EventId, "unknown", tostring(result_row.error))
			error("destination mailbox enqueue outcome is unresolved; retry the same event ID", 0)
		end
		emit(normalized, "destination_enqueue_rejected", event.EventId, tostring(result_row.code), tostring(result_row.error))
		return false, tostring(result_row.error or ("destination mailbox rejected event: " .. tostring(result_row.code)))
	end

	local processor: Processor = {
		Dispatch = dispatch,
		GetMailbox = function(_self, record)
			return mailboxes[record]
		end,
	}
	return table.freeze(processor)
end

return OutboxMailboxAdapter
