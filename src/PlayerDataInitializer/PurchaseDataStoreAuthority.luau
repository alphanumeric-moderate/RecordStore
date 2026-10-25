--!strict
-- Globally scoped, durable PurchaseId identity authority.
-- A hash collision fails closed after the stored full PurchaseId is compared.
-- UpdateAsync transforms are pure and all ambiguous outcomes are reconciled by
-- uncached reads before this adapter reports a successful claim or commit.
local DataStoreService = game:GetService("DataStoreService")

local PurchaseDataStoreAuthority = {}

export type AuthorityRecord = {
	PurchaseId: string,
	PlayerId: number,
	ProductId: number,
	Status: string,
	Outcome: string?,
}

export type StoreAdapter = {
	GetAsyncFresh: (self: StoreAdapter, key: string) -> (unknown, string?),
	UpdateAsync: (self: StoreAdapter, key: string, transform: (unknown) -> unknown?) -> (unknown, string?),
}

export type Options = {
	store_name: string,
	scope: string?,
	key_prefix: string?,
	store_adapter: StoreAdapter?,
	now_unix: (() -> number)?,
	get_request_budget: ((string) -> number)?,
}

type NormalizedOptions = {
	store_name: string,
	scope: string,
	key_prefix: string,
	store_adapter: StoreAdapter,
	is_injected: boolean,
	now_unix: () -> number,
	get_request_budget: ((string) -> number)?,
}

type Authority = {
	ClaimAsync: (self: Authority, purchase_id: string, player_id: number, product_id: number) -> (AuthorityRecord?, string?),
	CommitAsync: (self: Authority, purchase_id: string, player_id: number, product_id: number, outcome: string) -> (AuthorityRecord?, string?),
	GetStatusAsync: (self: Authority, purchase_id: string, player_id: number, product_id: number) -> (AuthorityRecord?, string?),
	BackfillAsync: (self: Authority, purchase_id: string, player_id: number, product_id: number) -> (AuthorityRecord?, string?),
}

local VERSION = 1
local HASH_MODULUS = 4294967296
local MAX_PURCHASE_ID_BYTES = 230
local MAX_STORE_NAME_BYTES = 50
local MAX_SCOPE_BYTES = 50
local MAX_KEY_PREFIX_BYTES = 18

local function valid_text(value: unknown, maximum: number): boolean
	return type(value) == "string" and value ~= "" and #value <= maximum
end

local function positive_integer(value: unknown): boolean
	return type(value) == "number" and math.isfinite(value)
		and value >= 1 and math.floor(value) == value
end

local function finite_timestamp(value: unknown): boolean
	return type(value) == "number" and math.isfinite(value) and value >= 0
end

local function digest(value: string): string
	-- Four independent 32-bit rolling hashes keep the Roblox DataStore key
	-- under 50 bytes. The unhashed PurchaseId is always validated on reads.
	local h1, h2, h3, h4 = 2166136261, 2246822519, 3266489917, 668265263
	for index = 1, #value do
		local byte = string.byte(value, index)
		h1 = (h1 * 33 + byte) % HASH_MODULUS
		h2 = (h2 * 65599 + byte) % HASH_MODULUS
		h3 = (h3 * 257 + byte) % HASH_MODULUS
		h4 = (h4 * 131071 + byte) % HASH_MODULUS
	end
	return string.format("%08x%08x%08x%08x", h1, h2, h3, h4)
end

local function valid_outcome(value: unknown): boolean
	return value == "granted" or value == "duplicate" or value == "historical"
end

local function copy_record(record: AuthorityRecord): AuthorityRecord
	return {
		PurchaseId = record.PurchaseId,
		PlayerId = record.PlayerId,
		ProductId = record.ProductId,
		Status = record.Status,
		Outcome = record.Outcome,
	}
end

