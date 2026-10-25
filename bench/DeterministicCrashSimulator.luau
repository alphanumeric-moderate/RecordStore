--!nocheck
-- Bench-only deterministic fault simulator for RecordStore protocol work.
-- This module never connects to Roblox services. Tests provide the production
-- adapter under test and drive it through DataStore, MemoryStore, messaging,
-- virtual-time, crash, and invariant controls exposed here.

local serde = require("@lune/serde")

local Simulator = {}

local MAX_FAULTS = 8192
local MAX_EVENTS = 16384
local MAX_TRACE_EVENTS = 8192
local MAX_DEPTH = 64
local MAX_SCRIPT_BYTES = 1024 * 1024
local MAX_RANDOM_SEED = 2147483646

local function finite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function valid_text(value, maximum)
	return type(value) == "string" and value ~= "" and #value <= maximum
end

local function dense_array(value, maximum)
	if type(value) ~= "table" then return false, 0 end
	local count = 0
	local highest = 0
	for key in pairs(value) do
		if type(key) ~= "number" or not finite(key) or math.floor(key) ~= key or key < 1 then
			return false, 0
		end
		count += 1
		highest = math.max(highest, key)
	end
	if count ~= highest or count > maximum then return false, count end
	return true, count
end

local function clone(value, depth, seen)
	depth = depth or 0
	seen = seen or {}
	if depth > MAX_DEPTH then error("simulator value exceeds maximum depth", 3) end
	local kind = type(value)
	if kind == "nil" or kind == "boolean" or kind == "string" then return value end
	if kind == "number" then
		if not finite(value) then error("simulator value contains a non-finite number", 3) end
		return value
	end
	if kind ~= "table" then error("simulator values must be JSON-compatible", 3) end
	if seen[value] then error("simulator value contains a cycle", 3) end
	seen[value] = true
	local result = {}
	for key, item in pairs(value) do
		local key_type = type(key)
		if key_type ~= "string" and key_type ~= "number" then
			error("simulator table keys must be strings or numbers", 3)
		end
		result[clone(key, depth + 1, seen)] = clone(item, depth + 1, seen)
	end
	seen[value] = nil
	return result
end

local function array_remove(array, index)
	table.remove(array, index)
end

local function make_key_info(entry)
	local info = {}
	function info:GetUserIds()
		return clone(entry.user_ids or {})
	end
	function info:GetMetadata()
		return clone(entry.metadata or {})
	end
	function info:GetVersion()
		return entry.version_id
	end
	function info:GetCreatedTime()
		return entry.created_at_ms
	end
	function info:GetUpdatedTime()
		return entry.updated_at_ms
	end
	return info
end

local function call_non_yielding(callback, ...)
	local thread = coroutine.create(callback)
	local ok, a, b, c, d = coroutine.resume(thread, ...)
	if not ok then return false, a end
	if coroutine.status(thread) ~= "dead" then
		return false, "callback yielded; simulator transforms and invariant checks must not yield"
	end
	return true, a, b, c, d
end

local function fault_matches(rule, operation, phase, key, server)
	return (rule.operation == nil or rule.operation == "*" or rule.operation == operation)
		and (rule.phase == nil or rule.phase == "*" or rule.phase == phase)
		and (rule.key == nil or rule.key == "*" or rule.key == key)
		and (rule.server == nil or rule.server == "*" or rule.server == server)
end

