--!strict
local DataStoreService = game:GetService("DataStoreService")

local Adapter = {}

export type Key = {
	name: string,
	scope: string,
	key: string,
}

export type Inspection = {
	status: string,
	eligible: boolean?,
	dependencies_clear: boolean?,
	generation: number?,
	message: string?,
	version: string?,
}

export type Options = {
	store_name: string,
	scope: string?,
	key_prefix: string?,
	page_size: number?,
	checkpoint_store_name: string,
	checkpoint_scope: string?,
	checkpoint_key: string,
	job_id: string,
	mode: string?,
	data_store_service: any?,
	new_get_options: (() -> any)?,
	get_generation: ((Key, unknown, any) -> number?)?,
	is_eligible: (Key, unknown, any) -> (boolean, string?),
	dependencies_clear: (Key, unknown, any) -> (boolean, string?),
	atomic_delete_if_generation: (any, Key, number, string) -> (string, string?),
	authorize: (string) -> (boolean, string?),
	assert_fence: (string) -> (boolean, string?),
}

local MAX_CURSOR_BYTES = 512
local MAX_KEY_BYTES = 50
local MAX_PAGE_SIZE = 100

local function valid_text(value: unknown, maximum: number): boolean
	return type(value) == "string" and value ~= "" and #value <= maximum
end

local function nonnegative_integer(value: unknown): boolean
	return type(value) == "number" and math.isfinite(value)
		and value >= 0 and math.floor(value) == value
end

local function copy_checkpoint(value: any): any
	local result = {}
	for key, child in pairs(value) do
		result[key] = child
	end
	return result
end

local function same_checkpoint(left: unknown, right: any): boolean
	if type(left) ~= "table" then return false end
	local value = left :: { [string]: unknown }
	return value.version == right.version
		and value.job_id == right.job_id
		and value.revision == right.revision
		and value.cursor == right.cursor
		and value.processed == right.processed
		and value.removed == right.removed
		and value.status == right.status
end

local function validate_checkpoint(value: unknown, job_id: string): boolean
	if type(value) ~= "table" then return false end
	local row = value :: { [string]: unknown }
	return row.version == 1
		and row.job_id == job_id
		and nonnegative_integer(row.revision)
		and (row.cursor == nil or valid_text(row.cursor, MAX_CURSOR_BYTES))
		and nonnegative_integer(row.processed)
		and nonnegative_integer(row.removed)
		and (row.removed :: number) <= (row.processed :: number)
		and (row.status == "idle" or row.status == "incomplete" or row.status == "completed"
			or row.status == "unknown" or row.status == "paused")
		and not (row.status == "completed" and row.cursor ~= nil)
		and not (row.status == "incomplete" and row.cursor == nil)
end

local function make_get_options(factory: (() -> any)?): any
	local options = if factory ~= nil then factory() else Instance.new("DataStoreGetOptions")
	if options == nil then error("could not create DataStoreGetOptions", 3) end
	options.UseCache = false
	return options
end

