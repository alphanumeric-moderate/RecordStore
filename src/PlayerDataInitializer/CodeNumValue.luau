--!strict
--!optimize 2

local HttpService = game:GetService("HttpService")

local CodeNumValue = {
	VERSION = "1.0.0",
	FORMAT_VERSION = 1,
}

export type CodeNumWide = {
	_codeNum: "wide",
	m: number,
	e: number,
	expSign: number,
	expLength: number,
}

export type LegacyValue = {
	kind: "legacy",
	raw: string,
	schema: string,
	value: any,
}

export type Value = number | CodeNumWide | LegacyValue
export type Node = { kind: string }
export type Options = {
	decimals: number?,
	trim_trailing_zeros: boolean?,
}

local MAX_SERIALIZED_LENGTH = 199_999
local SCHEMA = "CodeNumValue"
local LEGACY_ALYANUM_SCHEMA = "AlyaNumValue"
local LEGACY_INFINITEMATH_SCHEMA = "InfiniteMathValue"
local LEGACY_CODE_SCHEMA = "CodeNum"

local cached_api: any = nil
local cached_formatter: any = nil

local function is_finite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

local function resolve_api(): any
	if cached_api ~= nil then
		return cached_api
	end

	local replicated_storage = game:GetService("ReplicatedStorage")
	local module_script = replicated_storage:FindFirstChild("CodeNum")
	if module_script == nil or not module_script:IsA("ModuleScript") then
		error("CodeNumValue requires ReplicatedStorage.CodeNum", 2)
	end

	local ok, loaded = pcall(require, module_script)
	if not ok then
		error("failed to require CodeNum: " .. tostring(loaded), 2)
	end
	if type(loaded) ~= "table"
		or loaded.VERSION ~= "0.5.0"
		or type(loaded.encode) ~= "function"
		or type(loaded.decode) ~= "function"
		or type(loaded.parse) ~= "function"
		or type(loaded.fromScientific) ~= "function"
		or type(loaded.toString) ~= "function"
		or type(loaded.toNumber) ~= "function"
		or type(loaded.add) ~= "function"
		or type(loaded.sub) ~= "function"
		or type(loaded.mul) ~= "function"
		or type(loaded.div) ~= "function"
		or type(loaded.pow) ~= "function"
		or type(loaded.abs) ~= "function"
		or type(loaded.log10) ~= "function"
		or type(loaded.isWide) ~= "function"
	then
		error("ReplicatedStorage.CodeNum must expose the CodeNum 0.5.0 API", 2)
	end

	cached_api = loaded
	return loaded
end

local function resolve_formatter(): any
	if cached_formatter ~= nil then
		return cached_formatter
	end

	local ok, loaded = pcall(require, script.Parent.CodeNumFormatter)
	if not ok then
		error("failed to require CodeNumFormatter: " .. tostring(loaded), 2)
	end
	if type(loaded) ~= "table" or type(loaded.format) ~= "function" then
		error("CodeNumFormatter must expose format", 2)
	end

	cached_formatter = loaded
	return loaded
end

local function is_legacy(value: any): boolean
	return type(value) == "table"
		and value.kind == "legacy"
		and type(value.raw) == "string"
		and type(value.schema) == "string"
end

local function is_code_num_value(value: any): boolean
	if type(value) == "number" then
		return true
	end
	local api = resolve_api()
	if api.isWide(value) then
		return true
	end
	if type(value) == "table" then
		local ok = pcall(api.toString, value)
		return ok
	end
	return false
end

local function serialize_value(value: any): string
	if is_legacy(value) then
		return value.raw
	end
	local payload = resolve_api().encode(value)
	if type(payload) ~= "string" then
		error("CodeNum.encode must return a string", 3)
	end
	local serialized = HttpService:JSONEncode({
		schema = SCHEMA,
		version = CodeNumValue.FORMAT_VERSION,
		value = payload,
	})
	if type(serialized) ~= "string" then
		error("CodeNumValue encoder did not return a string", 3)
	end
	if #serialized > MAX_SERIALIZED_LENGTH then
		error("serialized CodeNumValue exceeds the safe StringValue limit of 199999 bytes", 3)
	end
	return serialized
end

local function try_decode_code_num(payload: any): (boolean, any?)
	if type(payload) ~= "string" or #payload > MAX_SERIALIZED_LENGTH then
		return false, nil
	end
	local ok, decoded = pcall(function()
		return resolve_api().decode(payload)
	end)
	if not ok or not is_code_num_value(decoded) then
		return false, nil
	end
	return true, decoded
