--!strict
local AtomicTombstone = {}

export type Key = {
	name: string?,
	store_name: string?,
	scope: string,
	key: string,
}

export type Options = {
	store_name: string,
	scope: string,
	key_prefix: string?,
	job_id: string,
	generation_field: string?,
	job_fence_field: string?,
	new_get_options: (() -> any)?,
	now_unix: (() -> number)?,
	is_eligible: (unknown, any, number, string) -> boolean,
	dependencies_clear: (unknown, any, number, string) -> boolean,
	make_tombstone: (unknown, any, number, string, number) -> unknown?,
	is_tombstone: (unknown, number, string) -> boolean,
}

export type Adapter = {
	FenceIfGeneration: (self: Adapter, store: any, item: unknown, expected_generation: number, job_id: string) -> (string, number?, string?),
	DeleteIfGeneration: (self: Adapter, store: any, item: unknown, expected_generation: number, job_id: string) -> (string, string?),
	FenceAndDeleteIfGeneration: (self: Adapter, store: any, item: unknown, expected_generation: number, job_id: string) -> (string, string?),
}

local MAX_KEY_BYTES = 50
local MAX_JOB_ID_BYTES = 96
local MAX_FIELD_BYTES = 128
local MAX_GENERATION = 9007199254740991

local function valid_text(value: unknown, maximum: number, allow_empty: boolean?): boolean
	return type(value) == "string"
		and (allow_empty == true or value ~= "")
		and #value <= maximum
		and string.find(value, "%c") == nil
end

local function generation(value: unknown): boolean
	return type(value) == "number"
		and math.isfinite(value)
		and value >= 0
		and value <= MAX_GENERATION
		and math.floor(value) == value
end

local function clone(value: unknown, seen: { [any]: any }?): any
	if type(value) ~= "table" then return value end
	local source = value :: { [any]: any }
	local memo = seen or {}
	local prior = memo[source]
	if prior ~= nil then return prior end
	local result: { [any]: any } = {}
	memo[source] = result
	for key, child in pairs(source) do
		result[clone(key, memo)] = clone(child, memo)
	end
	return result
end

local function invoke_pure(callback: (...any) -> any, ...: any): (boolean, any, string?)
	local arguments = table.pack(...)
	local returned: { [number]: any }? = nil
	local thread = coroutine.create(function()
		returned = table.pack(pcall(callback, table.unpack(arguments, 1, arguments.n)))
	end)
	local resumed, resume_error = coroutine.resume(thread)
	if not resumed then return false, nil, tostring(resume_error) end
	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		return false, nil, "maintenance mutation callbacks must not yield"
	end
	local result = returned
	if result == nil then return false, nil, "maintenance mutation callback did not return" end
	if result[1] ~= true then return false, nil, tostring(result[2]) end
	return true, result[2], nil
end

local function default_get_options(factory: (() -> any)?): any
	local options = if factory ~= nil then factory() else Instance.new("DataStoreGetOptions")
	if options == nil then error("could not create DataStoreGetOptions", 3) end
	options.UseCache = false
	return options
end

local function callback_boolean(
	callback: (...any) -> any,
	value: unknown,
	key_info: any,
	expected_generation: number,
	job_id: string
): (boolean, string?)
	local ok, allowed, message = invoke_pure(callback, value, key_info, expected_generation, job_id)
	if not ok then return false, message end
	if type(allowed) ~= "boolean" then return false, "maintenance policy callback did not return a boolean" end
	return allowed, if type(message) == "string" then message else nil
end

