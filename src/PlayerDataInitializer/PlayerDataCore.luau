--!strict
--!optimize 2
-- Hardened lifecycle/persistence core.
-- RecordStore persists non-finite numbers using its versioned envelope encoding.

local Players = game:GetService("Players")

local RecordStore = require(script.Parent.RecordStore)
local IntegerInfinityValueFactory = require(script.Parent.IntegerInfinityValue)
local NumberFormatterFactory = require(script.Parent.NumberFormatter)

type Scalar = string | number | boolean
type DataValue = Scalar
type PlayerData = {
	[string]: DataValue,
}

type IntegerInfinityRounding = "nearest" | "floor" | "ceil" | "trunc"
type ValueClass =
	"IntValue"
	| "NumberValue"
	| "StringValue"
	| "BoolValue"
	| "IntegerInfinityValue"
	| "CodeNumValue"

type DataField = {
	class_name: ValueClass,
	default: DataValue,
	rounding: IntegerInfinityRounding?,
}

type Leaderstat = {
	key: string,
	name: string,
	number_format: NumberFormatterFactory.Options?,
}

type CodeNumValueNode = { kind: string }
type CodeNumValueFactoryAPI = {
	is_value: (value: unknown) -> boolean,
	normalize: (value: unknown) -> string,
	is_serialized: (value: unknown) -> boolean,
	format: (value: unknown, options: NumberFormatterFactory.Options?) -> string,
	new: (name: string, initial_value: unknown) -> StringValue,
	normalize_serialized: ((value: unknown) -> (string?, CodeNumValueNode?))?,
}

-- The default schema does not use CodeNumValue, so defer its module load.
local cached_code_num_value_factory: CodeNumValueFactoryAPI? = nil

local function get_code_num_value_factory(): CodeNumValueFactoryAPI
	if cached_code_num_value_factory == nil then
		cached_code_num_value_factory = require(script.Parent.CodeNumValue) :: CodeNumValueFactoryAPI
	end
	return cached_code_num_value_factory
end

local CodeNumValueFactory: CodeNumValueFactoryAPI = table.freeze({
	is_value = function(value: unknown): boolean
		return get_code_num_value_factory().is_value(value)
	end,
	normalize = function(value: unknown): string
		return get_code_num_value_factory().normalize(value)
	end,
	is_serialized = function(value: unknown): boolean
		return get_code_num_value_factory().is_serialized(value)
	end,
	format = function(value: unknown, options: NumberFormatterFactory.Options?): string
		return get_code_num_value_factory().format(value, options)
	end,
	new = function(name: string, initial_value: unknown): StringValue
		return get_code_num_value_factory().new(name, initial_value)
	end,
	normalize_serialized = function(value: unknown): (string?, CodeNumValueNode?)
		local factory = get_code_num_value_factory()
		local normalize = factory.normalize_serialized
		if normalize ~= nil then
			return normalize(value)
		end
		if not factory.is_serialized(value) then
			return nil, nil
		end
		return factory.normalize(value), nil
	end,
})

export type Dependencies = {
	Players: typeof(Players)?,
	RecordStore: typeof(RecordStore)?,
	IntegerInfinityValue: typeof(IntegerInfinityValueFactory)?,
	NumberFormatter: typeof(NumberFormatterFactory)?,
	CodeNumValue: CodeNumValueFactoryAPI?,
	new_instance: ((string) -> Instance)?,
	task: typeof(task)?,
}

type PlayerRecord = RecordStore.Record

type PlayerValuePathCache = {
	leaderstats: Instance?,
	player_data_values: Instance?,
	values_by_key: { [string]: Instance },
}
type PlayerValuePathKey = "leaderstats" | "player_data_values"

export type Controller = {
	Start: (self: Controller) -> boolean,
	Shutdown: (self: Controller) -> boolean,
	-- Set is intentionally dot-callable: controller.Set(player, key, value).
	Set: (player: Player, key: string, value: unknown) -> (boolean, string?),
}

local function define_data_field(
	class_name: ValueClass,
	default: DataValue,
	rounding: IntegerInfinityRounding?
): DataField
	return {
		class_name = class_name,
		default = default,
		rounding = rounding,
	}
end

local function define_leaderstat(
	key: string,
	name: string,
	number_format: NumberFormatterFactory.Options?
): Leaderstat
	return {
		key = key,
		name = name,
		number_format = number_format,
	}
end

local CONFIG = {
	-- Retained to preserve the existing dataset; change only as an explicit migration.
	store_name = "PlayerData_Test1",
	scope = "global",
	key_prefix = "Player_",

	schema_version = 1,

	-- Tuned for a broad production workload, with a generous lease recovery margin.
	lease_duration = 180,
	lease_renewal = 60,
	autosave_interval = 90,

	retry_attempts = 5,
	operation_deadline = 20,
	load_retry_attempts = 4,
	load_retry_window = 45,
	load_retry_base_delay = 0.5,
	load_retry_max_delay = 4,
	shutdown_deadline = 25,
	shutdown_attempts = 2,
	budget_wait = 2,

	data = {
		-- NumberValue-backed integer semantics allow +/-infinity and NaN.
		kills = define_data_field("IntegerInfinityValue", 0, "nearest"),
		equipped = define_data_field("StringValue", "Default"),
		admin = define_data_field("BoolValue", false),

		-- Examples:
		-- balance = define_data_field("IntegerInfinityValue", 0, "nearest"),
		-- cash = define_data_field("CodeNumValue", 0),
	},

	leaderstats = {
		enabled = true,
		name = "leaderstats",
		values = {
			-- Kills is display-formatted by default. Update PlayerDataValues.kills.Value in gameplay code.
			define_leaderstat("kills", "Kills", { decimals = 2 }),
			define_leaderstat("equipped", "Equipped"),
		},
	},
}

local uses_codenum_values = false
for _, field in pairs(CONFIG.data) do
	if field.class_name == "CodeNumValue" then
		uses_codenum_values = true
		break
	end
end

local function resolve_rounding(value: unknown): IntegerInfinityRounding
	if value == nil or value == "nearest" then
		return "nearest"
	end

	if value == "floor" or value == "ceil" or value == "trunc" then
		return value
	end

	error('rounding must be "nearest", "floor", "ceil", or "trunc"', 3)
end

local function normalize_integer_infinity(
	value: number,
	rounding: IntegerInfinityRounding,
	factory: typeof(IntegerInfinityValueFactory)?
): number
	return (factory or IntegerInfinityValueFactory).normalize(value, rounding)
end

local function numeric_values_equal(left: number, right: number): boolean
	return left == right or (math.isnan(left) and math.isnan(right))
end

