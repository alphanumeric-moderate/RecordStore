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

export type CodeNumPrecise = {
	_codeNum: "precise",
}

export type LegacyValue = {
	kind: "legacy",
	raw: string,
	schema: string,
	value: any,
}

export type Value = number | CodeNumWide | CodeNumPrecise | LegacyValue
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
		or loaded.VERSION ~= "0.6.0"
		or type(loaded.encode) ~= "function"
		or type(loaded.decode) ~= "function"
		or type(loaded.parse) ~= "function"
		or type(loaded.fromScientific) ~= "function"
		or type(loaded.fromInteger) ~= "function"
		or type(loaded.isPrecise) ~= "function"
		or type(loaded.wasRounded) ~= "function"
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
		error("ReplicatedStorage.CodeNum must expose the CodeNum 0.6.0 API", 2)
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
	if api.isWide(value) or api.isPrecise(value) then
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
	local api = resolve_api()
	if #digits > api.MAX_PRECISE_DIGITS then
		return nil
	end
	local literal = (if sign < 0 then "-" else "") .. digits
	local ok, parsed = pcall(function()
		return api.fromInteger(literal)
	end)
	return if ok then parsed else nil
end

local function legacy_results_equal(api: any, actual: any, exact: any): boolean
	if type(actual) == "number" and actual ~= actual then
		return type(exact) == "number" and exact ~= exact
	elseif type(actual) == "number" and actual == 0
		and type(exact) == "number" and exact == 0
	then
		return 1 / actual == 1 / exact
	elseif type(actual) == "number" and (actual == math.huge or actual == -math.huge) then
		return actual == exact
	elseif type(exact) == "number" and (exact ~= exact or exact == math.huge or exact == -math.huge) then
		return false
	end
	return api.compare(actual, exact) == 0
end

local function is_unsafe_legacy_result(
	api: any,
	result: any,
	operation: string,
	left: any,
	right: any
): boolean
	if not is_code_num_value(result) or api.wasRounded(result)
		or api.wasRounded(left) or api.wasRounded(right)
	then
		return true
	end

	-- Keep large native/Wide integers on their original legacy payload path.
	if type(result) == "number" then
		if is_finite(result) and math.abs(result) > 9007199254740991
			and math.floor(result) == result
		then
			return true
		end
	elseif api.isWide(result) and api.compare(api.abs(result), 9007199254740991) == 1 then
		return true
	end

	local ok, exact = pcall(function()
		if operation == "add" then
			return api.add(left, right, api.MAX_PRECISE_DIGITS)
		elseif operation == "sub" then
			return api.sub(left, right, api.MAX_PRECISE_DIGITS)
		elseif operation == "mul" then
			return api.mul(left, right, api.MAX_PRECISE_DIGITS)
		elseif operation == "div" then
			return api.div(left, right, api.MAX_PRECISE_DIGITS)
		elseif operation == "pow" then
			return api.pow(left, right, api.MAX_PRECISE_DIGITS)
		end
		error("unsupported legacy arithmetic operator")
	end)
	if not ok or not is_code_num_value(exact) or api.wasRounded(exact) then
		return true
	end
	return not legacy_results_equal(api, result, exact)
end

local function is_exact_legacy_log10(api: any, value: any, result: number): boolean
	if not is_finite(result) or math.floor(result) ~= result or api.wasRounded(value) then
		return false
	end
	local ok, exact = pcall(function()
		return api.pow(10, result, api.MAX_PRECISE_DIGITS)
	end)
	return ok and not api.wasRounded(exact) and api.compare(value, exact) == 0
end

