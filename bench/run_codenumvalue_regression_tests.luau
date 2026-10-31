--!nocheck
local Shim = require("./codenum_shim")
local CodeNumValue, CodeNum = Shim.load_codenum_value()
local serde = require("@lune/serde")

local large = CodeNum.fromScientific(1.25, "1000")
local payload = CodeNumValue.encode(large)
local envelope = serde.decode("json", payload)
assert(envelope.schema == "CodeNumValue" and envelope.version == 1)
assert(envelope.value == CodeNum.encode(large))
assert(CodeNum.toString(CodeNumValue.decode(payload)) == CodeNum.toString(large))
assert(CodeNumValue.normalize(payload) == payload, "canonical serialization was not stable")
assert(CodeNumValue.is_serialized(payload), "current payload was not recognized")

assert(CodeNumValue.format(CodeNumValue.normalize(1_250)) == "1.25K")
assert(CodeNumValue.format(CodeNumValue.normalize(math.huge)) == "Infinity")
assert(CodeNumValue.format(CodeNumValue.normalize(-math.huge)) == "-Infinity")
assert(CodeNumValue.format(CodeNumValue.normalize(0 / 0)) == "NaN")
assert(CodeNumValue.format(payload) == "1.25e1000")

local precise_integer_text = "123456789012345678901234567890"
local precise_integer = CodeNum.fromInteger(precise_integer_text)
assert(CodeNum.isPrecise(precise_integer), "fromInteger did not retain precise storage")
local precise_payload = CodeNumValue.encode(precise_integer)
local precise_envelope = serde.decode("json", precise_payload)
assert(string.match(precise_envelope.value, "^CN2|P|") ~= nil, "CodeNumValue did not persist the CN2 codec")
assert(CodeNum.toString(CodeNumValue.decode(precise_payload)) == precise_integer_text,
	"CodeNumValue CN2 round-trip changed exact decimal digits")
assert(CodeNumValue.normalize(precise_payload) == precise_payload, "CN2 canonical serialization was not stable")
assert(CodeNumValue.format(precise_payload) == CodeNumValue.format(precise_integer),
	"CodeNumValue did not format a persisted precise value")

local precise_backing = CodeNumValue.new("PreciseCash", precise_integer)
assert(CodeNum.toString(CodeNumValue.get(precise_backing)) == precise_integer_text,
	"StringValue backing lost precise decimal digits")
CodeNumValue.set(precise_backing, CodeNum.add(precise_integer, 1))
assert(CodeNum.toString(CodeNumValue.get(precise_backing)) == "123456789012345678901234567891",
	"StringValue set/get lost precise integer addition")
precise_backing:Destroy()

local backing = CodeNumValue.new("Cash", large)
assert(backing.Name == "Cash")
assert(CodeNum.compare(CodeNumValue.get(backing), large) == 0)
CodeNumValue.set(backing, CodeNum.mul(large, 2))
assert(CodeNum.compare(CodeNumValue.get(backing), CodeNum.mul(large, 2)) == 0)

local old_alyanum = serde.encode("json", {
	schema = "AlyaNumValue",
	version = 1,
	value = {
		kind = "number",
		value = {
			sign = 1, multiplicand = 1.25, exponent = 1,
			tetrate = 0, pentate = 0, hexate = 0, heptate = 0,
		},
	},
})
local alyanum_migrated = CodeNumValue.normalize(old_alyanum)
assert(serde.decode("json", alyanum_migrated).schema == "CodeNumValue")
assert(CodeNum.toNumber(CodeNumValue.decode(alyanum_migrated)) > 17
	and CodeNum.toNumber(CodeNumValue.decode(alyanum_migrated)) < 18)

local old_alyanum_hyper = serde.encode("json", {
	schema = "AlyaNumValue",
	version = 1,
	value = {
		kind = "number",
		value = {
			sign = 1, multiplicand = 10, exponent = 2,
			tetrate = 1, pentate = 0, hexate = 0, heptate = 0,
		},
	},
})
assert(CodeNumValue.is_serialized(old_alyanum_hyper))
assert(CodeNumValue.normalize(old_alyanum_hyper) == old_alyanum_hyper,
	"unrepresentable AlyaNum values must be preserved verbatim")

local old_infinitemath = serde.encode("json", {
	schema = "InfiniteMathValue",
	version = 1,
	value = { kind = "number", first = 1.25, second = 12 },
})
local infinitemath_migrated = CodeNumValue.normalize(old_infinitemath)
assert(CodeNum.toNumber(CodeNumValue.decode(infinitemath_migrated)) == 1.25e12)

local old_code_integer = serde.encode("json", {
	schema = "CodeNum",
	version = 2,
	value = { kind = "integer", sign = 1, digits = "123456789012345678901234567890" },
})
assert(CodeNumValue.is_serialized(old_code_integer))
local migrated_old_code_integer = CodeNumValue.normalize(old_code_integer)
assert(migrated_old_code_integer ~= old_code_integer, "legacy exact integer was not migrated")
assert(CodeNum.isPrecise(CodeNumValue.decode(migrated_old_code_integer)),
	"legacy exact integer did not use precise storage")