function AtomicTombstone.new(config: Options): Adapter
	if type(config) ~= "table" then error("config must be a table", 2) end
	if not valid_text(config.store_name, MAX_KEY_BYTES) then error("store_name is invalid", 2) end
	if not valid_text(config.scope, MAX_KEY_BYTES, true) then error("scope is invalid", 2) end
	local prefix = if config.key_prefix == nil then "" else config.key_prefix
	if not valid_text(prefix, MAX_KEY_BYTES, true) then error("key_prefix is invalid", 2) end
	if not valid_text(config.job_id, MAX_JOB_ID_BYTES) then error("job_id is invalid", 2) end

	local generation_field = if config.generation_field == nil then "fencing_generation" else config.generation_field
	local job_fence_field = if config.job_fence_field == nil then "maintenance_fence_job_id" else config.job_fence_field
	if not valid_text(generation_field, MAX_FIELD_BYTES) or not valid_text(job_fence_field, MAX_FIELD_BYTES)
		or generation_field == job_fence_field
	then
		error("generation_field and job_fence_field must be distinct valid top-level fields", 2)
	end
	if config.new_get_options ~= nil and type(config.new_get_options) ~= "function" then
		error("new_get_options must be a function", 2)
	end
	if config.now_unix ~= nil and type(config.now_unix) ~= "function" then
		error("now_unix must be a function", 2)
	end
	if type(config.is_eligible) ~= "function"
		or type(config.dependencies_clear) ~= "function"
		or type(config.make_tombstone) ~= "function"
		or type(config.is_tombstone) ~= "function"
	then
		error("eligibility, dependency, tombstone creation, and tombstone verification callbacks are required", 2)
	end

	local get_options = function()
		return default_get_options(config.new_get_options)
	end
	local now_unix = config.now_unix or os.time

	local function read_fresh(store: any, key: string): (unknown, any?, string?)
		local ok, value, key_info = pcall(function()
			return store:GetAsync(key, get_options())
		end)
		if not ok then return nil, nil, tostring(value) end
		return value, key_info, nil
	end

	local function matches_tombstone(value: unknown, expected_generation: number, job_id: string): (boolean, string?)
		local ok, matched, message = invoke_pure(config.is_tombstone, value, expected_generation, job_id)
		if not ok then return false, message end
		if type(matched) ~= "boolean" then return false, "is_tombstone must return a boolean" end
		return matched, if type(message) == "string" then message else nil
	end

	local function classify_readback(
		value: unknown,
		key_info: any,
		expected_generation: number,
		job_id: string
	): (string, string?)
		if value == nil then return "already_absent", nil end
		local tombstone, tombstone_error = matches_tombstone(value, expected_generation, job_id)
		if tombstone then return "deleted", nil end
		if tombstone_error ~= nil then return "unknown", "could not validate tombstone after UpdateAsync: " .. tombstone_error end
		if type(value) ~= "table" then return "unknown", "observed record is not a table" end
		local raw = value :: { [string]: unknown }
		local current_generation = raw[generation_field]
		if not generation(current_generation) then return "unknown", "observed record has no valid fencing generation" end
		if current_generation ~= expected_generation then return "skipped", "record generation changed before the tombstone was confirmed" end
		if raw[job_fence_field] ~= job_id then return "skipped", "same-key job fence does not match this maintenance job" end
		local eligible, eligibility_error = callback_boolean(
			config.is_eligible, clone(value), key_info, expected_generation, job_id
		)
		if not eligible then
			return if eligibility_error == nil then "skipped" else "unknown",
				eligibility_error or "record is no longer eligible for maintenance deletion"
		end
		local dependencies_clear, dependency_error = callback_boolean(
			config.dependencies_clear, clone(value), key_info, expected_generation, job_id
		)
		if not dependencies_clear then
			return if dependency_error == nil then "skipped" else "unknown",
				dependency_error or "record dependencies are not confirmed clear"
		end
		return "unknown", "UpdateAsync did not confirm an expected-generation tombstone"
	end

	local self: any = {}

	local function classify_fence_readback(
		value: unknown,
		key_info: any,
		expected_generation: number,
		job_id: string
	): (string, number?, string?)
		if value == nil then return "skipped", nil, "maintenance target is absent" end
		if type(value) ~= "table" then return "unknown", nil, "observed target is not a table" end
		local raw = value :: { [string]: unknown }
		local current_generation = raw[generation_field]
		if not generation(current_generation) then
			return "unknown", nil, "observed target has no valid fencing generation"
		end
		if current_generation == expected_generation + 1 and raw[job_fence_field] == job_id then
			return "fenced", expected_generation + 1, nil
		end
		if current_generation ~= expected_generation then
			return "skipped", nil, "target generation changed before the maintenance fence was acquired"
		end
		if raw[job_fence_field] ~= nil and raw[job_fence_field] ~= job_id then
			return "skipped", nil, "a different maintenance job owns the same-key fence"
		end
		local eligible, eligibility_error = callback_boolean(
			config.is_eligible, clone(value), key_info, expected_generation, job_id
		)
		if not eligible then
			return if eligibility_error == nil then "skipped" else "unknown", nil,
				eligibility_error or "record is no longer eligible for maintenance"
		end
		local dependencies_clear, dependency_error = callback_boolean(
			config.dependencies_clear, clone(value), key_info, expected_generation, job_id
		)
		if not dependencies_clear then
			return if dependency_error == nil then "skipped" else "unknown", nil,
				dependency_error or "record dependencies are not confirmed clear"
		end
		return "unknown", nil, "UpdateAsync did not confirm the same-key maintenance fence"
	end

	function self:FenceIfGeneration(
		store: any,
		item: unknown,
		expected_generation: number,
		job_id: string
	): (string, number?, string?)
		if type(store) ~= "table" and type(store) ~= "userdata" then return "unknown", nil, "target DataStore is unavailable" end
		if type(item) ~= "table" then return "skipped", nil, "maintenance locator must be a table" end
		if not generation(expected_generation) or expected_generation > MAX_GENERATION - 2 then
			return "skipped", nil, "expected generation is invalid or cannot be safely fenced and tombstoned"
		end
		if job_id ~= config.job_id then return "skipped", nil, "job identity does not match the configured maintenance job" end

		local locator = item :: { [string]: unknown }
		local name = if type(locator.name) == "string" then locator.name else locator.store_name
		local scope = locator.scope
		local key = locator.key
		if name ~= config.store_name or scope ~= config.scope or not valid_text(key, MAX_KEY_BYTES)
			or (prefix ~= "" and string.sub(key :: string, 1, #prefix) ~= prefix)
		then
			return "skipped", nil, "maintenance locator is outside the configured store/scope/prefix"
		end

		local update_ok, updated_or_error = pcall(function()
			return store:UpdateAsync(key :: string, function(current: unknown, key_info: any): unknown?
				if type(current) ~= "table" then return nil end
				local raw = current :: { [string]: unknown }
				local current_generation = raw[generation_field]
				if current_generation == expected_generation + 1 and raw[job_fence_field] == job_id then
					return clone(current)
				end
				if not generation(current_generation) or current_generation ~= expected_generation then return nil end
				if raw[job_fence_field] ~= nil and raw[job_fence_field] ~= job_id then return nil end

				local eligible = callback_boolean(
					config.is_eligible, clone(current), key_info, expected_generation, job_id
				)
				if not eligible then return nil end
				local dependencies_clear = callback_boolean(
					config.dependencies_clear, clone(current), key_info, expected_generation, job_id
				)
				if not dependencies_clear then return nil end

				local fenced = clone(current) :: { [string]: unknown }
				fenced[generation_field] = expected_generation + 1
				fenced[job_fence_field] = job_id
				if fenced[generation_field] ~= expected_generation + 1 or fenced[job_fence_field] ~= job_id then
					return nil
				end
				return fenced
			end)
		end)
		if update_ok then
			local action, fenced_generation, message = classify_fence_readback(
				updated_or_error, nil, expected_generation, job_id
			)
			if action == "fenced" then return action, fenced_generation, nil end
			if action == "unknown" then
				local readback, key_info, read_error = read_fresh(store, key :: string)
				if read_error ~= nil then return "unknown", nil, (message or "maintenance fence outcome unresolved") .. "; readback failed: " .. read_error end
				return classify_fence_readback(readback, key_info, expected_generation, job_id)
			end
		end

		local readback, key_info, read_error = read_fresh(store, key :: string)
		if read_error ~= nil then
			return "unknown", nil, "maintenance fence outcome is unresolved"
				.. (if not update_ok then ": " .. tostring(updated_or_error) else "")
				.. "; uncached readback failed: " .. read_error
		end
		local action, fenced_generation, message = classify_fence_readback(
			readback, key_info, expected_generation, job_id
		)
		if action == "unknown" and not update_ok then
			return "unknown", nil, "UpdateAsync outcome is unresolved: " .. tostring(updated_or_error)
				.. (message and "; " .. message or "")
		end
		return action, fenced_generation, message
	end

	function self:FenceAndDeleteIfGeneration(
		store: any,
		item: unknown,
		expected_generation: number,
		job_id: string
	): (string, string?)
		local fence_action, fenced_generation, fence_error = self:FenceIfGeneration(
			store, item, expected_generation, job_id
		)
		if fence_action == "fenced" and fenced_generation ~= nil then
			local delete_action, delete_error = self:DeleteIfGeneration(
				store, item, fenced_generation, job_id
			)
			if delete_action == "deleted" then return "deleted", nil end
			local locator = if type(item) == "table" then item :: { [string]: unknown } else nil
			local name = if locator ~= nil and type(locator.name) == "string" then locator.name
				elseif locator ~= nil then locator.store_name else nil
			local key = if locator ~= nil then locator.key else nil
			if name == config.store_name and locator ~= nil and locator.scope == config.scope
				and valid_text(key, MAX_KEY_BYTES)
				and (prefix == "" or string.sub(key :: string, 1, #prefix) == prefix)
			then
				local observed, _, read_error = read_fresh(store, key :: string)
				if read_error == nil then
					local committed, validation_error = matches_tombstone(observed, fenced_generation, job_id)
					if committed then return "deleted", nil end
					if validation_error ~= nil and delete_action == "unknown" then
						return "unknown", validation_error
					end
				elseif delete_action == "unknown" then
					return "unknown", (delete_error or "tombstone outcome unresolved") .. "; readback failed: " .. read_error
				end
			end
			return delete_action, delete_error
		end

		if job_id == config.job_id and generation(expected_generation)
			and expected_generation <= MAX_GENERATION - 2 and type(store) == "table"
			and type(item) == "table"
		then
			local locator = item :: { [string]: unknown }
			local name = if type(locator.name) == "string" then locator.name else locator.store_name
			local key = locator.key
			if name == config.store_name and locator.scope == config.scope
				and valid_text(key, MAX_KEY_BYTES)
				and (prefix == "" or string.sub(key :: string, 1, #prefix) == prefix)
			then
				local observed, _, read_error = read_fresh(store, key :: string)
				if read_error == nil then
					local committed, validation_error = matches_tombstone(observed, expected_generation + 1, job_id)
					if committed then return "deleted", nil end
					if validation_error ~= nil and fence_action == "unknown" then return "unknown", validation_error end
				elseif fence_action == "unknown" then
					return "unknown", (fence_error or "maintenance fence outcome unresolved") .. "; readback failed: " .. read_error
				end
			end
		end
		return fence_action, fence_error
	end

	function self:DeleteIfGeneration(
		store: any,
		item: unknown,
		expected_generation: number,
		job_id: string
	): (string, string?)
		if type(store) ~= "table" and type(store) ~= "userdata" then return "unknown", "target DataStore is unavailable" end
		if type(item) ~= "table" then return "skipped", "maintenance locator must be a table" end
		if not generation(expected_generation) or expected_generation >= MAX_GENERATION then
			return "skipped", "expected generation is invalid or cannot be advanced safely"
		end
		if job_id ~= config.job_id then return "skipped", "job identity does not match the configured maintenance job" end

		local locator = item :: { [string]: unknown }
		local name = if type(locator.name) == "string" then locator.name else locator.store_name
		local scope = locator.scope
		local key = locator.key
		if name ~= config.store_name or scope ~= config.scope or not valid_text(key, MAX_KEY_BYTES)
			or (prefix ~= "" and string.sub(key :: string, 1, #prefix) ~= prefix)
		then
			return "skipped", "maintenance locator is outside the configured store/scope/prefix"
		end

		local now_ok, now = pcall(now_unix)
		if not now_ok or type(now) ~= "number" or not math.isfinite(now) or now < 0 then
			return "unknown", "maintenance clock did not return a finite non-negative timestamp"
		end

		local update_ok, updated_or_error = pcall(function()
			return store:UpdateAsync(key :: string, function(current: unknown, key_info: any): unknown?
				if current == nil then return nil end
				if type(current) ~= "table" then return nil end
				local raw = current :: { [string]: unknown }
				local current_generation = raw[generation_field]
				if not generation(current_generation) or current_generation ~= expected_generation then return nil end
				if raw[job_fence_field] ~= job_id then return nil end

				local eligible = callback_boolean(
					config.is_eligible, clone(current), key_info, expected_generation, job_id
				)
				if not eligible then return nil end
				local dependencies_clear = callback_boolean(
					config.dependencies_clear, clone(current), key_info, expected_generation, job_id
				)
				if not dependencies_clear then return nil end

				local snapshot = clone(current)
				local tombstone_ok, tombstone = invoke_pure(
					config.make_tombstone, snapshot, key_info, expected_generation, job_id, now
				)
				if not tombstone_ok or type(tombstone) ~= "table" then return nil end
				local candidate = tombstone :: { [string]: unknown }
				if candidate[generation_field] ~= expected_generation + 1
					or candidate[job_fence_field] ~= job_id
				then
					return nil
				end
				local candidate_matches, _ = matches_tombstone(tombstone, expected_generation, job_id)
				if not candidate_matches then return nil end
				return tombstone
			end)
		end)

		if update_ok then
			local tombstone, tombstone_error = matches_tombstone(updated_or_error, expected_generation, job_id)
			if tombstone then return "deleted", nil end
			if tombstone_error ~= nil then
				local readback, _, read_error = read_fresh(store, key :: string)
				if read_error ~= nil then return "unknown", tombstone_error .. "; readback failed: " .. read_error end
				return classify_readback(readback, nil, expected_generation, job_id)
			end
		end

		local readback, readback_info, read_error = read_fresh(store, key :: string)
		if read_error ~= nil then
			return "unknown", "tombstone outcome is unresolved"
				.. (if not update_ok then ": " .. tostring(updated_or_error) else "")
				.. "; uncached readback failed: " .. read_error
		end
		local action, message = classify_readback(readback, readback_info, expected_generation, job_id)
		if action == "unknown" and not update_ok then
			return "unknown", "UpdateAsync outcome is unresolved: " .. tostring(updated_or_error)
				.. (message and "; " .. message or "")
		end
		return action, message
	end

	return table.freeze(self) :: Adapter
end

return AtomicTombstone