function Adapter.new(config: Options)
	if type(config) ~= "table" then error("config must be a table", 2) end
	if not valid_text(config.store_name, MAX_KEY_BYTES) then error("store_name must be 1 to 50 bytes", 2) end
	local scope = if config.scope == nil then "global" else config.scope
	local checkpoint_scope = if config.checkpoint_scope == nil then "global" else config.checkpoint_scope
	local prefix = if config.key_prefix == nil then "" else config.key_prefix
	local page_size = if config.page_size == nil then 100 else config.page_size
	if type(scope) ~= "string" or #scope > MAX_KEY_BYTES then error("scope must be a string of at most 50 bytes", 2) end
	if type(checkpoint_scope) ~= "string" or #checkpoint_scope > MAX_KEY_BYTES then error("checkpoint_scope must be a string of at most 50 bytes", 2) end
	if type(prefix) ~= "string" or #prefix > MAX_KEY_BYTES then error("key_prefix must be at most 50 bytes", 2) end
	if not valid_text(config.checkpoint_store_name, MAX_KEY_BYTES) then error("checkpoint_store_name must be 1 to 50 bytes", 2) end
	if config.checkpoint_store_name == config.store_name and checkpoint_scope == scope then
		error("maintenance checkpoints must use a separate store/scope from the enumerated data", 2)
	end
	if not valid_text(config.checkpoint_key, MAX_KEY_BYTES) then error("checkpoint_key must be 1 to 50 bytes", 2) end
	if not valid_text(config.job_id, 96) then error("job_id must be 1 to 96 bytes", 2) end
	if not nonnegative_integer(page_size) or page_size < 1 or page_size > MAX_PAGE_SIZE then
		error("page_size must be an integer from 1 to 100", 2)
	end
	if type(config.is_eligible) ~= "function" then error("is_eligible callback is required", 2) end
	if type(config.dependencies_clear) ~= "function" then error("dependencies_clear callback is required", 2) end
	if type(config.atomic_delete_if_generation) ~= "function" then
		error("atomic_delete_if_generation callback is required; a preflight-only delete is unsafe", 2)
	end
	if type(config.authorize) ~= "function" or type(config.assert_fence) ~= "function" then
		error("authorize and assert_fence callbacks are required", 2)
	end
	if config.get_generation ~= nil and type(config.get_generation) ~= "function" then
		error("get_generation must be a function", 2)
	end
	if config.new_get_options ~= nil and type(config.new_get_options) ~= "function" then
		error("new_get_options must be a function", 2)
	end

	local service = config.data_store_service or DataStoreService
	local store = service:GetDataStore(config.store_name, scope)
	local checkpoint_store = service:GetDataStore(config.checkpoint_store_name, checkpoint_scope)
	local create_options = function() return make_get_options(config.new_get_options) end

	local function load_checkpoint(): (unknown, string?)
		local ok, value = pcall(function()
			return checkpoint_store:GetAsync(config.checkpoint_key, create_options())
		end)
		if not ok then return nil, "uncached checkpoint read failed: " .. tostring(value) end
		if value ~= nil and not validate_checkpoint(value, config.job_id) then
			return nil, "maintenance checkpoint is malformed or belongs to another job"
		end
		return value, nil
	end

	local function persist_checkpoint(proposed: any, expected_revision: number): (boolean, string?)
		if type(proposed) ~= "table" or not validate_checkpoint(proposed, config.job_id)
			or proposed.revision ~= expected_revision + 1
		then
			return false, "proposed maintenance checkpoint failed identity/revision validation"
		end
		local target = copy_checkpoint(proposed)
		local call_ok, observed, update_error = pcall(function()
			return checkpoint_store:UpdateAsync(config.checkpoint_key, function(raw)
				if raw == nil then
					if expected_revision ~= 0 then return nil end
					return copy_checkpoint(target)
				end
				if not validate_checkpoint(raw, config.job_id) then return nil end
				local current = raw :: { [string]: unknown }
				if same_checkpoint(current, target) then return nil end
				if current.revision ~= expected_revision then return nil end
				return copy_checkpoint(target)
			end)
		end)
		if call_ok and same_checkpoint(observed, target) then return true, nil end
		local readback, read_error = load_checkpoint()
		if same_checkpoint(readback, target) then return true, nil end
		if not call_ok then
			return false, "maintenance checkpoint write raised and did not reconcile: " .. tostring(observed)
		end
		return false, tostring(update_error or read_error or "maintenance checkpoint revision conflict or unknown outcome")
	end

	local function next_page(cursor: string?, requested: number)
		if cursor ~= nil and not valid_text(cursor, MAX_CURSOR_BYTES) then
			error("maintenance cursor must be 1 to 512 bytes", 2)
		end
		if not nonnegative_integer(requested) or requested < 1 then error("requested page size must be a positive integer", 2) end
		local count = math.min(page_size, MAX_PAGE_SIZE, requested)
		local pages = store:ListKeysAsync(prefix, count, cursor, false)
		local raw_page = pages:GetCurrentPage()
		if type(raw_page) ~= "table" then error("DataStoreKeyPages returned no current page", 2) end
		local items: { Key } = {}
		local count_items = 0
		for index in pairs(raw_page) do
			if type(index) ~= "number" or not math.isfinite(index)
				or math.floor(index) ~= index or index < 1 or index > #raw_page
			then
				error("DataStoreKeyPages current page is not a dense array", 2)
			end
			count_items += 1
		end
		if count_items ~= #raw_page then error("DataStoreKeyPages current page is not a dense array", 2) end
		for _, raw_key in ipairs(raw_page) do
			local key_ok, name = pcall(function() return raw_key.KeyName end)
			if not key_ok or not valid_text(name, MAX_KEY_BYTES)
				or (prefix ~= "" and string.sub(name :: string, 1, #prefix) ~= prefix)
			then
				error("DataStoreKeyPages returned an invalid or out-of-prefix key", 2)
			end
			items[#items + 1] = { name = config.store_name, scope = scope, key = name :: string }
		end
		local complete = pages.IsFinished == true
		local next_cursor = if complete then nil else pages.Cursor
		if complete and next_cursor ~= nil then
			next_cursor = nil
		elseif not complete and (not valid_text(next_cursor, MAX_CURSOR_BYTES) or next_cursor == cursor) then
			error("DataStoreKeyPages did not provide an advancing continuation cursor", 2)
		end
		return items, next_cursor, complete
	end

	local function inspect(item: Key): Inspection
		if type(item) ~= "table" or item.name ~= config.store_name
			or item.scope ~= scope or not valid_text(item.key, MAX_KEY_BYTES)
			or (prefix ~= "" and string.sub(item.key, 1, #prefix) ~= prefix)
		then
			return { status = "invalid", eligible = false, dependencies_clear = false, message = "key identity is outside the declared data-store family" }
		end
		local raw, key_info = store:GetAsync(item.key, create_options())
		if raw == nil then
			return { status = "success", eligible = false, dependencies_clear = true, generation = 0 }
		end
		local generation: number? = nil
		if config.get_generation ~= nil then
			generation = config.get_generation(item, raw, key_info)
		elseif type(raw) == "table" then
			generation = (raw :: { [string]: unknown }).fencing_generation :: number?
		end
		if not nonnegative_integer(generation) then
			return { status = "unsupported", eligible = false, dependencies_clear = false, message = "record has no verified non-negative generation" }
		end
		local eligible, eligibility_error = config.is_eligible(item, raw, key_info)
		if type(eligible) ~= "boolean" then
			return { status = "unknown", eligible = false, dependencies_clear = false, generation = generation, message = eligibility_error or "eligibility check did not return a boolean" }
		end
		local clear, dependency_error = config.dependencies_clear(item, raw, key_info)
		if type(clear) ~= "boolean" then
			return { status = "unknown", eligible = false, dependencies_clear = false, generation = generation, message = dependency_error or "dependency check did not return a boolean" }
		end
		local version: string? = nil
		if key_info ~= nil then
			local version_ok, observed_version = pcall(function() return key_info.Version end)
			if version_ok and observed_version ~= nil then version = tostring(observed_version) end
		end
		return {
			status = "success",
			eligible = eligible,
			dependencies_clear = clear,
			generation = generation,
			version = version,
			message = eligibility_error or dependency_error,
		}
	end

	local function delete_if_generation(item: Key, generation: number)
		if type(item) ~= "table" or item.name ~= config.store_name or item.scope ~= scope
			or not valid_text(item.key, MAX_KEY_BYTES) or not nonnegative_integer(generation)
		then
			return "skipped", "delete locator or generation failed validation"
		end
		if prefix ~= "" and string.sub(item.key, 1, #prefix) ~= prefix then
			return "skipped", "delete key fell outside the configured prefix"
		end
		local ok, action, message = pcall(
			config.atomic_delete_if_generation, store, item, generation, config.job_id
		)
		if not ok then return "unknown", tostring(action) end
		if type(action) ~= "string" or (action ~= "deleted" and action ~= "already_absent" and action ~= "skipped" and action ~= "unknown") then
			return "unknown", message or "atomic delete adapter returned an unsupported result"
		end
		return action :: string, message
	end

	return table.freeze({
		store = store,
		checkpoint_store = checkpoint_store,
		job_id = config.job_id,
		mode = config.mode or "dry_run",
		next_page = next_page,
		inspect = inspect,
		delete_if_generation = delete_if_generation,
		load_checkpoint = load_checkpoint,
		persist_checkpoint = persist_checkpoint,
		authorize = config.authorize,
		assert_fence = config.assert_fence,
	})
end

return Adapter
