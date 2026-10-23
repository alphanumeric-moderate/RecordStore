--!nonstrict
--!optimize 2

local HttpService = game:GetService("HttpService")
local NumberFormatterFactory = require(script.Parent.NumberFormatter)

local InfiniteMathValue = {
	VERSION = "1.0.5",
	FORMAT_VERSION = 1,
}

local MAX_SERIALIZED_LENGTH = 199_999
local SCHEMA = "InfiniteMathValue"
local LEGACY_SCHEMA = "CodeNum"
local cached_api = nil

local function is_finite(value)
	return type(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
end

local function special_value(name)
	return { kind = "special", name = name }
end

local function is_special(value)
	return type(value) == "table" and value.kind == "special"
end

local function is_legacy(value)
	return type(value) == "table" and value.kind == "legacy" and type(value.raw) == "string"
end

local function is_infinite_math_number(value)
	return type(value) == "table"
		and type(value.first) == "number"
		and type(value.second) == "number"
		and value.kind == nil
end

local function resolve_api()
	if cached_api ~= nil then
		return cached_api
	end

	local replicated_storage = game:GetService("ReplicatedStorage")
	local module_script = replicated_storage:FindFirstChild("InfiniteMath")
	if module_script == nil or not module_script:IsA("ModuleScript") then
		error("InfiniteMathValue requires ReplicatedStorage.InfiniteMath", 2)
	end

	local ok, loaded = pcall(require, module_script)
	if not ok then
		error("failed to require InfiniteMath: " .. tostring(loaded), 2)
	end
	if type(loaded) ~= "table" or type(loaded.new) ~= "function" then
		error("ReplicatedStorage.InfiniteMath must expose new", 2)
	end

	cached_api = loaded
	return cached_api
end

local function normalize_special_name(value)
	if type(value) ~= "string" then
		return nil
	end

	local name = string.lower(string.gsub(value, "%s", ""))
	if name == "nan" or name == "+nan" or name == "-nan" then
		return "nan"
	elseif name == "inf" or name == "+inf" or name == "infinity" or name == "+infinity" then
		return "+infinity"
	elseif name == "-inf" or name == "-infinity" then
		return "-infinity"
	end
	return nil
end

local function value_from_input(value)
	local api = resolve_api()

	if is_special(value) then
		if value.name == "nan" or value.name == "+infinity" or value.name == "-infinity" then
			return value
		end
		error("invalid InfiniteMath special value", 3)
	elseif is_legacy(value) then
		return value
	elseif is_infinite_math_number(value) then
		if not is_finite(value.first) or not is_finite(value.second) then
			if value.first ~= value.first or value.second ~= value.second then
				return special_value("nan")
			elseif value.first == math.huge or value.second == math.huge then
				return special_value("+infinity")
			elseif value.first == -math.huge or value.second == -math.huge then
				return special_value("-infinity")
			end
			error("InfiniteMath number fields must be finite", 3)
		end
		return api.new({ value.first, value.second })
	elseif type(value) == "number" then
		if value ~= value then
			return special_value("nan")
		elseif value == math.huge then
			return special_value("+infinity")
		elseif value == -math.huge then
			return special_value("-infinity")
		end
		return api.new(value)
	elseif type(value) == "string" then
		local special_name = normalize_special_name(value)
		if special_name ~= nil then
			return special_value(special_name)
		end
		return api.new(value)
	elseif type(value) == "table" then
		if value.kind == "finite"
			or value.kind == "integer"
			or value.kind == "scientific"
			or value.kind == "special"
			or value.kind == "hyper"
			or value.kind == "expression"
			or value.kind == "call"
		then
			error("legacy CodeNum nodes must be passed as a serialized payload", 3)
		end
		if type(value[1]) == "number" and type(value[2]) == "number" then
			if not is_finite(value[1]) or not is_finite(value[2]) then
				error("InfiniteMath tuple fields must be finite", 3)
			end
			return api.new({ value[1], value[2] })
		end
	end

	error("InfiniteMathValue expects a number, numeric string, InfiniteMath number, or serialized value", 3)
end

local function number_as_native(value)
	if is_special(value) then
		return nil
	end
	if not is_infinite_math_number(value) then
		return nil
	end

	local ok, native = pcall(function()
		return value:Reverse()
	end)
	if ok and is_finite(native) then
		return native
	end
	return nil
end

local function legacy_node_to_value(node, depth)
	if type(node) ~= "table" or depth > 128 then
		return nil
	end

	local api = resolve_api()
	local kind = node.kind
	if kind == "finite" then
		if type(node.value) ~= "number" then return nil end
		return value_from_input(node.value)
	elseif kind == "integer" then
		if (node.sign ~= 1 and node.sign ~= -1) or type(node.digits) ~= "string"
			or not string.match(node.digits, "^%d+$")
		then
			return nil
		end
		local digits = string.gsub(node.digits, "^0+", "")
		if digits == "" then return api.new(0) end
		local leading = string.sub(digits, 1, math.min(15, #digits))
		local mantissa = tonumber(leading) / math.pow(10, #leading - 1)
		return api.new({ node.sign * mantissa, #digits - 1 })
	elseif kind == "scientific" then
		if (node.sign ~= 1 and node.sign ~= -1)
			or not is_finite(node.mantissa)
			or node.mantissa <= 0
			or type(node.exponent) ~= "string"
			or not string.match(node.exponent, "^[+-]?%d+$")
		then
			return nil
		end
		local exponent = tonumber(node.exponent)
		if not is_finite(exponent) then return nil end
		return api.new({ node.sign * node.mantissa, exponent })
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
		return ok and result or nil
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
			return ok and result or nil
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
		if node.op == "abs" then
			return api.new({ math.abs(inner.first), inner.second })
		elseif node.op == "log10" then
			if inner.first <= 0 then return nil end
			return api.new(inner.second + math.log10(inner.first))
		end
	end
	return nil
end

local function serialize_value(value)
	if is_legacy(value) then
		return value.raw
	end

	local stored_value
	if is_special(value) then
		stored_value = { kind = "special", name = value.name }
	elseif is_infinite_math_number(value) then
		if not is_finite(value.first) or not is_finite(value.second) then
			error("InfiniteMath generated a non-finite serialized representation", 3)
		end
		stored_value = {
			kind = "number",
			first = value.first,
			second = value.second,
		}
	else
		error("unsupported InfiniteMathValue internal value", 3)
	end

	local serialized = HttpService:JSONEncode({
		schema = SCHEMA,
		version = InfiniteMathValue.FORMAT_VERSION,
		value = stored_value,
	})
	if type(serialized) ~= "string" then
		error("InfiniteMathValue encoder did not return a string", 3)
	end
	if #serialized > MAX_SERIALIZED_LENGTH then
		error("serialized InfiniteMathValue exceeds the safe StringValue limit of 199999 bytes", 3)
	end
	return serialized
end

local function decode_serialized_impl(serialized)
	if type(serialized) ~= "string" or #serialized > MAX_SERIALIZED_LENGTH then return nil end
	local ok, envelope = pcall(function() return HttpService:JSONDecode(serialized) end)
	if not ok or type(envelope) ~= "table" then return nil end
	if envelope.schema == SCHEMA then
		if envelope.version ~= InfiniteMathValue.FORMAT_VERSION or type(envelope.value) ~= "table" then return nil end
		local value = envelope.value
		if value.kind == "special" then
			if value.name ~= "nan" and value.name ~= "+infinity" and value.name ~= "-infinity" then return nil end
			local decoded = special_value(value.name)
			return decoded, serialize_value(decoded)
		elseif value.kind == "number" then
			if not is_finite(value.first) or not is_finite(value.second) then return nil end
			local decoded = resolve_api().new({ value.first, value.second })
			return decoded, serialize_value(decoded)
		end
		return nil
	elseif envelope.schema == LEGACY_SCHEMA then
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

function InfiniteMathValue.is_unsupported_version(value)
	if type(value) ~= "string" or #value > MAX_SERIALIZED_LENGTH then return false end
	local ok, envelope = pcall(function() return HttpService:JSONDecode(value) end)
	return ok and type(envelope) == "table" and envelope.schema == SCHEMA
		and type(envelope.version) == "number" and is_finite(envelope.version)
		and envelope.version ~= InfiniteMathValue.FORMAT_VERSION
end


function InfiniteMathValue.normalize_serialized(value)
	local decoded, canonical = decode_serialized(value)
	if decoded == nil or canonical == nil then
		return nil, nil
	end
	return canonical, { kind = is_special(decoded) and "special" or (is_legacy(decoded) and "legacy" or "number") }
end

function InfiniteMathValue.is_serialized(value)
	local decoded = decode_serialized(value)
	return decoded ~= nil
end

function InfiniteMathValue.normalize(value)
	if type(value) == "string" then
		if #value > MAX_SERIALIZED_LENGTH then
			error("InfiniteMathValue input exceeds the safe StringValue limit of 199999 bytes", 2)
		end
		local serialized = InfiniteMathValue.normalize_serialized(value)
		if serialized ~= nil then
			return serialized
		end
	end
	return serialize_value(value_from_input(value))
end

function InfiniteMathValue.is_value(value)
	return pcall(function()
		InfiniteMathValue.normalize(value)
	end)
end

function InfiniteMathValue.encode(value)
	return InfiniteMathValue.normalize(value)
end

function InfiniteMathValue.decode(serialized)
	local decoded = decode_serialized(serialized)
	if decoded == nil then
		error("invalid or unsupported InfiniteMathValue payload", 2)
	end
	return decoded
end

local function format_legacy_node(node, options, depth)
	if type(node) ~= "table" or depth > 48 then
		return "…"
	end
	local kind = node.kind
	if kind == "finite" and type(node.value) == "number" then
		return NumberFormatterFactory.format(node.value, options)
	elseif kind == "integer" and (node.sign == 1 or node.sign == -1) and type(node.digits) == "string" then
		return NumberFormatterFactory.formatInteger((node.sign == -1 and "-" or "") .. node.digits, options)
	elseif kind == "scientific" and (node.sign == 1 or node.sign == -1)
		and type(node.mantissa) == "number" and type(node.exponent) == "string"
	then
		return NumberFormatterFactory.formatScientific(node.sign, node.mantissa, node.exponent, options)
	elseif kind == "special" then
		if node.name == "nan" then return "NaN" end
		if node.name == "+infinity" then return "∞" end
		if node.name == "-infinity" then return "-∞" end
	elseif kind == "hyper" then
		local arrows = node.arrows
		local arrow_text = "↑"
		if type(arrows) == "table" and arrows.kind == "finite" and type(arrows.value) == "number" then
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
			local count = tonumber(arrows.digits) * arrows.sign
			if count ~= nil and count % 1 == 0 and count >= 1 and count <= 8 then
				arrow_text = string.rep("↑", count)
			else
				arrow_text = "↑{" .. (arrows.sign < 0 and "-" or "") .. arrows.digits .. "}"
			end
		end
		return "(" .. format_legacy_node(node.base, options, depth + 1) .. ")"
			.. arrow_text
			.. "(" .. format_legacy_node(node.height, options, depth + 1) .. ")"
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
	return "[legacy numeric value outside InfiniteMath range]"
end

local function decode_for_format(value)
	if type(value) == "string" then
		local decoded = decode_serialized(value)
		if decoded ~= nil then return decoded end
	end
	return value_from_input(value)
end

function InfiniteMathValue.format(value, options)
	local decoded = decode_for_format(value)
	if is_special(decoded) then
		if decoded.name == "nan" then return "NaN" end
		if decoded.name == "+infinity" then return "∞" end
		if decoded.name == "-infinity" then return "-∞" end
	elseif is_legacy(decoded) then
		return format_legacy_node(decoded.node, options, 0)
	end

	if options ~= nil and type(options) ~= "table" then
		error("options must be a table", 2)
	end
	local api = resolve_api()
	local decimals = if options ~= nil and options.decimals ~= nil then options.decimals else 2
	if type(decimals) ~= "number" or not is_finite(decimals)
		or math.floor(decimals) ~= decimals or decimals < 0 or decimals > 6
	then
		error("options.decimals must be an integer from 0 through 6", 2)
	end
	local trim = if options ~= nil and options.trim_trailing_zeros ~= nil
		then options.trim_trailing_zeros else true
	if type(trim) ~= "boolean" then
		error("options.trim_trailing_zeros must be a boolean", 2)
	end

	local previous_decimals = api.DECIMALPOINTS
	api.DECIMALPOINTS = decimals
	local ok, formatted = pcall(function()
		return tostring(decoded)
	end)
	api.DECIMALPOINTS = previous_decimals
	if ok and type(formatted) == "string" then
		if trim then
			return formatted
		end
		local number_text, suffix = string.match(formatted, "^([+-]?%d+%.?%d*)(.*)$")
		if number_text == nil then
			return formatted
		end
		local integer_part, fraction = string.match(number_text, "^([+-]?%d+)%.(%d+)$")
		if integer_part == nil then
			integer_part = number_text
			fraction = ""
		end
		if decimals == 0 then
			return integer_part .. suffix
		elseif #fraction < decimals then
			fraction = fraction .. string.rep("0", decimals - #fraction)
		elseif #fraction > decimals then
			fraction = string.sub(fraction, 1, decimals)
		end
		return integer_part .. "." .. fraction .. suffix
	end

	local exponent = string.format("%.0f", decoded.second)
	return NumberFormatterFactory.formatScientific(
		decoded.first < 0 and -1 or 1,
		math.abs(decoded.first),
		exponent,
		options
	)
end

function InfiniteMathValue.new(name, initial_value)
	if type(name) ~= "string" or name == "" then
		error("name must be a non-empty string", 2)
	end
	local value = Instance.new("StringValue")
	value.Name = name
	value.Value = InfiniteMathValue.normalize(initial_value)
	return value
end

local function expect_string_value(value)
	if typeof(value) ~= "Instance" or not (value :: Instance):IsA("StringValue") then
		error("backing_value must be a StringValue", 3)
	end
	return value
end

function InfiniteMathValue.get(value)
	local backing_value = expect_string_value(value)
	return InfiniteMathValue.decode(backing_value.Value)
end

function InfiniteMathValue.set(value, number_value)
	local backing_value = expect_string_value(value)
	backing_value.Value = InfiniteMathValue.normalize(number_value)
end

function InfiniteMathValue.toString(value)
	local decoded = decode_for_format(value)
	if is_special(decoded) then
		if decoded.name == "nan" then return "NaN" end
		if decoded.name == "+infinity" then return "Infinity" end
		return "-Infinity"
	elseif is_legacy(decoded) then
		return format_legacy_node(decoded.node, nil, 0)
	end
	return tostring(decoded)
end

return table.freeze(InfiniteMathValue)
