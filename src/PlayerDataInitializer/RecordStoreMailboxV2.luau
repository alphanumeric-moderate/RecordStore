--!strict
-- Experimental per-message durable mailbox. It is opt-in and does not replace RecordStore's v3 queue.
-- Call UpdateAsync transforms are pure. Handler callbacks run only after a claim is verified.

local MailboxV2 = {}
MailboxV2.__index = MailboxV2

type Dict = { [string]: unknown }
type Owner = {
	store_name: string,
	scope: string,
	profile_key: string,
	user_id: number?,
}
type StoreAdapter = {
	GetAsync: (self: StoreAdapter, key: string) -> unknown,
	UpdateAsync: (self: StoreAdapter, key: string, transform: (unknown, unknown?) -> unknown) -> unknown,
	RemoveAsync: ((self: StoreAdapter, key: string) -> ())?,
}
type Options = {
	now_ms: (() -> number)?,
	guid: (() -> string)?,
	encode: ((unknown) -> string)?,
	max_segments: number?,
	segment_max_messages: number?,
	max_payload_bytes: number?,
	max_request_bytes: number?,
	preparation_shard_count: number?,
	preparation_max_entries_per_shard: number?,
	preparation_max_entry_bytes: number?,
	dlq_max_segments: number?,
	dlq_segment_max_messages: number?,
	lease_ms: number?,
	clock_skew_grace_ms: number?,
	max_attempts: number?,
	retry_base_ms: number?,
	retry_max_ms: number?,
	priority_aging_ms: number?,
}
type Locator = { slot: number, generation: number, key: string }
type Result = {
	code: string,
	message_id: string?,
	message: Dict?,
	error: string?,
}
type Mailbox = typeof(setmetatable({} :: {
	store: StoreAdapter,
	owner: Owner,
	owner_text: string,
	options: Options,
}, MailboxV2))

local VERSION = 2
local MAX_KEY_LENGTH = 50
local DEFAULT_MAX_SEGMENTS = 64
local DEFAULT_SEGMENT_MAX_MESSAGES = 32
local DEFAULT_PREPARATION_SHARDS = 16
local DEFAULT_PREPARATION_ENTRIES = 16
local DEFAULT_PREPARATION_ENTRY_BYTES = 131072
local DEFAULT_MAX_PAYLOAD_BYTES = 65536
local DEFAULT_MAX_REQUEST_BYTES = 131072
local DEFAULT_DLQ_MAX_SEGMENTS = 64
local DEFAULT_DLQ_SEGMENT_MAX_MESSAGES = 32
local DEFAULT_LEASE_MS = 60000
local DEFAULT_CLOCK_SKEW_GRACE_MS = 5000
local DEFAULT_MAX_ATTEMPTS = 5
local DEFAULT_RETRY_BASE_MS = 1000
local DEFAULT_RETRY_MAX_MS = 60000
local DEFAULT_PRIORITY_AGING_MS = 60000
local TERMINAL = {
	acknowledged = true,
	dead_lettered = true,
	discarded = true,
	expired = true,
}

