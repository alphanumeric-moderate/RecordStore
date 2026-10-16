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
	return CONFIG.key_prefix .. tostring(player.UserId)
end

local function validate_player_data(value: RecordStore.JsonValue): (boolean, string?)
	if type(value) ~= "table" then
		return false, "player data must be an object"
	end

	for key, item in value do
		if type(key) ~= "string" then
			return false, "player data keys must be strings"
		end

		local item_type = type(item)
		if item_type ~= "string" and item_type ~= "number" and item_type ~= "boolean" then
			return false, ("player data.%s must be a string, number, or boolean"):format(key)
		end
	end

	return true, nil
end

local function normalize_player_data(value: RecordStore.JsonValue?): (PlayerData?, boolean)
	if type(value) ~= "table" then
		return nil, false
	end

	local result: PlayerData = {}
	local changed = false

	for key, item in value do
		if type(key) ~= "string" then
			return nil, false
		end

		local item_type = type(item)
		if item_type == "number" then
			result[key] = item
		elseif item_type == "string" or item_type == "boolean" then
			result[key] = item
		else
			return nil, false
		end
	end

	for key, field in pairs(CONFIG.data) do
		local normalized_value, value_changed = decode_stored_field_value(field, result[key])
		if normalized_value == nil then
			result[key] = field.default
			changed = true
		else
			result[key] = normalized_value
			if value_changed then
				changed = true
			end
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
	local loading: {[Player]: boolean} = {}
	local cancelled_loading: {[Player]: boolean} = {}
	local departed_players: {[Player]: boolean} = {}
	local removing: {[Player]: boolean} = {}
	local closing_records: {[PlayerRecord]: boolean} = {}

	local pending_changes: {[PlayerRecord]: {[string]: Scalar}} = {}
	local flush_running: {[PlayerRecord]: boolean} = {}
	local flush_scheduled: {[PlayerRecord]: boolean} = {}

	local function merge_pending(record: PlayerRecord, changes: {[string]: Scalar})
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
					local data = normalize_player_data(current)
					if data == nil then
						return nil
					end
					for key, value in pairs(batch) do
						data[key] = value
					end
					return encode_player_data(data)
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

	local function schedule_pending_flush(record: PlayerRecord)
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

	local function queue_value_change(record: PlayerRecord, key: string, value: Scalar)
		if closing_records[record] then
			return
		end

		local field = CONFIG.data[key]
		if field == nil then
			warn("[PlayerData]", record.Key, "rejected an invalid value change", key)
			return
		end

		local normalized_value = normalize_runtime_field_value(field, value)
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

	local function create_leaderstats(player: Player, record: PlayerRecord, data: PlayerData)
		if not CONFIG.leaderstats.enabled then
			return
		end

		local existing = player:FindFirstChild(CONFIG.leaderstats.name)
		if existing ~= nil then
			existing:Destroy()
		end

		local leaderstats = new_folder()
		leaderstats.Name = CONFIG.leaderstats.name

		for _, definition in ipairs(CONFIG.leaderstats.values) do
			local field = CONFIG.data[definition.key]
			if field == nil then
				continue
			end

			local stored_value = data[definition.key]
			if not field_value_is_valid(field, stored_value) then
				continue
			end

			if field.class_name == "IntValue" then
				if type(stored_value) ~= "number" then
					continue
				end
				local value = new_int_value()
				value.Name = definition.name
				value.Value = stored_value
				value.Changed:Connect(function(new_value)
					if record.State == "active" then
						queue_value_change(record, definition.key, new_value)
					end
				end)
				value.Parent = leaderstats

			elseif field.class_name == "NumberValue" then
				if type(stored_value) ~= "number" then
					continue
				end
				local value = new_number_value()
				value.Name = definition.name
				value.Value = stored_value
				value.Changed:Connect(function(new_value)
					if record.State == "active" then
						queue_value_change(record, definition.key, new_value)
					end
				end)
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
				value.Changed:Connect(function(new_value)
					if record.State == "active" then
						queue_value_change(record, definition.key, new_value)
					end
				end)
				value.Parent = leaderstats

			elseif field.class_name == "StringValue" then
				if type(stored_value) ~= "string" then
					continue
				end
				local value = new_string_value()
				value.Name = definition.name
				value.Value = stored_value
				value.Changed:Connect(function(new_value)
					if record.State == "active" then
						queue_value_change(record, definition.key, new_value)
					end
				end)
				value.Parent = leaderstats

			elseif field.class_name == "BoolValue" then
				if type(stored_value) ~= "boolean" then
					continue
				end
				local value = new_bool_value()
				value.Name = definition.name
				value.Value = stored_value
				value.Changed:Connect(function(new_value)
					if record.State == "active" then
						queue_value_change(record, definition.key, new_value)
					end
				end)
				value.Parent = leaderstats
			end
		end

		leaderstats.Parent = player
