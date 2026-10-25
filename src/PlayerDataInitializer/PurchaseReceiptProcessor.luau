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
	permanent_purchase_ledger_key: string?,
	permanent_purchase_ledger_capacity: number?,
	-- Acknowledges that pre-existing PurchaseIds were backfilled or do not exist.
	-- This is an operator assertion, not automatic proof of the migration.
	permanent_purchase_ledger_migration_complete: boolean?,
	on_diagnostic: ((diagnostic: Diagnostic) -> ())?,
}

export type ReceiptHandler = (receipt_info: unknown) -> EnumItem

export type HistoricalPurchase = {
	PurchaseId: string,
	PlayerId: number,
	ProductId: number,
}

export type BackfillResult = {
	code: string,
	processed_count: number,
	backfilled_count: number,
	duplicate_count: number,
	failed_index: number?,
	message: string?,
}

export type Processor = {
	CreateHandler: (
		self: Processor,
		product_grant_reducers: { [number]: GrantReducer }
	) -> ReceiptHandler,
	BackfillPermanentLedgerAsync: (
		self: Processor,
		record: RecordStore.Record,
		purchases: { HistoricalPurchase },
		max_items: number?
	) -> BackfillResult,
}

type NormalizedConfig = {
	get_record: (player_id: number) -> RecordStore.Record?,
	receipt_retention_seconds: number,
	permanent_purchase_ledger_key: string?,
	permanent_purchase_ledger_capacity: number?,
	permanent_purchase_ledger_migration_complete: boolean,
	on_diagnostic: ((diagnostic: Diagnostic) -> ())?,
}

local OPERATION_ID_PREFIX = "purchase:"
local MAX_OPERATION_ID_BYTES = 256
local MAX_PURCHASE_ID_BYTES = MAX_OPERATION_ID_BYTES - #OPERATION_ID_PREFIX
local MAX_RECEIPT_RETENTION_SECONDS = 31_536_000
local MAX_PERMANENT_PURCHASE_LEDGER_ENTRIES = 8192
local PERMANENT_LEDGER_RESULT_KEY = "recordstore_internal_purchase_ledger_status_v1"