assert(CodeNum.toString(CodeNumValue.decode(migrated_old_code_integer))
	== "123456789012345678901234567890", "legacy exact integer migration rounded decimal digits")

local safe_old_integer = serde.encode("json", {
	schema = "CodeNum",
	version = 2,
	value = { kind = "integer", sign = 1, digits = "9007199254740992" },
})
local safe_migrated = CodeNumValue.normalize(safe_old_integer)
assert(serde.decode("json", safe_migrated).schema == "CodeNumValue")
assert(CodeNum.compare(CodeNumValue.decode(safe_migrated), 9007199254740992) == 0)

local rounded_old_integer = serde.encode("json", {
	schema = "CodeNum",
	version = 2,
	value = { kind = "integer", sign = 1, digits = "9007199254740993" },
})
local rounded_migrated = CodeNumValue.normalize(rounded_old_integer)
assert(rounded_migrated ~= rounded_old_integer, "exact integer above 2^53 was not migrated")
assert(CodeNum.toString(CodeNumValue.decode(rounded_migrated)) == "9007199254740993",
	"legacy integer above 2^53 was rounded during migration")

local function legacy_expression(op, left, right)
	return serde.encode("json", {
		schema = "CodeNum", version = 2,
		value = { kind = "expression", op = op, left = left, right = right },
	})
end
local function integer(sign, digits)
	return { kind = "integer", sign = sign, digits = digits }
end
local function finite(value)
	return { kind = "finite", value = value }
end

local exact_expression_cases = {
	{
		legacy_expression("add", integer(1, "9007199254740992"), finite(1)),
		"9007199254740993",
	},
	{
		legacy_expression("sub", integer(-1, "9007199254740992"), finite(1)),
		"-9007199254740993",
	},
	{
		legacy_expression("mul", integer(1, "4503599627370496"), finite(2)),
		"9007199254740992",
	},
	{
		legacy_expression("add", {
			kind = "expression", op = "add",
			left = integer(1, "9007199254740992"), right = finite(1),
		}, finite(-1)),
		"9007199254740992",
	},
}
for _, case in exact_expression_cases do
	local expression = case[1]
	local expected = case[2]
	local migrated = CodeNumValue.normalize(expression)
	assert(migrated ~= expression, "exact legacy integer expression was not migrated")
	assert(CodeNum.toString(CodeNumValue.decode(migrated)) == expected,
		"precise legacy expression migration changed its exact result")
end
for _, expression in {
	legacy_expression("pow", finite(2), finite(53)),
	legacy_expression("mul", { kind = "scientific", sign = 1, mantissa = 1.25, exponent = "1000" }, finite(2)),
	legacy_expression("mul", { kind = "scientific", sign = -1, mantissa = 1.25, exponent = "1000" }, finite(2)),
} do
	assert(CodeNumValue.normalize(expression) == expression,
		"binary64 or Wide legacy expression was migrated without exact significand evidence")
end
local safe_expression = legacy_expression("add", integer(1, "9007199254740990"), finite(1))
assert(CodeNum.compare(CodeNumValue.decode(CodeNumValue.normalize(safe_expression)), 9007199254740991) == 0)
local fractional_expression = legacy_expression("div", finite(5), finite(2))
assert(CodeNum.compare(CodeNumValue.decode(CodeNumValue.normalize(fractional_expression)), 2.5) == 0)
local wide_fraction = legacy_expression("mul", { kind = "scientific", sign = 1, mantissa = 1.25, exponent = "-1000" }, finite(2))
assert(CodeNum.compare(CodeNumValue.decode(CodeNumValue.normalize(wide_fraction)), CodeNum.fromScientific(2.5, "-1000")) == 0)
local special_expression = legacy_expression("div", finite(1), finite(0))
assert(CodeNumValue.decode(CodeNumValue.normalize(special_expression)) == math.huge)

local function legacy_call(op, value)
	return serde.encode("json", {
		schema = "CodeNum", version = 2,
		value = { kind = "call", op = op, value = value },
	})
end

local repeating_division = legacy_expression("div", integer(1, "1"), integer(1, "3"))
assert(CodeNumValue.normalize(repeating_division) == repeating_division,
	"repeating precise division was migrated after losing decimal digits")

local power_3000 = {
	kind = "expression", op = "pow",
	left = integer(1, "9"), right = finite(3000),
}
local overflowing_product = legacy_expression("mul", power_3000, power_3000)
assert(CodeNumValue.normalize(overflowing_product) == overflowing_product,
	"multiplication beyond 4096 significant digits was migrated after rounding")

local nested_repeating = legacy_expression("add", {
	kind = "expression", op = "div",
	left = integer(1, "1"), right = integer(1, "3"),
}, finite(1))
assert(CodeNumValue.normalize(nested_repeating) == nested_repeating,
	"an inexact child expression was hidden by its parent")

local binary64_sum = legacy_expression("add", finite(0.1), finite(0.2))
assert(CodeNumValue.normalize(binary64_sum) == binary64_sum,
	"binary64 addition with a rounded decimal result was migrated as exact")

