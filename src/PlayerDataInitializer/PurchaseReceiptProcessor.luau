--!strict
local RecordStore = require(script.Parent:WaitForChild("RecordStore"))

local PurchaseReceiptProcessor = {}

export type ReceiptContext = {
	PurchaseId: string,
	PlayerId: number,
	ProductId: number,
}

export type GrantReducer = (
	current_data: RecordStore.JsonValue?,
	receipt: ReceiptContext
) -> (RecordStore.JsonValue?, RecordStore.JsonValue?)

export type Diagnostic = {
	category: string,
	status: string?,
	message: string?,
	product_id: number?,
}

export type Config = {
	get_record: (player_id: number) -> RecordStore.Record?,
	receipt_retention_seconds: number,
	on_diagnostic: ((diagnostic: Diagnostic) -> ())?,
}

export type ReceiptHandler = (receipt_info: unknown) -> EnumItem

export type Processor = {
	CreateHandler: (
		self: Processor,
		product_grant_reducers: { [number]: GrantReducer }
	) -> ReceiptHandler,
}

type NormalizedConfig = {
	get_record: (player_id: number) -> RecordStore.Record?,
	receipt_retention_seconds: number,
	on_diagnostic: ((diagnostic: Diagnostic) -> ())?,
}

local OPERATION_ID_PREFIX = "purchase:"
local MAX_OPERATION_ID_BYTES = 256
local MAX_PURCHASE_ID_BYTES = MAX_OPERATION_ID_BYTES - #OPERATION_ID_PREFIX
local MAX_RECEIPT_RETENTION_SECONDS = 31_536_000

local function normalize_config(config: unknown): NormalizedConfig
	if type(config) ~= "table" then
		error("config must be a table", 3)
	end

	local values = config :: { [string]: unknown }
	for option_name in pairs(values) do
		if option_name ~= "get_record"
			and option_name ~= "receipt_retention_seconds"
			and option_name ~= "on_diagnostic"
		then
			error("unsupported purchase receipt option: " .. tostring(option_name), 3)
		end
	end

	local get_record = values.get_record
	if type(get_record) ~= "function" then
		error("get_record must be a function that returns an already-active profile", 3)
	end

	local retention = values.receipt_retention_seconds
	if type(retention) ~= "number" or not math.isfinite(retention)
		or retention < 1 or retention > MAX_RECEIPT_RETENTION_SECONDS
	then
		error("receipt_retention_seconds must be from 1 to 31536000", 3)
	end

	local on_diagnostic = values.on_diagnostic
	if on_diagnostic ~= nil and type(on_diagnostic) ~= "function" then
		error("on_diagnostic must be a function when provided", 3)
	end

	local normalized: NormalizedConfig = {
		get_record = get_record :: (player_id: number) -> RecordStore.Record?,
		receipt_retention_seconds = retention :: number,
		on_diagnostic = on_diagnostic :: ((diagnostic: Diagnostic) -> ())?,
	}
	return table.freeze(normalized)
end

local function emit_diagnostic(
	config: NormalizedConfig,
	category: string,
	status: string?,
	message: string?,
	product_id: number?
)
	local diagnostic: Diagnostic = {
		category = category,
		status = status,
		message = message,
		product_id = product_id,
	}
	if config.on_diagnostic ~= nil then
		local ok = pcall(config.on_diagnostic, table.freeze(diagnostic))
		if not ok then
			warn("[PurchaseReceiptProcessor] diagnostic callback failed")
		end
		return
	end

	local detail = if status ~= nil then " (" .. status .. ")" else ""
	warn("[PurchaseReceiptProcessor] " .. category .. detail)
end

local function is_positive_integer(value: unknown): boolean
	return type(value) == "number"
		and math.isfinite(value)
		and value > 0
		and math.floor(value) == value
end

local function copy_product_reducers(
	product_grant_reducers: { [number]: GrantReducer }
): { [number]: GrantReducer }
	if type(product_grant_reducers) ~= "table" then
		error("product_grant_reducers must be a table keyed by developer product ID", 3)
	end

	local copied: { [number]: GrantReducer } = {}
	for product_id_value, reducer_value in pairs(product_grant_reducers) do
		if not is_positive_integer(product_id_value) then
			error("product_grant_reducers keys must be positive integer product IDs", 3)
		end
		if type(reducer_value) ~= "function" then
			error("each product grant reducer must be a function", 3)
		end
		copied[product_id_value :: number] = reducer_value :: GrantReducer
	end
	if next(copied) == nil then
		error("at least one product grant reducer must be configured", 3)
	end
	return table.freeze(copied)
