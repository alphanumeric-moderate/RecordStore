--!strict
--!optimize 2

-- EternityNumValue
-- JSON-safe adapter for the classic FoundForces EternityNum triplet.
-- RecordStore persists the triplet array; StringValue stores only its transport encoding.

local HttpService = game:GetService("HttpService")
local EternityNumValue = {}

export type Value = { number, number, number }

local function normalize(value: unknown): Value
	if type(value) ~= "table" then
		error("EternityNum value must be a three-number table", 3)
	end

	local triplet = value :: { [number]: unknown }
	local sign = triplet[1]
	local layer = triplet[2]
	local magnitude = triplet[3]

	if type(sign) ~= "number"
		or not math.isfinite(sign)
		or (sign ~= -1 and sign ~= 0 and sign ~= 1)
	then
		error("EternityNum sign must be -1, 0, or 1", 3)
	end
	if type(layer) ~= "number"
		or not math.isfinite(layer)
		or layer < 0
		or math.floor(layer) ~= layer
	then
		error("EternityNum layer must be a finite non-negative integer", 3)
	end
	if type(magnitude) ~= "number" or not math.isfinite(magnitude) then
		error("EternityNum magnitude must be finite", 3)
	end

	local count = 0
	for key in pairs(triplet) do
		if type(key) ~= "number"
			or key < 1
			or key > 3
			or math.floor(key) ~= key
		then
			error("EternityNum value must not contain extra fields", 3)
		end
		count += 1
	end
	if count ~= 3 then
		error("EternityNum value must contain exactly three components", 3)
	end

	return { sign, layer, magnitude }
end

function EternityNumValue.normalize(value: unknown): Value
	return normalize(value)
end

function EternityNumValue.is_valid(value: unknown): boolean
	local ok = pcall(normalize, value)
	return ok
end

function EternityNumValue.equals(left: unknown, right: unknown): boolean
	if not EternityNumValue.is_valid(left) or not EternityNumValue.is_valid(right) then
		return false
	end
	local a = normalize(left)
	local b = normalize(right)
	return a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

function EternityNumValue.encode(value: unknown): string
	return HttpService:JSONEncode(normalize(value))
end

function EternityNumValue.decode(serialized_value: string): Value
	if type(serialized_value) ~= "string" then
		error("serialized EternityNum value must be a string", 2)
	end
	return normalize(HttpService:JSONDecode(serialized_value))
end

function EternityNumValue.new(name: string, initial_value: unknown): StringValue
	if type(name) ~= "string" or name == "" then
		error("name must be a non-empty string", 2)
	end
	local backing_value = Instance.new("StringValue")
	backing_value.Name = name
	backing_value.Value = EternityNumValue.encode(initial_value)
	return backing_value
end

function EternityNumValue.get(backing_value: StringValue): Value
	if not backing_value:IsA("StringValue") then
		error("backing_value must be a StringValue", 2)
	end
	return EternityNumValue.decode(backing_value.Value)
end

function EternityNumValue.set(backing_value: StringValue, value: unknown)
	if not backing_value:IsA("StringValue") then
		error("backing_value must be a StringValue", 2)
	end
	backing_value.Value = EternityNumValue.encode(value)
end

return table.freeze(EternityNumValue)
