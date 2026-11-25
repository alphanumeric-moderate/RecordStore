--!strict
local SHA256 = require(script.Parent.RecordStoreSHA256)

local TransientMessaging = {}
local Client = {}
Client.__index = Client

local MAX_NAMESPACE_BYTES = 64
local MAX_TOPIC_NAME_BYTES = 128
local MAX_SERVER_ID_BYTES = 128
local MAX_MESSAGE_BYTES = 1024
local MAX_PAYLOAD_DEPTH = 16
local MAX_PAYLOAD_NODES = 256

type ClientType = {
	_service: any,
	_http: any,
	_namespace: string,
	_server_id: string,
	_max_message_bytes: number,
	_on_error: ((string, any) -> ())?,
	_subscriptions: { [number]: any },
	_next_subscription: number,
	_closed: boolean,
	PublishAsync: (self: ClientType, topic: string, payload: any) -> any,
	SubscribeAsync: (self: ClientType, topic: string, handler: (any, any) -> ()) -> any,
	SendToServerAsync: (self: ClientType, server_id: string, payload: any) -> any,
	SubscribeServerAsync: (self: ClientType, handler: (any, any) -> ()) -> any,
	PublishStreamWakeup: (self: ClientType, stream: string, partition: number, sequence: number?) -> any,
	SubscribeStreamWakeups: (self: ClientType, stream: string, partition: number, handler: (any, any) -> ()) -> any,
	Close: (self: ClientType) -> (),
}

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function integer_at_least(value: any, minimum: number): boolean
	return finite(value) and math.floor(value) == value and value >= minimum
end

local function valid_text(value: any, maximum: number): boolean
	return type(value) == "string" and #value > 0 and #value <= maximum
end

local function clone_payload(value: any, seen: { [any]: boolean }, depth: number, nodes: { number }): (any, string)
	if depth > MAX_PAYLOAD_DEPTH then
		error("payload exceeds maximum nesting depth", 0)
	end
	local kind = type(value)
	if kind == "nil" then
		error("payload cannot be nil", 0)
	elseif kind == "boolean" or kind == "string" then
		return value, kind .. ":" .. tostring(value)
	elseif kind == "number" then
		if not finite(value) then
			error("payload numbers must be finite", 0)
		end
		return value, "number:" .. string.format("%.17g", value)
	elseif kind ~= "table" then
		error("unsupported payload type " .. kind, 0)
	end
	if getmetatable(value) ~= nil then
		error("payload tables must not have metatables", 0)
	end
	if seen[value] then
		error("cyclic payload tables are unsupported", 0)
	end
	nodes[1] += 1
	if nodes[1] > MAX_PAYLOAD_NODES then
		error("payload exceeds maximum node count", 0)
	end
	seen[value] = true
	local count = 0
	local numeric_keys = true
	local string_keys = true
	local maximum_index = 0
	for key in pairs(value) do
		count += 1
		if type(key) == "number" and integer_at_least(key, 1) then
			maximum_index = math.max(maximum_index, key)
		else
			numeric_keys = false
		end
		if type(key) ~= "string" then
			string_keys = false
		end
	end
	local copy: any = {}
	local parts = table.create(count * 2)
	if count > 0 and numeric_keys and maximum_index == count then
		for index = 1, count do
			local child, encoded = clone_payload(value[index], seen, depth + 1, nodes)
			copy[index] = child
			parts[index] = encoded
		end
	elseif count == 0 or string_keys then
		local keys = {}
		for key in pairs(value) do
			table.insert(keys, key)
		end
		table.sort(keys)
		for index, key in ipairs(keys) do
			local child, encoded = clone_payload(value[key], seen, depth + 1, nodes)
			copy[key] = child
			parts[index * 2 - 1] = "key:" .. key
			parts[index * 2] = encoded
		end
	else
		seen[value] = nil
		error("payload tables must be dense arrays or string-keyed objects", 0)
	end
	seen[value] = nil
	return table.freeze(copy), if count > 0 and numeric_keys and maximum_index == count
		then "array:" .. table.concat(parts, "|")
		else "object:" .. table.concat(parts, "|")
end

local function normalize_payload(value: any): (any?, string?)
	local ok, copied, _canonical = pcall(function()
		return clone_payload(value, {}, 0, { 0 })
	end)
	if not ok then
		return nil, tostring(copied)
	end
	return copied, nil
end

local function physical_topic(namespace: string, kind: string, name: string): string
	return "rs2x" .. SHA256.digest(namespace .. "\0" .. kind .. "\0" .. name)
end

