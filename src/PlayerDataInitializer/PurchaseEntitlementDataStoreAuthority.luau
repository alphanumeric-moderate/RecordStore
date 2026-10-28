--!strict
local AuthorityModule = {}
local SHA256 = require(script.Parent:WaitForChild("RecordStoreSHA256"))

export type EntitlementRecord = {
	version: number,
	entitlement_id: string,
	player_id: number,
	purchase_id: string,
	product_id: number,
	status: string,
	revision: number,
	created_at: number,
	updated_at: number,
}

export type Result = {
	code: string,
	record: EntitlementRecord?,
	message: string?,
}

export type ErasureLocator = {
	key: string,
	generation: number,
}

export type StoreAdapter = {
	GetAsyncFresh: (self: any, key: string) -> (unknown, string?),
	UpdateAsync: (self: any, key: string, transform: (unknown) -> unknown?) -> (unknown, string?),
}

export type RequestRunner = (
	operation: string,
	call: () -> (unknown, string?)
) -> (unknown, string?)

export type Options = {
	store_name: string?,
	scope: string?,
	key_prefix: string?,
	store_adapter: StoreAdapter?,
	data_store_service: any?,
	now_unix: (() -> number)?,
	get_request_budget: ((string) -> number)?,
	request_runner: RequestRunner?,
	new_get_options: (() -> any)?,
}

type NormalizedOptions = {
	key_prefix: string,
	store_adapter: StoreAdapter,
	now_unix: () -> number,
	get_request_budget: ((string) -> number)?,
	request_runner: RequestRunner?,
}

type Authority = {
	ReserveAsync: (self: Authority, entitlement_id: string, player_id: number, product_id: number, purchase_id: string, expected_revision: number?) -> Result,
	CommitAsync: (self: Authority, entitlement_id: string, player_id: number, product_id: number, purchase_id: string) -> Result,
	BackfillAsync: (self: Authority, entitlement_id: string, player_id: number, product_id: number, purchase_id: string) -> Result,
	GetStatusAsync: (self: Authority, entitlement_id: string, player_id: number) -> Result,
	GetErasureLocatorAsync: (self: Authority, entitlement_id: string, player_id: number) -> (ErasureLocator?, string?),
	EraseRetainFenceAsync: (self: Authority, entitlement_id: string, player_id: number, expected_generation: number, erasure_id: string) -> Result,
}

local VERSION = 1
local ERASED_VERSION = 2
local MAX_ENTITLEMENT_ID_BYTES = 128
local MAX_PURCHASE_ID_BYTES = 247
local MAX_STORE_NAME_BYTES = 50
local MAX_SCOPE_BYTES = 50
local MAX_KEY_PREFIX_BYTES = 18
local MAX_SAFE_INTEGER = 9007199254740991

local function valid_text(value: unknown, maximum: number): boolean
	return type(value) == "string" and value ~= "" and #value <= maximum
		and string.find(value, "%c") == nil
end

local function positive_integer(value: unknown): boolean
	return type(value) == "number" and math.isfinite(value)
		and value >= 1 and value <= MAX_SAFE_INTEGER and math.floor(value) == value
end

local function valid_revision(value: unknown): boolean
	return type(value) == "number" and math.isfinite(value)
		and value >= 0 and value <= MAX_SAFE_INTEGER and math.floor(value) == value
end

local function finite_timestamp(value: unknown): boolean
	return type(value) == "number" and math.isfinite(value) and value >= 0
end

local function entitlement_key_material(entitlement_id: string, player_id: number): string
	return tostring(player_id) .. ":" .. entitlement_id
end

local function digest(value: string): string
	return string.sub(SHA256.digest(value), 1, 32)
end

