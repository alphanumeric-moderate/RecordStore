--!strict
--!optimize 2

local Players = game:GetService("Players")

local RecordStore = require(script.Parent.RecordStore)
local IntegerInfinityValueFactory = require(script.Parent.IntegerInfinityValue)

type Scalar = string | number | boolean
type DataValue = Scalar
type PlayerData = {
	[string]: DataValue,
}

type IntegerInfinityRounding = "nearest" | "floor" | "ceil" | "trunc"
type DataFieldOption = IntegerInfinityRounding | "ResetOnJoin"
type ValueClass =
	"IntValue"
	| "NumberValue"
	| "StringValue"
	| "BoolValue"
	| "IntegerInfinityValue"
	| "AlyaNumValue"

type DataField = {
	class_name: ValueClass,
	default: DataValue,
	rounding: IntegerInfinityRounding?,
	reset_on_join: boolean,
}

type NumberFormatOptions = {
	decimals: number?,
	trim_trailing_zeros: boolean?,
}

type AlyaNumFormatterAPI = {
	format: (value: number, options: NumberFormatOptions?) -> string,
}

type Leaderstat = {
	key: string,
	name: string,
	number_format: NumberFormatOptions?,
}

type AlyaNumValueNode = { kind: string }
type AlyaNumValueFactoryAPI = {
	is_value: (value: unknown) -> boolean,
	normalize: (value: unknown) -> string,
	is_serialized: (value: unknown) -> boolean,
	format: (value: unknown, options: NumberFormatOptions?) -> string,
	new: (name: string, initial_value: unknown) -> StringValue,
	normalize_serialized: ((value: unknown) -> (string?, AlyaNumValueNode?))?,
	is_unsupported_version: ((value: unknown) -> boolean)?,
}

local cached_alyanum_value_factory: AlyaNumValueFactoryAPI? = nil

local function get_alyanum_value_factory(): AlyaNumValueFactoryAPI
	if cached_alyanum_value_factory == nil then
		cached_alyanum_value_factory = require(script.Parent.AlyaNumValue) :: AlyaNumValueFactoryAPI
	end
	return cached_alyanum_value_factory :: AlyaNumValueFactoryAPI
end

