--!nocheck
-- CodSpeed scenario: legacy CodeNum migration and verbatim preservation.

local Shim = require("./codenum_shim")
local CodeNumValue, CodeNum = Shim.load_codenum_value()
local serde = require("@lune/serde")

local function legacy(value)
	return serde.encode("json", {
		schema = "CodeNum",
		version = 2,
		value = value,
	})
end

local function integer(sign, digits)
	return { kind = "integer", sign = sign, digits = digits }
end

local function finite(value)
	return { kind = "finite", value = value }
end

local function expression(op, left, right)
	return legacy({ kind = "expression", op = op, left = left, right = right })
end

-- Maximum-width import correctness is asserted in run_codenumvalue_regression_tests.luau.
local legacy_payloads = {
	{
		label = "integer above binary64 safe range",
		payload = legacy(integer(1, "9007199254740993")),
		preserve = false,
		expected_value = CodeNum.fromInteger("9007199254740993"),
	},
	{
		label = "exact expression",
		payload = expression("add", finite(1), finite(2)),
		preserve = false,
		expected_value = 3,
	},
	{
		label = "inexact expression",
		payload = expression("div", integer(1, "1"), integer(1, "3")),
		preserve = true,
	},
	{
		label = "nested inexact expression",
		payload = expression("add", {
			kind = "expression",
			op = "div",
			left = integer(1, "1"),
			right = integer(1, "3"),
		}, finite(1)),
		preserve = true,
	},
	{
		label = "current CN1 envelope",
		payload = CodeNumValue.encode(CodeNum.fromScientific(1.25, "1000")),
		preserve = true,
		expected_value = CodeNum.fromScientific(1.25, "1000"),
	},
	{
		label = "current CN2 envelope",
		payload = CodeNumValue.encode(CodeNum.fromInteger("9007199254740993")),
		preserve = true,
		expected_value = CodeNum.fromInteger("9007199254740993"),
	},
}

for _ = 1, 10 do
	for _, case in ipairs(legacy_payloads) do
		local normalized = CodeNumValue.normalize(case.payload)
		assert((normalized == case.payload) == case.preserve,
			"legacy migration changed its expected preserve-or-migrate decision: " .. case.label)
		if case.expected_value ~= nil then
			local actual = CodeNumValue.decode(normalized)
			assert(CodeNum.compare(actual, case.expected_value) == 0,
				"legacy migration changed the exact numeric value: " .. case.label)
		end
	end
end

print("[CodeNumValue migration] exact imports and conservative preservation passed")