local function validate_erasure_tombstone(
	raw: unknown,
	entitlement_id: string,
	player_id: number
): (number?, string?, string?)
	if type(raw) ~= "table" then return nil, nil, "corrupt: erasure tombstone is not a table" end
	local fields = raw :: { [string]: any }
	local allowed_fields = {
		version = true,
		status = true,
		revision = true,
		created_at = true,
		updated_at = true,
		identity_digest = true,
		erasure_fence = true,
	}
	for field in pairs(fields) do
		if allowed_fields[field] ~= true then
			return nil, nil, "corrupt: erasure tombstone retained an unapproved field"
		end
	end
	if fields.version ~= ERASED_VERSION or fields.status ~= "erased"
		or not positive_integer(fields.revision)
		or not finite_timestamp(fields.created_at)
		or not finite_timestamp(fields.updated_at)
		or (fields.updated_at :: number) < (fields.created_at :: number)
	then
		return nil, nil, "corrupt: erasure tombstone schema, revision or timestamp is invalid"
	end
	if type(fields.identity_digest) ~= "string" or #fields.identity_digest ~= 64
		or string.match(fields.identity_digest, "^[0-9a-f]+$") == nil
	then
		return nil, nil, "corrupt: erasure identity digest is malformed"
	end
	if fields.identity_digest ~= SHA256.digest(entitlement_key_material(entitlement_id, player_id)) then
		return nil, nil, "conflict: hashed key contains a different entitlement identity"
	end
	if type(fields.erasure_fence) ~= "table" then
		return nil, nil, "corrupt: erasure tombstone has no durable fence"
	end
	local fence = fields.erasure_fence :: { [string]: any }
	local allowed_fence_fields = {
		erasure_id = true,
		source_revision = true,
		fenced_revision = true,
	}
	for field in pairs(fence) do
		if allowed_fence_fields[field] ~= true then
			return nil, nil, "corrupt: erasure fence retained an unapproved field"
		end
	end
	if not valid_text(fence.erasure_id, 96)
		or string.find(fence.erasure_id, "%c") ~= nil
		or not valid_revision(fence.source_revision)
		or (fence.source_revision :: number) >= MAX_SAFE_INTEGER
		or not positive_integer(fence.fenced_revision)
		or fence.fenced_revision ~= fields.revision
		or fence.fenced_revision ~= (fence.source_revision :: number) + 1
	then
		return nil, nil, "corrupt: erasure fence identity or generation transition is invalid"
	end
	return fields.revision :: number, fence.erasure_id :: string, nil
end

local function copy_record(record: EntitlementRecord): EntitlementRecord
	return {
		version = record.version,
		entitlement_id = record.entitlement_id,
		player_id = record.player_id,
		purchase_id = record.purchase_id,
		product_id = record.product_id,
		status = record.status,
		revision = record.revision,
		created_at = record.created_at,
		updated_at = record.updated_at,
	}
end

local function parse_record(raw: unknown): (EntitlementRecord?, string?)
	if raw == nil then return nil, "not_found" end
	if type(raw) ~= "table" then return nil, "corrupt: entitlement row is not a table" end
	local fields = raw :: { [string]: unknown }
	if fields.version ~= VERSION
		or not valid_text(fields.entitlement_id, MAX_ENTITLEMENT_ID_BYTES)
		or not positive_integer(fields.player_id)
		or not valid_text(fields.purchase_id, MAX_PURCHASE_ID_BYTES)
		or not positive_integer(fields.product_id)
		or not positive_integer(fields.revision)
		or not finite_timestamp(fields.created_at)
		or not finite_timestamp(fields.updated_at)
		or (fields.updated_at :: number) < (fields.created_at :: number)
	then
		return nil, "corrupt: entitlement row failed identity/version/revision/timestamp validation"
	end
	if fields.status ~= "pending" and fields.status ~= "owned" then
		return nil, "corrupt: entitlement row has an unknown state"
	end
	return {
		version = VERSION,
		entitlement_id = fields.entitlement_id :: string,
		player_id = fields.player_id :: number,
		purchase_id = fields.purchase_id :: string,
		product_id = fields.product_id :: number,
		status = fields.status :: string,
		revision = fields.revision :: number,
		created_at = fields.created_at :: number,
		updated_at = fields.updated_at :: number,
	}, nil
