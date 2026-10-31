--!nocheck
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local CodeNum = luau.load(fs.readFile("src/CodeNum/init.luau"), {
	debugName = "CodeNumRegression",
})()

assert(type(CodeNum.fromInteger) == "function", "exact integer constructor is missing")
assert(CodeNum.MAX_EXPONENT == "1" .. string.rep("0", 308), "maximum exponent changed")
assert(CodeNum.toNumber(CodeNum.parse("1.25")) == 1.25)
assert(CodeNum.toNumber(CodeNum.parse("-0.125")) == -0.125)
assert(CodeNum.toNumber(CodeNum.parse("0.0000005")) == 0.0000005)

local huge = CodeNum.fromScientific(1.25, "1000")
assert(CodeNum.isWide(huge), "large scientific value was not stored as Wide")
assert(CodeNum.toString(huge) == "1.25e1000")
assert(CodeNum.toNumber(huge) == math.huge)

local doubled = CodeNum.add(huge, huge)
assert(CodeNum.toString(doubled) == "2.5e1000")
assert(CodeNum.compare(doubled, huge) == 1)
assert(CodeNum.compare(CodeNum.sub(doubled, huge), huge) == 0)
assert(CodeNum.compare(CodeNum.div(CodeNum.mul(huge, 10), 10), huge) == 0)
assert(CodeNum.toString(CodeNum.pow(huge, 2)) == "1.5625e2000")

local huge_exponent = CodeNum.fromScientific(1, "9007199254740992")
local advanced_exponent = CodeNum.mul(huge_exponent, 10)
assert(CodeNum.toString(advanced_exponent) == "1e9007199254740993",
	"large decimal exponent arithmetic lost integer precision")

local smallest = CodeNum.parse("5e-324")
assert(CodeNum.toNumber(smallest) == 5e-324, "smallest subnormal conversion failed")

local max_value = CodeNum.fromScientific(1, CodeNum.MAX_EXPONENT)
assert(CodeNum.toString(max_value) == "1e" .. CodeNum.MAX_EXPONENT)
assert(not pcall(function() CodeNum.fromScientific(1.01, CodeNum.MAX_EXPONENT) end),
	"value above the configured maximum was accepted")
assert(not pcall(function() CodeNum.fromScientific(1, CodeNum.MAX_EXPONENT .. "1") end),
	"exponent above 10^308 was accepted")

for _, value in { huge, doubled, CodeNum.parse("-1.25e-1000"), math.huge, -math.huge, 0 / 0 } do
	local decoded = CodeNum.decode(CodeNum.encode(value))
	if type(value) == "number" and value ~= value then
		assert(decoded ~= decoded, "NaN codec round-trip failed")
	else
		assert(CodeNum.compare(value, decoded) == 0, "CodeNum codec round-trip changed a value")
	end
end

local register = CodeNum.createRegister()
CodeNum.addInto(register, huge, huge)
assert(CodeNum.compare(CodeNum.readRegister(register), doubled) == 0,
	"allocation-free register addition changed the result")
CodeNum.mulInto(register, huge, 2)
assert(CodeNum.compare(CodeNum.readRegister(register), doubled) == 0,
	"allocation-free register multiplication changed the result")
CodeNum.divInto(register, doubled, 2)
assert(CodeNum.compare(CodeNum.readRegister(register), huge) == 0,
	"allocation-free register division changed the result")
assert(CodeNum.compare(0 / 0, 0) == nil, "NaN comparison must remain unordered")


assert(type(CodeNum.fromInteger) == "function", "exact integer constructor is missing")
assert(CodeNum.VERSION == "0.6.0", "wrong CodeNum version")
assert(CodeNum.MAX_PRECISE_DIGITS == 4096, "precise coefficient limit changed")
assert(CodeNum.DEFAULT_DIVISION_PRECISION == 34, "division precision default changed")