local function is_finite(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function as_dict(value: unknown): Dict?
	if type(value) == "table" then
		return value :: Dict
	end
	return nil
end

local function clone_json(value: unknown, depth: number?): unknown
	local level = depth or 0
	if level > 64 then
		error("value exceeds the supported nesting depth", 2)
	end
	if type(value) ~= "table" then
		return value
	end
	local result: Dict = {}
	for key, child in value :: Dict do
		if type(key) ~= "string" and (type(key) ~= "number" or not is_finite(key)) then
			error("JSON object keys must be strings and array keys must be finite numbers", 2)
		end
		result[key] = clone_json(child, level + 1)
	end
	return result
end

local function canonical(value: unknown, stack: { [table]: boolean }?, depth: number?): string
	local active = stack or {}
	local level = depth or 0
	if level > 64 then
		error("value exceeds the supported nesting depth", 2)
	end
	local kind = type(value)
	if value == nil then
		return "n"
	elseif kind == "boolean" then
		return if value then "b1" else "b0"
	elseif kind == "number" then
		if not is_finite(value) then
			error("non-finite numbers are not valid mailbox payloads", 2)
		end
		return "d" .. (if value == 0 then "0" else string.format("%.17g", value))
	elseif kind == "string" then
		return "s" .. tostring(#value) .. ":" .. value
	elseif kind ~= "table" then
		error("mailbox values must contain only JSON-compatible scalars and tables", 2)
	end

	local table_value = value :: table
	if active[table_value] then
		error("cyclic tables are not valid mailbox payloads", 2)
	end
	active[table_value] = true
	local source = table_value :: Dict
	local count = 0
	local max_array_index = 0
	local array_only = true
	for key in source do
		count += 1
		if type(key) == "number" and is_finite(key) and key >= 1 and key == math.floor(key) then
			max_array_index = math.max(max_array_index, key)
		else
			array_only = false
		end
	end
	if array_only and max_array_index == count and count > 0 then
		local parts = table.create(count)
		for index = 1, count do
			parts[index] = canonical(source[index], active, level + 1)
		end
		active[table_value] = nil
		return "a" .. tostring(count) .. "[" .. table.concat(parts, "") .. "]"
	end

	local keys: { string } = {}
	for key in source do
		if type(key) ~= "string" then
			active[table_value] = nil
			error("mixed or sparse arrays are not valid mailbox objects", 2)
		end
		table.insert(keys, key)
	end
	table.sort(keys)
	local parts = table.create(#keys)
	for index, key in keys do
		parts[index] = canonical(key, active, level + 1) .. canonical(source[key], active, level + 1)
	end
	active[table_value] = nil
	return "o" .. tostring(#keys) .. "{" .. table.concat(parts, "") .. "}"
end

-- SDBM-derived routing digest. It is not authentication or proof of identity; stored full identities are checked.
local function digest(value: string): string
	local result = table.create(4)
	for seed_index = 1, 4 do
		local hash = 2166136261 + seed_index * 7919
		for index = 1, #value do
			hash = (string.byte(value, index) + hash * 65599) % 4294967296
		end
		result[seed_index] = string.format("%08x", hash)
	end
	return table.concat(result, "")
end

local function now_default(): number
	return os.time() * 1000
end

local function ok(code: string, message_id: string?, message: Dict?, error_message: string?): Result
	return { code = code, message_id = message_id, message = message, error = error_message }
end

local function clone_owner(owner: Owner): Owner
	return {
		store_name = owner.store_name,
		scope = owner.scope,
		profile_key = owner.profile_key,
		user_id = owner.user_id,
	}
end

local function valid_owner(owner: unknown): (Owner?, string?)
	local value = as_dict(owner)
	if value == nil
		or type(value.store_name) ~= "string" or value.store_name == "" or #value.store_name > 50
		or type(value.scope) ~= "string" or value.scope == "" or #value.scope > 50
		or type(value.profile_key) ~= "string" or value.profile_key == "" or #value.profile_key > 50
	then
		return nil, "owner requires store_name, scope and profile_key of 1 to 50 characters"
	end
	if value.user_id ~= nil and (not is_finite(value.user_id) or (value.user_id :: number) < 1 or (value.user_id :: number) ~= math.floor(value.user_id :: number)) then
		return nil, "user_id must be a positive integer when supplied"
	end
	return clone_owner(value :: Owner), nil
end

local function same_owner(left: unknown, right: Owner): boolean
	local left_dict = as_dict(left)
	return left_dict ~= nil
		and left_dict.store_name == right.store_name
		and left_dict.scope == right.scope
		and left_dict.profile_key == right.profile_key
		and left_dict.user_id == right.user_id
end

local function result_route_key(self: Mailbox, prefix: string, identity: string): string
	local full_digest = digest(self.owner_text .. "|" .. identity)
	local key = if self.owner.user_id ~= nil
		then prefix .. tostring(self.owner.user_id) .. "-" .. string.sub(full_digest, 1, 24)
		else prefix .. full_digest
	assert(#key <= MAX_KEY_LENGTH, "internal key codec exceeded the DataStore key limit")
	return key
end

local function route_shard(self: Mailbox, route: string): number
	local value = tonumber(string.sub(digest(self.owner_text .. "|" .. route), 1, 8), 16) or 0
	return (value % (self.options.preparation_shard_count or DEFAULT_PREPARATION_SHARDS)) + 1
end

local function prefix_for_kind(kind: string): (string, string)
	if kind == "active" then
		return "mf2-", "si2-"
	end
	return "md2-", "di2-"
end

local function locate_slot(manifest: Dict, slot_number: number): Dict?
	local slots = manifest.slots
	if type(slots) ~= "table" then
		return nil
	end
	return as_dict((slots :: { unknown })[slot_number])
end

local function clone_dict(source: Dict): Dict
	return clone_json(source) :: Dict
end

local function has_row(segment: Dict, route: string, placement_generation: number): boolean
	local entries = segment.entries
	if type(entries) ~= "table" then
		return false
	end
	for _, entry in entries :: { unknown } do
		local row = as_dict(entry)
		if row ~= nil and row.route == route and row.placement_generation == placement_generation then
			return true
		end
	end
	return false
end

function MailboxV2.new(store: unknown, owner_value: Owner, options_value: Options?): Mailbox
	local owner, owner_error = valid_owner(owner_value)
	if owner == nil then
		error(owner_error or "invalid owner", 2)
	end
	if type(store) ~= "table"
		or type((store :: Dict).GetAsync) ~= "function"
		or type((store :: Dict).UpdateAsync) ~= "function"
	then
		error("store must implement GetAsync and UpdateAsync", 2)
	end
	local options = table.clone(options_value or {}) :: Options
	if type(options.encode) ~= "function" then
		error("options.encode must provide the exact serialized representation used by the DataStore adapter", 2)
	end
	options.max_segments = options.max_segments or DEFAULT_MAX_SEGMENTS
	options.segment_max_messages = options.segment_max_messages or DEFAULT_SEGMENT_MAX_MESSAGES
	options.max_payload_bytes = options.max_payload_bytes or DEFAULT_MAX_PAYLOAD_BYTES
	options.max_request_bytes = options.max_request_bytes or DEFAULT_MAX_REQUEST_BYTES
	options.preparation_shard_count = options.preparation_shard_count or DEFAULT_PREPARATION_SHARDS
	options.preparation_max_entries_per_shard = options.preparation_max_entries_per_shard or DEFAULT_PREPARATION_ENTRIES
	options.preparation_max_entry_bytes = options.preparation_max_entry_bytes or DEFAULT_PREPARATION_ENTRY_BYTES
	options.dlq_max_segments = options.dlq_max_segments or DEFAULT_DLQ_MAX_SEGMENTS
	options.dlq_segment_max_messages = options.dlq_segment_max_messages or DEFAULT_DLQ_SEGMENT_MAX_MESSAGES
	options.lease_ms = options.lease_ms or DEFAULT_LEASE_MS
	options.clock_skew_grace_ms = options.clock_skew_grace_ms or DEFAULT_CLOCK_SKEW_GRACE_MS
	options.max_attempts = options.max_attempts or DEFAULT_MAX_ATTEMPTS
	options.retry_base_ms = options.retry_base_ms or DEFAULT_RETRY_BASE_MS
	options.retry_max_ms = options.retry_max_ms or DEFAULT_RETRY_MAX_MS
	options.priority_aging_ms = options.priority_aging_ms or DEFAULT_PRIORITY_AGING_MS
	local numeric_options = {
		"max_segments", "segment_max_messages", "max_payload_bytes", "max_request_bytes",
		"preparation_shard_count", "preparation_max_entries_per_shard", "preparation_max_entry_bytes",
		"dlq_max_segments", "dlq_segment_max_messages", "lease_ms", "clock_skew_grace_ms",
		"max_attempts", "retry_base_ms", "retry_max_ms", "priority_aging_ms",
	}
	for _, key in numeric_options do
		local value = (options :: Dict)[key]
		if not is_finite(value) or (value :: number) < 1 or (value :: number) ~= math.floor(value :: number) then
			error(key .. " must be a positive integer", 2)
		end
	end
	if (options.max_segments :: number) > 64 or (options.dlq_max_segments :: number) > 64 then
		error("initial v2 segment bounds may not exceed 64 slots", 2)
	end
	if (options.segment_max_messages :: number) > 32 or (options.dlq_segment_max_messages :: number) > 32 then
		error("initial v2 segment bounds may not exceed 32 rows per segment", 2)
	end
	local self = {
		store = store :: StoreAdapter,
		owner = owner,
		owner_text = canonical(owner),
		options = options,
	}
	return setmetatable(self, MailboxV2) :: Mailbox
end

function MailboxV2._now(self: Mailbox): number
	return if self.options.now_ms ~= nil then self.options.now_ms() else now_default()
end

function MailboxV2._encode_size(self: Mailbox, value: unknown): (number?, string?)
	if self.options.encode == nil then
		return nil, "a production-compatible encoded-size callback is required"
	end
	local success, result = pcall(function()
		return (self.options.encode :: (unknown) -> string)(value)
	end)
	if not success or type(result) ~= "string" then
		return nil, "value is not serializable"
	end
	return #result, nil
end

function MailboxV2._get(self: Mailbox, key: string): (unknown, string?)
	local success, value = pcall(function()
		return self.store:GetAsync(key)
	end)
	if not success then
		return nil, tostring(value)
	end
	return value, nil
end

function MailboxV2._update(self: Mailbox, key: string, transform: (unknown) -> unknown): (unknown, string?)
	local success, value = pcall(function()
		return self.store:UpdateAsync(key, function(raw: unknown, key_info: any)
			local next_value = transform(raw)
			if key_info ~= nil then
				-- Preserve existing DataStore user IDs and metadata across queue-key mutations.
				return next_value, key_info:GetUserIds(), key_info:GetMetadata()
			end
			return next_value
		end)
	end)
	if not success then
		return nil, tostring(value)
	end
	return value, nil
end

function MailboxV2._route_key(self: Mailbox, idempotency_key: string?): (string?, string?)
	if idempotency_key ~= nil then
		if type(idempotency_key) ~= "string" or idempotency_key == "" or #idempotency_key > 256 then
			return nil, "idempotency_key must be 1 to 256 bytes"
		end
		return result_route_key(self, "m2i-", "producer:" .. idempotency_key), nil
	end
	local guid = if self.options.guid ~= nil then self.options.guid() else nil
	if type(guid) ~= "string" or guid == "" then
		return nil, "a guid callback is required when enqueueing without an idempotency key"
	end
	return result_route_key(self, "m2g-", "generated:" .. guid), nil
end

function MailboxV2._manifest_key(self: Mailbox, kind: string): string
	local manifest_prefix = prefix_for_kind(kind)
	return result_route_key(self, manifest_prefix, "manifest:" .. kind)
end

function MailboxV2._segment_key(self: Mailbox, kind: string, slot: number, generation: number): string
	local _, segment_prefix = prefix_for_kind(kind)
	return result_route_key(self, segment_prefix, kind .. ":" .. tostring(slot) .. ":" .. tostring(generation))
end

function MailboxV2._registry_key(self: Mailbox, shard: number): string
	return result_route_key(self, "pr2-", "preparation-shard:" .. tostring(shard))
end

function MailboxV2._fresh_manifest(self: Mailbox, kind: string): Dict
	local max_slots = if kind == "active" then self.options.max_segments :: number else self.options.dlq_max_segments :: number
	local slots = table.create(max_slots)
	for index = 1, max_slots do
		slots[index] = { generation = 0, state = "empty" }
	end
	return {
		version = VERSION,
		kind = kind,
		owner = clone_owner(self.owner),
		slots = slots,
	}
end

function MailboxV2._get_manifest(self: Mailbox, kind: string): (Dict?, string?)
	local key = self:_manifest_key(kind)
	local current, read_error = self:_get(key)
	if read_error == nil and current ~= nil then
		local manifest = as_dict(current)
		if manifest == nil or manifest.version ~= VERSION or manifest.kind ~= kind or not same_owner(manifest.owner, self.owner) or type(manifest.slots) ~= "table" then
			return nil, "manifest is corrupt, future-versioned or belongs to another owner"
		end
		return manifest, nil
	end
	local initial = self:_fresh_manifest(kind)
	local written, write_error = self:_update(key, function(raw)
		if raw == nil then
			return initial
		end
		return raw
	end)
	if write_error ~= nil then
		return nil, "manifest initialization outcome is unknown: " .. write_error
	end
	local manifest = as_dict(written)
	if manifest == nil or manifest.version ~= VERSION or manifest.kind ~= kind or not same_owner(manifest.owner, self.owner) then
		return nil, "manifest initialization could not be verified"
	end
	return manifest, nil
end

function MailboxV2._set_slot_state(self: Mailbox, kind: string, locator: Locator, expected_state: string, next_state: string, allocation_token: string?): boolean
	local key = self:_manifest_key(kind)
	local updated, update_error = self:_update(key, function(raw)
		local manifest = as_dict(raw)
		if manifest == nil or manifest.version ~= VERSION or not same_owner(manifest.owner, self.owner) then
			return raw
		end
		local next_manifest = clone_dict(manifest)
		local slot = locate_slot(next_manifest, locator.slot)
		if slot == nil or slot.generation ~= locator.generation or slot.state ~= expected_state then
			return raw
		end
		if allocation_token ~= nil and slot.allocation_token ~= allocation_token then
			return raw
		end
		local next_slot = clone_dict(slot)
		next_slot.state = next_state
		next_slot.allocation_token = nil
		(next_manifest.slots :: { unknown })[locator.slot] = next_slot
		return next_manifest
	end)
	if update_error ~= nil then
		return false
	end
	local manifest = as_dict(updated)
	local slot = if manifest ~= nil then locate_slot(manifest, locator.slot) else nil
	return slot ~= nil and slot.generation == locator.generation and slot.state == next_state
end

function MailboxV2._finish_allocation(self: Mailbox, kind: string, locator: Locator, token: string): (Locator?, string?)
	local segment_template: Dict = {
		version = VERSION,
		kind = kind,
		owner = clone_owner(self.owner),
		slot = locator.slot,
		generation = locator.generation,
		state = "open",
		entries = {},
	}
	local segment, segment_error = self:_update(locator.key, function(raw)
		if raw == nil then
			return segment_template
		end
		return raw
	end)
	if segment_error ~= nil then
		return nil, "segment allocation outcome is unknown: " .. segment_error
	end
	local segment_dict = as_dict(segment)
	if segment_dict == nil or segment_dict.version ~= VERSION or segment_dict.kind ~= kind
		or segment_dict.slot ~= locator.slot or segment_dict.generation ~= locator.generation
		or not same_owner(segment_dict.owner, self.owner)
	then
		return nil, "segment allocation collided with a different owner or generation"
	end
	local published = self:_set_slot_state(kind, locator, "allocating", "open", token)
	if not published then
		local latest_manifest = self:_get_manifest(kind)
		local slot = if latest_manifest ~= nil then locate_slot(latest_manifest, locator.slot) else nil
		if slot == nil or slot.generation ~= locator.generation or slot.state ~= "open" then
			return nil, "segment was initialized but its manifest publication is unknown"
		end
	end
	return locator, nil
end

function MailboxV2._reclaim_slot(self: Mailbox, kind: string): boolean
	local manifest, manifest_error = self:_get_manifest(kind)
	if manifest == nil then
		return false
	end
	local slots = manifest.slots :: { unknown }
	for slot_number, raw_slot in slots do
		local slot = as_dict(raw_slot)
		if slot ~= nil and slot.state == "sealed" then
			local locator: Locator = {
				slot = slot_number,
				generation = slot.generation :: number,
				key = self:_segment_key(kind, slot_number, slot.generation :: number),
			}
			local segment_value = self:_get(locator.key)
			local segment = as_dict(segment_value)
			if segment ~= nil and segment.state == "sealed" and segment.generation == locator.generation then
				local safe = true
				local entries = segment.entries
				if type(entries) == "table" then
					for _, raw_row in entries :: { unknown } do
						local row = as_dict(raw_row)
						if row == nil then
							safe = false
							break
						end
						local record_value = self:_get(tostring(row.route))
						local record = as_dict(record_value)
						if record == nil or not same_owner(record.owner, self.owner) then
							safe = false
							break
						end
						if kind == "active" then
							local active_locator = as_dict(record.locator)
							local row_is_stale = record.placement_generation ~= row.placement_generation
								or active_locator == nil
								or active_locator.slot ~= locator.slot
								or active_locator.generation ~= locator.generation
							if not row_is_stale and record.state ~= "acknowledged" and record.state ~= "dead_lettered" and record.state ~= "discarded" and record.state ~= "expired" then
								safe = false
								break
							end
						elseif record.state == "replaying"
							or (record.state == "dead_lettered" and record.dlq_placement_generation == row.placement_generation)
						then
							-- Retain the DLQ row until discard/retention or replay completion is verified.
							safe = false
							break
						end
					end
				end
				if safe then
					if not self:_set_slot_state(kind, locator, "sealed", "draining") then
						continue
					end
					local retired, retire_error = self:_update(locator.key, function(raw)
						local current = as_dict(raw)
						if current == nil or current.generation ~= locator.generation or current.state ~= "sealed" then
							return raw
						end
						local next_segment = clone_dict(current)
						next_segment.state = "retired"
						return next_segment
					end)
					if retire_error ~= nil or as_dict(retired) == nil then
						return false
					end
					-- Removal is safe only after the segment is non-writable and its manifest generation is retired.
					local storage_remove = self.store.RemoveAsync
					if storage_remove ~= nil then
						pcall(function()
							storage_remove(self.store, locator.key)
						end)
					end
					local current_manifest = self:_get_manifest(kind)
					if current_manifest ~= nil then
						local current_slot = locate_slot(current_manifest, slot_number)
						if current_slot ~= nil and current_slot.generation == locator.generation and current_slot.state == "draining" then
							local _, release_error = self:_update(self:_manifest_key(kind), function(raw)
								local current = as_dict(raw)
								if current == nil or not same_owner(current.owner, self.owner) then
									return raw
								end
								local next_manifest = clone_dict(current)
								local release_slot = locate_slot(next_manifest, slot_number)
								if release_slot == nil or release_slot.generation ~= locator.generation or release_slot.state ~= "draining" then
									return raw
								end
								local next_slot = clone_dict(release_slot)
								next_slot.state = "empty"
								next_slot.allocation_token = nil
								(next_manifest.slots :: { unknown })[slot_number] = next_slot
								return next_manifest
							end)
							if release_error == nil then
								return true
							end
						end
					end
				end
			end
		end
	end
	return false
end

function MailboxV2._open_segment(self: Mailbox, kind: string): (Locator?, string?)
	for _attempt = 1, 3 do
		local manifest, manifest_error = self:_get_manifest(kind)
		if manifest == nil then
			return nil, manifest_error
		end
		local slots = manifest.slots :: { unknown }
		for slot_number, raw_slot in slots do
			local slot = as_dict(raw_slot)
			if slot ~= nil and slot.state == "open" then
				local locator: Locator = {
					slot = slot_number,
					generation = slot.generation :: number,
					key = self:_segment_key(kind, slot_number, slot.generation :: number),
				}
				local segment_value, segment_error = self:_get(locator.key)
				local segment = as_dict(segment_value)
				if segment_error == nil and segment ~= nil and segment.state == "open"
					and segment.generation == locator.generation and same_owner(segment.owner, self.owner)
				then
					return locator, nil
				end
			end
		end
		for slot_number, raw_slot in slots do
			local slot = as_dict(raw_slot)
			if slot ~= nil and slot.state == "allocating" and type(slot.allocation_token) == "string" then
				local locator: Locator = {
					slot = slot_number,
					generation = slot.generation :: number,
					key = self:_segment_key(kind, slot_number, slot.generation :: number),
				}
				local finished, finish_error = self:_finish_allocation(kind, locator, slot.allocation_token :: string)
				if finished ~= nil then
					return finished, nil
				end
				return nil, finish_error
			end
		end
		local token = if self.options.guid ~= nil then self.options.guid() else digest(self.owner_text .. tostring(self:_now()) .. tostring(math.random()))
		local allocated, allocate_error = self:_update(self:_manifest_key(kind), function(raw)
			local current = as_dict(raw)
			if current == nil then
				return self:_fresh_manifest(kind)
			end
			if current.version ~= VERSION or not same_owner(current.owner, self.owner) then
				return raw
			end
			local next_manifest = clone_dict(current)
			local next_slots = next_manifest.slots :: { unknown }
			for slot_number, raw_slot in next_slots do
				local slot = as_dict(raw_slot)
				if slot ~= nil and slot.state == "empty" then
					local next_slot = clone_dict(slot)
					next_slot.generation = (if is_finite(slot.generation) then slot.generation :: number else 0) + 1
					next_slot.state = "allocating"
					next_slot.allocation_token = token
					next_slots[slot_number] = next_slot
					return next_manifest
				end
			end
			return raw
		end)
		if allocate_error ~= nil then
			return nil, "slot allocation outcome is unknown: " .. allocate_error
		end
		local next_manifest = as_dict(allocated)
		local selected_slot: number? = nil
		local selected_generation: number? = nil
		if next_manifest ~= nil and type(next_manifest.slots) == "table" then
			for slot_number, raw_slot in next_manifest.slots :: { unknown } do
				local slot = as_dict(raw_slot)
				if slot ~= nil and slot.state == "allocating" and slot.allocation_token == token then
					selected_slot = slot_number
					selected_generation = slot.generation :: number
					break
				end
			end
		end
		if selected_slot ~= nil and selected_generation ~= nil then
			local locator: Locator = {
				slot = selected_slot,
				generation = selected_generation,
				key = self:_segment_key(kind, selected_slot, selected_generation),
			}
			return self:_finish_allocation(kind, locator, token)
		end
		if not self:_reclaim_slot(kind) then
			return nil, "capacity: all segment slots contain live or unresolved rows"
		end
	end
	return nil, "capacity: could not allocate an active segment"
end

function MailboxV2._set_registry_entry(self: Mailbox, route: string, token: string, patch: Dict?, remove_entry: boolean?): (Dict?, string?)
	local key = self:_registry_key(route_shard(self, route))
	local updated, update_error = self:_update(key, function(raw)
		local current = as_dict(raw)
		if current == nil then
			return raw
		end
		if current.version ~= VERSION or not same_owner(current.owner, self.owner) then
			return raw
		end
		local entries = as_dict(current.entries)
		if entries == nil then
			return raw
		end
		local active = as_dict(entries[route])
		if active == nil or active.token ~= token then
			return raw
		end
		local next_registry = clone_dict(current)
		local next_entries = clone_dict(entries)
		if remove_entry == true then
			next_entries[route] = nil
		elseif patch ~= nil then
			local next_entry = clone_dict(active)
			for field, value in patch do
				next_entry[field] = clone_json(value)
			end
			next_entries[route] = next_entry
		end
		next_registry.entries = next_entries
		return next_registry
	end)
	if update_error ~= nil then
		return nil, "preparation update outcome is unknown: " .. update_error
	end
	local registry = as_dict(updated)
	local entry = if registry ~= nil then as_dict(as_dict(registry.entries) and (as_dict(registry.entries) :: Dict)[route]) else nil
	return entry, nil
end

function MailboxV2._get_registry_entry(self: Mailbox, route: string): (Dict?, string?)
	local raw, read_error = self:_get(self:_registry_key(route_shard(self, route)))
	if read_error ~= nil then
		return nil, read_error
	end
	local registry = as_dict(raw)
	if registry == nil then
		return nil, nil
	end
	if registry.version ~= VERSION or not same_owner(registry.owner, self.owner) then
		return nil, "preparation registry is corrupt or belongs to another owner"
	end
	local entries = as_dict(registry.entries)
	return if entries ~= nil then as_dict(entries[route]) else nil, nil
end

function MailboxV2._reserve(self: Mailbox, route: string, request_text: string, request: Dict, token: string): (Dict?, string?)
	local shard = route_shard(self, route)
	local key = self:_registry_key(shard)
	local maximum = self.options.preparation_max_entries_per_shard :: number
	local entry_size, size_error = self:_encode_size(request)
	if entry_size == nil or entry_size > (self.options.preparation_max_entry_bytes :: number) then
		return nil, size_error or "preparation entry exceeds the configured encoded-size cap"
	end
	local proposed: Dict = {
		route = route,
		token = token,
		request_text = request_text,
		request = clone_json(request),
		phase = "reserved",
		created_at = self:_now(),
		placement_generation = 1,
	}
	local updated, update_error = self:_update(key, function(raw)
		local current = as_dict(raw)
		if current == nil then
			current = {
				version = VERSION,
				owner = clone_owner(self.owner),
				shard = shard,
				entries = {},
			}
		end
		if current.version ~= VERSION or current.shard ~= shard or not same_owner(current.owner, self.owner) then
			return raw
		end
		local entries = as_dict(current.entries)
		if entries == nil then
			return raw
		end
		local existing = as_dict(entries[route])
		if existing ~= nil then
			return raw
		end
		local count = 0
		for _ in entries do
			count += 1
		end
		if count >= maximum then
			return raw
		end
		local next_registry = clone_dict(current)
		local next_entries = clone_dict(entries)
		next_entries[route] = proposed
		next_registry.entries = next_entries
		return next_registry
	end)
	if update_error ~= nil then
		local observed = self:_get_registry_entry(route)
		if observed ~= nil then
			if observed.request_text == request_text then
				return observed, nil
			end
		end
		return nil, "unknown: preparation reservation write may have committed"
	end
	local registry = as_dict(updated)
	local entries = if registry ~= nil then as_dict(registry.entries) else nil
	local existing = if entries ~= nil then as_dict(entries[route]) else nil
	if existing ~= nil then
		if existing.request_text ~= request_text then
			return nil, "conflict: idempotency key is already bound to a different request"
		end
		return existing, nil
	end
	return nil, "capacity: preparation shard is full; no reservation was accepted"
end

function MailboxV2._update_message(self: Mailbox, route: string, transform: (Dict?) -> Dict?): (Dict?, string?)
	local updated, update_error = self:_update(route, function(raw)
		local current = as_dict(raw)
		if current ~= nil and not same_owner(current.owner, self.owner) then
			return raw
		end
		return transform(current)
	end)
	if update_error ~= nil then
		return nil, update_error
	end
	local record = as_dict(updated)
	if record ~= nil and not same_owner(record.owner, self.owner) then
		return nil, "canonical route collision: owner identity mismatch"
	end
	return record, nil
end

function MailboxV2._record_snapshot(self: Mailbox, record: Dict): Dict
	return {
		Id = record.route,
		Type = record.message_type,
		Data = clone_json(record.payload),
		State = record.state,
		Attempts = record.attempts,
		TotalAttempts = record.total_attempts,
		ReplayCount = record.replay_count,
		CreatedAt = record.created_at,
		UpdatedAt = record.updated_at,
		AvailableAt = record.available_at,
		ExpiresAt = record.expires_at,
		Priority = record.priority,
		EffectOutcome = record.effect_outcome,
		LastError = record.last_error,
		CapacityBlocked = record.capacity_blocked == true,
		LeaseUntil = record.locked_until,
		PlacementGeneration = record.placement_generation,
		DeadLetteredAt = record.dead_lettered_at,
	}
end

function MailboxV2._reservation_row(self: Mailbox, entry: Dict): Dict
	return {
		route = entry.route,
		placement_generation = entry.placement_generation,
		reservation_token = entry.token,
	}
end

function MailboxV2._append_at_locator(self: Mailbox, kind: string, locator: Locator, row: Dict): (string, string?)
	local manifest, manifest_error = self:_get_manifest(kind)
	if manifest == nil then
		return "unknown", manifest_error
	end
	local manifest_slot = locate_slot(manifest, locator.slot)
	if manifest_slot == nil or manifest_slot.generation ~= locator.generation then
		return "unknown", "segment locator generation is no longer authoritative"
	end
	if manifest_slot.state ~= "open" then
		local previous, previous_error = self:_get(locator.key)
		local segment = as_dict(previous)
		if previous_error == nil and segment ~= nil
			and segment.generation == locator.generation
			and same_owner(segment.owner, self.owner)
			and has_row(segment, tostring(row.route), row.placement_generation :: number)
			and (manifest_slot.state == "sealed" or manifest_slot.state == "draining")
		then
			return "appended", nil
		end
		return "full", nil
	end
	local maximum = if kind == "active" then self.options.segment_max_messages :: number else self.options.dlq_segment_max_messages :: number
	local updated, update_error = self:_update(locator.key, function(raw)
		local segment = as_dict(raw)
		if segment == nil or segment.version ~= VERSION or segment.kind ~= kind
			or segment.slot ~= locator.slot or segment.generation ~= locator.generation
			or not same_owner(segment.owner, self.owner)
		then
			return raw
		end
		if has_row(segment, tostring(row.route), row.placement_generation :: number) then
			return raw
		end
		if segment.state ~= "open" or type(segment.entries) ~= "table" or #(segment.entries :: { unknown }) >= maximum then
			local sealed = clone_dict(segment)
			sealed.state = "sealed"
			return sealed
		end
		local next_segment = clone_dict(segment)
		local entries = table.clone(segment.entries :: { unknown })
		table.insert(entries, clone_json(row))
		next_segment.entries = entries
		if #entries >= maximum then
			next_segment.state = "sealed"
		end
		return next_segment
	end)
	if update_error ~= nil then
		return "unknown", update_error
	end
	local segment = as_dict(updated)
	if segment == nil or segment.version ~= VERSION or segment.generation ~= locator.generation or not same_owner(segment.owner, self.owner) then
		return "unknown", "segment update could not be verified"
	end
	if has_row(segment, tostring(row.route), row.placement_generation :: number) then
		if segment.state == "sealed" then
			self:_set_slot_state(kind, locator, "open", "sealed")
		end
		return "appended", nil
	end
	if segment.state == "sealed" then
		self:_set_slot_state(kind, locator, "open", "sealed")
		return "full", nil
	end
	return "unknown", "index row is not present after append"
end

function MailboxV2._append_index(self: Mailbox, kind: string, row: Dict): (Locator?, string?)
	local slot_limit = if kind == "active" then self.options.max_segments :: number else self.options.dlq_max_segments :: number
	for _attempt = 1, slot_limit + 2 do
		local locator, open_error = self:_open_segment(kind)
		if locator == nil then
			return nil, open_error
		end
		local status, append_error = self:_append_at_locator(kind, locator, row)
		if status == "appended" then
			return locator, nil
		elseif status == "unknown" then
			return nil, "unknown: " .. (append_error or "index append outcome is unknown")
		end
	end
	return nil, "capacity: no index segment can accept the row"
end

function MailboxV2._contains_index_row(self: Mailbox, kind: string, locator: Locator, route: string, placement: number): boolean
	local value = self:_get(locator.key)
	local segment = as_dict(value)
	return segment ~= nil and segment.generation == locator.generation
		and same_owner(segment.owner, self.owner) and has_row(segment, route, placement)
end

function MailboxV2._locator_from_entry(self: Mailbox, entry: Dict): Locator?
	local locator = as_dict(entry.locator)
	if locator == nil or not is_finite(locator.slot) or not is_finite(locator.generation) then
		return nil
	end
	return {
		slot = locator.slot :: number,
		generation = locator.generation :: number,
		key = self:_segment_key("active", locator.slot :: number, locator.generation :: number),
	}
end

function MailboxV2._resume_reservation(self: Mailbox, route: string, initial_entry: Dict): Result
	local entry = initial_entry
	local request = as_dict(entry.request)
	if request == nil or type(entry.request_text) ~= "string" or type(entry.token) ~= "string" then
		return ok("corrupt", route, nil, "preparation entry is missing its request identity")
	end
	local token = entry.token :: string
	local request_text = entry.request_text :: string
	local locator = self:_locator_from_entry(entry)
	if locator == nil then
		local next_locator, open_error = self:_open_segment("active")
		if next_locator == nil then
			local blocked_entry, _blocked_error = self:_set_registry_entry(route, token, { capacity_blocked = true })
			return ok("unknown", route, nil, open_error or (if blocked_entry ~= nil then "capacity-blocked preparing reservation" else "preparation remains unresolved"))
		end
		local patched, patch_error = self:_set_registry_entry(route, token, {
			locator = { slot = next_locator.slot, generation = next_locator.generation },
			phase = "located",
		})
		if patch_error ~= nil or patched == nil then
			return ok("unknown", route, nil, patch_error or "reservation locator update could not be verified")
		end
		entry = patched
		locator = next_locator
	end
	if locator == nil then
		return ok("unknown", route, nil, "reservation locator is unavailable")
	end
	local placement = if is_finite(entry.placement_generation) then entry.placement_generation :: number else 1

	if entry.phase == "reserved" or entry.phase == "located" then
		local row = self:_reservation_row(entry)
		local appended, append_error = self:_append_at_locator("active", locator, row)
		if appended == "full" then
			local next_locator, next_error = self:_open_segment("active")
			if next_locator == nil then
				local blocked_entry, _blocked_error = self:_set_registry_entry(route, token, { capacity_blocked = true })
				return ok("unknown", route, nil, next_error or (if blocked_entry ~= nil then "capacity-blocked preparing reservation" else "preparation remains unresolved"))
			end
			local next_placement = placement + 1
			local patched, patch_error = self:_set_registry_entry(route, token, {
				locator = { slot = next_locator.slot, generation = next_locator.generation },
				placement_generation = next_placement,
				phase = "located",
			})
			if patch_error ~= nil or patched == nil then
				return ok("unknown", route, nil, patch_error or "reservation retarget could not be verified")
			end
			return self:_resume_reservation(route, patched)
		elseif appended ~= "appended" then
			return ok("unknown", route, nil, append_error or "index append has unknown outcome")
		end
		local patched, patch_error = self:_set_registry_entry(route, token, { phase = "indexed" })
		if patch_error ~= nil or patched == nil then
			return ok("unknown", route, nil, patch_error or "index phase could not be verified")
		end
		entry = patched
		placement = entry.placement_generation :: number
		locator = self:_locator_from_entry(entry) :: Locator
	end

	local current_record_value, current_record_error = self:_get(route)
	if current_record_error ~= nil then
		return ok("unknown", route, nil, "canonical read failed: " .. current_record_error)
	end
	local current_record = as_dict(current_record_value)
	if current_record ~= nil then
		if not same_owner(current_record.owner, self.owner) or current_record.request_text ~= request_text then
			return ok("conflict", route, nil, "canonical route collision or different exact request")
		end
		if TERMINAL[tostring(current_record.state)] then
			-- The canonical terminal state is the durable producer receipt.
			self:_set_registry_entry(route, token, nil, true)
			return ok("duplicate", route, self:_record_snapshot(current_record), nil)
		end
		if current_record.state == "ready" or current_record.state == "claimed" or current_record.state == "acknowledging" then
			local current_locator = as_dict(current_record.locator)
			local same_locator = current_locator ~= nil
				and current_locator.slot == locator.slot
				and current_locator.generation == locator.generation
				and current_record.placement_generation == placement
			if not same_locator or not self:_contains_index_row("active", locator, route, placement) then
				return ok("unknown", route, self:_record_snapshot(current_record), "accepted-state receipt has no verified matching index row; registry retained")
			end
			local cleared, clear_error = self:_set_registry_entry(route, token, nil, true)
			if clear_error ~= nil or cleared ~= nil then
				return ok("duplicate", route, self:_record_snapshot(current_record), nil)
			end
			return ok("unknown", route, self:_record_snapshot(current_record), "registry clear outcome is unknown")
		end
	end

	local preparing_now = self:_now()
	local preparing, preparing_error = self:_update_message(route, function(current)
		if current == nil then
			return {
				version = VERSION,
				owner = clone_owner(self.owner),
				route = route,
				request_text = request_text,
				message_type = request.message_type,
				payload = clone_json(request.payload),
				priority = request.priority,
				available_at = if is_finite(request.available_at) then request.available_at else entry.created_at,
				expires_at = request.expires_at,
				created_at = entry.created_at,
				updated_at = preparing_now,
				attempts = 0,
				total_attempts = 0,
				replay_count = 0,
				state = "preparing",
				reservation_token = token,
				placement_generation = placement,
				locator = { slot = locator.slot, generation = locator.generation },
				effect_outcome = "not_started",
			}
		end
		if current.request_text ~= request_text then
			return current
		end
		if current.state == "preparing" and current.reservation_token == token then
			local next_record = clone_dict(current)
			next_record.locator = { slot = locator.slot, generation = locator.generation }
			next_record.placement_generation = placement
			next_record.updated_at = preparing_now
			return next_record
		end
		return current
	end)
	if preparing_error ~= nil then
		return ok("unknown", route, nil, "canonical preparation write is unknown: " .. preparing_error)
	end
	if preparing == nil or preparing.state ~= "preparing" or preparing.reservation_token ~= token then
		return ok("unknown", route, preparing, "canonical preparing state could not be verified")
	end
	local patched, phase_error = self:_set_registry_entry(route, token, { phase = "canonical" })
	if phase_error ~= nil or patched == nil then
		return ok("unknown", route, nil, phase_error or "preparation phase update is unknown")
	end
	entry = patched
	locator = self:_locator_from_entry(entry) :: Locator
	placement = entry.placement_generation :: number
	if not self:_contains_index_row("active", locator, route, placement) then
		local row = self:_reservation_row(entry)
		local status, index_error = self:_append_at_locator("active", locator, row)
		if status ~= "appended" then
			return ok(if status == "full" then "capacity" else "unknown", route, nil, index_error or "canonical index row is unresolved")
		end
	end
	local ready_now = self:_now()
	local ready, ready_error = self:_update_message(route, function(current)
		if current == nil or not same_owner(current.owner, self.owner) or current.request_text ~= request_text then
			return current
		end
		if current.state == "ready" then
			return current
		end
		if current.state ~= "preparing" or current.reservation_token ~= token then
			return current
		end
		local active_locator = as_dict(current.locator)
		if active_locator == nil or active_locator.slot ~= locator.slot or active_locator.generation ~= locator.generation
			or current.placement_generation ~= placement
		then
			return current
		end
		local next_record = clone_dict(current)
		next_record.state = "ready"
		next_record.updated_at = ready_now
		return next_record
	end)
	if ready_error ~= nil then
		return ok("unknown", route, nil, "ready promotion outcome is unknown: " .. ready_error)
	end
	if ready == nil or ready.state ~= "ready" then
		return ok("unknown", route, ready, "ready state could not be verified")
	end
	if not self:_contains_index_row("active", locator, route, placement) then
		return ok("unknown", route, self:_record_snapshot(ready), "ready record has no verified matching index row")
	end
	self:_set_registry_entry(route, token, nil, true)
	return ok("accepted", route, self:_record_snapshot(ready), nil)
end

function MailboxV2.EnqueueAsync(self: Mailbox, message_type: string, payload: unknown, enqueue_options: Dict?): Result
	if type(message_type) ~= "string" or message_type == "" or #message_type > 100 then
		return ok("invalid", nil, nil, "message_type must be 1 to 100 bytes")
	end
	local options = enqueue_options or {}
	if options.ordering_key ~= nil then
		return ok("invalid", nil, nil, "ordering_key is reserved until strict per-key ordering is implemented")
	end
	local priority = options.priority or "normal"
	if priority ~= "high" and priority ~= "normal" and priority ~= "background" then
		return ok("invalid", nil, nil, "priority must be high, normal or background")
	end
	local available_at = options.available_at or self:_now()
	local expires_at = options.expires_at
	if not is_finite(available_at) or (expires_at ~= nil and (not is_finite(expires_at) or (expires_at :: number) <= (available_at :: number))) then
		return ok("invalid", nil, nil, "available_at and expires_at must be finite milliseconds, with expiry after eligibility")
	end
	local payload_size, payload_error = self:_encode_size(payload)
	if payload_size == nil then
		return ok("invalid", nil, nil, payload_error)
	end
	if payload_size > (self.options.max_payload_bytes :: number) then
		return ok("invalid", nil, nil, "payload exceeds the configured encoded-size cap")
	end
	local route, route_error = self:_route_key(options.idempotency_key)
	if route == nil then
		return ok("invalid", nil, nil, route_error)
	end
	local request: Dict = {
		owner = clone_owner(self.owner),
		idempotency_key = options.idempotency_key,
		message_type = message_type,
		payload = clone_json(payload),
		priority = priority,
		available_at = options.available_at,
		expires_at = expires_at,
	}
	local request_text = canonical(request)
	local request_size, request_size_error = self:_encode_size(request)
	if request_size == nil or request_size > (self.options.max_request_bytes :: number) then
		return ok("invalid", route, nil, request_size_error or "canonical request exceeds the configured size cap")
	end
	if #request_text > (self.options.preparation_max_entry_bytes :: number) then
		return ok("invalid", route, nil, "canonical request is too large for the bounded preparation registry")
	end

	local existing_value, existing_error = self:_get(route)
	if existing_error ~= nil then
		return ok("unknown", route, nil, "canonical status is unavailable: " .. existing_error)
	end
	local existing = as_dict(existing_value)
	if existing ~= nil then
		if not same_owner(existing.owner, self.owner) or existing.request_text ~= request_text then
			return ok("conflict", route, nil, "idempotency route is already bound to a different request or owner")
		end
		if existing.state == "preparing" then
			local entry = self:_get_registry_entry(route)
			if entry ~= nil then
				return self:_resume_reservation(route, entry)
			end
			return ok("unknown", route, self:_record_snapshot(existing), "preparing record has no matching registry entry; quarantined")
		end
		return ok("duplicate", route, self:_record_snapshot(existing), nil)
	end

	local token = if self.options.guid ~= nil then self.options.guid() else digest(route .. request_text .. tostring(self:_now()))
	local entry, reserve_error = self:_reserve(route, request_text, request, token)
	if entry == nil then
		local code = if string.find(reserve_error or "", "capacity", 1, true) then "capacity"
			elseif string.find(reserve_error or "", "conflict", 1, true) then "conflict"
			else "unknown"
		return ok(code, route, nil, reserve_error)
	end
	return self:_resume_reservation(route, entry)
end

function MailboxV2.GetDeliveryAsync(self: Mailbox, message_id: string): (Dict?, Result)
	if type(message_id) ~= "string" or #message_id == 0 or #message_id > MAX_KEY_LENGTH then
		return nil, ok("invalid", message_id, nil, "message_id must be a valid v2 key")
	end
	local raw, read_error = self:_get(message_id)
	if read_error ~= nil then
		return nil, ok("unknown", message_id, nil, read_error)
	end
	local record = as_dict(raw)
	if record ~= nil then
		if not same_owner(record.owner, self.owner) then
			return nil, ok("conflict", message_id, nil, "message key belongs to another owner")
		end
		return self:_record_snapshot(record), ok("success", message_id, nil, nil)
	end
	local entry, entry_error = self:_get_registry_entry(message_id)
	if entry_error ~= nil then
		return nil, ok("unknown", message_id, nil, entry_error)
	end
	if entry ~= nil then
		return {
			Id = message_id,
			State = "preparing",
			Phase = entry.phase,
			CreatedAt = entry.created_at,
			CapacityBlocked = entry.capacity_blocked == true,
		}, ok("preparing", message_id, nil, nil)
	end
	return nil, ok("not_found", message_id, nil, "no canonical message or active preparation is present")
end

function MailboxV2._rows(self: Mailbox, kind: string): ({ Dict }, string?)
	local manifest, manifest_error = self:_get_manifest(kind)
	if manifest == nil then
		return {}, manifest_error
	end
	local result: { Dict } = {}
	for slot_number, raw_slot in manifest.slots :: { unknown } do
		local slot = as_dict(raw_slot)
		if slot ~= nil and (slot.state == "open" or slot.state == "sealed" or slot.state == "draining") then
			local locator: Locator = {
				slot = slot_number,
				generation = slot.generation :: number,
				key = self:_segment_key(kind, slot_number, slot.generation :: number),
			}
			local raw_segment, read_error = self:_get(locator.key)
			local segment = as_dict(raw_segment)
			if read_error ~= nil then
				return result, read_error
			end
			if segment ~= nil and segment.generation == locator.generation and same_owner(segment.owner, self.owner)
				and type(segment.entries) == "table"
			then
				for _, raw_row in segment.entries :: { unknown } do
					local row = as_dict(raw_row)
					if row ~= nil then
						local copied = clone_dict(row)
						copied.locator = { slot = locator.slot, generation = locator.generation }
						table.insert(result, copied)
					end
				end
			end
		end
	end
	return result, nil
end

function MailboxV2.GetQueueAsync(self: Mailbox): ({ Dict }, Result)
	local rows, rows_error = self:_rows("active")
	if rows_error ~= nil then
		return {}, ok("unknown", nil, nil, rows_error)
	end
	local result: { Dict } = {}
	local seen: { [string]: boolean } = {}
	for _, row in rows do
		local route = tostring(row.route)
		local record_value = self:_get(route)
		local record = as_dict(record_value)
		local locator = as_dict(row.locator)
		local record_locator = if record ~= nil then as_dict(record.locator) else nil
		if record ~= nil and same_owner(record.owner, self.owner) and record.state == "ready"
			and record.placement_generation == row.placement_generation and locator ~= nil and record_locator ~= nil
			and locator.slot == record_locator.slot and locator.generation == record_locator.generation
			and not seen[route]
		then
			seen[route] = true
			table.insert(result, self:_record_snapshot(record))
		end
	end
	table.sort(result, function(left, right)
		if left.Priority ~= right.Priority then
			local rank = { high = 1, normal = 2, background = 3 }
			return (rank[tostring(left.Priority)] or 2) < (rank[tostring(right.Priority)] or 2)
		end
		return (left.CreatedAt :: number) < (right.CreatedAt :: number)
	end)
	return result, ok("success", nil, nil, nil)
end

function MailboxV2._finish_acknowledgement(self: Mailbox, route: string, token: string): Result
	local completed_at = self:_now()
	local finished, finish_error = self:_update_message(route, function(current)
		if current == nil or current.state ~= "acknowledging" or current.claim_token ~= token then
			return current
		end
		local next_record = clone_dict(current)
		next_record.state = "acknowledged"
		next_record.updated_at = completed_at
		next_record.terminal_at = completed_at
		next_record.effect_outcome = "handler_succeeded"
		return next_record
	end)
	if finish_error ~= nil then
		return ok("unknown", route, nil, finish_error)
	end
	if finished == nil then
		return ok("unknown", route, nil, "acknowledgement completion could not be verified")
	end
	return ok(if finished.state == "acknowledged" then "processed" else "unknown", route, self:_record_snapshot(finished), nil)
end

function MailboxV2._finish_dead_letter(self: Mailbox, route: string): Result
	local record_value, read_error = self:_get(route)
	local record = as_dict(record_value)
	if read_error ~= nil or record == nil then
		return ok("unknown", route, nil, read_error or "dead-letter source record is missing")
	end
	if record.state == "dead_lettered" then
		return ok("duplicate", route, self:_record_snapshot(record), nil)
	end
	if record.state ~= "dead_lettering" then
		return ok("conflict", route, self:_record_snapshot(record), "record is not in dead_lettering state")
	end
	local placement = if is_finite(record.dlq_placement_generation) then record.dlq_placement_generation :: number else 1
	local locator, index_error = self:_append_index("dlq", {
		route = route,
		placement_generation = placement,
		reservation_token = record.dead_letter_token or route,
	})
	if locator == nil then
		local blocked_at = self:_now()
		local current, _ = self:_update_message(route, function(raw)
			if raw == nil or raw.state ~= "dead_lettering" then
				return raw
			end
			local next_record = clone_dict(raw)
			next_record.capacity_blocked = true
			next_record.updated_at = blocked_at
			return next_record
		end)
		return ok(if string.find(index_error or "", "capacity", 1, true) then "capacity" else "unknown", route, current, index_error)
	end
	local dead_lettered_at = self:_now()
	local terminal, terminal_error = self:_update_message(route, function(raw)
		if raw == nil or raw.state == "dead_lettered" then
			return raw
		end
		if raw.state ~= "dead_lettering" then
			return raw
		end
		local next_record = clone_dict(raw)
		next_record.state = "dead_lettered"
		next_record.dead_lettered_at = dead_lettered_at
		next_record.updated_at = dead_lettered_at
		next_record.capacity_blocked = false
		next_record.dlq_locator = { slot = locator.slot, generation = locator.generation }
		return next_record
	end)
	if terminal_error ~= nil or terminal == nil or terminal.state ~= "dead_lettered" then
		return ok("unknown", route, terminal, terminal_error or "DLQ append committed but terminal status is unknown")
	end
	return ok("dead_lettered", route, self:_record_snapshot(terminal), nil)
end

function MailboxV2._claim(self: Mailbox, route: string): (Dict?, Result)
	local token = if self.options.guid ~= nil then self.options.guid() else digest(route .. tostring(self:_now()) .. tostring(math.random()))
	local now = self:_now()
	local claimed, claim_error = self:_update_message(route, function(current)
		if current == nil or not same_owner(current.owner, self.owner) then
			return current
		end
		if current.state == "acknowledging" then
			return current
		end
		if current.state == "dead_lettering" then
			return current
		end
		if current.state == "ready" and is_finite(current.expires_at) and (current.expires_at :: number) <= now then
			local next_record = clone_dict(current)
			next_record.state = "expired"
			next_record.updated_at = now
			next_record.terminal_at = now
			next_record.effect_outcome = if (current.attempts :: number) > 0 then "handler_failed_or_unknown" else "not_started"
			return next_record
		end
		if current.state == "claimed" and is_finite(current.locked_until)
			and (current.locked_until :: number) + (self.options.clock_skew_grace_ms :: number) > now
		then
			return current
		end
		if current.state ~= "ready" and current.state ~= "claimed" then
			return current
		end
		if current.state == "ready" and (current.available_at :: number) > now then
			return current
		end
		if is_finite(current.expires_at) and (current.expires_at :: number) <= now then
			local next_record = clone_dict(current)
			next_record.state = "expired"
			next_record.updated_at = now
			next_record.terminal_at = now
			next_record.effect_outcome = if (current.attempts :: number) > 0 then "handler_failed_or_unknown" else "not_started"
			return next_record
		end
		if (current.attempts :: number) >= (self.options.max_attempts :: number) then
			local next_record = clone_dict(current)
			next_record.state = "dead_lettering"
			next_record.dead_letter_token = token
			next_record.dlq_placement_generation = 1
			next_record.updated_at = now
			next_record.last_error = current.last_error or "attempt limit reached"
			return next_record
		end
		local next_record = clone_dict(current)
		next_record.state = "claimed"
		next_record.claim_token = token
		next_record.locked_until = now + (self.options.lease_ms :: number)
		next_record.attempts = (current.attempts :: number) + 1
		next_record.total_attempts = (current.total_attempts :: number) + 1
		next_record.updated_at = now
		next_record.effect_outcome = "running"
		return next_record
	end)
	if claim_error ~= nil then
		return nil, ok("unknown", route, nil, "claim outcome is unknown: " .. claim_error)
	end
	if claimed == nil then
		return nil, ok("not_found", route, nil, "message does not exist")
	end
	if claimed.state == "acknowledging" then
		return nil, self:_finish_acknowledgement(route, tostring(claimed.claim_token))
	end
	if claimed.state == "dead_lettering" then
		return nil, self:_finish_dead_letter(route)
	end
	if claimed.state == "expired" then
		return nil, ok("expired", route, self:_record_snapshot(claimed), nil)
	end
	if claimed.state ~= "claimed" or claimed.claim_token ~= token then
		return nil, ok("busy", route, self:_record_snapshot(claimed), nil)
	end
	if (claimed.locked_until :: number) - now <= math.min(2000, (self.options.lease_ms :: number) / 4) then
		return nil, ok("unknown", route, self:_record_snapshot(claimed), "claim has insufficient verified lease margin")
	end
	return claimed, ok("claimed", route, self:_record_snapshot(claimed), nil)
end

function MailboxV2._complete_claim(self: Mailbox, route: string, token: string): Result
	local transition_now = self:_now()
	local transition, transition_error = self:_update_message(route, function(current)
		if current == nil or current.state ~= "claimed" or current.claim_token ~= token then
			return current
		end
		if (current.locked_until :: number) <= transition_now then
			return current
		end
		local next_record = clone_dict(current)
		next_record.state = "acknowledging"
		next_record.updated_at = transition_now
		return next_record
	end)
	if transition_error ~= nil or transition == nil then
		return ok("unknown", route, nil, transition_error or "acknowledgement transition is unresolved")
	end
	if transition.state == "acknowledged" then
		return ok("duplicate", route, self:_record_snapshot(transition), nil)
	end
	if transition.state ~= "acknowledging" or transition.claim_token ~= token then
		return ok("conflict", route, self:_record_snapshot(transition), "claim was fenced before acknowledgement")
	end
	return self:_finish_acknowledgement(route, token)
end

function MailboxV2._retry_claim(self: Mailbox, route: string, token: string, reason: string): Result
	local now = self:_now()
	local updated, update_error = self:_update_message(route, function(current)
		if current == nil or current.state ~= "claimed" or current.claim_token ~= token then
			return current
		end
		local next_record = clone_dict(current)
		next_record.last_error = string.sub(string.gsub(reason, "[^ -~]", "?"), 1, 512)
		next_record.effect_outcome = "handler_failed_or_unknown"
		next_record.updated_at = now
		if is_finite(current.expires_at) and (current.expires_at :: number) <= now then
			next_record.state = "expired"
			next_record.terminal_at = now
			next_record.effect_outcome = "handler_failed_or_unknown"
			next_record.claim_token = nil
			next_record.locked_until = 0
			return next_record
		end
		if (current.attempts :: number) >= (self.options.max_attempts :: number) then
			next_record.state = "dead_lettering"
			next_record.dead_letter_token = token
			next_record.dlq_placement_generation = if is_finite(current.dlq_placement_generation) then current.dlq_placement_generation else 1
			return next_record
		end
		local exponent = math.min(16, math.max(0, (current.attempts :: number) - 1))
		local delay = math.min(self.options.retry_max_ms :: number, (self.options.retry_base_ms :: number) * (2 ^ exponent))
		local jitter = (tonumber(string.sub(digest(route .. ":" .. tostring(current.attempts)), 1, 4), 16) or 0) % math.max(1, math.floor(delay / 4))
		next_record.state = "ready"
		next_record.available_at = now + delay - math.floor(delay / 8) + jitter
		next_record.claim_token = nil
		next_record.locked_until = 0
		return next_record
	end)
	if update_error ~= nil or updated == nil then
		return ok("unknown", route, nil, update_error or "retry state could not be verified")
	end
	if updated.state == "dead_lettering" then
		return self:_finish_dead_letter(route)
	end
	if updated.state == "expired" then
		return ok("expired", route, self:_record_snapshot(updated), nil)
	end
	if updated.state ~= "ready" then
		return ok("conflict", route, self:_record_snapshot(updated), "claim was fenced before retry")
	end
	return ok("retry_scheduled", route, self:_record_snapshot(updated), nil)
end

function MailboxV2.ProcessNextAsync(self: Mailbox, handler: (unknown, Dict) -> (unknown, string?)): Result
	if type(handler) ~= "function" then
		return ok("invalid", nil, nil, "handler must be a function")
	end
	local recovery = self:RecoverAsync()
	if recovery.code ~= "success" and recovery.code ~= "empty" then
		return recovery
	end
	local queue, queue_result = self:GetQueueAsync()
	if queue_result.code ~= "success" then
		return queue_result
	end
	if #queue == 0 then
		return ok("empty", nil, nil, nil)
	end
	local now = self:_now()
	local rank = { high = 1, normal = 2, background = 3 }
	table.sort(queue, function(left, right)
		local left_rank = rank[tostring(left.Priority)] or 2
		local right_rank = rank[tostring(right.Priority)] or 2
		if now - (left.CreatedAt :: number) >= (self.options.priority_aging_ms :: number) then
			left_rank = math.max(1, left_rank - 1)
		end
		if now - (right.CreatedAt :: number) >= (self.options.priority_aging_ms :: number) then
			right_rank = math.max(1, right_rank - 1)
		end
		if left_rank ~= right_rank then
			return left_rank < right_rank
		end
		return (left.CreatedAt :: number) < (right.CreatedAt :: number)
	end)
	for _, candidate in queue do
		local route = tostring(candidate.Id)
		local record, claim_result = self:_claim(route)
		if record ~= nil then
			local snapshot = self:_record_snapshot(record)
			local call_ok, handler_result, handler_error = pcall(handler, clone_json(record.payload), snapshot)
			if call_ok and handler_result ~= false then
				return self:_complete_claim(route, tostring(record.claim_token))
			end
			local reason = if not call_ok then tostring(handler_result) else tostring(handler_error or "handler returned false")
			return self:_retry_claim(route, tostring(record.claim_token), reason)
		elseif claim_result.code == "unknown" or claim_result.code == "capacity" then
			return claim_result
		end
	end
	return ok("empty", nil, nil, nil)
end

function MailboxV2.RecoverAsync(self: Mailbox): Result
	for shard = 1, (self.options.preparation_shard_count :: number) do
		local raw, read_error = self:_get(self:_registry_key(shard))
		if read_error ~= nil then
			return ok("unknown", nil, nil, "preparation recovery read failed: " .. read_error)
		end
		local registry = as_dict(raw)
		if registry ~= nil then
			if registry.version ~= VERSION or registry.shard ~= shard or not same_owner(registry.owner, self.owner) then
				return ok("corrupt", nil, nil, "preparation registry identity/version mismatch")
			end
			local entries = as_dict(registry.entries)
			if entries ~= nil then
				local routes: { string } = {}
				for route in entries do
					table.insert(routes, route)
				end
				table.sort(routes)
				for _, route in routes do
					local entry = self:_get_registry_entry(route)
					if entry ~= nil then
						local result = self:_resume_reservation(route, entry)
						if result.code ~= "accepted" and result.code ~= "duplicate" then
							return result
						end
					end
				end
			end
		end
	end
	local rows, rows_error = self:_rows("active")
	if rows_error ~= nil then
		return ok("unknown", nil, nil, rows_error)
	end
	for _, row in rows do
		local route = tostring(row.route)
		local record_value, read_error = self:_get(route)
		local record = as_dict(record_value)
		if read_error ~= nil then
			return ok("unknown", route, nil, read_error)
		end
		if record ~= nil and same_owner(record.owner, self.owner) then
			if record.state == "acknowledging" then
				local result = self:_finish_acknowledgement(route, tostring(record.claim_token))
				if result.code ~= "processed" and result.code ~= "duplicate" then
					return result
				end
			elseif record.state == "dead_lettering" then
				local result = self:_finish_dead_letter(route)
				if result.code ~= "dead_lettered" and result.code ~= "duplicate" then
					return result
				end
			elseif record.state == "replaying" then
				local generation = record.pending_replay_generation
				local replay_token = tostring(record.replay_operation_id)
				local locator, append_error = self:_append_index("active", {
					route = route,
					placement_generation = generation,
					reservation_token = replay_token,
				})
				if locator == nil then
					return ok("unknown", route, nil, append_error)
				end
				local recovered_at = self:_now()
				local ready, ready_error = self:_update_message(route, function(current)
					if current == nil or current.state ~= "replaying" or current.replay_operation_id ~= replay_token then
						return current
					end
					local next_record = clone_dict(current)
					next_record.state = "ready"
					next_record.placement_generation = generation
					next_record.locator = { slot = locator.slot, generation = locator.generation }
					next_record.updated_at = recovered_at
					next_record.claim_token = nil
					next_record.locked_until = 0
					return next_record
				end)
				if ready_error ~= nil or ready == nil or ready.state ~= "ready" then
					return ok("unknown", route, ready, ready_error or "replay readiness is unknown")
				end
			end
		end
	end
	local dlq_rows, dlq_rows_error = self:_rows("dlq")
	if dlq_rows_error ~= nil then
		return ok("unknown", nil, nil, dlq_rows_error)
	end
	local replay_seen: { [string]: boolean } = {}
	for _, row in dlq_rows do
		local route = tostring(row.route)
		if not replay_seen[route] then
			replay_seen[route] = true
			local record_value = self:_get(route)
			local record = as_dict(record_value)
			if record ~= nil and same_owner(record.owner, self.owner) and record.state == "replaying" then
				local generation = record.pending_replay_generation
				local replay_token = tostring(record.replay_operation_id)
				local locator, append_error = self:_append_index("active", {
					route = route,
					placement_generation = generation,
					reservation_token = replay_token,
				})
				if locator == nil then
					return ok("unknown", route, nil, append_error)
				end
				local recovered_at = self:_now()
				local ready, ready_error = self:_update_message(route, function(current)
					if current == nil or current.state ~= "replaying" or current.replay_operation_id ~= replay_token then
						return current
					end
					local next_record = clone_dict(current)
					next_record.state = "ready"
					next_record.placement_generation = generation
					next_record.locator = { slot = locator.slot, generation = locator.generation }
					next_record.updated_at = recovered_at
					next_record.claim_token = nil
					next_record.locked_until = 0
					return next_record
				end)
				if ready_error ~= nil or ready == nil or ready.state ~= "ready" then
					return ok("unknown", route, ready, ready_error or "replay readiness is unknown")
				end
			end
		end
	end
	return ok("success", nil, nil, nil)
end

function MailboxV2.GetDeadLettersAsync(self: Mailbox, cursor: string?, page_size: number?): ({ Dict }, string?, Result)
	local rows, rows_error = self:_rows("dlq")
	if rows_error ~= nil then
		return {}, nil, ok("unknown", nil, nil, rows_error)
	end
	local messages: { Dict } = {}
	local seen: { [string]: boolean } = {}
	for _, row in rows do
		local route = tostring(row.route)
		if not seen[route] then
			local record_value = self:_get(route)
			local record = as_dict(record_value)
			if record ~= nil and same_owner(record.owner, self.owner) and record.state == "dead_lettered" then
				seen[route] = true
				table.insert(messages, self:_record_snapshot(record))
			end
		end
	end
	table.sort(messages, function(left, right)
		return (left.DeadLetteredAt or left.CreatedAt :: number) > (right.DeadLetteredAt or right.CreatedAt :: number)
	end)
	local offset = 0
	if cursor ~= nil then
		offset = tonumber(cursor) or -1
		if offset < 0 or offset ~= math.floor(offset) then
			return {}, nil, ok("invalid", nil, nil, "cursor must be a non-negative integer string")
		end
	end
	local limit = page_size or 50
	if not is_finite(limit) or limit < 1 or limit > 100 or limit ~= math.floor(limit) then
		return {}, nil, ok("invalid", nil, nil, "page_size must be an integer from 1 to 100")
	end
	local page: { Dict } = {}
	for index = offset + 1, math.min(#messages, offset + limit) do
		table.insert(page, messages[index])
	end
	local next_cursor = if offset + #page < #messages then tostring(offset + #page) else nil
	return page, next_cursor, ok("success", nil, nil, nil)
end

function MailboxV2.ReplayDeadLetterAsync(self: Mailbox, message_id: string, operation_id: string): Result
	local replay_now = self:_now()
	if type(operation_id) ~= "string" or operation_id == "" or #operation_id > 256 then
		return ok("invalid", message_id, nil, "replay operation_id must be 1 to 256 bytes")
	end
	local record, read_error = self:_update_message(message_id, function(current)
		if current == nil or current.state ~= "dead_lettered" then
			return current
		end
		if current.last_replay_operation_id == operation_id then
			return current
		end
		local next_record = clone_dict(current)
		next_record.state = "replaying"
		next_record.last_replay_operation_id = operation_id
		next_record.replay_operation_id = operation_id
		next_record.pending_replay_generation = (current.placement_generation :: number) + 1
		next_record.replay_count = (current.replay_count :: number) + 1
		next_record.updated_at = replay_now
		return next_record
	end)
	if read_error ~= nil or record == nil then
		return ok("unknown", message_id, nil, read_error or "replay reservation is unknown")
	end
	if record.state == "ready" or record.state == "claimed" or record.state == "acknowledging" or record.state == "acknowledged" then
		if record.last_replay_operation_id == operation_id then
			return ok("duplicate", message_id, self:_record_snapshot(record), nil)
		end
	end
	if record.state ~= "replaying" or record.replay_operation_id ~= operation_id then
		return ok("conflict", message_id, self:_record_snapshot(record), "message is not available for replay")
	end
	local locator, append_error = self:_append_index("active", {
		route = message_id,
		placement_generation = record.pending_replay_generation,
		reservation_token = operation_id,
	})
	if locator == nil then
		return ok("unknown", message_id, self:_record_snapshot(record), append_error)
	end
	local ready, ready_error = self:_update_message(message_id, function(current)
		if current == nil or current.state ~= "replaying" or current.replay_operation_id ~= operation_id then
			return current
		end
		local next_record = clone_dict(current)
		next_record.state = "ready"
		next_record.placement_generation = current.pending_replay_generation
		next_record.locator = { slot = locator.slot, generation = locator.generation }
		next_record.claim_token = nil
		next_record.locked_until = 0
		next_record.available_at = replay_now
		next_record.updated_at = replay_now
		return next_record
	end)
	if ready_error ~= nil or ready == nil or ready.state ~= "ready" then
		return ok("unknown", message_id, ready, ready_error or "replay outcome is unknown")
	end
	return ok("accepted", message_id, self:_record_snapshot(ready), nil)
end

function MailboxV2.DiscardDeadLetterAsync(self: Mailbox, message_id: string, expected_replay_count: number): Result
	local discarded_at = self:_now()
	local discarded, discard_error = self:_update_message(message_id, function(current)
		if current == nil or current.state ~= "dead_lettered" or current.replay_count ~= expected_replay_count then
			return current
		end
		local next_record = clone_dict(current)
		next_record.state = "discarded"
		next_record.updated_at = discarded_at
		next_record.terminal_at = discarded_at
		return next_record
	end)
	if discard_error ~= nil or discarded == nil then
		return ok("unknown", message_id, nil, discard_error or "discard result is unknown")
	end
	if discarded.state ~= "discarded" then
		return ok("conflict", message_id, self:_record_snapshot(discarded), "dead letter changed or replay generation no longer matches")
	end
	return ok("discarded", message_id, self:_record_snapshot(discarded), nil)
end

function MailboxV2.GetStatsAsync(self: Mailbox): (Dict, Result)
	local queue, queue_result = self:GetQueueAsync()
	if queue_result.code ~= "success" then
		return {}, queue_result
	end
	local dlq, _, dlq_result = self:GetDeadLettersAsync(nil, 100)
	if dlq_result.code ~= "success" then
		return {}, dlq_result
	end
	local preparing = 0
	for shard = 1, (self.options.preparation_shard_count :: number) do
		local value = self:_get(self:_registry_key(shard))
		local registry = as_dict(value)
		local entries = if registry ~= nil then as_dict(registry.entries) else nil
		if entries ~= nil then
			for _ in entries do
				preparing += 1
			end
		end
	end
	return {
		ready = #queue,
		dead_lettered_page = #dlq,
		preparing_reservations = preparing,
		active_capacity = (self.options.max_segments :: number) * (self.options.segment_max_messages :: number),
		dlq_index_capacity = (self.options.dlq_max_segments :: number) * (self.options.dlq_segment_max_messages :: number),
		preparation_capacity = (self.options.preparation_shard_count :: number) * (self.options.preparation_max_entries_per_shard :: number),
		rtbf_keyed_by_user_id = self.owner.user_id ~= nil,
	}, ok("success", nil, nil, nil)
end

function MailboxV2.ReclaimAsync(self: Mailbox): Result
	local reclaimed_active = self:_reclaim_slot("active")
	local reclaimed_dlq = self:_reclaim_slot("dlq")
	return ok(if reclaimed_active or reclaimed_dlq then "success" else "empty", nil, nil, nil)
end

-- Small deterministic store model for Lune tests. Production code must pass a real DataStore.
local MockStore = {}
MockStore.__index = MockStore

function MockStore.new()
	return setmetatable({
		values = {},
		update_calls = 0,
		get_calls = 0,
		remove_calls = 0,
		fail_next_mode = nil,
		replay_next_update = 0,
	}, MockStore)
end

function MockStore:GetAsync(key: string): unknown
	self.get_calls += 1
	return clone_json(self.values[key])
end

function MockStore:UpdateAsync(key: string, transform: (unknown, unknown?) -> unknown): unknown
	self.update_calls += 1
	if self.fail_next_mode == "before" then
		self.fail_next_mode = nil
		error("injected failure before commit")
	end
	local old_value = clone_json(self.values[key])
	local proposed = transform(clone_json(old_value), nil)
	if self.replay_next_update > 0 then
		self.replay_next_update -= 1
		proposed = transform(clone_json(old_value), nil)
	end
	if proposed ~= nil then
		self.values[key] = clone_json(proposed)
	end
	local result = clone_json(self.values[key])
	if self.fail_next_mode == "after" then
		self.fail_next_mode = nil
		error("injected response loss after commit")
	end
	return result
end

function MockStore:RemoveAsync(key: string)
	self.remove_calls += 1
	self.values[key] = nil
end

function MockStore:FailNextUpdate(mode: string)
	assert(mode == "before" or mode == "after", "mode must be before or after")
	self.fail_next_mode = mode
end

function MockStore:ReplayNextUpdate()
	self.replay_next_update += 1
end

function MailboxV2.MockStore()
	return MockStore.new()
end

MailboxV2.Version = VERSION

return MailboxV2
