--!strict
--!optimize 2
-- CodeNumValue: StringValue transport for CodeNum's native, versioned JSON codec.

local NumberFormatterFactory = require(script.Parent.NumberFormatter)

local CodeNumValue = {}

export type Value = { kind: string }

type CodeNumAPI = {
    encode: (value: unknown) -> string,
    decode: (serialized: string) -> Value,
    toString: (value: Value) -> string,
}

-- Roblox's StringValue hard limit is conservatively treated as 199,999 bytes.
local MAX_SERIALIZED_LENGTH = 199_999
local cached_api: CodeNumAPI? = nil

local function resolve_api(): CodeNumAPI
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
    if type(loaded) ~= "table" then
        error("CodeNum module must return a table", 2)
    end

    local api = loaded :: { [string]: unknown }
    if type(api.encode) ~= "function"
        or type(api.decode) ~= "function"
        or type(api.toString) ~= "function"
    then
        error("CodeNum module must expose encode, decode, and toString", 2)
    end

    cached_api = loaded :: CodeNumAPI
    return cached_api
end

local function try_decode_serialized(value: unknown): (boolean, Value?)
    if type(value) ~= "string" or #value > MAX_SERIALIZED_LENGTH then
        return false, nil
    end

    local ok, decoded = pcall(function()
        return resolve_api().decode(value)
    end)
    if not ok or type(decoded) ~= "table" then
        return false, nil
    end

    local node = decoded :: { [string]: unknown }
    if type(node.kind) ~= "string" then
        return false, nil
    end
    return true, decoded :: Value
end

local function checked_encode(value: unknown): (string, Value)
    local api = resolve_api()
    local serialized = api.encode(value)
    if type(serialized) ~= "string" then
        error("CodeNum.encode must return a string", 2)
    end
    if #serialized > MAX_SERIALIZED_LENGTH then
        error("serialized CodeNum exceeds the safe StringValue limit of 199999 bytes", 2)
    end

    local ok, decoded = try_decode_serialized(serialized)
    if not ok or decoded == nil then
        error("CodeNum.encode returned a payload rejected by CodeNum.decode", 2)
    end
    return serialized, decoded
end

local function normalize_decoded_serialized(value: string, decoded: Value): (string, Value)
    local serialized = resolve_api().encode(decoded)
    if type(serialized) ~= "string" then
        error("CodeNum.encode must return a string", 2)
    end
    if #serialized > MAX_SERIALIZED_LENGTH then
        error("serialized CodeNum exceeds the safe StringValue limit of 199999 bytes", 2)
    end
    if serialized == value then
        return value, decoded
    end

    local ok, canonical_decoded = try_decode_serialized(serialized)
    if not ok or canonical_decoded == nil then
        error("CodeNum.encode returned a payload rejected by CodeNum.decode", 2)
    end
    return serialized, canonical_decoded
end

function CodeNumValue.normalize_serialized(value: unknown): (string?, Value?)
    local ok, decoded = try_decode_serialized(value)
    if not ok or decoded == nil then
        return nil, nil
    end
    return normalize_decoded_serialized(value :: string, decoded)
end

local function normalize_and_decode(value: unknown): (string, Value)
    if type(value) == "string" then
        if #value > MAX_SERIALIZED_LENGTH then
            error("CodeNum input string exceeds the safe StringValue limit of 199999 bytes", 2)
        end
        local serialized, decoded = CodeNumValue.normalize_serialized(value)
        if serialized ~= nil and decoded ~= nil then
            return serialized, decoded
        end
    end
    return checked_encode(value)
end

function CodeNumValue.is_serialized(value: unknown): boolean
    local ok = try_decode_serialized(value)
    return ok
end

function CodeNumValue.normalize(value: unknown): string
    local serialized = normalize_and_decode(value)
    return serialized
end

function CodeNumValue.is_value(value: unknown): boolean
    local ok = pcall(function()
        CodeNumValue.normalize(value)
    end)
    return ok
end

function CodeNumValue.encode(value: unknown): string
    return CodeNumValue.normalize(value)
end

function CodeNumValue.decode(serialized: string): Value
    local ok, decoded = try_decode_serialized(serialized)
    if not ok then
        error("invalid or unsupported CodeNum payload", 2)
    end
    return decoded :: Value
end

local function decode_for_format(value: unknown): Value
    if type(value) == "string" then
        if #value > MAX_SERIALIZED_LENGTH then
            error("CodeNum input string exceeds the safe StringValue limit of 199999 bytes", 2)
        end
        local ok, decoded = try_decode_serialized(value)
        if ok and decoded ~= nil then
            return decoded
        end
    end
    local _serialized, decoded = checked_encode(value)
    return decoded
end

function CodeNumValue.format(value: unknown, options: NumberFormatterFactory.Options?): string
    -- Formatting only needs a decoded node; don't re-encode an already-valid payload.
    local decoded = decode_for_format(value)
    local api = resolve_api()
    local node = decoded :: { [string]: unknown }

    if node.kind == "finite" and type(node.value) == "number" then
        return NumberFormatterFactory.format(node.value, options)
    end
    if node.kind == "special" then
        if node.name == "nan" then
            return NumberFormatterFactory.format(0 / 0, options)
        elseif node.name == "+infinity" then
            return NumberFormatterFactory.format(math.huge, options)
        elseif node.name == "-infinity" then
            return NumberFormatterFactory.format(-math.huge, options)
        end
    end
    if node.kind == "integer"
        and (node.sign == 1 or node.sign == -1)
        and type(node.digits) == "string"
    then
        return NumberFormatterFactory.formatInteger(
            (node.sign == -1 and "-" or "") .. node.digits,
            options
        )
    end
    if node.kind == "scientific"
        and (node.sign == 1 or node.sign == -1)
        and type(node.mantissa) == "number"
        and type(node.exponent) == "string"
    then
        return NumberFormatterFactory.formatScientific(node.sign, node.mantissa, node.exponent, options)
    end
    return api.toString(decoded)
end

function CodeNumValue.new(name: string, initial_value: unknown): StringValue
    if type(name) ~= "string" or name == "" then
        error("name must be a non-empty string", 2)
    end

    local value = Instance.new("StringValue")
    value.Name = name
    value.Value = CodeNumValue.normalize(initial_value)
    return value
end

local function expect_string_value(value: unknown): StringValue
    if typeof(value) ~= "Instance" or not (value :: Instance):IsA("StringValue") then
        error("backing_value must be a StringValue", 3)
    end
    return value :: StringValue
end

function CodeNumValue.get(value: StringValue): Value
    local backing_value = expect_string_value(value)
    return CodeNumValue.decode(backing_value.Value)
end

function CodeNumValue.set(value: StringValue, number_value: unknown)
    local backing_value = expect_string_value(value)
    backing_value.Value = CodeNumValue.normalize(number_value)
end

return table.freeze(CodeNumValue)