end

local function legacy_integer_to_value(sign: number, digits: string): any?
	digits = string.gsub(digits, "^0+", "")
	if digits == "" then
		return 0
	end
	if #digits > 309 then
		return nil
	end

	local literal = (if sign < 0 then "-" else "") .. digits
	local native = tonumber(literal)
	if native == nil or not is_finite(native) then
		return nil
	end
	if string.format("%.0f", math.abs(native)) ~= digits then
		return nil
	end
	return resolve_api().new(native)
end

local function legacy_node_to_value(node: any, depth: number, budget: {count: number}): any?
	if type(node) ~= "table" or depth > 128 then
		return nil
	end
	budget.count += 1
	if budget.count > 8192 then
		return nil
	end

	local api = resolve_api()
	local kind = node.kind
	if kind == "finite" then
		if not is_finite(node.value) then
			return nil
		end
		return api.new(node.value)
	elseif kind == "integer" then
		if (node.sign ~= 1 and node.sign ~= -1)
			or type(node.digits) ~= "string"
			or not string.match(node.digits, "^%d+$")
		then
			return nil
		end
		return legacy_integer_to_value(node.sign, node.digits)
	elseif kind == "scientific" then
		if (node.sign ~= 1 and node.sign ~= -1)
			or not is_finite(node.mantissa)
			or node.mantissa <= 0
			or type(node.exponent) ~= "string"
			or not string.match(node.exponent, "^[+-]?%d+$")
		then
			return nil
		end
		local ok, parsed = pcall(function()
			return api.fromScientific(node.sign * node.mantissa, node.exponent)
		end)
		return if ok then parsed else nil
	elseif kind == "special" then
		if node.name == "nan" then
			return 0 / 0
		elseif node.name == "+infinity" then
			return math.huge
		elseif node.name == "-infinity" then
			return -math.huge
		end
		return nil
	elseif kind == "expression" then
		local left = legacy_node_to_value(node.left, depth + 1, budget)
		local right = legacy_node_to_value(node.right, depth + 1, budget)
		if left == nil or right == nil then
			return nil
		end
		local ok, result = pcall(function()
			if node.op == "add" then
				return api.add(left, right)
			elseif node.op == "sub" then
				return api.sub(left, right)
			elseif node.op == "mul" then
				return api.mul(left, right)
			elseif node.op == "div" then
				return api.div(left, right)
			elseif node.op == "pow" then
				local power = api.toNumber(right)
				if not is_finite(power) then
					error("legacy power is outside CodeNum's numeric power domain")
				end
				return api.pow(left, power)
			end
			error("unsupported legacy expression operator")
		end)
		return if ok then result else nil
	elseif kind == "hyper" then
		local base = legacy_node_to_value(node.base, depth + 1, budget)
		local arrows = legacy_node_to_value(node.arrows, depth + 1, budget)
		local height = legacy_node_to_value(node.height, depth + 1, budget)
		if base == nil or arrows == nil or height == nil then
			return nil
		end

		local arrow_count = api.toNumber(arrows)
		local native_height = api.toNumber(height)
		if not is_finite(arrow_count) or not is_finite(native_height)
			or native_height % 1 ~= 0 or native_height < 1 or native_height > 3
		then
			return nil
		end

		if arrow_count == 1 then
			local ok, result = pcall(function()
				return api.pow(base, native_height)
			end)
			return if ok then result else nil
		elseif arrow_count == 2 and native_height <= 3 then
			local base_native = api.toNumber(base)
			if not is_finite(base_native) or math.abs(base_native) > 1_000_000 then
				return nil
			end
			local result = base_native
			for _ = 2, native_height do
				local ok, next_result = pcall(function()
					return base_native ^ result
				end)
				if not ok or not is_finite(next_result) then
					return nil
				end
				result = next_result
			end
			local ok, parsed = pcall(function()
				return api.new(result)
			end)
			return if ok then parsed else nil
		end
		return nil
	elseif kind == "call" then
		local inner = legacy_node_to_value(node.value, depth + 1, budget)
		if inner == nil then
			return nil
		end
		if node.op == "abs" then
			return api.abs(inner)
		elseif node.op == "log10" then
			local ok, result = pcall(function()
				return api.log10(inner)
			end)
			if not ok or not is_finite(result) then
				return nil
			end
			return result
		end
	end
	return nil
