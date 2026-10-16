--!strict
--!optimize 2

-- NumberFormatter
-- Compact display formatting for large finite numbers.
-- Formatting affects display text only; it does not mutate or persist values.

local NumberFormatter = {}

export type Options = {
	decimals: number?,
	trim_trailing_zeros: boolean?,
}

local SUFFIXES: {string} = {
	"K",
	"M",
	"B",
	"T",
	"Qa",
	"Qi",
	"Sx",
	"Sp",
	"Oc",
	"No",
	"Dc",
}

local function resolve_options(options: Options?): (number, boolean)
	if options == nil then
		return 2, true
	end
	if type(options) ~= "table" then
		error("options must be a table", 3)
	end

	local decimals = options.decimals
	if decimals == nil then
		decimals = 2
	elseif type(decimals) ~= "number"
		or not math.isfinite(decimals)
		or math.floor(decimals) ~= decimals
		or decimals < 0
		or decimals > 6
	then
		error("options.decimals must be an integer from 0 through 6", 3)
	end

	local trim_trailing_zeros = options.trim_trailing_zeros
	if trim_trailing_zeros == nil then
		trim_trailing_zeros = true
	elseif type(trim_trailing_zeros) ~= "boolean" then
		error("options.trim_trailing_zeros must be a boolean", 3)
	end

	return decimals, trim_trailing_zeros
end

local function trim_decimal_zeros(value: string): string
	if not string.find(value, "%.") then
		return value
	end

	value = string.gsub(value, "0+$", "")
	return string.gsub(value, "%.$", "")
end

function NumberFormatter.format(value: number, options: Options?): string
	if type(value) ~= "number" then
		error("value must be a number", 2)
	end

	if math.isnan(value) then
		return "NaN"
	elseif value == math.huge then
		return "∞"
	elseif value == -math.huge then
		return "-∞"
	elseif value == 0 then
		return "0"
	end

	local magnitude = math.abs(value)
	if magnitude < 1000 then
		return tostring(value)
	end

	local decimals, trim_trailing_zeros = resolve_options(options)
	local scaled = magnitude
	local suffix_index = 0

	while scaled >= 1000 and suffix_index < #SUFFIXES do
		scaled /= 1000
		suffix_index += 1
	end

	-- Do not emit invalid values such as 1000Dc when the suffix table ends.
	if scaled >= 1000 then
		return string.format("%." .. tostring(decimals) .. "e", value)
	end

	-- Truncate display precision so values below the next threshold are not
	-- prematurely displayed as the next unit.
	local scale = 10 ^ decimals
	local truncated = math.floor(scaled * scale) / scale
	local formatted = string.format("%." .. tostring(decimals) .. "f", truncated)
	if trim_trailing_zeros then
		formatted = trim_decimal_zeros(formatted)
	end

	local sign = if value < 0 then "-" else ""
	return sign .. formatted .. SUFFIXES[suffix_index]
end

return table.freeze(NumberFormatter)
