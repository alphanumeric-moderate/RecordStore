--!strict
--!optimize 2

local IntegerInfinityValue = {}

export type Rounding = "nearest" | "floor" | "ceil" | "trunc"

export type Options = {
	rounding: Rounding?,
}

local function resolve_rounding(value: unknown): Rounding
	if value == nil or value == "nearest" then
		return "nearest"
	end

	if value == "floor" then return "floor" end
	if value == "ceil" then return "ceil" end
	if value == "trunc" then return "trunc" end

	error('rounding must be "nearest", "floor", "ceil", or "trunc"', 3)
end

local function normalize(value: number, rounding: Rounding): number
	if math.isnan(value) then
		return value
	end

	if math.isinf(value) then
		return value
	end

	if value == 0 then
		return 0
	end

	local result: number
	if rounding == "nearest" then
		result = math.round(value)
	elseif rounding == "floor" then
		result = math.floor(value)
	elseif rounding == "ceil" then
		result = math.ceil(value)
	else
		result = if value < 0 then math.ceil(value) else math.floor(value)
	end

	return if result == 0 then 0 else result
end

function IntegerInfinityValue.normalize(value: number, rounding: Rounding?): number
	if type(value) ~= "number" then
		error("value must be a number", 2)
	end

	return normalize(value, resolve_rounding(rounding))
end

function IntegerInfinityValue.new(
	name: string,
	initial_value: number?,
	options: Options?
): NumberValue
	if type(name) ~= "string" then
		error("name must be a string", 2)
	end

	if initial_value ~= nil and type(initial_value) ~= "number" then
		error("initial_value must be a number", 2)
	end

	if options ~= nil and type(options) ~= "table" then
		error("options must be a table", 2)
	end

	local rounding: Rounding = resolve_rounding(
		if options == nil then nil else options.rounding
	)

	local value = Instance.new("NumberValue")
	value.Name = name
	value.Value = normalize(
		if initial_value == nil then 0 else initial_value,
		rounding
	)

	local resolving = false
	local connection: RBXScriptConnection? = nil

	connection = value.Changed:Connect(function(current: number)
		if resolving then
			return
		end

		local resolved = normalize(current, rounding)
		local negative_zero = current == 0 and 1 / current == -math.huge
		local unchanged = current == resolved
			or (math.isnan(current) and math.isnan(resolved))

		if unchanged and not negative_zero then
			return
		end

		resolving = true
		local ok, error_value = pcall(function()
			value.Value = resolved
		end)
		resolving = false

		if not ok then
			error(error_value, 0)
		end
	end)

	value.Destroying:Connect(function()
		if connection ~= nil then
			connection:Disconnect()
			connection = nil
		end
	end)

	return value
end

return table.freeze(IntegerInfinityValue)