end

local function create_handler(
	config: NormalizedConfig,
	product_grant_reducers: { [number]: GrantReducer }
): ReceiptHandler
	local purchase_granted = Enum.ProductPurchaseDecision.PurchaseGranted
	local not_processed_yet = Enum.ProductPurchaseDecision.NotProcessedYet

	return function(receipt_info: unknown): EnumItem
		if type(receipt_info) ~= "table" then
			emit_diagnostic(config, "invalid_receipt", nil, "receipt must be a table", nil)
			return not_processed_yet
		end

		local fields = receipt_info :: { [string]: unknown }
		local purchase_id = fields.PurchaseId
		local player_id = fields.PlayerId
		local product_id = fields.ProductId
		if type(purchase_id) ~= "string" or purchase_id == ""
			or #purchase_id > MAX_PURCHASE_ID_BYTES
			or string.find(purchase_id, "%c") ~= nil
			or not is_positive_integer(player_id)
			or not is_positive_integer(product_id)
		then
			emit_diagnostic(config, "invalid_receipt", nil, "receipt identity fields are invalid", nil)
			return not_processed_yet
		end

		local validated_purchase_id = purchase_id :: string
		local validated_player_id = player_id :: number
		local validated_product_id = product_id :: number
		local grant_reducer = product_grant_reducers[validated_product_id]
		if grant_reducer == nil then
			emit_diagnostic(config, "unsupported_product", nil, "no server-side grant reducer is configured", validated_product_id)
			return not_processed_yet
		end

		local lookup_ok, record = pcall(config.get_record, validated_player_id)
		if not lookup_ok or record == nil then
			emit_diagnostic(config, "active_profile_unavailable", nil, "no active profile is available", validated_product_id)
			return not_processed_yet
		end

		local session_ok, session_state, session_is_open = pcall(function()
			return record:GetState(), record:IsOpen()
		end)
		if not session_ok or session_state ~= "active" or session_is_open ~= true then
			emit_diagnostic(config, "active_profile_unavailable", nil, "profile is not actively owned on this server", validated_product_id)
			return not_processed_yet
		end

		local receipt_context: ReceiptContext = table.freeze({
			PurchaseId = validated_purchase_id,
			PlayerId = validated_player_id,
			ProductId = validated_product_id,
		})
		local request: RecordStore.JsonValue = {
			receipt_type = "developer_product",
			purchase_id = validated_purchase_id,
			player_id = validated_player_id,
			product_id = validated_product_id,
		}
		local transaction_reducer: RecordStore.TransactionReducer = function(current_data, _unused)
			return grant_reducer(current_data, receipt_context)
		end

		local transaction_ok, _result, status, message = pcall(function()
			return record:TransactAsync(
				OPERATION_ID_PREFIX .. validated_purchase_id,
				transaction_reducer,
				{
					request = request,
					receipt_retention_seconds = config.receipt_retention_seconds,
				}
			)
		end)
		if transaction_ok and (status == "committed" or status == "duplicate") then
			return purchase_granted
		end

		if not transaction_ok or status == "unknown" then
			local lookup_ok, durable_status = pcall(function()
				return record:GetTransactionStatusAsync(
					OPERATION_ID_PREFIX .. validated_purchase_id,
					request
				)
			end)
			if lookup_ok and durable_status.code == "committed" then
				return purchase_granted
			end
			if lookup_ok and durable_status.code == "conflict" then
				emit_diagnostic(config, "transaction_conflict", "conflict",
					durable_status.message, validated_product_id)
				return not_processed_yet
			end
			local lookup_message = if lookup_ok then durable_status.message else tostring(durable_status)
			emit_diagnostic(config, "transaction_status_unresolved",
				if lookup_ok then durable_status.code else "unknown",
				lookup_message or tostring(_result), validated_product_id)
			return not_processed_yet
		end

		local outcome_status = status :: string?
		local category = if outcome_status == "conflict" then "transaction_conflict" else "transaction_deferred"
		emit_diagnostic(config, category, outcome_status, message, validated_product_id)
		return not_processed_yet
	end
end

function PurchaseReceiptProcessor.new(config: Config): Processor
	local normalized = normalize_config(config)
	local processor: Processor = {
		CreateHandler = function(_self, product_grant_reducers)
			local reducers = copy_product_reducers(product_grant_reducers)
			return create_handler(normalized, reducers)
		end,
	}
	return processor
end

return PurchaseReceiptProcessor
