--!nocheck

local Shim = require("./alyanum_shim")
local AlyaNumValue, AlyaNum, Formatter = Shim.load_alyanum_value()
local serde = require("@lune/serde")

local high = AlyaNum.new(10):pow(1000)
local payload = AlyaNumValue.encode(high)
local envelope = serde.decode("json", payload)
assert(envelope.schema == "AlyaNumValue" and envelope.version == 1)
assert(envelope.value.kind == "number")
local restored = AlyaNumValue.decode(payload)
assert(AlyaNum.toString(restored) == AlyaNum.toString(high))

local special = AlyaNumValue.normalize(math.huge)
assert(AlyaNumValue.format(special) == "Infinity")
assert(AlyaNumValue.format(AlyaNumValue.normalize(-math.huge)) == "-Infinity")
assert(AlyaNumValue.format(AlyaNumValue.normalize(0 / 0)) == "NaN")

local old_value = serde.encode("json", {
	schema = "InfiniteMathValue",
	version = 1,
	value = { kind = "number", first = 1, second = 12 },
})
local migrated = AlyaNumValue.normalize(old_value)
local migrated_envelope = serde.decode("json", migrated)
assert(migrated_envelope.schema == "AlyaNumValue")
assert(AlyaNumValue.format(migrated) == "1T")

local old_integer = '{"schema":"CodeNum","version":2,"value":{"kind":"integer","sign":1,"digits":"123456789012345678901234567890"}}'
local converted = AlyaNumValue.normalize(old_integer)
assert(serde.decode("json", converted).schema == "AlyaNumValue")

local function legacy_integer(sign, digits)
	return serde.encode("json", {
		schema = "CodeNum", version = 2,
		value = { kind = "integer", sign = sign, digits = digits },
	})
end

-- Values in the native exact range must not lose their 16th digit.
for _, sign in { 1, -1 } do
	local digits = "1234567890123456"
	local migrated_number = AlyaNumValue.decode(legacy_integer(sign, digits))
	assert(AlyaNum.toNumber(migrated_number) == sign * tonumber(digits))
	assert(AlyaNum.toNumber(AlyaNumValue.decode(legacy_integer(sign, "0000"))) == 0)
end
-- At 308 digits the native conversion path should match AlyaNum.new exactly.
local finite_digits = "12345678901234567" .. string.rep("0", 291)
local finite_value = AlyaNumValue.decode(legacy_integer(-1, finite_digits))
local finite_expected = AlyaNum.new(-tonumber(finite_digits))
assert(finite_value.sign == finite_expected.sign and finite_value.exponent == finite_expected.exponent
	and finite_value.multiplicand == finite_expected.multiplicand)
-- Beyond the native range, keep 17 leading digits in the mantissa/exponent path.
local huge_digits = "12345678901234567" .. string.rep("0", 292)
local huge_value = AlyaNumValue.decode(legacy_integer(1, huge_digits))
local huge_expected = AlyaNum.new(tonumber(string.sub(huge_digits, 1, 17)) / 1e16) * AlyaNum.new(10):pow(308)
assert(huge_value.sign == huge_expected.sign and huge_value.exponent == huge_expected.exponent
	and huge_value.multiplicand == huge_expected.multiplicand)

-- Formatting an unconvertible symbolic node uses the same integer conversion.
local symbolic = serde.encode("json", { schema = "CodeNum", version = 2, value = {
	kind = "hyper", base = { kind = "integer", sign = -1, digits = "1234567890123456" },
	arrows = { kind = "integer", sign = 1, digits = "100" }, height = { kind = "finite", value = 10 },
} })
assert(AlyaNumValue.format(symbolic) == "(" .. Formatter.format(-1234567890123456) .. ")↑{100}(10)")
local symbolic_zero = serde.encode("json", { schema = "CodeNum", version = 2, value = {
	kind = "hyper", base = { kind = "integer", sign = -1, digits = "000" },
	arrows = { kind = "integer", sign = 1, digits = "100" }, height = { kind = "finite", value = 10 },
} })
assert(AlyaNumValue.format(symbolic_zero, { decimals = 2, trim_trailing_zeros = false }) == "(0)↑{100}(10.00)")

for _, schema in { "AlyaNumValue", "InfiniteMathValue", "CodeNum" } do
	local supported = if schema == "CodeNum" then 2 else 1
	for _, version in { supported - 1, supported, supported + 1 } do
		local candidate = serde.encode("json", { schema = schema, version = version, value = {} })
		assert(AlyaNumValue.is_unsupported_version(candidate) == (version ~= supported))
	end
end
assert(not AlyaNumValue.is_unsupported_version('{"schema":"unknown","version":99}'))
assert(not AlyaNumValue.is_unsupported_version('{"schema":"CodeNum","version":"3"}'))

-- Exercise PlayerDataCore's existing fail-closed load path with the real adapter.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local core_source = fs.readFile("src/PlayerDataInitializer/PlayerDataCore.luau")
local count
core_source, count = string.gsub(core_source, 'admin = define_data_field%("BoolValue", false%),',
	'admin = define_data_field("BoolValue", false), cash = define_data_field("AlyaNumValue", 0),', 1)
assert(count == 1)
core_source, count = string.gsub(core_source, "return table.freeze%(%{%s*new = new,%s*%}%s*%)%s*$",
	"return { validate = validate_player_data, decode = decode_stored_field_value }", 1)
assert(count == 1)
local core_modules = { RecordStore = {}, IntegerInfinityValue = {}, AlyaNumValue = {} }
local core = luau.load(core_source, { environment = {
	game = { GetService = function() return {} end },
	script = { Parent = core_modules },
	require = function(target)
		if target == core_modules.IntegerInfinityValue then return { normalize = function(value) return value end } end
		if target == core_modules.AlyaNumValue then return AlyaNumValue end
		return {}
	end,
} })()
local future_code = '{"schema":"CodeNum","version":3,"value":{"kind":"finite","value":42}}'
assert(core.validate({ cash = future_code }, AlyaNumValue), "future payload must reach the load guard")
local load_ok, load_error = pcall(core.decode, { class_name = "AlyaNumValue" }, future_code, nil, AlyaNumValue)
assert(not load_ok and string.find(tostring(load_error), "unsupported codec version", 1, true),
	"unsupported CodeNum data must not be replaced with the default")
local supported_code = '{"schema":"CodeNum","version":2,"value":{"kind":"finite","value":42}}'
local loaded, changed = core.decode({ class_name = "AlyaNumValue" }, supported_code, nil, AlyaNumValue)
assert(changed and AlyaNum.toNumber(AlyaNumValue.decode(loaded)) == 42)

local old_hyper = '{"schema":"CodeNum","version":2,"value":{"kind":"hyper","base":{"kind":"finite","value":10},"arrows":{"kind":"integer","sign":1,"digits":"100"},"height":{"kind":"finite","value":10}}}'
assert(AlyaNumValue.normalize(old_hyper) == old_hyper)
assert(string.find(AlyaNumValue.format(old_hyper), "↑{100}", 1, true) ~= nil)

local future = '{"schema":"AlyaNumValue","version":99,"value":{}}'
assert(AlyaNumValue.is_unsupported_version(future))
assert(not AlyaNumValue.is_serialized(future))
assert(not pcall(function() AlyaNumValue.normalize(future) end))

print("[AlyaNumValue] persistence and legacy conversion regressions passed")