local fractional_power = legacy_expression("pow", finite(2), finite(0.5))
assert(CodeNumValue.normalize(fractional_power) == fractional_power,
	"fractional power was migrated without an exact decimal result")

local approximate_logarithm = legacy_call("log10", finite(2))
assert(CodeNumValue.normalize(approximate_logarithm) == approximate_logarithm,
	"approximate logarithm was migrated as an exact value")
local exact_logarithm = legacy_call("log10", integer(1, "1000"))
local exact_logarithm_migrated = CodeNumValue.normalize(exact_logarithm)
assert(exact_logarithm_migrated ~= exact_logarithm
	and CodeNum.toString(CodeNumValue.decode(exact_logarithm_migrated)) == "3",
	"exact power-of-ten logarithm was not migrated")

local failed_expression = legacy_expression("unsupported", finite(1), finite(2))
assert(CodeNumValue.normalize(failed_expression) == failed_expression)

local function legacy_hyper(base, arrows, height)
	return serde.encode("json", {
		schema = "CodeNum", version = 2,
		value = { kind = "hyper", base = base, arrows = finite(arrows), height = finite(height) },
	})
end
for _, hyper in {
	legacy_hyper(finite(1000001), 1, 3),
	legacy_hyper(finite(-1000001), 1, 3),
	legacy_hyper({ kind = "scientific", sign = 1, mantissa = 1.25, exponent = "1000" }, 1, 1),
	legacy_hyper(finite(16), 2, 2),
} do
	assert(CodeNumValue.normalize(hyper) == hyper, "unsafe integer hyperoperation was migrated")
end
for _, case in { { 1, 16 }, { 2, 256 } } do
	local hyper = legacy_hyper(finite(4), case[1], 2)
	assert(CodeNum.compare(CodeNumValue.decode(CodeNumValue.normalize(hyper)), case[2]) == 0)
end
local wide_hyper_fraction = legacy_hyper({ kind = "scientific", sign = 1, mantissa = 1.25, exponent = "-1000" }, 1, 1)
assert(CodeNum.compare(CodeNumValue.decode(CodeNumValue.normalize(wide_hyper_fraction)), CodeNum.fromScientific(1.25, "-1000")) == 0)

local old_code_hyper = serde.encode("json", {
	schema = "CodeNum",
	version = 2,
	value = {
		kind = "hyper",
		base = { kind = "finite", value = 10 },
		arrows = { kind = "integer", sign = 1, digits = "100" },
		height = { kind = "finite", value = 10 },
	},
})
assert(CodeNumValue.is_serialized(old_code_hyper))
assert(CodeNumValue.normalize(old_code_hyper) == old_code_hyper,
	"unsupported symbolic CodeNum values must be preserved")
assert(string.find(CodeNumValue.format(old_code_hyper), "↑{100}", 1, true))

local future = '{"schema":"CodeNumValue","version":99,"value":"CN1|N|1"}'
assert(CodeNumValue.is_unsupported_version(future))
assert(not CodeNumValue.is_serialized(future))
assert(not pcall(function() CodeNumValue.normalize(future) end),
	"future CodeNumValue format version was accepted")
local future_legacy = '{"schema":"CodeNum","version":99,"value":{}}'
assert(CodeNumValue.is_unsupported_version(future_legacy))

local create_harness = require("./playerdata_set_harness")
for _, future_payload in { future, future_legacy } do
	local harness = create_harness(true, {
		kills = 41, equipped = "Default", admin = true, cash = future_payload,
	}, { CodeNumValue = CodeNumValue }, true, true)
	assert(harness.controller:Start(), "future-version controller failed to start")
	local deadline = os.clock() + 5
	while harness.player:GetAttribute("PlayerDataLoadStatus") ~= "Failed"
		and harness.player:GetAttribute("PlayerDataLoadStatus") ~= "Loaded"
		and os.clock() < deadline do
		harness.task.wait(0.01)
	end
	local record = harness.get_record()
	local saved_key = "PlayerData_Test1|global|Player_" .. tostring(harness.player.UserId)
	assert(record ~= nil and harness.get_record_options().validator(harness.saved_records[saved_key]),
		"recognized future version should pass the stored-data validator")
	assert(harness.player:GetAttribute("PlayerDataLoadStatus") == "Failed" and harness.player._kick_message ~= nil,
		"future-version player load must fail closed")
	assert(record._update_calls == 0 and harness.saved_records[saved_key].cash == future_payload,
		"future-version payload was replaced by a default or written during load")
	assert(record.State == "closed", "failed future-version session was not closed")
	assert(harness.controller:Shutdown(), "future-version controller failed to shut down")
end

local previous = backing.Value
assert(not pcall(function() CodeNumValue.set(backing, {}) end))
assert(backing.Value == previous, "invalid assignment changed a valid stored value")
assert(not pcall(function() CodeNumValue.get({}) end), "non-StringValue backing instance was accepted")

print("[CodeNumValue] persistence, migration, legacy preservation, and StringValue regressions passed")
