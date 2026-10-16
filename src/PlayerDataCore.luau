--!strict

-- Hardened lifecycle/persistence core.
-- RecordStore persists non-finite numbers using its versioned envelope encoding.

local Players = game:GetService("Players")

local RecordStore = require(script.Parent.RecordStore)
local IntegerInfinityValueFactory = require(script.Parent.IntegerInfinityValue)

type Scalar = string | number | boolean
type PlayerData = {
	[string]: Scalar,
}

type IntegerInfinityRounding = "nearest" | "floor" | "ceil" | "trunc"
type ValueClass =
	"IntValue"
	| "NumberValue"
	| "StringValue"
	| "BoolValue"
	| "IntegerInfinityValue"

type DataField = {
	class_name: ValueClass,
	default: Scalar,
	rounding: IntegerInfinityRounding?,
}

type Leaderstat = {
	key: string,
	name: string,
}

export type Dependencies = {
	Players: typeof(Players)?,
	RecordStore: typeof(RecordStore)?,
	IntegerInfinityValue: typeof(IntegerInfinityValueFactory)?,
	new_instance: ((string) -> Instance)?,
	task: typeof(task)?,
}

type PlayerRecord = RecordStore.Record

export type Controller = {
	Start: (self: Controller) -> boolean,
	Shutdown: (self: Controller) -> boolean,
}

local function define_data_field(
	class_name: ValueClass,
	default: Scalar,
	rounding: IntegerInfinityRounding?
): DataField
	return {
		class_name = class_name,
		default = default,
		rounding = rounding,
	}
end

local function define_leaderstat(key: string, name: string): Leaderstat
	return {
		key = key,
		name = name,
	}
end

local CONFIG = {
	store_name = "PlayerData_Test1",
	scope = "global",
	key_prefix = "Player_",

	schema_version = 1,

	lease_duration = 120,
	lease_renewal = 40,
	autosave_interval = 60,

	retry_attempts = 5,
	operation_deadline = 10,
	load_retry_attempts = 4,
	load_retry_window = 45,
	load_retry_base_delay = 0.5,
	load_retry_max_delay = 4,
	shutdown_deadline = 25,
	shutdown_attempts = 2,
	budget_wait = 2,

	data = {
		kills = define_data_field("IntValue", 0),
		equipped = define_data_field("StringValue", "Default"),
		admin = define_data_field("BoolValue", false),

		-- Example:
		-- balance = define_data_field("IntegerInfinityValue", 0, "nearest"),
	},

	leaderstats = {
		enabled = true,
		name = "leaderstats",
		values = {
			define_leaderstat("kills", "Kills"),
			define_leaderstat("equipped", "Equipped"),
		},
	},
}

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
	rounding: IntegerInfinityRounding
): number
	if math.isnan(value) then
		return 0
	end

	if math.isinf(value) then
		return value
	end

	if value == 0 then
		return 0
	end

	local result: number
	if rounding == "nearest" then
		result = math.round(value)
	elseif rounding == "floor" then
		result = math.floor(value)
	elseif rounding == "ceil" then
		result = math.ceil(value)
	else
		result = if value < 0 then math.ceil(value) else math.floor(value)
	end

	return if result == 0 then 0 else result
end

local function field_value_is_valid(field: DataField, value: Scalar?): boolean
	if field.class_name == "IntValue" then
		return type(value) == "number"
			and math.isfinite(value)
			and math.floor(value) == value
	elseif field.class_name == "NumberValue" then
		return type(value) == "number"
	elseif field.class_name == "StringValue" then
		return type(value) == "string" and #value <= 200_000
	elseif field.class_name == "BoolValue" then
		return type(value) == "boolean"
	elseif field.class_name == "IntegerInfinityValue" then
		return type(value) == "number"
			and not math.isnan(value)
			and (math.isinf(value) or math.floor(value) == value)
	end

	return false
end

local function encode_field_value(field: DataField, value: Scalar): Scalar
	if field.class_name == "IntegerInfinityValue" and type(value) == "number" then
		return normalize_integer_infinity(value, field.rounding or "nearest")
	end
	return value
end

local function decode_stored_field_value(
	field: DataField,
	value: Scalar?
): (Scalar?, boolean)
	if field.class_name == "IntegerInfinityValue" then
		if type(value) ~= "number" then
			return nil, false
		end

		local normalized = normalize_integer_infinity(
			value,
			field.rounding or "nearest"
		)
		local negative_zero = value == 0 and 1 / value == -math.huge
		return normalized, normalized ~= value or negative_zero or math.isnan(value)
	end

	if field_value_is_valid(field, value) then
		return value, false
	end

	return nil, false
end

local function normalize_runtime_field_value(
	field: DataField,
	value: Scalar?
): Scalar?
	if field.class_name == "IntegerInfinityValue" then
		if type(value) ~= "number" then
			return nil
		end

		return normalize_integer_infinity(
			value,
			field.rounding or "nearest"
		)
	end

	if field_value_is_valid(field, value) then
		return value
	end

	return nil
end

local function encode_player_data(data: PlayerData): PlayerData
	local result: PlayerData = table.clone(data)

	for key, field in pairs(CONFIG.data) do
		local value = result[key]
		if value ~= nil then
			result[key] = encode_field_value(field, value)
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
