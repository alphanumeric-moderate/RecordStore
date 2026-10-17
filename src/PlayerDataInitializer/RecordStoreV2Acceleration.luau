--!strict
-- Optional, advisory v2 wake-up accelerator.
-- Durable mailbox records remain authoritative; wake-up loss only adds polling delay.
-- Subscribe to a fixed number of shard topics, never one topic per player/profile.

local Acceleration = {}
Acceleration.__index = Acceleration

type Dict = { [string]: unknown }
type Callback = (reason: string, owner_digest: string) -> ()
type Connection = { Disconnect: (self: Connection) -> () }
type MessagingLike = {
	SubscribeAsync: (self: MessagingLike, topic: string, callback: (unknown) -> ()) -> Connection,
	PublishAsync: (self: MessagingLike, topic: string, payload: Dict) -> unknown,
}
type MemoryMapLike = {
	SetAsync: (self: MemoryMapLike, key: string, value: unknown, expiration: number) -> unknown,
	GetAsync: (self: MemoryMapLike, key: string) -> unknown,
}
type RequestRunner = {
	run_runtime_request: (kind: string, callback: () -> unknown, operation_deadline: number?, work_class: string?) -> (unknown, string?, string?),
}
type Config = {
	messaging_service: MessagingLike?,
	request_runner: RequestRunner?,
	operation_deadline_seconds: number?,
	memory_map: MemoryMapLike?,
	topic_prefix: string?,
	shard_count: number?,
	max_registrations: number?,
	max_candidates: number?,
	max_message_age_ms: number?,
	future_skew_ms: number?,
	memory_ttl_seconds: number?,
	poll_interval_seconds: number?,
	max_poll_callbacks_per_tick: number?,
	now_ms: (() -> number)?,
	guid: (() -> string)?,
}
type Registration = {
	identity_digest: string,
	shard: number,
	callback: Callback,
}
type Pending = {
	reason: string,
	event_id: string?,
	updated_at_ms: number,
}

type State = typeof(setmetatable({} :: {
	messaging_service: MessagingLike,
	request_runner: RequestRunner?,
	operation_deadline_seconds: number?,
	memory_map: MemoryMapLike?,
	topic_prefix: string,
	shard_count: number,
	max_registrations: number,
	max_candidates: number,
	max_message_age_ms: number,
	future_skew_ms: number,
	memory_ttl_seconds: number,
	poll_interval_seconds: number,
	max_poll_callbacks_per_tick: number,
	now_ms: () -> number,
	guid: (() -> string)?,
	running: boolean,
	connections: { Connection },
	subscribed_shards: { [number]: boolean },
	poller_started: boolean,
	registrations: { [string]: Registration },
	registration_order: { string },
	poll_cursor: number,
	pending: { [string]: Pending },
	pending_count: number,
	running_callbacks: { [string]: boolean },
	metrics: { [string]: number | string },
}, Acceleration))

local VERSION = 1
local MAX_TOPIC_LENGTH = 80
local MAX_IDENTITY_BYTES = 1024
local DEFAULT_TOPIC_PREFIX = "recordstore:v2:wake"
local DEFAULT_SHARDS = 16
local DEFAULT_REGISTRATIONS = 512
local DEFAULT_CANDIDATES = 512
local DEFAULT_MAX_AGE_MS = 60_000
local DEFAULT_FUTURE_SKEW_MS = 5_000
local DEFAULT_MEMORY_TTL_SECONDS = 30
local DEFAULT_POLL_INTERVAL_SECONDS = 3
local DEFAULT_POLL_CALLBACKS_PER_TICK = 64