local exact_integer = CodeNum.fromInteger("9007199254740993")
assert(CodeNum.isPrecise(exact_integer), "unsafe decimal integer was not stored precisely")
assert(not CodeNum.isWide(exact_integer), "precise values must not be reported as Wide")
assert(CodeNum.toString(exact_integer) == "9007199254740993", "unsafe integer parsing lost decimal digits")
assert(CodeNum.compare(exact_integer, 9007199254740992) == 1, "precise/native comparison lost the unit difference")
assert(CodeNum.toString(CodeNum.add(exact_integer, 1)) == "9007199254740994", "precise addition rounded the integer")
assert(CodeNum.toString(CodeNum.sub(exact_integer, 1)) == "9007199254740992", "precise subtraction rounded the integer")
assert(CodeNum.toString(CodeNum.mul(exact_integer, 10)) == "90071992547409930", "precise multiplication rounded the integer")

local long_decimal_text = "1.2345678901234567890123456789012345"
local long_decimal = CodeNum.parse(long_decimal_text)
assert(CodeNum.isPrecise(long_decimal), "long decimal text did not select precise storage")
assert(CodeNum.toString(long_decimal) == long_decimal_text, "long decimal parsing lost input digits")
assert(CodeNum.toString(CodeNum.parse("1.245", 3)) == "1.24", "half-even tie rounded an even digit upward")
assert(CodeNum.toString(CodeNum.parse("1.255", 3)) == "1.26", "half-even tie failed to round an odd digit upward")
assert(CodeNum.toString(CodeNum.parse("1.999", 2)) == "2", "precision carry did not renormalize the exponent")

local one = CodeNum.withPrecision(1, 34)
local three = CodeNum.fromInteger("3")
local one_third = CodeNum.div(one, three)
assert(CodeNum.isPrecise(one_third), "division did not retain precise storage")
assert(CodeNum.toString(one_third) == "0." .. string.rep("3", 34), "34-digit division rounding changed")
assert(CodeNum.toString(CodeNum.div(one, CodeNum.fromInteger("-3"), 34))
	== "-0." .. string.rep("3", 34), "negative precise division changed sign")
assert(CodeNum.toString(CodeNum.div(CodeNum.fromInteger("1"), CodeNum.fromInteger("8"), 34)) == "0.125",
	"terminating precise division did not trim trailing zeros")
assert(CodeNum.toString(CodeNum.pow(CodeNum.fromInteger("2"), -3)) == "0.125",
	"negative precise integer power failed")

local product = CodeNum.mul(CodeNum.fromInteger("123456789"), CodeNum.fromInteger("987654321"))
assert(CodeNum.toString(product) == "121932631112635269", "precise coefficient multiplication is incorrect: " .. CodeNum.toString(product))
assert(CodeNum.toString(CodeNum.pow(CodeNum.fromInteger("123456"), 2)) == "15241383936",
	"precise integer power is incorrect")

local precise_payload = CodeNum.encode(long_decimal)
assert(string.match(precise_payload, "^CN2|P|") ~= nil, "precise values did not use the CN2 codec")
local precise_decoded = CodeNum.decode(precise_payload)
assert(CodeNum.isPrecise(precise_decoded), "CN2 decoding did not restore precise storage")
assert(CodeNum.toString(precise_decoded) == long_decimal_text, "CN2 round-trip lost decimal digits")
assert(CodeNum.compare(CodeNum.abs(CodeNum.parse("-" .. long_decimal_text)), long_decimal) == 0,
	"precise absolute value changed the coefficient")
assert(CodeNum.sign(CodeNum.parse("-" .. long_decimal_text)) == -1, "precise sign was incorrect")
assert(CodeNum.log10(CodeNum.fromInteger("1000")) == 3, "precise logarithm conversion changed")

local precise_register = CodeNum.createRegister()
CodeNum.addInto(precise_register, exact_integer, 1)
assert(CodeNum.isPrecise(precise_register), "precise register output lost its value kind")
CodeNum.addInto(precise_register, precise_register, 1)
assert(CodeNum.toString(CodeNum.readRegister(precise_register)) == "9007199254740995",
	"precise register input/output aliasing corrupted the result")
