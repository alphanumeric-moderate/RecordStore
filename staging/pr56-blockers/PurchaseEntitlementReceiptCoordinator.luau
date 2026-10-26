--!strict
local Coordinator = {}

export type Receipt = {
	PurchaseId: string,
	PlayerId: number,
	ProductId: number,
}

export type GrantOnce = (receipt: Receipt, operation_id: string) -> (string, string?)

export type ActivationVerifier = () -> (boolean, string?)

export type Options = {
	purchase_authority: any,
	entitlement_authority: any,
	entitlement_by_product_id: { [number]: string },
	grant_profile_once: GrantOnce,
	verify_activation: ActivationVerifier,
}

export type Decision = {
	action: string,
	status: string,
	message: string?,
}

type NormalizedOptions = {
	purchase_authority: any,
	entitlement_authority: any,
	entitlement_by_product_id: { [number]: string },
	grant_profile_once: GrantOnce,
	verify_activation: ActivationVerifier,
}

local MAX_PURCHASE_ID_BYTES = 247
local MAX_PRODUCT_ENTITLEMENTS = 256
local MAX_ENTITLEMENT_ID_BYTES = 128
local MAX_USER_ID = 9007199254740991

local function valid_text(value: unknown, maximum: number): boolean
	return type(value) == "string" and value ~= "" and #value <= maximum
		and string.find(value, "%c") == nil
end

local function positive_integer(value: unknown): boolean
	return type(value) == "number" and math.isfinite(value)
		and value > 0 and value <= MAX_USER_ID and math.floor(value) == value
end

local function decision(action: string, status: string, message: string?): Decision
	return table.freeze({ action = action, status = status, message = message })
end

local function validate_receipt(raw: unknown): (Receipt?, string?)
	if type(raw) ~= "table" then return nil, "receipt must be a table" end
	local value = raw :: { [string]: unknown }
	if not valid_text(value.PurchaseId, MAX_PURCHASE_ID_BYTES)
		or not positive_integer(value.PlayerId)
		or not positive_integer(value.ProductId)
	then
		return nil, "PurchaseId, PlayerId or ProductId is malformed"
	end
	return table.freeze({
		PurchaseId = value.PurchaseId :: string,
		PlayerId = value.PlayerId :: number,
		ProductId = value.ProductId :: number,
	}), nil
end

local function validate_purchase_record(
	raw: unknown,
	receipt: Receipt
): ({ [string]: any }?, string?)
	if type(raw) ~= "table" then return nil, "purchase authority returned no record" end
	local row = raw :: { [string]: any }
	if row.PurchaseId ~= receipt.PurchaseId
		or row.PlayerId ~= receipt.PlayerId
		or row.ProductId ~= receipt.ProductId
	then
		return nil, "purchase authority identity does not match the receipt"
	end
	if row.Status ~= "claimed" and row.Status ~= "committed"
		and row.Status ~= "conflict" and row.Status ~= "corrupt"
	then
		return nil, "purchase authority returned an unsupported status"
	end
	if row.Status == "committed"
		and row.Outcome ~= "granted" and row.Outcome ~= "duplicate" and row.Outcome ~= "historical"
	then
		return nil, "purchase authority returned a committed row without a valid terminal outcome"
	end
	return row, nil
end

local function authority_method(authority: any, method_name: string, ...: any): (any?, string?)
	local arguments = table.pack(...)
	local ok, value, message = pcall(function()
		local method = authority[method_name]
		if type(method) ~= "function" then error("authority lacks " .. method_name) end
		return method(authority, table.unpack(arguments, 1, arguments.n))
	end)
	if not ok then return nil, tostring(value) end
	if type(message) == "string" and message ~= "" then return nil, message end
	return value, nil
end

local function confirm_purchase_status(options: NormalizedOptions, receipt: Receipt): ({ [string]: any }?, string?)
	local raw, message = authority_method(
		options.purchase_authority, "GetStatusAsync",
		receipt.PurchaseId, receipt.PlayerId, receipt.ProductId
	)
	if raw == nil then return nil, message or "purchase authority status is unknown" end
	return validate_purchase_record(raw, receipt)
end

