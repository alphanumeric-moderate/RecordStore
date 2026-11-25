--!strict
local SHA256 = require(script.Parent.RecordStoreSHA256)

local DurableStreams = {}
local Stream = {}
Stream.__index = Stream

local MAX_STREAM_NAME_BYTES = 96
local MAX_GROUP_NAME_BYTES = 96
local MAX_ROUTE_KEY_BYTES = 128
local MAX_EVENT_ID_BYTES = 128
local MAX_PRODUCER_ID_BYTES = 64
local MAX_PRODUCERS_PER_PARTITION = 128
local MAX_PRODUCER_STATE_BYTES = 65536
local MAX_PARTITIONS = 32
local MAX_SEGMENT_MESSAGES = 64
local MAX_SEGMENT_BYTES = 262144
local MAX_PAYLOAD_BYTES = 32768
local MAX_BATCH_MESSAGES = 32
local MIN_LEASE_SECONDS = 5
local MAX_LEASE_SECONDS = 120
local MAX_PAYLOAD_DEPTH = 32
local MAX_PAYLOAD_NODES = 4096
local MAX_SAFE_INTEGER = 9007199254740991
local MAX_CONSUMER_GROUPS = 16
local MAX_MAINTENANCE_LEASE_SECONDS = 600

type Message = {
	sequence: number,
	event_id: string,
	payload: any,
	payload_digest: string,
	payload_bytes: number,
	created_at: number,
	producer_id: string?,
	producer_sequence: number?,
}

type ProducerState = {
	sequence: number,
	stream_sequence: number,
	event_id: string,
	payload_digest: string,
}

type ProducerStates = {
	[string]: ProducerState,
}

type Segment = {
	format: number,
	stream: string,
	partition: number,
	segment: number,
	created_at: number,
	first_sequence: number,
	last_sequence: number,
	bytes: number,
	sealed: boolean,
	chain_integrity: string,
	integrity: string,
	messages: { Message },
	producer_states: ProducerStates,
}

type Head = {
	format: number,
	stream: string,
	partition: number,
	active_segment: number,
	next_sequence: number,
	retained_segment: number,
	retained_sequence: number,
	cleanup_segment: number,
	retention_generation: number,
	producer_states: ProducerStates,
	producer_integrity: string,
}

	type CursorRecord = {
	format: number,
	stream: string,
	group: string,
	partition: number,
	segment: number,
	offset: number,
	generation: number,
	owner_token: string?,
	lease_until: number,
}

type ClaimState = {
	group: string,
	partition: number,
	owner_token: string,
	generation: number,
	segment: number,
	offset: number,
	lease_until: number,
	lease_seconds: number,
	cursor_key: string,
	claim_key: string,
	released: boolean,
}

type GroupPosition = {
	segment: number,
	offset: number,
}

type RetentionFloor = {
	segment: number,
	sequence: number,
}

type ConsumerGroup = {
	name: string,
	retention_protected: boolean,
	removing: boolean,
	start_mode: string,
	explicit_segment: number?,
	explicit_offset: number?,
	positions: { GroupPosition },
}

type GroupRegistry = {
	format: number,
	stream: string,
	groups: { ConsumerGroup },
	floors: { RetentionFloor },
	lease_owner: string?,
	lease_generation: number,
	lease_until: number,
}

type MaintenanceLease = {
	owner: string,
	generation: number,
	lease_until: number,
}

type StreamOptions = {
	max_segment_messages: number,
	max_segment_bytes: number,
	max_payload_bytes: number,
	max_batch_messages: number,
	max_retained_segments: number,
	min_segment_age_seconds: number,
	max_segment_age_seconds: number?,
	now: () -> number,
}

type StreamType = {
	_store: any,
	_name: string,
	_hash: string,
	_partitions: number,
	_options: StreamOptions,
	_get_options: any,
	_heads: { [number]: Head },
	_claims: { [any]: ClaimState },
	_busy: { [string]: boolean },
	GetPartition: (self: StreamType, route_key: string) -> number,
	_ReadHead: (self: StreamType, partition: number) -> (Head?, string?),
	_RefreshHead: (self: StreamType, partition: number) -> (Head?, string?),
	_ReadSegment: (self: StreamType, partition: number, segment_id: number) -> (Segment?, string?),
	_ReadGroupRegistry: (self: StreamType) -> (GroupRegistry?, string?),
	_AcquireMaintenanceLease: (self: StreamType) -> (MaintenanceLease?, string?),
	_ReleaseMaintenanceLease: (self: StreamType, lease: MaintenanceLease) -> boolean,
	_FenceRetentionGeneration: (self: StreamType, lease: MaintenanceLease) -> (boolean, string?),
	_DeleteBelowRetentionFloor: (self: StreamType, partition: number, lease: MaintenanceLease, limit: number) -> (number, string?),
	_AdvanceHead: (self: StreamType, partition: number, segment: Segment) -> (boolean, string?),
	PublishAsync: (self: StreamType, route_key: string, event_id: string, payload: any, producer_id: string?, producer_sequence: number?) -> any,
	PublishBatchAsync: (self: StreamType, route_key: string, events: { any }) -> any,
	GetProducerSequenceAsync: (self: StreamType, route_key: string, producer_id: string) -> any,
	RegisterConsumerGroupAsync: (self: StreamType, group: string, start_position: any, retention_protected: boolean?) -> any,
	RemoveConsumerGroupAsync: (self: StreamType, group: string, confirm: boolean) -> any,
	PruneAsync: (self: StreamType, partition: number, max_segments: number?) -> any,
	GetRetentionStateAsync: (self: StreamType, partition: number) -> any,
	ClaimConsumerAsync: (self: StreamType, group: string, partition: number, owner_token: string, lease_seconds: number?) -> any,
	RenewConsumerAsync: (self: StreamType, claim: any) -> any,
	ConsumeBatchAsync: (self: StreamType, claim: any, handler: (any, any) -> (boolean, string?), batch_size: number?) -> any,
	ReleaseConsumerAsync: (self: StreamType, claim: any) -> any,
}

type ClientType = {
	_store: any,
	_options: StreamOptions,
	_get_options: DataStoreGetOptions,
	OpenStreamAsync: (self: ClientType, name: string, partitions: number) -> any,
}

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function integer_at_least(value: any, minimum: number): boolean
	return finite(value) and math.floor(value) == value and value >= minimum
end

local function safe_integer(value: any, minimum: number): boolean
	return integer_at_least(value, minimum) and value <= MAX_SAFE_INTEGER
end

local function valid_text(value: any, maximum: number): boolean
	return type(value) == "string" and #value > 0 and #value <= maximum
end

local function base36(value: number): string
	local digits = "0123456789abcdefghijklmnopqrstuvwxyz"
	local result = ""
	repeat
		local remainder = value % 36
		result = string.sub(digits, remainder + 1, remainder + 1) .. result
		value = math.floor(value / 36)
	until value == 0
	return result
end

