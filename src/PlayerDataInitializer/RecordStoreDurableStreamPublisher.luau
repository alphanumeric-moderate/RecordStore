--!strict
local Publisher = {}
local Client = {}
Client.__index = Client

local MAX_EVENT_ID_BYTES = 128
local MAX_PRODUCER_ID_BYTES = 64
local MAX_BATCH_MESSAGES = 32
local MAX_PENDING_MESSAGES = 4096
local MAX_PAYLOAD_DEPTH = 32
local MAX_PAYLOAD_NODES = 4096
local MAX_SAFE_INTEGER = 9007199254740991

type ClientType = {
	_stream: any,
	_route_key: string,
	_producer_id: string,
	_next_sequence: number,
	_queue: { any },
	_head: number,
	_tail: number,
	_count: number,
	_capacity: number,
	_max_batch_messages: number,
	_flush_delay_seconds: number,
	_busy: boolean,
	_closing: boolean,
	_closed: boolean,
	_scheduled: boolean,
	_schedule_generation: number,
	_schedule: (number, () -> ()) -> (),
	_defer: (() -> ()) -> (),
	_on_result: ((any, number) -> ())?,
	_on_error: ((string) -> ())?,
	_pending_event_ids: { [string]: boolean },
	Enqueue: (self: ClientType, event_id: string, payload: any) -> any,
	FlushAsync: (self: ClientType) -> any,
	CloseAsync: (self: ClientType) -> any,
	GetPendingCount: (self: ClientType) -> number,
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

local function clone_payload(value: any, seen: { [any]: boolean }, depth: number, nodes: { number }): any
	if depth > MAX_PAYLOAD_DEPTH then
		error("payload exceeds maximum nesting depth", 0)
	end
	local kind = type(value)
	if kind == "boolean" or kind == "string" then
		return value
	elseif kind == "number" then
		if not finite(value) then
			error("payload numbers must be finite", 0)
		end
		return value
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
	local copied: any = {}
	if count > 0 and numeric_keys and maximum_index == count then
		for index = 1, count do
			copied[index] = clone_payload(value[index], seen, depth + 1, nodes)
		end
	elseif count == 0 or string_keys then
		for key, child in pairs(value) do
			copied[key] = clone_payload(child, seen, depth + 1, nodes)
		end
	else
		seen[value] = nil
		error("payload tables must be dense arrays or string-keyed objects", 0)
	end
	seen[value] = nil
	return table.freeze(copied)
end

local function snapshot_payload(value: any): (any?, string?)
	local ok, copied = pcall(function()
		return clone_payload(value, {}, 0, { 0 })
	end)
	if not ok then
		return nil, tostring(copied)
	end
	return copied, nil
end

local function notify_result(self: ClientType, result: any, count: number)
	if self._on_result ~= nil then
		local ok, callback_error = pcall(self._on_result, result, count)
		if not ok and self._on_error ~= nil then
			pcall(self._on_error, tostring(callback_error))
		end
	end
end

local function cancel_schedule(self: ClientType)
	self._schedule_generation += 1
	self._scheduled = false
end

local function schedule_flush(self: ClientType, delay_seconds: number)
	if self._closed or self._count == 0 or self._scheduled then
		return
	end
	self._schedule_generation += 1
	local generation = self._schedule_generation
	self._scheduled = true
	local ok, schedule_error = pcall(self._schedule, delay_seconds, function()
		if self._closed or not self._scheduled or generation ~= self._schedule_generation then
			return
		end
		self._scheduled = false
		self._defer(function()
			if not self._closed and self._count > 0 then
				self:FlushAsync()
			end
		end)
	end)
	if not ok then
		self._scheduled = false
		if self._on_error ~= nil then
			pcall(self._on_error, "flush scheduling failed: " .. tostring(schedule_error))
		end
	end
end

function Publisher.OpenAsync(
	stream: any,
	route_key: string,
	producer_id: string,
	raw_options: any?
): (ClientType?, string?)
	if stream == nil
		or type(stream.PublishBatchAsync) ~= "function"
		or type(stream.GetProducerSequenceAsync) ~= "function"
	then
		return nil, "durable stream must expose PublishBatchAsync and GetProducerSequenceAsync"
	end
	if not valid_text(route_key, 128) then
		return nil, "route_key must be 1..128 bytes"
	end
	if not valid_text(producer_id, MAX_PRODUCER_ID_BYTES) then
		return nil, "producer_id must be 1..64 bytes"
	end
	if raw_options ~= nil and type(raw_options) ~= "table" then
		return nil, "options must be a table"
	end
	local options = raw_options or {}
	local max_batch_messages = options.max_batch_messages or MAX_BATCH_MESSAGES
	local capacity = options.max_pending_messages or 256
	local flush_delay_seconds = options.flush_delay_seconds or 0.025
	local schedule = options.schedule
	local defer = options.defer
	local on_result = options.on_result
	local on_error = options.on_error
	if not integer_at_least(max_batch_messages, 1) or max_batch_messages > MAX_BATCH_MESSAGES then
		return nil, "max_batch_messages must be 1..32"
	end
	if not integer_at_least(capacity, max_batch_messages) or capacity > MAX_PENDING_MESSAGES then
		return nil, "max_pending_messages must be max_batch_messages..4096"
	end
	if not finite(flush_delay_seconds) or flush_delay_seconds < 0 or flush_delay_seconds > 5 then
		return nil, "flush_delay_seconds must be 0..5"
	end
	if schedule ~= nil and type(schedule) ~= "function" then
		return nil, "schedule must be a function"
	end
	if defer ~= nil and type(defer) ~= "function" then
		return nil, "defer must be a function"
	end
	if on_result ~= nil and type(on_result) ~= "function" then
		return nil, "on_result must be a function"
	end
	if on_error ~= nil and type(on_error) ~= "function" then
		return nil, "on_error must be a function"
	end
	local sequence_state = stream:GetProducerSequenceAsync(route_key, producer_id)
	if type(sequence_state) ~= "table" or sequence_state.code ~= "ok"
		or not integer_at_least(sequence_state.sequence, 0)
		or sequence_state.sequence >= MAX_SAFE_INTEGER
	then
		return nil, "producer sequence could not be initialized: " .. tostring(sequence_state and sequence_state.message or sequence_state and sequence_state.code or "invalid response")
	end
	local selected_schedule = schedule or function(delay_seconds: number, callback: () -> ())
		task.delay(delay_seconds, callback)
	end
	local selected_defer = defer or function(callback: () -> ())
		task.defer(callback)
	end
	local client: any = {
		_stream = stream,
		_route_key = route_key,
		_producer_id = producer_id,
		_next_sequence = sequence_state.sequence + 1,
		_queue = table.create(capacity),
		_head = 1,
		_tail = 1,
		_count = 0,
		_capacity = capacity,
		_max_batch_messages = max_batch_messages,
		_flush_delay_seconds = flush_delay_seconds,
		_busy = false,
		_closing = false,
		_closed = false,
		_scheduled = false,
		_schedule_generation = 0,
		_schedule = selected_schedule,
		_defer = selected_defer,
		_on_result = on_result,
		_on_error = on_error,
		_pending_event_ids = {},
	}
	return setmetatable(client, Client) :: ClientType, nil
end

function Client.GetPendingCount(self: ClientType): number
	return self._count
end

function Client.Enqueue(self: ClientType, event_id: string, payload: any): any
	if self._closed or self._closing then
		return { code = "closed" }
	end
	if not valid_text(event_id, MAX_EVENT_ID_BYTES) then
		return { code = "invalid", message = "event_id must be 1..128 bytes" }
	end
	if self._pending_event_ids[event_id] then
		return { code = "conflict", message = "event_id is already pending in this publisher" }
	end
	if self._count >= self._capacity then
		return { code = "capacity", message = "publisher ring buffer is full", pending = self._count }
	end
	if self._next_sequence >= MAX_SAFE_INTEGER then
		return { code = "capacity", message = "producer sequence space is exhausted" }
	end
	local copied_payload, payload_error = snapshot_payload(payload)
	if payload_error ~= nil then
		return { code = "invalid", message = payload_error }
	end
	local sequence = self._next_sequence
	self._next_sequence += 1
	self._queue[self._tail] = {
		event_id = event_id,
		payload = copied_payload,
		producer_id = self._producer_id,
		producer_sequence = sequence,
	}
	self._tail = self._tail % self._capacity + 1
	self._count += 1
	self._pending_event_ids[event_id] = true
	if self._count >= self._max_batch_messages then
		cancel_schedule(self)
		schedule_flush(self, 0)
	else
		schedule_flush(self, self._flush_delay_seconds)
	end
	return { code = "queued", durable = false, producer_sequence = sequence, pending = self._count }
end

function Client.FlushAsync(self: ClientType): any
	if self._closed then
		return { code = "closed" }
	end
	if self._busy then
		return { code = "busy", pending = self._count }
	end
	if self._count == 0 then
		cancel_schedule(self)
		return { code = "idle", pending = 0 }
	end
	cancel_schedule(self)
	self._busy = true
	local batch_count = math.min(self._count, self._max_batch_messages)
	local events = table.create(batch_count)
	for index = 1, batch_count do
		local queue_index = (self._head + index - 2) % self._capacity + 1
		events[index] = self._queue[queue_index]
	end
	local ok, result = pcall(function()
		return self._stream:PublishBatchAsync(self._route_key, events)
	end)
	if not ok then
		result = { code = "unknown", message = tostring(result) }
	end
	if type(result) ~= "table" then
		result = { code = "unknown", message = "durable stream returned a malformed result" }
	end
	if result.code == "committed" then
		if result.count ~= batch_count then
			result = {
				code = "unknown",
				message = "durable stream reported a committed batch with a mismatched event count",
				expected_count = batch_count,
				committed_count = result.count,
			}
		else
			for _ = 1, batch_count do
				local queued = self._queue[self._head]
				self._pending_event_ids[queued.event_id] = nil
				self._queue[self._head] = nil
				self._head = self._head % self._capacity + 1
				self._count -= 1
			end
		end
	end
	self._busy = false
	notify_result(self, result, batch_count)
	if self._count > 0 and result.code == "committed" then
		schedule_flush(self, if self._count >= self._max_batch_messages then 0 else self._flush_delay_seconds)
	end
	return result
end

function Client.CloseAsync(self: ClientType): any
	if self._closed then
		return { code = "closed" }
	end
	self._closing = true
	cancel_schedule(self)
	while self._count > 0 do
		local result = self:FlushAsync()
		if result.code ~= "committed" then
			return result
		end
	end
	self._closed = true
	cancel_schedule(self)
	return { code = "closed", flushed = true, pending = 0 }
end

return table.freeze(Publisher)