local function safe_message_id(self: ClientType): (string?, string?)
	local ok, value = pcall(function()
		return self._http:GenerateGUID(false)
	end)
	if not ok then
		return nil, "message_id_generation_failed: " .. tostring(value)
	end
	if not valid_text(value, 128) then
		return nil, "message_id_generation_failed: invalid GUID"
	end
	return value, nil
end

local function encode_envelope(self: ClientType, kind: string, payload: any, target: string?): (any?, string?, string?)
	local copied, payload_error = normalize_payload(payload)
	if payload_error ~= nil then
		return nil, nil, "invalid_payload: " .. payload_error
	end
	local message_id, id_error = safe_message_id(self)
	if message_id == nil then
		return nil, nil, id_error
	end
	local envelope: any = {
		version = 1,
		namespace = self._namespace,
		kind = kind,
		message_id = message_id,
		sender = self._server_id,
		payload = copied,
	}
	if target ~= nil then
		envelope.target = target
	end
	local ok, encoded = pcall(function()
		return self._http:JSONEncode(envelope)
	end)
	if not ok then
		return nil, nil, "invalid_payload: JSON encoding failed: " .. tostring(encoded)
	end
	if type(encoded) ~= "string" or #encoded > self._max_message_bytes then
		return nil, nil, "message_too_large: encoded message exceeds configured byte limit"
	end
	return envelope, message_id, nil
end

local function message_context(envelope: any, sent_at: any): any
	return table.freeze({
		version = envelope.version,
		kind = envelope.kind,
		message_id = envelope.message_id,
		sender = envelope.sender,
		target = envelope.target,
		sent_at = sent_at,
	})
end

function TransientMessaging.new(messaging_service: any, http_service: any, raw_options: any?): (ClientType?, string?)
	if messaging_service == nil
		or type(messaging_service.PublishAsync) ~= "function"
		or type(messaging_service.SubscribeAsync) ~= "function"
	then
		return nil, "MessagingService with PublishAsync and SubscribeAsync is required"
	end
	if http_service == nil
		or type(http_service.GenerateGUID) ~= "function"
		or type(http_service.JSONEncode) ~= "function"
	then
		return nil, "HttpService with GenerateGUID and JSONEncode is required"
	end
	if raw_options ~= nil and type(raw_options) ~= "table" then
		return nil, "options must be a table"
	end
	local options = raw_options or {}
	local namespace = options.namespace
	local server_id = options.server_id
	local max_message_bytes = options.max_message_bytes or MAX_MESSAGE_BYTES
	local on_error = options.on_error
	if not valid_text(namespace, MAX_NAMESPACE_BYTES) then
		return nil, "namespace must be 1..64 bytes"
	end
	if not valid_text(server_id, MAX_SERVER_ID_BYTES) then
		return nil, "server_id must be 1..128 bytes"
	end
	if not integer_at_least(max_message_bytes, 128) or max_message_bytes > MAX_MESSAGE_BYTES then
		return nil, "max_message_bytes must be 128..1024"
	end
	if on_error ~= nil and type(on_error) ~= "function" then
		return nil, "on_error must be a function"
	end
	return setmetatable({
		_service = messaging_service,
		_http = http_service,
		_namespace = namespace,
		_server_id = server_id,
		_max_message_bytes = max_message_bytes,
		_on_error = on_error,
		_subscriptions = {},
		_next_subscription = 0,
		_closed = false,
	}, Client) :: any, nil
end

local function publish(self: ClientType, kind: string, logical_name: string, payload: any, target: string?): any
	if self._closed then
		return { code = "closed" }
	end
	local envelope, message_id, envelope_error = encode_envelope(self, kind, payload, target)
	if envelope == nil then
		local code = if string.sub(envelope_error or "", 1, 16) == "message_too_large" then "capacity" else "invalid"
		return { code = code, message = envelope_error }
	end
	local topic = physical_topic(self._namespace, kind, logical_name)
	local ok, publish_error = pcall(function()
		self._service:PublishAsync(topic, envelope)
	end)
	if not ok then
		return {
			code = "unknown",
			message = tostring(publish_error),
			message_id = message_id,
			topic_hash = topic,
		}
	end
	return { code = "published", message_id = message_id, topic_hash = topic }
end

function Client.PublishAsync(self: ClientType, topic: string, payload: any): any
	if not valid_text(topic, MAX_TOPIC_NAME_BYTES) then
		return { code = "invalid", message = "topic must be 1..128 bytes" }
	end
	return publish(self, "topic", topic, payload, nil)
end