end

local function make_record(
	entitlement_id: string,
	player_id: number,
	product_id: number,
	purchase_id: string,
	status: string,
	revision: number,
	created_at: number,
	updated_at: number
): EntitlementRecord
	return {
		version = VERSION,
		entitlement_id = entitlement_id,
		player_id = player_id,
		purchase_id = purchase_id,
		product_id = product_id,
		status = status,
		revision = revision,
		created_at = created_at,
		updated_at = updated_at,
	}
end

local function result(code: string, record: EntitlementRecord?, message: string?): Result
	return {
		code = code,
		record = if record == nil then nil else table.freeze(copy_record(record)),
		message = message,
	}
end

local function create_native_adapter(store: any, factory: (() -> any)?): StoreAdapter
	local adapter: any = {}
	local function get_options(): any
		local options = if factory ~= nil then factory() else Instance.new("DataStoreGetOptions")
		if options == nil then error("could not create DataStoreGetOptions", 3) end
		options.UseCache = false
		return options
	end
	function adapter:GetAsyncFresh(key: string): (unknown, string?)
		local ok, value = pcall(function()
			return store:GetAsync(key, get_options())
		end)
		if not ok then return nil, tostring(value) end
		return value, nil
	end
	function adapter:UpdateAsync(key: string, transform: (unknown) -> unknown?): (unknown, string?)
		local ok, value = pcall(function()
			return store:UpdateAsync(key, transform)
		end)
		if not ok then return nil, tostring(value) end
		return value, nil
	end
	return adapter :: StoreAdapter
end

local function normalize_options(raw: unknown): NormalizedOptions
	if type(raw) ~= "table" then error("options must be a table", 3) end
	local values = raw :: { [string]: unknown }
	for option_name in pairs(values) do
		if option_name ~= "store_name" and option_name ~= "scope"
			and option_name ~= "key_prefix" and option_name ~= "store_adapter"
			and option_name ~= "data_store_service" and option_name ~= "now_unix"
			and option_name ~= "get_request_budget" and option_name ~= "request_runner"
			and option_name ~= "new_get_options"
		then
			error("unsupported entitlement authority option: " .. tostring(option_name), 3)
		end
	end
	local key_prefix = if values.key_prefix == nil then "Ent_" else values.key_prefix
	if not valid_text(key_prefix, MAX_KEY_PREFIX_BYTES) then
		error("key_prefix must be 1 to 18 non-control bytes", 3)
	end
	local store_adapter = values.store_adapter
	if store_adapter == nil then
		if not valid_text(values.store_name, MAX_STORE_NAME_BYTES) then
			error("store_name must be 1 to 50 bytes when no store_adapter is supplied", 3)
		end
		local scope = if values.scope == nil then "global" else values.scope
		if type(scope) ~= "string" or #scope > MAX_SCOPE_BYTES or string.find(scope, "%c") ~= nil then
			error("scope must be a string of at most 50 non-control bytes", 3)
		end
		local service: any = values.data_store_service or game:GetService("DataStoreService")
		local store: any = service:GetDataStore(values.store_name :: string, scope)
		local new_get_options = values.new_get_options
		if new_get_options ~= nil and type(new_get_options) ~= "function" then
			error("new_get_options must be a function when supplied", 3)
		end
		store_adapter = create_native_adapter(store, new_get_options :: (() -> any)?)
	elseif type(store_adapter) ~= "table"
		or type((store_adapter :: { [string]: unknown }).GetAsyncFresh) ~= "function"
		or type((store_adapter :: { [string]: unknown }).UpdateAsync) ~= "function"
	then
		error("store_adapter must implement GetAsyncFresh and UpdateAsync", 3)
	end
	local now_unix = values.now_unix
	if now_unix ~= nil and type(now_unix) ~= "function" then error("now_unix must be a function", 3) end
	local get_budget = values.get_request_budget
	if get_budget ~= nil and type(get_budget) ~= "function" then error("get_request_budget must be a function", 3) end
	local request_runner = values.request_runner
	if request_runner ~= nil and type(request_runner) ~= "function" then error("request_runner must be a function", 3) end
	return table.freeze({
		key_prefix = key_prefix :: string,
		store_adapter = store_adapter :: StoreAdapter,
		now_unix = (now_unix or os.time) :: () -> number,
		get_request_budget = get_budget :: ((string) -> number)?,
		request_runner = request_runner :: RequestRunner?,
	})
