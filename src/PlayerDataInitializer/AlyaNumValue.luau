--!nonstrict
--!optimize 2

local HttpService = game:GetService("HttpService")

local AlyaNumValue = {
	VERSION = "1.0.0",
	FORMAT_VERSION = 1,
}

local MAX_SERIALIZED_LENGTH = 199_999
local SCHEMA = "AlyaNumValue"
local LEGACY_INFINITEMATH_SCHEMA = "InfiniteMathValue"
local LEGACY_CODE_SCHEMA = "CodeNum"
local cached_api = nil
local cached_formatter = nil

local function is_finite(value)
	return type(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
end

local function resolve_api()
	if cached_api ~= nil then return cached_api end
	local replicated_storage = game:GetService("ReplicatedStorage")
	local module_script = replicated_storage:FindFirstChild("AlyaNum")
	if module_script == nil or not module_script:IsA("ModuleScript") then
		error("AlyaNumValue requires ReplicatedStorage.AlyaNum", 2)
	end
	local ok, loaded = pcall(require, module_script)
	if not ok then error("failed to require AlyaNum: " .. tostring(loaded), 2) end
	if type(loaded) ~= "table" or type(loaded.new) ~= "function"
		or type(loaded.fix) ~= "function" or type(loaded.toBaseAlya) ~= "function"
	then
		error("ReplicatedStorage.AlyaNum does not expose the required API", 2)
	end
	cached_api = loaded
	return loaded
end

local function resolve_formatter()
	if cached_formatter ~= nil then return cached_formatter end
	local ok, loaded = pcall(require, script.Parent.AlyaNumFormatter)
	if not ok then error("failed to require AlyaNumFormatter: " .. tostring(loaded), 2) end
	if type(loaded) ~= "table" or type(loaded.format) ~= "function"
		or type(loaded.to_value) ~= "function"
	then
		error("AlyaNumFormatter must expose format and to_value", 2)
	end
	cached_formatter = loaded
	return loaded
end

local function special_value(name)
	return { kind = "special", name = name }
end

local function is_special(value)
	return type(value) == "table" and value.kind == "special"
		and (value.name == "nan" or value.name == "+infinity" or value.name == "-infinity")
end

local function is_legacy(value)
	return type(value) == "table" and value.kind == "legacy"
		and type(value.raw) == "string" and type(value.node) == "table"
end

local function from_pair(mantissa, exponent)
	if not is_finite(mantissa) or not is_finite(exponent) then return nil end
	local api = resolve_api()
	if mantissa == 0 then return api.new(0) end
	if exponent == 0 then return api.new(mantissa) end
	local ok, result = pcall(function()
		local magnitude = api.new(math.abs(mantissa))
		local power = api.new(10):pow(api.new(exponent))
		local product = magnitude * power
		return if mantissa < 0 then -product else product
	end)
	return if ok then result else nil
end

local function number_as_native(value)
	if is_special(value) or is_legacy(value) then return nil end
	local ok, result = pcall(function() return resolve_api().toNumber(value) end)
	if ok and is_finite(result) then return result end
	return nil
end

local function legacy_node_to_value(node, depth)
	if type(node) ~= "table" or depth > 128 then return nil end
	local kind = node.kind
	local api = resolve_api()
	if kind == "finite" then
		if not is_finite(node.value) then return nil end
		return api.new(node.value)
	elseif kind == "integer" then
		if (node.sign ~= 1 and node.sign ~= -1) or type(node.digits) ~= "string"
			or not string.match(node.digits, "^%d+$")
		then
			return nil
		end
		local digits = string.gsub(node.digits, "^0+", "")
		if digits == "" then return api.new(0) end
		local leading = string.sub(digits, 1, math.min(15, #digits))
		local leading_number = tonumber(leading)
		if leading_number == nil then return nil end
		local mantissa = leading_number / math.pow(10, #leading - 1)
		return from_pair(node.sign * mantissa, #digits - 1)
	elseif kind == "scientific" then
		if (node.sign ~= 1 and node.sign ~= -1)
			or not is_finite(node.mantissa) or node.mantissa <= 0
			or type(node.exponent) ~= "string"
			or not string.match(node.exponent, "^[+-]?%d+$")
		then
			return nil
		end
		local exponent = tonumber(node.exponent)
		if exponent == nil or not is_finite(exponent) then return nil end
		return from_pair(node.sign * node.mantissa, exponent)
	elseif kind == "special" then
		if node.name == "nan" or node.name == "+infinity" or node.name == "-infinity" then
			return special_value(node.name)
		end
		return nil
	elseif kind == "expression" then
		local left = legacy_node_to_value(node.left, depth + 1)
		local right = legacy_node_to_value(node.right, depth + 1)
		if left == nil or right == nil or is_special(left) or is_special(right) then return nil end
		local ok, result = pcall(function()
			if node.op == "add" then return left + right end
			if node.op == "sub" then return left - right end
			if node.op == "mul" then return left * right end
			if node.op == "div" then return left / right end
			if node.op == "pow" then return left ^ right end
			error("unsupported expression operator")
		end)
		return if ok then result else nil
	elseif kind == "hyper" then
		local base = legacy_node_to_value(node.base, depth + 1)
		local arrows = legacy_node_to_value(node.arrows, depth + 1)
		local height = legacy_node_to_value(node.height, depth + 1)
		if base == nil or arrows == nil or height == nil
			or is_special(base) or is_special(arrows) or is_special(height)
		then
			return nil
		end
		local arrow_count = number_as_native(arrows)
		local native_height = number_as_native(height)
		if arrow_count == 1 and native_height ~= nil then
			local ok, result = pcall(function() return base ^ native_height end)
			return if ok then result else nil
		elseif arrow_count == 2 and native_height ~= nil
			and native_height % 1 == 0 and native_height >= 1 and native_height <= 3
		then
			local result = base
			for _ = 2, native_height do
				local ok, next_result = pcall(function() return base ^ result end)
				if not ok then return nil end
				result = next_result
			end
			return result
		end
		return nil
	elseif kind == "call" then
		local inner = legacy_node_to_value(node.value, depth + 1)
		if inner == nil or is_special(inner) then return nil end
		if node.op == "abs" then return api.abs(inner) end
		if node.op == "log10" then
			local native = number_as_native(inner)
			if native ~= nil and native <= 0 then return nil end
			local ok, result = pcall(function() return api.log10(inner) end)
			return if ok then result else nil
		end
	end
	return nil
end

local function serialize_value(value)
	if is_legacy(value) then return value.raw end
	local stored_value
	if is_special(value) then
		stored_value = { kind = "special", name = value.name }
	else
		local serialized_base = {
			sign = value.sign,
			multiplicand = value.multiplicand,
			exponent = value.exponent,
			tetrate = value.tetrate,
			pentate = value.pentate,
			hexate = value.hexate,
			heptate = value.heptate,
		}
		for _, field in pairs(serialized_base) do
			if not is_finite(field) then error("AlyaNum generated a non-finite serialized field", 3) end
		end
		stored_value = { kind = "number", value = serialized_base }
	end
	local serialized = HttpService:JSONEncode({
		schema = SCHEMA,
		version = AlyaNumValue.FORMAT_VERSION,
		value = stored_value,
	})
	if type(serialized) ~= "string" then error("AlyaNumValue encoder did not return a string", 3) end
	if #serialized > MAX_SERIALIZED_LENGTH then
		error("serialized AlyaNumValue exceeds the safe StringValue limit of 199999 bytes", 3)
	end
	return serialized
end

local function decode_serialized_impl(serialized)
	if type(serialized) ~= "string" or #serialized > MAX_SERIALIZED_LENGTH then return nil end
	local ok, envelope = pcall(function() return HttpService:JSONDecode(serialized) end)
	if not ok or type(envelope) ~= "table" then return nil end
	if envelope.schema == SCHEMA then
		if envelope.version ~= AlyaNumValue.FORMAT_VERSION or type(envelope.value) ~= "table" then return nil end
		local value = envelope.value
		if value.kind == "special" then
			if value.name ~= "nan" and value.name ~= "+infinity" and value.name ~= "-infinity" then return nil end
			local decoded = special_value(value.name)
			return decoded, serialize_value(decoded)
		elseif value.kind == "number" and type(value.value) == "table" then
			local decoded_ok, decoded = pcall(function() return resolve_formatter().to_value(value.value) end)
			if not decoded_ok or type(decoded) ~= "table" or decoded.kind == "special" then return nil end
			return decoded, serialize_value(decoded)
		end
		return nil
	elseif envelope.schema == LEGACY_INFINITEMATH_SCHEMA then
		if envelope.version ~= 1 or type(envelope.value) ~= "table" then return nil end
		local value = envelope.value
		if value.kind == "special" then
			local decoded_name = value.name
			if decoded_name == "nan" or decoded_name == "+infinity" or decoded_name == "-infinity" then
				local decoded = special_value(decoded_name)
				return decoded, serialize_value(decoded)
			end
			return nil
		elseif value.kind == "number" then
			local decoded = from_pair(value.first, value.second)
			if decoded == nil then return nil end
			return decoded, serialize_value(decoded)
		end
		return nil
	elseif envelope.schema == LEGACY_CODE_SCHEMA then
		if envelope.version ~= 2 or type(envelope.value) ~= "table" then return nil end
		local decoded = legacy_node_to_value(envelope.value, 0)
		if decoded == nil then
			decoded = { kind = "legacy", raw = serialized, node = envelope.value }
			return decoded, serialized
		end
		return decoded, serialize_value(decoded)
	end
	return nil
end

local function decode_serialized(serialized)
	local ok, decoded, canonical = pcall(decode_serialized_impl, serialized)
	if not ok then return nil end
	return decoded, canonical
end

function AlyaNumValue.is_unsupported_version(value)
	if type(value) ~= "string" or #value > MAX_SERIALIZED_LENGTH then return false end
	local ok, envelope = pcall(function() return HttpService:JSONDecode(value) end)
	if not ok or type(envelope) ~= "table" or type(envelope.version) ~= "number"
		or not is_finite(envelope.version)
	then
		return false
	end
	if envelope.schema == SCHEMA or envelope.schema == LEGACY_INFINITEMATH_SCHEMA then
		return envelope.version ~= AlyaNumValue.FORMAT_VERSION
	end
	return false
end

function AlyaNumValue.normalize_serialized(value)
	local decoded, canonical = decode_serialized(value)
	if decoded == nil or canonical == nil then return nil, nil end
	return canonical, { kind = is_special(decoded) and "special" or (is_legacy(decoded) and "legacy" or "number") }
end

function AlyaNumValue.is_serialized(value)
	local decoded = decode_serialized(value)
	return decoded ~= nil
end

local function value_from_input(value)
	if is_special(value) then return value end
	if is_legacy(value) then return value end
	if type(value) == "table" then
		if value.kind == "finite" or value.kind == "integer" or value.kind == "scientific"
			or value.kind == "special" or value.kind == "hyper" or value.kind == "expression" or value.kind == "call"
		then
			error("legacy CodeNum nodes must be passed as a serialized payload", 3)
		end
		if type(value.first) == "number" and type(value.second) == "number" then
			local converted = from_pair(value.first, value.second)
			if converted ~= nil then return converted end
		end
		if type(value[1]) == "number" and type(value[2]) == "number" then
			local converted = from_pair(value[1], value[2])
			if converted ~= nil then return converted end
		end
	end
	return resolve_formatter().to_value(value)
end

function AlyaNumValue.normalize(value)
	if type(value) == "string" then
		if #value > MAX_SERIALIZED_LENGTH then
			error("AlyaNumValue input exceeds the safe StringValue limit of 199999 bytes", 2)
		end
		local serialized = AlyaNumValue.normalize_serialized(value)
		if serialized ~= nil then return serialized end
		if AlyaNumValue.is_unsupported_version(value) then
			error("stored AlyaNumValue uses an unsupported codec version; refusing to overwrite it", 2)
		end
	end
	return serialize_value(value_from_input(value))
end

function AlyaNumValue.is_value(value)
	local ok = pcall(function() AlyaNumValue.normalize(value) end)
	return ok
end

function AlyaNumValue.encode(value)
	return AlyaNumValue.normalize(value)
end

function AlyaNumValue.decode(serialized)
	local decoded = decode_serialized(serialized)
	if decoded == nil then error("invalid or unsupported AlyaNumValue payload", 2) end
	return decoded
end

local function format_legacy_node(node, options, depth)
	if type(node) ~= "table" or depth > 48 then return "…" end
	local kind = node.kind
	if kind == "finite" and is_finite(node.value) then
		return resolve_formatter().format(node.value, options)
	elseif kind == "integer" and (node.sign == 1 or node.sign == -1)
		and type(node.digits) == "string" and string.match(node.digits, "^%d+$")
	then
		local digits = string.gsub(node.digits, "^0+", "")
		if digits == "" then return "0" end
		local leading = string.sub(digits, 1, math.min(15, #digits))
		local mantissa = (tonumber(leading) or 0) / math.pow(10, #leading - 1)
		local value = from_pair(node.sign * mantissa, #digits - 1)
		return if value ~= nil then resolve_formatter().format(value, options) else "[legacy integer]"
	elseif kind == "scientific" and (node.sign == 1 or node.sign == -1)
		and is_finite(node.mantissa) and type(node.exponent) == "string"
	then
		local exponent = tonumber(node.exponent)
		local value = if exponent ~= nil then from_pair(node.sign * node.mantissa, exponent) else nil
		return if value ~= nil then resolve_formatter().format(value, options) else "[legacy scientific value]"
	elseif kind == "special" then
		if node.name == "nan" then return "NaN" end
		if node.name == "+infinity" then return "Infinity" end
		if node.name == "-infinity" then return "-Infinity" end
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
			and type(arrows.digits) == "string" and string.match(arrows.digits, "^%d+$")
		then
			local count = tonumber(arrows.digits)
			if count ~= nil and arrows.sign < 0 then count = -count end
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
	return "[legacy numeric value outside AlyaNum range]"
end

local function decode_for_format(value)
	if type(value) == "string" then
		local decoded = decode_serialized(value)
		if decoded ~= nil then return decoded end
	end
	return value_from_input(value)
end

function AlyaNumValue.format(value, options)
	local decoded = decode_for_format(value)
	if is_legacy(decoded) then return format_legacy_node(decoded.node, options, 0) end
	return resolve_formatter().format(decoded, options)
end

function AlyaNumValue.new(name, initial_value)
	if type(name) ~= "string" or name == "" then error("name must be a non-empty string", 2) end
	local value = Instance.new("StringValue")
	value.Name = name
	value.Value = AlyaNumValue.normalize(initial_value)
	return value
end

local function expect_string_value(value)
	if typeof(value) ~= "Instance" or not (value :: Instance):IsA("StringValue") then
		error("backing_value must be a StringValue", 3)
	end
	return value
end

function AlyaNumValue.get(value)
	local backing_value = expect_string_value(value)
	return AlyaNumValue.decode(backing_value.Value)
end

function AlyaNumValue.set(value, number_value)
	local backing_value = expect_string_value(value)
	backing_value.Value = AlyaNumValue.normalize(number_value)
end

function AlyaNumValue.toString(value)
	return AlyaNumValue.format(value)
end

return table.freeze(AlyaNumValue)
