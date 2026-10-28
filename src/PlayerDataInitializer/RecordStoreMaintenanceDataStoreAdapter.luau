--!strict
local DataStoreService = game:GetService("DataStoreService")

local Adapter = {}

export type Inspection = {
	status: string,
	eligible: boolean?,
	dependencies_clear: boolean?,
	generation: number?,
	message: string?,
}

type FamilyInspection = {
	status: string,
	eligible: boolean,
	dependencies_clear: boolean,
	[string]: any,
}

export type Family = {
	name: string,
	store_name: string,
	scope: string?,
	prefix: string?,
	get_generation: (value: unknown, key_info: any) -> number?,
	inspect: (key: string, value: unknown, key_info: any) -> (FamilyInspection?, string?),
	can_delete: (value: unknown, key_info: any, expected_generation: number, job_id: string) -> boolean,
	make_tombstone: (value: unknown, key_info: any, expected_generation: number, job_id: string) -> unknown?,
	is_tombstone: (value: unknown, expected_generation: number, job_id: string) -> boolean,
	delete_if_generation: ((store: any, item: any, expected_generation: number, job_id: string) -> (string, string?))?,
}

export type Config = {
	job_id: string,
	catalog_revision: string,
	families: { Family },
	checkpoint_store_name: string,
	checkpoint_scope: string?,
	checkpoint_key: string,
	maintenance: any,
	maintenance_runner: any,
	mode: string?,
	initial_cursor: string?,
	authorize: ((string) -> (boolean, string?))?,
	assert_fence: ((string) -> (boolean, string?))?,
	data_store_service: any?,
	instance_factory: ((string) -> Instance)?,
}

type Checkpoint = {
	version: number,
	job_id: string,
	revision: number,
	cursor: string?,
	processed: number,
	removed: number,
	status: string,
}

type CatalogItem = {
	family_name: string,
	store_name: string,
	scope: string,
	key: string,
}

local MAX_FAMILIES = 128
local MAX_PAGE_SIZE = 100
local MAX_CURSOR_BYTES = 512
local MAX_NAME_BYTES = 50

local CHECKPOINT_STATUSES = {
	idle = true,
	incomplete = true,
	completed = true,
	unknown = true,
	paused = true,
}

local function valid_text(value: unknown, maximum: number): boolean
	return type(value) == "string" and value ~= "" and #value <= maximum
end

local function nonnegative_integer(value: unknown): boolean
	return type(value) == "number"
		and math.isfinite(value)
		and value >= 0
		and math.floor(value) == value
end

local function copy_checkpoint(value: Checkpoint): Checkpoint
	return {
		version = value.version,
		job_id = value.job_id,
		revision = value.revision,
		cursor = value.cursor,
		processed = value.processed,
		removed = value.removed,
		status = value.status,
	}
end

local function inspection_failure(status: string, message: string): Inspection
	return {
		status = status,
		eligible = nil,
		dependencies_clear = nil,
		generation = nil,
		message = message,
	}
end

local function valid_checkpoint(value: unknown, job_id: string): Checkpoint?
	if type(value) ~= "table" then
		return nil
	end
	local checkpoint = value :: { [string]: unknown }
	if checkpoint.version ~= 1
		or checkpoint.job_id ~= job_id
		or not nonnegative_integer(checkpoint.revision)
		or (checkpoint.cursor ~= nil and not valid_text(checkpoint.cursor, MAX_CURSOR_BYTES))
		or not nonnegative_integer(checkpoint.processed)
		or not nonnegative_integer(checkpoint.removed)
		or (checkpoint.removed :: number) > (checkpoint.processed :: number)
		or type(checkpoint.status) ~= "string"
		or CHECKPOINT_STATUSES[checkpoint.status :: string] ~= true
		or (checkpoint.status == "completed" and checkpoint.cursor ~= nil)
		or (checkpoint.status == "incomplete" and checkpoint.cursor == nil)
	then
		return nil
	end
	return {
		version = 1,
		job_id = job_id,
		revision = checkpoint.revision :: number,
		cursor = checkpoint.cursor :: string?,
		processed = checkpoint.processed :: number,
		removed = checkpoint.removed :: number,
		status = checkpoint.status :: string,
	}
end

local function same_checkpoint(left: Checkpoint?, right: Checkpoint): boolean
	return left ~= nil
		and left.version == right.version
		and left.job_id == right.job_id
		and left.revision == right.revision
		and left.cursor == right.cursor
		and left.processed == right.processed
		and left.removed == right.removed
		and left.status == right.status