end

local function check_budget(options: NormalizedOptions, operation: string): (boolean, string?)
	if options.get_request_budget == nil then return true, nil end
	local ok, available = pcall(options.get_request_budget, operation)
	if not ok or type(available) ~= "number" or not math.isfinite(available) then
		return false, "budget_unavailable"
	end
	if available < 1 then return false, "budget_exhausted" end
	return true, nil
end

local function call_store(
	options: NormalizedOptions,
	operation: string,
	call: () -> (unknown, string?)
): (unknown, string?)
	local has_budget, budget_error = check_budget(options, operation)
	if not has_budget then return nil, budget_error end
	if options.request_runner == nil then
		local ok, value, message = pcall(call)
		if not ok then return nil, tostring(value) end
		return value, if type(message) == "string" then message else nil
	end
	local ok, value, message = pcall(function()
		return (options.request_runner :: RequestRunner)(operation, call)
	end)
	if not ok then return nil, tostring(value) end
	return value, if type(message) == "string" then message else nil
end

local function read_fresh(
	options: NormalizedOptions,
	key: string
): (unknown, string?)
	return call_store(options, "read", function()
		return options.store_adapter:GetAsyncFresh(key)
	end)
end

local function update(
	options: NormalizedOptions,
	key: string,
	transform: (unknown) -> unknown?
): (unknown, string?)
	return call_store(options, "update", function()
		return options.store_adapter:UpdateAsync(key, transform)
	end)
end

local function normalized_input(
	entitlement_id: unknown,
	player_id: unknown,
	product_id: unknown?,
	purchase_id: unknown?
): (string?, number?, number?, string?, string?)
	if not valid_text(entitlement_id, MAX_ENTITLEMENT_ID_BYTES) then
		return nil, nil, nil, nil, "entitlement_id must be 1 to 128 non-control bytes"
	end
	if not positive_integer(player_id) then return nil, nil, nil, nil, "player_id must be a positive integer" end
	if product_id ~= nil and not positive_integer(product_id) then
		return nil, nil, nil, nil, "product_id must be a positive integer"
	end
	if purchase_id ~= nil and not valid_text(purchase_id, MAX_PURCHASE_ID_BYTES) then
		return nil, nil, nil, nil, "purchase_id must be 1 to 247 non-control bytes"
	end
	return entitlement_id :: string, player_id :: number, product_id :: number?, purchase_id :: string?, nil
end

local function row_for_identity(
	raw: unknown,
	entitlement_id: string,
	player_id: number
): (EntitlementRecord?, string?)
	local record, parse_error = parse_record(raw)
	if record == nil then return nil, parse_error end
	if record.entitlement_id ~= entitlement_id or record.player_id ~= player_id then
		return nil, "conflict: hashed key contains a different entitlement identity"
	end
	return record, nil
end