end

local function alyanum_base_to_value(value: any): any?
	if type(value) ~= "table" then
		return nil
	end
	if value.kind == "special" then
		if value.name == "nan" then
			return 0 / 0
		elseif value.name == "+infinity" then
			return math.huge
		elseif value.name == "-infinity" then
			return -math.huge
		end
		return nil
	end
	if value.kind ~= "number" or type(value.value) ~= "table" then
		return nil
	end

	local base = value.value
	if (base.sign ~= -1 and base.sign ~= 0 and base.sign ~= 1)
		or not is_finite(base.multiplicand)
		or not is_finite(base.exponent)
		or not is_finite(base.tetrate)
		or not is_finite(base.pentate)
		or not is_finite(base.hexate)
		or not is_finite(base.heptate)
		or base.multiplicand < 0
		or base.exponent < 0
		or base.tetrate < 0
		or base.pentate < 0
		or base.hexate < 0
		or base.heptate < 0
	then
		return nil
	end
	if base.sign == 0 or base.multiplicand == 0 then
		return 0
	end
	if base.tetrate ~= 0 or base.pentate ~= 0 or base.hexate ~= 0 or base.heptate ~= 0 then
		return nil
	end

	local api = resolve_api()
	if base.exponent == 0 then
		return api.new(base.sign * base.multiplicand)
	elseif base.exponent == 1 then
		local integer_exponent = math.floor(base.multiplicand)
		local mantissa = 10 ^ (base.multiplicand - integer_exponent)
		local ok, result = pcall(function()
			return api.fromScientific(base.sign * mantissa, string.format("%.0f", integer_exponent))
		end)
		return if ok then result else nil
	elseif base.exponent == 2 and base.multiplicand <= 308 then
		local exponent = 10 ^ base.multiplicand
		if not is_finite(exponent) or exponent > 1e308 then
			return nil
		end
		local integer_exponent = math.floor(exponent)
		local mantissa = 10 ^ (exponent - integer_exponent)
		local ok, result = pcall(function()
			return api.fromScientific(base.sign * mantissa, string.format("%.0f", integer_exponent))
		end)
		return if ok then result else nil
	end
	return nil
end

local function make_legacy(serialized: string, schema: string, value: any): LegacyValue
	return {
		kind = "legacy",
		raw = serialized,
		schema = schema,
		value = value,
	}
end

local function decode_serialized_impl(serialized: string): (any?, string?)
	if type(serialized) ~= "string" or #serialized > MAX_SERIALIZED_LENGTH then
		return nil, nil
	end

	if string.sub(serialized, 1, 4) == "CN1|" then
		local ok, decoded = try_decode_code_num(serialized)
		if not ok then
			return nil, nil
		end
		return decoded, serialize_value(decoded)
	end

	local ok, envelope = pcall(function()
		return HttpService:JSONDecode(serialized)
	end)
	if not ok or type(envelope) ~= "table" then
		return nil, nil
	end

	if envelope.schema == SCHEMA then
		if envelope.version ~= CodeNumValue.FORMAT_VERSION or type(envelope.value) ~= "string" then
			return nil, nil
		end
		local valid, decoded = try_decode_code_num(envelope.value)
		if not valid then
			return nil, nil
		end
		return decoded, serialize_value(decoded)
	elseif envelope.schema == LEGACY_ALYANUM_SCHEMA then
		if envelope.version ~= 1 or type(envelope.value) ~= "table" then
			return nil, nil
		end
		local decoded = alyanum_base_to_value(envelope.value)
		if decoded == nil then
			return make_legacy(serialized, LEGACY_ALYANUM_SCHEMA, envelope.value), serialized
		end
		return decoded, serialize_value(decoded)
	elseif envelope.schema == LEGACY_INFINITEMATH_SCHEMA then
		if envelope.version ~= 1 or type(envelope.value) ~= "table" then
			return nil, nil
		end
		local value = envelope.value
		if value.kind == "special" then
			local decoded = if value.name == "nan" then 0 / 0
				elseif value.name == "+infinity" then math.huge
				elseif value.name == "-infinity" then -math.huge
				else nil
			if decoded == nil then
				return nil, nil
			end
			return decoded, serialize_value(decoded)
		elseif value.kind == "number" then
			local mantissa = value.first
			local exponent = value.second
			if not is_finite(mantissa) or not is_finite(exponent) or math.floor(exponent) ~= exponent then
				return make_legacy(serialized, LEGACY_INFINITEMATH_SCHEMA, value), serialized
			end
			local converted_ok, converted = pcall(function()
				return resolve_api().fromScientific(mantissa, string.format("%.0f", exponent))
			end)
			if not converted_ok then
				return make_legacy(serialized, LEGACY_INFINITEMATH_SCHEMA, value), serialized
			end
			return converted, serialize_value(converted)
		end
		return nil, nil
	elseif envelope.schema == LEGACY_CODE_SCHEMA then
		if envelope.version ~= 2 or type(envelope.value) ~= "table" then
			return nil, nil
		end
		local decoded = legacy_node_to_value(envelope.value, 0, { count = 0 })
		if decoded == nil then
			return make_legacy(serialized, LEGACY_CODE_SCHEMA, envelope.value), serialized
		end
		return decoded, serialize_value(decoded)
	end

	return nil, nil