local function legacy_node_to_value(
	node: any,
	depth: number,
	budget: {count: number}
): (any?, boolean)
	if type(node) ~= "table" or depth > 128 then
		return nil, false
	end
	budget.count += 1
	if budget.count > 8192 then
		return nil, false
	end

	local api = resolve_api()
	local kind = node.kind
	if kind == "finite" then
		if not is_finite(node.value) then
			return nil, false
		end
		return api.new(node.value), false
	elseif kind == "integer" then
		if (node.sign ~= 1 and node.sign ~= -1)
			or type(node.digits) ~= "string"
			or not string.match(node.digits, "^%d+$")
		then
			return nil, false
		end
		return legacy_integer_to_value(node.sign, node.digits), false
	elseif kind == "scientific" then
		if (node.sign ~= 1 and node.sign ~= -1)
			or not is_finite(node.mantissa)
			or node.mantissa <= 0
			or type(node.exponent) ~= "string"
			or not string.match(node.exponent, "^[+-]?%d+$")
		then
			return nil, false
		end
		local ok, parsed = pcall(function()
			return api.fromScientific(node.sign * node.mantissa, node.exponent)
		end)
		if ok then
			return parsed, false
		end
		return nil, false
	elseif kind == "special" then
		if node.name == "nan" then
			return 0 / 0, false
		elseif node.name == "+infinity" then
			return math.huge, false
		elseif node.name == "-infinity" then
			return -math.huge, false
		end
		return nil, false
	elseif kind == "expression" then
		local left, leftRounded = legacy_node_to_value(node.left, depth + 1, budget)
		local right, rightRounded = legacy_node_to_value(node.right, depth + 1, budget)
		if left == nil or right == nil then
			return nil, leftRounded or rightRounded
		end
		if leftRounded or rightRounded then
			return nil, true
		end
		local operation = node.op
		local ok, result = pcall(function()
			if operation == "add" then
				return api.add(left, right)
			elseif operation == "sub" then
				return api.sub(left, right)
			elseif operation == "mul" then
				return api.mul(left, right)
			elseif operation == "div" then
				return api.div(left, right)
			elseif operation == "pow" then
				local power = api.toNumber(right)
				if not is_finite(power) or api.compare(right, power) ~= 0 then
					error("legacy power cannot be represented exactly as a native exponent")
				end
				return api.pow(left, power)
			end
			error("unsupported legacy expression operator")
		end)
		if not ok then
			return nil, false
		end
		local exactRight = if operation == "pow" then api.toNumber(right) else right
		if is_unsafe_legacy_result(api, result, operation, left, exactRight) then
			return nil, true
		end
		return result, false
	elseif kind == "hyper" then
		local base, baseRounded = legacy_node_to_value(node.base, depth + 1, budget)
		local arrows, arrowsRounded = legacy_node_to_value(node.arrows, depth + 1, budget)
		local height, heightRounded = legacy_node_to_value(node.height, depth + 1, budget)
		if base == nil or arrows == nil or height == nil then
			return nil, baseRounded or arrowsRounded or heightRounded
		end
		if baseRounded or arrowsRounded or heightRounded then
			return nil, true
		end

		local arrow_count = api.toNumber(arrows)
		local native_height = api.toNumber(height)
		if not is_finite(arrow_count) or not is_finite(native_height)
			or api.compare(arrows, arrow_count) ~= 0 or api.compare(height, native_height) ~= 0
			or native_height % 1 ~= 0 or native_height < 1 or native_height > 3
		then
			return nil, false
		end

		if arrow_count == 1 then
			local ok, result = pcall(function()
				return api.pow(base, native_height)
			end)
			if not ok then
				return nil, false
			end
			if is_unsafe_legacy_result(api, result, "pow", base, native_height) then
				return nil, true
			end
			return result, false
		elseif arrow_count == 2 and native_height <= 3 then
			local base_native = api.toNumber(base)
			if not is_finite(base_native) or math.abs(base_native) > 1_000_000
				or api.compare(base, base_native) ~= 0
			then
				return nil, false
			end
			local result = base
			local result_native = base_native
			local exact_base = api.new(base_native)
			for _ = 2, native_height do
				local ok, next_native = pcall(function()
					return base_native ^ result_native
				end)
				if not ok or not is_finite(next_native) then
					return nil, false
				end
				local parsed, next_result = pcall(function()
					return api.new(next_native)
				end)
				if not parsed then
					return nil, false
				end
				if is_unsafe_legacy_result(api, next_result, "pow", exact_base, result_native) then
					return nil, true
				end
				result = next_result
				result_native = next_native
			end
			return result, false
		end
		return nil, false
	elseif kind == "call" then
		local inner, innerRounded = legacy_node_to_value(node.value, depth + 1, budget)
		if inner == nil or innerRounded then
			return nil, innerRounded
		end
		if node.op == "abs" then
			return api.abs(inner), false
		elseif node.op == "log10" then
			local ok, result = pcall(function()
				return api.log10(inner)
			end)
			if not ok or not is_finite(result) then
				return nil, false
			end
			if not is_exact_legacy_log10(api, inner, result) then
				return nil, true
			end
			return result, false
		end
	end
	return nil, false
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

	if string.match(serialized, "^CN[12]|") ~= nil then
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

-- Validation runs before profile open. Do not evaluate legacy expression trees in this path.
local function inspect_code_num_payload(payload: any): boolean
	if type(payload) ~= "string" or #payload > MAX_SERIALIZED_LENGTH then return false end
	local api = resolve_api()
	local ok, decoded = pcall(api.decode, payload)
	if not ok then return false end
	local valid, supported = pcall(function()
		return type(decoded) == "number" or api.isWide(decoded) or api.isPrecise(decoded)
	end)
	return valid and supported == true
end

function CodeNumValue.inspect_serialized(value: any): boolean
	if type(value) ~= "string" or #value > MAX_SERIALIZED_LENGTH then return false end
	if string.match(value, "^CN[12]|") ~= nil then return inspect_code_num_payload(value) end
	local ok, envelope = pcall(function() return HttpService:JSONDecode(value) end)
	if not ok or type(envelope) ~= "table" then return false end
	if envelope.schema == SCHEMA then
		return envelope.version == CodeNumValue.FORMAT_VERSION and inspect_code_num_payload(envelope.value)
	elseif envelope.schema == LEGACY_ALYANUM_SCHEMA then
		return envelope.version == 1 and type(envelope.value) == "table"
	elseif envelope.schema == LEGACY_INFINITEMATH_SCHEMA then
		if envelope.version ~= 1 or type(envelope.value) ~= "table" then return false end
		local legacy_value = envelope.value
		return legacy_value.kind == "number"
			or (legacy_value.kind == "special"
				and (legacy_value.name == "nan"
					or legacy_value.name == "+infinity"
					or legacy_value.name == "-infinity"))
	elseif envelope.schema == LEGACY_CODE_SCHEMA then
		return envelope.version == 2 and type(envelope.value) == "table"
			and (envelope.value.kind ~= "finite" or type(envelope.value.value) == "number")
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
	return CodeNumValue.inspect_serialized(value)
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