local function claim_purchase(options: NormalizedOptions, receipt: Receipt): ({ [string]: any }?, string?)
	local raw, message = authority_method(
		options.purchase_authority, "ClaimAsync",
		receipt.PurchaseId, receipt.PlayerId, receipt.ProductId
	)
	local row = if raw == nil then nil else validate_purchase_record(raw, receipt)
	if row ~= nil then return row, nil end
	local observed, read_error = confirm_purchase_status(options, receipt)
	if observed ~= nil then return observed, nil end
	return nil, message or read_error or "purchase authority claim is unresolved"
end

local function confirm_purchase_commit(
	options: NormalizedOptions,
	receipt: Receipt,
	outcome: string
): (boolean, string?)
	local raw, message = authority_method(
		options.purchase_authority, "CommitAsync",
		receipt.PurchaseId, receipt.PlayerId, receipt.ProductId, outcome
	)
	if raw ~= nil then
		local row, validation_error = validate_purchase_record(raw, receipt)
		if row ~= nil and row.Status == "committed" then return true, nil end
		if row ~= nil and (row.Status == "conflict" or row.Status == "corrupt") then
			return false, "purchase authority refused terminal commit: " .. row.Status
		end
		if validation_error ~= nil then message = validation_error end
	end
	local observed, read_error = confirm_purchase_status(options, receipt)
	if observed ~= nil and observed.Status == "committed" then return true, nil end
	return false, message or read_error or "purchase authority commit is not durably confirmed"
end

local function normalize_entitlement_result(raw: unknown): ({ [string]: any }?, string?)
	if type(raw) ~= "table" then return nil, "entitlement authority returned no result" end
	local value = raw :: { [string]: any }
	if not valid_text(value.code, 64) then return nil, "entitlement authority returned no status code" end
	if value.record ~= nil and type(value.record) ~= "table" then
		return nil, "entitlement authority returned a malformed record"
	end
	return value, nil
end

local function entitlement_matches(
	row: { [string]: any }?,
	entitlement_id: string,
	receipt: Receipt
): (boolean, string?)
	if row == nil then return false, "entitlement authority did not return a row" end
	if row.entitlement_id ~= entitlement_id or row.player_id ~= receipt.PlayerId then
		return false, "entitlement authority identity does not match the requested owner"
	end
	return true, nil
end

local function read_entitlement_status(
	options: NormalizedOptions,
	entitlement_id: string,
	receipt: Receipt
): ({ [string]: any }?, string?)
	local raw, message = authority_method(
		options.entitlement_authority, "GetStatusAsync", entitlement_id, receipt.PlayerId
	)
	local normalized, normalize_error = normalize_entitlement_result(raw)
	if normalized == nil then return nil, message or normalize_error or "entitlement status is unknown" end
	if normalized.code == "unknown" or normalized.code == "corrupt" or normalized.code == "conflict" then
		return nil, normalized.message or normalized.code
	end
	if normalized.record ~= nil then
		local matches, identity_error = entitlement_matches(
			normalized.record, entitlement_id, receipt
		)
		if not matches then return nil, identity_error end
	end
	return normalized, nil
end

local function reserve_entitlement(
	options: NormalizedOptions,
	entitlement_id: string,
	receipt: Receipt
): ({ [string]: any }?, string?)
	local raw, message = authority_method(
		options.entitlement_authority, "ReserveAsync",
		entitlement_id, receipt.PlayerId, receipt.ProductId, receipt.PurchaseId
	)
	local normalized, normalize_error = normalize_entitlement_result(raw)
	if normalized ~= nil and normalized.code ~= "unknown" then return normalized, nil end
	local observed, read_error = read_entitlement_status(options, entitlement_id, receipt)
	if observed == nil then return nil, message or normalize_error or read_error or "entitlement reservation is unresolved" end
	local row = observed.record
	if observed.code == "owned" then
		if row ~= nil and row.purchase_id == receipt.PurchaseId and row.product_id == receipt.ProductId then
			return { code = "owned", record = row }, nil
		end
		return { code = "already_owned", record = row }, nil
	end
	if observed.code == "pending" then
		if row ~= nil and row.purchase_id == receipt.PurchaseId and row.product_id == receipt.ProductId then
			return { code = "claimed", record = row }, nil
		end
		return { code = "pending", record = row }, nil
	end
	return nil, message or normalize_error or "entitlement reservation could not be confirmed"