CodeNum.mulInto(precise_register, precise_register, 10)
assert(CodeNum.toString(CodeNum.readRegister(precise_register)) == "90071992547409950",
	"precise register multiplication changed the result")

assert(not pcall(function() CodeNum.parse("1", 0) end), "zero precision was accepted")
assert(not pcall(function() CodeNum.parse("1", 4097) end), "precision above the configured maximum was accepted")
assert(not pcall(function() CodeNum.fromInteger(string.rep("9", 4097)) end),
	"integer input above 4096 digits was accepted")
assert(not pcall(function() CodeNum.pow(long_decimal, 0.5) end),
	"fractional powers silently downcast a precise value")


local rounded_parse = CodeNum.parse("1.255", 2)
assert(CodeNum.wasRounded(rounded_parse), "precision truncation was not recorded")
assert(not CodeNum.wasRounded(CodeNum.fromInteger("1255")), "exact integer was marked rounded")
assert(CodeNum.wasRounded(CodeNum.div(CodeNum.fromInteger("1"), CodeNum.fromInteger("3"))),
	"repeating precise division was not marked rounded")
assert(not CodeNum.wasRounded(CodeNum.div(CodeNum.fromInteger("5"), CodeNum.fromInteger("2"), 34)),
	"terminating precise division was marked rounded")
assert(CodeNum.wasRounded(CodeNum.abs(rounded_parse)), "absolute value discarded rounding provenance")
assert(CodeNum.wasRounded(CodeNum.withPrecision(CodeNum.fromInteger("123456"), 3)),
	"precision reduction did not record rounding")
local rounded_product = CodeNum.mul(CodeNum.fromInteger(string.rep("9", 4096)), 9)
assert(CodeNum.wasRounded(rounded_product), "4097-digit multiplication did not record rounding")

local negative_zero_product = CodeNum.mul(-0.0, CodeNum.fromInteger("2"))
assert(negative_zero_product == 0 and 1 / negative_zero_product == -math.huge,
	"precise multiplication lost the sign of negative zero")
local negative_zero_quotient = CodeNum.div(-0.0, CodeNum.fromInteger("2"))
assert(negative_zero_quotient == 0 and 1 / negative_zero_quotient == -math.huge,
	"precise division lost the sign of negative zero")
local negative_zero_over_negative = CodeNum.div(0.0, CodeNum.fromInteger("-2"))
assert(negative_zero_over_negative == 0 and 1 / negative_zero_over_negative == -math.huge,
	"precise division did not derive zero sign from both operands")

local negative_precise = CodeNum.fromInteger("-1")
assert(CodeNum.div(negative_precise, 0.0) == -math.huge,
	"negative precise numerator divided by positive zero returned the wrong infinity")
assert(CodeNum.div(negative_precise, -0.0) == math.huge,
	"negative precise numerator divided by negative zero returned the wrong infinity")
assert(CodeNum.div(CodeNum.fromInteger("1"), -0.0) == -math.huge,
	"positive precise numerator divided by negative zero returned the wrong infinity")

local precise_special = CodeNum.fromInteger("9007199254740993")
assert(CodeNum.add(math.huge, precise_special) == math.huge,
	"positive infinity plus a precise value changed special-number semantics")
assert(CodeNum.sub(-math.huge, precise_special) == -math.huge,
	"negative infinity minus a precise value changed special-number semantics")
assert(CodeNum.mul(-math.huge, precise_special) == -math.huge,
	"infinity multiplication with a precise value changed sign")
local negative_zero_from_infinity = CodeNum.div(CodeNum.fromInteger("-1"), math.huge)
assert(negative_zero_from_infinity == 0 and 1 / negative_zero_from_infinity == -math.huge,
	"precise division by infinity did not preserve signed zero")
