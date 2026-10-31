--!strict
--!optimize 2

local ReplicatedStorage = game:GetService("ReplicatedStorage")

export type Options = {
	decimals: number?,
	trim_trailing_zeros: boolean?,
}

local Formatter = {}
local cached_api: any = nil

local SUFFIXES = {
	"K", "M", "B", "T",
	"Qa", "Qi", "Sx", "Sp", "Oc", "No",
	"Dc", "Ud", "Dd", "Td", "Qad", "Qid", "Sxd", "Spd", "Ocd", "Nod",
	"Vg", "Uvg", "Dvg", "Tvg", "Qavg", "Qivg", "Sxvg", "Spvg", "Ocvg", "Novg",
	"Tg", "Ut", "Dt", "Tt", "Qat", "Qit", "Sxt", "Spt", "Oct", "Not",
	"Qag", "Uqag", "Dqag", "Tqag", "Qaqag", "Qiqag", "Sxqag", "Spqag", "Ocqag", "Noqag",
	"Qig", "Uqig", "Dqig", "Tqig", "Qaqig", "Qiqig", "Sxqig", "Spqig", "Ocqig", "Noqig",
	"Sxg", "Usxg", "Dsxg", "Tsxg", "Qasxg", "Qisxg", "Sxsxg", "Spsxg", "Ocsxg", "Nosxg",
	"Spg", "Uspg", "Dspg", "Tspg", "Qaspg", "Qispg", "Sxspg", "Spspg", "Ocspg", "Nospg",
	"Ocg", "Uocg", "Docg", "Tocg", "Qaocg", "Qiocg", "Sxocg", "Spocg", "Ococg", "Noocg",
	"Nog", "Unog", "Dnog", "Tnog", "Qanog", "Qinog", "Sxnog", "Spnog", "Ocnog", "Nonog",
	"Ce",
	"Mi", "Mc", "Na", "Pi", "Fm", "At", "Zp", "Yc", "Xo", "Ve",
	"Me", "Due", "Tre", "Te", "Pt", "He", "Hp", "Octi", "En", "Ic",
	"Mei", "Dui", "Tri", "Teti", "Pti", "Hei", "Oci", "Eni", "Tra", "TeC",
	"MTc", "DTc", "TrTc", "TeTc", "PeTc", "HTc", "HpT", "OcT", "EnT",
	"TetC", "MTetc", "DTetc", "TrTetc", "TeTetc", "PeTetc", "HTetc", "HpTetc",
	"OcTetc", "EnTetc", "PcT", "MPcT", "DPcT", "TPCt", "TePCt", "PePCt",
	"HePCt", "HpPct", "OcPct", "EnPct", "HCt", "MHcT", "DHcT", "THCt",
	"TeHCt", "PeHCt", "HeHCt", "HpHct", "OcHct", "EnHct", "HpCt",
	"MHpcT", "DHpcT", "THpCt", "TeHpCt", "PeHpCt", "HeHpCt", "HpHpct",
	"OcHpct", "EnHpct", "OCt", "MOcT", "DOcT", "TOCt", "TeOCt", "PeOCt",
	"HeOCt", "HpOct", "OcOct", "EnOct", "Ent", "MEnT", "DEnT", "TEnt",
	"TeEnt", "PeEnt", "HeEnt", "HpEnt", "OcEnt", "EnEnt", "Hect", "MeHect",
}

local function resolve_api(): any
	if cached_api ~= nil then
		return cached_api
	end

	local module_script = ReplicatedStorage:FindFirstChild("CodeNum")
	if module_script == nil or not module_script:IsA("ModuleScript") then
		error("CodeNumFormatter requires ReplicatedStorage.CodeNum", 2)
	end

	local ok, loaded = pcall(require, module_script)
	if not ok then
		error("failed to require CodeNum: " .. tostring(loaded), 2)
	end
	if type(loaded) ~= "table"
		or type(loaded.parse) ~= "function"
		or type(loaded.fromScientific) ~= "function"
		or type(loaded.toNumber) ~= "function"
		or type(loaded.toString) ~= "function"
		or type(loaded.log10) ~= "function"
		or type(loaded.abs) ~= "function"
		or type(loaded.div) ~= "function"
		or type(loaded.sign) ~= "function"
		or type(loaded.isWide) ~= "function"
	then
		error("ReplicatedStorage.CodeNum does not expose the required 0.5 API", 2)
	end

	cached_api = loaded
	return loaded