end

local function commit_entitlement(
	options: NormalizedOptions,
	entitlement_id: string,
	receipt: Receipt
): (boolean, string?)
	local raw, message = authority_method(
		options.entitlement_authority, "CommitAsync",
		entitlement_id, receipt.PlayerId, receipt.ProductId, receipt.PurchaseId
	)
	local normalized, normalize_error = normalize_entitlement_result(raw)
	if normalized ~= nil and (normalized.code == "committed" or normalized.code == "owned") then
		local row = normalized.record
		local matches, identity_error = entitlement_matches(row, entitlement_id, receipt)
		if matches and row ~= nil and row.status == "owned"
			and row.purchase_id == receipt.PurchaseId and row.product_id == receipt.ProductId
		then
			return true, nil
		end
		if identity_error ~= nil then return false, identity_error end
	end
	local observed, read_error = read_entitlement_status(options, entitlement_id, receipt)
	if observed ~= nil and observed.code == "owned" and observed.record ~= nil
		and observed.record.purchase_id == receipt.PurchaseId
		and observed.record.product_id == receipt.ProductId
	then
		return true, nil
	end
	return false, message or normalize_error or read_error or "entitlement commit is not durably confirmed"
end

local function process_receipt(options: NormalizedOptions, raw_receipt: unknown): Decision
	local receipt, receipt_error = validate_receipt(raw_receipt)
	if receipt == nil then return decision("defer", "invalid_receipt", receipt_error) end
	local entitlement_id = options.entitlement_by_product_id[receipt.ProductId]
	if entitlement_id == nil then return decision("not_applicable", "unmapped_product", nil) end

	local gate_ok, activation_ready, gate_message = pcall(options.verify_activation)
	if not gate_ok or activation_ready ~= true then
		return decision("defer", "activation_blocked", if gate_ok then gate_message else tostring(activation_ready))
	end

	local purchase, purchase_error = claim_purchase(options, receipt)
	if purchase == nil then return decision("defer", "purchase_unknown", purchase_error) end
	if purchase.Status == "conflict" or purchase.Status == "corrupt" then
		return decision("defer", "purchase_conflict", "purchase identity authority returned " .. purchase.Status)
	end
	if purchase.Status == "committed" then
		return decision("acknowledge", "purchase_already_committed", nil)
	end
	if purchase.Status ~= "claimed" then return decision("defer", "purchase_state_unknown", nil) end

	local entitlement, entitlement_error = reserve_entitlement(options, entitlement_id, receipt)
	if entitlement == nil then return decision("defer", "entitlement_unknown", entitlement_error) end
	local entitlement_code = entitlement.code
	local owner = entitlement.record
	if entitlement_code == "already_owned" or entitlement_code == "owned"
		or entitlement_code == "claimed" or entitlement_code == "pending"
	then
		if owner == nil then
			return decision("defer", "entitlement_state_unknown", "entitlement status has no authoritative record")
		end
		local identity_ok, identity_error = entitlement_matches(owner, entitlement_id, receipt)
		if not identity_ok then return decision("defer", "entitlement_conflict", identity_error) end
		if entitlement_code == "already_owned" or entitlement_code == "owned" then
			if owner.status ~= "owned" then
				return decision("defer", "entitlement_state_unknown", "owned entitlement status conflicts with the durable row")
			end
		elseif entitlement_code == "claimed" or entitlement_code == "pending" then
			if owner.status ~= "pending" then
				return decision("defer", "entitlement_state_unknown", "pending entitlement status conflicts with the durable row")
			end
		end
	end

	if entitlement_code == "already_owned" then
		local committed, message = confirm_purchase_commit(options, receipt, "duplicate")
		if not committed then return decision("defer", "duplicate_not_committed", message) end
		return decision("acknowledge", "lifetime_entitlement_already_owned", nil)
	end
	if entitlement_code == "owned" then
		if owner == nil or owner.purchase_id ~= receipt.PurchaseId or owner.product_id ~= receipt.ProductId then
			return decision("defer", "entitlement_conflict", "owned entitlement is not bound to this receipt")
		end
		local committed, message = confirm_purchase_commit(options, receipt, "granted")
		if not committed then return decision("defer", "purchase_commit_unknown", message) end
		return decision("acknowledge", "entitlement_already_committed", nil)
	end
	if entitlement_code == "pending" then
		return decision("defer", "entitlement_pending", "another receipt has an unresolved claim for this lifetime entitlement")
	end
	if entitlement_code ~= "claimed" then
		return decision("defer", "entitlement_state_unknown", "entitlement status is " .. tostring(entitlement_code))
	end
	if owner ~= nil and (owner.purchase_id ~= receipt.PurchaseId or owner.product_id ~= receipt.ProductId
		or owner.status ~= "pending")
	then
		return decision("defer", "entitlement_conflict", "pending entitlement is bound to a different receipt")
	end

	local grant_ok, grant_code, grant_message = pcall(
		options.grant_profile_once, receipt, "purchase:" .. receipt.PurchaseId
	)
	if not grant_ok then return decision("defer", "profile_grant_unknown", tostring(grant_code)) end
	if grant_code ~= "granted" and grant_code ~= "duplicate" then
		return decision("defer", "profile_grant_unconfirmed", tostring(grant_message or grant_code or "unknown grant result"))
	end

	local entitlement_committed, entitlement_commit_error = commit_entitlement(options, entitlement_id, receipt)
	if not entitlement_committed then
		return decision("defer", "entitlement_commit_unknown", entitlement_commit_error)
	end
	local purchase_committed, purchase_commit_error = confirm_purchase_commit(options, receipt, grant_code)
	if not purchase_committed then
		return decision("defer", "purchase_commit_unknown", purchase_commit_error)
	end
	return decision("acknowledge", if grant_code == "duplicate" then "duplicate_grant_reconciled" else "grant_committed", nil)
