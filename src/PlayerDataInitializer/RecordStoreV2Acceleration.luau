--!nocheck
-- Optional cross-server mailbox wake-up acceleration.
-- Notifications and MemoryStore entries are lossy hints; durable mailbox polling
-- and reconciliation remain authoritative. Disabled unless explicitly enabled.

local Acceleration = {}

local MAX_SHARDS = 16
local MAX_TOPIC_PREFIX_BYTES = 40
local MAX_OWNER_BYTES = 1024
local MAX_REASON_BYTES = 32
local MAX_REGISTERED_OWNERS = 512
local MAX_PENDING_OWNERS = 512
local MAX_CALLBACKS_PER_PUMP = 32
local MAX_SEEN_EVENTS = 2048
local MAX_MEMORY_HINT_SLOTS = 256
local SEEN_EVENT_TTL_MS = 120000

local REASONS = {
	enqueue = true,
	retry = true,
	reconcile = true,
	maintenance = true,
}

local function finite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function valid_text(value, maximum)
	return type(value) == "string" and value ~= "" and #value <= maximum
end

local function has_method(value, name)
	local ok, method = pcall(function() return value[name] end)
	return ok and type(method) == "function"
end

local function canonical(value, stack, depth)
	stack = stack or {}
	depth = depth or 0
	if depth > 32 then error("owner identity exceeds maximum depth", 3) end
	local kind = type(value)
	if kind == "nil" then return "n" end
	if kind == "boolean" then return if value then "b1" else "b0" end
	if kind == "number" then
		if not finite(value) then error("owner identity contains a non-finite number", 3) end
		return if value == 0 then "d0" else "d" .. string.format("%.17g", value)
	end
	if kind == "string" then return "s" .. tostring(#value) .. ":" .. value end
	if kind ~= "table" then error("owner identity contains an unsupported value", 3) end
	if stack[value] then error("owner identity contains a cycle", 3) end
	stack[value] = true
	local count, numeric, string_keys, max_index = 0, true, true, 0
	for key in pairs(value) do
		count += 1
		if type(key) ~= "number" or not finite(key) or math.floor(key) ~= key or key < 1 then
			numeric = false
		else
			max_index = math.max(max_index, key)
		end
		if type(key) ~= "string" then string_keys = false end
	end
	local result
	if count > 0 and numeric and max_index == count then
		local parts = {}
		for index = 1, count do parts[index] = canonical(value[index], stack, depth + 1) end
		result = "a" .. tostring(count) .. "[" .. table.concat(parts, "") .. "]"
	elseif count == 0 or string_keys then
		local keys = {}
		for key in pairs(value) do table.insert(keys, key) end
		table.sort(keys)
		local parts = {}
		for _, key in ipairs(keys) do
			parts[#parts + 1] = canonical(key, stack, depth + 1)
			parts[#parts + 1] = canonical(value[key], stack, depth + 1)
		end
		result = "o" .. tostring(#keys) .. "{" .. table.concat(parts, "") .. "}"
	else
		stack[value] = nil
		error("owner identity contains mixed or sparse keys", 3)
	end
	stack[value] = nil
	return result
end

local function owner_material(owner)
	local material
	if type(owner) == "string" then
		material = owner
	else
		local ok, value = pcall(canonical, owner)
		if not ok then return nil, "owner identity is not canonicalizable" end
		material = value
	end
	if not valid_text(material, MAX_OWNER_BYTES) then
		return nil, "owner identity is empty or exceeds the byte limit"
	end
	return material, nil
end

local function owner_hash(material)
	-- These routing hashes are not security credentials or durable ownership tokens.
	local first, second = 5381, 1
	for index = 1, #material do
		local byte = string.byte(material, index)
		first = (first * 33 + byte) % 2147483647
		second = (second * 65599 + byte) % 2147483629
	end
	return string.format("%08x%08x", first, second)
end

local function shard_for(hash, shard_count)
	local bucket = tonumber(string.sub(hash, 1, 8), 16) or 0
	return (bucket % shard_count) + 1
end

local function disconnect(connection)
	if not has_method(connection, "Disconnect") then return end
	pcall(function() connection:Disconnect() end)
end

function Acceleration.new(options)
	options = options or {}
	if type(options) ~= "table" then error("acceleration options must be a table", 2) end
	local messaging = options.messaging_service
	if not has_method(messaging, "SubscribeAsync") or not has_method(messaging, "PublishAsync") then
		error("messaging_service must implement SubscribeAsync and PublishAsync", 2)
	end

	local topic_prefix = options.topic_prefix or "RecordStoreV2.Wakeup.v1"
	local shard_count = options.shard_count or MAX_SHARDS
	local max_registered = options.max_registered_owners or MAX_REGISTERED_OWNERS
	local max_pending = options.max_pending_owners or MAX_PENDING_OWNERS
	local max_callbacks = options.max_callbacks_per_pump or MAX_CALLBACKS_PER_PUMP
	local coalesce_ms = options.coalesce_window_ms or 25
	local enabled = options.enabled == true
	if not valid_text(topic_prefix, MAX_TOPIC_PREFIX_BYTES)
		or not finite(shard_count) or math.floor(shard_count) ~= shard_count or shard_count < 1 or shard_count > MAX_SHARDS
		or not finite(max_registered) or math.floor(max_registered) ~= max_registered or max_registered < 1 or max_registered > MAX_REGISTERED_OWNERS
		or not finite(max_pending) or math.floor(max_pending) ~= max_pending or max_pending < 1 or max_pending > MAX_PENDING_OWNERS
		or not finite(max_callbacks) or math.floor(max_callbacks) ~= max_callbacks or max_callbacks < 1 or max_callbacks > MAX_CALLBACKS_PER_PUMP
		or not finite(coalesce_ms) or coalesce_ms < 0 or coalesce_ms > 10000
		or (options.enabled ~= nil and type(options.enabled) ~= "boolean")
	then
		error("invalid acceleration bounds or feature gate", 2)
	end

	local server_id = options.server_id
	local http_service = options.http_service
	if not valid_text(server_id, 128) and has_method(http_service, "GenerateGUID") then
		local ok, value = pcall(function() return http_service:GenerateGUID(false) end)
		if ok and valid_text(value, 128) then server_id = value end
	end
	if not valid_text(server_id, 128) then
		error("server_id is required unless http_service.GenerateGUID is supplied", 2)
	end

	local now_ms = options.now_ms
	if now_ms == nil then now_ms = function() return DateTime.now().UnixTimestampMillis end end
	if type(now_ms) ~= "function" then error("now_ms must return milliseconds", 2) end
	local schedule = options.schedule
	if schedule ~= nil and type(schedule) ~= "function" then
		error("schedule must accept delay_ms and callback", 2)
	end
	if schedule == nil then
		local task_api = options.task
		if task_api == nil then task_api = task end
		if has_method(task_api, "delay") then
			schedule = function(delay_ms, callback)
				task_api.delay(delay_ms / 1000, callback)
				return true
			end
		end
	end

	local memory_map = nil
	if options.enable_memory_store == true then
		local memory_service = options.memory_store_service
		if not has_method(memory_service, "GetSortedMap") then
			error("enable_memory_store requires memory_store_service.GetSortedMap", 2)
		end
		local map_name = options.memory_map_name or (topic_prefix .. ".Candidates")
		if not valid_text(map_name, 50) then error("memory_map_name must be 1 to 50 bytes", 2) end
		local ok, map = pcall(function() return memory_service:GetSortedMap(map_name) end)
		if not ok or not has_method(map, "SetAsync") or not has_method(map, "GetRangeAsync") then
			error("could not initialize the optional MemoryStore sorted map", 2)
		end
		memory_map = map
	elseif options.enable_memory_store ~= nil and type(options.enable_memory_store) ~= "boolean" then
		error("enable_memory_store must be a boolean", 2)
	end

	local sort_ascending = options.sort_direction_ascending
	if sort_ascending == nil then pcall(function() sort_ascending = Enum.SortDirection.Ascending end) end
	if sort_ascending == nil then sort_ascending = "Ascending" end
	local memory_slots = options.max_memory_hint_slots or 128
	local memory_ttl = options.memory_hint_ttl_seconds or 30
	local poll_ms = options.memory_poll_interval_ms or 1000
	local seen_limit = options.max_seen_events or MAX_SEEN_EVENTS
	if not finite(memory_slots) or math.floor(memory_slots) ~= memory_slots or memory_slots < 1 or memory_slots > MAX_MEMORY_HINT_SLOTS
		or not finite(memory_ttl) or math.floor(memory_ttl) ~= memory_ttl or memory_ttl < 1 or memory_ttl > 60
		or not finite(poll_ms) or math.floor(poll_ms) ~= poll_ms or poll_ms < 100 or poll_ms > 30000
		or not finite(seen_limit) or math.floor(seen_limit) ~= seen_limit or seen_limit < 1 or seen_limit > MAX_SEEN_EVENTS
	then
		error("invalid MemoryStore or event-deduplication bounds", 2)
	end

	local self = {
		messaging = messaging, memory_map = memory_map, enabled = enabled, running = false, generation = 0,
		topic_prefix = topic_prefix, shard_count = shard_count, server_id = server_id, now_ms = now_ms,
		schedule = schedule, sort_ascending = sort_ascending, coalesce_window_ms = coalesce_ms,
		max_registered_owners = max_registered, max_pending_owners = max_pending, max_callbacks_per_pump = max_callbacks,
		max_memory_hint_slots = memory_slots, memory_hint_ttl_seconds = memory_ttl,
		memory_poll_interval_ms = poll_ms, max_seen_events = seen_limit,
		owners = {}, owner_count = 0, pending = {}, pending_order = {}, pump_scheduled = false,
		subscriptions = {}, seen_events = {}, seen_order = {}, sequence = 0,
		metrics = {
			published = 0, publish_errors = 0, memory_write_errors = 0, memory_poll_errors = 0,
			received = 0, invalid_messages = 0, coalesced = 0, dropped_at_capacity = 0,
			callbacks_run = 0, callback_errors = 0, seen_duplicates = 0, subscribe_errors = 0,
		},
	}

	local function topic_for(shard)
		return topic_prefix .. "." .. string.format("%02d", shard)
	end

	local function remove_pending(owner_digest)
		self.pending[owner_digest] = nil
		for index = #self.pending_order, 1, -1 do
			if self.pending_order[index] == owner_digest then table.remove(self.pending_order, index) end
		end
	end

	local function remember_event(event_id)
		local now = self.now_ms()
		if not finite(now) then return false, "clock_invalid" end
		for index = #self.seen_order, 1, -1 do
			local old = self.seen_order[index]
			if now >= old.at_ms and now - old.at_ms > SEEN_EVENT_TTL_MS then
				self.seen_events[old.id] = nil
				table.remove(self.seen_order, index)
			end
		end
		if self.seen_events[event_id] ~= nil then return false, "duplicate" end
		if #self.seen_order >= self.max_seen_events then
			local old = table.remove(self.seen_order, 1)
			self.seen_events[old.id] = nil
		end
		self.seen_events[event_id] = now
		table.insert(self.seen_order, { id = event_id, at_ms = now })
		return true, nil
	end

	local function schedule_callback(delay_ms, callback)
		if type(self.schedule) == "function" then
			local ok, result = pcall(self.schedule, delay_ms, callback)
			return ok and result ~= false
		end
		-- Non-Roblox hosts without a scheduler degrade to immediate local dispatch.
		local ok = pcall(callback)
		return ok
	end

	local function queue_owner(owner_digest, reason)
		if not self.running then return false, "stopped" end
		local owner = self.owners[owner_digest]
		if owner == nil or owner.active ~= true then return false, "not_registered" end
		local current = self.pending[owner_digest]
		if current ~= nil then
			current.reason = reason
			self.metrics.coalesced += 1
			return true, "coalesced"
		end
		if #self.pending_order >= self.max_pending_owners then
			self.metrics.dropped_at_capacity += 1
			return false, "capacity"
		end
		self.pending[owner_digest] = { reason = reason, owner = owner }
		table.insert(self.pending_order, owner_digest)
		if not self.pump_scheduled then
			self.pump_scheduled = true
			local generation = self.generation
			local scheduled = schedule_callback(self.coalesce_window_ms, function()
				if self.running and self.generation == generation then self:_pump() end
			end)
			if not scheduled then
				self.pump_scheduled = false
				remove_pending(owner_digest)
				return false, "scheduler_unavailable"
			end
		end
		return true, "queued"
	end

	function self:_receive(topic_shard, envelope)
		if not self.running then return false, "stopped" end
		local data = if type(envelope) == "table" and type(envelope.Data) == "table" then envelope.Data else envelope
		if type(data) ~= "table" or data.version ~= 1
			or not valid_text(data.owner_hash, 16) or string.match(data.owner_hash, "^[%x]+$") == nil
			or not valid_text(data.event_id, 192) or not valid_text(data.reason, MAX_REASON_BYTES)
			or REASONS[data.reason] ~= true or not valid_text(data.sender, 128)
			or not finite(data.published_at_ms) or data.published_at_ms < 0
		then
			self.metrics.invalid_messages += 1
			return false, "invalid"
		end
		if shard_for(data.owner_hash, self.shard_count) ~= topic_shard then
			self.metrics.invalid_messages += 1
			return false, "wrong_shard"
		end
		local remembered, why = remember_event(data.event_id)
		if not remembered then
			if why == "duplicate" then self.metrics.seen_duplicates += 1 else self.metrics.invalid_messages += 1 end
			return false, why
		end
		if data.sender == self.server_id then return true, "self" end
		self.metrics.received += 1
		return queue_owner(data.owner_hash, data.reason)
	end

	function self:_pump()
		self.pump_scheduled = false
		if not self.running then return end
		local processed = 0
		while #self.pending_order > 0 and processed < self.max_callbacks_per_pump do
			local owner_digest = table.remove(self.pending_order, 1)
			local pending = self.pending[owner_digest]
			self.pending[owner_digest] = nil
			processed += 1
			if pending ~= nil and self.owners[owner_digest] == pending.owner and pending.owner.active == true then
				local ok = pcall(pending.owner.callback, pending.reason)
				if ok then self.metrics.callbacks_run += 1 else self.metrics.callback_errors += 1 end
			end
		end
		if #self.pending_order > 0 and not self.pump_scheduled then
			self.pump_scheduled = true
			local generation = self.generation
			local scheduled = schedule_callback(0, function()
				if self.running and self.generation == generation then self:_pump() end
			end)
			if not scheduled then self.pump_scheduled = false end
		end
	end

	function self:Register(owner_identity, callback)
		local material, err = owner_material(owner_identity)
		if material == nil then return false, err end
		if type(callback) ~= "function" then return false, "callback must be a function" end
		local digest = owner_hash(material)
		local existing = self.owners[digest]
		if existing ~= nil then
			if existing.material ~= material then return false, "owner hash collision" end
			return false, "owner callback is already registered"
		end
		if self.owner_count >= self.max_registered_owners then return false, "registered-owner capacity reached" end
		local registration = { hash = digest, material = material, callback = callback, active = true }
		self.owners[digest] = registration
		self.owner_count += 1
		local self_owner = self
		local handle = { Connected = true }
		function handle:Disconnect()
			if not self.Connected then return end
			self.Connected = false
			if registration.active ~= true then return end
			registration.active = false
			if self_owner.owners[digest] == registration then
				self_owner.owners[digest] = nil
				self_owner.owner_count = math.max(0, self_owner.owner_count - 1)
				remove_pending(digest)
			end
		end
		return true, handle
	end

	function self:Publish(owner_identity, reason)
		if not self.enabled or not self.running then
			return { code = "disabled", message = "wake-up acceleration is disabled or not started" }
		end
		local material, err = owner_material(owner_identity)
		if material == nil then return { code = "invalid", message = err } end
		if not valid_text(reason, MAX_REASON_BYTES) or REASONS[reason] ~= true then
			return { code = "invalid", message = "wake-up reason is unsupported" }
		end
		local now = self.now_ms()
		if not finite(now) or now < 0 then return { code = "invalid", message = "clock returned invalid milliseconds" } end
		self.sequence += 1
		local digest = owner_hash(material)
		local shard = shard_for(digest, self.shard_count)
		local message = {
			version = 1, owner_hash = digest, shard = shard, reason = reason,
			event_id = self.server_id .. ":" .. tostring(self.sequence) .. ":" .. tostring(now),
			sender = self.server_id, published_at_ms = now,
		}
		remember_event(message.event_id)
		local local_ok = true
		if self.owners[digest] ~= nil then local_ok = select(1, queue_owner(digest, reason)) end
		local memory_ok = false
		if self.memory_map ~= nil then
			local first_hash = tonumber(string.sub(digest, 1, 8), 16) or 0
			local slot = "h" .. tostring((first_hash + self.sequence) % self.max_memory_hint_slots)
			local ok = pcall(function()
				self.memory_map:SetAsync(slot, message, now, self.memory_hint_ttl_seconds)
			end)
			memory_ok = ok
			if not ok then self.metrics.memory_write_errors += 1 end
		end
		local topic_ok = pcall(function() self.messaging:PublishAsync(topic_for(shard), message) end)
		if not topic_ok then self.metrics.publish_errors += 1 end
		if not topic_ok and not memory_ok then
			return { code = if local_ok then "unavailable" else "capacity", message = "remote hints unavailable; durable polling must recover" }
		end
		self.metrics.published += 1
		return { code = "scheduled", event_id = message.event_id, shard = shard }
	end

	function self:PollMemoryHints(max_items)
		if not self.enabled or not self.running or self.memory_map == nil then
			return { code = "disabled", processed = 0 }
		end
		max_items = math.clamp(math.floor(max_items or 32), 1, self.max_memory_hint_slots)
		local ok, rows = pcall(function()
			return self.memory_map:GetRangeAsync(self.sort_ascending, max_items)
		end)
		if not ok or type(rows) ~= "table" then
			self.metrics.memory_poll_errors += 1
			return { code = "unknown", processed = 0 }
		end
		local processed = 0
		for _, row in ipairs(rows) do
			if type(row) == "table" then
				local payload = row.value or row.Value
				local shard = if type(payload) == "table" then payload.shard else nil
				if type(payload) == "table" and finite(shard) and math.floor(shard) == shard
					and shard >= 1 and shard <= self.shard_count
				then
					self:_receive(shard, payload)
					processed += 1
				end
			end
		end
		return { code = "success", processed = processed }
	end

	function self:_schedule_memory_poll()
		if not self.running or self.memory_map == nil or type(self.schedule) ~= "function" then return end
		local generation = self.generation
		local scheduled = schedule_callback(self.memory_poll_interval_ms, function()
			if not self.running or self.generation ~= generation then return end
			self:PollMemoryHints()
			self:_schedule_memory_poll()
		end)
		if not scheduled then self.metrics.memory_poll_errors += 1 end
	end

	function self:Start()
		if not self.enabled then return false, "wake-up acceleration is disabled by configuration" end
		if self.running then return true, nil end
		local connections = {}
		for shard = 1, self.shard_count do
			local shard_index = shard
			local ok, connection = pcall(function()
				return self.messaging:SubscribeAsync(topic_for(shard_index), function(envelope)
					self:_receive(shard_index, envelope)
				end)
			end)
			if not ok or connection == nil then
				for _, existing in ipairs(connections) do disconnect(existing) end
				self.metrics.subscribe_errors += 1
				return false, "MessagingService subscription setup failed"
			end
			table.insert(connections, connection)
		end
		self.subscriptions = connections
		self.running = true
		self.generation += 1
		self:_schedule_memory_poll()
		return true, nil
	end

	function self:Stop()
		self.running = false
		self.generation += 1
		for _, connection in ipairs(self.subscriptions) do disconnect(connection) end
		self.subscriptions = {}
		self.pending = {}
		self.pending_order = {}
		self.pump_scheduled = false
		return true
	end

	function self:Stats()
		local metrics = {}
		for key, value in pairs(self.metrics) do metrics[key] = value end
		return {
			enabled = self.enabled, running = self.running, registered_owners = self.owner_count,
			pending_owners = #self.pending_order, shard_count = self.shard_count,
			memory_store_enabled = self.memory_map ~= nil, metrics = metrics,
		}
	end

	return self
end

return Acceleration