local function clone_payload(value: any, seen: { [any]: boolean }, depth: number, nodes: { number }, copy_value: boolean): (any, string)
	if depth > MAX_PAYLOAD_DEPTH then
		error("payload exceeds the maximum nesting depth", 0)
	end
	local kind = type(value)
	if kind == "nil" then
		error("payload cannot be nil", 0)
	elseif kind == "boolean" then
		return if copy_value then value else nil, if value then "b1" else "b0"
	elseif kind == "number" then
		if not finite(value) then
			error("payload numbers must be finite", 0)
		end
		return if copy_value then value else nil, if value == 0 then "d0" else "d" .. string.format("%.17g", value)
	elseif kind == "string" then
		return if copy_value then value else nil, "s" .. tostring(#value) .. ":" .. value
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
		error("payload exceeds the maximum node count", 0)
	end
	seen[value] = true
	local count = 0
	local numeric_keys = true
	local string_keys = true
	local max_index = 0
	for key in pairs(value) do
		count += 1
		if type(key) == "number" and integer_at_least(key, 1) then
			max_index = math.max(max_index, key)
		else
			numeric_keys = false
		end
		if type(key) ~= "string" then
			string_keys = false
		end
	end
	local copied: any = if copy_value then {} else nil
	local canonical: string
	if count > 0 and numeric_keys and max_index == count then
		local parts = table.create(count)
		for index = 1, count do
			local child, encoded = clone_payload(value[index], seen, depth + 1, nodes, copy_value)
			if copy_value then copied[index] = child end
			parts[index] = encoded
		end
		canonical = "a" .. tostring(count) .. "[" .. table.concat(parts, "") .. "]"
	elseif count == 0 or string_keys then
		local keys = {}
		for key in pairs(value) do
			table.insert(keys, key)
		end
		table.sort(keys)
		local parts = table.create(count * 2)
		for index, key in ipairs(keys) do
			local child, encoded = clone_payload(value[key], seen, depth + 1, nodes, copy_value)
			if copy_value then copied[key] = child end
			parts[index * 2 - 1] = "s" .. tostring(#key) .. ":" .. key
			parts[index * 2] = encoded
		end
		canonical = "o" .. tostring(count) .. "{" .. table.concat(parts, "") .. "}"
	else
		seen[value] = nil
		error("payload tables must be dense arrays or string-keyed objects", 0)
	end
	seen[value] = nil
	return if copy_value then table.freeze(copied) else nil, canonical
end

local function normalize_payload(value: any, maximum_bytes: number, copy_value: boolean): (any?, string?, number?, string?)
	local ok, copied, canonical = pcall(function()
		local result, encoded = clone_payload(value, {}, 0, { 0 }, copy_value)
		return result, encoded
	end)
	if not ok then
		return nil, nil, nil, tostring(copied)
	end
	local bytes = #canonical
	if bytes > maximum_bytes then
		return nil, nil, nil, "payload exceeds the configured byte limit"
	end
	return copied, canonical, bytes, nil
end

local function initial_integrity(stream_name: string, partition: number, segment: number, first_sequence: number, created_at: number): string
	return SHA256.digest(stream_name .. "\0" .. tostring(partition) .. "\0" .. tostring(segment) .. "\0" .. tostring(first_sequence) .. "\0" .. tostring(created_at))
end

local function next_integrity(previous: string, message: Message): string
	local producer_identity = ""
	if message.producer_id ~= nil then
		producer_identity = "\0producer\0" .. message.producer_id .. "\0" .. tostring(message.producer_sequence)
	end
	return SHA256.digest(
		previous
			.. "\0"
			.. tostring(message.sequence)
			.. "\0"
			.. message.event_id
			.. "\0"
			.. message.payload_digest
			.. "\0"
			.. tostring(message.payload_bytes)
			.. producer_identity
	)
end

local function producer_state_digest(states: ProducerStates): string
	local producer_ids = {}
	for producer_id in pairs(states) do
		producer_ids[#producer_ids + 1] = producer_id
	end
	table.sort(producer_ids)
	local parts = table.create(#producer_ids)
	for index, producer_id in ipairs(producer_ids) do
		local state = states[producer_id]
		parts[index] = tostring(#producer_id)
			.. ":" .. producer_id
			.. ":" .. tostring(state.sequence)
			.. ":" .. tostring(state.stream_sequence)
			.. ":" .. tostring(#state.event_id)
			.. ":" .. state.event_id
			.. ":" .. state.payload_digest
	end
	return SHA256.digest(table.concat(parts, "\0"))
end

local function validate_producer_states(value: any): (ProducerStates?, string?)
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return nil, "producer checkpoint table is malformed"
	end
	local count = 0
	local bytes = 0
	for producer_id, state in pairs(value) do
		count += 1
		if not valid_text(producer_id, MAX_PRODUCER_ID_BYTES)
			or type(state) ~= "table"
			or getmetatable(state) ~= nil
			or not safe_integer(state.sequence, 1)
			or not safe_integer(state.stream_sequence, 1)
			or not valid_text(state.event_id, MAX_EVENT_ID_BYTES)
			or type(state.payload_digest) ~= "string"
			or #state.payload_digest ~= 64
		then
			return nil, "producer checkpoint entry is malformed"
		end
		bytes += #producer_id + #state.event_id + #state.payload_digest
			+ #tostring(state.sequence) + #tostring(state.stream_sequence) + 64
		if count > MAX_PRODUCERS_PER_PARTITION or bytes > MAX_PRODUCER_STATE_BYTES then
			return nil, "producer checkpoint exceeds its fixed storage bound"
		end
	end
	return value :: ProducerStates, nil
end

local function segment_integrity(chain: string, sealed: boolean, producer_states: ProducerStates): string
	local base = SHA256.digest(chain .. "\0sealed\0" .. (if sealed then "1" else "0"))
	return SHA256.digest(base .. "\0producer-state\0" .. producer_state_digest(producer_states))
end

local function new_segment(
	stream_name: string,
	partition: number,
	segment_id: number,
	first_sequence: number,
	created_at: number,
	producer_states: ProducerStates
): Segment
	local chain = initial_integrity(stream_name, partition, segment_id, first_sequence, created_at)
	local copied_producers = table.clone(producer_states)
	return {
		format = 3,
		stream = stream_name,
		partition = partition,
		segment = segment_id,
		created_at = created_at,
		first_sequence = first_sequence,
		last_sequence = first_sequence - 1,
		bytes = 0,
		sealed = false,
		chain_integrity = chain,
		integrity = segment_integrity(chain, false, copied_producers),
		messages = {},
		producer_states = copied_producers,
	}
end

local function validate_head(value: any, stream_name: string, partition: number): (Head?, string?)
	if type(value) ~= "table" then
		return nil, "partition head is missing or malformed"
	end
	if value.format ~= 3 then
		return nil, "unsupported partition-head format"
	end
	if value.stream ~= stream_name or value.partition ~= partition then
		return nil, "partition-head identity mismatch"
	end
	if not safe_integer(value.active_segment, 1) or not safe_integer(value.next_sequence, 1)
		or not safe_integer(value.retained_segment, 1) or value.retained_segment > value.active_segment
		or not safe_integer(value.retained_sequence, 1) or value.retained_sequence > value.next_sequence
		or not safe_integer(value.cleanup_segment, 1) or value.cleanup_segment > value.retained_segment
		or not safe_integer(value.retention_generation, 0)
	then
		return nil, "partition head contains invalid sequence or retention metadata"
	end
	local producers, producer_error = validate_producer_states(value.producer_states)
	if producers == nil or type(value.producer_integrity) ~= "string"
		or value.producer_integrity ~= producer_state_digest(producers)
	then
		return nil, "partition head producer checkpoint is corrupt: " .. tostring(producer_error or "integrity mismatch")
	end
	return value :: Head, nil
end

local function validate_segment(
	value: any,
	stream_name: string,
	partition: number,
	segment_id: number,
	options: StreamOptions
): (Segment?, string?)
	if type(value) ~= "table" or value.format ~= 3 then
		return nil, "missing, malformed, or unsupported segment"
	end
	if value.stream ~= stream_name or value.partition ~= partition or value.segment ~= segment_id then
		return nil, "segment identity mismatch"
	end
	if not safe_integer(value.created_at, 0)
		or not safe_integer(value.first_sequence, 1)
		or not safe_integer(value.last_sequence, 0)
		or not integer_at_least(value.bytes, 0)
		or not safe_integer(value.segment, 1)
		or type(value.sealed) ~= "boolean"
		or type(value.chain_integrity) ~= "string"
		or type(value.integrity) ~= "string"
		or type(value.messages) ~= "table"
	then
		return nil, "segment metadata is malformed"
	end
	local producer_states, producer_error = validate_producer_states(value.producer_states)
	if producer_states == nil then
		return nil, "segment producer checkpoint is malformed: " .. tostring(producer_error)
	end
	local messages = value.messages
	local count = #messages
	local message_keys = 0
	for key in pairs(messages) do
		if not integer_at_least(key, 1) or key > count then
			return nil, "segment message array is not dense"
		end
		message_keys += 1
	end
	if message_keys ~= count then
		return nil, "segment message array is not dense"
	end
	if count > options.max_segment_messages or value.bytes > options.max_segment_bytes then
		return nil, "segment exceeds its configured bounds"
	end
	if value.last_sequence ~= value.first_sequence + count - 1 then
		return nil, "segment sequence range is discontinuous"
	end
	local expected_integrity = initial_integrity(stream_name, partition, segment_id, value.first_sequence, value.created_at)
	local expected_bytes = 0
	local seen_event_ids: { [string]: boolean } = {}
	for index = 1, count do
		local message = messages[index]
		if type(message) ~= "table"
			or message.sequence ~= value.first_sequence + index - 1
			or not valid_text(message.event_id, MAX_EVENT_ID_BYTES)
			or type(message.payload_digest) ~= "string"
			or not safe_integer(message.payload_bytes, 1)
			or not safe_integer(message.created_at, 0)
			or (message.producer_id ~= nil and (
				not valid_text(message.producer_id, MAX_PRODUCER_ID_BYTES)
				or not safe_integer(message.producer_sequence, 1)
			))
			or (message.producer_id == nil and message.producer_sequence ~= nil)
		then
			return nil, "segment message metadata is malformed"
		end
		local _, canonical, payload_bytes, payload_error = normalize_payload(message.payload, options.max_payload_bytes, false)
		if payload_error ~= nil or canonical == nil or payload_bytes == nil then
			return nil, "segment payload is invalid: " .. tostring(payload_error)
		end
		local actual_digest = SHA256.digest(canonical)
		local producer_bytes = if message.producer_id ~= nil
			then #message.producer_id + #tostring(message.producer_sequence) + 24
			else 0
		local actual_bytes = #message.event_id + payload_bytes + 64 + producer_bytes
		if seen_event_ids[message.event_id] then
			return nil, "segment contains a duplicate event identity"
		end
		seen_event_ids[message.event_id] = true
		if actual_digest ~= message.payload_digest or actual_bytes ~= message.payload_bytes then
			return nil, "segment payload digest or byte count mismatch"
		end
		if message.producer_id ~= nil then
			local state = producer_states[message.producer_id]
			if state == nil or state.sequence < (message.producer_sequence :: number) then
				return nil, "producer checkpoint is behind a stored message"
			end
			if state.sequence == message.producer_sequence
				and (state.stream_sequence ~= message.sequence or state.event_id ~= message.event_id or state.payload_digest ~= message.payload_digest)
			then
				return nil, "latest producer checkpoint disagrees with its message"
			end
		end
		expected_bytes += actual_bytes
		expected_integrity = next_integrity(expected_integrity, message :: Message)
	end
	for _, state in pairs(producer_states) do
		if state.stream_sequence > value.last_sequence then
			return nil, "producer checkpoint is ahead of the segment sequence range"
		end
		if state.stream_sequence >= value.first_sequence then
			local latest = messages[state.stream_sequence - value.first_sequence + 1]
			if latest == nil or latest.producer_id == nil or latest.producer_sequence ~= state.sequence
				or latest.event_id ~= state.event_id or latest.payload_digest ~= state.payload_digest
			then
				return nil, "producer checkpoint does not identify its latest segment message"
			end
		end
	end
	if expected_bytes ~= value.bytes
		or expected_integrity ~= value.chain_integrity
		or segment_integrity(expected_integrity, value.sealed, producer_states) ~= value.integrity
	then
		return nil, "segment integrity verification failed"
	end
	return value :: Segment, nil
end

local function validate_cursor(value: any, stream_name: string, group: string, partition: number): (CursorRecord?, string?)
	if type(value) ~= "table" or value.format ~= 3 then
		return nil, "consumer cursor is missing, malformed, or unsupported"
	end
	if value.stream ~= stream_name or value.group ~= group or value.partition ~= partition then
		return nil, "consumer cursor identity mismatch"
	end
	if not safe_integer(value.segment, 1)
		or not safe_integer(value.offset, 1)
		or not safe_integer(value.generation, 0)
		or not safe_integer(value.lease_until, 0)
		or (value.owner_token ~= nil and not valid_text(value.owner_token, 128))
	then
		return nil, "consumer cursor metadata is malformed"
	end
	return value :: CursorRecord, nil
end

local function copy_head(head: Head): Head
	return {
		format = head.format,
		stream = head.stream,
		partition = head.partition,
		active_segment = head.active_segment,
		next_sequence = head.next_sequence,
		retained_segment = head.retained_segment,
		retained_sequence = head.retained_sequence,
		cleanup_segment = head.cleanup_segment,
		retention_generation = head.retention_generation,
		producer_states = table.clone(head.producer_states),
		producer_integrity = head.producer_integrity,
	}
end

local function copy_cursor(cursor: CursorRecord): CursorRecord
	return {
		format = cursor.format,
		stream = cursor.stream,
		group = cursor.group,
		partition = cursor.partition,
		segment = cursor.segment,
		offset = cursor.offset,
		generation = cursor.generation,
		owner_token = cursor.owner_token,
		lease_until = cursor.lease_until,
	}
end

local function datastore_get(store: any, key: string, get_options: DataStoreGetOptions): (any, string?)
	local ok, value = pcall(function()
		return store:GetAsync(key, get_options)
	end)
	if not ok then
		return nil, tostring(value)
	end
	return value, nil
end

local function datastore_update(store: any, key: string, transform: (any) -> any): (any, string?)
	local ok, value = pcall(function()
		return store:UpdateAsync(key, transform)
	end)
	if not ok then
		return nil, tostring(value)
	end
	return value, nil
end

local function datastore_remove(store: any, key: string): (boolean, string?)
	local ok, result = pcall(function()
		return store:RemoveAsync(key)
	end)
	if not ok then
		return false, tostring(result)
	end
	return true, nil
end

local function manifest_key(stream_hash: string): string
	return "rs2m" .. stream_hash
end

local function head_key(stream_hash: string, partition: number): string
	return "rs2h" .. stream_hash .. base36(partition)
end

local function group_registry_key(stream_hash: string): string
	return "rs2g" .. stream_hash
end

local function segment_key(stream_hash: string, partition: number, segment_id: number): string
	local partition_code = base36(partition)
	local segment_code = base36(segment_id)
	return "rs2s"
		.. stream_hash
		.. string.rep("0", 2 - #partition_code)
		.. partition_code
		.. string.rep("0", 11 - #segment_code)
		.. segment_code
end

local function cursor_key(stream_hash: string, group: string, partition: number): string
	return "rs2c" .. SHA256.digest(stream_hash .. "\0" .. group .. "\0" .. tostring(partition)):sub(1, 36)
end


local function validate_group_registry(value: any, stream_name: string, partitions: number): (GroupRegistry?, string?)
	if type(value) ~= "table" or value.format ~= 3 or value.stream ~= stream_name
		or type(value.groups) ~= "table" or type(value.floors) ~= "table"
		or not safe_integer(value.lease_generation, 0)
		or not safe_integer(value.lease_until, 0)
		or (value.lease_owner ~= nil and not valid_text(value.lease_owner, 128))
	then
		return nil, "consumer-group registry is missing, malformed, or unsupported"
	end
	local floor_keys = 0
	for key in pairs(value.floors) do
		if not integer_at_least(key, 1) or key > partitions then
			return nil, "retention floor array is not dense"
		end
		floor_keys += 1
	end
	if floor_keys ~= partitions then
		return nil, "retention floor array is not dense"
	end
	for partition = 1, partitions do
		local floor = value.floors[partition]
		if type(floor) ~= "table" or not safe_integer(floor.segment, 1) or not safe_integer(floor.sequence, 1) then
			return nil, "retention floor metadata is malformed"
		end
	end
	local count = #value.groups
	local keys = 0
	local names: { [string]: boolean } = {}
	for key in pairs(value.groups) do
		if not integer_at_least(key, 1) or key > count then
			return nil, "consumer-group registry array is not dense"
		end
		keys += 1
	end
	if keys ~= count or count > MAX_CONSUMER_GROUPS then
		return nil, "consumer-group registry exceeds its bounds"
	end
	for index = 1, count do
		local group = value.groups[index]
		if type(group) ~= "table" or not valid_text(group.name, MAX_GROUP_NAME_BYTES)
			or names[group.name] or type(group.retention_protected) ~= "boolean"
			or type(group.removing) ~= "boolean"
			or (group.start_mode ~= "earliest" and group.start_mode ~= "latest" and group.start_mode ~= "position")
			or (group.start_mode == "position" and (not safe_integer(group.explicit_segment, 1) or not safe_integer(group.explicit_offset, 1)))
			or type(group.positions) ~= "table" or #group.positions ~= partitions
		then
			return nil, "consumer-group registry entry is malformed"
		end
		names[group.name] = true
		local position_keys = 0
		for key in pairs(group.positions) do
			if not integer_at_least(key, 1) or key > partitions then
				return nil, "consumer-group positions array is not dense"
			end
			position_keys += 1
		end
		if position_keys ~= partitions then
			return nil, "consumer-group positions array is not dense"
		end
		for partition = 1, partitions do
			local position = group.positions[partition]
			if type(position) ~= "table" or not safe_integer(position.segment, 1)
				or not safe_integer(position.offset, 1)
			then
				return nil, "consumer-group start position is malformed"
			end
		end
	end
	return value :: GroupRegistry, nil
end

local function copy_group_registry(registry: GroupRegistry): GroupRegistry
	return {
		format = registry.format,
		stream = registry.stream,
		groups = table.clone(registry.groups),
		floors = table.clone(registry.floors),
		lease_owner = registry.lease_owner,
		lease_generation = registry.lease_generation,
		lease_until = registry.lease_until,
	}
end

local function find_consumer_group(registry: GroupRegistry, name: string): ConsumerGroup?
	for _, group in ipairs(registry.groups) do
		if group.name == name then
			return group
		end
	end
	return nil
end

function DurableStreams.new(data_store: any, raw_options: any?): any
	if data_store == nil or type(data_store.GetAsync) ~= "function" or type(data_store.UpdateAsync) ~= "function"
		or type(data_store.RemoveAsync) ~= "function"
	then
		return nil, "a DataStore with GetAsync, UpdateAsync, and RemoveAsync is required"
	end
	if raw_options ~= nil and type(raw_options) ~= "table" then
		return nil, "options must be a table"
	end
	local options = raw_options or {}
	local max_payload_bytes = options.max_payload_bytes or 8192
	local max_segment_messages = options.max_segment_messages or 24
	local max_segment_bytes = options.max_segment_bytes or 131072
	local max_batch_messages = options.max_batch_messages or 16
	local max_retained_segments = options.max_retained_segments or 32
	local min_segment_age_seconds = options.min_segment_age_seconds or 0
	local max_segment_age_seconds = options.max_segment_age_seconds
	local now = options.now or os.time
	if not integer_at_least(max_payload_bytes, 128) or max_payload_bytes > MAX_PAYLOAD_BYTES then
		return nil, "max_payload_bytes must be 128..32768"
	end
	if not integer_at_least(max_segment_messages, 1) or max_segment_messages > MAX_SEGMENT_MESSAGES then
		return nil, "max_segment_messages must be 1..64"
	end
	if not integer_at_least(max_segment_bytes, max_payload_bytes + MAX_EVENT_ID_BYTES + 64)
		or max_segment_bytes > MAX_SEGMENT_BYTES
	then
		return nil, "max_segment_bytes is outside the supported bounds"
	end
	if not integer_at_least(max_batch_messages, 1) or max_batch_messages > MAX_BATCH_MESSAGES
		or max_batch_messages > max_segment_messages
	then
		return nil, "max_batch_messages must be 1..min(32, max_segment_messages)"
	end
	if not integer_at_least(max_retained_segments, 2) or max_retained_segments > 128 then
		return nil, "max_retained_segments must be 2..128"
	end
	if not safe_integer(min_segment_age_seconds, 0) then
		return nil, "min_segment_age_seconds must be a non-negative safe integer"
	end
	if max_segment_age_seconds ~= nil and (not safe_integer(max_segment_age_seconds, min_segment_age_seconds) or max_segment_age_seconds == 0) then
		return nil, "max_segment_age_seconds must be nil or a positive safe integer not smaller than the minimum age"
	end
	if type(now) ~= "function" then
		return nil, "now must be a function"
	end
	local get_options = Instance.new("DataStoreGetOptions") :: DataStoreGetOptions
	get_options.UseCache = false
	local config: StreamOptions = {
		max_segment_messages = max_segment_messages,
		max_segment_bytes = max_segment_bytes,
		max_payload_bytes = max_payload_bytes,
		max_batch_messages = max_batch_messages,
		max_retained_segments = max_retained_segments,
		min_segment_age_seconds = min_segment_age_seconds,
		max_segment_age_seconds = max_segment_age_seconds,
		now = now,
	}
	local client: any = {
		_store = data_store,
		_options = config,
		_get_options = get_options,
	}
	function client:OpenStreamAsync(name: string, partitions: number): any
		if not valid_text(name, MAX_STREAM_NAME_BYTES) then
			return nil, "stream name must be 1..96 bytes"
		end
		if not integer_at_least(partitions, 1) or partitions > MAX_PARTITIONS then
			return nil, "partitions must be 1..32"
		end
		local hash = SHA256.digest(name):sub(1, 28)
		local key = manifest_key(hash)
		local existing, read_error = datastore_get(self._store, key, self._get_options)
		if read_error ~= nil then
			return nil, "manifest_read_failed: " .. read_error
		end
		local expected = {
			format = 3,
			stream = name,
			partitions = partitions,
			max_segment_messages = self._options.max_segment_messages,
			max_segment_bytes = self._options.max_segment_bytes,
			max_payload_bytes = self._options.max_payload_bytes,
			max_batch_messages = self._options.max_batch_messages,
			max_retained_segments = self._options.max_retained_segments,
			min_segment_age_seconds = self._options.min_segment_age_seconds,
			max_segment_age_seconds = self._options.max_segment_age_seconds,
		}
		if existing == nil then
			local created, write_error = datastore_update(self._store, key, function(current)
				if current == nil then
					return expected
				end
				return nil
			end)
			if write_error ~= nil then
				existing, read_error = datastore_get(self._store, key, self._get_options)
				if read_error ~= nil then
					return nil, "manifest_outcome_unknown: " .. write_error
				end
			elseif created ~= nil then
				existing = created
			else
				existing, read_error = datastore_get(self._store, key, self._get_options)
				if read_error ~= nil then
					return nil, "manifest_read_failed: " .. read_error
				end
			end
		end
		if type(existing) ~= "table" or existing.format ~= 3 or existing.stream ~= name then
			return nil, "manifest_corrupt_or_unsupported"
		end
		for field, value in pairs(expected) do
			if existing[field] ~= value then
				return nil, "stream_configuration_conflict: " .. tostring(field)
			end
		end
		local stream: any = setmetatable({
			_store = self._store,
			_name = name,
			_hash = hash,
			_partitions = partitions,
			_options = self._options,
			_get_options = self._get_options,
			_heads = {},
			_claims = setmetatable({}, { __mode = "k" }),
			_busy = {},
		}, Stream)
		return stream, nil
	end
	return client, nil
end

function Stream.GetPartition(self: StreamType, route_key: string): number
	if not valid_text(route_key, MAX_ROUTE_KEY_BYTES) then
		error("route_key must be 1..128 bytes", 2)
	end
	local hash = SHA256.digest(self._name .. "\0" .. route_key):sub(1, 8)
	local value = tonumber(hash, 16) :: number
	return value % self._partitions + 1
end

function Stream._ReadHead(self: StreamType, partition: number): (Head?, string?)
	self._heads[partition] = nil
	local key = head_key(self._hash, partition)
	local value, read_error = datastore_get(self._store, key, self._get_options)
	if read_error ~= nil then
		return nil, "head_read_failed: " .. read_error
	end
	if value == nil then
		local created, write_error = datastore_update(self._store, key, function(current)
			if current == nil then
				return {
					format = 3,
					stream = self._name,
					partition = partition,
					active_segment = 1,
					next_sequence = 1,
					retained_segment = 1,
					retained_sequence = 1,
					cleanup_segment = 1,
					retention_generation = 0,
					producer_states = {},
					producer_integrity = producer_state_digest({}),
				}
			end
			return nil
		end)
		if write_error ~= nil then
			value, read_error = datastore_get(self._store, key, self._get_options)
			if read_error ~= nil then
				return nil, "head_outcome_unknown: " .. write_error
			end
		elseif created ~= nil then
			value = created
		else
			value, read_error = datastore_get(self._store, key, self._get_options)
			if read_error ~= nil then
				return nil, "head_read_failed: " .. read_error
			end
		end
	end
	local head, validation_error = validate_head(value, self._name, partition)
	if head == nil then
		return nil, "head_corrupt: " .. tostring(validation_error)
	end
	self._heads[partition] = head
	return head, nil
end

function Stream._RefreshHead(self: StreamType, partition: number): (Head?, string?)
	return self:_ReadHead(partition)
end

function Stream._ReadSegment(self: StreamType, partition: number, segment_id: number): (Segment?, string?)
	local key = segment_key(self._hash, partition, segment_id)
	local value, read_error = datastore_get(self._store, key, self._get_options)
	if read_error ~= nil then
		return nil, "segment_read_failed: " .. read_error
	end
	if value == nil then
		return nil, nil
	end
	local segment, validation_error = validate_segment(value, self._name, partition, segment_id, self._options)
	if segment == nil then
		return nil, "segment_corrupt: " .. tostring(validation_error)
	end
	return segment, nil
end

function Stream._AdvanceHead(self: StreamType, partition: number, segment: Segment): (boolean, string?)
	if segment.segment >= MAX_SAFE_INTEGER or segment.last_sequence >= MAX_SAFE_INTEGER then
		return false, "capacity: partition sequence space is exhausted"
	end
	local key = head_key(self._hash, partition)
	local updated, write_error = datastore_update(self._store, key, function(raw)
		local current, validation_error = validate_head(raw, self._name, partition)
		if current == nil then
			error("head corrupt during rollover: " .. tostring(validation_error), 0)
		end
		if current.active_segment > segment.segment then
			return nil
		end
		if current.active_segment ~= segment.segment or current.next_sequence ~= segment.first_sequence then
			error("head and sealed segment disagree", 0)
		end
		if current.cleanup_segment < current.retained_segment
			or current.active_segment - current.retained_segment + 1 >= self._options.max_retained_segments
		then
			return nil
		end
		local next_head = copy_head(current)
		next_head.active_segment = segment.segment + 1
		next_head.next_sequence = segment.last_sequence + 1
		next_head.producer_states = table.clone(segment.producer_states)
		next_head.producer_integrity = producer_state_digest(next_head.producer_states)
		return next_head
	end)
	if write_error ~= nil then
		local refreshed, refresh_error = self:_RefreshHead(partition)
		if refreshed ~= nil and refreshed.active_segment > segment.segment then
			return true, nil
		end
		return false, "rollover_outcome_unknown: " .. tostring(refresh_error or write_error)
	end
	if updated ~= nil then
		local head, validation_error = validate_head(updated, self._name, partition)
		if head == nil then
			return false, "rollover_corrupt: " .. tostring(validation_error)
		end
		self._heads[partition] = head
		return true, nil
	end
	local refreshed, refresh_error = self:_RefreshHead(partition)
	if refreshed ~= nil and refreshed.active_segment > segment.segment then
		return true, nil
	end
	if refreshed ~= nil and refreshed.active_segment == segment.segment then
		if refreshed.cleanup_segment < refreshed.retained_segment then
			return false, "capacity: sealed segment cleanup is still pending"
		end
		if refreshed.active_segment - refreshed.retained_segment + 1 >= self._options.max_retained_segments then
			return false, "capacity: retained segment limit reached"
		end
	end
	return false, "rollover_not_confirmed: " .. tostring(refresh_error)
end

function Stream._ReadGroupRegistry(self: StreamType): (GroupRegistry?, string?)
	local value, read_error = datastore_get(self._store, group_registry_key(self._hash), self._get_options)
	if read_error ~= nil then
		return nil, "consumer_group_registry_read_failed: " .. read_error
	end
	if value == nil then
		return nil, nil
	end
	local registry, validation_error = validate_group_registry(value, self._name, self._partitions)
	if registry == nil then
		return nil, "consumer_group_registry_corrupt: " .. tostring(validation_error)
	end
	return registry, nil
end

function Stream._AcquireMaintenanceLease(self: StreamType): (MaintenanceLease?, string?)
	local now = self._options.now()
	if not safe_integer(now, 0) or now > MAX_SAFE_INTEGER - MAX_MAINTENANCE_LEASE_SECONDS then
		return nil, "clock is outside the safe maintenance-lease range"
	end
	local owner = SHA256.digest(self._name .. "\0" .. tostring(now) .. "\0" .. tostring({})):sub(1, 32)
	local key = group_registry_key(self._hash)
	local updated, update_error = datastore_update(self._store, key, function(raw)
		local current: GroupRegistry
		if raw == nil then
			local floors = table.create(self._partitions)
			for partition = 1, self._partitions do
				floors[partition] = { segment = 1, sequence = 1 }
			end
			current = {
				format = 3,
				stream = self._name,
				groups = {},
				floors = floors,
				lease_owner = nil,
				lease_generation = 0,
				lease_until = 0,
			}
		else
			local valid, validation_error = validate_group_registry(raw, self._name, self._partitions)
			if valid == nil then
				error("consumer-group registry corrupt during maintenance lease: " .. tostring(validation_error), 0)
			end
			current = valid
		end
		if current.lease_owner ~= nil and current.lease_owner ~= owner and current.lease_until > now then
			return nil
		end
		if current.lease_generation >= MAX_SAFE_INTEGER then
			return nil
		end
		local next_registry = copy_group_registry(current)
		next_registry.lease_owner = owner
		next_registry.lease_generation += 1
		next_registry.lease_until = now + MAX_MAINTENANCE_LEASE_SECONDS
		return next_registry
	end)
	if updated == nil or update_error ~= nil then
		local observed, read_error = datastore_get(self._store, key, self._get_options)
		if read_error ~= nil then
			return nil, "maintenance_lease_outcome_unknown: " .. tostring(update_error or "lease not returned") .. "; " .. read_error
		end
		local registry, validation_error = validate_group_registry(observed, self._name, self._partitions)
		if registry == nil then
			return nil, update_error or validation_error or "consumer-group registry is missing"
		end
		if registry.lease_owner == owner and registry.lease_until > now then
			return {
				owner = owner,
				generation = registry.lease_generation,
				lease_until = registry.lease_until,
			}, nil
		end
		if registry.lease_owner ~= nil and registry.lease_until > now then
			return nil, "maintenance_busy"
		end
		return nil, "maintenance_lease_outcome_unknown: " .. tostring(update_error or "lease was not acquired")
	end
	local registry, validation_error = validate_group_registry(updated, self._name, self._partitions)
	if registry == nil then
		return nil, "maintenance_lease_corrupt: " .. tostring(validation_error)
	end
	if registry.lease_owner ~= owner then
		return nil, "maintenance_busy"
	end
	return {
		owner = owner,
		generation = registry.lease_generation,
		lease_until = registry.lease_until,
	}, nil
end

function Stream._ReleaseMaintenanceLease(self: StreamType, lease: MaintenanceLease): boolean
	local key = group_registry_key(self._hash)
	local updated = datastore_update(self._store, key, function(raw)
		local current, validation_error = validate_group_registry(raw, self._name, self._partitions)
		if current == nil then
			error("consumer-group registry corrupt during lease release: " .. tostring(validation_error), 0)
		end
		if current.lease_owner ~= lease.owner or current.lease_generation ~= lease.generation then
			return nil
		end
		local next_registry = copy_group_registry(current)
		next_registry.lease_owner = nil
		next_registry.lease_until = 0
		return next_registry
	end)
	if updated ~= nil then
		return true
	end
	local observed = self:_ReadGroupRegistry()
	if observed ~= nil and observed.lease_owner == nil and observed.lease_generation == lease.generation then
		return true
	end
	return false
end

function Stream._FenceRetentionGeneration(self: StreamType, lease: MaintenanceLease): (boolean, string?)
	for partition = 1, self._partitions do
		local head, head_error = self:_ReadHead(partition)
		if head == nil then
			return false, head_error
		end
		if head.retention_generation > lease.generation then
			return false, "maintenance_fenced"
		end
		if head.retention_generation < lease.generation then
			local key = head_key(self._hash, partition)
			local updated, update_error = datastore_update(self._store, key, function(raw)
				local current, validation_error = validate_head(raw, self._name, partition)
				if current == nil then
					error("head corrupt while fencing retention generation: " .. tostring(validation_error), 0)
				end
				if current.retention_generation >= lease.generation then
					return nil
				end
				local next_head = copy_head(current)
				next_head.retention_generation = lease.generation
				return next_head
			end)
			if update_error ~= nil or updated == nil then
				local refreshed, refresh_error = self:_RefreshHead(partition)
				if refreshed == nil or refreshed.retention_generation ~= lease.generation then
					return false, "retention_generation_fence_unknown: " .. tostring(refresh_error or update_error)
				end
				head = refreshed
			else
				local validated, validation_error = validate_head(updated, self._name, partition)
				if validated == nil then
					return false, "retention_generation_fence_corrupt: " .. tostring(validation_error)
				end
				head = validated
			end
		end
		self._heads[partition] = head
	end
	return true, nil
end

local function find_event(segment: Segment, event_id: string): Message?
	for _, message in ipairs(segment.messages) do
		if message.event_id == event_id then
			return message
		end
	end
	return nil
end

local function is_capacity_error(message: any): boolean
	return type(message) == "string" and string.sub(message, 1, 9) == "capacity:"
end

local function prepare_events(events: any, options: StreamOptions): ({ any }?, string?)
	if type(events) ~= "table" then
		return nil, "events must be a dense array"
	end
	local count = #events
	if count < 1 or count > options.max_batch_messages then
		return nil, "batch size is outside the configured bound"
	end
	local key_count = 0
	for key in pairs(events) do
		if not integer_at_least(key, 1) or key > count then
			return nil, "events must be a dense array"
		end
		key_count += 1
	end
	if key_count ~= count then
		return nil, "events must be a dense array"
	end
	local prepared = table.create(count)
	local event_ids: { [string]: boolean } = {}
	local total_bytes = 0
	for index = 1, count do
		local item = events[index]
		if type(item) ~= "table" or getmetatable(item) ~= nil or not valid_text(item.event_id, MAX_EVENT_ID_BYTES) then
			return nil, "each event requires an event_id of 1..128 bytes"
		end
		if event_ids[item.event_id] then
			return nil, "event_id values must be unique within a batch"
		end
		event_ids[item.event_id] = true
		local payload, canonical, payload_bytes, payload_error = normalize_payload(item.payload, options.max_payload_bytes, true)
		if payload_error ~= nil or payload == nil or canonical == nil or payload_bytes == nil then
			return nil, payload_error or "event payload is invalid"
		end
		local entry_bytes = #item.event_id + payload_bytes + 64
		total_bytes += entry_bytes
		prepared[index] = {
			event_id = item.event_id,
			payload = payload,
			payload_digest = SHA256.digest(canonical),
			payload_bytes = entry_bytes,
			created_at = 0,
		}
	end
	if total_bytes > options.max_segment_bytes then
		return nil, "batch cannot fit in one segment"
	end
	return prepared, nil
end

local function resolve_batch(segment: Segment, prepared: { any }): (boolean, number, { any }?, string?)
	local results = table.create(#prepared)
	local found_count = 0
	for index, event in ipairs(prepared) do
		local existing = find_event(segment, event.event_id)
		if existing == nil then
			results[index] = nil
		else
			if existing.payload_digest ~= event.payload_digest then
				return false, 0, nil, "event_id already exists with different content"
			end
			found_count += 1
			results[index] = {
				event_id = existing.event_id,
				sequence = existing.sequence,
				segment = segment.segment,
			}
		end
	end
	if found_count == #prepared then
		return true, found_count, results, nil
	end
	return false, found_count, results, nil
end

function Stream.PublishBatchAsync(self: StreamType, route_key: string, events: { any }): any
	if not valid_text(route_key, MAX_ROUTE_KEY_BYTES) then
		return { code = "invalid", message = "route_key must be 1..128 bytes" }
	end
	local prepared, prepare_error = prepare_events(events, self._options)
	if prepared == nil then
		return { code = "invalid", message = prepare_error }
	end
	local now = self._options.now()
	if not safe_integer(now, 0) then
		return { code = "invalid", message = "clock must return a non-negative safe integer timestamp" }
	end
	for _, event in ipairs(prepared) do
		event.created_at = now
	end
	local partition = self:GetPartition(route_key)
	for _ = 1, 4 do
		local head, head_error = self:_ReadHead(partition)
		if head == nil then
			return { code = "unknown", message = head_error, partition = partition }
		end
		if head.active_segment >= MAX_SAFE_INTEGER or head.next_sequence >= MAX_SAFE_INTEGER then
			return { code = "capacity", message = "partition sequence space is exhausted", partition = partition }
		end
		local key = segment_key(self._hash, partition, head.active_segment)
		local updated, update_error = datastore_update(self._store, key, function(raw)
			local current: Segment
			if raw == nil then
				current = new_segment(self._name, partition, head.active_segment, head.next_sequence, now)
			else
				local valid, validation_error = validate_segment(raw, self._name, partition, head.active_segment, self._options)
				if valid == nil then
					error("segment corrupt during append: " .. tostring(validation_error), 0)
				end
				current = valid
			end
			if current.sealed then
				return nil
			end
			local missing = table.create(#prepared)
			local missing_count = 0
			local missing_bytes = 0
			for _, event in ipairs(prepared) do
				local existing = find_event(current, event.event_id)
				if existing ~= nil then
					if existing.payload_digest ~= event.payload_digest then
						error("EVENT_ID_CONFLICT", 0)
					end
				else
					missing_count += 1
					missing_bytes += event.payload_bytes
					missing[missing_count] = event
				end
			end
			if missing_count == 0 then
				return nil
			end
			if #current.messages + missing_count > self._options.max_segment_messages
				or current.bytes + missing_bytes > self._options.max_segment_bytes
			then
				local sealed = table.clone(current)
				sealed.sealed = true
				sealed.integrity = segment_integrity(sealed.chain_integrity, true)
				return sealed
			end
			local messages = table.clone(current.messages)
			local chain = current.chain_integrity
			local sequence = current.last_sequence
			for index = 1, missing_count do
				local event = missing[index]
				sequence += 1
				local message: Message = {
					sequence = sequence,
					event_id = event.event_id,
					payload = event.payload,
					payload_digest = event.payload_digest,
					payload_bytes = event.payload_bytes,
					created_at = event.created_at,
				}
				messages[#messages + 1] = message
				chain = next_integrity(chain, message)
			end
			local new_bytes = current.bytes + missing_bytes
			local sealed = #messages >= self._options.max_segment_messages
				or new_bytes >= self._options.max_segment_bytes
			return {
				format = 3,
				stream = self._name,
				partition = partition,
				segment = head.active_segment,
				created_at = current.created_at,
				first_sequence = current.first_sequence,
				last_sequence = sequence,
				bytes = new_bytes,
				sealed = sealed,
				chain_integrity = chain,
				integrity = segment_integrity(chain, sealed),
				messages = messages,
			}
		end)
		if update_error ~= nil then
			local segment, read_error = self:_ReadSegment(partition, head.active_segment)
			if segment ~= nil then
				local all_found, _, results, conflict_error = resolve_batch(segment, prepared)
				if conflict_error ~= nil then
					return { code = "conflict", message = conflict_error, partition = partition }
				end
				if all_found then
					if segment.sealed then
						self:_AdvanceHead(partition, segment)
					end
					return {
						code = "committed",
						duplicate = true,
						reconciled = true,
						count = #prepared,
						items = results,
						partition = partition,
						segment = segment.segment,
					}
				end
				if segment.sealed then
					local advanced, advance_error = self:_AdvanceHead(partition, segment)
					if advanced then
						continue
					end
					return { code = if is_capacity_error(advance_error) then "capacity" else "unknown", message = advance_error, partition = partition }
				end
			else
				local refreshed, refresh_error = self:_RefreshHead(partition)
				if refreshed ~= nil and refreshed.active_segment > head.active_segment then
					continue
				end
				return {
					code = "unknown",
					message = "append outcome could not be proven: " .. tostring(read_error or update_error or refresh_error),
					partition = partition,
					segment = head.active_segment,
				}
			end
			return {
				code = "unknown",
				message = "append outcome could not be proven: " .. tostring(update_error),
				partition = partition,
				segment = head.active_segment,
			}
		end
		if updated ~= nil then
			local segment, validation_error = validate_segment(updated, self._name, partition, head.active_segment, self._options)
			if segment == nil then
				return { code = "corrupt", message = validation_error, partition = partition }
			end
			local all_found, _, results, conflict_error = resolve_batch(segment, prepared)
			if conflict_error ~= nil then
				return { code = "conflict", message = conflict_error, partition = partition }
			end
			if not all_found or results == nil then
				if segment.sealed then
					local advanced, advance_error = self:_AdvanceHead(partition, segment)
					if advanced then
						continue
					end
					return { code = if is_capacity_error(advance_error) then "capacity" else "retryable", message = advance_error, partition = partition }
				end
				return { code = "unknown", message = "append committed without all requested events", partition = partition }
			end
			if segment.sealed then
				local advanced = self:_AdvanceHead(partition, segment)
				return {
					code = "committed",
					partition = partition,
					segment = segment.segment,
					count = #prepared,
					items = results,
					rollover_pending = not advanced,
				}
			end
			return {
				code = "committed",
				partition = partition,
				segment = segment.segment,
				count = #prepared,
				items = results,
			}
		end
		local segment, read_error = self:_ReadSegment(partition, head.active_segment)
		if segment == nil then
			local refreshed, refresh_error = self:_RefreshHead(partition)
			if refreshed ~= nil and refreshed.active_segment > head.active_segment then
				continue
			end
			return { code = "unknown", message = read_error or refresh_error or "append was not observable", partition = partition }
		end
		local all_found, _, results, conflict_error = resolve_batch(segment, prepared)
		if conflict_error ~= nil then
			return { code = "conflict", message = conflict_error, partition = partition }
		end
		if all_found then
			return {
				code = "committed",
				duplicate = true,
				partition = partition,
				segment = segment.segment,
				count = #prepared,
				items = results,
			}
		end
		if segment.sealed then
			local advanced, advance_error = self:_AdvanceHead(partition, segment)
			if advanced then
				continue
			end
			return { code = if is_capacity_error(advance_error) then "capacity" else "retryable", message = advance_error, partition = partition }
		end
		return { code = "unknown", message = "append did not produce a verifiable batch", partition = partition }
	end
	return { code = "retryable", message = "partition rollover retry limit reached", partition = partition }
end

function Stream.PublishAsync(self: StreamType, route_key: string, event_id: string, payload: any): any
	local result = self:PublishBatchAsync(route_key, { { event_id = event_id, payload = payload } })
	if result.code ~= "committed" then
		return result
	end
	local first = result.items and result.items[1]
	return {
		code = "committed",
		duplicate = result.duplicate,
		reconciled = result.reconciled,
		partition = result.partition,
		segment = first and first.segment or result.segment,
		sequence = first and first.sequence,
		rollover_pending = result.rollover_pending,
	}
end

local function validate_lease_seconds(value: any): boolean
	return integer_at_least(value, MIN_LEASE_SECONDS) and value <= MAX_LEASE_SECONDS
end

local function claim_result(self: StreamType, record: CursorRecord, group: string, partition: number, owner_token: string, lease_seconds: number): any
	local claim_key = group .. "\0" .. tostring(partition)
	local claim: any = table.freeze({})
	self._claims[claim] = {
		group = group,
		partition = partition,
		owner_token = owner_token,
		generation = record.generation,
		segment = record.segment,
		offset = record.offset,
		lease_until = record.lease_until,
		lease_seconds = lease_seconds,
		cursor_key = cursor_key(self._hash, group, partition),
		claim_key = claim_key,
		released = false,
	}
	return { code = "claimed", claim = claim, generation = record.generation, position = { segment = record.segment, offset = record.offset } }
end

local function same_group_configuration(
	group: ConsumerGroup,
	start_mode: string,
	retention_protected: boolean,
	explicit_segment: number?,
	explicit_offset: number?
): boolean
	return group.start_mode == start_mode
		and group.retention_protected == retention_protected
		and group.explicit_segment == explicit_segment
		and group.explicit_offset == explicit_offset
end

function Stream.RegisterConsumerGroupAsync(self: StreamType, group: string, start_position: any, retention_protected: boolean?): any
	if not valid_text(group, MAX_GROUP_NAME_BYTES) then
		return { code = "invalid", message = "group must be 1..96 bytes" }
	end
	local protected = if retention_protected == nil then true else retention_protected
	if type(protected) ~= "boolean" then
		return { code = "invalid", message = "retention_protected must be a boolean" }
	end
	local start_mode: string
	local explicit_segment: number? = nil
	local explicit_offset: number? = nil
	if start_position == nil or start_position == "earliest" then
		start_mode = "earliest"
	elseif start_position == "latest" then
		start_mode = "latest"
	elseif type(start_position) == "table"
		and safe_integer(start_position.segment, 1)
		and safe_integer(start_position.offset, 1)
	then
		start_mode = "position"
		explicit_segment = start_position.segment
		explicit_offset = start_position.offset
	else
		return { code = "invalid", message = "start_position must be earliest, latest, or { segment, offset }" }
	end

	local lease, lease_error = self:_AcquireMaintenanceLease()
	if lease == nil then
		return { code = if lease_error == "maintenance_busy" then "busy" else "unknown", message = lease_error }
	end
	local function finish(result: any): any
		self:_ReleaseMaintenanceLease(lease)
		return result
	end
	local fenced, fence_error = self:_FenceRetentionGeneration(lease)
	if not fenced then
		return finish({ code = "fenced", message = fence_error })
	end
	local registry, registry_error = self:_ReadGroupRegistry()
	if registry_error ~= nil or registry == nil then
		return finish({ code = "unknown", message = registry_error or "consumer-group registry disappeared" })
	end
	local existing = find_consumer_group(registry, group)
	if existing ~= nil then
		if existing.removing then
			return finish({ code = "removed", message = "consumer group removal is in progress" })
		end
		if same_group_configuration(existing, start_mode, protected, explicit_segment, explicit_offset) then
			return finish({ code = "exists" })
		end
		return finish({ code = "conflict", message = "consumer group already exists with a different start or retention policy" })
	end
	if #registry.groups >= MAX_CONSUMER_GROUPS then
		return finish({ code = "capacity", message = "stream consumer-group limit reached" })
	end

	local positions = table.create(self._partitions)
	for partition = 1, self._partitions do
		local head, head_error = self:_RefreshHead(partition)
		if head == nil then
			return finish({ code = "unknown", message = head_error })
		end
		local position: GroupPosition
		if start_mode == "earliest" then
			local floor = registry.floors[partition]
			position = { segment = floor.segment, offset = 1 }
		elseif start_mode == "latest" then
			local active, segment_error = self:_ReadSegment(partition, head.active_segment)
			if segment_error ~= nil then
				return finish({ code = "unknown", message = segment_error })
			end
			if active == nil then
				position = { segment = head.active_segment, offset = 1 }
			elseif active.sealed then
				position = { segment = head.active_segment + 1, offset = 1 }
			else
				position = { segment = head.active_segment, offset = #active.messages + 1 }
			end
		else
			position = { segment = explicit_segment :: number, offset = explicit_offset :: number }
			if position.segment < registry.floors[partition].segment then
				return finish({
					code = "expired",
					message = "explicit start position is below the retained floor",
					partition = partition,
					earliest_segment = registry.floors[partition].segment,
					earliest_sequence = registry.floors[partition].sequence,
				})
			end
			if position.segment > head.active_segment + 1 then
				return finish({ code = "invalid", message = "explicit start position is ahead of the partition head", partition = partition })
			end
			if position.segment == head.active_segment + 1 then
				local active, segment_error = self:_ReadSegment(partition, head.active_segment)
				if segment_error ~= nil or active == nil or not active.sealed or position.offset ~= 1 then
					return finish({ code = "invalid", message = "next-segment start requires a sealed active segment and offset 1", partition = partition })
				end
			else
				local selected, segment_error = self:_ReadSegment(partition, position.segment)
				if segment_error ~= nil then
					return finish({ code = "corrupt", message = segment_error, partition = partition })
				end
				if selected == nil then
					if position.segment ~= head.active_segment or position.offset ~= 1 then
						return finish({ code = "invalid", message = "explicit start segment does not exist", partition = partition })
					end
				elseif position.offset > #selected.messages + 1 then
					return finish({ code = "invalid", message = "explicit start offset exceeds the segment", partition = partition })
				end
			end
		end
		positions[partition] = position
	end

	local key = group_registry_key(self._hash)
	local updated, update_error = datastore_update(self._store, key, function(raw)
		local current, validation_error = validate_group_registry(raw, self._name, self._partitions)
		if current == nil then
			error("consumer-group registry corrupt during registration: " .. tostring(validation_error), 0)
		end
		if current.lease_owner ~= lease.owner or current.lease_generation ~= lease.generation or current.lease_until <= self._options.now() then
			return nil
		end
		if find_consumer_group(current, group) ~= nil then
			return nil
		end
		if #current.groups >= MAX_CONSUMER_GROUPS then
			return nil
		end
		local next_registry = copy_group_registry(current)
		local next_groups = table.clone(current.groups)
		table.insert(next_groups, {
			name = group,
			retention_protected = protected,
			removing = false,
			start_mode = start_mode,
			explicit_segment = explicit_segment,
			explicit_offset = explicit_offset,
			positions = positions,
		})
		next_registry.groups = next_groups
		return next_registry
	end)
	if update_error ~= nil or updated == nil then
		local observed, read_error = self:_ReadGroupRegistry()
		if observed ~= nil then
			local found = find_consumer_group(observed, group)
			if found ~= nil and same_group_configuration(found, start_mode, protected, explicit_segment, explicit_offset) then
				return finish({ code = "registered", reconciled = true })
			end
		end
		return finish({ code = "unknown", message = tostring(update_error or "registration was not committed") .. (read_error and "; " .. read_error or "") })
	end
	return finish({ code = "registered" })
end

local function update_cursor_for_group_removal(self: StreamType, group: string, partition: number): (boolean, string?)
	local key = cursor_key(self._hash, group, partition)
	local updated, update_error = datastore_update(self._store, key, function(raw)
		if raw == nil then
			return nil
		end
		local current, validation_error = validate_cursor(raw, self._name, group, partition)
		if current == nil then
			error("consumer cursor corrupt during group removal: " .. tostring(validation_error), 0)
		end
		if current.generation >= MAX_SAFE_INTEGER then
			error("consumer cursor fencing generation is exhausted", 0)
		end
		local next_record = copy_cursor(current)
		next_record.generation += 1
		next_record.owner_token = nil
		next_record.lease_until = 0
		return next_record
	end)
	if update_error ~= nil then
		return false, update_error
	end
	if updated == nil then
		local observed, read_error = datastore_get(self._store, key, self._get_options)
		if read_error ~= nil then
			return false, read_error
		end
		if observed == nil then
			return true, nil
		end
		local current, validation_error = validate_cursor(observed, self._name, group, partition)
		if current == nil then
			return false, validation_error
		end
		if current.owner_token == nil then
			return true, nil
		end
		return false, "cursor invalidation was not confirmed"
	end
	return true, nil
end

function Stream.RemoveConsumerGroupAsync(self: StreamType, group: string, confirm: boolean): any
	if not valid_text(group, MAX_GROUP_NAME_BYTES) then
		return { code = "invalid", message = "group must be 1..96 bytes" }
	end
	if confirm ~= true then
		return { code = "invalid", message = "confirm=true is required because group removal is destructive" }
	end
	local lease, lease_error = self:_AcquireMaintenanceLease()
	if lease == nil then
		return { code = if lease_error == "maintenance_busy" then "busy" else "unknown", message = lease_error }
	end
	local function finish(result: any): any
		self:_ReleaseMaintenanceLease(lease)
		return result
	end
	local fenced, fence_error = self:_FenceRetentionGeneration(lease)
	if not fenced then
		return finish({ code = "fenced", message = fence_error })
	end
	local registry, registry_error = self:_ReadGroupRegistry()
	if registry_error ~= nil or registry == nil then
		return finish({ code = "unknown", message = registry_error or "consumer-group registry is missing" })
	end
	local entry = find_consumer_group(registry, group)
	if entry == nil then
		return finish({ code = "not_found" })
	end
	local registry_key = group_registry_key(self._hash)
	if not entry.removing then
		local marked, mark_error = datastore_update(self._store, registry_key, function(raw)
			local current, validation_error = validate_group_registry(raw, self._name, self._partitions)
			if current == nil then
				error("consumer-group registry corrupt while marking removal: " .. tostring(validation_error), 0)
			end
			if current.lease_owner ~= lease.owner or current.lease_generation ~= lease.generation or current.lease_until <= self._options.now() then
				return nil
			end
			local next_registry = copy_group_registry(current)
			local next_groups = table.clone(current.groups)
			for index, candidate in ipairs(next_groups) do
				if candidate.name == group then
					local removing_entry = table.clone(candidate)
					removing_entry.removing = true
					next_groups[index] = removing_entry
					break
				end
			end
			next_registry.groups = next_groups
			return next_registry
		end)
		if mark_error ~= nil or marked == nil then
			local observed, read_error = self:_ReadGroupRegistry()
			local current_entry = observed and find_consumer_group(observed, group)
			if current_entry == nil or not current_entry.removing then
				return finish({ code = "unknown", message = mark_error or read_error or "group removal marker was not committed" })
			end
		end
	end
	for partition = 1, self._partitions do
		local invalidated, invalidate_error = update_cursor_for_group_removal(self, group, partition)
		if not invalidated then
			return finish({
				code = "cleanup_pending",
				message = invalidate_error,
				partition = partition,
				group_removing = true,
			})
		end
		local removed, remove_error = datastore_remove(self._store, cursor_key(self._hash, group, partition))
		if not removed then
			return finish({
				code = "cleanup_pending",
				message = remove_error,
				partition = partition,
				group_removing = true,
			})
		end
	end
	local updated, update_error = datastore_update(self._store, registry_key, function(raw)
		local current, validation_error = validate_group_registry(raw, self._name, self._partitions)
		if current == nil then
			error("consumer-group registry corrupt during final removal: " .. tostring(validation_error), 0)
		end
		if current.lease_owner ~= lease.owner or current.lease_generation ~= lease.generation or current.lease_until <= self._options.now() then
			return nil
		end
		local next_groups = table.create(math.max(0, #current.groups - 1))
		for _, candidate in ipairs(current.groups) do
			if candidate.name ~= group then
				next_groups[#next_groups + 1] = candidate
			end
		end
		local next_registry = copy_group_registry(current)
		next_registry.groups = next_groups
		return next_registry
	end)
	if update_error ~= nil or updated == nil then
		local observed, read_error = self:_ReadGroupRegistry()
		if read_error ~= nil or observed == nil or find_consumer_group(observed, group) ~= nil then
			return finish({ code = "unknown", message = update_error or read_error or "final group removal was not confirmed" })
		end
	end
	return finish({ code = "removed", cleanup_pending = false })
end

function Stream._DeleteBelowRetentionFloor(self: StreamType, partition: number, lease: MaintenanceLease, limit: number): (number, string?)
	local removed = 0
	while removed < limit do
		local registry, registry_error = self:_ReadGroupRegistry()
		if registry_error ~= nil or registry == nil then
			return removed, registry_error or "consumer-group registry is missing"
		end
		local floor = registry.floors[partition]
		local head, head_error = self:_RefreshHead(partition)
		if head == nil then
			return removed, head_error
		end
		if head.cleanup_segment >= floor.segment then
			return removed, nil
		end
		local segment_id = head.cleanup_segment
		local ok, remove_error = datastore_remove(self._store, segment_key(self._hash, partition, segment_id))
		if not ok then
			return removed, "segment_remove_failed: " .. tostring(remove_error)
		end
		local key = head_key(self._hash, partition)
		local updated, update_error = datastore_update(self._store, key, function(raw)
			local current, validation_error = validate_head(raw, self._name, partition)
			if current == nil then
				error("head corrupt during segment cleanup: " .. tostring(validation_error), 0)
			end
			if current.cleanup_segment > segment_id then
				return nil
			end
			if current.cleanup_segment ~= segment_id then
				error("cleanup cursor moved backwards", 0)
			end
			local next_head = copy_head(current)
			next_head.cleanup_segment = segment_id + 1
			if next_head.retained_segment < floor.segment then
				next_head.retained_segment = floor.segment
				next_head.retained_sequence = floor.sequence
			end
			return next_head
		end)
		if update_error ~= nil or updated == nil then
			local refreshed, refresh_error = self:_RefreshHead(partition)
			if refreshed == nil or refreshed.cleanup_segment <= segment_id then
				return removed, "cleanup_cursor_outcome_unknown: " .. tostring(refresh_error or update_error)
			end
		else
			local checked, validation_error = validate_head(updated, self._name, partition)
			if checked == nil then
				return removed, "cleanup_cursor_corrupt: " .. tostring(validation_error)
			end
		end
		removed += 1
	end
	return removed, nil
end

local function sync_retention_head(
	self: StreamType,
	partition: number,
	floor: RetentionFloor,
	generation: number
): (boolean, string?)
	local key = head_key(self._hash, partition)
	local updated, update_error = datastore_update(self._store, key, function(raw)
		local current, validation_error = validate_head(raw, self._name, partition)
		if current == nil then
			error("head corrupt while syncing retention floor: " .. tostring(validation_error), 0)
		end
		if current.retention_generation > generation then
			return nil
		end
		if current.retained_segment >= floor.segment and current.retention_generation == generation then
			return nil
		end
		local next_head = copy_head(current)
		if next_head.retained_segment < floor.segment then
			next_head.retained_segment = floor.segment
			next_head.retained_sequence = floor.sequence
		end
		next_head.retention_generation = math.max(next_head.retention_generation, generation)
		return next_head
	end)
	if update_error ~= nil or updated == nil then
		local refreshed, refresh_error = self:_RefreshHead(partition)
		if refreshed ~= nil and refreshed.retained_segment >= floor.segment then
			return true, nil
		end
		return false, "retention_head_sync_unknown: " .. tostring(refresh_error or update_error)
	end
	local checked, validation_error = validate_head(updated, self._name, partition)
	if checked == nil then
		return false, "retention_head_sync_corrupt: " .. tostring(validation_error)
	end
	self._heads[partition] = checked
	return true, nil
end

local function advance_sealed_active_segment(self: StreamType, partition: number): (boolean, string?)
	local head, head_error = self:_RefreshHead(partition)
	if head == nil then
		return false, head_error
	end
	local segment, segment_error = self:_ReadSegment(partition, head.active_segment)
	if segment_error ~= nil then
		return false, segment_error
	end
	if segment == nil or not segment.sealed then
		return true, nil
	end
	return self:_AdvanceHead(partition, segment)
end

function Stream.PruneAsync(self: StreamType, partition: number, max_segments: number?): any
	if not integer_at_least(partition, 1) or partition > self._partitions then
		return { code = "invalid", message = "partition is outside this stream" }
	end
	local limit = max_segments or 4
	if not integer_at_least(limit, 1) or limit > 32 then
		return { code = "invalid", message = "max_segments must be 1..32" }
	end
	local now = self._options.now()
	if not safe_integer(now, 0) then
		return { code = "invalid", message = "clock must return a non-negative safe integer timestamp" }
	end
	local lease, lease_error = self:_AcquireMaintenanceLease()
	if lease == nil then
		return { code = if lease_error == "maintenance_busy" then "busy" else "unknown", message = lease_error }
	end
	local function finish(result: any): any
		self:_ReleaseMaintenanceLease(lease)
		return result
	end
	local fenced, fence_error = self:_FenceRetentionGeneration(lease)
	if not fenced then
		return finish({ code = "fenced", message = fence_error })
	end
	local registry, registry_error = self:_ReadGroupRegistry()
	if registry_error ~= nil or registry == nil then
		return finish({ code = "unknown", message = registry_error or "consumer-group registry is missing" })
	end
	local floor = registry.floors[partition]
	local synced, sync_error = sync_retention_head(self, partition, floor, lease.generation)
	if not synced then
		return finish({ code = "unknown", message = sync_error, retained_segment = floor.segment })
	end
	local removed, cleanup_error = self._DeleteBelowRetentionFloor(self, partition, lease, limit)
	if cleanup_error ~= nil then
		local current = self:_RefreshHead(partition)
		return finish({
			code = "unknown",
			message = cleanup_error,
			removed = removed,
			retained_segment = floor.segment,
			retained_sequence = floor.sequence,
			cleanup_pending = current ~= nil and current.cleanup_segment < floor.segment,
		})
	end
	if removed >= limit then
		local current = self:_RefreshHead(partition)
		return finish({
			code = "pruned",
			removed = removed,
			retained_segment = floor.segment,
			retained_sequence = floor.sequence,
			cleanup_pending = current ~= nil and current.cleanup_segment < floor.segment,
		})
	end
	local advanced_before_scan, advance_before_error = advance_sealed_active_segment(self, partition)
	if not advanced_before_scan and not is_capacity_error(advance_before_error) then
		return finish({ code = "unknown", message = advance_before_error, removed = removed })
	end

	local head, head_error = self:_RefreshHead(partition)
	if head == nil then
		return finish({ code = "unknown", message = head_error, removed = removed })
	end
	local protected_positions = {}
	for _, entry in ipairs(registry.groups) do
		if entry.retention_protected and not entry.removing then
			local key = cursor_key(self._hash, entry.name, partition)
			local raw, cursor_read_error = datastore_get(self._store, key, self._get_options)
			if cursor_read_error ~= nil then
				return finish({ code = "unknown", message = "consumer cursor read failed: " .. cursor_read_error, removed = removed })
			end
			if raw == nil then
				protected_positions[#protected_positions + 1] = {
					group = entry.name,
					segment = entry.positions[partition].segment,
				}
			else
				local cursor, cursor_error = validate_cursor(raw, self._name, entry.name, partition)
				if cursor == nil then
					return finish({ code = "corrupt", message = cursor_error, removed = removed })
				end
				protected_positions[#protected_positions + 1] = {
					group = entry.name,
					segment = cursor.segment,
				}
			end
		end
	end
	local target_segment = floor.segment
	local target_sequence = floor.sequence
	local candidate_count = 0
	local forced_expiry = false
	local blocked_reason = nil
	local remaining_limit = limit - removed
	while candidate_count < remaining_limit and target_segment < head.active_segment do
		local segment, segment_error = self:_ReadSegment(partition, target_segment)
		if segment_error ~= nil or segment == nil then
			return finish({ code = "corrupt", message = segment_error or "retained segment is missing", removed = removed })
		end
		if not segment.sealed then
			break
		end
		if now < segment.created_at then
			return finish({ code = "invalid", message = "clock is behind the stored segment creation time", removed = removed })
		end
		local age = now - segment.created_at
		local forced = self._options.max_segment_age_seconds ~= nil and age >= self._options.max_segment_age_seconds
		local old_enough = age >= self._options.min_segment_age_seconds
		local consumers_passed = true
		for _, position in ipairs(protected_positions) do
			if position.segment <= target_segment then
				consumers_passed = false
				break
			end
		end
		if not forced and (not old_enough or not consumers_passed) then
			blocked_reason = if not old_enough then "minimum_age" else "protected_consumer"
			break
		end
		if forced and not consumers_passed then
			forced_expiry = true
		end
		target_segment += 1
		target_sequence = segment.last_sequence + 1
		candidate_count += 1
	end
	if candidate_count == 0 then
		if blocked_reason ~= nil then
			return finish({
				code = "blocked",
				reason = blocked_reason,
				removed = removed,
				retained_segment = floor.segment,
				retained_sequence = floor.sequence,
			})
		end
		return finish({
			code = "idle",
			removed = removed,
			retained_segment = floor.segment,
			retained_sequence = floor.sequence,
		})
	end

	local registry_key = group_registry_key(self._hash)
	local updated, update_error = datastore_update(self._store, registry_key, function(raw)
		local current, validation_error = validate_group_registry(raw, self._name, self._partitions)
		if current == nil then
			error("consumer-group registry corrupt during retention floor advance: " .. tostring(validation_error), 0)
		end
		if current.lease_owner ~= lease.owner
			or current.lease_generation ~= lease.generation
			or current.lease_until <= self._options.now()
		then
			return nil
		end
		local live_floor = current.floors[partition]
		if live_floor.segment ~= floor.segment or live_floor.sequence ~= floor.sequence then
			return nil
		end
		local next_registry = copy_group_registry(current)
		local next_floors = table.clone(current.floors)
		next_floors[partition] = { segment = target_segment, sequence = target_sequence }
		next_registry.floors = next_floors
		return next_registry
	end)
	if update_error ~= nil or updated == nil then
		local observed, read_error = self:_ReadGroupRegistry()
		if observed == nil or observed.floors[partition].segment < target_segment then
			return finish({
				code = "unknown",
				message = "retention floor outcome unknown: " .. tostring(read_error or update_error),
				removed = removed,
			})
		end
		registry = observed
		floor = observed.floors[partition]
	else
		local checked, validation_error = validate_group_registry(updated, self._name, self._partitions)
		if checked == nil then
			return finish({ code = "corrupt", message = validation_error, removed = removed })
		end
		registry = checked
		floor = checked.floors[partition]
	end
	synced, sync_error = sync_retention_head(self, partition, floor, lease.generation)
	if not synced then
		return finish({ code = "unknown", message = sync_error, removed = removed, retained_segment = floor.segment, retained_sequence = floor.sequence })
	end
	local deleted, delete_error = self._DeleteBelowRetentionFloor(self, partition, lease, limit - removed)
	removed += deleted
	local advanced_after_prune, advance_after_error = advance_sealed_active_segment(self, partition)
	if not advanced_after_prune and not is_capacity_error(advance_after_error) then
		return finish({ code = "unknown", message = advance_after_error, removed = removed, retained_segment = floor.segment, retained_sequence = floor.sequence })
	end
	local refreshed = self:_RefreshHead(partition)
	if delete_error ~= nil then
		return finish({
			code = "unknown",
			message = delete_error,
			removed = removed,
			retained_segment = floor.segment,
			retained_sequence = floor.sequence,
			cleanup_pending = refreshed ~= nil and refreshed.cleanup_segment < floor.segment,
			forced_expiry = forced_expiry,
		})
	end
	return finish({
		code = "pruned",
		removed = removed,
		retained_segment = floor.segment,
		retained_sequence = floor.sequence,
		cleanup_pending = refreshed ~= nil and refreshed.cleanup_segment < floor.segment,
		forced_expiry = forced_expiry,
	})
end

function Stream.GetRetentionStateAsync(self: StreamType, partition: number): any
	if not integer_at_least(partition, 1) or partition > self._partitions then
		return { code = "invalid", message = "partition is outside this stream" }
	end
	local head, read_error = self:_RefreshHead(partition)
	if head == nil then
		return { code = "unknown", message = read_error }
	end
	local registry, registry_error = self:_ReadGroupRegistry()
	if registry_error ~= nil or registry == nil then
		return { code = "unknown", message = registry_error or "consumer-group registry is missing" }
	end
	local floor = registry.floors[partition]
	return {
		code = "ok",
		partition = partition,
		active_segment = head.active_segment,
		retained_segment = floor.segment,
		retained_sequence = floor.sequence,
		cleanup_segment = head.cleanup_segment,
		max_retained_segments = self._options.max_retained_segments,
		min_segment_age_seconds = self._options.min_segment_age_seconds,
		max_segment_age_seconds = self._options.max_segment_age_seconds,
	}
end

function Stream.ClaimConsumerAsync(self: StreamType, group: string, partition: number, owner_token: string, lease_seconds: number?): any
	if not valid_text(group, MAX_GROUP_NAME_BYTES) then
		return { code = "invalid", message = "group must be 1..96 bytes" }
	end
	if not integer_at_least(partition, 1) or partition > self._partitions then
		return { code = "invalid", message = "partition is outside this stream" }
	end
	if not valid_text(owner_token, 128) then
		return { code = "invalid", message = "owner_token must be 1..128 bytes and unique to this worker incarnation" }
	end
	local duration = lease_seconds or 30
	if not validate_lease_seconds(duration) then
		return { code = "invalid", message = "lease_seconds must be 5..120" }
	end
	local now = self._options.now()
	if not safe_integer(now, 0) or now > MAX_SAFE_INTEGER - duration then
		return { code = "invalid", message = "clock or lease expiry exceeds the safe integer range" }
	end
	local registry, registry_error = self:_ReadGroupRegistry()
	if registry_error ~= nil then
		return { code = "unknown", message = registry_error }
	end
	if registry == nil then
		return { code = "not_registered", message = "consumer group must be registered before it can claim a partition" }
	end
	local registration = find_consumer_group(registry, group)
	if registration == nil then
		return { code = "not_registered", message = "consumer group must be registered before it can claim a partition" }
	end
	if registration.removing then
		return { code = "removed", message = "consumer group removal is in progress" }
	end
	local start_position = registration.positions[partition]
	local head, head_error = self:_RefreshHead(partition)
	if head == nil then
		return { code = "unknown", message = head_error }
	end
	local key = cursor_key(self._hash, group, partition)
	local initial_cursor, initial_cursor_error = datastore_get(self._store, key, self._get_options)
	if initial_cursor_error ~= nil then
		return { code = "unknown", message = "consumer cursor read failed: " .. initial_cursor_error }
	end
	if initial_cursor == nil then
		if start_position.segment < registry.floors[partition].segment then
			return {
				code = "expired",
				earliest_segment = registry.floors[partition].segment,
				earliest_sequence = registry.floors[partition].sequence,
				position = { segment = start_position.segment, offset = start_position.offset },
			}
		end
	else
		local existing, existing_error = validate_cursor(initial_cursor, self._name, group, partition)
		if existing == nil then
			return { code = "corrupt", message = existing_error }
		end
		if existing.segment < registry.floors[partition].segment then
			return {
				code = "expired",
				earliest_segment = registry.floors[partition].segment,
				earliest_sequence = registry.floors[partition].sequence,
				position = { segment = existing.segment, offset = existing.offset },
			}
		end
	end
	if start_position.segment > head.active_segment + 1 then
		return { code = "corrupt", message = "registered consumer start position is ahead of the partition head" }
	end
	local function release_expired_claim(current: CursorRecord)
		if current.owner_token ~= owner_token then
			return
		end
		datastore_update(self._store, key, function(raw)
			local live = validate_cursor(raw, self._name, group, partition)
			if live == nil or live.owner_token ~= owner_token or live.generation ~= current.generation then
				return nil
			end
			local released = copy_cursor(live)
			released.owner_token = nil
			released.lease_until = 0
			return released
		end)
	end
	local updated, update_error = datastore_update(self._store, key, function(raw)
		local current: CursorRecord
		if raw == nil then
			current = {
				format = 3,
				stream = self._name,
				group = group,
				partition = partition,
				segment = start_position.segment,
				offset = start_position.offset,
				generation = 0,
				owner_token = nil,
				lease_until = 0,
			}
		else
			local valid, validation_error = validate_cursor(raw, self._name, group, partition)
			if valid == nil then
				error("consumer cursor corrupt: " .. tostring(validation_error), 0)
			end
			current = valid
		end
		if current.owner_token ~= owner_token and current.owner_token ~= nil and current.lease_until > now then
			return nil
		end
		if current.generation >= MAX_SAFE_INTEGER then
			return nil
		end
		local next_record = copy_cursor(current)
		if current.owner_token ~= owner_token or current.lease_until <= now then
			next_record.generation += 1
		end
		next_record.owner_token = owner_token
		next_record.lease_until = now + duration
		return next_record
	end)
	local latest_registry, latest_registry_error = self:_ReadGroupRegistry()
	if latest_registry_error ~= nil or latest_registry == nil then
		return { code = "unknown", message = latest_registry_error or "consumer-group registry disappeared during claim" }
	end
	local latest_registration = find_consumer_group(latest_registry, group)
	if latest_registration == nil or latest_registration.removing then
		return { code = "removed", message = "consumer group is no longer active" }
	end
	local latest_floor = latest_registry.floors[partition]
	if update_error ~= nil or updated == nil then
		local observed, read_error = datastore_get(self._store, key, self._get_options)
		if read_error ~= nil then
			return { code = "unknown", message = tostring(update_error or "claim was not returned") .. "; reconciliation failed: " .. read_error }
		end
		local current, validation_error = validate_cursor(observed, self._name, group, partition)
		if current == nil then
			if update_error ~= nil then
				return { code = "unknown", message = update_error }
			end
			return { code = "corrupt", message = validation_error }
		end
		if current.segment < latest_floor.segment then
			release_expired_claim(current)
			return { code = "expired", earliest_segment = latest_floor.segment, earliest_sequence = latest_floor.sequence }
		end
		if current.owner_token == owner_token and current.lease_until > now then
			return claim_result(self, current, group, partition, owner_token, duration)
		end
		if current.owner_token ~= nil and current.lease_until > now then
			return { code = "busy", lease_until = current.lease_until, generation = current.generation }
		end
		return { code = "unknown", message = update_error or "claim outcome was not confirmed" }
	end
	local current, validation_error = validate_cursor(updated, self._name, group, partition)
	if current == nil then
		return { code = "corrupt", message = validation_error }
	end
	if current.segment < latest_floor.segment then
		release_expired_claim(current)
		return { code = "expired", earliest_segment = latest_floor.segment, earliest_sequence = latest_floor.sequence }
	end
	if current.owner_token ~= owner_token then
		return { code = "busy", lease_until = current.lease_until, generation = current.generation }
	end
	return claim_result(self, current, group, partition, owner_token, duration)
end

function Stream.RenewConsumerAsync(self: StreamType, claim: any): any
	local state = self._claims[claim]
	if state == nil or state.released then
		return { code = "invalid", message = "claim does not belong to this stream instance" }
	end
	local now = self._options.now()
	if not safe_integer(now, 0) or now > MAX_SAFE_INTEGER - state.lease_seconds then
		return { code = "invalid", message = "clock or lease expiry exceeds the safe integer range" }
	end
	local updated, update_error = datastore_update(self._store, state.cursor_key, function(raw)
		local current, validation_error = validate_cursor(raw, self._name, state.group, state.partition)
		if current == nil then
			if raw == nil then
				return nil
			end
			error("consumer cursor corrupt during renewal: " .. tostring(validation_error), 0)
		end
		if current.owner_token ~= state.owner_token or current.generation ~= state.generation or current.lease_until <= now then
			return nil
		end
		local next_record = copy_cursor(current)
		next_record.lease_until = now + state.lease_seconds
		return next_record
	end)
	if update_error ~= nil or updated == nil then
		local observed, read_error = datastore_get(self._store, state.cursor_key, self._get_options)
		if read_error ~= nil then
			return { code = "unknown", message = tostring(update_error or "renewal not returned") .. "; reconciliation failed: " .. read_error }
		end
		if observed == nil then
			state.released = true
			return { code = "fenced" }
		end
		local current, validation_error = validate_cursor(observed, self._name, state.group, state.partition)
		if current == nil then
			return { code = "corrupt", message = validation_error }
		end
		if current.owner_token == state.owner_token and current.generation == state.generation and current.lease_until > now then
			state.lease_until = current.lease_until
			return { code = "renewed", lease_until = current.lease_until }
		end
		return { code = "fenced", generation = current.generation }
	end
	local current, validation_error = validate_cursor(updated, self._name, state.group, state.partition)
	if current == nil then
		return { code = "corrupt", message = validation_error }
	end
	state.lease_until = current.lease_until
	return { code = "renewed", lease_until = current.lease_until }
end

local function checkpoint(
	self: StreamType,
	claim: any,
	state: ClaimState,
	expected_segment: number,
	expected_offset: number,
	next_segment: number,
	next_offset: number
): any
	local now = self._options.now()
	if not safe_integer(now, 0) or now > MAX_SAFE_INTEGER - state.lease_seconds
		or not safe_integer(next_segment, 1) or not safe_integer(next_offset, 1)
	then
		return { code = "capacity", message = "checkpoint position or lease expiry exceeds the safe integer range" }
	end
	local updated, update_error = datastore_update(self._store, state.cursor_key, function(raw)
		local current, validation_error = validate_cursor(raw, self._name, state.group, state.partition)
		if current == nil then
			if raw == nil then
				return nil
			end
			error("consumer cursor corrupt during checkpoint: " .. tostring(validation_error), 0)
		end
		if current.owner_token ~= state.owner_token or current.generation ~= state.generation or current.lease_until <= now then
			return nil
		end
		if current.segment ~= expected_segment or current.offset ~= expected_offset then
			return nil
		end
		local next_record = copy_cursor(current)
		next_record.segment = next_segment
		next_record.offset = next_offset
		next_record.lease_until = now + state.lease_seconds
		return next_record
	end)
	if update_error ~= nil or updated == nil then
		local observed, read_error = datastore_get(self._store, state.cursor_key, self._get_options)
		if read_error ~= nil then
			return { code = "unknown", message = tostring(update_error or "checkpoint not returned") .. "; reconciliation failed: " .. read_error }
		end
		if observed == nil then
			state.released = true
			return { code = "fenced" }
		end
		local current, validation_error = validate_cursor(observed, self._name, state.group, state.partition)
		if current == nil then
			return { code = "corrupt", message = validation_error }
		end
		if current.owner_token ~= state.owner_token or current.generation ~= state.generation or current.lease_until <= now then
			return { code = "fenced", generation = current.generation }
		end
		if current.segment == next_segment and current.offset == next_offset then
			state.segment = current.segment
			state.offset = current.offset
			state.lease_until = current.lease_until
			return { code = "committed", reconciled = true, claim = claim }
		end
		if current.segment ~= expected_segment or current.offset ~= expected_offset then
			return { code = "conflict", position = { segment = current.segment, offset = current.offset } }
		end
		return { code = "unknown", message = update_error or "checkpoint was not committed" }
	end
	local current, validation_error = validate_cursor(updated, self._name, state.group, state.partition)
	if current == nil then
		return { code = "corrupt", message = validation_error }
	end
	state.segment = current.segment
	state.offset = current.offset
	state.lease_until = current.lease_until
	return { code = "committed", claim = claim }
end

function Stream.ConsumeBatchAsync(self: StreamType, claim: any, handler: (any, any) -> (boolean, string?), batch_size: number?): any
	local state = self._claims[claim]
	if state == nil or state.released then
		return { code = "invalid", message = "claim does not belong to this stream instance" }
	end
	if type(handler) ~= "function" then
		return { code = "invalid", message = "handler must be a function" }
	end
	local limit = batch_size or self._options.max_batch_messages
	if not integer_at_least(limit, 1) or limit > self._options.max_batch_messages then
		return { code = "invalid", message = "batch_size is outside the configured bound" }
	end
	if self._busy[state.claim_key] then
		return { code = "busy" }
	end
	self._busy[state.claim_key] = true
	local function finish(result: any): any
		self._busy[state.claim_key] = nil
		return result
	end
	local current_time = self._options.now()
	if not safe_integer(current_time, 0) or state.lease_until <= current_time then
		return finish({ code = "fenced", generation = state.generation })
	end
	local registry, registry_error = self:_ReadGroupRegistry()
	if registry_error ~= nil then
		return finish({ code = "unknown", message = registry_error })
	end
	if registry == nil then
		return finish({ code = "removed", message = "consumer-group registry is missing" })
	end
	local registration = find_consumer_group(registry, state.group)
	if registration == nil or registration.removing then
		return finish({ code = "removed", message = "consumer group is no longer active" })
	end
	local retention_floor = registry.floors[state.partition]
	local expected_segment = state.segment
	local expected_offset = state.offset
	local head, head_error = self:_RefreshHead(state.partition)
	if head == nil then
		return finish({ code = "unknown", message = head_error })
	end
	if expected_segment < retention_floor.segment then
		return finish({
			code = "expired",
			earliest_segment = retention_floor.segment,
			earliest_sequence = retention_floor.sequence,
			position = { segment = expected_segment, offset = expected_offset },
		})
	end
	local segment, read_error = self:_ReadSegment(state.partition, expected_segment)
	if read_error ~= nil then
		return finish({ code = "corrupt", message = read_error })
	end
	if segment == nil then
		if expected_segment < head.active_segment then
			return finish({ code = "corrupt", message = "retained consumer segment is missing" })
		end
		if expected_segment > head.active_segment then
			if expected_segment ~= head.active_segment + 1 then
				return finish({ code = "corrupt", message = "consumer cursor is more than one segment ahead of the partition head" })
			end
			local previous, previous_error = self:_ReadSegment(state.partition, head.active_segment)
			if previous_error ~= nil or previous == nil or not previous.sealed then
				return finish({ code = "corrupt", message = previous_error or "previous segment is missing or not sealed" })
			end
			local advanced, advance_error = self:_AdvanceHead(state.partition, previous)
			if not advanced then
				return finish({ code = if is_capacity_error(advance_error) then "capacity" else "unknown", message = advance_error or "rollover repair was not confirmed" })
			end
			local repaired, repair_error = self:_RefreshHead(state.partition)
			if repaired == nil or repaired.active_segment ~= expected_segment then
				return finish({ code = "unknown", message = repair_error or "rollover repair did not reach the consumer cursor" })
			end
			return finish({ code = "idle", claim = claim, rollover_repaired = true })
		end
		return finish({ code = "idle", claim = claim })
	end
	if expected_offset > #segment.messages + 1 then
		return finish({ code = "corrupt", message = "consumer cursor offset exceeds segment bounds" })
	end
	if expected_offset == #segment.messages + 1 then
		if not segment.sealed then
			return finish({ code = "idle", claim = claim })
		end
		local skipped = checkpoint(self, claim, state, expected_segment, expected_offset, expected_segment + 1, 1)
		return finish(skipped)
	end
	local last_index = math.min(#segment.messages, expected_offset + limit - 1)
	local messages = table.create(last_index - expected_offset + 1)
	for index = expected_offset, last_index do
		local row = segment.messages[index]
		messages[#messages + 1] = table.freeze({
			sequence = row.sequence,
			event_id = row.event_id,
			payload = row.payload,
			created_at = row.created_at,
		})
	end
	local next_segment = expected_segment
	local next_offset = last_index + 1
	if next_offset == #segment.messages + 1 and segment.sealed then
		next_segment += 1
		next_offset = 1
	end
	local context = table.freeze({
		stream = self._name,
		group = state.group,
		partition = state.partition,
		fence_generation = state.generation,
		first_sequence = segment.messages[expected_offset].sequence,
		last_sequence = segment.messages[last_index].sequence,
	})
	local handler_ok, accepted, handler_message = pcall(handler, table.freeze(messages), context)
	if not handler_ok then
		return finish({ code = "retryable", message = tostring(accepted), count = #messages })
	end
	if accepted ~= true then
		return finish({ code = "retryable", message = tostring(handler_message or "handler did not confirm the batch"), count = #messages })
	end
	local latest_registry, latest_registry_error = self:_ReadGroupRegistry()
	if latest_registry_error ~= nil then
		return finish({ code = "unknown", message = latest_registry_error })
	end
	local latest_floor = latest_registry and latest_registry.floors[state.partition]
	local latest_group = latest_registry and find_consumer_group(latest_registry, state.group)
	if latest_group == nil or latest_group.removing then
		return finish({ code = "removed", message = "consumer group was removed while the handler was running" })
	end
	if latest_floor == nil or expected_segment < latest_floor.segment then
		return finish({
			code = "expired",
			earliest_segment = latest_floor and latest_floor.segment,
			earliest_sequence = latest_floor and latest_floor.sequence,
			message = "retention advanced while the handler was running",
		})
	end
	local result = checkpoint(self, claim, state, expected_segment, expected_offset, next_segment, next_offset)
	if result.code == "committed" then
		result.count = #messages
		result.first_sequence = context.first_sequence
		result.last_sequence = context.last_sequence
	end
	return finish(result)
end

function Stream.ReleaseConsumerAsync(self: StreamType, claim: any): any
	local state = self._claims[claim]
	if state == nil or state.released then
		return { code = "invalid", message = "claim does not belong to this stream instance" }
	end
	local updated, update_error = datastore_update(self._store, state.cursor_key, function(raw)
		local current, validation_error = validate_cursor(raw, self._name, state.group, state.partition)
		if current == nil then
			if raw == nil then
				return nil
			end
			error("consumer cursor corrupt during release: " .. tostring(validation_error), 0)
		end
		if current.owner_token ~= state.owner_token or current.generation ~= state.generation then
			return nil
		end
		local next_record = copy_cursor(current)
		next_record.owner_token = nil
		next_record.lease_until = 0
		return next_record
	end)
	if update_error ~= nil or updated == nil then
		local observed, read_error = datastore_get(self._store, state.cursor_key, self._get_options)
		if read_error ~= nil then
			return { code = "unknown", message = tostring(update_error or "release not returned") .. "; reconciliation failed: " .. read_error }
		end
		if observed == nil then
			state.released = true
			return { code = "fenced" }
		end
		local current, validation_error = validate_cursor(observed, self._name, state.group, state.partition)
		if current == nil then
			return { code = "corrupt", message = validation_error }
		end
		if current.owner_token == nil and current.generation == state.generation then
			state.released = true
			return { code = "released", reconciled = true }
		end
		return { code = "fenced", generation = current.generation }
	end
	local current, validation_error = validate_cursor(updated, self._name, state.group, state.partition)
	if current == nil then
		return { code = "corrupt", message = validation_error }
	end
	state.released = true
	return { code = "released" }
end

return table.freeze(DurableStreams)