local AlyaNumValueFactory: AlyaNumValueFactoryAPI = table.freeze({
	is_value = function(value: unknown): boolean
		return get_alyanum_value_factory().is_value(value)
	end,
	normalize = function(value: unknown): string
		return get_alyanum_value_factory().normalize(value)
	end,
	is_serialized = function(value: unknown): boolean
		return get_alyanum_value_factory().is_serialized(value)
	end,
	format = function(value: unknown, options: NumberFormatOptions?): string
		return get_alyanum_value_factory().format(value, options)
	end,
	new = function(name: string, initial_value: unknown): StringValue
		return get_alyanum_value_factory().new(name, initial_value)
	end,
	is_unsupported_version = function(value: unknown): boolean
		local check = get_alyanum_value_factory().is_unsupported_version
		return if check ~= nil then check(value) else false
	end,
	normalize_serialized = function(value: unknown): (string?, AlyaNumValueNode?)
		local factory = get_alyanum_value_factory()
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

local cached_alyanum_formatter: AlyaNumFormatterAPI? = nil

local function get_alyanum_formatter(): AlyaNumFormatterAPI
	if cached_alyanum_formatter ~= nil then
		return cached_alyanum_formatter
	end

	local ok, loaded = pcall(require, script.Parent.AlyaNumFormatter)
	if not ok then
		error("failed to require AlyaNumFormatter: " .. tostring(loaded), 2)
	end
	if type(loaded) ~= "table" or type(loaded.format) ~= "function" then
		error("PlayerDataInitializer.AlyaNumFormatter must expose format", 2)
	end

	local formatter = loaded :: AlyaNumFormatterAPI
	cached_alyanum_formatter = formatter
	return formatter
end


type DurabilityMode = "balanced" | "durability_first" | "read_only_on_risk"
export type QueueMessageHandler = (
	player: Player,
	message_type: string,
	payload: RecordStore.JsonValue?,
	attempts: number,
	message_id: string,
	sender_job_id: string,
	created_at: number,
	context: unknown?
) -> (boolean, string?)

export type Dependencies = {
	Players: typeof(Players)?,
	RecordStore: typeof(RecordStore)?,
	IntegerInfinityValue: typeof(IntegerInfinityValueFactory)?,
	AlyaNumValue: AlyaNumValueFactoryAPI?,
	AlyaNumFormatter: AlyaNumFormatterAPI?,
	new_instance: ((string) -> Instance)?,
	task: typeof(task)?,
	DurabilityMode: DurabilityMode?,
	MaxDirtyAgeSeconds: number?,
	LeaseRecoveryEnabled: boolean?,
	MessagingEnabled: boolean?,
	TakeoverEnabled: boolean?,
	DurableQueueEnabled: boolean?,
	TransactionalOperationsEnabled: boolean?,
	MailboxWakeupsEnabled: boolean?,
	MemoryStoreAccelerationHintsEnabled: boolean?,
	QueueMessageHandler: QueueMessageHandler?,
	RecordStoreV2: any?,
	RecordStoreV2Acceleration: any?,
	MessagingService: any?,
	MemoryStoreService: any?,
	HttpService: any?,
	ServerId: string?,
}

type PlayerRecord = RecordStore.Record

type PlayerValuePathCache = {
	leaderstats: Instance?,
	player_data_values: Instance?,
	values_by_key: { [string]: Instance? },
}
type PlayerValuePathKey = "leaderstats" | "player_data_values"

export type PlayerDataStatus = {
	state: RecordStore.SessionState,
	pending_change_count: number,
	pending_age_seconds: number?,
	flush_running: boolean,
	dirty: boolean?,
	mutation_admission: string?,
	dirty_age_slo_exceeded: boolean?,
	ownership: string?,
	last_error_code: string?,
	last_error_retryable: boolean?,
	last_error_requires_verification: boolean?,
}

export type Controller = {
	Start: (self: Controller) -> boolean,
	Shutdown: (self: Controller) -> boolean,
	Set: (player: Player, key: string, value: unknown) -> (boolean, string?),
	GetStatus: (player: Player) -> (PlayerDataStatus?, string?),
	Transact: (
		player: Player,
		operation_id: string,
		request: RecordStore.JsonValue,
		reducer: RecordStore.TransactionReducer,
		receipt_retention_seconds: number?
	) -> (RecordStore.JsonValue?, RecordStore.TransactionStatus, string?),
	GetTransactionStatus: (
		player: Player,
		operation_id: string,
		request: RecordStore.JsonValue
	) -> RecordStore.TransactionReceiptStatus,
}

local function define_data_field(
	class_name: ValueClass,
	default: DataValue,
	option: DataFieldOption?
): DataField
	local rounding: IntegerInfinityRounding? = nil
	local reset_on_join = false

	if option == "ResetOnJoin" then
		reset_on_join = true
	elseif option == "nearest" or option == "floor" or option == "ceil" or option == "trunc" then
		rounding = option :: IntegerInfinityRounding
	elseif option ~= nil then
		error('data field option must be a rounding mode or "ResetOnJoin"', 2)
	end

	return {
		class_name = class_name,
		default = default,
		rounding = rounding,
		reset_on_join = reset_on_join,
	}
end

local function define_leaderstat(
	key: string,
	name: string,
	number_format: NumberFormatOptions?
): Leaderstat
	return {
		key = key,
		name = name,
		number_format = number_format,
	}
end

local function validate_number_format_options(options: NumberFormatOptions)
	if type(options) ~= "table" then error("options must be a table", 2) end
	local decimals = options.decimals
	if decimals ~= nil and (
		type(decimals) ~= "number"
		or not math.isfinite(decimals)
		or math.floor(decimals) ~= decimals
		or decimals < 0
		or decimals > 6
	) then error("options.decimals must be an integer from 0 through 6", 2) end
	local trim = options.trim_trailing_zeros
	if trim ~= nil and type(trim) ~= "boolean" then error("options.trim_trailing_zeros must be a boolean", 2) end
end

local CONFIG = {
	store_name = "PlayerData_Test1",
	scope = "global",
	key_prefix = "Player_",

	schema_version = 1,

	lease_duration = 180,
	lease_renewal = 60,
	autosave_interval = 90,

	retry_attempts = 5,
	durability_mode = ("balanced" :: DurabilityMode),
	max_dirty_age_seconds = 180,
	lease_recovery_enabled = false,
	messaging_enabled = true,
	takeover_enabled = true,
	durable_queue_enabled = false,
	transactional_operations_enabled = false,
	advanced_scheduler = {
		enabled = true,
		rollout_percent = 100,
		rollout_salt = "playerdatacore-scheduler-v1",
		algorithm = "drr",
		shadow_algorithm = "weighted",
		shadow_enabled = true,
		shadow_sample_rate = 0.1,
	},
	operation_deadline = 20,
	mailbox_max_messages_per_wake = 4,
	load_retry_attempts = 4,
	load_retry_window = 45,
	load_retry_base_delay = 0.5,
	load_retry_max_delay = 4,
	shutdown_deadline = 25,
	shutdown_attempts = 2,
	budget_wait = 2,

	data = {
		kills = define_data_field("IntegerInfinityValue", 0, "nearest"),
		equipped = define_data_field("StringValue", "Default", "ResetOnJoin"),
		admin = define_data_field("BoolValue", false),

	},

	leaderstats = {
		enabled = true,
		name = "leaderstats",
		values = {
			define_leaderstat("kills", "Kills", { decimals = 2 }),
			define_leaderstat("equipped", "Equipped"),
		},
	},
}

local uses_alyanum_values = false
for _, field in pairs(CONFIG.data) do
	if field.class_name == "AlyaNumValue" then
		uses_alyanum_values = true
		break
	end
end

local function resolve_rounding(value: unknown): IntegerInfinityRounding
	if value == nil or value == "nearest" then
		return "nearest"
	end

	if value == "floor" then return "floor" end
	if value == "ceil" then return "ceil" end
	if value == "trunc" then return "trunc" end

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

local function data_values_equal(left: DataValue?, right: DataValue): boolean
	if type(left) == "number" and type(right) == "number" then
		return numeric_values_equal(left, right)
	end
	return left == right
end

local function field_value_is_valid(
	field: DataField,
	value: DataValue?,
	alyanum_factory: AlyaNumValueFactoryAPI?
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
	elseif field.class_name == "AlyaNumValue" then
		return (alyanum_factory or AlyaNumValueFactory).is_value(value)
	end
	return false
end

local function encode_field_value(
	field: DataField,
	value: DataValue,
	integer_infinity_factory: typeof(IntegerInfinityValueFactory)?,
	alyanum_factory: AlyaNumValueFactoryAPI?
): DataValue
	if field.class_name == "IntegerInfinityValue" and type(value) == "number" then
		return normalize_integer_infinity(value, field.rounding or "nearest", integer_infinity_factory)
	elseif field.class_name == "AlyaNumValue" then
		return (alyanum_factory or AlyaNumValueFactory).normalize(value)
	end
	return value
end

local function normalize_serialized_alyanum(
    factory: AlyaNumValueFactoryAPI,
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
	alyanum_factory: AlyaNumValueFactoryAPI?
): (DataValue?, boolean)
	if field.class_name == "AlyaNumValue" then
		local factory = alyanum_factory or AlyaNumValueFactory
		if type(value) ~= "string" then return nil, false end
		if factory.is_unsupported_version ~= nil and factory.is_unsupported_version(value) then
			error("stored AlyaNumValue uses an unsupported codec version; refusing to overwrite it with a default", 2)
		end
		local normalized = normalize_serialized_alyanum(factory, value)
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
	alyanum_factory: AlyaNumValueFactoryAPI?
): DataValue?
	if field.class_name == "AlyaNumValue" then
		local factory = alyanum_factory or AlyaNumValueFactory
		if type(value) ~= "string" then return nil end
		return normalize_serialized_alyanum(factory, value)
	end
	if field.class_name == "IntegerInfinityValue" then
		if type(value) ~= "number" then return nil end
		return normalize_integer_infinity(value, field.rounding or "nearest", integer_infinity_factory)
	end
	if field_value_is_valid(field, value) then return value end
	return nil
end

local function _encode_player_data(
	data: PlayerData,
	integer_infinity_factory: typeof(IntegerInfinityValueFactory)?,
	alyanum_factory: AlyaNumValueFactoryAPI?
): PlayerData
	local result: PlayerData = table.clone(data)

	for key, field in pairs(CONFIG.data) do
		local value = result[key]
		if value ~= nil then
			result[key] = encode_field_value(field, value, integer_infinity_factory, alyanum_factory)
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

		local rounding: IntegerInfinityRounding = resolve_rounding(field.rounding)
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
			and field.class_name ~= "AlyaNumValue"
		then
			error(
				("leaderstats value %q requests number formatting but is not numeric"):format(
					leaderstat.key
				)
			)
		end

		local format_ok, format_error = pcall(function()
			validate_number_format_options(leaderstat.number_format :: NumberFormatOptions)
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
	alyanum_factory: AlyaNumValueFactoryAPI?
): (boolean, string?)
	if type(value) ~= "table" then return false, "player data must be an object" end
	for key, item in pairs(value) do
		if type(key) ~= "string" then return false, "player data keys must be strings" end
		local item_type = type(item)
		if item_type ~= "string" and item_type ~= "number" and item_type ~= "boolean" then
			return false, ("player data.%s has an unsupported type"):format(key)
		end
		local field = CONFIG.data[key]
		if field ~= nil and field.class_name == "AlyaNumValue" then
			local factory = alyanum_factory or AlyaNumValueFactory
			local supported = item_type == "string" and factory.is_serialized(item)
			local unsupported = item_type == "string" and factory.is_unsupported_version ~= nil
				and factory.is_unsupported_version(item)
			if not supported and not unsupported then
				return false, ("player data.%s must contain a valid serialized AlyaNum value"):format(key)
			end
		end
	end
	return true, nil
end

local function normalize_player_data(
	value: RecordStore.JsonValue?,
	integer_infinity_factory: typeof(IntegerInfinityValueFactory)?,
	alyanum_factory: AlyaNumValueFactoryAPI?
): (PlayerData?, boolean)
	if type(value) ~= "table" then return nil, false end
	local result: PlayerData = {}
	local changed = false
	for key, item in pairs(value) do
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
			alyanum_factory
		)
		if field.reset_on_join then
			local reset_value = encode_field_value(
				field,
				field.default,
				integer_infinity_factory,
				alyanum_factory
			)
			if normalized_value == nil
				or value_changed
				or not data_values_equal(normalized_value, reset_value)
			then
				changed = true
			end
			result[key] = reset_value
		elseif normalized_value == nil then
			result[key] = encode_field_value(field, field.default, integer_infinity_factory, alyanum_factory)
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
	local injected: Dependencies = dependencies or {}
	local players = injected.Players or Players
	local record_store = injected.RecordStore or RecordStore
	local integer_infinity_value_factory = injected.IntegerInfinityValue or IntegerInfinityValueFactory
	local alyanum_value_factory = injected.AlyaNumValue or AlyaNumValueFactory
	local alyanum_formatter = injected.AlyaNumFormatter
	local durability_mode: DurabilityMode = injected.DurabilityMode or CONFIG.durability_mode
	local max_dirty_age_seconds: number = injected.MaxDirtyAgeSeconds or CONFIG.max_dirty_age_seconds
	local lease_recovery_enabled: boolean = if injected.LeaseRecoveryEnabled ~= nil
		then injected.LeaseRecoveryEnabled else CONFIG.lease_recovery_enabled
	local messaging_enabled: boolean = if injected.MessagingEnabled ~= nil
		then injected.MessagingEnabled else CONFIG.messaging_enabled
	local takeover_enabled: boolean = if injected.TakeoverEnabled ~= nil
		then injected.TakeoverEnabled else CONFIG.takeover_enabled
	local mailbox_wakeups_enabled: boolean = if injected.MailboxWakeupsEnabled ~= nil
		then injected.MailboxWakeupsEnabled else false
	local memory_store_acceleration_hints_enabled: boolean = if injected.MemoryStoreAccelerationHintsEnabled ~= nil
		then injected.MemoryStoreAccelerationHintsEnabled else false
	local queue_message_handler: QueueMessageHandler? = injected.QueueMessageHandler
	local durable_queue_enabled: boolean = if injected.DurableQueueEnabled ~= nil
		then injected.DurableQueueEnabled
		elseif mailbox_wakeups_enabled then true
		else CONFIG.durable_queue_enabled
	local transactional_operations_enabled: boolean = if injected.TransactionalOperationsEnabled ~= nil
		then injected.TransactionalOperationsEnabled else CONFIG.transactional_operations_enabled
	if type(messaging_enabled) ~= "boolean" then
		error("MessagingEnabled must be a boolean")
	end
	if type(takeover_enabled) ~= "boolean" then
		error("TakeoverEnabled must be a boolean")
	end
	if type(durable_queue_enabled) ~= "boolean" then
		error("DurableQueueEnabled must be a boolean")
	end
	if type(mailbox_wakeups_enabled) ~= "boolean" then
		error("MailboxWakeupsEnabled must be a boolean")
	end
	if type(memory_store_acceleration_hints_enabled) ~= "boolean" then
		error("MemoryStoreAccelerationHintsEnabled must be a boolean")
	end
	if queue_message_handler ~= nil and type(queue_message_handler) ~= "function" then
		error("QueueMessageHandler must be a function")
	end
	if mailbox_wakeups_enabled and queue_message_handler == nil then
		error("MailboxWakeupsEnabled requires an application-owned QueueMessageHandler")
	end
	if memory_store_acceleration_hints_enabled and not mailbox_wakeups_enabled then
		error("MemoryStoreAccelerationHintsEnabled requires MailboxWakeupsEnabled")
	end
	if mailbox_wakeups_enabled and not durable_queue_enabled then
		error("MailboxWakeupsEnabled requires DurableQueueEnabled")
	end
	if type(transactional_operations_enabled) ~= "boolean" then
		error("TransactionalOperationsEnabled must be a boolean")
	end
	if durability_mode ~= "balanced"
		and durability_mode ~= "durability_first"
		and durability_mode ~= "read_only_on_risk"
	then
		error("DurabilityMode must be balanced, durability_first, or read_only_on_risk")
	end
	if not math.isfinite(max_dirty_age_seconds)
		or max_dirty_age_seconds <= 0
		or max_dirty_age_seconds > 86400
	then
		error("MaxDirtyAgeSeconds must be positive and no greater than 86400")
	end
	if type(lease_recovery_enabled) ~= "boolean" then
		error("LeaseRecoveryEnabled must be a boolean")
	end

	local function format_native_number(value: number, options: NumberFormatOptions?): string
		local formatter = alyanum_formatter or get_alyanum_formatter()
		return formatter.format(value, options)
	end

	local new_instance: (class_name: string) -> Instance = injected.new_instance or function(class_name: string): Instance
		return Instance.new(class_name)
	end
	local scheduler = injected.task or task

	local function configure_advanced_scheduler(): boolean
		local config = CONFIG.advanced_scheduler
		if not config.enabled then return false end

		local api = record_store :: any
		local get_snapshot = api.get_scheduler_snapshot
		local configure_policy = api.configure_scheduler_policy
		local configure_rollout = api.configure_scheduler_rollout
		local set_enabled = api.set_scheduler_enabled
		if type(get_snapshot) ~= "function"
			or type(configure_policy) ~= "function"
			or type(configure_rollout) ~= "function"
			or type(set_enabled) ~= "function"
		then
			if injected.RecordStore == nil then
				warn("[PlayerData] advanced scheduler APIs are unavailable; retaining RecordStore's default scheduler")
			end
			return false
		end

		local snapshot_ok, snapshot = pcall(get_snapshot)
		if not snapshot_ok or type(snapshot) ~= "table"
			or type(snapshot.policy) ~= "table"
			or type(snapshot.rollout) ~= "table"
		then
			warn("[PlayerData] advanced scheduler state could not be inspected; retaining the current scheduler state")
			return false
		end

		local current_policy = snapshot.policy
		if current_policy.algorithm ~= config.algorithm
			or current_policy.shadow_algorithm ~= config.shadow_algorithm
			or current_policy.shadow_enabled ~= config.shadow_enabled
			or current_policy.shadow_sample_rate ~= config.shadow_sample_rate
		then
			local revision = current_policy.revision
			if type(revision) ~= "number" or not math.isfinite(revision) then
				warn("[PlayerData] advanced scheduler policy revision is invalid")
				return false
			end
			local policy_result: string? = nil
			local policy_message: string? = nil
			local policy_call_ok = pcall(function()
				policy_result, policy_message = configure_policy({
					revision = revision + 1,
					algorithm = config.algorithm,
					shadow_algorithm = config.shadow_algorithm,
					shadow_enabled = config.shadow_enabled,
					shadow_sample_rate = config.shadow_sample_rate,
				})
			end)
			if not policy_call_ok or policy_result ~= "success" then
				warn("[PlayerData] advanced scheduler policy was not applied", policy_message or policy_result or "unknown error")
				return false
			end
		end

		local current_rollout = snapshot.rollout
		if current_rollout.percent ~= config.rollout_percent
			or current_rollout.salt ~= config.rollout_salt
		then
			local revision = current_rollout.revision
			if type(revision) ~= "number" or not math.isfinite(revision) then
				warn("[PlayerData] advanced scheduler rollout revision is invalid")
				return false
			end
			local rollout_result: string? = nil
			local rollout_message: string? = nil
			local rollout_call_ok = pcall(function()
				rollout_result, rollout_message = configure_rollout({
					revision = revision + 1,
					percent = config.rollout_percent,
					salt = config.rollout_salt,
				})
			end)
			if not rollout_call_ok or rollout_result ~= "success" then
				warn("[PlayerData] advanced scheduler rollout was not applied", rollout_message or rollout_result or "unknown error")
				return false
			end
		end

		local enable_call_ok, enabled_result = pcall(set_enabled, true)
		if not enable_call_ok or enabled_result ~= true then
			warn("[PlayerData] advanced scheduler activation failed", enabled_result or "unknown error")
			return false
		end

		local verify_ok, verified = pcall(get_snapshot)
		if not verify_ok or type(verified) ~= "table"
			or verified.enabled ~= true
			or type(verified.policy) ~= "table"
			or verified.policy.algorithm ~= config.algorithm
			or verified.policy.shadow_algorithm ~= config.shadow_algorithm
			or verified.policy.shadow_enabled ~= config.shadow_enabled
			or verified.policy.shadow_sample_rate ~= config.shadow_sample_rate
			or type(verified.rollout) ~= "table"
			or verified.rollout.percent ~= config.rollout_percent
			or verified.rollout.salt ~= config.rollout_salt
			or verified.rollout.cohort_included ~= true
		then
			warn("[PlayerData] advanced scheduler activation or configuration could not be confirmed")
			return false
		end
		return true
	end

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
		local check_ok, retryable = pcall(function(): boolean
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
		local code_ok, returned_code = pcall(function(): string
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
	local player_value_paths = (setmetatable({}, { __mode = "k" }) :: any) :: { [Player]: PlayerValuePathCache }
	local loading: {[Player]: boolean} = {}
	local cancelled_loading: {[Player]: boolean} = {}
	local departed_players: {[Player]: boolean} = {}
	local removing: {[Player]: boolean} = {}
	local closing_records: {[PlayerRecord]: boolean} = {}
	local transaction_sync_targets: {[PlayerRecord]: {[string]: DataValue}} = {}

	local pending_changes: {[PlayerRecord]: {[string]: DataValue}} = {}
	local pending_since: {[PlayerRecord]: number} = {}
	local flush_running: {[PlayerRecord]: boolean} = {}
	local flush_scheduled: {[PlayerRecord]: boolean} = {}
	local recovery_flush_requested: {[PlayerRecord]: boolean} = {}
	local schedule_pending_flush: (PlayerRecord) -> ()
	local request_recovery_flush: (PlayerRecord) -> ()
	local deferred_close_records: {[PlayerRecord]: { player: Player, deadline: number, warned_timeout: boolean? }} = {}
	local deferred_close_running: {[PlayerRecord]: boolean} = {}
	local deferred_close_requested: {[PlayerRecord]: boolean} = {}
	local start_deferred_close: (PlayerRecord) -> ()
	local recordstore_v2: any? = nil
	local wakeup_acceleration: any? = nil
	local wakeup_registrations: {[PlayerRecord]: any} = {}

	local function initialize_mailbox_wakeups()
		if not mailbox_wakeups_enabled then
			return
		end

		local initialized, initialize_error = pcall(function(): boolean
			local v2_factory = injected.RecordStoreV2 or require(script.Parent.RecordStoreV2)
			local acceleration_factory = injected.RecordStoreV2Acceleration
				or require(script.Parent.RecordStoreV2Acceleration)
			local mailbox_module = (record_store :: any).MailboxV2
			if type(v2_factory) ~= "table" or type(v2_factory.new) ~= "function" then
				error("RecordStoreV2 must expose new")
			end
			if type(acceleration_factory) ~= "table" or type(acceleration_factory.new) ~= "function" then
				error("RecordStoreV2Acceleration must expose new")
			end
			if type(mailbox_module) ~= "table" or type(mailbox_module.new) ~= "function" then
				error("RecordStore must expose its embedded MailboxV2 implementation")
			end

			local v2_api = v2_factory.new(record_store, mailbox_module, {
				acceleration_module = acceleration_factory,
			})
			if type(v2_api) ~= "table"
				or type(v2_api.Mailbox) ~= "table"
				or type(v2_api.Mailbox.new) ~= "function"
				or type(v2_api.Canonicalize) ~= "function"
			then
				error("RecordStoreV2 returned an incomplete mailbox wake-up API")
			end
			recordstore_v2 = v2_api

			local messaging_service = injected.MessagingService or game:GetService("MessagingService")
			local http_service = injected.HttpService or game:GetService("HttpService")
			local acceleration_options: {[string]: any} = {
				messaging_service = messaging_service,
				http_service = http_service,
				server_id = injected.ServerId,
				enabled = true,
				enable_memory_store = memory_store_acceleration_hints_enabled,
				task = scheduler,
			}
			if memory_store_acceleration_hints_enabled then
				acceleration_options.memory_store_service = injected.MemoryStoreService
					or game:GetService("MemoryStoreService")
			end

			local acceleration = acceleration_factory.new(acceleration_options)
			local start_call_ok, start_result, start_message = pcall(function()
				return acceleration:Start()
			end)
			if not start_call_ok or start_result ~= true then
				if type(acceleration.Stop) == "function" then
					pcall(function()
						acceleration:Stop()
					end)
				end
				warn("[PlayerData] V2 mailbox acceleration could not start; durable queue polling remains enabled",
					if start_call_ok then tostring(start_message or start_result) else tostring(start_result))
				return false
			end
			wakeup_acceleration = acceleration
			return true
		end)
		if not initialized then
			warn("[PlayerData] V2 mailbox integration initialization failed; durable queue polling remains enabled",
				tostring(initialize_error))
		end
	end

	local function disconnect_mailbox_wakeup(record: PlayerRecord)
		local registration = wakeup_registrations[record]
		if registration == nil then
			return
		end
		wakeup_registrations[record] = nil
		local disconnected, disconnect_error = pcall(function()
			registration:Disconnect()
		end)
		if not disconnected then
			warn("[PlayerData]", record.Key, "could not disconnect its mailbox wake-up registration",
				tostring(disconnect_error))
		end
	end

	local function dispatch_queue_message(
		player: Player,
		record: PlayerRecord,
		message_type: string,
		payload: unknown,
		attempts: number,
		message_id: string,
		sender_job_id: string,
		created_at: number,
		context: unknown?
	): (boolean, string?)
		if shutting_down or departed_players[player] or sessions[player] ~= record
			or closing_records[record] or not record_is_open(record)
		then
			return false, "PlayerData session is no longer active"
		end
		local handler = queue_message_handler
		if handler == nil then
			return false, "QueueMessageHandler is not configured"
		end
		local call_ok, accepted, message = pcall(
			handler,
			player,
			message_type,
			payload :: RecordStore.JsonValue?,
			attempts,
			message_id,
			sender_job_id,
			created_at,
			context
		)
		if not call_ok then
			warn("[PlayerData]", player.Name, "queue message handler raised", tostring(accepted))
			return false, "QueueMessageHandler raised an error"
		end
		if accepted ~= true then
			return false, if type(message) == "string" and message ~= ""
				then message else "QueueMessageHandler rejected the message"
		end
		return true, nil
	end

	local function bind_player_mailbox(player: Player, record: PlayerRecord)
		if not mailbox_wakeups_enabled or recordstore_v2 == nil then
			return
		end
		if sessions[player] ~= record or closing_records[record] or departed_players[player] then
			return
		end

		local adapter_call_ok, store, store_result, store_message = pcall(function()
			return record:CreateMailboxStoreAdapter()
		end)
		if not adapter_call_ok or store == nil then
			warn("[PlayerData]", player.Name, "could not create its V2 mailbox store adapter",
				if adapter_call_ok then tostring(store_message or store_result) else tostring(store))
			return
		end

		local owner_call_ok, owner = pcall(function()
			return record:GetMailboxOwner()
		end)
		if not owner_call_ok or type(owner) ~= "table" then
			warn("[PlayerData]", player.Name, "could not resolve its V2 mailbox owner",
				if owner_call_ok then "invalid mailbox owner" else tostring(owner))
			return
		end

		local mailbox_call_ok, mailbox = pcall(function()
			return recordstore_v2.Mailbox.new(store, owner, {
				active_record = record,
				activation_guard = function(_operation: string)
					local allowed = sessions[player] == record
						and not closing_records[record]
						and not departed_players[player]
						and not shutting_down
						and record_is_open(record)
					return allowed, if allowed then nil else "PlayerData session is not active"
				end,
			})
		end)
		if not mailbox_call_ok or type(mailbox) ~= "table" then
			warn("[PlayerData]", player.Name, "could not construct its V2 mailbox",
				if mailbox_call_ok then "mailbox constructor returned no instance" else tostring(mailbox))
			return
		end

		local bind_call_ok, bind_result, bind_message = pcall(function()
			return record:BindMailboxV2Async(mailbox)
		end)
		if not bind_call_ok or bind_result ~= "success" then
			warn("[PlayerData]", player.Name, "V2 mailbox binding was not confirmed",
				if bind_call_ok then tostring(bind_message or bind_result) else tostring(bind_result))
			return
		end

		if wakeup_acceleration == nil then
			return
		end

		local wakeups_bound_call_ok, wakeups_bound, wakeups_bind_error = pcall(function()
			return mailbox:BindWakeups(wakeup_acceleration)
		end)
		if not wakeups_bound_call_ok or wakeups_bound ~= true then
			warn("[PlayerData]", player.Name, "could not bind the V2 mailbox wake-up adapter",
				if wakeups_bound_call_ok then tostring(wakeups_bind_error) else tostring(wakeups_bound))
			return
		end

		local owner_text_call_ok, owner_text = pcall(function()
			return recordstore_v2.Canonicalize(owner)
		end)
		if not owner_text_call_ok or type(owner_text) ~= "string" then
			warn("[PlayerData]", player.Name, "could not canonicalize its V2 mailbox owner",
				if owner_text_call_ok then "canonical owner identity is invalid" else tostring(owner_text))
			return
		end

		local registration_call_ok, registered, registration_or_error = pcall(function()
			return wakeup_acceleration:Register(owner_text, function()
				if sessions[player] ~= record or closing_records[record]
					or departed_players[player] or shutting_down
				then
					return
				end
				local process_call_ok, process_result, process_message = pcall(function()
					return record:ProcessQueueAsync(CONFIG.mailbox_max_messages_per_wake)
				end)
				if not process_call_ok then
					warn("[PlayerData]", player.Name, "V2 mailbox wake-up processing raised",
						tostring(process_result))
				elseif process_result ~= "processed" and process_result ~= "empty"
					and process_result ~= "busy" and should_warn_result(process_result)
				then
					warn("[PlayerData]", player.Name, "V2 mailbox wake-up processing failed",
						process_result, process_message or "")
				end
			end)
		end)
		if not registration_call_ok or registered ~= true then
			warn("[PlayerData]", player.Name, "V2 mailbox wake-up registration failed",
				if registration_call_ok then tostring(registration_or_error) else tostring(registered))
			return
		end
		if type(registration_or_error) ~= "table"
			or type(registration_or_error.Disconnect) ~= "function"
		then
			warn("[PlayerData]", player.Name, "V2 mailbox wake-up registration returned no disconnect handle")
			return
		end
		wakeup_registrations[record] = registration_or_error
	end

	local function merge_pending(record: PlayerRecord, changes: {[string]: DataValue})
		local pending = pending_changes[record]
		if pending == nil then
			pending = {}
			pending_changes[record] = pending
		end
		if pending_since[record] == nil then
			pending_since[record] = os.clock()
		end

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
			local empty = pending == nil or next(pending) == nil
			if empty then
				pending_changes[record] = nil
				pending_since[record] = nil
			end
			return empty, "fenced", "record is no longer active"
		end

		flush_running[record] = true
		local last_result: RecordStore.ResultCode? = nil
		local last_message: string? = nil
		local drained_read_only_snapshot = false

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

			if durability_mode == "read_only_on_risk" then
				local status_ok, status = pcall(function()
					return record:GetDurabilityStatus()
				end)
				if not status_ok or type(status) ~= "table" then
					last_result = "unknown"
					last_message = "could not verify persistence state before flushing accepted PlayerData changes"
					break
				end
				if status.mutation_admission == "read_only" and status.dirty == true then
					if drained_read_only_snapshot then
						last_result = "capacity"
						last_message = "Record remains dirty after the bounded drain save; accepted PlayerData changes remain queued"
						break
					end
					local save_ok, save_result, save_message = pcall(function()
						return record:Save("playerdata-buffer-drain")
					end)
					if not save_ok or save_result ~= "saved" then
						last_result = if save_ok then save_result :: RecordStore.ResultCode else "unknown"
						last_message = if save_ok then save_message else tostring(save_result)
						if save_ok and save_result == "busy" then
							scheduler.wait(0.05)
							continue
						end
						break
					end
					drained_read_only_snapshot = true
					continue
				end
			end

			local batch = table.clone(pending)
			table.clear(pending)
			local call_ok, result, message = pcall(function()
				return record:Update(function(current)
					if type(current) ~= "table" then
						return nil
					end
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

			last_result = if call_ok then result :: RecordStore.ResultCode else "unknown"
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
			pending_changes[record] = nil
			pending_since[record] = nil
			return true, nil, nil
		end

		if last_result == nil then
			last_result = "busy"
			last_message = "PlayerData flush deadline expired with pending changes"
		end
		if should_warn_result(last_result :: RecordStore.ResultCode) then
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
			if not flushed and result ~= nil and should_warn_result(result :: RecordStore.ResultCode) then
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
			and field.class_name == "AlyaNumValue"
			and type(value) == "string"
			then value
			else normalize_runtime_field_value(field, value, integer_infinity_value_factory, alyanum_value_factory)
		if normalized_value == nil then
			warn("[PlayerData]", record.Key, "rejected an invalid value change", key)
			return
		end

		local pending = pending_changes[record]
		if pending == nil then
			pending = {}
			pending_changes[record] = pending
		end
		if pending_since[record] == nil then
			pending_since[record] = os.clock()
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

	local mutation_backpressure_reason: (record: PlayerRecord) -> string?

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
			local sync_targets = transaction_sync_targets[record]
			local expected_sync_value = if sync_targets ~= nil then sync_targets[key] else nil
			if expected_sync_value ~= nil then
				local normalized_sync_value = normalize_runtime_field_value(
					field,
					new_value :: DataValue,
					integer_infinity_value_factory,
					alyanum_value_factory
				)
				if normalized_sync_value ~= nil and data_values_equal(normalized_sync_value, expected_sync_value) then
					last_valid_value = normalized_sync_value
					sync_targets[key] = nil
					if next(sync_targets) == nil then transaction_sync_targets[record] = nil end
					return
				end
				sync_targets[key] = nil
				if next(sync_targets) == nil then transaction_sync_targets[record] = nil end
			end
			if record.State ~= "active" or closing_records[record] then
				restoring = true
				local restore_ok = pcall(assign_backing_value, instance, last_valid_value)
				restoring = false
				if not restore_ok then
					warn("[PlayerData]", record.Key, "could not restore a rejected value change", key, "unknown error")
				end
				return
			end

			local value_type = type(new_value)
			if value_type ~= "number" and value_type ~= "string" and value_type ~= "boolean" then
				restoring = true
				local restore_ok = pcall(assign_backing_value, instance, last_valid_value)
				restoring = false
				if not restore_ok then
					warn("[PlayerData]", record.Key, "could not restore an invalid value change", key, "unknown error")
				end
				return
			end

			local normalized_value = normalize_runtime_field_value(
				field,
				new_value :: DataValue,
				integer_infinity_value_factory,
				alyanum_value_factory
			)
			if normalized_value == nil then
				restoring = true
				local restore_ok = pcall(assign_backing_value, instance, last_valid_value)
				restoring = false
				if not restore_ok then
					warn("[PlayerData]", record.Key, "could not restore an invalid value change", key, "unknown error")
				end
				return
			end
			local backpressure = mutation_backpressure_reason(record)
			if backpressure ~= nil then
				restoring = true
				local restore_ok = pcall(assign_backing_value, instance, last_valid_value)
				restoring = false
				if not restore_ok then
					warn("[PlayerData]", record.Key, "could not restore a backpressured value change", key, "unknown error")
				end
				return
			end

			last_valid_value = normalized_value
			if normalized_value ~= new_value then
				restoring = true
				local assign_ok = pcall(assign_backing_value, instance, normalized_value)
				restoring = false
				if not assign_ok then
					warn("[PlayerData]", record.Key, "could not canonicalize a value change", key, "unknown error")
					return
				end
			end
			queue_value_change(record, key, normalized_value)
		end)
	end

	local function create_alyanum_backing_value(
		player: Player,
		record: PlayerRecord,
		key: string,
		initial_value: string
	): StringValue
		local backing_value = alyanum_value_factory.new(key, initial_value)
		local last_valid_serialized = initial_value
		local restoring = false
		backing_value.Changed:Connect(function(serialized_value: string)
			if restoring then return end
			local sync_targets = transaction_sync_targets[record]
			local expected_sync_value = if sync_targets ~= nil then sync_targets[key] else nil
			if expected_sync_value ~= nil then
				local normalized_sync_value = normalize_serialized_alyanum(alyanum_value_factory, serialized_value)
				if normalized_sync_value ~= nil and normalized_sync_value == expected_sync_value then
					last_valid_serialized = normalized_sync_value
					sync_targets[key] = nil
					if next(sync_targets) == nil then transaction_sync_targets[record] = nil end
					return
				end
				sync_targets[key] = nil
				if next(sync_targets) == nil then transaction_sync_targets[record] = nil end
			end
			local normalized = normalize_serialized_alyanum(alyanum_value_factory, serialized_value)
			if normalized == nil then
				restoring = true
				backing_value.Value = last_valid_serialized
				restoring = false
				warn("[PlayerData]", player.Name, "rejected invalid AlyaNum value for", key)
				return
			end
			if record.State ~= "active" or closing_records[record] then
				restoring = true
				backing_value.Value = last_valid_serialized
				restoring = false
				return
			end
			local backpressure = mutation_backpressure_reason(record)
			if backpressure ~= nil then
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

		local has_player_data_values = uses_alyanum_values
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
					error("PlayerDataValues is reserved for RecordStore-managed formatted or AlyaNum values")
				end
				existing_values:Destroy()
			end

			local values_folder: Folder = new_folder()
			values_folder.Name = "PlayerDataValues"
			values_folder:SetAttribute("RecordStoreManaged", true)
			player_data_values = values_folder
		end

		local leaderstats = new_folder()
		leaderstats.Name = CONFIG.leaderstats.name

		for _, definition in ipairs(CONFIG.leaderstats.values) do
			local field = CONFIG.data[definition.key]
			if field == nil then
				continue
			end

			local stored_value = data[definition.key]
			if field.class_name == "AlyaNumValue" then
				if type(stored_value) ~= "string" or not alyanum_value_factory.is_serialized(stored_value) then
					continue
				end
			elseif not field_value_is_valid(field, stored_value, alyanum_value_factory) then
				continue
			end

			if field.class_name == "AlyaNumValue" then
				local value_folder = player_data_values
				if value_folder == nil then error("AlyaNum leaderstats require the PlayerDataValues folder") end
				local backing_value = create_alyanum_backing_value(player, record, definition.key, stored_value :: string)
				local display_value = new_string_value()
				display_value.Name = definition.name
				display_value.Value = alyanum_value_factory.format(stored_value, definition.number_format)
				display_value.Changed:Connect(function()
					local ok, expected = pcall(function(): string
					return alyanum_value_factory.format(backing_value.Value, definition.number_format)
				end)
					if ok and display_value.Value ~= expected then display_value.Value = expected end
				end)
				backing_value.Changed:Connect(function(serialized_value: string)
					if alyanum_value_factory.is_serialized(serialized_value) then
						display_value.Value = alyanum_value_factory.format(serialized_value, definition.number_format)
					end
				end)
				display_value.Parent = leaderstats
				local backing_instance: Instance = backing_value
				backing_instance.Parent = value_folder
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
				display_value.Value = format_native_number(stored_value, format_options)
				display_value.Changed:Connect(function()
					local expected = format_native_number(backing_value.Value, format_options)
					if display_value.Value ~= expected then
						display_value.Value = expected
					end
				end)

				backing_value:GetPropertyChangedSignal("Value"):Connect(function()
					display_value.Value = format_native_number(backing_value.Value, format_options)
				end)
				connect_persistent_value(record, definition.key, backing_value, stored_value)

				display_value.Parent = leaderstats
				local backing_instance: Instance = backing_value
				backing_instance.Parent = value_folder
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
			local displayed_alyanum_keys: {[string]: boolean} = {}
			for _, definition in ipairs(CONFIG.leaderstats.values) do
				local field = CONFIG.data[definition.key]
				if field ~= nil and field.class_name == "AlyaNumValue" then
					displayed_alyanum_keys[definition.key] = true
				end
			end

			for key, field in pairs(CONFIG.data) do
				if field.class_name == "AlyaNumValue" and not displayed_alyanum_keys[key] then
					local stored_value = data[key]
					if type(stored_value) == "string" and alyanum_value_factory.is_serialized(stored_value) then
						local backing_value = create_alyanum_backing_value(
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

		local values_by_key: { [string]: Instance? } = {}
		for key, field in pairs(CONFIG.data) do
			local definition = leaderstat_by_key[key]
			local value_instance: Instance? = nil
			if field.class_name == "AlyaNumValue"
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
		if field.class_name == "AlyaNumValue"
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
		if field.class_name == "AlyaNumValue" then
			local normalize_ok, normalized = pcall(function(): string
				return alyanum_value_factory.normalize(value)
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
			alyanum_value_factory
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

	mutation_backpressure_reason = function(record: PlayerRecord): string?
		if durability_mode ~= "read_only_on_risk" then
			return nil
		end
		local pending_at = pending_since[record]
		if pending_at ~= nil and os.clock() - pending_at >= max_dirty_age_seconds then
			request_recovery_flush(record)
			return "pending PlayerData changes exceeded MaxDirtyAgeSeconds; mutations are paused"
		end
		local status_ok, status = pcall(function()
			return record:GetDurabilityStatus()
		end)
		if not status_ok or type(status) ~= "table" then
			return "could not verify persistence risk status; mutations are paused"
		end
		if status.mutation_admission == "read_only" or status.dirty_age_slo_exceeded == true then
			return "persistence risk threshold exceeded; mutations are paused"
		end
		return nil
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
		local backpressure = mutation_backpressure_reason(record)
		if backpressure ~= nil then
			return false, backpressure
		end

		local requires_instance = CONFIG.leaderstats.enabled
			and (leaderstat_by_key[key] ~= nil or field.class_name == "AlyaNumValue")
		if requires_instance then
			local instance = find_player_value_instance(player, key, field)
			if instance == nil then
				return false, ("runtime value instance for PlayerData field %q is missing"):format(key)
			end

			local assign_ok = pcall(assign_player_value, instance, normalized)
			if not assign_ok then
				return false, ("could not assign PlayerData field %q: %s"):format(key, "unknown error")
			end
			return true, nil
		end

		queue_value_change(record, key, normalized)
		return true, nil
	end


	local function resolve_session_record(
		player: Player,
		allow_unknown: boolean
	): (PlayerRecord?, string?)
		if typeof(player) ~= "Instance" or not player:IsA("Player") then
			return nil, "player must be a Player instance"
		end
		if player.Parent ~= players or departed_players[player] or removing[player] then
			return nil, "player is leaving or is no longer connected"
		end
		local record = sessions[player]
		if record == nil then
			return nil, "player does not have a loaded PlayerData session"
		end
		if closing_records[record] or deferred_close_records[record] ~= nil then
			return nil, "PlayerData session is closing"
		end
		if record.State == "fenced" or record.State == "closed" or record.State == "corrupt"
			or record.State == "future" or record.State == "tombstoned"
		then
			return nil, "PlayerData session is no longer usable"
		end
		if record.State ~= "active" and not (allow_unknown and record.State == "unknown") then
			return nil, "PlayerData session is not active"
		end
		return record, nil
	end

	local function get_player_status(player: Player): (PlayerDataStatus?, string?)
		local record, session_error = resolve_session_record(player, true)
		if record == nil then
			return nil, session_error
		end

		local durability_ok, durability = pcall(function()
			return record:GetDurabilityStatus()
		end)
		if not durability_ok or type(durability) ~= "table" then
			return nil, "could not inspect PlayerData durability status"
		end

		local pending = pending_changes[record]
		local pending_count = 0
		if pending ~= nil then
			for _ in pairs(pending) do
				pending_count += 1
			end
		end
		local pending_at = pending_since[record]
		local last_error_code: string? = nil
		local last_error_retryable: boolean? = nil
		local last_error_requires_verification: boolean? = nil
		local error_ok, last_error = pcall(function()
			return record:GetLastError()
		end)
		if error_ok and last_error ~= nil then
			last_error_code = if type(last_error.Code) == "string" then last_error.Code else nil
			last_error_retryable = if type(last_error.Retryable) == "boolean" then last_error.Retryable else nil
			last_error_requires_verification = if type(last_error.RequiresVerification) == "boolean"
				then last_error.RequiresVerification else nil
		end

		return {
			state = record.State,
			pending_change_count = pending_count,
			pending_age_seconds = if pending_at ~= nil then math.max(0, os.clock() - pending_at) else nil,
			flush_running = flush_running[record] == true,
			dirty = if type(durability.dirty) == "boolean" then durability.dirty else nil,
			mutation_admission = if type(durability.mutation_admission) == "string"
				then durability.mutation_admission else nil,
			dirty_age_slo_exceeded = if type(durability.dirty_age_slo_exceeded) == "boolean"
				then durability.dirty_age_slo_exceeded else nil,
			ownership = if type(durability.ownership) == "string" then durability.ownership else nil,
			last_error_code = last_error_code,
			last_error_retryable = last_error_retryable,
			last_error_requires_verification = last_error_requires_verification,
		}, nil
	end

	local function normalize_transaction_data(value: RecordStore.JsonValue?): (PlayerData?, string?)
		if type(value) ~= "table" then
			return nil, "transaction reducer must return a PlayerData table"
		end
		local valid, validation_message = validate_player_data(value, alyanum_value_factory)
		if not valid then
			return nil, validation_message or "transaction returned invalid PlayerData"
		end

		local data: PlayerData = table.clone(value :: PlayerData)
		for key, field in pairs(CONFIG.data) do
			local stored_value = data[key]
			if stored_value == nil then
				return nil, ("transaction cannot remove configured PlayerData field %q"):format(key)
			end
			local normalized = normalize_runtime_field_value(
				field,
				stored_value,
				integer_infinity_value_factory,
				alyanum_value_factory
			)
			if normalized == nil then
				return nil, ("transaction returned an invalid value for PlayerData field %q"):format(key)
			end
			data[key] = encode_field_value(
				field,
				normalized,
				integer_infinity_value_factory,
				alyanum_value_factory
			)
		end
		return data, nil
	end

	local function sync_transaction_values(player: Player, record: PlayerRecord)
		if sessions[player] ~= record or departed_players[player] or removing[player]
			or closing_records[record] or record.State ~= "active"
		then
			return
		end

		local read_ok, raw_data = pcall(function()
			return record:Get()
		end)
		if not read_ok or type(raw_data) ~= "table" then
			warn("[PlayerData]", record.Key, "transaction committed but live values could not be refreshed")
			return
		end

		local data = raw_data :: PlayerData
		local targets: {[string]: DataValue} = {}
		local instances: {[string]: Instance} = {}
		local pending = pending_changes[record]
		for key, field in pairs(CONFIG.data) do
			-- Preserve gameplay edits accepted while the transaction was in flight.
			if pending ~= nil and pending[key] ~= nil then continue end
			local stored_value = data[key]
			local normalized = decode_stored_field_value(
				field,
				stored_value,
				integer_infinity_value_factory,
				alyanum_value_factory
			)
			if normalized == nil then
				warn("[PlayerData]", record.Key, "transaction committed but a configured field could not be decoded", key)
				return
			end
			local instance = find_player_value_instance(player, key, field)
			if instance ~= nil then
				targets[key] = normalized
				instances[key] = instance
			end
		end

		if next(targets) ~= nil then
			transaction_sync_targets[record] = targets
		end
		for key, instance in pairs(instances) do
			local target_value = targets[key]
			if target_value ~= nil then
				local assign_ok = pcall(assign_player_value, instance, target_value)
				if not assign_ok then
					local sync_targets = transaction_sync_targets[record]
					if sync_targets ~= nil then
						sync_targets[key] = nil
						if next(sync_targets) == nil then transaction_sync_targets[record] = nil end
					end
					warn("[PlayerData]", record.Key, "transaction committed but a live value could not be assigned", key)
				end
			end
		end
	end

	local function transact_player(
		player: Player,
		operation_id: string,
		request: RecordStore.JsonValue,
		reducer: RecordStore.TransactionReducer,
		receipt_retention_seconds: number?
	): (RecordStore.JsonValue?, RecordStore.TransactionStatus, string?)
		local record, session_error = resolve_session_record(player, true)
		if record == nil then
			return nil, "fenced", session_error
		end
		if not transactional_operations_enabled then
			return nil, "disabled", "PlayerData transactional operations are disabled"
		end
		if type(operation_id) ~= "string" or operation_id == "" or #operation_id > 256 then
			return nil, "invalid", "operation_id must be 1 to 256 bytes"
		end
		if request == nil then
			return nil, "invalid", "transaction request is required for idempotency"
		end
		if type(reducer) ~= "function" then
			return nil, "invalid", "transaction reducer must be a function"
		end
		if receipt_retention_seconds ~= nil and (
			type(receipt_retention_seconds) ~= "number"
			or not math.isfinite(receipt_retention_seconds)
			or receipt_retention_seconds < 1
			or receipt_retention_seconds > 31_536_000
		) then
			return nil, "invalid", "receipt_retention_seconds must be from 1 to 31536000"
		end

		if record.State == "active" then
			local backpressure = mutation_backpressure_reason(record)
			if backpressure ~= nil then
				return nil, "retryable", backpressure
			end
			local flushed, flush_result, flush_message = flush_pending_changes(record)
			if not flushed then
				local status: RecordStore.TransactionStatus = if flush_result == "unknown" then "unknown"
					elseif flush_result == "fenced" or record.State ~= "active" then "fenced"
					elseif flush_result == "capacity" then "capacity"
					elseif flush_result == "validation" then "validation"
					else "retryable"
				return nil, status, flush_message or "pending PlayerData changes could not be flushed before transaction"
			end
		end

		local guarded_reducer: RecordStore.TransactionReducer = function(current, input)
			if type(current) ~= "table" then
				error("transaction current PlayerData is not a table", 0)
			end
			local next_data, result = reducer(table.clone(current :: PlayerData), input)
			local normalized_data, normalize_error = normalize_transaction_data(next_data)
			if normalized_data == nil then
				error(normalize_error or "transaction returned invalid PlayerData", 0)
			end
			return normalized_data, result
		end
		local transaction_options: RecordStore.TransactionOptions = { request = request }
		if receipt_retention_seconds ~= nil then
			transaction_options.receipt_retention_seconds = receipt_retention_seconds
		end

		local result: RecordStore.JsonValue? = nil
		local transaction_status: RecordStore.TransactionStatus = "unknown"
		local message: string? = nil
		local call_ok = pcall(function()
			result, transaction_status, message = record:TransactAsync(
				operation_id,
				guarded_reducer,
				transaction_options
			)
		end)
		if not call_ok then
			return nil, "unknown", "transaction call raised an error; retry only with the same operation ID and request"
		end
		if transaction_status == "committed" or transaction_status == "duplicate" then
			sync_transaction_values(player, record)
		end
		return result, transaction_status, message
	end

	local function get_transaction_status(
		player: Player,
		operation_id: string,
		request: RecordStore.JsonValue
	): RecordStore.TransactionReceiptStatus
		if not transactional_operations_enabled then
			return { code = "disabled", message = "PlayerData transactional operations are disabled" }
		end
		local record, session_error = resolve_session_record(player, true)
		if record == nil then
			return { code = "invalid", message = session_error }
		end
		if type(operation_id) ~= "string" or operation_id == "" or #operation_id > 256 then
			return { code = "invalid", message = "operation_id must be 1 to 256 bytes" }
		end
		if request == nil then
			return { code = "invalid", message = "transaction request is required for status lookup" }
		end
		local call_ok, status = pcall(function()
			return record:GetTransactionStatusAsync(operation_id, request)
		end)
		if not call_ok or type(status) ~= "table" then
			return { code = "unknown", message = "transaction receipt status could not be read" }
		end
		return status
	end

	local function close_record(player: Player, record: PlayerRecord)
		disconnect_mailbox_wakeup(record)
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

	local function deferred_close_is_terminal(state: string): boolean
		return state == "fenced" or state == "corrupt" or state == "future"
			or state == "closed" or state == "tombstoned"
	end

	local function finish_deferred_close(record: PlayerRecord, discard_pending: boolean, reason: string?)
		local deferred = deferred_close_records[record]
		if deferred == nil then return end
		local pending = pending_changes[record]
		if discard_pending and pending ~= nil and next(pending) ~= nil then
			warn("[PlayerData]", record.Key,
				"queued PlayerData changes cannot be persisted safely after ownership became unavailable",
				tostring(record.State), reason or "")
		end
		pending_changes[record] = nil
		pending_since[record] = nil
		transaction_sync_targets[record] = nil
		deferred_close_records[record] = nil
		deferred_close_requested[record] = nil
		recovery_flush_requested[record] = nil
		if record.State ~= "closed" then
			close_record(deferred.player, record)
		end
		closing_records[record] = nil
		removing[deferred.player] = nil
	end

	start_deferred_close = function(record: PlayerRecord)
		local deferred = deferred_close_records[record]
		if deferred == nil then return end
		if shutting_down and os.clock() >= deferred.deadline then
			if not deferred.warned_timeout then
				warn("[PlayerData]", deferred.player.Name,
					"shutdown deadline expired with unresolved PlayerData changes; retaining the record and queued values rather than issuing an unsafe close")
				deferred.warned_timeout = true
			end
			deferred_close_requested[record] = nil
			removing[deferred.player] = nil
			return
		end
		if deferred_close_running[record] then
			deferred_close_requested[record] = true
			return
		end
		deferred_close_running[record] = true
		scheduler.spawn(function()
			local retry_delay = 0.25
			while deferred_close_records[record] ~= nil do
				deferred = deferred_close_records[record]
				if deferred == nil then break end
				if shutting_down and os.clock() >= deferred.deadline then
					removing[deferred.player] = nil
					break
				end
				local state = record.State
				if state == "unknown" then
					break
				elseif deferred_close_is_terminal(state) then
					finish_deferred_close(record, true, "record entered a terminal non-owned state")
					break
				elseif state ~= "active" then
					if shutting_down and os.clock() >= deferred.deadline then
						break
					end
					scheduler.wait(0.05)
				else
					local pending = pending_changes[record]
					if pending == nil or next(pending) == nil then
						finish_deferred_close(record, false, nil)
						break
					end
					local attempt_deadline = os.clock() + CONFIG.operation_deadline
					if shutting_down then
						attempt_deadline = math.min(attempt_deadline, deferred.deadline)
					end
					if attempt_deadline <= os.clock() then
						break
					end
					local flushed, result, message = flush_pending_changes(record, attempt_deadline)
					local remaining = pending_changes[record]
					if (flushed or remaining == nil or next(remaining) == nil) and record.State == "active" then
						finish_deferred_close(record, false, nil)
						break
					elseif record.State == "unknown" then
						break
					elseif deferred_close_is_terminal(record.State) then
						finish_deferred_close(record, true, message or tostring(result))
						break
					elseif shutting_down and os.clock() >= deferred.deadline then
						break
					else
						scheduler.wait(retry_delay)
						retry_delay = math.min(5, retry_delay * 2)
					end
				end
			end
			deferred_close_running[record] = nil
			deferred = deferred_close_records[record]
			if deferred ~= nil and shutting_down and os.clock() >= deferred.deadline then
				if not deferred.warned_timeout then
					warn("[PlayerData]", deferred.player.Name,
						"shutdown deadline expired with unresolved PlayerData changes; retaining the record and queued values rather than issuing an unsafe close")
					deferred.warned_timeout = true
				end
				removing[deferred.player] = nil
			end
			if deferred ~= nil and deferred_close_requested[record] then
				deferred_close_requested[record] = nil
				if record.State ~= "unknown"
					and not (shutting_down and os.clock() >= deferred.deadline)
				then
					scheduler.defer(function() start_deferred_close(record) end)
				end
			end
		end)
	end

	local function setup_player(player: Player)
		if shutting_down or departed_players[player] or loading[player] or sessions[player] ~= nil then
			return
		end

		loading[player] = true
		set_load_status(player, "Loading")

		local event_record: PlayerRecord? = nil
		local create_ok, record_or_error = pcall(function(): RecordStore.Record
			return record_store.new(CONFIG.store_name, CONFIG.scope, resolve_key(player), {
				schema_version = CONFIG.schema_version,
				autosave_interval = CONFIG.autosave_interval,
				durability_mode = durability_mode,
				max_dirty_age_seconds = max_dirty_age_seconds,
				lease_recovery_enabled = lease_recovery_enabled,
				messaging_enabled = messaging_enabled,
				takeover_enabled = takeover_enabled,
				durable_queue_enabled = durable_queue_enabled,
				transactional_operations_enabled = transactional_operations_enabled,
				on_queue_message = if mailbox_wakeups_enabled then function(
					message_type, payload, attempts, message_id, sender_job_id, created_at
				)
					if event_record == nil then
						return false, "PlayerData Record is not initialized"
					end
					return dispatch_queue_message(
						player, event_record, message_type, payload, attempts,
						message_id, sender_job_id, created_at, nil
					)
				end else nil,
				on_queue_message_async = if mailbox_wakeups_enabled then function(
					message_type, payload, attempts, message_id, sender_job_id, created_at, context
				)
					if event_record == nil then
						return false, "PlayerData Record is not initialized"
					end
					return dispatch_queue_message(
						player, event_record, message_type, payload, attempts,
						message_id, sender_job_id, created_at, context
					)
				end else nil,
				lease_duration = CONFIG.lease_duration,
				lease_renewal = CONFIG.lease_renewal,
				retry_attempts = CONFIG.retry_attempts,
				operation_deadline = CONFIG.operation_deadline,
				shutdown_deadline = CONFIG.shutdown_deadline,
				shutdown_attempts = CONFIG.shutdown_attempts,
				budget_wait = CONFIG.budget_wait,
				user_ids = { player.UserId },
				validator = function(value: RecordStore.JsonValue): (boolean, string?)
					return validate_player_data(value, alyanum_value_factory)
				end,
				on_event = function(event, key, result, message)
					local observed_record = event_record
					if observed_record ~= nil and deferred_close_records[observed_record] ~= nil then
						scheduler.defer(function()
							start_deferred_close(observed_record)
						end)
					elseif event == "reconcile" and result == "success" and observed_record ~= nil then
						scheduler.defer(function()
							request_recovery_flush(observed_record)
						end)
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
			return normalize_player_data(record:Get(), integer_infinity_value_factory, alyanum_value_factory)
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

		bind_player_mailbox(player, record)
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

		disconnect_mailbox_wakeup(record)
		closing_records[record] = true
		local deadline = shared_deadline or (os.clock() + CONFIG.shutdown_deadline)
		while flush_running[record] and os.clock() < deadline do
			scheduler.wait(0.05)
		end

		local flushed, flush_result, flush_message = flush_pending_changes(record, deadline)
		local pending = pending_changes[record]
		if record.State == "active"
			and (flushed or pending == nil or next(pending) == nil)
		then
			pending_changes[record] = nil
			pending_since[record] = nil
			close_record(player, record)
			closing_records[record] = nil
			removing[player] = nil
			return
		end

		if deferred_close_is_terminal(record.State) then
			if pending ~= nil and next(pending) ~= nil then
				warn("[PlayerData]", player.Name,
					"pending changes could not be persisted because record ownership is no longer available",
					tostring(record.State), flush_message or tostring(flush_result))
			end
			pending_changes[record] = nil
			pending_since[record] = nil
			close_record(player, record)
			closing_records[record] = nil
			removing[player] = nil
			return
		end

		if not flushed and flush_result ~= nil then
			warn("[PlayerData]", player.Name,
				"deferring record close until pending PlayerData changes can be flushed",
				flush_result, flush_message or "")
		end
		deferred_close_records[record] = {
			player = player,
			deadline = deadline,
			warned_timeout = false,
		}
		start_deferred_close(record)
	end
	local function start(): boolean
		if started or shutting_down then
			return false
		end
		started = true
		configure_advanced_scheduler()
		initialize_mailbox_wakeups()

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
		for record, deferred in pairs(deferred_close_records) do
			deferred.deadline = deadline
			start_deferred_close(record)
		end
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

		for record in pairs(wakeup_registrations) do
			disconnect_mailbox_wakeup(record)
		end
		if wakeup_acceleration ~= nil then
			local acceleration = wakeup_acceleration
			wakeup_acceleration = nil
			local stop_ok, stop_error = pcall(function()
				acceleration:Stop()
			end)
			if not stop_ok then
				warn("[PlayerData] V2 mailbox acceleration shutdown failed", tostring(stop_error))
			end
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
		GetStatus = function(player: Player): (PlayerDataStatus?, string?)
			return get_player_status(player)
		end,
		Transact = function(
			player: Player,
			operation_id: string,
			request: RecordStore.JsonValue,
			reducer: RecordStore.TransactionReducer,
			receipt_retention_seconds: number?
		): (RecordStore.JsonValue?, RecordStore.TransactionStatus, string?)
			return transact_player(player, operation_id, request, reducer, receipt_retention_seconds)
		end,
		GetTransactionStatus = function(
			player: Player,
			operation_id: string,
			request: RecordStore.JsonValue
		): RecordStore.TransactionReceiptStatus
			return get_transaction_status(player, operation_id, request)
		end,
	}

	return controller
end

return table.freeze({
	new = new,
})
