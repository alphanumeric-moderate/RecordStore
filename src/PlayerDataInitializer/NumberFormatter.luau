--!strict
--!optimize 2
local NumberFormatter = {}
export type Options = { decimals: number?, trim_trailing_zeros: boolean? }
local SUFFIX_GROUPS = {
	beginning = {
		"K", "M", "B", "T",
	},
	first = {
		"Qa", "Qi", "Sx", "Sp", "Oc", "No",
	},
	second = {
		"Dc", "Ud", "Dd", "Td", "Qad", "Qid",
		"Sxd", "Spd", "Ocd", "Nod",
	},
	third = {
		"Vg", "Uvg", "Dvg", "Tvg", "Qavg", "Qivg",
		"Sxvg", "Spvg", "Ocvg", "Novg",
		"Tg", "Ut", "Dt", "Tt", "Qat", "Qit",
		"Sxt", "Spt", "Oct", "Not",
		"Qag", "Uqag", "Dqag", "Tqag", "Qaqag", "Qiqag",
		"Sxqag", "Spqag", "Ocqag", "Noqag",
		"Qig", "Uqig", "Dqig", "Tqig", "Qaqig", "Qiqig",
		"Sxqig", "Spqig", "Ocqig", "Noqig",
		"Sxg", "Usxg", "Dsxg", "Tsxg", "Qasxg", "Qisxg",
		"Sxsxg", "Spsxg", "Ocsxg", "Nosxg",
		"Spg", "Uspg", "Dspg", "Tspg", "Qaspg", "Qispg",
		"Sxspg", "Spspg", "Ocspg", "Nospg",
		"Ocg", "Uocg", "Docg", "Tocg", "Qaocg", "Qiocg",
		"Sxocg", "Spocg", "Ococg", "Noocg",
		"Nog", "Unog", "Dnog", "Tnog", "Qanog", "Qinog",
		"Sxnog", "Spnog", "Ocnog", "Nonog",
		"Ce",
	},
	mult = {
		"Mi", "Mc", "Na", "Pi", "Fm", "At", "Zp", "Yc",
		"Xo", "Ve", "Me", "Due", "Tre", "Te", "Pt", "He",
		"Hp", "Octi", "En", "Ic",

		"Mei", "Dui", "Tri", "Teti", "Pti", "Hei",
		"Oci", "Eni", "Tra", "TeC", "MTc", "DTc", "TrTc",
		"TeTc", "PeTc", "HTc", "HpT", "OcT", "EnT",

		"TetC", "MTetc", "DTetc", "TrTetc", "TeTetc",
		"PeTetc", "HTetc", "HpTetc", "OcTetc", "EnTetc",
		"PcT", "MPcT", "DPcT", "TPCt", "TePCt", "PePCt",
		"HePCt", "HpPct", "OcPct", "EnPct",

		"HCt", "MHcT", "DHcT", "THCt", "TeHCt", "PeHCt",
		"HeHCt", "HpHct", "OcHct", "EnHct", "HpCt",
		"MHpcT", "DHpcT", "THpCt", "TeHpCt", "PeHpCt",
		"HeHpCt", "HpHpct", "OcHpct", "EnHpct",

		"OCt", "MOcT", "DOcT", "TOCt", "TeOCt", "PeOCt",
		"HeOCt", "HpOct", "OcOct", "EnOct", "Ent", "MEnT",
		"DEnT", "TEnt", "TeEnt", "PeEnt", "HeEnt", "HpEnt",
		"OcEnt", "EnEnt",

		"Hect", "MeHect",
	},
}
local SUFFIXES: {string} = {}
local SEEN_SUFFIXES: {[string]: boolean} = {}
for _, group in {
	SUFFIX_GROUPS.beginning,
	SUFFIX_GROUPS.first,
	SUFFIX_GROUPS.second,
	SUFFIX_GROUPS.third,
	SUFFIX_GROUPS.mult,
	} do
	for _, suffix in group do
		if SEEN_SUFFIXES[suffix] then
			error("duplicate suffix: " .. suffix, 0)
		end
		SEEN_SUFFIXES[suffix] = true
		SUFFIXES[#SUFFIXES + 1] = suffix
	end
end
table.freeze(SUFFIXES)
for _, group in SUFFIX_GROUPS do table.freeze(group) end
table.freeze(SUFFIX_GROUPS)
local function resolve_options(options: Options?): (number, boolean)
	if options == nil then return 2, true end
	if type(options) ~= "table" then error("options must be a table", 3) end
	local decimals = options.decimals
	if decimals == nil then decimals = 2
	elseif type(decimals) ~= "number" or not math.isfinite(decimals) or math.floor(decimals) ~= decimals or decimals < 0 or decimals > 6 then error("options.decimals must be an integer from 0 through 6", 3) end
	local trim = options.trim_trailing_zeros
	if trim == nil then trim = true elseif type(trim) ~= "boolean" then error("options.trim_trailing_zeros must be a boolean", 3) end
	return decimals, trim
end
local function trim_decimal_zeros(value: string): string
	if not string.find(value, "%.") then return value end
	value = string.gsub(value, "0+$", "")
	return string.gsub(value, "%.$", "")
end
local function format_scaled(magnitude: number, suffix: string?, sign: string, decimals: number, trim: boolean): string
	local scale = 10 ^ decimals
	local formatted = string.format("%." .. tostring(decimals) .. "f", math.floor(magnitude * scale) / scale)
	if trim then formatted = trim_decimal_zeros(formatted) end
	return sign .. formatted .. (suffix or "")
end
local function exponent_fallback(sign: string, mantissa: number, exponent: string, decimals: number, trim: boolean): string
	local formatted = string.format("%." .. tostring(decimals) .. "f", mantissa)
	if trim then formatted = trim_decimal_zeros(formatted) end
	if string.sub(exponent, 1, 1) ~= "-" and string.sub(exponent, 1, 1) ~= "+" then exponent = "+" .. exponent end
	return sign .. formatted .. "e" .. exponent
end
local function format_number(value: number, decimals: number, trim: boolean): string
	if math.isnan(value) then return "NaN" elseif value == math.huge then return "∞" elseif value == -math.huge then return "-∞" elseif value == 0 then return "0" end
	local magnitude = math.abs(value)
	if magnitude < 1000 then return tostring(value) end
	local scaled, index = magnitude, 0
	while scaled >= 1000 and index < #SUFFIXES do scaled /= 1000; index += 1 end
	if scaled >= 1000 then
		local exponent = math.floor(math.log10(magnitude))
		return exponent_fallback(value < 0 and "-" or "", magnitude / math.pow(10, exponent), tostring(exponent), decimals, trim)
	end
	return format_scaled(scaled, SUFFIXES[index], value < 0 and "-" or "", decimals, trim)
end

function NumberFormatter.format(value: number, options: Options?): string
	if type(value) ~= "number" then error("value must be a number", 2) end
	local decimals, trim = resolve_options(options)
	return format_number(value, decimals, trim)
end
local function suffix_index_from_exponent(exponent: number): number
	return math.floor(exponent / 3)
end
function NumberFormatter.formatInteger(value: string, options: Options?): string
	if type(value) ~= "string" or not string.match(value, "^[+-]?%d+$") then error("integer value must be a signed decimal integer string", 2) end
	local decimals, trim = resolve_options(options)
	local sign = ""
	if string.sub(value, 1, 1) == "-" then sign, value = "-", string.sub(value, 2) elseif string.sub(value, 1, 1) == "+" then value = string.sub(value, 2) end
	value = string.gsub(value, "^0+", "")
	if value == "" then return "0" end
	if #value <= 3 then return sign .. value end
	local exponent = #value - 1
	local index = suffix_index_from_exponent(exponent)
	if index == 0 then return sign .. value end
	if index > #SUFFIXES then
		local count = math.min(#value, decimals + 1)
		return exponent_fallback(sign, tonumber(string.sub(value, 1, count)) / (10 ^ (count - 1)), tostring(exponent), decimals, trim)
	end
	local whole = exponent % 3 + 1
	local count = math.min(#value, whole + decimals)
	local scaled = tonumber(string.sub(value, 1, count)) / (10 ^ math.max(0, count - whole))
	return format_scaled(scaled, SUFFIXES[index], sign, decimals, trim)
end
function NumberFormatter.formatScientific(sign_value: number, mantissa: number, exponent: string, options: Options?): string
	if type(sign_value) ~= "number"
		or (sign_value ~= -1 and sign_value ~= 1)
		or type(mantissa) ~= "number"
		or not math.isfinite(mantissa)
		or mantissa < 1
		or mantissa >= 10
		or type(exponent) ~= "string"
		or not string.match(exponent, "^[+-]?%d+$")
	then
		error("invalid scientific value", 2)
	end
	local decimals, trim = resolve_options(options)
	local sign = sign_value < 0 and "-" or ""
	local exp = tonumber(exponent)
	if exp ~= nil and math.isfinite(exp) and math.floor(exp) == exp then
		if exp >= 0 and exp <= (#SUFFIXES * 3 + 2) then
			local index = suffix_index_from_exponent(exp)
			local scaled = mantissa * (10 ^ (exp % 3))
			if index == 0 then return format_number(sign_value * scaled, decimals, trim) end
			if index <= #SUFFIXES then return format_scaled(scaled, SUFFIXES[index], sign, decimals, trim) end
		elseif exp < 0 and exp >= -308 then
			local native = sign_value * mantissa * math.pow(10, exp)
			if native ~= 0 and math.isfinite(native) then return format_number(native, decimals, trim) end
		end
	end
	return exponent_fallback(sign, mantissa, exponent, decimals, trim)
end
function NumberFormatter.getSuffixes(): {string}
	return table.clone(SUFFIXES)
end
return table.freeze(NumberFormatter)