end

local function decode_serialized(serialized: string): (any?, string?)
	local ok, decoded, canonical = pcall(decode_serialized_impl, serialized)
	if not ok then
		return nil, nil
	end
	return decoded, canonical
end

function CodeNumValue.is_unsupported_version(value: any): boolean
	if type(value) ~= "string" or #value > MAX_SERIALIZED_LENGTH then
		return false
	end
	local ok, envelope = pcall(function()
		return HttpService:JSONDecode(value)
	end)
	if not ok or type(envelope) ~= "table" or type(envelope.version) ~= "number"
		or not is_finite(envelope.version)
	then
		return false
	end
	if envelope.schema == SCHEMA then
		return envelope.version ~= CodeNumValue.FORMAT_VERSION
	elseif envelope.schema == LEGACY_ALYANUM_SCHEMA then
		return envelope.version ~= 1
	elseif envelope.schema == LEGACY_INFINITEMATH_SCHEMA then
		return envelope.version ~= 1
	elseif envelope.schema == LEGACY_CODE_SCHEMA then
		return envelope.version ~= 2
	end
	return false
end

function CodeNumValue.normalize_serialized(value: any): (string?, Node?)
	local decoded, canonical = decode_serialized(value)
	if decoded == nil or canonical == nil then
		return nil, nil
	end
	local kind = if is_legacy(decoded) then "legacy"
		elseif type(decoded) == "number" and not is_finite(decoded) then "special"
		else "number"
	return canonical, { kind = kind }
end

function CodeNumValue.is_serialized(value: any): boolean
	local decoded = decode_serialized(value)
	return decoded ~= nil
end

function CodeNumValue.normalize(value: any): string
	if is_legacy(value) then
		return value.raw
	end
	if type(value) == "string" then
		local decoded, canonical = decode_serialized(value)
		if decoded ~= nil and canonical ~= nil then
			return canonical
		end
		if CodeNumValue.is_unsupported_version(value) then
			error("stored CodeNumValue uses an unsupported codec version; refusing to overwrite it", 2)
		end
		if string.match(value, "^CN%d+|") then
			error("invalid or unsupported CodeNum payload", 2)
		end
		local parsed = resolve_api().parse(value)
		return serialize_value(parsed)
	end
	return serialize_value(value)
end

function CodeNumValue.is_value(value: any): boolean
	local ok = pcall(function()
		CodeNumValue.normalize(value)
	end)
	return ok
end

function CodeNumValue.encode(value: any): string
	return CodeNumValue.normalize(value)
end

function CodeNumValue.decode(serialized: string): Value
	local decoded = decode_serialized(serialized)
	if decoded == nil then
		error("invalid or unsupported CodeNumValue payload", 2)
	end
	return decoded
end

local function legacy_integer_display(node: any, options: Options?, depth: number): string
	local sign = if node.sign == -1 then "-" else ""
	local digits = string.gsub(node.digits, "^0+", "")
	if digits == "" then
		return "0"
	end
	local converted = legacy_integer_to_value(node.sign, digits)
	if converted ~= nil then
		return resolve_formatter().format(converted, options)
	end
	return sign .. string.sub(digits, 1, 17) .. "…"
end

