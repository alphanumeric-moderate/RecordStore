--!strict
--!optimize 2

local MailboxV2 = {}
MailboxV2.__index = MailboxV2

type Dict = { [string]: unknown }
type Owner = {
	store_name: string,
	scope: string,
	profile_key: string,
	user_id: number?,
}
type ActiveRecordLike = {
	GetIdentity: (self: ActiveRecordLike) -> Dict,
	IsOpen: (self: ActiveRecordLike) -> boolean,
	GetState: (self: ActiveRecordLike) -> string,
	Stats: (self: ActiveRecordLike) -> Dict,
}
type StoreAdapter = {
	GetAsync: (self: StoreAdapter, key: string) -> unknown,
	GetAsyncFresh: ((self: StoreAdapter, key: string) -> unknown)?,
	UpdateAsync: (self: StoreAdapter, key: string, transform: (unknown, unknown?) -> (unknown, { number }?, Dict?)) -> unknown,
	RemoveAsync: ((self: StoreAdapter, key: string) -> ())?,
}
type WakeupAdapter = {
	Publish: (self: WakeupAdapter, owner_identity: string, reason: string) -> Dict,
}
type Options = {
	active_record: ActiveRecordLike?,
	wakeups: WakeupAdapter?,
	sender_job_id: string?,
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
	lease_renewal_horizon_ms: number?,
	clock_skew_grace_ms: number?,
	max_attempts: number?,
	retry_base_ms: number?,
	retry_max_ms: number?,
	priority_aging_ms: number?,
	high_priority_burst: number?,
	strict_ordering_enabled: boolean?,
	lease_renewal_scheduler: ((string, number, number, () -> unknown, (unknown) -> ()) -> unknown)?,
	activation_guard: ((string) -> (boolean, string?))?,
	allow_unattested_activation: boolean?,
}
type Locator = { slot: number, generation: number, key: string }
type Result = {
	code: string,
	message_id: string?,
	message: Dict?,
	error: string?,
}
type HandlerContext = {
	is_cancelled: () -> boolean,
	cancellation_reason: () -> string?,
	renew_lease_async: () -> Result,
}
type Mailbox = typeof(setmetatable({} :: {
	store: StoreAdapter,
	owner: Owner,
	owner_text: string,
	sender_job_id: string,
	options: Options,
	processing: boolean,
	high_priority_streak: number,
	wakeup_published: number,
	wakeup_publish_errors: number,
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
local DEFAULT_HIGH_PRIORITY_BURST = 4
local MAX_ORDERING_KEY_LENGTH = 256

local resolved_task_api = false
local cached_task_api: any = nil
local function task_api(): any
	if resolved_task_api then return cached_task_api end
	resolved_task_api = true
	local global_ok, global_value = pcall(function() return task end)
	if global_ok and type(global_value) == "table"
		and type(global_value.spawn) == "function" and type(global_value.wait) == "function"
	then
		cached_task_api = global_value
		return cached_task_api
	end
	local module_ok, module_value = pcall(require, "@lune/task")
	if module_ok and type(module_value) == "table"
		and type(module_value.spawn) == "function" and type(module_value.wait) == "function"
	then
		cached_task_api = module_value
	end
	return cached_task_api
end
local function spawn_scheduled(callback: () -> ())
	local api = task_api()
	if api ~= nil then api.spawn(callback) else callback() end
end
local function wait_scheduled(seconds: number)
	local api = task_api()
	if api ~= nil then api.wait(seconds) end
end

local TERMINAL = {
	acknowledged = true,
	dead_lettered = true,
	discarded = true,
	expired = true,
}

local function is_finite(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function valid_text(value: unknown, maximum: number): boolean
	return type(value) == "string" and value ~= "" and #value <= maximum
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
	local result: { [string | number]: unknown } = {}
	for key, child in value :: any do
		if type(key) ~= "string" and (type(key) ~= "number" or not is_finite(key)) then
			error("JSON object keys must be strings and array keys must be finite numbers", 2)
		end
		local result_key: string | number = if type(key) == "string" then key else key :: number
		result[result_key] = clone_json(child, level + 1)
	end
	return result
end

local function canonical(value: unknown, stack: { [any]: boolean }?, depth: number?): string
	local active: { [any]: boolean } = stack or {}
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
		local number_value = value :: number
		if not is_finite(number_value) then error("non-finite numbers are not valid mailbox payloads", 2) end
		return "d" .. (if number_value == 0 then "0" else string.format("%.17g", number_value))
	elseif kind == "string" then
		local string_value = value :: string
		return "s" .. tostring(#string_value) .. ":" .. string_value
	elseif kind ~= "table" then
		error("mailbox values must contain only JSON-compatible scalars and tables", 2)
	end

	local table_value = value :: { [string | number]: unknown }
	if active[table_value] then
		error("cyclic tables are not valid mailbox payloads", 2)
	end
	active[table_value] = true
	local source: { [string | number]: unknown } = table_value
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
	local success, value = pcall(function()
		return DateTime.now().UnixTimestampMillis
	end)
	if success and is_finite(value) then
		return value
	end
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
	return {
		store_name = value.store_name :: string,
		scope = value.scope :: string,
		profile_key = value.profile_key :: string,
		user_id = value.user_id :: number?,
	}, nil
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
	if options.now_ms ~= nil and type(options.now_ms) ~= "function" then
		error("options.now_ms must be a function returning finite milliseconds", 2)
	end
	if options.guid ~= nil and type(options.guid) ~= "function" then
		error("options.guid must be a function returning a non-empty string of at most 256 bytes", 2)
	end
	if options.lease_renewal_scheduler ~= nil and type(options.lease_renewal_scheduler) ~= "function" then
		error("options.lease_renewal_scheduler must be a function", 2)
	end
	if type(options.encode) ~= "function" then
		error("options.encode must provide the exact serialized representation used by the DataStore adapter", 2)
	end
	if type(options.activation_guard) ~= "function" and options.allow_unattested_activation ~= true then
		error("mailbox v2 requires activation_guard; allow_unattested_activation=true is reserved for isolated tests or explicitly unsafe staging", 2)
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
	options.lease_renewal_horizon_ms = options.lease_renewal_horizon_ms or (options.lease_ms :: number) * 4
	options.clock_skew_grace_ms = options.clock_skew_grace_ms or DEFAULT_CLOCK_SKEW_GRACE_MS
	options.max_attempts = options.max_attempts or DEFAULT_MAX_ATTEMPTS
	options.retry_base_ms = options.retry_base_ms or DEFAULT_RETRY_BASE_MS
	options.retry_max_ms = options.retry_max_ms or DEFAULT_RETRY_MAX_MS
	options.priority_aging_ms = options.priority_aging_ms or DEFAULT_PRIORITY_AGING_MS
	if options.high_priority_burst == nil then
		options.high_priority_burst = DEFAULT_HIGH_PRIORITY_BURST
	end
	if options.strict_ordering_enabled ~= nil and type(options.strict_ordering_enabled) ~= "boolean" then
		error("strict_ordering_enabled must be a boolean", 2)
	end
	options.strict_ordering_enabled = options.strict_ordering_enabled == true
	if options.strict_ordering_enabled and type((store :: Dict).GetAsyncFresh) ~= "function" then
		error("strict_ordering_enabled requires store:GetAsyncFresh(key) to bypass stale DataStore caches", 2)
	end
	local numeric_options = {
		"max_segments", "segment_max_messages", "max_payload_bytes", "max_request_bytes",
		"preparation_shard_count", "preparation_max_entries_per_shard", "preparation_max_entry_bytes",
		"dlq_max_segments", "dlq_segment_max_messages", "lease_ms", "lease_renewal_horizon_ms", "clock_skew_grace_ms",
		"max_attempts", "retry_base_ms", "retry_max_ms", "priority_aging_ms", "high_priority_burst",
	}
	for _, key in numeric_options do
		local value = ((options :: unknown) :: Dict)[key]
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
	if (options.lease_renewal_horizon_ms :: number) < (options.lease_ms :: number) then
		error("lease_renewal_horizon_ms must be at least lease_ms", 2)
	end
	if (options.high_priority_burst :: number) > 32 then
		error("high_priority_burst may not exceed 32", 2)
	end
	local sender_job_id = options.sender_job_id
	if sender_job_id == nil then
		local job_ok, job_id = pcall(function() return game.JobId end)
		sender_job_id = if job_ok and type(job_id) == "string" then job_id else ""
	end
	if type(sender_job_id) ~= "string" or #sender_job_id > 128 then error("sender_job_id must be a string of at most 128 bytes", 2) end
	local self = {
		store = store :: StoreAdapter,
		owner = owner,
		owner_text = canonical(owner),
		sender_job_id = sender_job_id,
		options = options,
		processing = false,
		high_priority_streak = 0,
		wakeup_published = 0,
		wakeup_publish_errors = 0,
	}
	return setmetatable(self, MailboxV2) :: Mailbox
end


function MailboxV2._check_activation(self: Mailbox, operation: string): Result?
	if self.options.allow_unattested_activation == true then return nil end
	local guard = self.options.activation_guard
	if type(guard) ~= "function" then
		return ok("disabled", nil, nil, "mailbox v2 has no authoritative rollout activation guard")
	end
	local call_ok, allowed, message = pcall(guard, operation)
	if not call_ok then
		return ok("unknown", nil, nil, "rollout activation guard failed: " .. tostring(allowed))
	end
	if allowed ~= true then
		return ok("disabled", nil, nil, tostring(message or ("rollout gate denied " .. operation)))
	end
	return nil
end

function MailboxV2._now(self: Mailbox): number
	local value = if self.options.now_ms ~= nil then self.options.now_ms() else now_default()
	if not is_finite(value) then
		error("options.now_ms must return finite milliseconds", 2)
	end
	return value
end

function MailboxV2._guid(self: Mailbox): (string?, string?)
	local value
	if self.options.guid == nil then
		local call_ok, generated = pcall(function()
			return game:GetService("HttpService"):GenerateGUID(false)
		end)
		if not call_ok then
			return nil, "HttpService:GenerateGUID(false) failed: " .. tostring(generated)
		end
		value = generated
	else
		local call_ok, generated = pcall(self.options.guid)
		if not call_ok then
			return nil, "options.guid raised: " .. tostring(generated)
		end
		value = generated
	end
	if type(value) ~= "string" or value == "" or #value > 256 then
		return nil, "GUID provider must return a non-empty string of at most 256 bytes"
	end
	return value, nil
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

function MailboxV2._get_fresh(self: Mailbox, key: string): (unknown, string?)
	local fresh_get = self.store.GetAsyncFresh
	if type(fresh_get) ~= "function" then
		return nil, "store does not provide an authoritative uncached read"
	end
	local success, value = pcall(function()
		return (fresh_get :: (any, string) -> unknown)(self.store, key)
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
	local guid, guid_error = self:_guid()
	if guid == nil then
		return nil, guid_error
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

	local function release_draining_slot(slot_number: number, generation: number): boolean
		local updated, update_error = self:_update(self:_manifest_key(kind), function(raw)
			local current = as_dict(raw)
			if current == nil or current.version ~= VERSION or not same_owner(current.owner, self.owner) then
				return raw
			end
			local next_manifest = clone_dict(current)
			local slot = locate_slot(next_manifest, slot_number)
			if slot == nil or slot.generation ~= generation or slot.state ~= "draining" then
				return raw
			end
			local next_slot = clone_dict(slot)
			next_slot.state = "empty"
			next_slot.allocation_token = nil
			(next_manifest.slots :: { unknown })[slot_number] = next_slot
			return next_manifest
		end)
		if update_error ~= nil then
			return false
		end
		local next_manifest = as_dict(updated)
		local next_slot = if next_manifest ~= nil then locate_slot(next_manifest, slot_number) else nil
		return next_slot ~= nil and next_slot.generation == generation and next_slot.state == "empty"
	end

	local function rows_are_safe(segment: Dict, locator: Locator): boolean
		local entries = segment.entries
		if type(entries) ~= "table" then
			return false
		end
		for _, raw_row in entries :: { unknown } do
			local row = as_dict(raw_row)
			if row == nil then
				return false
			end
			local record_value, record_error = self:_get(tostring(row.route))
			local record = as_dict(record_value)
			if record_error ~= nil or record == nil or not same_owner(record.owner, self.owner) then
				return false
			end
			if kind == "active" then
				local active_locator = as_dict(record.locator)
				local row_is_stale = record.placement_generation ~= row.placement_generation
					or active_locator == nil
					or active_locator.slot ~= locator.slot
					or active_locator.generation ~= locator.generation
				if not row_is_stale
					and record.state ~= "acknowledged"
					and record.state ~= "dead_lettered"
					and record.state ~= "discarded"
					and record.state ~= "expired"
				then
					return false
				end
			elseif record.state == "replaying"
				or (record.state == "dead_lettered" and record.dlq_placement_generation == row.placement_generation)
			then
				return false
			end
		end
		return true
	end

	for slot_number, raw_slot in slots do
		local slot = as_dict(raw_slot)
		if slot ~= nil and (slot.state == "sealed" or slot.state == "draining") then
			local generation = slot.generation :: number
			local locator: Locator = {
				slot = slot_number,
				generation = generation,
				key = self:_segment_key(kind, slot_number, generation),
			}
			local segment_value, segment_error = self:_get(locator.key)
			if segment_error ~= nil then
				return false
			end
			local segment = as_dict(segment_value)

			if slot.state == "draining" and segment == nil then
				if release_draining_slot(slot_number, generation) then
					return true
				end
				return false
			end
			if segment == nil
				or segment.generation ~= generation
				or not same_owner(segment.owner, self.owner)
				or (segment.state ~= "sealed" and segment.state ~= "retired")
			then
				continue
			end

			local safe = segment.state == "retired" or rows_are_safe(segment, locator)
			if not safe then
				continue
			end
			if slot.state == "sealed" then
				if not self:_set_slot_state(kind, locator, "sealed", "draining") then
					continue
				end
			end

			if segment.state == "sealed" then
				local retired, retire_error = self:_update(locator.key, function(raw)
					local current = as_dict(raw)
					if current == nil or current.generation ~= generation or current.state ~= "sealed"
						or not same_owner(current.owner, self.owner)
					then
						return raw
					end
					local next_segment = clone_dict(current)
					next_segment.state = "retired"
					return next_segment
				end)
				local retired_segment = as_dict(retired)
				if retire_error ~= nil or retired_segment == nil
					or retired_segment.generation ~= generation or retired_segment.state ~= "retired"
				then
					return false
				end
			end

			local storage_remove = self.store.RemoveAsync
			if storage_remove == nil then
				return false
			end
			pcall(function()
				storage_remove(self.store, locator.key)
			end)
			local after_remove, verify_error = self:_update(locator.key, function(raw)
				return raw
			end)
			if verify_error ~= nil or after_remove ~= nil then
				return false
			end
			if release_draining_slot(slot_number, generation) then
				return true
			end
			return false
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
		local token, generation_error = self:_guid()
		if token == nil then return nil, generation_error end
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
		sender_job_id = self.sender_job_id,
		phase = "reserved",
		created_at = self:_now(),
		placement_generation = 1,
	}
	local updated, update_error = self:_update(key, function(raw)
		local current = as_dict(raw)
		if current == nil then
			current = ({
				version = VERSION,
				owner = clone_owner(self.owner),
				shard = shard,
				entries = {},
			} :: unknown) :: Dict
		end
		assert(current ~= nil)
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
		SenderJobId = if type(record.sender_job_id) == "string" then record.sender_job_id else "",
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
		ClaimStartedAt = record.claim_started_at,
		OrderingKey = record.ordering_key,
		OrderingSequence = record.ordering_sequence,
		PlacementGeneration = record.placement_generation,
		DeadLetteredAt = record.dead_lettered_at,
	}
end

local function valid_scheduling_record(record: Dict, route: string): (boolean, string?)
	if type(record.route) ~= "string" or record.route ~= route then
		return false, "canonical route does not match its index entry"
	end
	if type(record.message_type) ~= "string" or record.message_type == "" or #record.message_type > 100 then
		return false, "canonical message type is malformed"
	end
	if record.priority ~= "high" and record.priority ~= "normal" and record.priority ~= "background" then
		return false, "canonical priority is malformed"
	end
	local attempts = record.attempts
	local total_attempts = record.total_attempts
	local replay_count = record.replay_count
	if not is_finite(attempts) or (attempts :: number) < 0 or math.floor(attempts :: number) ~= attempts
		or not is_finite(total_attempts) or (total_attempts :: number) < (attempts :: number)
		or math.floor(total_attempts :: number) ~= total_attempts
		or not is_finite(replay_count) or (replay_count :: number) < 0
		or math.floor(replay_count :: number) ~= replay_count
	then
		return false, "canonical retry counters are malformed"
	end
	local created_at = record.created_at
	local updated_at = record.updated_at
	local available_at = record.available_at
	local expires_at = record.expires_at
	if not is_finite(created_at) or not is_finite(updated_at) or not is_finite(available_at)
		or (expires_at ~= nil and (not is_finite(expires_at) or (expires_at :: number) <= (available_at :: number)))
	then
		return false, "canonical scheduling times are malformed"
	end
	local placement = record.placement_generation
	if not is_finite(placement) or (placement :: number) < 1 or math.floor(placement :: number) ~= placement then
		return false, "canonical placement generation is malformed"
	end
	if record.ordering_key == nil then
		if record.ordering_sequence ~= nil then
			return false, "canonical ordering sequence exists without an ordering_key"
		end
	elseif type(record.ordering_key) ~= "string" or record.ordering_key == ""
		or #record.ordering_key > MAX_ORDERING_KEY_LENGTH
		or not is_finite(record.ordering_sequence) or (record.ordering_sequence :: number) < 1
		or math.floor(record.ordering_sequence :: number) ~= record.ordering_sequence
		or (record.ordering_sequence :: number) > 9_007_199_254_740_991
	then
		return false, "canonical ordering metadata is malformed"
	end
	if record.state == "claimed" then
		if type(record.claim_token) ~= "string" or record.claim_token == "" or #record.claim_token > 256
			or not is_finite(record.claim_started_at) or not is_finite(record.locked_until)
			or (record.locked_until :: number) <= (record.claim_started_at :: number)
		then
			return false, "canonical claim lease metadata is malformed"
		end
	end
	return true, nil
end

function MailboxV2._ordering_route(self: Mailbox, ordering_key: string): string
	return result_route_key(self, "m2o-", "ordering:" .. ordering_key)
end

local function valid_ordering_routes(routes: Dict, next_sequence: unknown): boolean
	if not is_finite(next_sequence) then return false end
	local next_value = next_sequence :: number
	if next_value < 1 or next_value > 9_007_199_254_740_991
		or math.floor(next_value) ~= next_value
	then
		return false
	end
	local sequence_routes = {}
	for route, sequence in routes do
		if type(route) ~= "string" or route == "" or #route > MAX_KEY_LENGTH
			or not is_finite(sequence)
		then
			return false
		end
		local value = sequence :: number
		if value < 1 or value >= next_value or math.floor(value) ~= value
			or sequence_routes[value] ~= nil
		then
			return false
		end
		sequence_routes[value] = route
	end
	return true
end

function MailboxV2._ensure_ordering_slot(self: Mailbox, route: string, ordering_key: string?): (number?, string?)
	if ordering_key == nil then return nil, nil end
	local ordering_route = self:_ordering_route(ordering_key)
	local updated_at = self:_now()
	local updated, update_error = self:_update(ordering_route, function(raw)
		local current = as_dict(raw)
		if current == nil then
			current = ({
				version = VERSION,
				owner = clone_owner(self.owner),
				ordering_key = ordering_key,
				next_sequence = 1,
				routes = {},
			} :: unknown) :: Dict
		end
		assert(current ~= nil)
		if current.version ~= VERSION or not same_owner(current.owner, self.owner)
			or current.ordering_key ~= ordering_key
		then
			return raw
		end
		local routes = as_dict(current.routes)
		if routes == nil or not valid_ordering_routes(routes, current.next_sequence) then return raw end
		local existing = routes[route]
		if existing ~= nil then
			return current
		end
		local next_sequence = current.next_sequence :: number
		if next_sequence >= 9_007_199_254_740_991 then
			return raw
		end
		local next_record = clone_dict(current)
		local next_routes = clone_dict(routes)
		next_routes[route] = next_sequence
		next_record.routes = next_routes
		next_record.next_sequence = (next_sequence :: number) + 1
		next_record.updated_at = updated_at
		return next_record
	end)
	if update_error ~= nil or updated == nil then
		local latest_value, read_error = self:_get_fresh(ordering_route)
		local latest = as_dict(latest_value)
		local routes = if latest ~= nil then as_dict(latest.routes) else nil
		local sequence = if routes ~= nil then routes[route] else nil
		if read_error == nil and latest ~= nil and latest.version == VERSION
			and same_owner(latest.owner, self.owner) and latest.ordering_key == ordering_key
			and routes ~= nil and valid_ordering_routes(routes, latest.next_sequence)
			and is_finite(sequence)
		then
			return sequence :: number, nil
		end
		return nil, "ordering sequence reservation is unresolved: " .. tostring(update_error or read_error or "no durable sequence")
	end
	local record = as_dict(updated)
	local routes = if record ~= nil then as_dict(record.routes) else nil
	local sequence = if routes ~= nil then routes[route] else nil
	if record == nil or record.version ~= VERSION or not same_owner(record.owner, self.owner)
		or record.ordering_key ~= ordering_key or routes == nil
		or not valid_ordering_routes(routes, record.next_sequence) or not is_finite(sequence)
	then
		return nil, "ordering sequence reservation could not be verified"
	end
	return sequence :: number, nil
end

function MailboxV2._release_ordering_slot(
	self: Mailbox,
	route: string,
	ordering_key: unknown,
	expected_sequence: number?
): boolean
	if type(ordering_key) ~= "string" or ordering_key == "" then return true end
	local ordering_route = self:_ordering_route(ordering_key)
	local released_at = self:_now()
	local updated, update_error = self:_update(ordering_route, function(raw)
		local current = as_dict(raw)
		if current == nil or not same_owner(current.owner, self.owner)
			or current.ordering_key ~= ordering_key
		then
			return raw
		end
		local routes = as_dict(current.routes)
		local route_sequence = if routes ~= nil then routes[route] else nil
		if routes == nil or route_sequence == nil
			or (expected_sequence ~= nil and route_sequence ~= expected_sequence)
		then
			return current
		end
		local next_record = clone_dict(current)
		local next_routes = clone_dict(routes)
		next_routes[route] = nil
		next_record.routes = next_routes
		local replay_operations = if current.replay_operations == nil then {} else as_dict(current.replay_operations)
		if replay_operations ~= nil then
			local replay_entry = as_dict(replay_operations[route])
			if replay_entry == nil or replay_entry.sequence == route_sequence then
				local next_replay_operations = clone_dict(replay_operations)
				next_replay_operations[route] = nil
				next_record.replay_operations = next_replay_operations
			end
		end
		next_record.updated_at = released_at
		return next_record
	end)
	if update_error ~= nil or updated == nil then
		local latest_value, read_error = self:_get_fresh(ordering_route)
		local latest = as_dict(latest_value)
		local routes = if latest ~= nil then as_dict(latest.routes) else nil
		local latest_sequence = if routes ~= nil then routes[route] else nil
		return read_error == nil and latest ~= nil and latest.version == VERSION
			and same_owner(latest.owner, self.owner) and latest.ordering_key == ordering_key
			and routes ~= nil and valid_ordering_routes(routes, latest.next_sequence)
			and (latest_sequence == nil or (expected_sequence ~= nil and latest_sequence ~= expected_sequence))
	end
	local record = as_dict(updated)
	local routes = if record ~= nil then as_dict(record.routes) else nil
	local latest_sequence = if routes ~= nil then routes[route] else nil
	return record ~= nil and same_owner(record.owner, self.owner)
		and (latest_sequence == nil or (expected_sequence ~= nil and latest_sequence ~= expected_sequence))
end

function MailboxV2._reserve_replay_ordering_slot(
	self: Mailbox,
	route: string,
	ordering_key: string,
	operation_id: string
): (number?, string?)
	local ordering_route = self:_ordering_route(ordering_key)
	local reserved_at = self:_now()
	local updated, update_error = self:_update(ordering_route, function(raw)
		local current = as_dict(raw)
		if current == nil then
			current = ({
				version = VERSION,
				owner = clone_owner(self.owner),
				ordering_key = ordering_key,
				next_sequence = 1,
				routes = {},
				replay_operations = {},
			} :: unknown) :: Dict
		end
		assert(current ~= nil)
		if current.version ~= VERSION or not same_owner(current.owner, self.owner)
			or current.ordering_key ~= ordering_key
		then
			return raw
		end
		local routes = as_dict(current.routes)
		local replay_operations = if current.replay_operations == nil then {} else as_dict(current.replay_operations)
		if routes == nil or replay_operations == nil
			or not valid_ordering_routes(routes, current.next_sequence)
		then
			return raw
		end
		local prior_replay = as_dict(replay_operations[route])
		local current_sequence = routes[route]
		if prior_replay ~= nil and prior_replay.operation_id == operation_id
			and is_finite(prior_replay.sequence) and current_sequence == prior_replay.sequence
		then
			return current
		end
		local next_sequence = current.next_sequence
		if not is_finite(next_sequence) or (next_sequence :: number) < 1
			or math.floor(next_sequence :: number) ~= next_sequence
			or (next_sequence :: number) >= 9_007_199_254_740_991
		then
			return raw
		end
		local next_record = clone_dict(current)
		local next_routes = clone_dict(routes)
		local next_replay_operations = clone_dict(replay_operations)
		next_routes[route] = next_sequence
		next_replay_operations[route] = { operation_id = operation_id, sequence = next_sequence }
		next_record.routes = next_routes
		next_record.replay_operations = next_replay_operations
		next_record.next_sequence = (next_sequence :: number) + 1
		next_record.updated_at = reserved_at
		return next_record
	end)
	if update_error ~= nil or updated == nil then
		return nil, "replay ordering reservation is unresolved: " .. tostring(update_error or "no durable ordering state")
	end
	local record = as_dict(updated)
	local routes = if record ~= nil then as_dict(record.routes) else nil
	local replay_operations = if record ~= nil then as_dict(record.replay_operations) else nil
	local replay_entry = if replay_operations ~= nil then as_dict(replay_operations[route]) else nil
	local sequence = if replay_entry ~= nil then replay_entry.sequence else nil
	if record == nil or record.version ~= VERSION or not same_owner(record.owner, self.owner)
		or record.ordering_key ~= ordering_key or routes == nil
		or not valid_ordering_routes(routes, record.next_sequence) or replay_entry == nil
		or replay_entry.operation_id ~= operation_id or not is_finite(sequence)
		or routes[route] ~= sequence
	then
		return nil, "replay ordering reservation could not be verified"
	end
	return sequence :: number, nil
end

function MailboxV2._ensure_replay_ordering_sequence(
	self: Mailbox,
	route: string,
	operation_id: string,
	record: Dict
): (Dict?, string?)
	local ordering_key = record.ordering_key
	if ordering_key == nil then return record, nil end
	if type(ordering_key) ~= "string" or ordering_key == "" or #ordering_key > MAX_ORDERING_KEY_LENGTH then
		return nil, "replaying message has invalid ordering metadata"
	end
	local sequence, reserve_error = self:_reserve_replay_ordering_slot(route, ordering_key, operation_id)
	if sequence == nil then return nil, reserve_error end
	local updated_at = self:_now()
	local updated, update_error = self:_update_message(route, function(current)
		if current == nil or current.state ~= "replaying" or current.replay_operation_id ~= operation_id
			or current.ordering_key ~= ordering_key
		then
			return current
		end
		if current.ordering_sequence == sequence then return current end
		local next_record = clone_dict(current)
		next_record.ordering_sequence = sequence
		next_record.updated_at = updated_at
		return next_record
	end)
	if update_error ~= nil or updated == nil then
		return nil, "replay message ordering sequence is unresolved: " .. tostring(update_error or "missing canonical record")
	end
	local canonical_record = as_dict(updated)
	if canonical_record == nil or canonical_record.state ~= "replaying"
		or canonical_record.replay_operation_id ~= operation_id
		or canonical_record.ordering_key ~= ordering_key
		or canonical_record.ordering_sequence ~= sequence
	then
		return nil, "replay message ordering sequence could not be verified"
	end
	return canonical_record, nil
end

function MailboxV2._ordering_blocked(self: Mailbox, record: Dict, route: string): (boolean, string?)
	local ordering_key = record.ordering_key
	local sequence = record.ordering_sequence
	if ordering_key == nil then return false, nil end
	if type(ordering_key) ~= "string" or ordering_key == ""
		or #ordering_key > MAX_ORDERING_KEY_LENGTH
		or not is_finite(sequence) or (sequence :: number) < 1
		or math.floor(sequence :: number) ~= sequence
	then
		return true, "ordered message has invalid durable ordering metadata"
	end
	local order_route = self:_ordering_route(ordering_key)
	local ordering_value, read_error = self:_get_fresh(order_route)
	local ordering = as_dict(ordering_value)
	if read_error ~= nil then return true, "ordering state read failed: " .. read_error end
	local routes = if ordering ~= nil then as_dict(ordering.routes) else nil
	local next_sequence = if ordering ~= nil then ordering.next_sequence else nil
	if ordering == nil or ordering.version ~= VERSION or not same_owner(ordering.owner, self.owner)
		or ordering.ordering_key ~= ordering_key or routes == nil
		or not is_finite(next_sequence) or (next_sequence :: number) < 1
		or math.floor(next_sequence :: number) ~= next_sequence
		or (next_sequence :: number) > 9_007_199_254_740_991
		or (next_sequence :: number) <= (sequence :: number)
	then
		return true, "ordering state is missing or corrupt"
	end
	if routes[route] ~= sequence then
		return true, "ordered message does not match its durable ordering slot"
	end
	local sequence_routes = {}
	for prior_route, prior_sequence in routes do
		if type(prior_route) ~= "string" or prior_route == "" or #prior_route > MAX_KEY_LENGTH
			or not is_finite(prior_sequence) or (prior_sequence :: number) < 1
			or math.floor(prior_sequence :: number) ~= prior_sequence
			or (prior_sequence :: number) >= (next_sequence :: number)
		then
			return true, "ordering state contains a malformed route or sequence"
		end
		local prior_route_for_sequence = sequence_routes[prior_sequence]
		if prior_route_for_sequence ~= nil and prior_route_for_sequence ~= prior_route then
			return true, "ordering state assigns one sequence to multiple messages"
		end
		sequence_routes[prior_sequence] = prior_route
		if (prior_sequence :: number) < (sequence :: number) then
			local prior_value, prior_error = self:_get_fresh(prior_route)
			if prior_error ~= nil then return true, "predecessor state read failed: " .. prior_error end
			local prior = as_dict(prior_value)
			if prior == nil or not same_owner(prior.owner, self.owner) then
				return true, "earlier ordered message has no verifiable canonical record"
			end
			if prior.ordering_key ~= ordering_key or prior.ordering_sequence ~= prior_sequence then
				return true, "predecessor does not match its current durable ordering slot"
			end
			if not TERMINAL[tostring(prior.state)] then
				return true, "an earlier message with the same ordering_key is not terminal"
			end
			if type(prior_sequence) == "number" and is_finite(prior_sequence) then
			self:_release_ordering_slot(prior_route, ordering_key, prior_sequence :: number)
		end
		end
	end
	return false, nil
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
	local request_ordering_key = request.ordering_key
	if request_ordering_key ~= nil and (type(request_ordering_key) ~= "string"
		or request_ordering_key == "" or #request_ordering_key > MAX_ORDERING_KEY_LENGTH)
	then
		return ok("corrupt", route, nil, "preparation entry has an invalid ordering_key")
	end
	local ordering_sequence, ordering_error = self:_ensure_ordering_slot(route, request_ordering_key :: string?)
	if ordering_error ~= nil then return ok("unknown", route, nil, ordering_error) end
	local locator = self:_locator_from_entry(entry)
	if locator == nil then
		local next_locator, open_error = self:_open_segment("active")
		if next_locator == nil then
			local blocked_entry, _blocked_error = self:_set_registry_entry(route, token, ({ capacity_blocked = true } :: unknown) :: Dict)
			return ok("unknown", route, nil, open_error or (if blocked_entry ~= nil then "capacity-blocked preparing reservation" else "preparation remains unresolved"))
		end
		local patched, patch_error = self:_set_registry_entry(route, token, ({
			locator = { slot = next_locator.slot, generation = next_locator.generation },
			phase = "located",
		} :: unknown) :: Dict)
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
				local blocked_entry, _blocked_error = self:_set_registry_entry(route, token, ({ capacity_blocked = true } :: unknown) :: Dict)
				return ok("unknown", route, nil, next_error or (if blocked_entry ~= nil then "capacity-blocked preparing reservation" else "preparation remains unresolved"))
			end
			local next_placement = placement + 1
			local patched, patch_error = self:_set_registry_entry(route, token, ({
				locator = { slot = next_locator.slot, generation = next_locator.generation },
				placement_generation = next_placement,
				phase = "located",
			} :: unknown) :: Dict)
			if patch_error ~= nil or patched == nil then
				return ok("unknown", route, nil, patch_error or "reservation retarget could not be verified")
			end
			return self:_resume_reservation(route, patched)
		elseif appended ~= "appended" then
			return ok("unknown", route, nil, append_error or "index append has unknown outcome")
		end
		local patched, patch_error = self:_set_registry_entry(route, token, ({ phase = "indexed" } :: unknown) :: Dict)
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
			return ({
				version = VERSION,
				owner = clone_owner(self.owner),
				route = route,
				request_text = request_text,
				message_type = request.message_type,
				payload = clone_json(request.payload),
				sender_job_id = if type(entry.sender_job_id) == "string" then entry.sender_job_id else "",
				priority = request.priority,
				ordering_key = request_ordering_key,
				ordering_sequence = ordering_sequence,
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
			} :: unknown) :: Dict
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
	local patched, phase_error = self:_set_registry_entry(route, token, ({ phase = "canonical" } :: unknown) :: Dict)
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
	local cleared_entry, clear_error = self:_set_registry_entry(route, token, nil, true)
	if clear_error ~= nil or cleared_entry ~= nil then
		return ok("unknown", route, self:_record_snapshot(ready), clear_error or "preparation registry clear was not verified")
	end
	return ok("accepted", route, self:_record_snapshot(ready), nil)
end


local function publish_after_enqueue(self: Mailbox, result: Result): Result
	if result.code ~= "accepted" and result.code ~= "duplicate" then return result end
	local state = if type(result.message) == "table" then result.message.State else nil
	if state ~= nil and state ~= "ready" then return result end
	local wakeups = self.options.wakeups
	if wakeups == nil then return result end
	local ok, response = pcall(function()
		return wakeups:Publish(self.owner_text, "enqueue")
	end)
	if ok and type(response) == "table" and response.code == "scheduled" then
		self.wakeup_published += 1
	else
		self.wakeup_publish_errors += 1
	end
	return result
end

function MailboxV2.BindWakeups(self: Mailbox, wakeups: unknown): (boolean, string?)
	if type(wakeups) ~= "table" or type((wakeups :: Dict).Publish) ~= "function" then
		return false, "wakeups must expose Publish(owner_identity, reason)"
	end
	self.options.wakeups = wakeups :: WakeupAdapter
	return true, nil
end

function MailboxV2.SetLeaseRenewalScheduler(
	self: Mailbox,
	scheduler: unknown
): (boolean, string?)
	if scheduler ~= nil and type(scheduler) ~= "function" then
		return false, "lease renewal scheduler must be a function or nil"
	end
	self.options.lease_renewal_scheduler = scheduler :: ((string, number, number, () -> unknown, (unknown) -> ()) -> unknown)?
	return true, nil
end

function MailboxV2.GetOwner(self: Mailbox): Owner
	return clone_owner(self.owner)
end

function MailboxV2.GetActiveRecord(self: Mailbox): ActiveRecordLike?
	return self.options.active_record
end

local function verify_active_record(self: Mailbox): (string, string?)
	local record = self.options.active_record
	if record == nil then
		return "fenced", "an active Record must be configured before processing V2 messages"
	end
	local open_ok, is_open = pcall(function() return record:IsOpen() end)
	if not open_ok or is_open ~= true then
		return "fenced", "bound Record is not open"
	end
	local state_ok, record_state = pcall(function() return record:GetState() end)
	if not state_ok or record_state ~= "active" then
		return "fenced", "bound Record is not actively owned"
	end
	local identity_ok, identity = pcall(function() return record:GetIdentity() end)
	if not identity_ok or type(identity) ~= "table" then
		return "fenced", "bound Record identity could not be verified"
	end
	if identity.store_name ~= self.owner.store_name
		or identity.scope ~= self.owner.scope
		or identity.profile_key ~= self.owner.profile_key
	then
		return "fenced", "bound Record identity does not match the V2 mailbox owner"
	end
	local user_ids = identity.user_ids
	if type(user_ids) ~= "table" then
		return "fenced", "bound Record UserIds could not be verified"
	end
	local user_ids_array = user_ids :: { unknown }
	if self.owner.user_id ~= nil then
		local found = false
		for _, user_id in ipairs(user_ids_array) do
			if user_id == self.owner.user_id then found = true; break end
		end
		if not found then return "fenced", "V2 mailbox UserId does not match the bound Record" end
	elseif #user_ids_array > 0 then
		return "fenced", "V2 mailbox owner must include a UserId for this Record"
	end
	local stats_ok, stats = pcall(function() return record:Stats() end)
	if not stats_ok or type(stats) ~= "table" then
		return "fenced", "bound Record session state could not be verified"
	end
	local takeover_requested = stats.takeover_requested
	if takeover_requested == true or (type(takeover_requested) == "number" and takeover_requested > 0) then
		return "closing", "Record session takeover has been requested"
	end
	return "success", nil
end

function MailboxV2.EnqueueAsync(self: Mailbox, message_type: string, payload: unknown, enqueue_options: Dict?): Result
	local activation = self:_check_activation("enqueue")
	if activation ~= nil then return activation end
	if type(message_type) ~= "string" or message_type == "" or #message_type > 100 then
		return ok("invalid", nil, nil, "message_type must be 1 to 100 bytes")
	end
	local options: Dict = enqueue_options or ({} :: Dict)
	local ordering_key = options.ordering_key
	if ordering_key ~= nil and (type(ordering_key) ~= "string" or ordering_key == ""
		or #ordering_key > MAX_ORDERING_KEY_LENGTH)
	then
		return ok("invalid", nil, nil, "ordering_key must be 1 to " .. tostring(MAX_ORDERING_KEY_LENGTH) .. " bytes")
	end
	if ordering_key ~= nil and not self.options.strict_ordering_enabled then
		return ok("invalid", nil, nil, "ordering_key requires strict_ordering_enabled=true")
	end
	local priority = if options.priority == nil then "normal" else options.priority
	if priority ~= "high" and priority ~= "normal" and priority ~= "background" then
		return ok("invalid", nil, nil, "priority must be high, normal or background")
	end
	local available_at = if options.available_at == nil then self:_now() else options.available_at
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
	local idempotency_value = options.idempotency_key
	if idempotency_value ~= nil and type(idempotency_value) ~= "string" then
		return ok("invalid", nil, nil, "idempotency_key must be a string when supplied")
	end
	local idempotency_key: string? = idempotency_value :: string?
	local route, route_error = self:_route_key(idempotency_key)
	if route == nil then
		return ok("invalid", nil, nil, route_error)
	end
	local request: Dict = {
		owner = clone_owner(self.owner),
		idempotency_key = idempotency_key,
		message_type = message_type,
		payload = clone_json(payload),
		priority = priority,
		ordering_key = ordering_key,
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
				return publish_after_enqueue(self, self:_resume_reservation(route, entry))
			end
			return ok("unknown", route, self:_record_snapshot(existing), "preparing record has no matching registry entry; quarantined")
		end
		return publish_after_enqueue(self, ok("duplicate", route, self:_record_snapshot(existing), nil))
	end

	local token, generation_error = self:_guid()
	if token == nil then return ok("invalid", route, nil, generation_error) end
	local entry, reserve_error = self:_reserve(route, request_text, request, token)
	if entry == nil then
		local code = if string.find(reserve_error or "", "capacity", 1, true) then "capacity"
			elseif string.find(reserve_error or "", "conflict", 1, true) then "conflict"
			else "unknown"
		return ok(code, route, nil, reserve_error)
	end
	return publish_after_enqueue(self, self:_resume_reservation(route, entry))
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
		local snapshot = ({
			Id = message_id,
			State = "preparing",
			Phase = entry.phase,
			CreatedAt = entry.created_at,
			CapacityBlocked = entry.capacity_blocked == true,
		} :: unknown) :: Dict
		return snapshot, ok("preparing", message_id, nil, nil)
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
		local record_value, record_error = self:_get(route)
		if record_error ~= nil then
			return {}, ok("unknown", nil, nil, "queue canonical read failed: " .. record_error)
		end
		local record = as_dict(record_value)
		if record_value ~= nil and record == nil then
			return {}, ok("corrupt", nil, nil, "queue index points to a malformed canonical record")
		end
		local locator = as_dict(row.locator)
		local record_locator = if record ~= nil then as_dict(record.locator) else nil
		if record ~= nil and same_owner(record.owner, self.owner) and record.state == "ready"
			and record.placement_generation == row.placement_generation and locator ~= nil and record_locator ~= nil
			and locator.slot == record_locator.slot and locator.generation == record_locator.generation
			and not seen[route]
		then
			local attempts = record.attempts
			local total_attempts = record.total_attempts
			local replay_count = record.replay_count
			local created_at = record.created_at
			local updated_at = record.updated_at
			local available_at = record.available_at
			local expires_at = record.expires_at
			local priority_valid = record.priority == "high" or record.priority == "normal"
				or record.priority == "background"
			local counters_valid = is_finite(attempts) and (attempts :: number) >= 0
				and math.floor(attempts :: number) == attempts
				and is_finite(total_attempts) and (total_attempts :: number) >= (attempts :: number)
				and math.floor(total_attempts :: number) == total_attempts
				and is_finite(replay_count) and (replay_count :: number) >= 0
				and math.floor(replay_count :: number) == replay_count
			local times_valid = is_finite(created_at) and is_finite(updated_at) and is_finite(available_at)
				and (expires_at == nil or (is_finite(expires_at) and (expires_at :: number) > (available_at :: number)))
			local ordering_valid = record.ordering_key == nil and record.ordering_sequence == nil
			if record.ordering_key ~= nil then
				ordering_valid = type(record.ordering_key) == "string" and record.ordering_key ~= ""
					and #record.ordering_key <= MAX_ORDERING_KEY_LENGTH
					and is_finite(record.ordering_sequence) and (record.ordering_sequence :: number) >= 1
					and math.floor(record.ordering_sequence :: number) == record.ordering_sequence
					and (record.ordering_sequence :: number) <= 9_007_199_254_740_991
			end
			if type(record.route) ~= "string" or record.route ~= route
				or type(record.message_type) ~= "string" or record.message_type == "" or #record.message_type > 100
				or not priority_valid or not counters_valid or not times_valid or not ordering_valid
				or not is_finite(record.placement_generation) or (record.placement_generation :: number) < 1
				or math.floor(record.placement_generation :: number) ~= record.placement_generation
			then
				return {}, ok("corrupt", route, nil, "ready mailbox message contains malformed priority, counter, time or ordering metadata")
			end
			seen[route] = true
			table.insert(result, self:_record_snapshot(record))
		end
	end
	local rank = { high = 1, normal = 2, background = 3 }
	table.sort(result, function(left, right)
		local left_rank = rank[tostring(left.Priority)] :: number
		local right_rank = rank[tostring(right.Priority)] :: number
		if left_rank ~= right_rank then return left_rank < right_rank end
		if left.CreatedAt ~= right.CreatedAt then
			return (left.CreatedAt :: number) < (right.CreatedAt :: number)
		end
		return tostring(left.Id) < tostring(right.Id)
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
	if finished.state == "acknowledged" then
		if type(finished.ordering_key) == "string" and is_finite(finished.ordering_sequence) then
			self:_release_ordering_slot(route, finished.ordering_key, finished.ordering_sequence :: number)
		end
		return ok("processed", route, self:_record_snapshot(finished), nil)
	end
	return ok("unknown", route, self:_record_snapshot(finished), "acknowledgement terminal state was not confirmed")
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
	if type(terminal.ordering_key) == "string" and is_finite(terminal.ordering_sequence) then
		self:_release_ordering_slot(route, terminal.ordering_key, terminal.ordering_sequence :: number)
	end
	return ok("dead_lettered", route, self:_record_snapshot(terminal), nil)
end

function MailboxV2._claim(self: Mailbox, route: string): (Dict?, Result)
	local current_value, current_error = self:_get(route)
	if current_error ~= nil then
		return nil, ok("unknown", route, nil, "canonical claim read failed: " .. current_error)
	end
	local current_record = as_dict(current_value)
	if current_record == nil or not same_owner(current_record.owner, self.owner) then
		return nil, ok("not_found", route, nil, "message does not exist")
	end
	if current_record.state == "ready" or current_record.state == "claimed" then
		local blocked, ordering_error = self:_ordering_blocked(current_record, route)
		if blocked then return nil, ok("ordered", route, self:_record_snapshot(current_record), ordering_error) end
	end
	local token, generation_error = self:_guid()
	if token == nil then return nil, ok("invalid", route, nil, generation_error) end
	local now = self:_now()
	local claimed, claim_error = self:_update_message(route, function(current)
		if current == nil or not same_owner(current.owner, self.owner) then
			return current
		end
		if current.state == "ready" or current.state == "claimed" then
			local valid = valid_scheduling_record(current, route)
			if not valid then return current end
		end
		if current.ordering_key ~= current_record.ordering_key
			or current.ordering_sequence ~= current_record.ordering_sequence
		then
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
		next_record.claim_started_at = now
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
	if claimed.state == "ready" or claimed.state == "claimed" then
		local valid, validation_error = valid_scheduling_record(claimed, route)
		if not valid then
			return nil, ok("corrupt", route, nil, validation_error or "canonical scheduling metadata is malformed")
		end
	end
	if claimed.state == "acknowledging" then
		return nil, self:_finish_acknowledgement(route, tostring(claimed.claim_token))
	end
	if claimed.state == "dead_lettering" then
		return nil, self:_finish_dead_letter(route)
	end
	if claimed.state == "expired" then
		if type(claimed.ordering_key) == "string" and is_finite(claimed.ordering_sequence) then
			self:_release_ordering_slot(route, claimed.ordering_key, claimed.ordering_sequence :: number)
		end
		return nil, ok("expired", route, self:_record_snapshot(claimed), nil)
	end
	if claimed.state ~= "claimed" or claimed.claim_token ~= token then
		return nil, ok("busy", route, self:_record_snapshot(claimed), nil)
	end
	local verified_now = self:_now()
	if (claimed.locked_until :: number) - verified_now <= math.min(2000, (self.options.lease_ms :: number) / 4) then
		return nil, ok("unknown", route, self:_record_snapshot(claimed), "claim has insufficient verified lease margin")
	end
	return claimed, ok("claimed", route, self:_record_snapshot(claimed), nil)
end


function MailboxV2.RenewClaimAsync(self: Mailbox, message_id: string, claim_token: string): Result
	if type(message_id) ~= "string" or message_id == "" or #message_id > MAX_KEY_LENGTH then
		return ok("invalid", message_id, nil, "message_id must be a valid v2 key")
	end
	if type(claim_token) ~= "string" or claim_token == "" or #claim_token > 256 then
		return ok("invalid", message_id, nil, "claim_token must be 1 to 256 bytes")
	end

	local now = self:_now()
	local renewal_id, generation_error = self:_guid()
	if renewal_id == nil then return ok("invalid", message_id, nil, generation_error) end
	local renewed, update_error = self:_update_message(message_id, function(current)
		if current == nil or current.state ~= "claimed" or current.claim_token ~= claim_token then
			return current
		end
		if not is_finite(current.claim_started_at) or (current.claim_started_at :: number) > now
			or not is_finite(current.locked_until) or (current.locked_until :: number) <= now
		then
			return current
		end
		local claim_started_at = current.claim_started_at :: number
		local horizon_end = claim_started_at + (self.options.lease_renewal_horizon_ms :: number)
		if now >= horizon_end then
			return current
		end
		local next_lease_until = math.min(now + (self.options.lease_ms :: number), horizon_end)
		local margin = math.min(2000, (self.options.lease_ms :: number) / 4)
		if next_lease_until - now <= margin then
			return current
		end
		local next_record = clone_dict(current)
		next_record.locked_until = next_lease_until
		next_record.lease_renewed_at = now
		next_record.last_renewal_id = renewal_id
		next_record.updated_at = now
		return next_record
	end)

	if update_error ~= nil or renewed == nil then
		local latest_value, read_error = self:_get(message_id)
		local latest = as_dict(latest_value)
		if read_error ~= nil then
			return ok("unknown", message_id, nil, "claim renewal outcome is unknown; verification read failed: " .. read_error)
		end
		if latest == nil or not same_owner(latest.owner, self.owner) then
			return ok("lease_lost", message_id, nil, "claim is missing or belongs to another owner")
		end
		if latest.state == "claimed" and latest.claim_token == claim_token
			and latest.last_renewal_id == renewal_id and is_finite(latest.locked_until)
			and (latest.locked_until :: number) > self:_now()
		then
			return ok("renewed", message_id, self:_record_snapshot(latest), "renewal was committed despite an ambiguous response")
		end
		return ok("unknown", message_id, self:_record_snapshot(latest),
			"claim renewal outcome could not be proven: " .. tostring(update_error or "no canonical record"))
	end

	if renewed.state ~= "claimed" or renewed.claim_token ~= claim_token then
		return ok("lease_lost", message_id, self:_record_snapshot(renewed), "claim token was fenced or the message is no longer claimed")
	end
	if renewed.last_renewal_id ~= renewal_id then
		local started = renewed.claim_started_at
		if is_finite(started) and now >= (started :: number) + (self.options.lease_renewal_horizon_ms :: number) then
			return ok("lease_horizon_reached", message_id, self:_record_snapshot(renewed), "bounded claim-renewal horizon has been reached")
		end
		if is_finite(renewed.locked_until) and (renewed.locked_until :: number) <= now then
			return ok("lease_lost", message_id, self:_record_snapshot(renewed), "claim lease expired before renewal")
		end
		return ok("lease_not_renewed", message_id, self:_record_snapshot(renewed), "claim remained owned but renewal was not applied")
	end
	return ok("renewed", message_id, self:_record_snapshot(renewed), nil)
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
		if type(updated.ordering_key) == "string" and is_finite(updated.ordering_sequence) then
		self:_release_ordering_slot(route, updated.ordering_key, updated.ordering_sequence :: number)
		end
		return ok("expired", route, self:_record_snapshot(updated), nil)
	end
	if updated.state ~= "ready" then
		return ok("conflict", route, self:_record_snapshot(updated), "claim was fenced before retry")
	end
	return ok("retry_scheduled", route, self:_record_snapshot(updated), nil)
end

local function process_next_internal(self: Mailbox, handler: (unknown, Dict, HandlerContext?) -> (unknown, string?)): Result
	if type(handler) ~= "function" then
		return ok("invalid", nil, nil, "handler must be a function")
	end
	local session_code, session_error = verify_active_record(self)
	if session_code ~= "success" then return ok(session_code, nil, nil, session_error) end
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
		local left_age = math.max(0, now - (left.CreatedAt :: number))
		local right_age = math.max(0, now - (right.CreatedAt :: number))
		local left_rank = rank[tostring(left.Priority)] or 2
		local right_rank = rank[tostring(right.Priority)] or 2
		if left_age >= (self.options.priority_aging_ms :: number) * 2 then left_rank = 1
		elseif left_age >= (self.options.priority_aging_ms :: number) then left_rank = math.min(left_rank, 2) end
		if right_age >= (self.options.priority_aging_ms :: number) * 2 then right_rank = 1
		elseif right_age >= (self.options.priority_aging_ms :: number) then right_rank = math.min(right_rank, 2) end
		if self.high_priority_streak >= (self.options.high_priority_burst :: number) then
			if tostring(left.Priority) == "high" then left_rank = 4 end
			if tostring(right.Priority) == "high" then right_rank = 4 end
		end
		if left_rank ~= right_rank then return left_rank < right_rank end
		if left.CreatedAt ~= right.CreatedAt then
			return (left.CreatedAt :: number) < (right.CreatedAt :: number)
		end
		return tostring(left.Id) < tostring(right.Id)
	end)
	for _, candidate in queue do
		local route = tostring(candidate.Id)
		local record, claim_result = self:_claim(route)
		if record ~= nil then
			if tostring(record.priority) == "high" then
				self.high_priority_streak += 1
			else
				self.high_priority_streak = 0
			end
			local session_code_after_claim, session_error_after_claim = verify_active_record(self)
			if session_code_after_claim ~= "success" then
				local released = self:_retry_claim(route, tostring(record.claim_token), "active Record guard changed before handler start: " .. tostring(session_error_after_claim))
				if released.code ~= "retry_scheduled" and released.code ~= "expired" and released.code ~= "dead_lettered" then return released end
				return ok(session_code_after_claim, route, nil, session_error_after_claim)
			end
			local snapshot = self:_record_snapshot(record)
			local token = tostring(record.claim_token)
			local lease_until = record.locked_until :: number
			local lease_lost = false
			local cancellation_reason: string? = nil
			local handler_done = false
			local handler_ok = false
			local handler_result: unknown = nil
			local handler_error: unknown = nil
			local function renew_for_handler(): Result
				if lease_lost then
					return ok("lease_lost", route, nil, cancellation_reason or "claim lease has been lost")
				end
				local renewal: Result
				local renewal_scheduler = self.options.lease_renewal_scheduler
				if type(renewal_scheduler) == "function" then
					local completed = false
					local scheduled_result: Result? = nil
					local lease_remaining_ms = math.max(0, lease_until - self:_now())
					local call_ok, submission = pcall(
						renewal_scheduler,
						route,
						0,
						lease_remaining_ms,
						function(): Result
							return self:RenewClaimAsync(route, token)
						end,
						function(result_value: unknown)
							if type(result_value) == "table" then
								scheduled_result = result_value :: Result
							else
								scheduled_result = ok("unknown", route, nil, "scheduler returned no structured renewal result")
							end
							completed = true
						end
					)
					if not call_ok then
						return ok("unknown", route, nil, "lease renewal scheduler raised: " .. tostring(submission))
					end
					if type(submission) ~= "table" or (submission :: Dict).code ~= "accepted" then
						local reason = if type(submission) == "table" then tostring((submission :: Dict).message or (submission :: Dict).code)
							else "scheduler rejected renewal"
						return ok("unknown", route, nil, "lease renewal was not accepted by the shared scheduler: " .. reason)
					end
					local wait_deadline = os.clock() + math.max(0.01, lease_remaining_ms / 1000)
					while not completed and not lease_lost and os.clock() < wait_deadline do
						wait_scheduled(0.001)
					end
					if not completed then
						return ok("unknown", route, nil, "lease renewal did not complete before the local wait deadline")
					end
					renewal = scheduled_result or ok("unknown", route, nil, "lease renewal completion was missing")
				else
					renewal = self:RenewClaimAsync(route, token)
				end
				if renewal.code == "renewed" then
					local renewed_snapshot = as_dict(renewal.message)
					if renewed_snapshot ~= nil and is_finite(renewed_snapshot.LeaseUntil) then
						lease_until = renewed_snapshot.LeaseUntil :: number
					end
				elseif renewal.code ~= "unknown" and renewal.code ~= "lease_not_renewed" then
					lease_lost = true
					cancellation_reason = renewal.error or renewal.code
				elseif self:_now() >= lease_until then
					lease_lost = true
					cancellation_reason = renewal.error or "claim renewal could not be verified before the last verified lease deadline"
				end
				return renewal
			end
			local context: HandlerContext = {
				is_cancelled = function(): boolean return lease_lost end,
				cancellation_reason = function(): string? return cancellation_reason end,
				renew_lease_async = renew_for_handler,
			}
			spawn_scheduled(function()
				local call_ok, result_value, error_value = pcall(handler, clone_json(record.payload), snapshot, context)
				handler_ok = call_ok
				handler_result = result_value
				handler_error = error_value
				handler_done = true
			end)
			local renewal_interval = math.max(1, math.floor((self.options.lease_ms :: number) / 3))
			while not handler_done do
				wait_scheduled(renewal_interval / 1000)
				if handler_done then break end
				if not lease_lost then
					renew_for_handler()
				end
			end
			if lease_lost then
				return ok("unknown", route, nil, "handler ended after claim lease loss; external effect outcome is uncertain: " .. tostring(cancellation_reason or "claim ownership changed"))
			end
			if handler_ok and handler_result ~= false then
				return self:_complete_claim(route, token)
			end
			local reason = if not handler_ok then tostring(handler_result) else tostring(handler_error or "handler returned false")
			return self:_retry_claim(route, token, reason)
		elseif claim_result.code == "unknown" or claim_result.code == "capacity" or claim_result.code == "corrupt" then
			return claim_result
		end
	end
	return ok("empty", nil, nil, nil)
end

function MailboxV2.ProcessNextAsync(self: Mailbox, handler: (unknown, Dict, HandlerContext?) -> (unknown, string?)): Result
	local activation = self:_check_activation("process")
	if activation ~= nil then return activation end
	if self.processing then return ok("busy", nil, nil, "a ProcessNextAsync call is already running on this mailbox instance") end
	self.processing = true
	local call_ok, result = pcall(process_next_internal, self, handler)
	self.processing = false
	if not call_ok then return ok("unknown", nil, nil, tostring(result)) end
	if type(result) ~= "table" then return ok("unknown", nil, nil, "ProcessNextAsync returned no structured result") end
	return result :: Result
end

function MailboxV2.RecoverAsync(self: Mailbox): Result
	local activation = self:_check_activation("recover")
	if activation ~= nil then return activation end
	local capacity_blocked_preparations = 0
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
							local latest_entry, entry_error = self:_get_registry_entry(route)
							if result.code == "unknown" and entry_error == nil and latest_entry ~= nil and latest_entry.capacity_blocked == true then
								capacity_blocked_preparations += 1
							else
								return result
							end
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
			elseif record.state == "claimed"
				and is_finite(record.locked_until)
				and (record.locked_until :: number) + (self.options.clock_skew_grace_ms :: number) <= self:_now()
			then
				local result = self:_retry_claim(route, tostring(record.claim_token), "claim lease expired; handler outcome is unknown")
				if result.code ~= "retry_scheduled" and result.code ~= "expired" and result.code ~= "dead_lettered" then
					return result
				end
			elseif record.state == "dead_lettering" then
				local result = self:_finish_dead_letter(route)
				if result.code ~= "dead_lettered" and result.code ~= "duplicate" then
					return result
				end
			elseif record.state == "replaying" then
				local replay_token = tostring(record.replay_operation_id)
				local sequenced_record, ordering_error = self:_ensure_replay_ordering_sequence(route, replay_token, record)
				if sequenced_record == nil then
					return ok("unknown", route, nil, ordering_error or "replay ordering recovery is unresolved")
				end
				record = sequenced_record
				local generation = record.pending_replay_generation
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
				local replay_token = tostring(record.replay_operation_id)
				local sequenced_record, ordering_error = self:_ensure_replay_ordering_sequence(route, replay_token, record)
				if sequenced_record == nil then
					return ok("unknown", route, nil, ordering_error or "replay ordering recovery is unresolved")
				end
				record = sequenced_record
				local generation = record.pending_replay_generation
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
	local recovery_metadata: Dict? = if capacity_blocked_preparations > 0
		then ({ capacity_blocked_preparations = capacity_blocked_preparations } :: unknown) :: Dict
		else nil
	return ok("success", nil, recovery_metadata, nil)
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
			local record_value, record_error = self:_get(route)
			if record_error ~= nil then
				return {}, nil, ok("unknown", nil, nil, "dead-letter canonical read failed: " .. record_error)
			end
			local record = as_dict(record_value)
			if record_value ~= nil and record == nil then
				return {}, nil, ok("corrupt", nil, nil, "dead-letter index points to a malformed canonical record")
			end
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
	local activation = self:_check_activation("replay")
	if activation ~= nil then return activation end
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
		next_record.attempts = 0
		next_record.claim_token = nil
		next_record.locked_until = 0
		next_record.last_error = nil
		next_record.effect_outcome = "not_started"
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
	local sequenced_record, ordering_error = self:_ensure_replay_ordering_sequence(message_id, operation_id, record)
	if sequenced_record == nil then
		return ok("unknown", message_id, self:_record_snapshot(record), ordering_error or "replay ordering is unresolved")
	end
	record = sequenced_record
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
	local activation = self:_check_activation("discard")
	if activation ~= nil then return activation end
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
	local dlq, dlq_cursor, dlq_result = self:GetDeadLettersAsync(nil, 100)
	if dlq_result.code ~= "success" then
		return {}, dlq_result
	end
	local preparing = 0
	for shard = 1, (self.options.preparation_shard_count :: number) do
		local value, read_error = self:_get(self:_registry_key(shard))
		if read_error ~= nil then
			return {}, ok("unknown", nil, nil, "preparation registry stats read failed: " .. read_error)
		end
		if value ~= nil then
			local registry = as_dict(value)
			if registry == nil or registry.version ~= VERSION or registry.shard ~= shard
				or not same_owner(registry.owner, self.owner)
			then
				return {}, ok("corrupt", nil, nil, "preparation registry stats row is malformed or belongs to another owner")
			end
			local entries = as_dict(registry.entries)
			if entries == nil then
				return {}, ok("corrupt", nil, nil, "preparation registry entries are malformed")
			end
			for route, raw_entry in entries do
				local entry = as_dict(raw_entry)
				if type(route) ~= "string" or entry == nil or entry.route ~= route
					or not valid_text(entry.token, 128) or not valid_text(entry.phase, 32)
				then
					return {}, ok("corrupt", nil, nil, "preparation registry contains a malformed entry")
				end
				preparing += 1
			end
		end
	end
	local active_capacity = (self.options.max_segments :: number) * (self.options.segment_max_messages :: number)
	local dlq_capacity = (self.options.dlq_max_segments :: number) * (self.options.dlq_segment_max_messages :: number)
	local preparation_capacity = (self.options.preparation_shard_count :: number) * (self.options.preparation_max_entries_per_shard :: number)
	return {
		observed_at = self:_now(),
		consistency = "bounded_non_linearizable",
		completeness = {
			active_index = "complete_for_observed_manifest",
			dead_letter_index = if dlq_cursor == nil then "first_page_complete" else "page_only",
			preparation_registry = "all_configured_shards_read",
			global_snapshot = false,
		},
		exactness = {
			ready = "exact_over_observed_active_index",
			dead_lettered_page = "page_count_not_total",
			preparing_reservations = "observed_registry_entry_count",
			wakeups_published = "process_local",
			wakeup_publish_errors = "process_local",
		},
		scan = {
			active_index_capacity = active_capacity,
			dead_letter_index_capacity = dlq_capacity,
			dead_letter_page_size = 100,
			preparation_shard_count = self.options.preparation_shard_count,
		},
		ready = #queue,
		dead_lettered_page = #dlq,
		dead_letter_page_cursor = dlq_cursor,
		dead_lettered_page_has_more = dlq_cursor ~= nil,
		preparing_reservations = preparing,
		active_capacity = active_capacity,
		dlq_index_capacity = dlq_capacity,
		preparation_capacity = preparation_capacity,
		wakeups_enabled = self.options.wakeups ~= nil,
		wakeups_published = self.wakeup_published,
		wakeup_publish_errors = self.wakeup_publish_errors,
		rtbf_keyed_by_user_id = self.owner.user_id ~= nil,
	}, ok("success", nil, nil, nil)
end

function MailboxV2.ReclaimAsync(self: Mailbox): Result
	local activation = self:_check_activation("maintenance")
	if activation ~= nil then return activation end
	local reclaimed_active = self:_reclaim_slot("active")
	local reclaimed_dlq = self:_reclaim_slot("dlq")
	return ok(if reclaimed_active or reclaimed_dlq then "success" else "empty", nil, nil, nil)
end

type MockStoreState = {
	values: { [string]: unknown },
	update_calls: number,
	get_calls: number,
	remove_calls: number,
	fail_next_mode: string?,
	fail_update_call: number?,
	fail_update_call_mode: string?,
	delay_next_update_ms: number,
	delay_update_key: string?,
	advance_time: ((number) -> ())?,
	replay_next_update: number,
}

local MockStore = {}
MockStore.__index = MockStore

function MockStore.new(): MockStoreState
	local state: MockStoreState = {
		values = {},
		update_calls = 0,
		get_calls = 0,
		remove_calls = 0,
		fail_next_mode = nil,
		fail_update_call = nil,
		fail_update_call_mode = nil,
		delay_next_update_ms = 0,
		delay_update_key = nil,
		advance_time = nil,
		replay_next_update = 0,
	}
	setmetatable(state, MockStore)
	return (state :: unknown) :: MockStoreState
end

function MockStore.GetAsync(self: MockStoreState, key: string): unknown
	self.get_calls += 1
	return clone_json(self.values[key])
end

function MockStore.GetAsyncFresh(self: MockStoreState, key: string): unknown
	self.get_calls += 1
	return clone_json(self.values[key])
end

function MockStore.UpdateAsync(self: MockStoreState, key: string, transform: (unknown, unknown?) -> (unknown, { number }?, Dict?)): unknown
	self.update_calls += 1
	local failure_mode = nil
	if self.fail_update_call == self.update_calls then
		failure_mode = self.fail_update_call_mode
		self.fail_update_call = nil
		self.fail_update_call_mode = nil
	elseif self.fail_next_mode ~= nil then
		failure_mode = self.fail_next_mode
		self.fail_next_mode = nil
	end
	if failure_mode == "before" then
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
	if self.delay_next_update_ms > 0 and (self.delay_update_key == nil or self.delay_update_key == key) then
		local delay_ms = self.delay_next_update_ms
		self.delay_next_update_ms = 0
		self.delay_update_key = nil
		if self.advance_time ~= nil then
			self.advance_time(delay_ms)
		end
	end
	if failure_mode == "after" then
		error("injected response loss after commit")
	end
	return result
end

function MockStore.RemoveAsync(self: MockStoreState, key: string)
	self.remove_calls += 1
	self.values[key] = nil
end

function MockStore.FailNextUpdate(self: MockStoreState, mode: string)
	assert(mode == "before" or mode == "after", "mode must be before or after")
	self.fail_next_mode = mode
end

function MockStore.ReplayNextUpdate(self: MockStoreState)
	self.replay_next_update += 1
end

function MockStore.FailUpdateAt(self: MockStoreState, update_call: number, mode: string)
	assert(type(update_call) == "number" and update_call == math.floor(update_call)
		and update_call > self.update_calls, "update_call must target a future UpdateAsync call")
	assert(mode == "before" or mode == "after", "mode must be before or after")
	self.fail_update_call = update_call
	self.fail_update_call_mode = mode
end

function MockStore:DelayNextUpdateBy(delay_ms: number)
	assert(is_finite(delay_ms) and delay_ms >= 0 and delay_ms <= 60_000,
		"delay_ms must be finite and between 0 and 60000")
	self.delay_next_update_ms = delay_ms
	self.delay_update_key = nil
end

function MockStore:DelayUpdateForKey(key: string, delay_ms: number)
	assert(type(key) == "string" and key ~= "", "key must be a non-empty string")
	assert(is_finite(delay_ms) and delay_ms >= 0 and delay_ms <= 60_000,
		"delay_ms must be finite and between 0 and 60000")
	self.delay_next_update_ms = delay_ms
	self.delay_update_key = key
end

function MailboxV2.MockStore()
	return MockStore.new()
end

MailboxV2.Version = VERSION

return MailboxV2
