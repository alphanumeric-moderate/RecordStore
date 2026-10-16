--!strict
--!optimize 2
-- CodeNumValue: StringValue transport for CodeNum's native, versioned JSON codec.
local HttpService = game:GetService("HttpService")
local NumberFormatterFactory = require(script.Parent.NumberFormatter)
local CodeNumValue = {}
export type Value = { kind: string }
type CodeNumAPI = { encode: (value: unknown) -> string, decode: (serialized: string) -> Value, toString: (value: Value) -> string }
local MAX_SERIALIZED_LENGTH = 200_000
local cached_api: CodeNumAPI? = nil
local function resolve_api(): CodeNumAPI
	if cached_api ~= nil then return cached_api end
	local replicated_storage = game:GetService("ReplicatedStorage")
	local module_script = replicated_storage:FindFirstChild("CodeNum")
	if module_script == nil or not module_script:IsA("ModuleScript") then error('CodeNumValue requires ReplicatedStorage.CodeNum', 2) end
	local ok, loaded = pcall(require, module_script)
	if not ok then error("failed to require CodeNum: " .. tostring(loaded), 2) end
	if type(loaded) ~= "table" then error("CodeNum module must return a table", 2) end
	local api = loaded :: { [string]: unknown }
	if type(api.encode) ~= "function" or type(api.decode) ~= "function" or type(api.toString) ~= "function" then error("CodeNum module must expose encode, decode, and toString", 2) end
	cached_api = loaded :: CodeNumAPI
	return cached_api
end
local function checked_encode(value: unknown): string
	local api = resolve_api()
	local serialized = api.encode(value)
	if type(serialized) ~= "string" then error("CodeNum.encode must return a string", 2) end
	if #serialized > MAX_SERIALIZED_LENGTH then error("serialized CodeNum exceeds StringValue's 200000-character limit", 2) end
	api.decode(serialized)
	return serialized
end
function CodeNumValue.is_serialized(value: unknown): boolean
	if type(value) ~= "string" or #value > MAX_SERIALIZED_LENGTH then return false end
	local ok = pcall(function() resolve_api().decode(value) end)
	return ok
end
function CodeNumValue.normalize(value: unknown): string
	if CodeNumValue.is_serialized(value) then return checked_encode(resolve_api().decode(value :: string)) end
	return checked_encode(value)
end
function CodeNumValue.is_value(value: unknown): boolean
	local ok = pcall(function() CodeNumValue.normalize(value) end)
	return ok
end
function CodeNumValue.encode(value: unknown): string
	return CodeNumValue.normalize(value)
end
function CodeNumValue.decode(serialized: string): Value
	if not CodeNumValue.is_serialized(serialized) then error("invalid or unsupported CodeNum payload", 2) end
	return resolve_api().decode(serialized)
end
function CodeNumValue.format(value: unknown, options: NumberFormatterFactory.Options?): string
	local serialized = CodeNumValue.normalize(value)
	local decoded = CodeNumValue.decode(serialized)
	local api = resolve_api()
	local envelope = HttpService:JSONDecode(serialized) :: { [string]: unknown }
	if type(envelope.value) ~= "table" then return api.toString(decoded) end
	local node = envelope.value :: { [string]: unknown }
	if node.kind == "finite" and type(node.value) == "number" then return NumberFormatterFactory.format(node.value, options) end
	if node.kind == "special" then
		if node.name == "nan" then return NumberFormatterFactory.format(0 / 0, options) end
		if node.name == "+infinity" then return NumberFormatterFactory.format(math.huge, options) end
		if node.name == "-infinity" then return NumberFormatterFactory.format(-math.huge, options) end
	end
	if node.kind == "integer" and (node.sign == 1 or node.sign == -1) and type(node.digits) == "string" then
		return NumberFormatterFactory.formatInteger((node.sign == -1 and "-" or "") .. node.digits, options)
	end
	if node.kind == "scientific" and (node.sign == 1 or node.sign == -1) and type(node.mantissa) == "number" and type(node.exponent) == "string" then
		return NumberFormatterFactory.formatScientific(node.sign, node.mantissa, node.exponent, options)
	end
	return api.toString(decoded)
end
function CodeNumValue.new(name: string, initial_value: unknown): StringValue
	if type(name) ~= "string" or name == "" then error("name must be a non-empty string", 2) end
	local value = Instance.new("StringValue")
	value.Name = name
	value.Value = CodeNumValue.normalize(initial_value)
	return value
end
function CodeNumValue.get(value: StringValue): Value
	if not value:IsA("StringValue") then error("backing_value must be a StringValue", 2) end
	return CodeNumValue.decode(value.Value)
end
function CodeNumValue.set(value: StringValue, number_value: unknown)
	if not value:IsA("StringValue") then error("backing_value must be a StringValue", 2) end
	value.Value = CodeNumValue.normalize(number_value)
end
return table.freeze(CodeNumValue)