local function normalize_config(config: unknown): NormalizedConfig
	if type(config) ~= "table" then
		error("config must be a table", 3)
	end

	local values = config :: { [string]: unknown }
	for option_name in pairs(values) do
		if option_name ~= "get_record"
			and option_name ~= "receipt_retention_seconds"
			and option_name ~= "permanent_purchase_ledger_key"
			and option_name ~= "permanent_purchase_ledger_capacity"
			and option_name ~= "permanent_purchase_ledger_migration_complete"
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

	local ledger_key = values.permanent_purchase_ledger_key
	local ledger_capacity = values.permanent_purchase_ledger_capacity
	local ledger_migration_complete = values.permanent_purchase_ledger_migration_complete
	if ledger_migration_complete ~= nil and type(ledger_migration_complete) ~= "boolean" then
		error("permanent_purchase_ledger_migration_complete must be a boolean", 3)
	end
	if ledger_key == nil then
		if ledger_capacity ~= nil then
			error("permanent_purchase_ledger_capacity requires permanent_purchase_ledger_key", 3)
		end
		if ledger_migration_complete == true then
			error("permanent_purchase_ledger_migration_complete requires permanent_purchase_ledger_key", 3)
		end
	elseif type(ledger_key) ~= "string" or ledger_key == "" or #ledger_key > 96
		or string.sub(ledger_key, 1, #"__recordstore_") == "__recordstore_"
	then
		error("permanent_purchase_ledger_key must be a non-reserved application data field of 1 to 96 bytes", 3)
	end
	-- Keep the processor available for a read/reconcile-only ledger backfill.
	-- The receipt handler itself remains blocked until this gate is true.
	if ledger_capacity ~= nil and (type(ledger_capacity) ~= "number"
		or not math.isfinite(ledger_capacity) or math.floor(ledger_capacity) ~= ledger_capacity
		or ledger_capacity < 1 or ledger_capacity > MAX_PERMANENT_PURCHASE_LEDGER_ENTRIES)
	then
		error("permanent_purchase_ledger_capacity must be an integer from 1 to 8192", 3)
	end

	local on_diagnostic = values.on_diagnostic
	if on_diagnostic ~= nil and type(on_diagnostic) ~= "function" then
		error("on_diagnostic must be a function when provided", 3)
	end

	local normalized: NormalizedConfig = {
		get_record = get_record :: (player_id: number) -> RecordStore.Record?,
		receipt_retention_seconds = retention :: number,
		permanent_purchase_ledger_key = ledger_key :: string?,
		permanent_purchase_ledger_capacity = (ledger_capacity or (if ledger_key ~= nil then MAX_PERMANENT_PURCHASE_LEDGER_ENTRIES else nil)) :: number?,
		permanent_purchase_ledger_migration_complete = ledger_migration_complete == true,
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
		if config.permanent_purchase_ledger_key ~= nil
			and config.permanent_purchase_ledger_migration_complete ~= true
		then
			emit_diagnostic(config, "permanent_purchase_ledger_migration_required", "blocked",
				"receipt grants are disabled until historical PurchaseIds are backfilled or explicitly reconciled",
				validated_product_id)
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
			local ledger_key = config.permanent_purchase_ledger_key
			if ledger_key == nil then
				return grant_reducer(current_data, receipt_context)
			end
			local function ledger_result(ledger_status: string, grant_result: RecordStore.JsonValue?): RecordStore.JsonValue
				local marker: { [string]: RecordStore.JsonValue } = { status = ledger_status }
				if grant_result ~= nil then marker.grant_result = grant_result end
				return { [PERMANENT_LEDGER_RESULT_KEY] = marker }
			end
			if type(current_data) ~= "table" then
				return current_data, ledger_result("corrupt")
			end
			local current = current_data :: { [string]: RecordStore.JsonValue }
			for key in pairs(current) do
				if type(key) ~= "string" then return current_data, ledger_result("corrupt") end
			end
			local raw_ledger = current[ledger_key]
			if raw_ledger ~= nil and type(raw_ledger) ~= "table" then
				return current_data, ledger_result("corrupt")
			end
			local ledger: { [string]: RecordStore.JsonValue } = {}
			local prior_count = 0
			if raw_ledger ~= nil then
				local raw_entries = raw_ledger :: { [string]: RecordStore.JsonValue }
				for prior_id, raw_prior in pairs(raw_entries) do
					if type(prior_id) ~= "string" or prior_id == "" or type(raw_prior) ~= "table" then
						return current_data, ledger_result("corrupt")
					end
					local prior_fields = raw_prior :: { [string]: RecordStore.JsonValue }
					if not is_positive_integer(prior_fields.player_id)
						or not is_positive_integer(prior_fields.product_id)
					then
						return current_data, ledger_result("corrupt")
					end
					ledger[prior_id] = {
						player_id = prior_fields.player_id,
						product_id = prior_fields.product_id,
					}
					prior_count += 1
				end
			end
		local prior = ledger[validated_purchase_id]
		if prior ~= nil then
			if type(prior) ~= "table" then return current_data, ledger_result("corrupt") end
			local prior_fields = prior :: { [string]: RecordStore.JsonValue }
			if prior_fields.player_id == validated_player_id and prior_fields.product_id == validated_product_id then
				return current_data, ledger_result("duplicate")
			end
			return current_data, ledger_result("conflict")
		end
			if prior_count >= (config.permanent_purchase_ledger_capacity :: number) then
				return current_data, ledger_result("capacity")
			end
			local next_data, result = grant_reducer(current_data, receipt_context)
			if type(next_data) ~= "table" then
				return current_data, ledger_result("invalid_grant")
			end
			local next_data_dictionary = next_data :: { [string]: RecordStore.JsonValue }
			for next_key in pairs(next_data_dictionary) do
				if type(next_key) ~= "string" then return current_data, ledger_result("invalid_grant") end
			end
			ledger[validated_purchase_id] = {
				player_id = validated_player_id,
				product_id = validated_product_id,
			}
			local committed_data = table.clone(next_data :: { [string]: RecordStore.JsonValue })
			committed_data[ledger_key] = ledger
			return committed_data, ledger_result("granted", result)
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
		local function defer_for_permanent_ledger(result_value: unknown): boolean
			if config.permanent_purchase_ledger_key == nil then return false end
			local marker = if type(result_value) == "table"
				then (result_value :: { [string]: unknown })[PERMANENT_LEDGER_RESULT_KEY]
				else nil
			if type(marker) ~= "table" then
				-- Older transaction receipts created before the permanent-ledger option
				-- cannot prove that the application ledger was populated. Do not silently
				-- acknowledge them and risk re-granting after the finite sidecar expires.
				emit_diagnostic(config, "permanent_purchase_ledger_marker_missing", "unknown",
					"transaction receipt predates or lacks the permanent-ledger result marker; operator reconciliation is required",
					validated_product_id)
				return true
			end
			local ledger_status = (marker :: { [string]: unknown }).status
			if ledger_status == "granted" or ledger_status == "duplicate" then return false end
			if ledger_status == "conflict" or ledger_status == "capacity"
				or ledger_status == "corrupt" or ledger_status == "invalid_grant"
			then
				local category = if ledger_status == "conflict" then "permanent_purchase_conflict"
					elseif ledger_status == "capacity" then "permanent_purchase_ledger_capacity"
					elseif ledger_status == "corrupt" then "permanent_purchase_ledger_corrupt"
					else "purchase_grant_rejected"
				emit_diagnostic(config, category, tostring(ledger_status),
					"permanent purchase ledger did not authorize a new grant", validated_product_id)
				return true
			end
			emit_diagnostic(config, "permanent_purchase_ledger_marker_missing", "unknown",
				"unrecognized permanent-ledger marker; operator reconciliation is required", validated_product_id)
			return true
		end
		if transaction_ok and (status == "committed" or status == "duplicate") then
			if defer_for_permanent_ledger(_result) then return not_processed_yet end
			return purchase_granted
		end

		if not transaction_ok or status == "unknown" then
			local status_lookup_ok, durable_status = pcall(function()
				return record:GetTransactionStatusAsync(
					OPERATION_ID_PREFIX .. validated_purchase_id,
					request
				)
			end)
			if status_lookup_ok and durable_status ~= nil and durable_status.code == "committed" then
				if defer_for_permanent_ledger(durable_status.result) then return not_processed_yet end
				return purchase_granted
			end
			if status_lookup_ok and durable_status ~= nil and durable_status.code == "conflict" then
				emit_diagnostic(config, "transaction_conflict", "conflict",
					durable_status.message, validated_product_id)
				return not_processed_yet
			end
			local lookup_message = if status_lookup_ok and durable_status ~= nil
				then durable_status.message
				elseif status_lookup_ok then "transaction status lookup returned no structured result"
				else tostring(durable_status)
			local lookup_status = if status_lookup_ok and durable_status ~= nil
				then durable_status.code
				else "unknown"
			emit_diagnostic(config, "transaction_status_unresolved", lookup_status,
				lookup_message or tostring(_result), validated_product_id)
			return not_processed_yet
		end

		local outcome_status = status :: string?
		local category = if outcome_status == "conflict" then "transaction_conflict" else "transaction_deferred"
		emit_diagnostic(config, category, outcome_status, message, validated_product_id)
		return not_processed_yet
	end
end


local BACKFILL_OPERATION_ID_PREFIX = "pb:"
local MAX_BACKFILL_PURCHASE_ID_BYTES = MAX_PURCHASE_ID_BYTES
local MAX_BACKFILL_BATCH = 16

local function backfill_permanent_ledger(
	config: NormalizedConfig,
	record: RecordStore.Record,
	purchases: { HistoricalPurchase },
	max_items: number?
): BackfillResult
	local result: BackfillResult = {
		code = "invalid",
		processed_count = 0,
		backfilled_count = 0,
		duplicate_count = 0,
		failed_index = nil,
		message = nil,
	}
	local ledger_key = config.permanent_purchase_ledger_key
	if ledger_key == nil then
		result.code = "unsupported"
		result.message = "permanent_purchase_ledger_key is not configured"
		return result
	end

	local limit = if max_items == nil then MAX_BACKFILL_BATCH else max_items
	if type(limit) ~= "number" or not math.isfinite(limit) or math.floor(limit) ~= limit
		or limit < 1 or limit > MAX_BACKFILL_BATCH
	then
		result.message = "max_items must be an integer from 1 to 16"
		return result
	end
	if type(purchases) ~= "table" then
		result.message = "purchases must be a dense array"
		return result
	end
	local count = #purchases
	if count < 1 or count > limit then
		result.message = "purchases must contain 1 to max_items entries"
		return result
	end
	local dense_count = 0
	for key in pairs(purchases) do
		if type(key) ~= "number" or not math.isfinite(key) or math.floor(key) ~= key
			or key < 1 or key > count
		then
			result.message = "purchases must be a dense numeric array"
			return result
		end
		dense_count += 1
	end
	if dense_count ~= count then
		result.message = "purchases must be a dense numeric array"
		return result
	end

	local session_ok, session_state, session_open, identity = pcall(function()
		return record:GetState(), record:IsOpen(), record:GetIdentity()
	end)
	if not session_ok or session_state ~= "active" or session_open ~= true or type(identity) ~= "table" then
		result.code = "fenced"
		result.message = "historical ledger backfill requires active profile ownership"
		return result
	end
	if type(identity.user_ids) ~= "table" then
		result.code = "fenced"
		result.message = "profile identity does not expose UserIds for ownership verification"
		return result
	end
	local allowed_players: { [number]: boolean } = {}
	for _, user_id in ipairs(identity.user_ids) do
		if not is_positive_integer(user_id) then
			result.code = "fenced"
			result.message = "profile UserId metadata is malformed"
			return result
		end
		allowed_players[user_id] = true
	end

	-- Validate the complete batch before the first write so malformed input
	-- cannot leave a partially imported batch.
	local purchase_id_by_index: { [number]: string } = {}
	local player_id_by_index: { [number]: number } = {}
	local product_id_by_index: { [number]: number } = {}
	for index = 1, count do
		local item = purchases[index]
		if type(item) ~= "table" then
			result.message = "purchase entry must be a table"
			result.failed_index = index
			return result
		end
		local purchase_id = item.PurchaseId
		local player_id = item.PlayerId
		local product_id = item.ProductId
		if type(purchase_id) ~= "string" or purchase_id == ""
			or #purchase_id > MAX_BACKFILL_PURCHASE_ID_BYTES
			or string.find(purchase_id, "%c") ~= nil
			or not is_positive_integer(player_id)
			or not is_positive_integer(product_id)
		then
			result.message = "historical PurchaseId, PlayerId, or ProductId is malformed"
			result.failed_index = index
			return result
		end
		if not allowed_players[player_id :: number] then
			result.code = "fenced"
			result.message = "historical PlayerId is not associated with this active profile"
			result.failed_index = index
			return result
		end
		purchase_id_by_index[index] = purchase_id :: string
		player_id_by_index[index] = player_id :: number
		product_id_by_index[index] = product_id :: number
	end

	local function get_marker(value: unknown): string?
		if type(value) ~= "table" then return nil end
		local marker = (value :: { [string]: unknown })[PERMANENT_LEDGER_RESULT_KEY]
		if type(marker) ~= "table" then return nil end
		local status = (marker :: { [string]: unknown }).status
		return if type(status) == "string" then status else nil
	end

	local function apply_one(index: number): (string, string?)
		local purchase_id = purchase_id_by_index[index]
		local player_id = player_id_by_index[index]
		local product_id = product_id_by_index[index]
		local operation_id = BACKFILL_OPERATION_ID_PREFIX .. purchase_id
		local request: RecordStore.JsonValue = {
			receipt_type = "developer_product_backfill",
			purchase_id = purchase_id,
			player_id = player_id,
			product_id = product_id,
		}
		local transaction_reducer: RecordStore.TransactionReducer = function(current_data, _unused)
			local function marker(status: string): RecordStore.JsonValue
				return { [PERMANENT_LEDGER_RESULT_KEY] = { status = status } }
			end
			if type(current_data) ~= "table" then return current_data, marker("corrupt") end
			local current = current_data :: { [string]: RecordStore.JsonValue }
			for key in pairs(current) do
				if type(key) ~= "string" then return current_data, marker("corrupt") end
			end
			local raw_ledger = current[ledger_key :: string]
			if raw_ledger ~= nil and type(raw_ledger) ~= "table" then
				return current_data, marker("corrupt")
			end
			local ledger: { [string]: RecordStore.JsonValue } = {}
			local prior_count = 0
			if raw_ledger ~= nil then
				for prior_id, raw_prior in pairs(raw_ledger :: { [string]: RecordStore.JsonValue }) do
					if type(prior_id) ~= "string" or prior_id == ""
						or #prior_id > MAX_PURCHASE_ID_BYTES or type(raw_prior) ~= "table"
					then
						return current_data, marker("corrupt")
					end
					local prior = raw_prior :: { [string]: RecordStore.JsonValue }
					if not is_positive_integer(prior.player_id) or not is_positive_integer(prior.product_id) then
						return current_data, marker("corrupt")
					end
					ledger[prior_id] = {
						player_id = prior.player_id,
						product_id = prior.product_id,
					}
					prior_count += 1
				end
			end
			local prior = ledger[purchase_id]
			if prior ~= nil then
				local prior_fields = prior :: { [string]: RecordStore.JsonValue }
				if prior_fields.player_id == player_id and prior_fields.product_id == product_id then
					return current_data, marker("duplicate")
				end
				return current_data, marker("conflict")
			end
			if prior_count >= (config.permanent_purchase_ledger_capacity :: number) then
				return current_data, marker("capacity")
			end
			ledger[purchase_id] = {
				player_id = player_id,
				product_id = product_id,
			}
			local next_data = table.clone(current)
			next_data[ledger_key :: string] = ledger
			return next_data, marker("backfilled")
		end

		local call_ok, transaction_value, transaction_status, transaction_message = pcall(function()
			return record:TransactAsync(operation_id, transaction_reducer, {
				request = request,
				receipt_retention_seconds = config.receipt_retention_seconds,
			})
		end)
		if call_ok and (transaction_status == "committed" or transaction_status == "duplicate") then
			local status = get_marker(transaction_value)
			if status == "backfilled" then
				return if transaction_status == "duplicate" then "duplicate" else "backfilled", nil
			elseif status == "duplicate" then
				return "duplicate", nil
			elseif status ~= nil then
				return status, "permanent ledger rejected the historical purchase"
			end
		end

		if not call_ok or transaction_status == "unknown" then
			local status_ok, durable_status = pcall(function()
				return record:GetTransactionStatusAsync(operation_id, request)
			end)
			if status_ok and type(durable_status) == "table" and durable_status.code == "committed" then
				local status = get_marker(durable_status.result)
				if status == "backfilled" or status == "duplicate" then
					return "duplicate", nil
				elseif status ~= nil then
					return status, "durable ledger rejected the historical purchase"
				end
			end
			if status_ok and type(durable_status) == "table" and durable_status.code == "conflict" then
				return "conflict", durable_status.message or "backfill operation ID conflicts with another request"
			end
			return "unknown", "historical PurchaseId backfill outcome is unresolved; retry the same PurchaseIds"
		end
		return if type(transaction_status) == "string" then transaction_status else "unknown",
			transaction_message or "historical PurchaseId backfill did not commit"
	end

	for index = 1, count do
		local status, message = apply_one(index)
		if status == "backfilled" or status == "duplicate" then
			result.processed_count += 1
			if status == "backfilled" then result.backfilled_count += 1 else result.duplicate_count += 1 end
		else
			result.code = if result.processed_count > 0 then "partial" else status
			result.failed_index = index
			result.message = message or ("backfill stopped with status " .. status)
			return result
		end
	end
	result.code = if result.backfilled_count == 0 then "duplicate" else "complete"
	return result
end

function PurchaseReceiptProcessor.new(config: Config): Processor
	local normalized = normalize_config(config)
	local processor: Processor = {
		CreateHandler = function(_self, product_grant_reducers)
			local reducers = copy_product_reducers(product_grant_reducers)
			return create_handler(normalized, reducers)
		end,
		BackfillPermanentLedgerAsync = function(_self, record, purchases, max_items)
			return backfill_permanent_ledger(normalized, record, purchases, max_items)
		end,
	}
	return processor
end

return PurchaseReceiptProcessor