end

local function normalized_scope(scope: string?): string
	return if scope == nil or scope == "" then "global" else scope
end

local function same_store(left: Family, right: Family): boolean
	return left.store_name == right.store_name and normalized_scope(left.scope) == normalized_scope(right.scope)
end

local function prefixes_overlap(left: string, right: string): boolean
	return left == ""
		or right == ""
		or string.sub(left, 1, #right) == right
		or string.sub(right, 1, #left) == left
end

function Adapter.new(config: Config)
	if type(config) ~= "table" then
		error("config must be a table", 2)
	end
	if not valid_text(config.job_id, 96) then
		error("job_id must be 1 to 96 bytes", 2)
	end
	if not valid_text(config.catalog_revision, 80)
		or string.find(config.catalog_revision, "|", 1, true) ~= nil
	then
		error("catalog_revision must be 1 to 80 bytes and must not contain |", 2)
	end
	if type(config.families) ~= "table" or #config.families < 1 or #config.families > MAX_FAMILIES then
		error("families must be a dense array containing 1 to 128 explicit DataStore key families", 2)
	end
	local family_count = #config.families
	local observed_family_count = 0
	for family_index in pairs(config.families) do
		if type(family_index) ~= "number"
			or not math.isfinite(family_index)
			or math.floor(family_index) ~= family_index
			or family_index < 1
			or family_index > family_count
		then
			error("families must be a dense array", 2)
		end
		observed_family_count += 1
	end
	if observed_family_count ~= family_count then
		error("families must be a dense array", 2)
	end
	if not valid_text(config.checkpoint_store_name, MAX_NAME_BYTES)
		or type(config.checkpoint_scope) == "string" and #config.checkpoint_scope > MAX_NAME_BYTES
		or not valid_text(config.checkpoint_key, MAX_NAME_BYTES)
	then
		error("checkpoint store, scope, and key are invalid", 2)
	end
	if type(config.maintenance) ~= "table" or type(config.maintenance.NewCompactor) ~= "function" then
		error("maintenance must expose NewCompactor", 2)
	end
	if type(config.maintenance_runner) ~= "table" or type(config.maintenance_runner.new) ~= "function" then
		error("maintenance_runner must expose new", 2)
	end

	local service = config.data_store_service or DataStoreService
	local instance_factory: (string) -> Instance
	if config.instance_factory ~= nil then
		instance_factory = config.instance_factory
	else
		instance_factory = function(class_name: string): Instance
			return Instance.new(class_name)
		end
	end
	local families: { Family } = table.create(family_count)
	for index, family in ipairs(config.families) do
		if type(family) ~= "table" then
			error("family " .. tostring(index) .. " must be a table", 2)
		end
		families[index] = table.freeze(table.clone(family)) :: Family
	end
	local family_by_name: { [string]: Family } = {}
	local store_cache: { [string]: any } = {}
	local all_family_names: { [string]: boolean } = {}

	for index, family in ipairs(families) do
		if type(family) ~= "table"
			or not valid_text(family.name, 64)
			or not valid_text(family.store_name, MAX_NAME_BYTES)
			or (family.scope ~= nil and (type(family.scope) ~= "string" or #family.scope > MAX_NAME_BYTES))
			or (family.prefix ~= nil and (type(family.prefix) ~= "string" or #family.prefix > MAX_NAME_BYTES))
			or type(family.get_generation) ~= "function"
			or type(family.inspect) ~= "function"
			or type(family.can_delete) ~= "function"
			or type(family.make_tombstone) ~= "function"
			or type(family.is_tombstone) ~= "function"
			or (family.delete_if_generation ~= nil and type(family.delete_if_generation) ~= "function")
		then
			error("family " .. tostring(index) .. " is missing a valid store identity or required schema callbacks", 2)
		end
		if family_by_name[family.name] ~= nil then
			error("family names must be unique", 2)
		end
		family_by_name[family.name] = family
		all_family_names[family.name] = true
	end
	for _, family in ipairs(families) do
		if family.store_name == config.checkpoint_store_name
			and normalized_scope(family.scope) == normalized_scope(config.checkpoint_scope)
		then
			error("checkpoint store/scope must be separate from every catalog data family", 2)
		end
	end
	for left_index, left in ipairs(families) do
		for right_index = left_index + 1, #families do
			local right = families[right_index]
			if same_store(left, right)
				and prefixes_overlap(left.prefix or "", right.prefix or "")
			then
				error("key-family prefixes must not overlap within the same DataStore and scope", 2)
			end
		end
	end
	table.freeze(families)

	local function get_store(name: string, scope: string?): any
		local cache_key = name .. "\n" .. normalized_scope(scope)
		local cached = store_cache[cache_key]
		if cached ~= nil then
			return cached
		end
		local store = if scope == nil or scope == "" then service:GetDataStore(name) else service:GetDataStore(name, scope)
		store_cache[cache_key] = store
		return store
	end

	local function get_options(): DataStoreGetOptions
		local options = instance_factory("DataStoreGetOptions") :: DataStoreGetOptions
		options.UseCache = false
		return options
	end

	local function read_fresh(store: any, key: string): (unknown, any?, string?)
		local ok, value, key_info = pcall(function()
			return store:GetAsync(key, get_options())
		end)
		if not ok then
			return nil, nil, tostring(value)
		end
		return value, key_info, nil
	end

	local function parse_cursor(cursor: string?): (number, string?)
		if cursor == nil then
			return 1, nil
		end
		if #cursor > MAX_CURSOR_BYTES then
			error("maintenance catalog cursor exceeds 512 bytes", 3)
		end
		local revision, rest = string.match(cursor, "^([^|]+)|(.+)$")
		if revision ~= config.catalog_revision or rest == nil then
			error("maintenance cursor belongs to a different catalog revision", 3)
		end
		local family_index, datastore_cursor = string.match(rest, "^(%d+):(.*)$")
		local numeric_index = tonumber(family_index)
		if not nonnegative_integer(numeric_index)
			or (numeric_index :: number) < 1
			or (numeric_index :: number) > #families
		then
			error("maintenance cursor contains an invalid family index", 3)
		end
		return numeric_index :: number, if datastore_cursor == "" then nil else datastore_cursor
	end

	local function make_cursor(family_index: number, datastore_cursor: string?): string
		local cursor = config.catalog_revision .. "|" .. tostring(family_index) .. ":" .. (datastore_cursor or "")
		if #cursor > MAX_CURSOR_BYTES then
			error("combined maintenance cursor exceeds 512 bytes", 3)
		end
		return cursor
	end

	local adapter = {}

	function adapter:NextPage(cursor: string?, maximum: number): ({ CatalogItem }?, string?, boolean, string?)
		if not nonnegative_integer(maximum) or maximum < 1 then
			return nil, nil, false, "maximum must be a positive integer"
		end
		local family_index, datastore_cursor = parse_cursor(cursor)
		local family = families[family_index]
		local store_ok, store_or_error = pcall(function()
			return get_store(family.store_name, family.scope)
		end)
		if not store_ok then
			return nil, nil, false, "could not open inventory DataStore: " .. tostring(store_or_error)
		end
		local page_size = math.min(maximum, MAX_PAGE_SIZE)
		local list_ok, pages_or_error = pcall(function()
			return store_or_error:ListKeysAsync(family.prefix, page_size, datastore_cursor, false)
		end)
		if not list_ok or pages_or_error == nil then
			return nil, nil, false, "ListKeysAsync failed: " .. tostring(pages_or_error)
		end
		local pages = pages_or_error
		local current_ok, keys_or_error = pcall(function()
			return pages:GetCurrentPage()
		end)
		if not current_ok or type(keys_or_error) ~= "table" then
			return nil, nil, false, "ListKeysAsync page read failed: " .. tostring(keys_or_error)
		end
		local items: { CatalogItem } = {}
		for _, key_info in ipairs(keys_or_error) do
			local key_name = key_info.KeyName
			if not valid_text(key_name, MAX_NAME_BYTES) then
				return nil, nil, false, "key listing returned an invalid key name"
			end
			items[#items + 1] = {
				family_name = family.name,
				store_name = family.store_name,
				scope = normalized_scope(family.scope),
				key = key_name,
			}
		end
		local finished = pages.IsFinished == true
		if not finished then
			local next_datastore_cursor = pages.Cursor
			if not valid_text(next_datastore_cursor, MAX_CURSOR_BYTES)
				or next_datastore_cursor == datastore_cursor
			then
				return nil, nil, false, "ListKeysAsync did not provide an advancing cursor"
			end
			return items, make_cursor(family_index, next_datastore_cursor), false, nil
		end
		if family_index < #families then
			return items, make_cursor(family_index + 1, nil), false, nil
		end
		return items, nil, true, nil
	end

	function adapter:Inspect(item: unknown): (Inspection?, string?)
		if type(item) ~= "table" then
			return inspection_failure("invalid", "inventory item must be a table"), "invalid inventory item"
		end
		local locator = item :: { [string]: unknown }
		local family_name = locator.family_name
		local key = locator.key
		if type(family_name) ~= "string" or type(key) ~= "string" then
			return inspection_failure("invalid", "inventory item lacks family_name or key"), "invalid inventory locator"
		end
		local family = family_by_name[family_name]
		if family == nil or locator.store_name ~= family.store_name or (locator.scope ~= nil and type(locator.scope) ~= "string")
			or normalized_scope(locator.scope :: string?) ~= normalized_scope(family.scope) then
			return inspection_failure("invalid", "inventory locator does not match the explicit family catalog"), "catalog mismatch"
		end
		local prefix = family.prefix or ""
		if #key > MAX_NAME_BYTES or (prefix ~= "" and string.sub(key, 1, #prefix) ~= prefix) then
			return inspection_failure("invalid", "inventory key is outside the declared family prefix"), "family prefix mismatch"
		end
		local ok, store_or_error = pcall(function()
			return get_store(family.store_name, family.scope)
		end)
		if not ok then
			local message = tostring(store_or_error)
			return inspection_failure("unknown", message), message
		end
		local value, key_info, read_error = read_fresh(store_or_error, key)
		if read_error ~= nil then
			return inspection_failure("unknown", read_error), read_error
		end
		if value == nil then
			return { status = "success", eligible = false, dependencies_clear = true, generation = 0, message = nil }, nil
		end
		local called, inspected, inspect_error = pcall(family.inspect, key, value, key_info)
		if not called or type(inspected) ~= "table" or inspected.status ~= "success" then
			local message = if not called then tostring(inspected) else inspect_error or "family inspection did not confirm success"
			return inspection_failure("unknown", message), message
		end
		if type(inspected.eligible) ~= "boolean" or type(inspected.dependencies_clear) ~= "boolean" then
			return inspection_failure("invalid", "family inspection omitted eligibility or dependency status"), "invalid family inspection result"
		end
		if inspected.eligible then
			local generation = inspected.generation
			if not nonnegative_integer(generation) then
				return inspection_failure("invalid", "eligible item must expose a non-negative generation"), "invalid generation"
			end
		end
		local normalized_inspection: Inspection = {
			status = inspected.status,
			eligible = inspected.eligible,
			dependencies_clear = inspected.dependencies_clear,
			generation = if type(inspected.generation) == "number" then inspected.generation else nil,
			message = if type(inspected.message) == "string" then inspected.message else nil,
		}
		return normalized_inspection, nil
	end

	function adapter:DeleteIfGeneration(item: unknown, expected_generation: number): (string, string?)
		if type(item) ~= "table" or not nonnegative_integer(expected_generation) then
			return "skipped", "invalid inventory item or generation"
		end
		local locator = item :: { [string]: unknown }
		local family = if type(locator.family_name) == "string" then family_by_name[locator.family_name] else nil
		local key = locator.key
		if family == nil or type(key) ~= "string" or not valid_text(key, MAX_NAME_BYTES)
			or locator.store_name ~= family.store_name or (locator.scope ~= nil and type(locator.scope) ~= "string")
			or normalized_scope(locator.scope :: string?) ~= normalized_scope(family.scope)
		then
			return "skipped", "inventory locator does not match the explicit family catalog"
		end
		local prefix = family.prefix or ""
		if prefix ~= "" and string.sub(key, 1, #prefix) ~= prefix then
			return "skipped", "inventory key is outside the declared family prefix"
		end
		local store_ok, store_or_error = pcall(function()
			return get_store(family.store_name, family.scope)
		end)
		if not store_ok then return "unknown", "could not open target DataStore: " .. tostring(store_or_error) end
		if family.delete_if_generation ~= nil then
			local called, action, message = pcall(
				family.delete_if_generation,
				store_or_error,
				locator,
				expected_generation,
				config.job_id
			)
			if not called then return "unknown", tostring(action) end
			if action ~= "deleted" and action ~= "already_absent" and action ~= "skipped" and action ~= "unknown" then
				return "unknown", message or "custom same-key deletion protocol returned an unsupported result"
			end
			return action, if type(message) == "string" then message else nil
		end
		local existing, key_info, read_error = read_fresh(store_or_error, key)
		if read_error ~= nil then return "unknown", read_error end
		if existing == nil or family.is_tombstone(existing, expected_generation, config.job_id) then
			return "already_absent", nil
		end
		local current_generation = family.get_generation(existing, key_info)
		if current_generation ~= expected_generation then
			return "skipped", "generation changed after inspection"
		end
		local update_ok, updated_or_error = pcall(function()
			return store_or_error:UpdateAsync(key, function(current: unknown, current_info: any): any
				if current == nil then return nil end
				if family.get_generation(current, current_info) ~= expected_generation then return nil end
				local allowed = family.can_delete(current, current_info, expected_generation, config.job_id)
				if allowed ~= true then return nil end
				return family.make_tombstone(current, current_info, expected_generation, config.job_id)
			end)
		end)
		if update_ok and family.is_tombstone(updated_or_error, expected_generation, config.job_id) then
			return "deleted", nil
		end
		local observed, observed_info, verify_error = read_fresh(store_or_error, key)
		if verify_error ~= nil then
			return "unknown", tostring(updated_or_error) .. "; verification failed: " .. verify_error
		end
		if observed == nil or family.is_tombstone(observed, expected_generation, config.job_id) then
			return "deleted", nil
		end
		if family.get_generation(observed, observed_info) ~= expected_generation then
			return "skipped", "generation changed before the delete fence committed"
		end
		if not update_ok then
			return "unknown", "UpdateAsync outcome is unresolved: " .. tostring(updated_or_error)
		end
		return "unknown", "UpdateAsync did not confirm the expected same-key tombstone"
	end

	function adapter:LoadCheckpoint(): (unknown, string?)
		local ok, store_or_error = pcall(function()
			return get_store(config.checkpoint_store_name, config.checkpoint_scope)
		end)
		if not ok then return nil, "could not open maintenance checkpoint store: " .. tostring(store_or_error) end
		local value, _, read_error = read_fresh(store_or_error, config.checkpoint_key)
		if read_error ~= nil then return nil, read_error end
		return value, nil
	end

	function adapter:PersistCheckpoint(proposed_value: unknown, expected_revision: number): (boolean, string?)
		local proposed = valid_checkpoint(proposed_value, config.job_id)
		if proposed == nil or not nonnegative_integer(expected_revision) or proposed.revision ~= expected_revision + 1 then
			return false, "proposed maintenance checkpoint is invalid"
		end
		local store_ok, store_or_error = pcall(function()
			return get_store(config.checkpoint_store_name, config.checkpoint_scope)
		end)
		if not store_ok then return false, "could not open checkpoint store: " .. tostring(store_or_error) end
		local update_ok, updated_or_error = pcall(function()
			return store_or_error:UpdateAsync(config.checkpoint_key, function(raw: unknown): any
				if raw == nil then
					if expected_revision ~= 0 then return nil end
					return copy_checkpoint(proposed)
				end
				local current = valid_checkpoint(raw, config.job_id)
				if current == nil then return nil end
				if same_checkpoint(current, proposed) then return nil end
				if current.revision ~= expected_revision then return nil end
				return copy_checkpoint(proposed)
			end)
		end)
		if update_ok and same_checkpoint(valid_checkpoint(updated_or_error, config.job_id), proposed) then
			return true, nil
		end
		local readback, read_error = adapter:LoadCheckpoint()
		local verified = valid_checkpoint(readback, config.job_id)
		if same_checkpoint(verified, proposed) then
			return true, nil
		end
		if not update_ok then
			return false, "checkpoint UpdateAsync outcome unresolved: " .. tostring(updated_or_error) .. (read_error and "; readback failed: " .. read_error or "")
		end
		if verified ~= nil and verified.revision ~= expected_revision then
			return false, "checkpoint revision changed concurrently"
		end
		return false, read_error or "checkpoint write was not confirmed by an uncached read"
	end

	function adapter:NewRunner()
		local runner_config = {
			job_id = config.job_id,
			mode = config.mode or "dry_run",
			initial_cursor = config.initial_cursor,
			next_page = function(cursor: string?, maximum: number)
				return adapter:NextPage(cursor, maximum)
			end,
			inspect = function(item: unknown)
				return adapter:Inspect(item)
			end,
			delete_if_generation = function(item: unknown, generation: number)
				return adapter:DeleteIfGeneration(item, generation)
			end,
			load_checkpoint = function()
				return adapter:LoadCheckpoint()
			end,
			persist_checkpoint = function(proposed: any, expected_revision: number)
				return adapter:PersistCheckpoint(proposed, expected_revision)
			end,
			authorize = config.authorize,
			assert_fence = config.assert_fence,
		}
		return config.maintenance_runner.new(config.maintenance, runner_config)
	end

	return table.freeze(adapter)
end


return Adapter