local function finite(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function valid_text(value: unknown, maximum: number): boolean
	return type(value) == "string" and value ~= "" and #value <= maximum
end

-- Routing only. Products stay below 2^53, so integer arithmetic is exact in Luau numbers.
-- The full identity is never published or used as a MemoryStore key.
local function digest(value: string): string
	local parts = table.create(4)
	for seed = 1, 4 do
		local hash = 2166136261 + seed * 7919
		for index = 1, #value do
			hash = (string.byte(value, index) + hash * 65599) % 4294967296
		end
		parts[seed] = string.format("%08x", hash)
	end
	return table.concat(parts, "")
end

local function now_default(): number
	return DateTime.now().UnixTimestampMillis
end

local function shard_for_digest(owner_digest: string, shard_count: number): number
	local number = tonumber(string.sub(owner_digest, 1, 8), 16) or 0
	return (number % shard_count) + 1
end

local function topic_for(self: State, shard: number): string
	return self.topic_prefix .. ":" .. tostring(shard)
end

local function memory_key(shard: number, owner_digest: string): string
	return "rs2w-" .. tostring(shard) .. "-" .. owner_digest
end

local function call_external(self: State, kind: string, callback: () -> unknown): unknown
	if self.request_runner == nil then return callback() end
	local result, code, message = self.request_runner.run_runtime_request(
		kind,
		callback,
		self.operation_deadline_seconds,
		"messaging"
	)
	if code ~= nil then
		error(("shared RecordStore runtime gate rejected an external service call (%s): %s"):format(tostring(code), tostring(message or "")), 3)
	end
	return result
end

local function valid_reason(reason: unknown): boolean
	return reason == "enqueue" or reason == "retry" or reason == "outbox" or reason == "manual" or reason == "poll"
end

local function queue_candidate(self: State, owner_digest: string, reason: string, event_id: string?)
	local registration = self.registrations[owner_digest]
	if registration == nil then
		self.metrics.unregistered_hints += 1
		return
	end
	local pending = self.pending[owner_digest]
	if pending ~= nil then
		pending.reason = if pending.reason == "poll" then reason else pending.reason
		pending.event_id = event_id or pending.event_id
		pending.updated_at_ms = self.now_ms()
		self.metrics.coalesced_hints += 1
	else
		if self.pending_count >= self.max_candidates then
			local oldest, oldest_at = nil, nil
			for identity, candidate in pairs(self.pending) do
				if not self.running_callbacks[identity] and (oldest_at == nil or candidate.updated_at_ms < oldest_at) then
					oldest, oldest_at = identity, candidate.updated_at_ms
				end
			end
			if oldest ~= nil then
				self.pending[oldest] = nil
				self.pending_count = math.max(0, self.pending_count - 1)
				self.metrics.candidate_evictions += 1
			else
				self.metrics.candidate_drops += 1
				return
			end
		end
		self.pending[owner_digest] = { reason = reason, event_id = event_id, updated_at_ms = self.now_ms() }
		self.pending_count += 1
	end
	if self.running_callbacks[owner_digest] then return end

	self.running_callbacks[owner_digest] = true
	task.spawn(function()
		while self.running do
			local candidate = self.pending[owner_digest]
			if candidate == nil then break end
			self.pending[owner_digest] = nil
			self.pending_count = math.max(0, self.pending_count - 1)
			local current_registration = self.registrations[owner_digest]
			if current_registration == nil then break end
			local ok, message = pcall(current_registration.callback, candidate.reason, current_registration.identity_digest)
			if ok then
				self.metrics.callbacks += 1
			else
				self.metrics.callback_errors += 1
				self.metrics.last_error = string.sub(string.gsub(tostring(message), "%c", " "), 1, 200)
			end
		end
		self.running_callbacks[owner_digest] = nil
	end)
end

local function parse_message(self: State, payload_value: unknown, expected_shard: number): (Dict?, string?)
	if type(payload_value) ~= "table" then return nil, "payload is not an object" end
	local payload = payload_value :: Dict
	if payload.version ~= VERSION or payload.shard ~= expected_shard then return nil, "version/shard mismatch" end
	if type(payload.owner_digest) ~= "string" or #payload.owner_digest ~= 32
		or string.match(payload.owner_digest, "^[0-9a-f]+$") == nil
	then
		return nil, "owner_digest must be exactly 32 lowercase hex characters"
	end
	if not valid_text(payload.event_id, 128) or not valid_reason(payload.reason) or not finite(payload.issued_at_ms) then
		return nil, "message fields are invalid"
	end
	local now = self.now_ms()
	if (payload.issued_at_ms :: number) < now - self.max_message_age_ms
		or (payload.issued_at_ms :: number) > now + self.future_skew_ms
	then
		return nil, "message is outside the accepted age window"
	end
	return payload, nil
end

local function receive(self: State, payload_value: unknown, shard: number)
	local payload, message = parse_message(self, payload_value, shard)
	if payload == nil then
		self.metrics.invalid_hints += 1
		self.metrics.last_error = tostring(message)
		return
	end
	self.metrics.received_hints += 1
	queue_candidate(self, payload.owner_digest :: string, payload.reason :: string, payload.event_id :: string)
end

function Acceleration.new(config: Config?): State
	config = config or {}
	local messaging_service = config.messaging_service or game:GetService("MessagingService")
	if type(messaging_service) ~= "table" and typeof(messaging_service) ~= "Instance" then
		error("messaging_service is invalid", 2)
	end
	local prefix = config.topic_prefix or DEFAULT_TOPIC_PREFIX
	if not valid_text(prefix, 64) or #prefix + 1 + #tostring(config.shard_count or DEFAULT_SHARDS) > MAX_TOPIC_LENGTH then
		error("topic_prefix must leave room for the shard suffix within the 80-character topic limit", 2)
	end
	local shard_count = config.shard_count or DEFAULT_SHARDS
	if not finite(shard_count) or shard_count < 1 or shard_count > 16 or shard_count ~= math.floor(shard_count) then
		error("shard_count must be an integer from 1 to 16", 2)
	end
	local function bounded_number(value: number?, fallback: number, minimum: number, maximum: number, name: string): number
		local result = value or fallback
		if not finite(result) or result < minimum or result > maximum then
			error(name .. " is outside its allowed bounds", 2)
		end
		return result
	end
	local self: State = {
		messaging_service = messaging_service :: MessagingLike,
		request_runner = config.request_runner,
		operation_deadline_seconds = config.operation_deadline_seconds,
		memory_map = config.memory_map,
		topic_prefix = prefix,
		shard_count = shard_count,
		max_registrations = bounded_number(config.max_registrations, DEFAULT_REGISTRATIONS, 1, 4096, "max_registrations"),
		max_candidates = bounded_number(config.max_candidates, DEFAULT_CANDIDATES, 1, 4096, "max_candidates"),
		max_message_age_ms = bounded_number(config.max_message_age_ms, DEFAULT_MAX_AGE_MS, 1000, 600_000, "max_message_age_ms"),
		future_skew_ms = bounded_number(config.future_skew_ms, DEFAULT_FUTURE_SKEW_MS, 0, 60_000, "future_skew_ms"),
		memory_ttl_seconds = bounded_number(config.memory_ttl_seconds, DEFAULT_MEMORY_TTL_SECONDS, 1, 3600, "memory_ttl_seconds"),
		poll_interval_seconds = bounded_number(config.poll_interval_seconds, DEFAULT_POLL_INTERVAL_SECONDS, 0.1, 60, "poll_interval_seconds"),
		max_poll_callbacks_per_tick = bounded_number(config.max_poll_callbacks_per_tick, DEFAULT_POLL_CALLBACKS_PER_TICK, 1, 1024, "max_poll_callbacks_per_tick"),
		now_ms = config.now_ms or now_default,
		guid = config.guid,
		running = false,
		connections = {},
		subscribed_shards = {},
		poller_started = false,
		registrations = {},
		registration_order = {},
		poll_cursor = 1,
		pending = {},
		pending_count = 0,
		running_callbacks = {},
		metrics = {
			published_hints = 0,
			publish_errors = 0,
			received_hints = 0,
			invalid_hints = 0,
			unregistered_hints = 0,
			coalesced_hints = 0,
			candidate_evictions = 0,
			candidate_drops = 0,
			callbacks = 0,
			callback_errors = 0,
			poll_callbacks = 0,
			memory_writes = 0,
			memory_write_errors = 0,
			memory_reads = 0,
			memory_read_errors = 0,
			last_error = "",
		},
	}
	return setmetatable(self, Acceleration) :: State
end

function Acceleration.IdentityDigest(_self: State, owner_identity: string): string?
	if not valid_text(owner_identity, MAX_IDENTITY_BYTES) then return nil end
	return digest(owner_identity)
end

function Acceleration.ShardFor(self: State, owner_identity: string): (number?, string?)
	local owner_digest = self:IdentityDigest(owner_identity)
	if owner_digest == nil then return nil, "owner identity must be 1 to 1024 bytes" end
	return shard_for_digest(owner_digest, self.shard_count), owner_digest
end

function Acceleration.Register(self: State, owner_identity: string, callback: Callback): (boolean, string?)
	if not valid_text(owner_identity, MAX_IDENTITY_BYTES) or type(callback) ~= "function" then
		return false, "Register requires a bounded identity and callback"
	end
	local owner_digest = digest(owner_identity)
	if self.registrations[owner_digest] == nil then
		local count = 0
		for _ in pairs(self.registrations) do count += 1 end
		if count >= self.max_registrations then return false, "local owner registration capacity reached" end
		table.insert(self.registration_order, owner_digest)
	end
	self.registrations[owner_digest] = {
		identity_digest = owner_digest,
		shard = shard_for_digest(owner_digest, self.shard_count),
		callback = callback,
	}
	return true, nil
end

function Acceleration.Unregister(self: State, owner_identity: string): boolean
	if not valid_text(owner_identity, MAX_IDENTITY_BYTES) then return false end
	local owner_digest = digest(owner_identity)
	self.registrations[owner_digest] = nil
	if self.pending[owner_digest] ~= nil then
		self.pending[owner_digest] = nil
		self.pending_count = math.max(0, self.pending_count - 1)
	end
	for index = #self.registration_order, 1, -1 do
		if self.registration_order[index] == owner_digest then table.remove(self.registration_order, index) end
	end
	if self.poll_cursor > #self.registration_order then self.poll_cursor = 1 end
	return true
end

function Acceleration.Wake(self: State, owner_identity: string, reason: string?): (boolean, string?)
	if not valid_text(owner_identity, MAX_IDENTITY_BYTES) then return false, "owner identity is invalid" end
	local actual_reason = reason or "manual"
	if not valid_reason(actual_reason) then return false, "unsupported wake reason" end
	local owner_digest = digest(owner_identity)
	if self.registrations[owner_digest] == nil then return false, "owner is not registered" end
	queue_candidate(self, owner_digest, actual_reason, nil)
	return true, nil
end

function Acceleration.Publish(self: State, owner_identity: string, reason: string?): { [string]: unknown }
	if not valid_text(owner_identity, MAX_IDENTITY_BYTES) then return { code = "invalid", durable = false, message = "owner identity is invalid" } end
	local actual_reason = reason or "enqueue"
	if actual_reason == "poll" or not valid_reason(actual_reason) then return { code = "invalid", durable = false, message = "unsupported publish reason" } end
	local owner_digest = digest(owner_identity)
	local shard = shard_for_digest(owner_digest, self.shard_count)
	local event_id = if self.guid ~= nil then self.guid() else ("%d-%s"):format(self.now_ms(), string.sub(digest(owner_digest .. tostring(self.now_ms())), 1, 16))
	if not valid_text(event_id, 128) then return { code = "invalid", durable = false, message = "guid callback returned an invalid event ID" } end
	local payload: Dict = {
		version = VERSION,
		shard = shard,
		owner_digest = owner_digest,
		event_id = event_id,
		issued_at_ms = self.now_ms(),
		reason = actual_reason,
	}
	task.spawn(function()
		if self.memory_map ~= nil then
			local ok, message = pcall(function()
				call_external(self, "service", function()
					return self.memory_map:SetAsync(memory_key(shard, owner_digest), payload, self.memory_ttl_seconds)
				end)
			end)
			if ok then self.metrics.memory_writes += 1 else
				self.metrics.memory_write_errors += 1
				self.metrics.last_error = string.sub(string.gsub(tostring(message), "%c", " "), 1, 200)
			end
		end
		local ok, message = pcall(function()
			call_external(self, "service", function()
				return self.messaging_service:PublishAsync(topic_for(self, shard), payload)
			end)
		end)
		if ok then
			self.metrics.published_hints += 1
		else
			self.metrics.publish_errors += 1
			self.metrics.last_error = string.sub(string.gsub(tostring(message), "%c", " "), 1, 200)
		end
	end)
	return { code = "scheduled", durable = false, shard = shard, owner_digest = owner_digest, event_id = event_id }
end

function Acceleration.ProbeHint(self: State, owner_identity: string): (boolean, string?)
	if self.memory_map == nil then return false, "MemoryStore hint map is not configured" end
	if not valid_text(owner_identity, MAX_IDENTITY_BYTES) then return false, "owner identity is invalid" end
	local owner_digest = digest(owner_identity)
	local shard = shard_for_digest(owner_digest, self.shard_count)
	local ok, value = pcall(function()
		return call_external(self, "service", function()
			return self.memory_map:GetAsync(memory_key(shard, owner_digest))
		end)
	end)
	if not ok then
		self.metrics.memory_read_errors += 1
		self.metrics.last_error = string.sub(string.gsub(tostring(value), "%c", " "), 1, 200)
		return false, tostring(value)
	end
	self.metrics.memory_reads += 1
	local payload, message = parse_message(self, value, shard)
	if payload == nil then return false, message end
	if payload.owner_digest ~= owner_digest then return false, "MemoryStore hint identity does not match" end
	queue_candidate(self, owner_digest, payload.reason :: string, payload.event_id :: string)
	return true, nil
end

function Acceleration.Start(self: State): (boolean, string?)
	self.running = true
	local failures = 0
	for shard = 1, self.shard_count do
		if not self.subscribed_shards[shard] then
			local expected_shard = shard
			local ok, connection = pcall(function()
				return call_external(self, "service", function()
					return self.messaging_service:SubscribeAsync(topic_for(self, expected_shard), function(message)
						local payload = if type(message) == "table" then (message :: Dict).Data else nil
						receive(self, payload, expected_shard)
					end)
				end)
			end)
			if ok and connection ~= nil then
				self.subscribed_shards[shard] = true
				table.insert(self.connections, connection :: Connection)
			else
				failures += 1
				self.metrics.last_error = string.sub(string.gsub(tostring(connection), "%c", " "), 1, 200)
			end
		end
	end
	if not self.poller_started then
		self.poller_started = true
		task.spawn(function()
			while self.running do
				task.wait(self.poll_interval_seconds)
				if not self.running then break end
				local count = #self.registration_order
				if count == 0 then continue end
				local delivered = 0
				local examined = 0
				while examined < count and delivered < self.max_poll_callbacks_per_tick do
					if self.poll_cursor > count then self.poll_cursor = 1 end
					local owner_digest = self.registration_order[self.poll_cursor]
					self.poll_cursor += 1
					examined += 1
					if self.registrations[owner_digest] ~= nil then
						queue_candidate(self, owner_digest, "poll", nil)
						self.metrics.poll_callbacks += 1
						delivered += 1
					end
				end
			end
			self.poller_started = false
		end)
	end
	return failures == 0, if failures == 0 then nil else ("%d shard subscriptions failed; polling fallback remains active; call Start again to retry subscriptions"):format(failures)
end

function Acceleration.Stop(self: State)
	self.running = false
	for _, connection in ipairs(self.connections) do
		pcall(function() connection:Disconnect() end)
	end
	table.clear(self.connections)
	table.clear(self.subscribed_shards)
end

function Acceleration.Stats(self: State): { [string]: unknown }
	local registrations = 0
	local pending = 0
	for _ in pairs(self.registrations) do registrations += 1 end
	for _ in pairs(self.pending) do pending += 1 end
	return {
		running = self.running,
		shard_count = self.shard_count,
		active_subscriptions = #self.connections,
		registrations = registrations,
		candidate_count = pending,
		metrics = table.clone(self.metrics),
		memory_map_configured = self.memory_map ~= nil,
		shared_request_gate_configured = self.request_runner ~= nil,
		hints_are_authoritative = false,
	}
end

Acceleration.Version = VERSION
return Acceleration