local mixed_nan = CodeNum.add(0 / 0, precise_special)
assert(mixed_nan ~= mixed_nan, "NaN plus a precise value did not remain NaN")


local negative_large = CodeNum.fromInteger("-9007199254740993")
local positive_large = CodeNum.fromInteger("9007199254740992")
assert(CodeNum.toString(CodeNum.add(negative_large, positive_large)) == "-1",
	"mixed-sign precise addition corrupted its result sign")
assert(CodeNum.add(exact_integer, CodeNum.fromInteger("-9007199254740993")) == 0,
	"exact precise cancellation did not produce zero")
assert(CodeNum.toString(CodeNum.sub(negative_large, positive_large)) == "-18014398509481985",
	"mixed-sign precise subtraction changed the exact result")

assert(CodeNum.toString(CodeNum.div(CodeNum.fromInteger("1"), CodeNum.fromInteger("8"), 2)) == "0.12",
	"half-even division did not round a tie toward an even last digit")
assert(CodeNum.toString(CodeNum.div(CodeNum.fromInteger("3"), CodeNum.fromInteger("8"), 2)) == "0.38",
	"half-even division did not round an odd last digit upward")
assert(CodeNum.toString(CodeNum.div(CodeNum.fromInteger("-1"), CodeNum.fromInteger("8"), 2)) == "-0.12",
	"negative half-even division changed its rounding direction")
assert(CodeNum.toString(CodeNum.div(CodeNum.fromInteger("-3"), CodeNum.fromInteger("8"), 2)) == "-0.38",
	"negative half-even division did not preserve half-even rounding")

local far_exponent = "1000000000000000000000000000000000000000"
local far_value = CodeNum.fromScientific(1, far_exponent)
local far_sum = CodeNum.add(far_value, 1, 34)
assert(CodeNum.toString(far_sum) == "1e" .. far_exponent,
	"addition with a distant exponent changed the dominant value")
assert(CodeNum.wasRounded(far_sum), "discarding a distant insignificant operand was not recorded")

local large_aligned_value = CodeNum.parse(string.rep("9", 4096), 4096)
local distant_small_value = CodeNum.parse("1e-5000", 4096)
local aligned_add_ok, aligned_add_result = pcall(function()
	return CodeNum.add(large_aligned_value, distant_small_value)
end)
assert(aligned_add_ok, "valid addition exceeded temporary capacity after coefficient alignment")
assert(CodeNum.toString(aligned_add_result) == CodeNum.toString(large_aligned_value),
	"adding a value beyond the selected precision changed the dominant coefficient")
assert(CodeNum.wasRounded(aligned_add_result),
	"discarding a value beyond the selected precision was not recorded")

local rounded_zero_product = CodeNum.mul(rounded_parse, 0)
assert(CodeNum.wasRounded(rounded_zero_product),
	"multiplication by zero discarded rounded arithmetic ancestry")
local rounded_zero_cancellation = CodeNum.sub(rounded_parse, rounded_parse)
assert(CodeNum.wasRounded(rounded_zero_cancellation),
	"exact cancellation discarded rounded arithmetic ancestry")
local encoded_rounded_zero = CodeNum.encode(rounded_zero_product)
assert(not CodeNum.wasRounded(CodeNum.decode(encoded_rounded_zero)),
	"runtime-only rounding provenance was unexpectedly serialized")

local negative_rounded = CodeNum.parse("-1.255", 2)
local negative_rounded_zero = CodeNum.mul(negative_rounded, 0)
assert(CodeNum.wasRounded(negative_rounded_zero),
	"negative zero result discarded rounded arithmetic ancestry")
assert(CodeNum.toString(negative_rounded_zero) == "-0",
	"precise negative zero string conversion lost its sign")
local negative_zero_number = CodeNum.toNumber(negative_rounded_zero)
assert(negative_zero_number == 0 and 1 / negative_zero_number == -math.huge,
	"precise rounded zero lost its negative sign during native conversion")