local function read_row(
	raw: unknown,
	purchase_id: string,
	player_id: number,
	product_id: number
): (AuthorityRecord?, string?)
	if raw == nil then return nil, "not_found" end
	if type(raw) ~= "table" then return nil, "corrupt: authority row is not a table" end
	local fields = raw :: { [string]: unknown }
	if fields.version ~= VERSION
		or not valid_text(fields.purchase_id, MAX_PURCHASE_ID_BYTES)
		or not positive_integer(fields.player_id)
		or not positive_integer(fields.product_id)
		or not finite_timestamp(fields.created_at)
		or not finite_timestamp(fields.updated_at)
		or (fields.updated_at :: number) < (fields.created_at :: number)
	then
		return nil, "corrupt: authority row failed identity/version/timestamp validation"
	end
	local status = fields.status
	local outcome = fields.outcome
	if status == "claimed" then
		if outcome ~= nil then return nil, "corrupt: claimed authority row has a terminal outcome" end
	elseif status == "committed" then
		if not valid_outcome(outcome) then return nil, "corrupt: committed authority row has an invalid outcome" end
	else
		return nil, "corrupt: authority row status is unknown"
	end
	if fields.purchase_id ~= purchase_id
		or fields.player_id ~= player_id
		or fields.product_id ~= product_id
	then
		return {
			PurchaseId = purchase_id,
			PlayerId = player_id,
			ProductId = product_id,
			Status = "conflict",
		}, nil
	end
	return {
		PurchaseId = purchase_id,
		PlayerId = player_id,
		ProductId = product_id,
		Status = status :: string,
		Outcome = outcome :: string?,
	}, nil
end

local function make_record(
	purchase_id: string,
	player_id: number,
	product_id: number,
	status: string,
	outcome: string?,
	created_at: number,
	updated_at: number
): { [string]: unknown }
	return {
		version = VERSION,
		purchase_id = purchase_id,
		player_id = player_id,
		product_id = product_id,
		status = status,
		outcome = outcome,
		created_at = created_at,
		updated_at = updated_at,
	}
end

local function make_native_store(store: any, options: NormalizedOptions): StoreAdapter
	local adapter: any = {}
	local function has_budget(kind: string): (boolean, string?)
		local budget = options.get_request_budget
		if budget ~= nil then
			local ok, available = pcall(budget, kind)
			if not ok or type(available) ~= "number" or not math.isfinite(available) then
				return false, "request budget lookup failed for " .. kind
			end
			if available < 1 then return false, "request budget exhausted for " .. kind end
			return true, nil
		end
		local request_type = if kind == "read"
			then Enum.DataStoreRequestType.StandardRead else Enum.DataStoreRequestType.StandardWrite
		local ok, available = pcall(function()
			return DataStoreService:GetRequestBudgetForRequestType(request_type)
		end)
		if not ok or type(available) ~= "number" or not math.isfinite(available) then
			return false, "request budget lookup failed for " .. kind
		end
		if available < 1 then return false, "request budget exhausted for " .. kind end
		return true, nil
	end
	function adapter:GetAsyncFresh(key: string): (unknown, string?)
		local allowed, budget_error = has_budget("read")
		if not allowed then return nil, budget_error end
		local get_options = Instance.new("DataStoreGetOptions")
		get_options.UseCache = false
		local ok, value = pcall(function()
			return store:GetAsync(key, get_options)
		end)
		if not ok then return nil, "fresh authority read failed: " .. tostring(value) end
		return value, nil
	end
	function adapter:UpdateAsync(key: string, transform: (unknown) -> unknown?): (unknown, string?)
		local read_allowed, read_error = has_budget("read")
		if not read_allowed then return nil, read_error end
		local write_allowed, write_error = has_budget("write")
		if not write_allowed then return nil, write_error end
		local ok, value = pcall(function()
			return store:UpdateAsync(key, function(raw)
				-- Caller transforms only inspect one value and return a new row or nil.
				return transform(raw)
			end)
		end)
		if not ok then return nil, "authority UpdateAsync outcome is uncertain: " .. tostring(value) end
		return value, nil
	end
	return adapter
end