local function result_from_row(
	operation: string,
	raw: unknown,
	entitlement_id: string,
	player_id: number,
	product_id: number?,
	purchase_id: string?
): Result
	if raw == nil then return result("unknown", nil, "authoritative entitlement state could not be reconciled") end
	if type(raw) == "table" and (raw :: { [string]: any }).status == "erased" then
		local tombstone_generation, _tombstone_id, tombstone_error = validate_erasure_tombstone(
			raw, entitlement_id, player_id
		)
		if tombstone_generation == nil then
			local code = if string.sub(tombstone_error or "", 1, 10) == "conflict: " then "conflict" else "corrupt"
			return result(code, nil, tombstone_error)
		end
		return result("erased", nil, nil)
	end
	local record, row_error = row_for_identity(raw, entitlement_id, player_id)
	if record == nil then
		local code = if string.sub(row_error or "", 1, 10) == "conflict: " then "conflict" else "corrupt"
		return result(code, nil, row_error)
	end
	if operation == "status" then return result(record.status == "owned" and "owned" or "pending", record, nil) end
	if operation == "reserve" then
		if record.status == "owned" then
			if record.purchase_id == purchase_id and record.product_id == product_id then
				return result("owned", record, nil)
			end
			return result("already_owned", record, nil)
		end
		if record.purchase_id ~= purchase_id then return result("pending", record, nil) end
		if record.product_id ~= product_id then return result("conflict", record, "purchase ID is bound to another product") end
		return result("claimed", record, nil)
	end
	if operation == "commit" then
		if record.status == "owned" then
			if record.purchase_id == purchase_id and record.product_id == product_id then
				return result("committed", record, nil)
			end
			return result("already_owned", record, nil)
		end
		if record.purchase_id ~= purchase_id then
			return result("conflict", record, "purchase no longer owns the pending reservation")
		end
		if record.product_id ~= product_id then return result("conflict", record, "purchase ID is bound to another product") end
		return result("pending", record, "entitlement claim is still pending")
	end
	if operation == "backfill" then
		if record.status == "owned" then
			if record.purchase_id == purchase_id and record.product_id == product_id then
				return result("imported", record, nil)
			end
			return result("already_owned", record, nil)
		end
		return result("pending", record, "historical backfill cannot replace an unresolved live claim")
	end
	return result("invalid", record, "unsupported entitlement operation")
end