local function field_value_is_valid(
	field: DataField,
	value: DataValue?,
	code_num_factory: CodeNumValueFactoryAPI?
): boolean
	if field.class_name == "IntValue" then
		return type(value) == "number" and math.isfinite(value) and math.floor(value) == value
	elseif field.class_name == "NumberValue" then
		return type(value) == "number"
	elseif field.class_name == "StringValue" then
		return type(value) == "string" and #value <= 200_000
	elseif field.class_name == "BoolValue" then
		return type(value) == "boolean"
	elseif field.class_name == "IntegerInfinityValue" then
		return type(value) == "number" and (math.isnan(value) or math.isinf(value) or math.floor(value) == value)
	elseif field.class_name == "CodeNumValue" then
		return (code_num_factory or CodeNumValueFactory).is_value(value)
	end
	return false
end

local function encode_field_value(
	field: DataField,
	value: DataValue,
	integer_infinity_factory: typeof(IntegerInfinityValueFactory)?,
	code_num_factory: CodeNumValueFactoryAPI?
): DataValue
	if field.class_name == "IntegerInfinityValue" and type(value) == "number" then
		return normalize_integer_infinity(value, field.rounding or "nearest", integer_infinity_factory)
	elseif field.class_name == "CodeNumValue" then
		return (code_num_factory or CodeNumValueFactory).normalize(value)
	end
	return value
end

local function normalize_serialized_code_num(
    factory: CodeNumValueFactoryAPI,
    value: string
): string?
    local normalizer = factory.normalize_serialized
    if normalizer ~= nil then
        local normalized = normalizer(value)
        return if type(normalized) == "string" then normalized else nil
    end
    if not factory.is_serialized(value) then
        return nil
    end
    return factory.normalize(value)
end

local function decode_stored_field_value(
	field: DataField,
	value: DataValue?,
	integer_infinity_factory: typeof(IntegerInfinityValueFactory)?,
	code_num_factory: CodeNumValueFactoryAPI?
): (DataValue?, boolean)
	if field.class_name == "CodeNumValue" then
		local factory = code_num_factory or CodeNumValueFactory
		if type(value) ~= "string" then return nil, false end
		local normalized = normalize_serialized_code_num(factory, value)
		if normalized == nil then return nil, false end
		return normalized, normalized ~= value
	end
	if field.class_name == "IntegerInfinityValue" then
		if type(value) ~= "number" then return nil, false end
		local normalized = normalize_integer_infinity(value, field.rounding or "nearest", integer_infinity_factory)
		local negative_zero = value == 0 and 1 / value == -math.huge
		return normalized, not numeric_values_equal(normalized, value) or negative_zero
	end
	if field_value_is_valid(field, value) then return value, false end
	return nil, false
end

local function normalize_runtime_field_value(
	field: DataField,
	value: DataValue?,
	integer_infinity_factory: typeof(IntegerInfinityValueFactory)?,
	code_num_factory: CodeNumValueFactoryAPI?
): DataValue?
	if field.class_name == "CodeNumValue" then
		local factory = code_num_factory or CodeNumValueFactory
		if type(value) ~= "string" then return nil end
		return normalize_serialized_code_num(factory, value)
	end
	if field.class_name == "IntegerInfinityValue" then
		if type(value) ~= "number" then return nil end
		return normalize_integer_infinity(value, field.rounding or "nearest", integer_infinity_factory)
	end
	if field_value_is_valid(field, value) then return value end
	return nil
end

local function encode_player_data(
	data: PlayerData,
	integer_infinity_factory: typeof(IntegerInfinityValueFactory)?,
	code_num_factory: CodeNumValueFactoryAPI?
): PlayerData
	local result: PlayerData = table.clone(data)

	for key, field in pairs(CONFIG.data) do
		local value = result[key]
		if value ~= nil then
			result[key] = encode_field_value(field, value, integer_infinity_factory, code_num_factory)
		end
	end

	return result
end

for key, field in pairs(CONFIG.data) do
	if field.class_name == "IntegerInfinityValue" then
		local default_value = field.default
		if type(default_value) ~= "number" then
			error(("CONFIG.data.%s.default must be a number for IntegerInfinityValue"):format(key))
		end

		local rounding = resolve_rounding(field.rounding)
		field.rounding = rounding
		field.default = normalize_integer_infinity(default_value, rounding)
	end

	if not field_value_is_valid(field, field.default) then
		error(("CONFIG.data.%s.default is invalid for %s"):format(key, field.class_name))
	end

	if field.class_name == "StringValue"
		and type(field.default) == "string"
		and #field.default > 200_000
	then
		error(("CONFIG.data.%s.default exceeds StringValue's 200000 character limit"):format(key))
	end
end

if CONFIG.leaderstats.enabled and CONFIG.leaderstats.name ~= "leaderstats" then
	error('leaderstats.name must be "leaderstats" when the built-in leaderboard is enabled')
end

local leaderstat_keys: {[string]: boolean} = {}
local leaderstat_names: {[string]: boolean} = {}
local leaderstat_by_key: {[string]: Leaderstat} = {}

for _, leaderstat in ipairs(CONFIG.leaderstats.values) do
	local field = CONFIG.data[leaderstat.key]
	if field == nil then
		error(("leaderstats value %q refers to missing data field"):format(leaderstat.key))
	end
	if leaderstat.name == "" then
		error(("leaderstats value %q must have a non-empty name"):format(leaderstat.key))
	end
	if leaderstat_keys[leaderstat.key] then
		error(("leaderstats value %q is configured more than once"):format(leaderstat.key))
	end
	if leaderstat_names[leaderstat.name] then
		error(("leaderstats name %q is configured more than once"):format(leaderstat.name))
	end

	leaderstat_keys[leaderstat.key] = true
	leaderstat_names[leaderstat.name] = true
	leaderstat_by_key[leaderstat.key] = leaderstat

	if leaderstat.number_format ~= nil then
		if field.class_name ~= "IntValue"
			and field.class_name ~= "NumberValue"
			and field.class_name ~= "IntegerInfinityValue"
			and field.class_name ~= "CodeNumValue"
		then
			error(
				("leaderstats value %q requests number formatting but is not numeric"):format(
					leaderstat.key
				)
			)
		end

		local format_ok, format_error = pcall(function()
			NumberFormatterFactory.format(0, leaderstat.number_format)
		end)
		if not format_ok then
			error(
				("leaderstats value %q has invalid number-format options: %s"):format(
					leaderstat.key,
					tostring(format_error)
				)
			)
		end
	end

	if field.class_name == "BoolValue" then
		warn(
			("[PlayerData] leaderstats %q uses BoolValue; verify PlayerList presentation"):format(
				leaderstat.name
			)
		)
	end
end

local template: PlayerData = {}
for key, field in pairs(CONFIG.data) do
	template[key] = encode_field_value(field, field.default)
end

local function resolve_key(player: Player): string
	return CONFIG.key_prefix .. tostring(player.UserId)