local function format_legacy_node(node: any, options: Options?, depth: number): string
	if type(node) ~= "table" or depth > 48 then
		return "…"
	end
	local kind = node.kind
	if kind == "finite" and is_finite(node.value) then
		return resolve_formatter().format(node.value, options)
	elseif kind == "integer"
		and (node.sign == 1 or node.sign == -1)
		and type(node.digits) == "string"
		and string.match(node.digits, "^%d+$")
	then
		return legacy_integer_display(node, options, depth)
	elseif kind == "scientific"
		and (node.sign == 1 or node.sign == -1)
		and is_finite(node.mantissa)
		and type(node.exponent) == "string"
	then
		local converted = legacy_node_to_value(node, depth, { count = 0 })
		return if converted ~= nil then resolve_formatter().format(converted, options)
			else (node.sign < 0 and "-" or "") .. tostring(node.mantissa) .. "e" .. node.exponent
	elseif kind == "special" then
		if node.name == "nan" then
			return "NaN"
		elseif node.name == "+infinity" then
			return "Infinity"
		elseif node.name == "-infinity" then
			return "-Infinity"
		end
	elseif kind == "hyper" then
		local arrows = node.arrows
		local arrow_text = "↑"
		if type(arrows) == "table" and arrows.kind == "finite" and is_finite(arrows.value) then
			local count = arrows.value
			if count % 1 == 0 and count >= 1 and count <= 8 then
				arrow_text = string.rep("↑", count)
			else
				arrow_text = "↑{" .. tostring(count) .. "}"
			end
		elseif type(arrows) == "table" and arrows.kind == "integer"
			and (arrows.sign == 1 or arrows.sign == -1)
			and type(arrows.digits) == "string"
			and string.match(arrows.digits, "^%d+$")
		then
			local count = tonumber(arrows.digits)
			if count ~= nil and arrows.sign < 0 then
				count = -count
			end
			if count ~= nil and count % 1 == 0 and count >= 1 and count <= 8 then
				arrow_text = string.rep("↑", count)
			else
				arrow_text = "↑{" .. (arrows.sign < 0 and "-" or "") .. arrows.digits .. "}"
			end
		end
		return "(" .. format_legacy_node(node.base, options, depth + 1) .. ")"
			.. arrow_text .. "(" .. format_legacy_node(node.height, options, depth + 1) .. ")"
	elseif kind == "expression" then
		local symbols = { add = "+", sub = "−", mul = "×", div = "÷", pow = "^" }
		local symbol = symbols[node.op]
		if symbol ~= nil then
			return "(" .. format_legacy_node(node.left, options, depth + 1) .. " "
				.. symbol .. " " .. format_legacy_node(node.right, options, depth + 1) .. ")"
		end
	elseif kind == "call" then
		return tostring(node.op) .. "(" .. format_legacy_node(node.value, options, depth + 1) .. ")"
	end
	return "[legacy CodeNum value outside CodeNum 0.5 range]"
end

function CodeNumValue.format(value: any, options: Options?): string
	local decoded: any
	if type(value) == "string" then
		decoded = decode_serialized(value)
		if decoded == nil then
			decoded = CodeNumValue.decode(CodeNumValue.normalize(value))
		end
	else
		decoded = value
	end

	if is_legacy(decoded) then
		if decoded.schema == LEGACY_CODE_SCHEMA then
			return format_legacy_node(decoded.value, options, 0)
		end
		return "[legacy " .. decoded.schema .. " value outside CodeNum 0.5 range]"
	end

	return resolve_formatter().format(decoded, options)
end

function CodeNumValue.new(name: string, initial_value: any): StringValue
	if type(name) ~= "string" or name == "" then
		error("name must be a non-empty string", 2)
	end
	local value = Instance.new("StringValue")
	value.Name = name
	value.Value = CodeNumValue.normalize(initial_value)
	return value
end

local function expect_string_value(value: any): StringValue
	if typeof(value) ~= "Instance" or not (value :: Instance):IsA("StringValue") then
		error("backing_value must be a StringValue", 3)
	end
	return value :: StringValue
end

function CodeNumValue.get(value: any): Value
	local backing_value = expect_string_value(value)
	return CodeNumValue.decode(backing_value.Value)
end

function CodeNumValue.set(value: any, number_value: any)
	local backing_value = expect_string_value(value)
	backing_value.Value = CodeNumValue.normalize(number_value)
end

function CodeNumValue.toString(value: any): string
	return CodeNumValue.format(value)
end

return table.freeze(CodeNumValue)
