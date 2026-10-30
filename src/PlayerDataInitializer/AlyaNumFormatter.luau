--!nonstrict
--!optimize 2

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Formatter = {}
local cached_api = nil
local DEFAULT_DECIMAL_POINTS = 2

local function resolve_api()
	if cached_api ~= nil then return cached_api end
	local module_script = ReplicatedStorage:FindFirstChild("AlyaNum")
	if module_script == nil or not module_script:IsA("ModuleScript") then
		error("AlyaNumFormatter requires ReplicatedStorage.AlyaNum", 2)
	end
	local ok, loaded = pcall(require, module_script)
	if not ok then error("failed to require AlyaNum: " .. tostring(loaded), 2) end
	if type(loaded) ~= "table"
		or type(loaded.new) ~= "function"
		or type(loaded.fix) ~= "function"
		or type(loaded.toString) ~= "function"
		or type(loaded.fromString) ~= "function"
		or type(loaded.changeDecimalPoints) ~= "function"
	then
		error("ReplicatedStorage.AlyaNum does not expose the required API", 2)
	end
	cached_api = loaded
	return loaded
end

local function is_finite(value)
	return type(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
end

local function special_name(value)
	if type(value) == "number" then
		if value ~= value then return "nan" end
		if value == math.huge then return "+infinity" end
		if value == -math.huge then return "-infinity" end
	elseif type(value) == "string" then
		local name = string.lower((string.gsub(value, "%s", "")))
		if name == "nan" or name == "+nan" or name == "-nan" then return "nan" end
		if name == "inf" or name == "+inf" or name == "infinity" or name == "+infinity" then
			return "+infinity"
		end
		if name == "-inf" or name == "-infinity" then return "-infinity" end
	elseif type(value) == "table" and value.kind == "special" then
		if value.name == "nan" or value.name == "+infinity" or value.name == "-infinity" then
			return value.name
		end
	end
	return nil
end

local function special_text(name)
	if name == "nan" then return "NaN" end
	if name == "+infinity" then return "Infinity" end
	return "-Infinity"
end

local function valid_base(value)
	if type(value) ~= "table" then return false end
	if value.sign ~= -1 and value.sign ~= 0 and value.sign ~= 1 then return false end
	for _, key in ipairs({ "multiplicand", "exponent", "tetrate", "pentate", "hexate", "heptate" }) do
		if not is_finite(value[key]) then return false end
	end
	return value.multiplicand >= 0
		and value.exponent >= 0
		and value.tetrate >= 0
		and value.pentate >= 0
		and value.hexate >= 0
		and value.heptate >= 0
end

local function copy_base(value)
	return {
		sign = value.sign,
		multiplicand = value.multiplicand,
		exponent = value.exponent,
		tetrate = value.tetrate,
		pentate = value.pentate,
		hexate = value.hexate,
		heptate = value.heptate,
	}
end

local function from_pair(mantissa, exponent)
	if not is_finite(mantissa) or not is_finite(exponent) then
		error("AlyaNum mantissa and exponent must be finite", 3)
	end
	local api = resolve_api()
	if mantissa == 0 then return api.new(0) end
	if exponent == 0 then return api.new(mantissa) end
	local magnitude = api.new(math.abs(mantissa))
	local power = api.new(10):pow(api.new(exponent))
	local result = magnitude * power
	return if mantissa < 0 then -result else result
end

local function to_value(value)
	local special = special_name(value)
	if special ~= nil then return { kind = "special", name = special } end
	local api = resolve_api()
	if type(value) == "number" then
		if not is_finite(value) then error("unsupported non-finite number", 3) end
		return api.new(value)
	elseif type(value) == "string" then
		local text = string.gsub(value, "^%s*(.-)%s*$", "%1")
		local pair_mantissa, pair_exponent = string.match(text, "^([+-]?[%d%.]+),([+-]?[%d%.eE]+)$")
		if pair_mantissa ~= nil then
			local mantissa = tonumber(pair_mantissa)
			local exponent = tonumber(pair_exponent)
			if mantissa == nil or exponent == nil or not is_finite(mantissa) or not is_finite(exponent) then
				error("invalid AlyaNum mantissa/exponent string", 3)
			end
			return from_pair(mantissa, exponent)
		end
		local numeric = tonumber(text)
		if numeric ~= nil and is_finite(numeric) then return api.new(numeric) end
		if string.match(text, "^[+-]?[%d%.]+[eE][+-]?%d+$") then
			local ok, parsed = pcall(function() return api.fromScientific(text) end)
			if ok and type(parsed) == "table" then return parsed end
		end
		error("AlyaNum expects a finite number, scientific string, or mantissa/exponent pair", 3)
	elseif type(value) == "table" then
		if value.kind == "special" then
			error("invalid AlyaNum special value", 3)
		end
		if valid_base(value) then
			local ok, parsed = pcall(function() return api.fix(copy_base(value)) end)
			if ok and type(parsed) == "table" then return parsed end
			if not ok then error(tostring(parsed), 3) end
		end
		if type(value.first) == "number" and type(value.second) == "number" then
			return from_pair(value.first, value.second)
		end
		if type(value[1]) == "number" and type(value[2]) == "number" then
			return from_pair(value[1], value[2])
		end
	end
	error("AlyaNum expects a number or AlyaNum-compatible value", 3)
end

local function validate_options(options)
	if options == nil then return DEFAULT_DECIMAL_POINTS, true end
	if type(options) ~= "table" then error("options must be a table", 3) end
	for key in pairs(options) do
		if key ~= "decimals" and key ~= "trim_trailing_zeros" then
			error("unsupported AlyaNum formatting option: " .. tostring(key), 3)
		end
	end
	local decimals = options.decimals
	if decimals == nil then decimals = DEFAULT_DECIMAL_POINTS end
	if type(decimals) ~= "number" or not is_finite(decimals)
		or math.floor(decimals) ~= decimals or decimals < 0 or decimals > 6
	then
		error("options.decimals must be an integer from 0 through 6", 3)
	end
	local trim = options.trim_trailing_zeros
	if trim ~= nil and type(trim) ~= "boolean" then
		error("options.trim_trailing_zeros must be a boolean", 3)
	end
	return decimals, trim ~= false
end

local function pad_fraction(formatted, decimals)
	local prefix, suffix = string.match(formatted, "^([+-]?%d+%.?%d*)(.*)$")
	if prefix == nil then return formatted end
	local numeric = tonumber(prefix)
	if numeric == nil then return formatted end
	return string.format("%." .. tostring(decimals) .. "f", numeric) .. suffix
end

function Formatter.to_value(value)
	return to_value(value)
end

function Formatter.format(value, options)
	local special = special_name(value)
	if special ~= nil then return special_text(special) end
	local decimals, trim = validate_options(options)
	local api = resolve_api()
	local number = to_value(value)
	local previous_decimals = DEFAULT_DECIMAL_POINTS
	api.changeDecimalPoints(decimals)
	local ok, formatted = pcall(function() return api.toString(number) end)
	api.changeDecimalPoints(previous_decimals)
	if not ok then error("AlyaNum formatting failed: " .. tostring(formatted), 2) end

	local coefficient, suffix = string.match(formatted, "^([+-]?[%d%.]+)([%a][%w]*)$")
	if coefficient ~= nil and suffix ~= nil
		and string.lower(string.sub(suffix, 1, 1)) ~= "e"
		and math.abs(tonumber(coefficient) or 0) >= 1000
	then
		local normalized_ok, normalized = pcall(function()
			return api.toString(api.fromString(formatted))
		end)
		if normalized_ok and type(normalized) == "string" then
			formatted = normalized
		end
	end

	if trim == false and decimals > 0 then
		formatted = pad_fraction(formatted, decimals)
	end
	return formatted
end

return table.freeze(Formatter)