end

local function validate_player_data(
	value: RecordStore.JsonValue,
	code_num_factory: CodeNumValueFactoryAPI?
): (boolean, string?)
	if type(value) ~= "table" then return false, "player data must be an object" end
	for key, item in value do
		if type(key) ~= "string" then return false, "player data keys must be strings" end
		local item_type = type(item)
		if item_type ~= "string" and item_type ~= "number" and item_type ~= "boolean" then
			return false, ("player data.%s has an unsupported type"):format(key)
		end
		local field = CONFIG.data[key]
		if field ~= nil and field.class_name == "CodeNumValue" then
			if item_type ~= "string" or not (code_num_factory or CodeNumValueFactory).is_serialized(item) then
				return false, ("player data.%s must contain a valid serialized CodeNum value"):format(key)
			end
		end
	end
	return true, nil
end

local function normalize_player_data(
	value: RecordStore.JsonValue?,
	integer_infinity_factory: typeof(IntegerInfinityValueFactory)?,
	code_num_factory: CodeNumValueFactoryAPI?
): (PlayerData?, boolean)
	if type(value) ~= "table" then return nil, false end
	local result: PlayerData = {}
	local changed = false
	for key, item in value do
		if type(key) ~= "string" then return nil, false end
		local item_type = type(item)
		if item_type == "number" then result[key] = item
		elseif item_type == "string" or item_type == "boolean" then result[key] = item
		else return nil, false end
	end
	for key, field in pairs(CONFIG.data) do
		local normalized_value, value_changed = decode_stored_field_value(
			field,
			result[key],
			integer_infinity_factory,
			code_num_factory
		)
		if normalized_value == nil then
			result[key] = encode_field_value(field, field.default, integer_infinity_factory, code_num_factory)
			changed = true
		else
			result[key] = normalized_value
			if value_changed then changed = true end
		end
	end
	return result, changed
end

local function should_warn_result(result: RecordStore.ResultCode): boolean
	return result == "locked"
		or result == "busy"
		or result == "fenced"
		or result == "unknown"
		or result == "conflict"
		or result == "validation"
		or result == "migration"
		or result == "future_schema"
		or result == "corrupt"
		or result == "tombstoned"
		or result == "legacy"
		or result == "budget"
		or result == "retry_exhausted"
		or result == "invalid"
		or result == "closing"
end