end

function Coordinator.new(config: Options)
	if type(config) ~= "table" then error("config must be a table", 2) end
	for key in pairs(config) do
		if key ~= "purchase_authority" and key ~= "entitlement_authority"
			and key ~= "entitlement_by_product_id" and key ~= "grant_profile_once"
			and key ~= "verify_activation"
		then
			error("unsupported lifetime entitlement coordinator option: " .. tostring(key), 2)
		end
	end
	if type(config.purchase_authority) ~= "table" then error("purchase_authority is required", 2) end
	if type(config.entitlement_authority) ~= "table" then error("entitlement_authority is required", 2) end
	if type(config.entitlement_by_product_id) ~= "table" then error("product_entitlement_by_id is required", 2) end
	if type(config.grant_profile_once) ~= "function" then error("grant_profile_once is required", 2) end
	if type(config.verify_activation) ~= "function" then error("verify_activation is required", 2) end
	for _, method in ipairs({ "ClaimAsync", "CommitAsync", "GetStatusAsync" }) do
		if type(config.purchase_authority[method]) ~= "function" then
			error("purchase_authority lacks " .. method, 2)
		end
	end
	for _, method in ipairs({ "ReserveAsync", "CommitAsync", "GetStatusAsync" }) do
		if type(config.entitlement_authority[method]) ~= "function" then
			error("entitlement_authority lacks " .. method, 2)
		end
	end
	local mapping: { [number]: string } = {}
	local count = 0
	for product_id, entitlement_id in pairs(config.entitlement_by_product_id) do
		if not positive_integer(product_id) or not valid_text(entitlement_id, MAX_ENTITLEMENT_ID_BYTES) then
			error("product entitlement map requires positive product IDs and valid entitlement IDs", 2)
		end
		mapping[product_id] = entitlement_id
		count += 1
	end
	if count < 1 or count > MAX_PRODUCT_ENTITLEMENTS then
		error("product entitlement map must contain 1 to 256 products", 2)
	end
	local normalized: NormalizedOptions = table.freeze({
		purchase_authority = config.purchase_authority,
		entitlement_authority = config.entitlement_authority,
		entitlement_by_product_id = table.freeze(mapping),
		grant_profile_once = config.grant_profile_once,
		verify_activation = config.verify_activation,
	})
	local instance: any = {}
	function instance:HandlesProduct(product_id: unknown): boolean
		if not positive_integer(product_id) then return false end
		return normalized.entitlement_by_product_id[product_id :: number] ~= nil
	end

	function instance:Process(receipt: unknown): Decision
		return process_receipt(normalized, receipt)
	end
	return table.freeze(instance)
end

return Coordinator