local negative_zero_power = CodeNum.toNumber(CodeNum.pow(negative_rounded_zero, 3))
assert(negative_zero_power == 0 and 1 / negative_zero_power == -math.huge,
	"odd integer power changed the sign of precise negative zero")
local positive_zero_power = CodeNum.toNumber(CodeNum.pow(negative_rounded_zero, 2))
assert(positive_zero_power == 0 and 1 / positive_zero_power == math.huge,
	"even integer power did not produce positive zero")
local negative_zero_precision = CodeNum.withPrecision(negative_rounded_zero, 12)
local negative_zero_precision_number = CodeNum.toNumber(negative_zero_precision)
assert(CodeNum.wasRounded(negative_zero_precision)
	and negative_zero_precision_number == 0
	and 1 / negative_zero_precision_number == -math.huge,
	"withPrecision did not preserve negative-zero provenance")

local rounded_power_base = CodeNum.parse("1.5", 2)
assert(CodeNum.toString(CodeNum.pow(rounded_power_base, 5, 2)) == "7.6",
	"integer power rounded intermediate products instead of the final result")
assert(CodeNum.toString(CodeNum.pow(rounded_power_base, -5, 2)) == "0.13",
	"negative integer power inherited intermediate rounding error")
assert(CodeNum.toString(CodeNum.pow(CodeNum.parse("1.5", 4), 3, 4)) == "3.375",
	"integer power lost exactness when the selected precision was sufficient")

local rounded_zero_times_infinity = CodeNum.mul(math.huge, rounded_zero_product)
assert(rounded_zero_times_infinity ~= rounded_zero_times_infinity,
	"Precise zero multiplied by infinity did not produce NaN")
local negative_infinity_times_rounded_zero = CodeNum.mul(-math.huge, rounded_zero_product)
assert(negative_infinity_times_rounded_zero ~= negative_infinity_times_rounded_zero,
	"negative infinity multiplied by Precise zero did not produce NaN")

local rounded_zero_register = CodeNum.createRegister()
CodeNum.mulInto(rounded_zero_register, negative_rounded, 0)
assert(CodeNum.isPrecise(rounded_zero_register) and CodeNum.wasRounded(rounded_zero_register),
	"precise register did not retain zero rounding provenance")
local register_add_result = CodeNum.add(rounded_zero_register, 1)
assert(CodeNum.compare(register_add_result, 1) == 0 and CodeNum.wasRounded(register_add_result),
	"precise register operand lost exact value or rounding provenance")
local parsed_negative_zero = CodeNum.parse("-0", 34)
assert(parsed_negative_zero == 0 and 1 / parsed_negative_zero == -math.huge,
	"decimal parsing did not preserve negative zero")
local scientific_negative_zero = CodeNum.fromScientific(-0.0, "100")
assert(scientific_negative_zero == 0 and 1 / scientific_negative_zero == -math.huge,
	"scientific construction did not preserve negative zero")
local encoded_negative_zero = CodeNum.encode(negative_rounded_zero)
assert(encoded_negative_zero == "CN1|N|-0",
	"precise negative zero did not use the signed native zero codec")
local decoded_negative_zero = CodeNum.decode(encoded_negative_zero)
assert(decoded_negative_zero == 0 and 1 / decoded_negative_zero == -math.huge
	and not CodeNum.wasRounded(decoded_negative_zero),
	"negative zero codec changed its sign or persisted runtime-only provenance")

local invalid_precision_operations = {
	function() CodeNum.add(math.huge, 1, 0) end,
	function() CodeNum.sub(0 / 0, 1, 4097) end,
	function() CodeNum.mul(-math.huge, 1, 0) end,
	function() CodeNum.div(1, math.huge, 4097) end,
	function() CodeNum.pow(2, 0, 0) end,
}
for _, operation in invalid_precision_operations do
	assert(not pcall(operation), "invalid precision was accepted by an arithmetic operation")
end

print("[CodeNum 0.6.0] native, Wide, precise arithmetic, range, codec, and register regressions passed")