local function normalize_options(config: unknown): NormalizedOptions
	if type(config) ~= "table" then error("config must be a table", 3) end
	local fields = config :: { [string]: unknown }
	for key in pairs(fields) do
		if key ~= "store_name" and key ~= "scope" and key ~= "key_prefix"
			and key ~= "store_adapter" and key ~= "now_unix" and key ~= "get_request_budget"
		then
			error("unsupported PurchaseDataStoreAuthority option: " .. tostring(key), 3)
		end
	end
	local store_name = fields.store_name
	local scope = if fields.scope == nil then "global" else fields.scope
	local key_prefix = if fields.key_prefix == nil then "pa-" else fields.key_prefix
	if not valid_text(store_name, MAX_STORE_NAME_BYTES) then error("store_name must be 1 to 50 bytes", 3) end
	if type(scope) ~= "string" or #scope > MAX_SCOPE_BYTES then error("scope must be a string of at most 50 bytes", 3) end
	if not valid_text(key_prefix, MAX_KEY_PREFIX_BYTES) then
		error("key_prefix must be 1 to 18 bytes so authority keys stay within platform limits", 3)
	end
	if fields.store_adapter ~= nil then
		local adapter = fields.store_adapter
		if type(adapter) ~= "table"
			or type((adapter :: { [string]: unknown }).GetAsyncFresh) ~= "function"
			or type((adapter :: { [string]: unknown }).UpdateAsync) ~= "function"
		then
			error("store_adapter must implement uncached GetAsyncFresh and atomic UpdateAsync", 3)
		end
	end
	if fields.now_unix ~= nil and type(fields.now_unix) ~= "function" then
		error("now_unix must be a function when provided", 3)
	end
	if fields.get_request_budget ~= nil and type(fields.get_request_budget) ~= "function" then
		error("get_request_budget must be a function when provided", 3)
	end
	local normalized: NormalizedOptions = {
		store_name = store_name :: string,
		scope = scope :: string,
		key_prefix = key_prefix :: string,
		store_adapter = (fields.store_adapter or {}) :: StoreAdapter,
		is_injected = fields.store_adapter ~= nil,
		now_unix = fields.now_unix :: (() -> number)? or os.time,
		get_request_budget = fields.get_request_budget :: ((string) -> number)?,
	}
	if normalized.is_injected ~= true then
		local ok, store = pcall(function()
			return DataStoreService:GetDataStore(normalized.store_name, normalized.scope)
		end)
		if not ok or store == nil then error("could not open PurchaseDataStoreAuthority DataStore: " .. tostring(store), 3) end
		normalized.store_adapter = make_native_store(store, normalized)
	end
	return table.freeze(normalized)
end