end

local function finite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

local function resolve_options(options: Options?): (number, boolean)
	if options == nil then
		return 2, true
	end
	if type(options) ~= "table" then
		error("options must be a table", 3)
	end
	for key in pairs(options) do
		if key ~= "decimals" and key ~= "trim_trailing_zeros" then
			error("unsupported CodeNum formatting option: " .. tostring(key), 3)
		end
	end

	local decimals = options.decimals
	if decimals == nil then
		decimals = 2
	end
	if type(decimals) ~= "number" or not finite(decimals)
		or math.floor(decimals) ~= decimals or decimals < 0 or decimals > 6
	then
		error("options.decimals must be an integer from 0 through 6", 3)
	end

	local trim = options.trim_trailing_zeros
	if trim == nil then
		trim = true
	elseif type(trim) ~= "boolean" then
		error("options.trim_trailing_zeros must be a boolean", 3)
	end
	return decimals, trim :: boolean
end

local function trim_decimal_zeros(value: string): string
	if not string.find(value, "%.") then
		return value
	end
	value = string.gsub(value, "0+$", "")
	return string.gsub(value, "%.$", "")
end

local function format_scaled(magnitude: number, suffix: string?, sign: string, decimals: number, trim: boolean): string
	local scale = 10 ^ decimals
	local rounded = math.round(magnitude * scale) / scale
	local formatted = string.format("%." .. tostring(decimals) .. "f", rounded)
	if trim then
		formatted = trim_decimal_zeros(formatted)
	end
	return sign .. formatted .. (suffix or "")
end

local function to_value(value: any): any
	local api = resolve_api()
	if type(value) == "string" then
		if string.sub(value, 1, 4) == "CN1|" then
			return api.decode(value)
		end
		return api.parse(value)
	elseif type(value) == "number" or api.isWide(value) then
		return value
	elseif type(value) == "table" then
		local ok = pcall(api.toString, value)
		if ok then
			return value
		end
	end
	error("CodeNumFormatter expects a native number, CodeNum value, or numeric string", 3)
end

function Formatter.to_value(value: any): any
	return to_value(value)
end

function Formatter.format(value: any, options: Options?): string
	local api = resolve_api()
	local number = to_value(value)
	local decimals, trim = resolve_options(options)

	if type(number) == "number" then
		if number ~= number then
			return "NaN"
		elseif number == math.huge then
			return "Infinity"
		elseif number == -math.huge then
			return "-Infinity"
		elseif number == 0 then
			return "0"
		end
	end

	local sign_value = api.sign(number)
	if sign_value == nil then
		return "NaN"
	elseif sign_value == 0 then
		return "0"
	end

	local sign = if sign_value < 0 then "-" else ""
	local magnitude = api.abs(number)
	local logarithm = api.log10(magnitude)
	if not finite(logarithm) then
		return api.toString(number)
	end

	if logarithm <= -(decimals + 1) then
		return api.toString(number)
	end

	local exponent = math.floor(logarithm)
	local suffix_index = if exponent >= 3 then math.floor(exponent / 3) else 0
	if suffix_index > #SUFFIXES then
		return api.toString(number)
	end

	local scaled: number
	if suffix_index == 0 then
		scaled = api.toNumber(magnitude)
	else
		local scale_exponent = suffix_index * 3
		local scale_value = api.fromScientific(1, scale_exponent)
		scaled = api.toNumber(api.div(magnitude, scale_value))
	end

	if not finite(scaled) then
		return api.toString(number)
	end

	local factor = 10 ^ decimals
	local rounded = math.round(scaled * factor) / factor
	if rounded >= 1000 and suffix_index < #SUFFIXES then
		rounded /= 1000
		suffix_index += 1
	end

	local suffix = if suffix_index > 0 then SUFFIXES[suffix_index] else nil
	return format_scaled(rounded, suffix, sign, decimals, trim)
end

function Formatter.getSuffixes(): {string}
	return table.clone(SUFFIXES)
end

return table.freeze(Formatter)