function AuthorityModule.new(raw_options: Options): Authority
	local options = normalize_options(raw_options)
	local self: any = {}
	local function key_for(entitlement_id: string, player_id: number): string
		return options.key_prefix .. digest(entitlement_key_material(entitlement_id, player_id))
	end

	local function run_write(
		operation: string,
		entitlement_id: string,
		player_id: number,
		product_id: number,
		purchase_id: string,
		expected_revision: number?
	): Result
		local key = key_for(entitlement_id, player_id)
		local now_ok, now_value = pcall(options.now_unix)
		if not now_ok or not finite_timestamp(now_value) then
			return result("invalid", nil, "clock did not return a finite non-negative timestamp")
		end
		local now = now_value :: number
		local observed, write_error = update(options, key, function(raw: unknown): unknown?
			if raw == nil then
				if operation == "reserve" then
					return make_record(entitlement_id, player_id, product_id, purchase_id, "pending", 1, now, now)
				elseif operation == "backfill" then
					return make_record(entitlement_id, player_id, product_id, purchase_id, "owned", 1, now, now)
				end
				return nil
			end
			local existing = parse_record(raw)
			if existing == nil then return nil end
			if existing.entitlement_id ~= entitlement_id or existing.player_id ~= player_id then return nil end
			if operation == "reserve" then
				if existing.status == "pending" and existing.purchase_id ~= purchase_id
					and expected_revision == existing.revision and existing.revision < MAX_SAFE_INTEGER
				then
					return make_record(entitlement_id, player_id, product_id, purchase_id,
						"pending", existing.revision + 1, existing.created_at, math.max(existing.updated_at, now))
				end
				return copy_record(existing)
			end
			if operation == "backfill" then return copy_record(existing) end
			if operation == "commit" then
				if existing.status == "owned" then return copy_record(existing) end
				if existing.purchase_id ~= purchase_id or existing.product_id ~= product_id
					or existing.revision >= MAX_SAFE_INTEGER then
					return copy_record(existing)
				end
				return make_record(
					entitlement_id,
					player_id,
					product_id,
					purchase_id,
					"owned",
					existing.revision + 1,
					existing.created_at,
					math.max(existing.updated_at, now)
				)
			end
			return nil
		end)
		local raw = observed
		if write_error ~= nil or observed == nil then
			local readback, read_error = read_fresh(options, key)
			if read_error ~= nil then
				return result("unknown", nil, "entitlement write could not be reconciled: "
					.. tostring(write_error or "empty write response") .. "; readback failed: " .. tostring(read_error))
			end
			raw = readback
		end
		if raw == nil then
			if operation == "commit" and write_error == nil then
				return result("not_found", nil, "entitlement must be claimed before it can be committed")
			end
			return result("unknown", nil, tostring(write_error or "entitlement write returned no durable row"))
		end
		return result_from_row(operation, raw, entitlement_id, player_id, product_id, purchase_id)
	end

	function self:ReserveAsync(entitlement_id: string, player_id: number, product_id: number, purchase_id: string, expected_revision: number?): Result
		local id, subject, product, purchase, invalid = normalized_input(entitlement_id, player_id, product_id, purchase_id)
		if invalid ~= nil then return result("invalid", nil, invalid) end
		if expected_revision ~= nil and not positive_integer(expected_revision) then
			return result("invalid", nil, "expected_revision must be a positive safe integer")
		end
		return run_write("reserve", id :: string, subject :: number, product :: number, purchase :: string, expected_revision)
	end

	function self:CommitAsync(entitlement_id: string, player_id: number, product_id: number, purchase_id: string): Result
		local id, subject, product, purchase, invalid = normalized_input(entitlement_id, player_id, product_id, purchase_id)
		if invalid ~= nil then return result("invalid", nil, invalid) end
		return run_write("commit", id :: string, subject :: number, product :: number, purchase :: string)
	end

	function self:BackfillAsync(entitlement_id: string, player_id: number, product_id: number, purchase_id: string): Result
		local id, subject, product, purchase, invalid = normalized_input(entitlement_id, player_id, product_id, purchase_id)
		if invalid ~= nil then return result("invalid", nil, invalid) end
		return run_write("backfill", id :: string, subject :: number, product :: number, purchase :: string)
	end

	function self:GetStatusAsync(entitlement_id: string, player_id: number): Result
		local id, subject, _, _, invalid = normalized_input(entitlement_id, player_id, nil, nil)
		if invalid ~= nil then return result("invalid", nil, invalid) end
		local raw, read_error = read_fresh(options, key_for(id :: string, subject :: number))
		if read_error ~= nil then return result("unknown", nil, "authoritative entitlement read failed: " .. tostring(read_error)) end
		if raw == nil then return result("not_found", nil, nil) end
		return result_from_row("status", raw, id :: string, subject :: number, nil, nil)
	end

	function self:GetErasureLocatorAsync(
		entitlement_id: string,
		player_id: number
	): (ErasureLocator?, string?)
		local id, subject, _, _, invalid = normalized_input(entitlement_id, player_id, nil, nil)
		if invalid ~= nil then return nil, invalid end
		local normalized_id = id :: string
		local normalized_player = subject :: number
		local key = key_for(normalized_id, normalized_player)
		local raw, read_error = read_fresh(options, key)
		if read_error ~= nil then
			return nil, "authoritative entitlement erasure locator read failed: " .. tostring(read_error)
		end
		if raw == nil then
			return table.freeze({ key = key, generation = 0 }), nil
		end
		if type(raw) == "table" and (raw :: { [string]: any }).status == "erased" then
			local generation, _erasure_id, tombstone_error = validate_erasure_tombstone(
				raw, normalized_id, normalized_player
			)
			if generation == nil then return nil, tombstone_error end
			return table.freeze({ key = key, generation = generation }), nil
		end
		local record, row_error = row_for_identity(raw, normalized_id, normalized_player)
		if record == nil then return nil, row_error or "entitlement row is corrupt" end
		return table.freeze({ key = key, generation = record.revision }), nil
	end

	function self:EraseRetainFenceAsync(
		entitlement_id: string,
		player_id: number,
		expected_generation: number,
		erasure_id: string
	): Result
		local id, subject, _, _, invalid = normalized_input(entitlement_id, player_id, nil, nil)
		if invalid ~= nil then return result("invalid", nil, invalid) end
		if not valid_revision(expected_generation) then
			return result("invalid", nil, "expected_generation must be a non-negative safe integer")
		end
		if expected_generation >= MAX_SAFE_INTEGER then
			return result("invalid", nil, "expected_generation cannot advance beyond the safe-integer limit")
		end
		if not valid_text(erasure_id, 96) or string.find(erasure_id, "%c") ~= nil then
			return result("invalid", nil, "erasure_id must be 1 to 96 non-control bytes")
		end
		local now_ok, now_value = pcall(options.now_unix)
		if not now_ok or not finite_timestamp(now_value) then
			return result("invalid", nil, "clock did not return a finite non-negative timestamp")
		end
		local now = now_value :: number
		local normalized_id = id :: string
		local normalized_player = subject :: number
		local key = key_for(normalized_id, normalized_player)
		local identity_digest = SHA256.digest(entitlement_key_material(normalized_id, normalized_player))
		local function make_tombstone(created_at: number): { [string]: any }
			return {
				version = ERASED_VERSION,
				status = "erased",
				revision = expected_generation + 1,
				created_at = created_at,
				updated_at = math.max(created_at, now),
				identity_digest = identity_digest,
				erasure_fence = {
					erasure_id = erasure_id,
					source_revision = expected_generation,
					fenced_revision = expected_generation + 1,
				},
			}
		end
		local observed, write_error = update(options, key, function(raw: unknown): unknown?
			if raw == nil then
				if expected_generation ~= 0 then return nil end
				return make_tombstone(now)
			end
			if type(raw) ~= "table" then return nil end
			local fields = raw :: { [string]: any }
			if fields.status == "erased" then return nil end
			local record = row_for_identity(raw, normalized_id, normalized_player)
			if record == nil or record.revision ~= expected_generation then return nil end
			return make_tombstone(record.created_at)
		end)
		local raw = observed
		if write_error ~= nil or raw == nil then
			local readback, read_error = read_fresh(options, key)
			if read_error ~= nil then
				return result("unknown", nil, "entitlement erasure could not be reconciled: "
					.. tostring(write_error or "empty write response") .. "; readback failed: " .. tostring(read_error))
			end
			raw = readback
		end
		if raw == nil then
			if write_error ~= nil then
				return result("unknown", nil, "entitlement erasure write result is unresolved: " .. tostring(write_error))
			end
			return result("conflict", nil, "entitlement generation changed before the erasure tombstone was committed")
		end
		if type(raw) == "table" and (raw :: { [string]: any }).status == "erased" then
			local generation, observed_erasure_id, tombstone_error = validate_erasure_tombstone(
				raw, normalized_id, normalized_player
			)
			if generation == nil then
				local code = if string.sub(tombstone_error or "", 1, 10) == "conflict: " then "conflict" else "corrupt"
				return result(code, nil, tombstone_error)
			end
			local fields = raw :: { [string]: any }
			local fence = fields.erasure_fence :: { [string]: any }
			if observed_erasure_id == erasure_id
				and fence.source_revision == expected_generation
				and generation == expected_generation + 1
			then
				return result("erased", nil, nil)
			end
			return result("conflict", nil, "entitlement key is permanently fenced by another erasure identity")
		end
		local current_record, row_error = row_for_identity(raw, normalized_id, normalized_player)
		if current_record == nil then
			local code = if string.sub(row_error or "", 1, 10) == "conflict: " then "conflict" else "corrupt"
			return result(code, nil, row_error)
		end
		if current_record.revision ~= expected_generation then
			return result("conflict", nil, "entitlement generation changed before the erasure tombstone was committed")
		end
		if write_error ~= nil then
			return result("unknown", nil, "entitlement erasure write result is unresolved: " .. tostring(write_error))
		end
		return result("conflict", nil, "entitlement erasure transformer did not commit a tombstone")
	end

	return self :: Authority
end

return AuthorityModule
