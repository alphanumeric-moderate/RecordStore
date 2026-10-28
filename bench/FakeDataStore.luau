--!nocheck
local datetime = require("@lune/datetime")
local task = require("@lune/task")
local serde = require("@lune/serde")

local FakeDataStore = {}

local function clone(value, seen)
	if type(value) ~= "table" then
		return value
	end
	seen = seen or {}
	assert(not seen[value], "fake DataStore refuses cyclic values")
	seen[value] = true
	local result = {}
	for key, child in pairs(value) do
		result[clone(key, seen)] = clone(child, seen)
	end
	seen[value] = nil
	return result
end

local function store_identity(name, scope)
	return serde.encode("json", { name, scope })
end

local function key_info(entry)
	if entry == nil then
		return nil
	end
	local info = {
		Version = entry.Version,
		CreatedTime = entry.CreatedTime,
		UpdatedTime = entry.UpdatedTime,
	}
	function info:GetUserIds()
		return clone(entry.UserIds)
	end
	function info:GetMetadata()
		return clone(entry.Metadata)
	end
	return info
end

function FakeDataStore.new(options)
	options = options or {}
	local state = {
		records = {},
		versions = {},
		version_counter = 0,
		get_calls = 0,
		update_calls = 0,
		fresh_get_calls = 0,
		cache_get_calls = 0,
		transform_calls = 0,
		transform_replays = 0,
		active_requests = 0,
		max_active_requests = 0,
		read_failures = 0,
		update_faults = {},
		next_replay_count = 0,
		cache_updates_enabled = true,
		inside_transform = false,
		locks = {},
		budgets = {
			StandardRead = math.huge,
			StandardWrite = math.huge,
			StandardList = math.huge,
			StandardRemove = math.huge,
		},
		delay_seconds = options.delay_seconds or 0,
		cache_seconds = options.cache_seconds or 4,
	}

	local function enter_request()
		state.active_requests += 1
		state.max_active_requests = math.max(state.max_active_requests, state.active_requests)
	end

	local function leave_request()
		state.active_requests -= 1
		assert(state.active_requests >= 0, "fake DataStore request counter underflowed")
	end

	local function get_record_key(name, scope, key)
		return store_identity(name, scope) .. ":" .. tostring(#key) .. ":" .. key
	end

	local function get_current(name, scope, key)
		return state.records[get_record_key(name, scope, key)]
	end

	local function new_store(name, scope)
		local cache = {}
		local Store = {}

		function Store:GetAsync(key, get_options)
			assert(not state.inside_transform, "DataStore reads must not run inside UpdateAsync transforms")
			state.get_calls += 1
			local use_cache = get_options == nil or get_options.UseCache ~= false
			if use_cache then
				local cached = cache[key]
				if cached ~= nil and os.clock() - cached.at < state.cache_seconds then
					state.cache_get_calls += 1
					return clone(cached.value), clone(cached.info)
				end
			else
				state.fresh_get_calls += 1
			end

			enter_request()
			local call_ok, value, info = pcall(function()
				if state.delay_seconds > 0 then
					task.wait(state.delay_seconds)
				end
				if state.read_failures > 0 then
					state.read_failures -= 1
					error("injected fake DataStore read failure", 0)
				end
				local entry = get_current(name, scope, key)
				return if entry == nil then nil else clone(entry.Value),
					if entry == nil then nil else key_info(entry)
			end)
			leave_request()
			if not call_ok then
				error(value, 0)
			end
			if use_cache then
				cache[key] = { at = os.clock(), value = clone(value), info = clone(info) }
			end
			return value, info
		end

		function Store:UpdateAsync(key, transform)
			assert(not state.inside_transform, "nested DataStore update attempted inside UpdateAsync transform")
			state.update_calls += 1
			enter_request()
			local call_ok, result, info = pcall(function()
				if state.delay_seconds > 0 then
					task.wait(state.delay_seconds)
				end

				local identity = get_record_key(name, scope, key)
				while state.locks[identity] do
					task.wait(0.001)
				end
				state.locks[identity] = true

				local previous = state.records[identity]
				local previous_value = if previous == nil then nil else clone(previous.Value)
				local previous_info = key_info(previous)
				local replay_count = state.next_replay_count
				state.next_replay_count = 0
				local new_value, user_ids, metadata
				for _ = 0, replay_count do
					state.transform_calls += 1
					state.inside_transform = true
					local transform_ok
					transform_ok, new_value, user_ids, metadata = pcall(
						transform,
						clone(previous_value),
						clone(previous_info)
					)
					state.inside_transform = false
					if not transform_ok then
						state.locks[identity] = nil
						error(new_value, 0)
					end
					if new_value == nil then
						state.locks[identity] = nil
						return nil, previous_info
					end
				end

				local fault = table.remove(state.update_faults, 1)
				if fault == "before_commit" then
					state.locks[identity] = nil
					error("injected fake DataStore failure before commit", 0)
				end

				state.version_counter += 1
				local now = datetime.now().unixTimestampMillis
				local entry = {
					Value = clone(new_value),
					UserIds = clone(user_ids or (previous and previous.UserIds) or {}),
					Metadata = clone(metadata or (previous and previous.Metadata) or {}),
					Version = ("fake-version-%d"):format(state.version_counter),
					CreatedTime = if previous ~= nil then previous.CreatedTime else now,
					UpdatedTime = now,
				}
				state.records[identity] = entry
				local history = state.versions[identity]
				if history == nil then
					history = {}
					state.versions[identity] = history
				end
				table.insert(history, clone(entry))
				if state.cache_updates_enabled then
					cache[key] = { at = os.clock(), value = clone(entry.Value), info = clone(key_info(entry)) }
				end
				state.locks[identity] = nil

				if fault == "commit_then_error" then
					error("injected fake DataStore response loss after durable commit", 0)
				end
				return clone(entry.Value), key_info(entry)
			end)
			state.inside_transform = false
			leave_request()
			if not call_ok then
				error(result, 0)
			end
			return result, info
		end

		function Store:GetVersionAsync(key, version)
			assert(not state.inside_transform, "version reads must not run inside UpdateAsync transforms")
			local history = state.versions[get_record_key(name, scope, key)] or {}
			for _, entry in ipairs(history) do
				if entry.Version == version then
					return clone(entry.Value), key_info(entry)
				end
			end
			return nil, nil
		end

		function Store:ListVersionsAsync(key, sort_direction, min_date, max_date, page_size)
			local history = state.versions[get_record_key(name, scope, key)] or {}
			local entries = {}
			for index = #history, 1, -1 do
				local entry = history[index]
				entries[#entries + 1] = {
					Version = entry.Version,
					CreatedTime = entry.CreatedTime,
					UpdatedTime = entry.UpdatedTime,
					IsDeleted = false,
				}
				if page_size ~= nil and #entries >= page_size then
					break
				end
			end
			local page = {}
			function page:GetCurrentPage()
				return clone(entries)
			end
			function page:AdvanceToNextPageAsync()
				error("fake DataStore history adapter only supports its first bounded page", 0)
			end
			return page
		end

		return Store
	end

	local service = {}

	function service:GetDataStore(name, scope)
		assert(type(name) == "string" and name ~= "", "invalid fake DataStore name")
		return new_store(name, scope or "global")
	end

	function service:GetRequestBudgetForRequestType(request_type)
		local name = if type(request_type) == "table" then request_type.Name else tostring(request_type)
		return state.budgets[name] or 0
	end

	local control = {}

	function control:set_budget(name, value)
		assert(type(value) == "number" and value >= 0, "budget must be non-negative")
		state.budgets[name] = value
	end

	function control:set_cache_updates_enabled(enabled)
		assert(type(enabled) == "boolean", "cache update setting must be a boolean")
		state.cache_updates_enabled = enabled
	end

	function control:set_delay(seconds)
		assert(type(seconds) == "number" and seconds >= 0 and math.isfinite(seconds), "delay must be finite and non-negative")
		state.delay_seconds = seconds
	end

	function control:replace_raw(name, scope, key, value, user_ids, metadata)
		assert(not state.inside_transform, "external fixture replacement is forbidden inside UpdateAsync transforms")
		local identity = get_record_key(name, scope or "global", key)
		local previous = state.records[identity]
		state.version_counter += 1
		local now = datetime.now().unixTimestampMillis
		local entry = {
			Value = clone(value),
			UserIds = clone(user_ids or (previous and previous.UserIds) or {}),
			Metadata = clone(metadata or (previous and previous.Metadata) or {}),
			Version = ("fake-version-%d"):format(state.version_counter),
			CreatedTime = if previous ~= nil then previous.CreatedTime else now,
			UpdatedTime = now,
		}
		state.records[identity] = entry
		local history = state.versions[identity]
		if history == nil then
			history = {}
			state.versions[identity] = history
		end
		table.insert(history, clone(entry))
	end

	function control:fail_next_get(count)
		assert(type(count) == "number" and count >= 0 and math.floor(count) == count)
		state.read_failures = count
	end

	function control:fail_next_update(mode)
		assert(mode == "before_commit" or mode == "commit_then_error", "unsupported update fault")
		table.insert(state.update_faults, mode)
	end

	function control:replay_next_update(count)
		assert(type(count) == "number" and count >= 0 and count <= 20 and math.floor(count) == count)
		state.next_replay_count = count
	end

	function control:get_raw(name, scope, key)
		local entry = get_current(name, scope or "global", key)
		return if entry == nil then nil else clone(entry.Value)
	end

	function control:get_key_info(name, scope, key)
		return key_info(get_current(name, scope or "global", key))
	end

	function control:metrics()
		return {
			get_calls = state.get_calls,
			update_calls = state.update_calls,
			fresh_get_calls = state.fresh_get_calls,
			cache_get_calls = state.cache_get_calls,
			transform_calls = state.transform_calls,
			transform_replays = state.transform_replays,
			active_requests = state.active_requests,
			max_active_requests = state.max_active_requests,
		}
	end

	return {
		service = service,
		control = control,
	}
end

return FakeDataStore