function PurchaseDataStoreAuthority.new(config: Options): Authority
	local options = normalize_options(config)
	local function validate_identity(purchase_id: unknown, player_id: unknown, product_id: unknown): (string?, number?, number?, string?)
		if not valid_text(purchase_id, MAX_PURCHASE_ID_BYTES)
			or string.find(purchase_id :: string, "%c") ~= nil
			or not positive_integer(player_id) or not positive_integer(product_id)
		then
			return nil, nil, nil, "PurchaseId, PlayerId or ProductId is malformed"
		end
		return purchase_id :: string, player_id :: number, product_id :: number, nil
	end
	local function key_for(purchase_id: string): string
		return options.key_prefix .. digest(purchase_id)
	end
	local function read_status(purchase_id: string, player_id: number, product_id: number): (AuthorityRecord?, string?)
		local ok, raw, read_error = pcall(function()
			return options.store_adapter:GetAsyncFresh(key_for(purchase_id))
		end)
		if not ok then return nil, "uncached authority status read raised: " .. tostring(raw) end
		if read_error ~= nil then return nil, tostring(read_error) end
		return read_row(raw, purchase_id, player_id, product_id)
	end
	local function update(
		purchase_id: string,
		player_id: number,
		product_id: number,
		transform: (unknown) -> unknown?
	): (AuthorityRecord?, string?)
		local key = key_for(purchase_id)
		local ok, _, write_error = pcall(function()
			return options.store_adapter:UpdateAsync(key, transform)
		end)
		local observed, read_error = read_status(purchase_id, player_id, product_id)
		if observed ~= nil then
			return observed, nil
		end
		if read_error ~= "not_found" then
			return nil, read_error or write_error or "authority write could not be reconciled"
		end
		if not ok or write_error ~= nil then
			return nil, tostring(write_error or "authority write failed and the uncached read found no row")
		end
		return nil, "authority write was not observed after uncached reconciliation"
	end

	local authority: Authority = {
		ClaimAsync = function(_self, purchase_id, player_id, product_id)
			local id, user_id, product, validation_error = validate_identity(purchase_id, player_id, product_id)
			if id == nil then return nil, validation_error end
			local now = options.now_unix()
			if not finite_timestamp(now) then return nil, "authority clock returned an invalid timestamp" end
			local observed, write_error = update(id, user_id :: number, product :: number, function(raw)
				if raw ~= nil then return nil end
				return make_record(id, user_id :: number, product :: number, "claimed", nil, now, now)
			end)
			if observed == nil then return nil, write_error end
			if observed.Status == "claimed" or observed.Status == "committed"
				or observed.Status == "conflict" or observed.Status == "corrupt"
			then
				return copy_record(observed), nil
			end
			return nil, "authority returned an unsupported claim state"
		end,
		CommitAsync = function(_self, purchase_id, player_id, product_id, outcome)
			local id, user_id, product, validation_error = validate_identity(purchase_id, player_id, product_id)
			if id == nil then return nil, validation_error end
			if not valid_outcome(outcome) or outcome == "historical" then
				return nil, "commit outcome must be granted or duplicate"
			end
			local now = options.now_unix()
			if not finite_timestamp(now) then return nil, "authority clock returned an invalid timestamp" end
			local observed, write_error = update(id, user_id :: number, product :: number, function(raw)
				local row, row_error = read_row(raw, id, user_id :: number, product :: number)
				if row == nil or row_error ~= nil or row.Status == "conflict" or row.Status == "corrupt" then
					return nil
				end
				if row.Status == "claimed" then
					return make_record(id, user_id :: number, product :: number, "committed", outcome, now, now)
				end
				-- A committed matching ID stays terminal. Outcome can differ between
				-- the original grant and a replay that observed an existing local ledger.
				return nil
			end)
			if observed == nil then return nil, write_error end
			if observed.Status == "conflict" or observed.Status == "corrupt" then return copy_record(observed), nil end
			if observed.Status == "committed" and valid_outcome(observed.Outcome) then return copy_record(observed), nil end
			return nil, "external authority commit is not durably confirmed"
		end,
		GetStatusAsync = function(_self, purchase_id, player_id, product_id)
			local id, user_id, product, validation_error = validate_identity(purchase_id, player_id, product_id)
			if id == nil then return nil, validation_error end
			return read_status(id, user_id :: number, product :: number)
		end,
		BackfillAsync = function(_self, purchase_id, player_id, product_id)
			local id, user_id, product, validation_error = validate_identity(purchase_id, player_id, product_id)
			if id == nil then return nil, validation_error end
			local before, before_error = read_status(id, user_id :: number, product :: number)
			if before ~= nil then return copy_record(before), nil end
			if before_error ~= "not_found" then return nil, before_error or "historical authority read was unresolved" end
			local now = options.now_unix()
			if not finite_timestamp(now) then return nil, "authority clock returned an invalid timestamp" end
			local observed, write_error = update(id, user_id :: number, product :: number, function(raw)
				if raw ~= nil then return nil end
				return make_record(id, user_id :: number, product :: number, "committed", "historical", now, now)
			end)
			if observed == nil then return nil, write_error end
			if observed.Status == "committed" and observed.Outcome == "historical" then
				local imported = copy_record(observed)
				imported.Status = "imported"
				return imported, nil
			end
			return copy_record(observed), nil
		end,
	}
	return table.freeze(authority)
end

return table.freeze(PurchaseDataStoreAuthority)