function Simulator.new(options)
	options = options or {}
	if type(options) ~= "table" then error("simulator options must be a table", 2) end
	local seed = options.seed or 1
	if not finite(seed) or math.floor(seed) ~= seed or seed < 1 or seed > MAX_RANDOM_SEED then
		error("seed must be an integer in [1, 2147483646]", 2)
	end

	local self = {
		now_ms = 0,
		clock_offsets = {},
		server_epochs = {},
		local_state = {},
		store = {},
		versions = {},
		cache = {},
		memory = {},
		subscriptions = {},
		scheduled = {},
		_running_event = false,
		faults = {},
		trace = {},
		invariants = {},
		first_violation = nil,
		next_sequence = 0,
		next_subscription = 0,
		random_state = seed,
		max_events = math.clamp(math.floor(options.max_events or MAX_EVENTS), 1, MAX_EVENTS),
		trace_capacity = math.clamp(math.floor(options.trace_capacity or MAX_TRACE_EVENTS), 1, MAX_TRACE_EVENTS),
		cache_ttl_ms = math.clamp(math.floor(options.cache_ttl_ms or 4000), 0, 60000),
		budgets = {},
		counters = {
			reads = 0,
			writes = 0,
			transform_calls = 0,
			transform_replays = 0,
			crashes = 0,
			dropped_hints = 0,
			delivered_hints = 0,
			faults_consumed = 0,
			events_executed = 0,
			events_dropped = 0,
		},
	}
	self.clock_offsets["server-a"] = 0
	self.clock_offsets["server-b"] = 0
	self.server_epochs["server-a"] = 0
	self.server_epochs["server-b"] = 0
	self.local_state["server-a"] = {}
	self.local_state["server-b"] = {}
	self.cache["server-a"] = {}
	self.cache["server-b"] = {}

	local default_budget = options.initial_budget or 1000
	if not finite(default_budget) or default_budget < 0 then
		error("initial_budget must be finite and non-negative", 2)
	end
	self.budgets["server-a"] = { read = default_budget, write = default_budget }
	self.budgets["server-b"] = { read = default_budget, write = default_budget }

	function self:_trace(server, operation_id, key_family, transition, outcome, detail)
		local item = {
			at_ms = self:Now(server),
			server_id = server,
			operation_id = if valid_text(operation_id, 128) then operation_id else nil,
			key_family = if valid_text(key_family, 128) then key_family else "unspecified",
			transition = transition,
			outcome = outcome,
			detail = if valid_text(detail, 256) then detail else nil,
		}
		if #self.trace >= self.trace_capacity then
			array_remove(self.trace, 1)
		end
		table.insert(self.trace, item)
	end

	function self:_entry(key)
		return self.store[key]
	end

	function self:_consume_budget(server, dimension)
		local budget = self.budgets[server]
		if budget == nil then
			budget = { read = default_budget, write = default_budget }
			self.budgets[server] = budget
		end
		if budget[dimension] == math.huge then return true end
		if budget[dimension] < 1 then
			self:_trace(server, nil, "datastore", "request_budget", "capacity", dimension .. " budget exhausted")
			error("simulated DataStore request budget exhausted: " .. dimension, 3)
		end
		budget[dimension] -= 1
		return true
	end

	function self:_take_fault(operation, phase, key, server)
		for index, rule in ipairs(self.faults) do
			if rule.remaining > 0 and fault_matches(rule, operation, phase, key, server) then
				rule.remaining -= 1
				self.counters.faults_consumed += 1
				self:_trace(server, rule.operation_id, rule.key_family or "fault-script", "fault:" .. phase, rule.action, "deterministic fault consumed")
				return rule
			end
		end
		return nil
	end

	function self:_write_entry(key, value, user_ids, metadata)
		local now = self.now_ms
		local old = self.store[key]
		local revision = if old then old.revision + 1 else 1
		local entry = {
			value = clone(value),
			user_ids = clone(if user_ids ~= nil then user_ids else (old and old.user_ids or {})),
			metadata = clone(if metadata ~= nil then metadata else (old and old.metadata or {})),
			revision = revision,
			version_id = "sim-v" .. tostring(revision),
			created_at_ms = if old then old.created_at_ms else now,
			updated_at_ms = now,
		}
		self.store[key] = entry
		self.versions[key] = self.versions[key] or {}
		table.insert(self.versions[key], clone(entry))
		for _, cache in pairs(self.cache) do
			if cache[key] ~= nil then cache[key] = nil end
		end
		self.counters.writes += 1
		return entry
	end

	function self:Now(server)
		server = server or "server-a"
		return self.now_ms + (self.clock_offsets[server] or 0)
	end

	function self:SetClock(server, absolute_ms)
		if not valid_text(server, 96) or not finite(absolute_ms) or absolute_ms < 0 then
			return false, "server and finite non-negative absolute milliseconds are required"
		end
		self.clock_offsets[server] = absolute_ms - self.now_ms
		self.server_epochs[server] = self.server_epochs[server] or 0
		self.local_state[server] = self.local_state[server] or {}
		self.cache[server] = self.cache[server] or {}
		self.budgets[server] = self.budgets[server] or { read = default_budget, write = default_budget }
		self:_trace(server, nil, "clock", "set_clock", "success", "server-local virtual time updated")
		return true, nil
	end

	function self:Advance(delta_ms)
		if not finite(delta_ms) or delta_ms < 0 or delta_ms > 31_536_000_000 then
			return false, "advance must be finite and in [0, one year in milliseconds]"
		end
		self.now_ms += delta_ms
		self:_trace("simulator", nil, "clock", "advance", "success", tostring(delta_ms) .. " ms")
		return true, self.now_ms
	end

	function self:NextRandomInt(minimum, maximum)
		if not finite(minimum) or not finite(maximum) or math.floor(minimum) ~= minimum or math.floor(maximum) ~= maximum or minimum > maximum then
			error("random integer bounds are invalid", 2)
		end
		self.random_state = (self.random_state * 48271) % 2147483647
		return minimum + (self.random_state % (maximum - minimum + 1))
	end

	function self:SetBudget(server, read_budget, write_budget)
		if not valid_text(server, 96)
			or not finite(read_budget) or read_budget < 0
			or not finite(write_budget) or write_budget < 0
		then
			return false, "server and finite non-negative read/write budgets are required"
		end
		self.budgets[server] = { read = read_budget, write = write_budget }
		return true, nil
	end

	function self:AddBudget(server, read_units, write_units)
		local current = self.budgets[server] or { read = 0, write = 0 }
		if not finite(read_units) or read_units < 0 or not finite(write_units) or write_units < 0 then
			return false, "budget increments must be finite and non-negative"
		end
		current.read += read_units
		current.write += write_units
		self.budgets[server] = current
		return true, nil
	end

	function self:GetRequestBudgetForRequestType(server, request_type)
		local budget = self.budgets[server] or { read = 0, write = 0 }
		if request_type == "GetAsync" or request_type == "StandardRead" or request_type == "ListAsync" then
			return budget.read
		end
		if request_type == "UpdateAsync" or request_type == "SetAsync" or request_type == "RemoveAsync" or request_type == "StandardWrite" then
			return budget.write
		end
		return 0
	end

	function self:LoadFaultScript(script)
		local valid, count = dense_array(script, MAX_FAULTS)
		if not valid then return false, "fault script must be a dense array with at most 8192 entries" end
		local normalized = {}
		local actions = {
			fail_before_commit = true,
			commit_then_error = true,
			transform_replay = true,
			ownership_race = true,
			throttle = true,
			budget_exhaustion = true,
			drop_hint = true,
			duplicate_hint = true,
			delay_hint = true,
			reorder_hint = true,
			expire_hint = true,
			stale_read = true,
		}
		for index = 1, count do
			local raw = script[index]
			if type(raw) ~= "table"
				or not valid_text(raw.action, 48)
				or actions[raw.action] ~= true
				or (raw.operation ~= nil and not valid_text(raw.operation, 48))
				or (raw.phase ~= nil and not valid_text(raw.phase, 48))
				or (raw.key ~= nil and type(raw.key) ~= "string")
				or (raw.server ~= nil and type(raw.server) ~= "string")
			then
				return false, "invalid fault rule at index " .. tostring(index)
			end
			local remaining = raw.remaining or raw.times or 1
			if not finite(remaining) or math.floor(remaining) ~= remaining or remaining < 1 or remaining > 100000 then
				return false, "fault rule remaining/times must be an integer in [1, 100000]"
			end
			if raw.delay_ms ~= nil and (not finite(raw.delay_ms) or raw.delay_ms < 0 or raw.delay_ms > 86_400_000) then
				return false, "fault rule delay_ms must be in [0, one day in milliseconds]"
			end
			normalized[index] = {
				operation = raw.operation,
				phase = raw.phase,
				key = raw.key,
				server = raw.server,
				action = raw.action,
				remaining = remaining,
				delay_ms = raw.delay_ms,
				ttl_ms = raw.ttl_ms,
				concurrent_value = if raw.concurrent_value ~= nil then clone(raw.concurrent_value) else nil,
				operation_id = raw.operation_id,
				key_family = raw.key_family,
			}
		end
		self.faults = normalized
		return true, nil
	end

	function self:InjectFault(rule)
		local list = clone(self.faults)
		table.insert(list, rule)
		return self:LoadFaultScript(list)
	end

	function self:SerializeFaultScript()
		local data = {}
		for index, rule in ipairs(self.faults) do
			data[index] = {
				operation = rule.operation,
				phase = rule.phase,
				key = rule.key,
				server = rule.server,
				action = rule.action,
				remaining = rule.remaining,
				delay_ms = rule.delay_ms,
				ttl_ms = rule.ttl_ms,
				concurrent_value = if rule.concurrent_value ~= nil then clone(rule.concurrent_value) else nil,
				operation_id = rule.operation_id,
				key_family = rule.key_family,
			}
		end
		local encoded = serde.encode("json", data)
		if #encoded > MAX_SCRIPT_BYTES then error("serialized fault script exceeds 1 MiB", 2) end
		return encoded
	end

	function self:LoadSerializedFaultScript(encoded)
		if type(encoded) ~= "string" or #encoded > MAX_SCRIPT_BYTES then
			return false, "serialized fault script must be a string no larger than 1 MiB"
		end
		local ok, decoded = pcall(function() return serde.decode("json", encoded) end)
		if not ok then return false, "serialized fault script is not valid JSON" end
		return self:LoadFaultScript(decoded)
	end

	function self:_read(server, key, fresh, context)
		if not valid_text(server, 96) or not valid_text(key, 2048) then error("server and key are required", 3) end
		local phase = if fresh then "before_fresh_read" else "before_read"
		local fault = self:_take_fault("GetAsync", phase, key, server)
		if fault == nil then fault = self:_take_fault("*", phase, key, server) end
		if fault and (fault.action == "fail_before_commit" or fault.action == "throttle" or fault.action == "budget_exhaustion") then
			error("simulated " .. fault.action .. " during " .. phase, 3)
		end
		self:_consume_budget(server, "read")
		self.counters.reads += 1
		local cache = self.cache[server] or {}
		if not fresh then
			local cached = cache[key]
			if cached ~= nil and cached.expires_at_ms >= self:Now(server) then
				return clone(cached.value), if cached.entry then make_key_info(cached.entry) else nil
			end
			if fault and fault.action == "stale_read" and cached ~= nil then
				return clone(cached.value), if cached.entry then make_key_info(cached.entry) else nil
			end
		end
		local entry = self.store[key]
		local value = if entry then clone(entry.value) else nil
		local info = if entry then make_key_info(entry) else nil
		if not fresh then
			self.cache[server] = cache
			cache[key] = {
				value = clone(value),
				entry = if entry then clone(entry) else nil,
				expires_at_ms = self:Now(server) + self.cache_ttl_ms,
			}
		end
		self:_trace(server, context and context.operation_id, context and context.key_family or "datastore", if fresh then "get_fresh" else "get", "success", if entry then "record found" else "record absent")
		return value, info
	end

	function self:GetAsync(server, key, context)
		return self:_read(server or "server-a", key, false, context)
	end

	function self:GetAsyncFresh(server, key, context)
		return self:_read(server or "server-a", key, true, context)
	end

	function self:UpdateAsync(server, key, transform, context)
		server = server or "server-a"
		if not valid_text(server, 96) or not valid_text(key, 2048) or type(transform) ~= "function" then
			error("UpdateAsync requires server, key, and transform", 2)
		end
		local before_fault = self:_take_fault("UpdateAsync", "before_update", key, server)
		if before_fault == nil then before_fault = self:_take_fault("*", "before_update", key, server) end
		if before_fault and (before_fault.action == "fail_before_commit" or before_fault.action == "throttle" or before_fault.action == "budget_exhaustion") then
			error("simulated " .. before_fault.action .. " before UpdateAsync", 2)
		end
		self:_consume_budget(server, "read")
		self:_consume_budget(server, "write")

		local function invoke_transform(current)
			self.counters.transform_calls += 1
			local entry = self.store[key]
			local thread = coroutine.create(function()
				return transform(clone(current), if entry then make_key_info(entry) else nil)
			end)
			local ok, next_value, next_user_ids, next_metadata = coroutine.resume(thread)
			if not ok then error("UpdateAsync transform failed: " .. tostring(next_value), 2) end
			if coroutine.status(thread) ~= "dead" then error("UpdateAsync transform yielded", 2) end
			return next_value, next_user_ids, next_metadata
		end

		local transform_fault = self:_take_fault("UpdateAsync", "during_transform", key, server)
		if transform_fault == nil then transform_fault = self:_take_fault("*", "during_transform", key, server) end
		local current_entry = self.store[key]
		local current = if current_entry then clone(current_entry.value) else nil
		local next_value, next_user_ids, next_metadata = invoke_transform(current)

		if transform_fault and transform_fault.action == "ownership_race" then
			local raced_value = if transform_fault.concurrent_value ~= nil
				then clone(transform_fault.concurrent_value)
				else { __simulated_competing_write = true, previous = clone(current) }
			self:_write_entry(key, raced_value, current_entry and current_entry.user_ids, current_entry and current_entry.metadata)
			self.counters.transform_replays += 1
			current_entry = self.store[key]
			next_value, next_user_ids, next_metadata = invoke_transform(clone(current_entry.value))
		elseif transform_fault and transform_fault.action == "transform_replay" then
			self.counters.transform_replays += 1
			next_value, next_user_ids, next_metadata = invoke_transform(current)
		end

		local commit_fault = self:_take_fault("UpdateAsync", "before_commit", key, server)
		if commit_fault == nil then commit_fault = self:_take_fault("*", "before_commit", key, server) end
		if commit_fault and (commit_fault.action == "fail_before_commit" or commit_fault.action == "throttle" or commit_fault.action == "budget_exhaustion") then
			error("simulated " .. commit_fault.action .. " at UpdateAsync commit boundary", 2)
		end

		if next_value == nil then
			self:_trace(server, context and context.operation_id, context and context.key_family or "datastore", "update", "cancelled", "transform returned nil")
			return nil, if current_entry then make_key_info(current_entry) else nil
		end
		local written = self:_write_entry(key, next_value, next_user_ids, next_metadata)
		self.cache[server] = self.cache[server] or {}
		self.cache[server][key] = {
			value = clone(written.value),
			entry = clone(written),
			expires_at_ms = self:Now(server) + self.cache_ttl_ms,
		}
		self:_trace(server, context and context.operation_id, context and context.key_family or "datastore", "update", "committed", "durable mock entry updated")

		local after_fault = self:_take_fault("UpdateAsync", "after_commit", key, server)
		if after_fault == nil then after_fault = self:_take_fault("*", "after_commit", key, server) end
		if after_fault and after_fault.action == "commit_then_error" then
			error("simulated response loss after durable commit", 2)
		end
		return clone(written.value), make_key_info(written)
	end

	function self:SetAsync(server, key, value, user_ids, metadata, context)
		server = server or "server-a"
		local fault = self:_take_fault("SetAsync", "before_update", key, server)
		if fault and (fault.action == "fail_before_commit" or fault.action == "throttle" or fault.action == "budget_exhaustion") then
			error("simulated " .. fault.action .. " during SetAsync", 2)
		end
		self:_consume_budget(server, "write")
		local entry = self:_write_entry(key, value, user_ids, metadata)
		self:_trace(server, context and context.operation_id, context and context.key_family or "datastore", "set", "committed", "durable mock entry replaced")
		if fault and fault.action == "commit_then_error" then error("simulated response loss after SetAsync", 2) end
		return clone(entry.value), make_key_info(entry)
	end

	function self:RemoveAsync(server, key, context)
		server = server or "server-a"
		local fault = self:_take_fault("RemoveAsync", "before_update", key, server)
		if fault and (fault.action == "fail_before_commit" or fault.action == "throttle" or fault.action == "budget_exhaustion") then
			error("simulated " .. fault.action .. " during RemoveAsync", 2)
		end
		self:_consume_budget(server, "write")
		local old = self.store[key]
		self.store[key] = nil
		self.versions[key] = self.versions[key] or {}
		for _, cache in pairs(self.cache) do cache[key] = nil end
		self.counters.writes += 1
		self:_trace(server, context and context.operation_id, context and context.key_family or "datastore", "remove", "committed", if old then "mock key removed" else "mock key was already absent")
		if fault and fault.action == "commit_then_error" then error("simulated response loss after RemoveAsync", 2) end
		return if old then clone(old.value) else nil
	end

	function self:Crash(server, reason)
		server = server or "server-a"
		if not valid_text(server, 96) then return false, "server ID is invalid" end
		self.server_epochs[server] = (self.server_epochs[server] or 0) + 1
		self.local_state[server] = {}
		self.cache[server] = {}
		self.counters.crashes += 1
		self:_trace(server, nil, "process", "crash", "committed_state_preserved", valid_text(reason, 256) and reason or "simulated process restart")
		return true, nil
	end

	function self:LocalState(server)
		server = server or "server-a"
		self.local_state[server] = self.local_state[server] or {}
		return self.local_state[server]
	end

	function self:ScheduleAfter(server, delay_ms, operation_id, callback_id, callback)
		server = server or "server-a"
		if not valid_text(server, 96) or not finite(delay_ms) or delay_ms < 0 or delay_ms > 31_536_000_000
			or type(callback) ~= "function"
		then
			return nil, "schedule requires a server, valid delay, and callback"
		end
		local active = if self._running_event then 1 else 0
		if #self.scheduled + active >= self.max_events then return nil, "simulated event queue is full" end
		self.next_sequence += 1
		local event = {
			server = server,
			due_global_ms = self.now_ms + delay_ms,
			sequence = self.next_sequence,
			epoch = self.server_epochs[server] or 0,
			operation_id = operation_id,
			callback_id = callback_id,
			callback = callback,
		}
		table.insert(self.scheduled, event)
		return event.sequence, nil
	end

	function self:RunNext()
		if #self.scheduled == 0 then return { code = "empty" } end
		local selected_index = 1
		for index = 2, #self.scheduled do
			local candidate = self.scheduled[index]
			local selected = self.scheduled[selected_index]
			if candidate.due_global_ms < selected.due_global_ms
				or (candidate.due_global_ms == selected.due_global_ms and candidate.sequence < selected.sequence)
			then
				selected_index = index
			end
		end
		local event = table.remove(self.scheduled, selected_index)
		if event.due_global_ms > self.now_ms then self.now_ms = event.due_global_ms end
		if event.epoch ~= (self.server_epochs[event.server] or 0) then
			self.counters.events_dropped += 1
			self:_trace(event.server, event.operation_id, "scheduler", "event", "dropped_after_crash", "scheduled callback belonged to an earlier process epoch")
			return { code = "dropped", sequence = event.sequence }
		end
		local thread = event.thread
		if thread == nil then
			thread = coroutine.create(function()
				return event.callback(self, event)
			end)
		end
		self._running_event = true
		local ok, result = coroutine.resume(thread, event.resume_value)
		self._running_event = false
		if not ok then
			self.counters.events_executed += 1
			self:_trace(event.server, event.operation_id, "scheduler", event.callback_id or "callback", "failed", "callback failed; exception details redacted")
			return { code = "failed", sequence = event.sequence, result = "callback failed; exception details redacted" }
		end
		if coroutine.status(thread) ~= "dead" then
			if #self.scheduled >= self.max_events then
				self:_trace(event.server, event.operation_id, "scheduler", event.callback_id or "callback", "yield_blocked", "event capacity prevented deterministic rescheduling")
				return { code = "capacity", sequence = event.sequence, result = "yielding callback could not be rescheduled because the event queue is full" }
			end
			local yielded = result
			local delay_ms = 0
			if type(yielded) == "table" and yielded.delay_ms ~= nil then
				if not finite(yielded.delay_ms) or yielded.delay_ms < 0 or yielded.delay_ms > 31_536_000_000 then
					self:_trace(event.server, event.operation_id, "scheduler", event.callback_id or "callback", "invalid_yield", "yield delay was outside the supported finite range")
					return { code = "invalid", sequence = event.sequence, result = "yield delay must be finite and non-negative" }
				end
				delay_ms = yielded.delay_ms
			end
			self.next_sequence += 1
			event.sequence = self.next_sequence
			event.due_global_ms = self.now_ms + delay_ms
			event.thread = thread
			event.resume_value = nil
			table.insert(self.scheduled, event)
			self:_trace(event.server, event.operation_id, "scheduler", event.callback_id or "callback", "yielded", "callback suspended and was rescheduled deterministically")
			return { code = "yielded", sequence = event.sequence, due_ms = event.due_global_ms }
		end
		self.counters.events_executed += 1
		self:_trace(event.server, event.operation_id, "scheduler", event.callback_id or "callback", "completed", "deterministic callback completed")
		return { code = "completed", sequence = event.sequence, result = result }
	end

	function self:RunUntil(global_time_ms, maximum_events)
		if not finite(global_time_ms) or global_time_ms < self.now_ms then
			return { code = "invalid", message = "target time must be finite and not earlier than current global time" }
		end
		local limit = math.clamp(math.floor(maximum_events or self.max_events), 1, self.max_events)
		local ran = 0
		while #self.scheduled > 0 and ran < limit do
			local earliest = math.huge
			for _, event in ipairs(self.scheduled) do earliest = math.min(earliest, event.due_global_ms) end
			if earliest > global_time_ms then break end
			self:RunNext()
			ran += 1
		end
		if ran >= limit and #self.scheduled > 0 then
			return { code = "capacity", ran = ran, now_ms = self.now_ms, pending = #self.scheduled }
		end
		self.now_ms = global_time_ms
		return { code = "success", ran = ran, now_ms = self.now_ms, pending = #self.scheduled }
	end

	function self:RegisterInvariant(name, predicate)
		if not valid_text(name, 96) or type(predicate) ~= "function" then
			return false, "invariant needs a name and predicate"
		end
		if self.invariants[name] ~= nil then return false, "invariant name already registered" end
		self.invariants[name] = predicate
		return true, nil
	end

	function self:CheckInvariant(name, context)
		local predicate = self.invariants[name]
		if predicate == nil then return false, "invariant is not registered" end
		local ok, passed, detail = call_non_yielding(predicate, self, context)
		if ok and passed == true then return true, nil end
		local violation = {
			at_ms = self.now_ms,
			invariant = name,
			detail = if ok and passed == true then "invariant failed" else if ok then "predicate returned false" else "predicate raised an error; exception details redacted",
			context_id = if type(context) == "table" and valid_text(context.operation_id, 128) then context.operation_id else nil,
		}
		if self.first_violation == nil then self.first_violation = violation end
		self:_trace("simulator", violation.context_id, "invariant", name, "violated", violation.detail)
		return false, violation
	end

	function self:CheckAllInvariants(context)
		local names = {}
		for name in pairs(self.invariants) do table.insert(names, name) end
		table.sort(names)
		for _, name in ipairs(names) do
			local passed, violation = self:CheckInvariant(name, context)
			if not passed then return false, violation end
		end
		return true, nil
	end

	function self:TraceSnapshot()
		return clone(self.trace)
	end

	function self:Stats()
		return {
			now_ms = self.now_ms,
			scheduled = #self.scheduled,
			fault_rules = #self.faults,
			first_violation = clone(self.first_violation),
			counters = clone(self.counters),
			trace_capacity = self.trace_capacity,
		}
	end

	function self:DataStore(name, scope, server)
		server = server or "server-a"
		local simulator = self
		if not valid_text(name, 50) or type(scope) ~= "string" or #scope > 50 then
			error("DataStore adapter needs a name and bounded scope", 2)
		end
		local prefix = name .. "\31" .. scope .. "\31"
		local adapter = {}
		local function actual_key(key)
			if not valid_text(key, 2048) then error("DataStore key must be a non-empty bounded string", 3) end
			return prefix .. key
		end
		function adapter:GetAsync(key)
			return simulator:GetAsync(server, actual_key(key), { key_family = name .. "/" .. scope })
		end
		function adapter:GetAsyncFresh(key)
			return simulator:GetAsyncFresh(server, actual_key(key), { key_family = name .. "/" .. scope })
		end
		function adapter:UpdateAsync(key, transform)
			return simulator:UpdateAsync(server, actual_key(key), transform, { key_family = name .. "/" .. scope })
		end
		function adapter:SetAsync(key, value, user_ids, metadata)
			return simulator:SetAsync(server, actual_key(key), value, user_ids, metadata, { key_family = name .. "/" .. scope })
		end
		function adapter:RemoveAsync(key)
			return simulator:RemoveAsync(server, actual_key(key), { key_family = name .. "/" .. scope })
		end
		function adapter:GetRequestBudgetForRequestType(request_type)
			return simulator:GetRequestBudgetForRequestType(server, request_type)
		end
		return adapter
	end

	local function memory_namespace(name)
		if not valid_text(name, 128) then error("MemoryStore map name is invalid", 3) end
		self.memory[name] = self.memory[name] or {}
		return self.memory[name]
	end

	local function memory_get(map_name, key)
		local map = memory_namespace(map_name)
		local entry = map[key]
		if entry == nil then return nil end
		if entry.expires_at_ms ~= math.huge and entry.expires_at_ms <= self.now_ms then
			map[key] = nil
			return nil
		end
		return clone(entry.value)
	end

	local function memory_set(map_name, key, value, expiration_seconds, sort_key)
		if not valid_text(key, 2048) then error("MemoryStore key is invalid", 3) end
		if not finite(expiration_seconds) or expiration_seconds <= 0 or expiration_seconds > 45 * 24 * 60 * 60 then
			error("MemoryStore expiration must be in (0, 45 days]", 3)
		end
		local map = memory_namespace(map_name)
		map[key] = {
			value = clone(value),
			sort_key = sort_key,
			expires_at_ms = self.now_ms + expiration_seconds * 1000,
		}
		return true
	end

	function self:MemoryStoreService()
		local simulator = self
		local service = {}
		function service:GetHashMap(name)
			local map = {}
			function map:GetAsync(key) return memory_get(name, key) end
			function map:SetAsync(key, value, expiration_seconds) return memory_set(name, key, value, expiration_seconds) end
			function map:RemoveAsync(key)
				local values = memory_namespace(name)
				local old = memory_get(name, key)
				values[key] = nil
				return old
			end
			function map:UpdateAsync(key, transform, expiration_seconds)
				if type(transform) ~= "function" then error("MemoryStore UpdateAsync requires transform", 2) end
				local before = memory_get(name, key)
				local ok, next_value = call_non_yielding(transform, clone(before))
				if not ok then error("MemoryStore transform failed: " .. tostring(next_value), 2) end
				if next_value == nil then return before end
				memory_set(name, key, next_value, expiration_seconds)
				return clone(next_value)
			end
			return map
		end
		function service:GetSortedMap(name)
			local map = service:GetHashMap(name)
			function map:SetAsync(key, value, sort_key, expiration_seconds)
				if not finite(sort_key) then error("sorted map sort key must be finite", 2) end
				return memory_set(name, key, value, expiration_seconds, sort_key)
			end
			function map:GetRangeAsync(direction, count, exclusive_lower_bound, exclusive_upper_bound)
				if direction ~= "Ascending" and direction ~= "Descending" then error("invalid sorted-map direction", 2) end
				count = math.clamp(math.floor(count or 100), 1, 100)
				local entries = {}
				for key, entry in pairs(memory_namespace(name)) do
					if entry.expires_at_ms == math.huge or entry.expires_at_ms > simulator.now_ms then
						local sort_key = entry.sort_key
						if type(sort_key) == "number"
							and (exclusive_lower_bound == nil or sort_key > exclusive_lower_bound)
							and (exclusive_upper_bound == nil or sort_key < exclusive_upper_bound)
						then
							table.insert(entries, { key = key, value = clone(entry.value), sort_key = sort_key })
						end
					end
				end
				table.sort(entries, function(left, right)
					if left.sort_key == right.sort_key then return left.key < right.key end
					return if direction == "Ascending" then left.sort_key < right.sort_key else left.sort_key > right.sort_key
				end)
				while #entries > count do table.remove(entries) end
				return entries
			end
			return map
		end
		return service
	end

	function self:MessagingService()
		local service = {}
		function service:SubscribeAsync(server, topic, callback)
			if not valid_text(server, 96) or not valid_text(topic, 128) or type(callback) ~= "function" then
				error("SubscribeAsync requires server, topic, and callback", 2)
			end
			self._sim.next_subscription += 1
			local subscription = { id = self._sim.next_subscription, server = server, topic = topic, callback = callback, epoch = self._sim.server_epochs[server] or 0, connected = true }
			local list = self._sim.subscriptions[topic] or {}
			table.insert(list, subscription)
			self._sim.subscriptions[topic] = list
			local connection = { Connected = true }
			function connection:Disconnect()
				subscription.connected = false
				self.Connected = false
			end
			return connection
		end
		function service:PublishAsync(server, topic, message, options)
			if not valid_text(server, 96) or not valid_text(topic, 128) then error("PublishAsync requires server and topic", 2) end
			options = options or {}
			local fault = self._sim:_take_fault("PublishAsync", "before_publish", topic, server)
			if fault == nil then fault = self._sim:_take_fault("*", "before_publish", topic, server) end
			if fault and fault.action == "throttle" then error("simulated MessagingService throttle", 2) end
			if fault and fault.action == "drop_hint" then
				self._sim.counters.dropped_hints += 1
				self._sim:_trace(server, options.operation_id, "messaging", "publish", "dropped_hint", "publication intentionally lost")
				return { code = "published" }
			end
			local sent_global = self._sim.now_ms
			local ttl_ms = if fault and fault.ttl_ms ~= nil then fault.ttl_ms else (options.ttl_ms or 60000)
			local delay_ms = if fault and fault.delay_ms ~= nil then fault.delay_ms else (options.delay_ms or 0)
			if fault and fault.action == "reorder_hint" then delay_ms += 1000 end
			if fault and fault.action == "expire_hint" then ttl_ms = 0 end
			local copies = if fault and fault.action == "duplicate_hint" then 2 else 1
			for _ = 1, copies do
				local recipients = self._sim.subscriptions[topic] or {}
				for _, subscription in ipairs(recipients) do
					if subscription.connected and subscription.server ~= server then
						local selected = subscription
						local copied_message = clone(message)
						self._sim:ScheduleAfter(selected.server, delay_ms, options.operation_id, "messaging_delivery", function(sim)
							if not selected.connected or selected.epoch ~= (sim.server_epochs[selected.server] or 0) then
								sim.counters.events_dropped += 1
								return
							end
							if sim.now_ms - sent_global > ttl_ms then
								sim.counters.events_dropped += 1
								sim:_trace(selected.server, options.operation_id, "messaging", "delivery", "expired", "best-effort hint exceeded its TTL")
								return
							end
							local ok, err = pcall(selected.callback, { Data = clone(copied_message), SentAt = sent_global, Topic = topic })
							if ok then
								sim.counters.delivered_hints += 1
								sim:_trace(selected.server, options.operation_id, "messaging", "delivery", "delivered_hint", "callback completed")
							else
								sim:_trace(selected.server, options.operation_id, "messaging", "delivery", "callback_failed", tostring(err):sub(1, 240))
							end
						end)
					end
				end
			end
			self._sim:_trace(server, options.operation_id, "messaging", "publish", "published_hint", "hint is advisory; durable polling remains authoritative")
			return { code = "published" }
		end
		service._sim = self
		return service
	end

	function self:Replay(script, callbacks)
		local valid, count = dense_array(script, MAX_EVENTS)
		if not valid then return { code = "invalid", message = "replay script must be a dense array with at most 16384 events", completed = 0 } end
		callbacks = callbacks or {}
		local completed = 0
		for index = 1, count do
			local event = script[index]
			if type(event) ~= "table" or not valid_text(event.op, 48) then
				return { code = "invalid", message = "invalid replay event at index " .. tostring(index), completed = completed }
			end
			if event.op == "advance" then
				local ok, message = self:Advance(event.delta_ms)
				if not ok then return { code = "invalid", message = message, completed = completed } end
			elseif event.op == "set_clock" then
				local ok, message = self:SetClock(event.server, event.absolute_ms)
				if not ok then return { code = "invalid", message = message, completed = completed } end
			elseif event.op == "crash" then
				local ok, message = self:Crash(event.server, event.reason)
				if not ok then return { code = "invalid", message = message, completed = completed } end
			elseif event.op == "inject_fault" then
				local ok, message = self:InjectFault(event.rule)
				if not ok then return { code = "invalid", message = message, completed = completed } end
			elseif event.op == "run_next" then
				local result = self:RunNext()
				if result.code == "failed" then return { code = "callback_failed", message = tostring(result.result), completed = completed } end
			elseif event.op == "run_until" then
				local result = self:RunUntil(event.global_time_ms, event.maximum_events)
				if result.code ~= "success" then return { code = result.code, message = result.message, completed = completed } end
			elseif event.op == "invoke" then
				if not valid_text(event.callback_id, 128) or type(callbacks[event.callback_id]) ~= "function" then
					return { code = "invalid", message = "replay callback is not registered at index " .. tostring(index), completed = completed }
				end
				local ok, err = pcall(callbacks[event.callback_id], self, clone(event.args))
				if not ok then
					self:_trace(event.server or "simulator", event.operation_id, event.key_family or "scenario", event.callback_id, "failed", tostring(err):sub(1, 240))
					return { code = "callback_failed", message = tostring(err), completed = completed }
				end
			elseif event.op == "assert_invariant" then
				local ok, violation = self:CheckInvariant(event.name, event.context)
				if not ok then return { code = "invariant_failed", violation = violation, completed = completed } end
			else
				return { code = "invalid", message = "unsupported replay operation: " .. event.op, completed = completed }
			end
			completed += 1
		end
		return { code = "success", completed = completed, stats = self:Stats() }
	end

	function self:SerializeScript(script)
		local valid = dense_array(script, MAX_EVENTS)
		if not valid then error("scenario script must be a dense bounded array", 2) end
		local encoded = serde.encode("json", script)
		if #encoded > MAX_SCRIPT_BYTES then error("serialized scenario exceeds 1 MiB", 2) end
		return encoded
	end

	function self:LoadSerializedScript(encoded)
		if type(encoded) ~= "string" or #encoded > MAX_SCRIPT_BYTES then
			return nil, "serialized scenario must be a string no larger than 1 MiB"
		end
		local ok, decoded = pcall(function() return serde.decode("json", encoded) end)
		if not ok then return nil, "serialized scenario is not valid JSON" end
		local valid = dense_array(decoded, MAX_EVENTS)
		if not valid then return nil, "serialized scenario is not a dense bounded array" end
		return decoded, nil
	end

	self._sim = self
	return self
end

return Simulator