local function new(dependencies: Dependencies?): Controller
	local injected = dependencies or {}
	local players = injected.Players or Players
	local record_store = injected.RecordStore or RecordStore
	local integer_infinity_value_factory = injected.IntegerInfinityValue or IntegerInfinityValueFactory
	local number_formatter = injected.NumberFormatter or NumberFormatterFactory
	local code_num_value_factory = injected.CodeNumValue or CodeNumValueFactory

	local new_instance = injected.new_instance or function(class_name: string): Instance
		return Instance.new(class_name)
	end
	local scheduler = injected.task or task

	local function new_int_value(): IntValue
		local value = new_instance("IntValue")
		if not value:IsA("IntValue") then
			error("new_instance must return an IntValue for IntValue requests")
		end
		return value
	end

	local function new_number_value(): NumberValue
		local value = new_instance("NumberValue")
		if not value:IsA("NumberValue") then
			error("new_instance must return a NumberValue for NumberValue requests")
		end
		return value
	end

	local function new_string_value(): StringValue
		local value = new_instance("StringValue")
		if not value:IsA("StringValue") then
			error("new_instance must return a StringValue for StringValue requests")
		end
		return value
	end

	local function new_bool_value(): BoolValue
		local value = new_instance("BoolValue")
		if not value:IsA("BoolValue") then
			error("new_instance must return a BoolValue for BoolValue requests")
		end
		return value
	end

	local function new_folder(): Folder
		local folder = new_instance("Folder")
		if not folder:IsA("Folder") then
			error("new_instance must return a Folder for Folder requests")
		end
		return folder
	end

	local function set_load_status(player: Player, status: string)
		pcall(function()
			player:SetAttribute("PlayerDataLoadStatus", status)
		end)
	end

	local function record_is_open(record: PlayerRecord): boolean
		local check_ok, is_open = pcall(function()
			return record:IsOpen()
		end)
		return check_ok and is_open == true
	end

	local function is_retryable_load_result(result: RecordStore.ResultCode, operation: string): boolean
		local check_ok, retryable = pcall(function()
			return record_store.is_retryable_result(result, operation)
		end)
		return check_ok and retryable == true
	end

	local function load_retry_delay(attempt: number): number
		return math.min(CONFIG.load_retry_max_delay, CONFIG.load_retry_base_delay * (2 ^ math.max(0, attempt - 1)))
	end

	local function diagnostic_field(value: unknown): string
		if value == nil then
			return "none"
		end
		local normalized = string.gsub(tostring(value), "%c", " ")
		return string.sub(normalized, 1, 320)
	end

	local function log_load_failure(
		player: Player,
		phase: RecordStore.DiagnosticPhase,
		result: RecordStore.ResultCode,
		attempt_count: number,
		message: string?,
		record: PlayerRecord?
	): string
		local code_ok, returned_code = pcall(function()
			return record_store.get_diagnostic_code(phase, result)
		end)
		local code = if code_ok and type(returned_code) == "string" then returned_code else "RS-LOAD-UNKNOWN"
		local record_state = "unavailable"
		local record_error_summary = "unavailable"

		if record ~= nil then
			local state_ok, state = pcall(function()
				return record:GetState()
			end)
			if state_ok then
				record_state = diagnostic_field(state)
			end

			local error_ok, record_error = pcall(function()
				return record:GetLastError()
			end)
			if error_ok and record_error ~= nil then
				record_error_summary = string.format(
					"code=%s retryable=%s verify=%s outcome=%s operation=%s generation=%s revision=%s message=%s",
					diagnostic_field(record_error.Code),
					diagnostic_field(record_error.Retryable),
					diagnostic_field(record_error.RequiresVerification),
					diagnostic_field(record_error.DurableOutcome),
					diagnostic_field(record_error.OperationId),
					diagnostic_field(record_error.Generation),
					diagnostic_field(record_error.Revision),
					diagnostic_field(record_error.Message)
				)
			elseif error_ok then
				record_error_summary = "none"
			end
		end

		local line_ok, line = pcall(function()
			return string.format(
				"[PlayerData][DataLoadFailure] code=%s phase=%s player=%s "
					.. "userId=%d key=%s result=%s attempts=%d state=%s "
					.. "message=%s recordError={%s}",
				code,
				phase,
				diagnostic_field(player.Name),
				player.UserId,
				diagnostic_field(resolve_key(player)),
				diagnostic_field(result),
				attempt_count,
				record_state,
				diagnostic_field(message),
				record_error_summary
			)
		end)
		if line_ok then
			warn(line)
		else
			warn("[PlayerData][DataLoadFailure] code=" .. code .. " phase=" .. phase .. " result=" .. result)
		end
		return code
	end

	local function make_player_kick_message(
		code: string,
		phase: RecordStore.DiagnosticPhase,
		result: RecordStore.ResultCode
	): string
		if phase == "open" and result == "corrupt" then
			return "Your data could not be loaded. Code: "
				.. code
				.. ". The saved record failed a format check, and automatic history recovery "
				.. "could not confirm a safe prior version. Check server Output for "
				.. "[PlayerData][DataLoadFailure]."
		end
		return "Your data could not be loaded. Code: " .. code
	end

	local started = false
	local shutting_down = false
	local player_added_connection: RBXScriptConnection? = nil
	local player_removing_connection: RBXScriptConnection? = nil
	local sessions: {[Player]: PlayerRecord} = {}
	local player_value_paths: { [Player]: PlayerValuePathCache } = setmetatable({}, { __mode = "k" })
	local loading: {[Player]: boolean} = {}
	local cancelled_loading: {[Player]: boolean} = {}
	local departed_players: {[Player]: boolean} = {}
	local removing: {[Player]: boolean} = {}
	local closing_records: {[PlayerRecord]: boolean} = {}

	local pending_changes: {[PlayerRecord]: {[string]: DataValue}} = {}
	local flush_running: {[PlayerRecord]: boolean} = {}
	local flush_scheduled: {[PlayerRecord]: boolean} = {}
	local recovery_flush_requested: {[PlayerRecord]: boolean} = {}
	local schedule_pending_flush: (PlayerRecord) -> ()
	local request_recovery_flush: (PlayerRecord) -> ()

	local function merge_pending(record: PlayerRecord, changes: {[string]: DataValue})
		local pending = pending_changes[record]
		if pending == nil then
			pending = {}
			pending_changes[record] = pending
		end

		-- Keep the newest observed value if another change arrived while Update was running.
		for key, value in pairs(changes) do
			if pending[key] == nil then
				pending[key] = value
			end
		end
	end

	local function flush_pending_changes(
		record: PlayerRecord,
		deadline: number?
	): (boolean, RecordStore.ResultCode?, string?)
		local end_time = deadline or (os.clock() + CONFIG.operation_deadline)
		while flush_running[record] and os.clock() < end_time do
			scheduler.wait(0.05)
		end
		if flush_running[record] then
			return false, "busy", "timed out waiting for the current PlayerData flush"
		end
		if record.State ~= "active" then
			local pending = pending_changes[record]
			return pending == nil or next(pending) == nil, "fenced", "record is no longer active"
		end

		flush_running[record] = true
		local last_result: RecordStore.ResultCode? = nil
		local last_message: string? = nil

		while record.State == "active" and os.clock() < end_time do
			local pending = pending_changes[record]
			if pending == nil or next(pending) == nil then
				break
			end

			local stats_ok, stats = pcall(function()
				return record:Stats()
			end)
			if not stats_ok then
				last_result = "unknown"
				last_message = tostring(stats)
				break
			end
			if stats.busy ~= 0 then
				scheduler.wait(0.05)
				continue
			end

			local batch = table.clone(pending)
			table.clear(pending)
			local call_ok, result, message = pcall(function()
				return record:Update(function(current)
					if type(current) ~= "table" then
						return nil
					end
					-- RecordStore supplies an isolated copy of its validated active data.
					-- queue_value_change canonicalizes every batched value before it arrives.
					local data = current :: PlayerData
					for key, value in pairs(batch) do
						data[key] = value
					end
					return data
				end)
			end)

			if call_ok and result == "success" then
				continue
			end

			last_result = if call_ok then result else "unknown"
			last_message = if call_ok then message else tostring(result)
			merge_pending(record, batch)
			if last_result ~= "busy" then
				break
			end
			scheduler.wait(0.05)
		end

		flush_running[record] = nil
		if recovery_flush_requested[record] then
			local retained = pending_changes[record]
			if closing_records[record] or retained == nil or next(retained) == nil then
				recovery_flush_requested[record] = nil
			elseif record.State == "active" then
				recovery_flush_requested[record] = nil
				schedule_pending_flush(record)
			end
		end
		local remaining = pending_changes[record]
		if remaining == nil or next(remaining) == nil then
			return true, nil, nil
		end

		if last_result == nil then
			last_result = "busy"
			last_message = "PlayerData flush deadline expired with pending changes"
		end
		if should_warn_result(last_result) then
			warn("[PlayerData]", record.Key, last_result, last_message or "")
		end
		return false, last_result, last_message
	end

	schedule_pending_flush = function(record: PlayerRecord)
		if flush_scheduled[record] or flush_running[record] or closing_records[record] then
			return
		end
		flush_scheduled[record] = true

		scheduler.defer(function()
			flush_scheduled[record] = nil
			local flushed, result, message = flush_pending_changes(record)
			if not flushed and result ~= nil and should_warn_result(result) then
				warn("[PlayerData]", record.Key, result, message or "")
			end
		end)
	end

	request_recovery_flush = function(record: PlayerRecord)
		if closing_records[record] then return end
		if flush_running[record] or flush_scheduled[record] then
			recovery_flush_requested[record] = true
			return
		end
		schedule_pending_flush(record)
	end

	local function queue_value_change(
		record: PlayerRecord,
		key: string,
		value: DataValue,
		already_normalized: boolean?
	)
		if closing_records[record] then
			return
		end

		local field = CONFIG.data[key]
		if field == nil then
			warn("[PlayerData]", record.Key, "rejected an invalid value change", key)
			return
		end

		local normalized_value = if already_normalized == true
			and field.class_name == "CodeNumValue"
			and type(value) == "string"
			then value
			else normalize_runtime_field_value(field, value, integer_infinity_value_factory, code_num_value_factory)
		if normalized_value == nil then
			warn("[PlayerData]", record.Key, "rejected an invalid value change", key)
			return
		end

		local pending = pending_changes[record]
		if pending == nil then
			pending = {}
			pending_changes[record] = pending
		end
		pending[key] = normalized_value
		schedule_pending_flush(record)
	end


	local function assign_backing_value(instance: Instance, value: DataValue)
		if instance:IsA("StringValue") then
			if type(value) ~= "string" then error("expected a string value") end
			(instance :: StringValue).Value = value
		elseif instance:IsA("BoolValue") then
			if type(value) ~= "boolean" then error("expected a boolean value") end
			(instance :: BoolValue).Value = value
		elseif instance:IsA("IntValue") then
			if type(value) ~= "number" then error("expected a numeric value") end
			(instance :: IntValue).Value = value
		elseif instance:IsA("NumberValue") then
			if type(value) ~= "number" then error("expected a numeric value") end
			(instance :: NumberValue).Value = value
		else
			error("configured PlayerData value is not a supported ValueBase instance")
		end
	end

	local function connect_persistent_value(
		record: PlayerRecord,
		key: string,
		instance: Instance,
		initial_value: DataValue
	)
		local field = CONFIG.data[key]
		if field == nil then return end
		local last_valid_value = initial_value
		local restoring = false

		instance.Changed:Connect(function(new_value)
			if restoring then return end
			if record.State ~= "active" or closing_records[record] then
				restoring = true
				local restore_ok, restore_error = pcall(assign_backing_value, instance, last_valid_value)
				restoring = false
				if not restore_ok then
					warn("[PlayerData]", record.Key, "could not restore a rejected value change", key, tostring(restore_error))
				end
				return
			end

			local value_type = type(new_value)
			if value_type ~= "number" and value_type ~= "string" and value_type ~= "boolean" then
				restoring = true
				local restore_ok, restore_error = pcall(assign_backing_value, instance, last_valid_value)
				restoring = false
				if not restore_ok then
					warn("[PlayerData]", record.Key, "could not restore an invalid value change", key, tostring(restore_error))
				end
				return
			end

			local normalized_value = normalize_runtime_field_value(
				field,
				new_value :: DataValue,
				integer_infinity_value_factory,
				code_num_value_factory
			)
			if normalized_value == nil then
				restoring = true
				local restore_ok, restore_error = pcall(assign_backing_value, instance, last_valid_value)
				restoring = false
				if not restore_ok then
					warn("[PlayerData]", record.Key, "could not restore an invalid value change", key, tostring(restore_error))
				end
				return
			end

			last_valid_value = normalized_value
			if normalized_value ~= new_value then
				restoring = true
				local assign_ok, assign_error = pcall(assign_backing_value, instance, normalized_value)
				restoring = false
				if not assign_ok then
					warn("[PlayerData]", record.Key, "could not canonicalize a value change", key, tostring(assign_error))
					return
				end
			end
			queue_value_change(record, key, normalized_value)
		end)
	end

	local function create_codenum_backing_value(
		player: Player,
		record: PlayerRecord,
		key: string,
		initial_value: string
	): StringValue
		local backing_value = code_num_value_factory.new(key, initial_value)
		local last_valid_serialized = initial_value
		local restoring = false
		backing_value.Changed:Connect(function(serialized_value: string)
			if restoring then return end
			local normalized = normalize_serialized_code_num(code_num_value_factory, serialized_value)
			if normalized == nil then
				restoring = true
				backing_value.Value = last_valid_serialized
				restoring = false
				warn("[PlayerData]", player.Name, "rejected invalid CodeNum value for", key)
				return
			end
			if record.State ~= "active" or closing_records[record] then
				restoring = true
				backing_value.Value = last_valid_serialized
				restoring = false
				return
			end
			if normalized ~= serialized_value then
				restoring = true
				backing_value.Value = normalized
				restoring = false
			end
			last_valid_serialized = normalized
			queue_value_change(record, key, normalized, true)
		end)
		return backing_value
	end

	local function create_leaderstats(player: Player, record: PlayerRecord, data: PlayerData)
		if not CONFIG.leaderstats.enabled then
			return
		end

		local existing = player:FindFirstChild(CONFIG.leaderstats.name)
		if existing ~= nil then
			existing:Destroy()
		end

		local has_player_data_values = uses_codenum_values
		for _, definition in ipairs(CONFIG.leaderstats.values) do
			if definition.number_format ~= nil then
				has_player_data_values = true
				break
			end
		end

		local player_data_values: Folder? = nil
		if has_player_data_values then
			local existing_values = player:FindFirstChild("PlayerDataValues")
			if existing_values ~= nil then
				if existing_values:GetAttribute("RecordStoreManaged") ~= true then
					error("PlayerDataValues is reserved for RecordStore-managed formatted or CodeNum values")
				end
				existing_values:Destroy()
			end

			player_data_values = new_folder()
			player_data_values.Name = "PlayerDataValues"
			player_data_values:SetAttribute("RecordStoreManaged", true)
		end

		local leaderstats = new_folder()
		leaderstats.Name = CONFIG.leaderstats.name

		for _, definition in ipairs(CONFIG.leaderstats.values) do
			local field = CONFIG.data[definition.key]
			if field == nil then
				continue
			end

			local stored_value = data[definition.key]
			if field.class_name == "CodeNumValue" then
				if type(stored_value) ~= "string" or not code_num_value_factory.is_serialized(stored_value) then
					continue
				end
			elseif not field_value_is_valid(field, stored_value, code_num_value_factory) then
				continue
			end

			if field.class_name == "CodeNumValue" then
				local value_folder = player_data_values
				if value_folder == nil then error("CodeNum leaderstats require the PlayerDataValues folder") end
				local backing_value = create_codenum_backing_value(player, record, definition.key, stored_value)
				local display_value = new_string_value()
				display_value.Name = definition.name
				display_value.Value = code_num_value_factory.format(stored_value, definition.number_format)
				display_value.Changed:Connect(function()
					local ok, expected = pcall(code_num_value_factory.format, backing_value.Value, definition.number_format)
					if ok and display_value.Value ~= expected then display_value.Value = expected end
				end)
				backing_value.Changed:Connect(function(serialized_value: string)
					if code_num_value_factory.is_serialized(serialized_value) then
						display_value.Value = code_num_value_factory.format(serialized_value, definition.number_format)
					end
				end)
				display_value.Parent = leaderstats
				backing_value.Parent = value_folder
				continue
			end
			local format_options = definition.number_format
			if format_options ~= nil then
				local value_folder = player_data_values
				if value_folder == nil then
					error("formatted leaderstats require the PlayerDataValues folder")
				end

				if type(stored_value) ~= "number" then
					continue
				end

				local backing_value: NumberValue | IntValue
				if field.class_name == "IntValue" then
					local value = new_int_value()
					value.Name = definition.key
					value.Value = stored_value
					backing_value = value
				elseif field.class_name == "NumberValue" then
					local value = new_number_value()
					value.Name = definition.key
					value.Value = stored_value
					backing_value = value
				elseif field.class_name == "IntegerInfinityValue" then
					local value = integer_infinity_value_factory.new(
						definition.key,
						stored_value,
						{ rounding = field.rounding }
					)
					if not value:IsA("NumberValue") then
						error("IntegerInfinityValue factory must return a NumberValue")
					end
					backing_value = value
				else
					continue
				end

				local display_value = new_string_value()
				display_value.Name = definition.name
				display_value.Value = number_formatter.format(stored_value, format_options)
				display_value.Changed:Connect(function()
					local expected = number_formatter.format(backing_value.Value, format_options)
					if display_value.Value ~= expected then
						display_value.Value = expected
					end
				end)

				backing_value.Changed:Connect(function(new_value: number)
					display_value.Value = number_formatter.format(new_value, format_options)
				end)
				connect_persistent_value(record, definition.key, backing_value, stored_value)

				display_value.Parent = leaderstats
				backing_value.Parent = value_folder
				continue
			end

			if field.class_name == "IntValue" then
				if type(stored_value) ~= "number" then
					continue
				end
				local value = new_int_value()
				value.Name = definition.name
				value.Value = stored_value
				connect_persistent_value(record, definition.key, value, stored_value)
				value.Parent = leaderstats

			elseif field.class_name == "NumberValue" then
				if type(stored_value) ~= "number" then
					continue
				end
				local value = new_number_value()
				value.Name = definition.name
				value.Value = stored_value
				connect_persistent_value(record, definition.key, value, stored_value)
				value.Parent = leaderstats

			elseif field.class_name == "IntegerInfinityValue" then
				if type(stored_value) ~= "number" then
					continue
				end
				local value = integer_infinity_value_factory.new(
					definition.name,
					stored_value,
					{ rounding = field.rounding }
				)
				if not value:IsA("NumberValue") then
					error("IntegerInfinityValue factory must return a NumberValue")
				end
				connect_persistent_value(record, definition.key, value, stored_value)
				value.Parent = leaderstats

			elseif field.class_name == "StringValue" then
				if type(stored_value) ~= "string" then
					continue
				end
				local value = new_string_value()
				value.Name = definition.name
				value.Value = stored_value
				connect_persistent_value(record, definition.key, value, stored_value)
				value.Parent = leaderstats

			elseif field.class_name == "BoolValue" then
				if type(stored_value) ~= "boolean" then
					continue
				end
				local value = new_bool_value()
				value.Name = definition.name
				value.Value = stored_value
				connect_persistent_value(record, definition.key, value, stored_value)
				value.Parent = leaderstats
			end
		end

		if player_data_values ~= nil then
			local displayed_codenum_keys: {[string]: boolean} = {}
			for _, definition in ipairs(CONFIG.leaderstats.values) do
				local field = CONFIG.data[definition.key]
				if field ~= nil and field.class_name == "CodeNumValue" then
					displayed_codenum_keys[definition.key] = true
				end
			end

			for key, field in pairs(CONFIG.data) do
				if field.class_name == "CodeNumValue" and not displayed_codenum_keys[key] then
					local stored_value = data[key]
					if type(stored_value) == "string" and code_num_value_factory.is_serialized(stored_value) then
						local backing_value = create_codenum_backing_value(
							player,
							record,
							key,
							stored_value
						)
						backing_value.Parent = player_data_values
					end
				end
			end

			player_data_values.Parent = player
		end
		leaderstats.Parent = player

		local values_by_key: { [string]: Instance } = {}
		for key, field in pairs(CONFIG.data) do
			local definition = leaderstat_by_key[key]
			local value_instance: Instance? = nil
			if field.class_name == "CodeNumValue"
				or (definition ~= nil and definition.number_format ~= nil)
			then
				if player_data_values ~= nil then
					value_instance = player_data_values:FindFirstChild(key)
				end
			elseif definition ~= nil then
				value_instance = leaderstats:FindFirstChild(definition.name)
			end
			if value_instance ~= nil then
				values_by_key[key] = value_instance
			end
		end
		player_value_paths[player] = {
			leaderstats = leaderstats,
			player_data_values = player_data_values,
			values_by_key = values_by_key,
		}
	end

	local function find_cached_player_child(
		player: Player,
		path_key: PlayerValuePathKey,
		root_name: string,
		cache_key: string,
		child_name: string
	): Instance?
		local paths = player_value_paths[player]
		if paths == nil then
			paths = {
				leaderstats = nil,
				player_data_values = nil,
				values_by_key = {},
			}
			player_value_paths[player] = paths
		end

		local root = paths[path_key]
		if root == nil or root.Parent ~= player or root.Name ~= root_name then
			root = player:FindFirstChild(root_name)
			paths[path_key] = root
		end
		if root == nil then
			return nil
		end

		local cached_value = paths.values_by_key[cache_key]
		if cached_value ~= nil and cached_value.Parent == root and cached_value.Name == child_name then
			return cached_value
		end

		local value_instance = root:FindFirstChild(child_name)
		if value_instance ~= nil then
			paths.values_by_key[cache_key] = value_instance
		end
		return value_instance
	end

	local function find_player_value_instance(player: Player, key: string, field: DataField): Instance?
		if not CONFIG.leaderstats.enabled then
			return nil
		end

		local definition = leaderstat_by_key[key]
		if field.class_name == "CodeNumValue"
			or (definition ~= nil and definition.number_format ~= nil)
		then
			return find_cached_player_child(player, "player_data_values", "PlayerDataValues", key, key)
		end

		if definition ~= nil then
			return find_cached_player_child(player, "leaderstats", CONFIG.leaderstats.name, key, definition.name)
		end

		return nil
	end

	local function normalize_set_value(field: DataField, value: unknown): DataValue?
		if field.class_name == "CodeNumValue" then
			local normalize_ok, normalized = pcall(function()
				return code_num_value_factory.normalize(value)
			end)
			if normalize_ok and type(normalized) == "string" then
				return normalized
			end
			return nil
		end

		local value_type = type(value)
		if value_type ~= "number" and value_type ~= "string" and value_type ~= "boolean" then
			return nil
		end
		return normalize_runtime_field_value(
			field,
			value :: DataValue,
			integer_infinity_value_factory,
			code_num_value_factory
		)
	end

	local function assign_player_value(instance: Instance, value: DataValue)
		if instance:IsA("StringValue") then
			if type(value) ~= "string" then error("expected a string value") end
			(instance :: StringValue).Value = value
		elseif instance:IsA("BoolValue") then
			if type(value) ~= "boolean" then error("expected a boolean value") end
			(instance :: BoolValue).Value = value
		elseif instance:IsA("IntValue") then
			if type(value) ~= "number" then error("expected a numeric value") end
			(instance :: IntValue).Value = value
		elseif instance:IsA("NumberValue") then
			if type(value) ~= "number" then error("expected a numeric value") end
			(instance :: NumberValue).Value = value
		else
			error("configured PlayerData value is not a supported ValueBase instance")
		end
	end

	local function set_player_value(player: Player, key: string, value: unknown): (boolean, string?)
		if typeof(player) ~= "Instance" or not player:IsA("Player") then
			return false, "player must be a Player instance"
		end
		if type(key) ~= "string" or key == "" then
			return false, "key must be a non-empty string"
		end

		local field = CONFIG.data[key]
		if field == nil then
			return false, ("unknown PlayerData field %q"):format(key)
		end

		local record = sessions[player]
		if record == nil or record.State ~= "active" then
			return false, "player does not have an active PlayerData session"
		end

		local normalized = normalize_set_value(field, value)
		if normalized == nil then
			return false, ("invalid value for PlayerData field %q"):format(key)
		end

		local requires_instance = CONFIG.leaderstats.enabled
			and (leaderstat_by_key[key] ~= nil or field.class_name == "CodeNumValue")
		if requires_instance then
			local instance = find_player_value_instance(player, key, field)
			if instance == nil then
				return false, ("runtime value instance for PlayerData field %q is missing"):format(key)
			end

			local assign_ok, assign_error = pcall(assign_player_value, instance, normalized)
			if not assign_ok then
				return false, ("could not assign PlayerData field %q: %s"):format(key, tostring(assign_error))
			end
			-- The existing Value.Changed connection updates the coalesced persistence queue
			-- and, for formatted fields, refreshes the display StringValue.
			return true, nil
		end

		-- Non-leaderstat fields have no replicated ValueBase. Queue them directly.
		queue_value_change(record, key, normalized)
		return true, nil
	end

	local function close_record(player: Player, record: PlayerRecord)
		local call_ok, result, message = pcall(function()
			return record:Close()
		end)
		if not call_ok then
			warn("[PlayerData]", player.Name, "record close threw", tostring(result))
			return
		end
		if result ~= "closed" and result ~= "fenced" and result ~= "tombstoned" then
			warn("[PlayerData]", player.Name, result, message or "")
		end
	end

	local function setup_player(player: Player)
		if shutting_down or departed_players[player] or loading[player] or sessions[player] ~= nil then
			return
		end

		loading[player] = true
		set_load_status(player, "Loading")

		local event_record: PlayerRecord? = nil
		local create_ok, record_or_error = pcall(function()
			return record_store.new(CONFIG.store_name, CONFIG.scope, resolve_key(player), {
				schema_version = CONFIG.schema_version,
				autosave_interval = CONFIG.autosave_interval,
				lease_duration = CONFIG.lease_duration,
				lease_renewal = CONFIG.lease_renewal,
				retry_attempts = CONFIG.retry_attempts,
				operation_deadline = CONFIG.operation_deadline,
				shutdown_deadline = CONFIG.shutdown_deadline,
				shutdown_attempts = CONFIG.shutdown_attempts,
				budget_wait = CONFIG.budget_wait,
				user_ids = { player.UserId },
				validator = function(value: RecordStore.JsonValue): (boolean, string?)
					return validate_player_data(value, code_num_value_factory)
				end,
				on_event = function(event, key, result, message)
					if event == "reconcile" and result == "success" then
						local recovered_record = event_record
						if recovered_record ~= nil then
							scheduler.defer(function()
								local pending = pending_changes[recovered_record]
							if pending ~= nil and next(pending) ~= nil then
								request_recovery_flush(recovered_record)
							end
							end)
						end
					end
					if should_warn_result(result) then
						warn("[RecordStore]", event, key, result, message or "")
					end
				end,
			})
		end)
		if not create_ok then
			loading[player] = nil
			cancelled_loading[player] = nil
			if not shutting_down and not departed_players[player] and player.Parent == players then
				local code = log_load_failure(player, "create", "unknown", 0, tostring(record_or_error), nil)
				set_load_status(player, "Failed")
				player:Kick(make_player_kick_message(code, "create", "unknown"))
			end
			return
		end

		local record: PlayerRecord = record_or_error :: PlayerRecord
		event_record = record
		local open_result: RecordStore.ResultCode = "unknown"
		local open_message: string? = nil
		local open_succeeded = false
		local open_attempts = 0
		local open_retry_deadline = os.clock() + CONFIG.load_retry_window

		for attempt = 1, CONFIG.load_retry_attempts do
			open_attempts = attempt
			if shutting_down or cancelled_loading[player] or departed_players[player] or player.Parent ~= players then
				open_result = "closing"
				open_message = "player load was cancelled before record acquisition completed"
				break
			end

			local open_call_ok, returned_result, returned_message = pcall(function()
				return record:Open(template)
			end)
			if open_call_ok then
				open_result = returned_result :: RecordStore.ResultCode
				open_message = returned_message
			else
				open_result = "unknown"
				open_message = tostring(returned_result)
			end

			if record_is_open(record) then
				if open_result ~= "created" and open_result ~= "loaded" then
					open_result = "loaded"
				end
				open_succeeded = true
				break
			end

			if open_result == "created" or open_result == "loaded" then
				open_result = "unknown"
				open_message = "RecordStore reported a loaded result but did not confirm active ownership"
			end

			if not is_retryable_load_result(open_result, "open")
				or attempt >= CONFIG.load_retry_attempts
				or os.clock() >= open_retry_deadline
			then
				break
			end

			local delay = math.min(load_retry_delay(attempt), math.max(0, open_retry_deadline - os.clock()))
			if delay <= 0 then
				break
			end
			set_load_status(player, "Retrying")
			warn("[PlayerData]", player.Name, "record open retry", attempt, open_result, open_message or "")
			scheduler.wait(delay)
		end

		if not open_succeeded then
			local should_kick = not shutting_down and not cancelled_loading[player] and player.Parent == players
			loading[player] = nil
			cancelled_loading[player] = nil
			if should_kick then
				local code = log_load_failure(player, "open", open_result, open_attempts, open_message, record)
				set_load_status(player, "Failed")
				player:Kick(make_player_kick_message(code, "open", open_result))
			else
				set_load_status(player, "Cancelled")
			end
			return
		end

		if shutting_down or cancelled_loading[player] or departed_players[player] or player.Parent ~= players then
			loading[player] = nil
			cancelled_loading[player] = nil
			close_record(player, record)
			set_load_status(player, "Cancelled")
			return
		end

		local normalize_call_ok, normalized_or_error, changed_or_nil = pcall(function()
			return normalize_player_data(record:Get(), integer_infinity_value_factory, code_num_value_factory)
		end)
		local normalized: PlayerData? = if normalize_call_ok then normalized_or_error :: PlayerData? else nil
		local changed = normalize_call_ok and changed_or_nil == true
		local normalization_error = if normalize_call_ok then nil else tostring(normalized_or_error)

		if normalized == nil then
			local should_kick = not shutting_down and not cancelled_loading[player] and player.Parent == players
			loading[player] = nil
			cancelled_loading[player] = nil
			if should_kick then
				local code = log_load_failure(
					player,
					"normalize",
					"validation",
					1,
					normalization_error or "loaded value does not match the configured PlayerData schema",
					record
				)
				set_load_status(player, "Failed")
				close_record(player, record)
				player:Kick(make_player_kick_message(code, "normalize", "validation"))
			else
				close_record(player, record)
			end
			return
		end

		if changed then
			local update_result: RecordStore.ResultCode = "unknown"
			local update_message: string? = nil
			local update_succeeded = false
			local update_attempts = 0
			local update_retry_deadline = os.clock() + CONFIG.load_retry_window

			for attempt = 1, CONFIG.load_retry_attempts do
				update_attempts = attempt
				local update_call_ok, returned_result, returned_message = pcall(function()
					return record:Update(function()
						-- normalized already contains the canonical persisted representation.
				return normalized
					end)
				end)
				if update_call_ok then
					update_result = returned_result :: RecordStore.ResultCode
					update_message = returned_message
				else
					update_result = "unknown"
					update_message = tostring(returned_result)
				end

				if update_result == "success" then
					update_succeeded = true
					break
				end

				if not is_retryable_load_result(update_result, "update")
					or attempt >= CONFIG.load_retry_attempts
					or os.clock() >= update_retry_deadline
				then
					break
				end

				local delay = math.min(load_retry_delay(attempt), math.max(0, update_retry_deadline - os.clock()))
				if delay <= 0 then
					break
				end
				set_load_status(player, "Retrying")
				warn("[PlayerData]", player.Name, "initial data normalization retry", attempt, update_result, update_message or "")
				scheduler.wait(delay)
			end

			if not update_succeeded then
				local should_kick = not shutting_down and not cancelled_loading[player] and player.Parent == players
				loading[player] = nil
				cancelled_loading[player] = nil
				if should_kick then
					local code = log_load_failure(player, "update", update_result, update_attempts, update_message, record)
					set_load_status(player, "Failed")
					close_record(player, record)
					player:Kick(make_player_kick_message(code, "update", update_result))
				else
					close_record(player, record)
				end
				return
			end
		end

		if shutting_down or cancelled_loading[player] or player.Parent ~= players or loading[player] ~= true then
			loading[player] = nil
			cancelled_loading[player] = nil
			close_record(player, record)
			return
		end

		sessions[player] = record
		loading[player] = nil
		cancelled_loading[player] = nil

		local stats_ok, stats_error = pcall(function()
			create_leaderstats(player, record, normalized)
		end)
		if not stats_ok then
			sessions[player] = nil
			closing_records[record] = true
			close_record(player, record)
			closing_records[record] = nil
			set_load_status(player, "Failed")
			warn("[PlayerData]", player.Name, "leaderstats initialization failed", tostring(stats_error))
			if player.Parent == players then
				player:Kick("Your data could not be initialized. Please rejoin.")
			end
			return
		end

		set_load_status(player, "Loaded")
	end

	local function remove_player(player: Player, shared_deadline: number?)
		if removing[player] then
			local duplicate_deadline = shared_deadline or (os.clock() + CONFIG.operation_deadline)
			while removing[player] and os.clock() < duplicate_deadline do
				scheduler.wait(0.05)
			end
			return
		end

		removing[player] = true
		departed_players[player] = true
		if loading[player] then
			cancelled_loading[player] = true
		end

		local record = sessions[player]
		sessions[player] = nil
		player_value_paths[player] = nil
		if record == nil then
			removing[player] = nil
			return
		end

		closing_records[record] = true
		local deadline = shared_deadline or (os.clock() + CONFIG.shutdown_deadline)
		while flush_running[record] and os.clock() < deadline do
			scheduler.wait(0.05)
		end

		if flush_running[record] then
			warn(
				"[PlayerData]",
				player.Name,
				"an active flush exceeded its cleanup deadline; deferring record close until it settles"
			)
			scheduler.spawn(function()
				while flush_running[record] do
					scheduler.wait(0.05)
				end
				local deferred_deadline = os.clock() + CONFIG.operation_deadline
				local deferred_flushed, deferred_result, deferred_message = flush_pending_changes(record, deferred_deadline)
				if not deferred_flushed and deferred_result ~= nil then
					warn(
						"[PlayerData]",
						player.Name,
						"deferred pending changes could not be fully flushed",
						deferred_result,
						deferred_message or ""
					)
				end
				pending_changes[record] = nil
				close_record(player, record)
				closing_records[record] = nil
				removing[player] = nil
			end)
			return
		end

		local flushed, flush_result, flush_message = flush_pending_changes(record, deadline)
		if not flushed and flush_result ~= nil then
			warn("[PlayerData]", player.Name, "pending changes could not be fully flushed", flush_result, flush_message or "")
		end
		pending_changes[record] = nil
		close_record(player, record)
		closing_records[record] = nil
		removing[player] = nil
	end

	local function start(): boolean
		if started or shutting_down then
			return false
		end
		started = true

		player_added_connection = players.PlayerAdded:Connect(function(player)
			if not shutting_down then
				scheduler.spawn(setup_player, player)
			end
		end)
		player_removing_connection = players.PlayerRemoving:Connect(function(player)
			departed_players[player] = true
			scheduler.spawn(remove_player, player)
		end)

		local startup_players = players:GetPlayers()
		for _, player in ipairs(startup_players) do
			scheduler.spawn(setup_player, player)
		end
		return true
	end

	local function shutdown(): boolean
		if shutting_down then
			return false
		end
		shutting_down = true
		started = false

		if player_added_connection ~= nil then
			player_added_connection:Disconnect()
			player_added_connection = nil
		end
		if player_removing_connection ~= nil then
			player_removing_connection:Disconnect()
			player_removing_connection = nil
		end

		for player in pairs(loading) do
			cancelled_loading[player] = true
		end

		local deadline = os.clock() + CONFIG.shutdown_deadline
		local load_wait_deadline = math.min(deadline, os.clock() + CONFIG.operation_deadline)
		while os.clock() < load_wait_deadline do
			local still_loading = false
			for _ in pairs(loading) do
				still_loading = true
				break
			end
			if not still_loading then
				break
			end
			scheduler.wait(0.05)
		end

		local players_to_remove: {Player} = {}
		for player in pairs(sessions) do
			players_to_remove[#players_to_remove + 1] = player
		end
		for _, player in ipairs(players_to_remove) do
			scheduler.spawn(remove_player, player, deadline)
		end

		while os.clock() < deadline do
			local still_removing = false
			for _ in pairs(removing) do
				still_removing = true
				break
			end
			if not still_removing then
				break
			end
			scheduler.wait(0.05)
		end
		return true
	end

	local controller: Controller = {
		Start = function(_self: Controller): boolean
			return start()
		end,
		Shutdown = function(_self: Controller): boolean
			return shutdown()
		end,
		Set = function(player: Player, key: string, value: unknown): (boolean, string?)
			return set_player_value(player, key, value)
		end,
	}

	return controller
end

return table.freeze({
	new = new,
})