local function subscribe(
	self: ClientType,
	kind: string,
	logical_name: string,
	handler: (any, any) -> (),
	target_server: string?,
	wakeup_stream: string?,
	wakeup_partition: number?
): any
	if self._closed then
		return { code = "closed" }
	end
	local topic = physical_topic(self._namespace, kind, logical_name)
	local callback = function(message: any)
		if type(message) ~= "table" or type(message.Data) ~= "table" then
			return
		end
		local envelope = message.Data
		if envelope.version ~= 1
			or envelope.namespace ~= self._namespace
			or envelope.kind ~= kind
			or not valid_text(envelope.message_id, 128)
			or not valid_text(envelope.sender, MAX_SERVER_ID_BYTES)
			or envelope.payload == nil
		then
			return
		end
		if target_server ~= nil and envelope.target ~= target_server then
			return
		end
		if wakeup_stream ~= nil then
			local data = envelope.payload
			if type(data) ~= "table"
				or data.stream ~= wakeup_stream
				or data.partition ~= wakeup_partition
			then
				return
			end
		end
		local payload, payload_error = normalize_payload(envelope.payload)
		if payload_error ~= nil or payload == nil then
			return
		end
		local context = message_context(envelope, message.Sent)
		local handler_ok, handler_error = pcall(handler, payload, context)
		if not handler_ok and self._on_error ~= nil then
			pcall(self._on_error, tostring(handler_error), context)
		end
	end
	local ok, connection = pcall(function()
		return self._service:SubscribeAsync(topic, callback)
	end)
	if not ok or connection == nil or type(connection.Disconnect) ~= "function" then
		return { code = "unknown", message = tostring(connection or "SubscribeAsync returned no connection") }
	end
	self._next_subscription += 1
	local subscription_id = self._next_subscription
	local handle: any = {
		connected = true,
		_connection = connection,
		_owner = self,
		_id = subscription_id,
	}
	function handle:Disconnect()
		if not self.connected then
			return
		end
		self.connected = false
		local live = self._connection
		if live ~= nil then
			pcall(function()
				live:Disconnect()
			end)
		end
		local owner = self._owner
		if owner ~= nil then
			owner._subscriptions[self._id] = nil
		end
	end
	self._subscriptions[subscription_id] = handle
	return { code = "subscribed", subscription = handle, topic_hash = topic }
end

function Client.SubscribeAsync(self: ClientType, topic: string, handler: (any, any) -> ()): any
	if not valid_text(topic, MAX_TOPIC_NAME_BYTES) then
		return { code = "invalid", message = "topic must be 1..128 bytes" }
	end
	if type(handler) ~= "function" then
		return { code = "invalid", message = "handler must be a function" }
	end
	return subscribe(self, "topic", topic, handler, nil, nil, nil)
end

function Client.SendToServerAsync(self: ClientType, server_id: string, payload: any): any
	if not valid_text(server_id, MAX_SERVER_ID_BYTES) then
		return { code = "invalid", message = "server_id must be 1..128 bytes" }
	end
	return publish(self, "direct", server_id, payload, server_id)
end

function Client.SubscribeServerAsync(self: ClientType, handler: (any, any) -> ()): any
	if type(handler) ~= "function" then
		return { code = "invalid", message = "handler must be a function" }
	end
	return subscribe(self, "direct", self._server_id, handler, self._server_id, nil, nil)
end

function Client.PublishStreamWakeup(self: ClientType, stream: string, partition: number, sequence: number?): any
	if not valid_text(stream, MAX_TOPIC_NAME_BYTES) then
		return { code = "invalid", message = "stream must be 1..128 bytes" }
	end
	if not integer_at_least(partition, 1) then
		return { code = "invalid", message = "partition must be a positive integer" }
	end
	if sequence ~= nil and not integer_at_least(sequence, 1) then
		return { code = "invalid", message = "sequence must be a positive integer when supplied" }
	end
	return publish(self, "wakeup", stream .. "\0" .. tostring(partition), {
		stream = stream,
		partition = partition,
		sequence = sequence,
	}, nil)
end

function Client.SubscribeStreamWakeups(
	self: ClientType,
	stream: string,
	partition: number,
	handler: (any, any) -> ()
): any
	if not valid_text(stream, MAX_TOPIC_NAME_BYTES) then
		return { code = "invalid", message = "stream must be 1..128 bytes" }
	end
	if not integer_at_least(partition, 1) then
		return { code = "invalid", message = "partition must be a positive integer" }
	end
	if type(handler) ~= "function" then
		return { code = "invalid", message = "handler must be a function" }
	end
	return subscribe(
		self,
		"wakeup",
		stream .. "\0" .. tostring(partition),
		handler,
		nil,
		stream,
		partition
	)
end

function Client.Close(self: ClientType)
	if self._closed then
		return
	end
	self._closed = true
	local handles = {}
	for _, handle in pairs(self._subscriptions) do
		handles[#handles + 1] = handle
	end
	for _, handle in ipairs(handles) do
		handle:Disconnect()
	end
end

return table.freeze(TransientMessaging)
