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
assert(CodeNum.toNumber(CodeNum.parse("0.3", 34)) == 0.3,
	"precise decimal 0.3 did not round-trip to its binary64 value")
assert(CodeNum.toNumber(CodeNum.withPrecision(0.3, 34)) == 0.3,
	"precision-wrapped binary64 0.3 did not preserve its binary64 value")
assert(CodeNum.toNumber(CodeNum.parse("0.1", 34)) == 0.1,
	"precise decimal 0.1 did not round-trip to its binary64 value")
local binary64_midpoint_above = "1.00000000000000011102230246251565404236316680908203126"
assert(CodeNum.toNumber(CodeNum.parse(binary64_midpoint_above)) == 1.0000000000000002,
	"precise conversion discarded digits beyond the binary64 midpoint")
assert(CodeNum.toNumber(CodeNum.parse("-" .. binary64_midpoint_above)) == -1.0000000000000002,
	"negative precise conversion discarded digits beyond the binary64 midpoint")
assert(CodeNum.toNumber(CodeNum.parse("2.4703282292062328e-324")) == 5e-324,
	"precise conversion rounded a subnormal above the midpoint to zero")
local negative_underflow = CodeNum.toNumber(CodeNum.parse("-1.234567890123456789e-400"))
assert(negative_underflow == 0 and 1 / negative_underflow == -math.huge,
	"precise underflow did not preserve negative zero")
assert(CodeNum.toNumber(CodeNum.parse("1.7976931348623157e308")) == 1.7976931348623157e308,
	"precise conversion overflowed the largest finite binary64 value")
assert(CodeNum.toNumber(CodeNum.parse("1.234567890123456789e9000")) == math.huge,
	"precise conversion did not overflow for a large exponent")
local fallback_underflow = CodeNum.toNumber(CodeNum.parse("-1.234567890123456789e-9000"))
assert(fallback_underflow == 0 and 1 / fallback_underflow == -math.huge,
	"precise conversion did not preserve signed zero for a large negative exponent")
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
assert(CodeNum.toString(CodeNum.div(CodeNum.parse("1", 2), three)) == "0.33",
	"division did not inherit a lower operand precision")
assert(CodeNum.toString(CodeNum.div(CodeNum.parse("1", 2), three, 5)) == "0.33333",
	"division precision override did not take precedence")
assert(type(CodeNum.div(1, 3)) == "number" and CodeNum.div(1, 3) == 1 / 3,
	"native division did not retain its fast path")
assert(CodeNum.toString(CodeNum.pow(CodeNum.fromInteger("2"), -3)) == "0.125",
	"negative precise integer power failed")
assert(CodeNum.toString(CodeNum.pow(three, -1)) == "0." .. string.rep("3", 34),
	"negative precise power did not use the 34-digit default")
assert(CodeNum.toString(CodeNum.pow(CodeNum.parse("3", 2), -1)) == "0.33",
	"negative precise power ignored the operand's lower precision")
assert(CodeNum.toString(CodeNum.pow(three, -1, 50)) == "0." .. string.rep("3", 50),
	"negative precise power ignored its precision override")
local reciprocal_midpoint_base = CodeNum.parse("7." .. string.rep("9", 30), 31)
assert(CodeNum.toString(CodeNum.pow(reciprocal_midpoint_base, -1, 2)) == "0.13",
	"negative power rounded its input before resolving a reciprocal midpoint")
local power_midpoint_base = CodeNum.parse("1.25" .. string.rep("0", 25) .. "1", 29)
assert(CodeNum.toString(CodeNum.pow(power_midpoint_base, 1, 2)) == "1.3",
	"positive power rounded its input before resolving a midpoint")
assert(CodeNum.toString(CodeNum.pow(CodeNum.parse("1.234", 4), 2)) == "1.523",
	"positive precise power did not inherit its operand precision")

assert(CodeNum.toString(CodeNum.sub(CodeNum.fromInteger("100"), 1)) == "99",
	"precise subtraction misordered unequal-length coefficients")
assert(CodeNum.toString(CodeNum.sub(CodeNum.fromInteger("5"), 10)) == "-5",
	"precise subtraction lost the sign of the larger right coefficient")
assert(CodeNum.toString(CodeNum.sub(CodeNum.fromInteger("123"), 23)) == "100",
	"precise subtraction changed equal-length aligned coefficient comparison")

local product = CodeNum.mul(CodeNum.fromInteger("123456789"), CodeNum.fromInteger("987654321"))
assert(CodeNum.toString(product) == "121932631112635269", "precise coefficient multiplication is incorrect: " .. CodeNum.toString(product))
assert(CodeNum.toString(CodeNum.pow(CodeNum.fromInteger("123456"), 2)) == "15241383936",
	"precise integer power is incorrect")

local precise_payload = CodeNum.encode(long_decimal)
assert(string.match(precise_payload, "^CN2|P|") ~= nil, "precise values did not use the CN2 codec")
local precise_decoded = CodeNum.decode(precise_payload)
assert(CodeNum.isPrecise(precise_decoded), "CN2 decoding did not restore precise storage")
assert(CodeNum.toString(precise_decoded) == long_decimal_text, "CN2 round-trip lost decimal digits")
assert(not pcall(function() CodeNum.decode("CN2|P|1|1234|0|3") end),
	"CN2 decoding silently rounded a coefficient exceeding its precision")
assert(not pcall(function() CodeNum.decode("CN2|P|1|0012300|0|2") end),
	"CN2 decoding accepted excess significant digits surrounded by zeros")
assert(not pcall(function() CodeNum.decode("CN2|P|1|" .. string.rep("0", 4097) .. "|0|1") end),
	"CN2 decoding accepted a coefficient above the digit limit")
local padded_precise = CodeNum.decode("CN2|P|1|0012300|-2|3")
assert(CodeNum.toString(padded_precise) == "123" and not CodeNum.wasRounded(padded_precise),
	"CN2 decoding rejected or rounded insignificant coefficient zeros")
local padded_zero = CodeNum.decode("CN2|P|-1|0000|0|1")
assert(CodeNum.isPrecise(padded_zero) and 1 / CodeNum.toNumber(padded_zero) == -math.huge,
	"CN2 decoding changed a padded signed zero")
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
local rounded_zero_power = CodeNum.pow(rounded_parse, 0)
assert(CodeNum.isPrecise(rounded_zero_power) and CodeNum.wasRounded(rounded_zero_power)
	and CodeNum.toString(CodeNum.add(rounded_zero_power, 123)) == "120",
	"zero power discarded the precise operand's precision or rounding ancestry")
local override_zero_power = CodeNum.pow(rounded_parse, 0, 4)
assert(CodeNum.isPrecise(override_zero_power) and CodeNum.wasRounded(override_zero_power)
	and CodeNum.toString(CodeNum.add(override_zero_power, 123)) == "124",
	"zero power did not preserve its explicit precision and rounding ancestry")
assert(CodeNum.isPrecise(CodeNum.pow(2, 0, 3)) and type(CodeNum.pow(2, 0)) == "number",
	"zero power changed explicit or native precision dispatch")
local zero_to_zero = CodeNum.pow(CodeNum.parse("0", 2), 0)
assert(CodeNum.encode(zero_to_zero) == "CN2|P|1|1|0|2" and not CodeNum.wasRounded(zero_to_zero),
	"zero to the zeroth power discarded its precise context or invented rounding")
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
local negative_zero_product_number = CodeNum.toNumber(negative_zero_product)
assert(CodeNum.isPrecise(negative_zero_product)
	and negative_zero_product_number == 0 and 1 / negative_zero_product_number == -math.huge,
	"precise multiplication lost the sign of negative zero")
local negative_zero_quotient = CodeNum.div(-0.0, CodeNum.fromInteger("2"))
local negative_zero_quotient_number = CodeNum.toNumber(negative_zero_quotient)
assert(CodeNum.isPrecise(negative_zero_quotient)
	and negative_zero_quotient_number == 0 and 1 / negative_zero_quotient_number == -math.huge,
	"precise division lost the sign of negative zero")
local negative_zero_over_negative = CodeNum.div(0.0, CodeNum.fromInteger("-2"))
local negative_zero_over_negative_number = CodeNum.toNumber(negative_zero_over_negative)
assert(CodeNum.isPrecise(negative_zero_over_negative)
	and negative_zero_over_negative_number == 0 and 1 / negative_zero_over_negative_number == -math.huge,
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
local exact_integer_cancellation = CodeNum.add(
	exact_integer, CodeNum.fromInteger("-9007199254740993")
)
assert(CodeNum.compare(exact_integer_cancellation, 0) == 0
	and CodeNum.isPrecise(exact_integer_cancellation)
	and not CodeNum.wasRounded(exact_integer_cancellation),
	"exact precise cancellation did not retain a precise zero without inventing rounding provenance")

local precision_two_value = CodeNum.parse("1.2", 2)
local explicit_precision_zero = CodeNum.parse("0", 2)
assert(CodeNum.isPrecise(explicit_precision_zero)
	and not CodeNum.wasRounded(explicit_precision_zero)
	and CodeNum.toString(CodeNum.add(explicit_precision_zero, 123)) == "120",
	"explicit precision on zero was not retained by parsing")
local negative_explicit_precision_zero = CodeNum.parse("-0", 2)
assert(CodeNum.isPrecise(negative_explicit_precision_zero)
	and CodeNum.toNumber(negative_explicit_precision_zero) == 0
	and 1 / CodeNum.toNumber(negative_explicit_precision_zero) == -math.huge,
	"explicit negative-zero precision or sign was not retained by parsing")
local integer_zero = CodeNum.fromInteger("0")
assert(CodeNum.isPrecise(integer_zero),
	"exact integer construction collapsed zero to native storage")
local assigned_precision_zero = CodeNum.withPrecision(0, 2)
assert(CodeNum.isPrecise(assigned_precision_zero)
	and CodeNum.toString(CodeNum.add(assigned_precision_zero, 123)) == "120",
	"withPrecision did not assign a precision context to native zero")

local exact_cancellation_zero = CodeNum.sub(precision_two_value, precision_two_value)
assert(CodeNum.isPrecise(exact_cancellation_zero)
	and not CodeNum.wasRounded(exact_cancellation_zero)
	and CodeNum.toString(CodeNum.add(exact_cancellation_zero, 123)) == "120",
	"exact cancellation discarded the selected precision context")
local exact_product_zero = CodeNum.mul(precision_two_value, 0)
assert(CodeNum.isPrecise(exact_product_zero)
	and not CodeNum.wasRounded(exact_product_zero)
	and CodeNum.toString(CodeNum.add(exact_product_zero, 123)) == "120",
	"multiplication by native zero discarded the precise operand's context")
local exact_quotient_zero = CodeNum.div(explicit_precision_zero, precision_two_value)
assert(CodeNum.isPrecise(exact_quotient_zero)
	and not CodeNum.wasRounded(exact_quotient_zero)
	and CodeNum.toString(CodeNum.add(exact_quotient_zero, 123)) == "120",
	"exact division of precise zero discarded its precision context")
local absolute_precise_zero = CodeNum.abs(explicit_precision_zero)
assert(CodeNum.isPrecise(absolute_precise_zero)
	and not CodeNum.wasRounded(absolute_precise_zero)
	and CodeNum.toString(CodeNum.add(absolute_precise_zero, 123)) == "120",
	"absolute value collapsed precise zero storage")
local powered_precise_zero = CodeNum.pow(explicit_precision_zero, 2)
assert(CodeNum.isPrecise(powered_precise_zero)
	and not CodeNum.wasRounded(powered_precise_zero)
	and CodeNum.toString(CodeNum.add(powered_precise_zero, 123)) == "120",
	"integer power collapsed precise zero storage")
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
local parsed_negative_zero_number = CodeNum.toNumber(parsed_negative_zero)
assert(CodeNum.isPrecise(parsed_negative_zero)
	and parsed_negative_zero_number == 0 and 1 / parsed_negative_zero_number == -math.huge,
	"decimal parsing did not preserve precise negative zero")
local scientific_negative_zero = CodeNum.fromScientific(-0.0, "100")
assert(scientific_negative_zero == 0 and 1 / scientific_negative_zero == -math.huge,
	"scientific construction did not preserve negative zero")
local positive_rounded_zero = CodeNum.mul(rounded_parse, 0)
assert(CodeNum.isPrecise(positive_rounded_zero) and CodeNum.wasRounded(positive_rounded_zero),
	"positive rounded zero lost its precise representation or rounding provenance")
local encoded_positive_zero = CodeNum.encode(positive_rounded_zero)
assert(encoded_positive_zero == "CN2|P|1|0|0|2",
	"positive precise zero did not retain its precision in the CN2 codec")
local decoded_positive_zero = CodeNum.decode(encoded_positive_zero)
assert(CodeNum.isPrecise(decoded_positive_zero) and not CodeNum.wasRounded(decoded_positive_zero),
	"decoded positive precise zero did not retain precise storage independently of rounding provenance")
assert(CodeNum.encode(decoded_positive_zero) == encoded_positive_zero,
	"positive precise zero did not have a stable CN2 round-trip")
local positive_zero_number = CodeNum.toNumber(decoded_positive_zero)
assert(positive_zero_number == 0 and 1 / positive_zero_number == math.huge,
	"positive precise zero changed sign during native conversion")
local integer_123 = CodeNum.fromInteger("123")
assert(CodeNum.toString(CodeNum.add(positive_rounded_zero, integer_123)) == "120",
	"positive rounded zero did not apply its precision context before serialization")
assert(CodeNum.toString(CodeNum.add(decoded_positive_zero, integer_123)) == "120",
	"CN2 round-trip discarded the precision context of positive zero")
for _, sum in { CodeNum.add(decoded_positive_zero, 0), CodeNum.add(0, decoded_positive_zero),
	CodeNum.sub(decoded_positive_zero, 0) } do
	assert(CodeNum.isPrecise(sum) and not CodeNum.wasRounded(sum),
		"zero arithmetic discarded precise storage or introduced rounding provenance")
	local round_trip = CodeNum.decode(CodeNum.encode(sum))
	assert(CodeNum.toString(CodeNum.add(round_trip, 123)) == "120",
		"zero arithmetic discarded precision across a chained codec round-trip")
end
local rounded_zero_sum = CodeNum.add(positive_rounded_zero, 0)
assert(CodeNum.wasRounded(rounded_zero_sum), "zero addition discarded rounding provenance")
local zero_register = CodeNum.createRegister()
CodeNum.addInto(zero_register, decoded_positive_zero, 0)
CodeNum.addInto(zero_register, zero_register, 0)
assert(CodeNum.isPrecise(zero_register) and not CodeNum.wasRounded(zero_register)
	and CodeNum.toString(CodeNum.add(zero_register, 123)) == "120",
	"aliased register zero addition discarded its precision context")

local encoded_negative_zero = CodeNum.encode(negative_rounded_zero)
assert(encoded_negative_zero == "CN2|P|-1|0|0|2",
	"negative precise zero did not retain its precision in the CN2 codec")
local decoded_negative_zero = CodeNum.decode(encoded_negative_zero)
assert(CodeNum.isPrecise(decoded_negative_zero) and not CodeNum.wasRounded(decoded_negative_zero),
	"decoded negative precise zero did not retain precise storage independently of rounding provenance")
assert(CodeNum.encode(decoded_negative_zero) == encoded_negative_zero,
	"negative precise zero did not have a stable CN2 round-trip")
local negative_zero_number = CodeNum.toNumber(decoded_negative_zero)
assert(negative_zero_number == 0 and 1 / negative_zero_number == -math.huge,
	"negative precise zero changed sign during native conversion")
local negative_zero_sum = CodeNum.toNumber(CodeNum.add(decoded_negative_zero, -0.0))
assert(negative_zero_sum == 0 and 1 / negative_zero_sum == -math.huge,
	"precise zero addition changed the sign of two negative zeros")

local native_positive_zero_payload = CodeNum.encode(0)
local native_negative_zero_payload = CodeNum.encode(-0.0)
assert(native_positive_zero_payload == "CN1|N|0" and native_negative_zero_payload == "CN1|N|-0",
	"native positive or negative zero lost CN1 compatibility")
local decoded_native_negative_zero = CodeNum.decode(native_negative_zero_payload)
assert(not CodeNum.isPrecise(decoded_native_negative_zero)
	and decoded_native_negative_zero == 0
	and 1 / decoded_native_negative_zero == -math.huge,
	"native negative zero no longer decodes as signed native zero")

local invalid_precision_operations = {
	function() CodeNum.add(math.huge, 1, 0) end,
	function() CodeNum.sub(0 / 0, 1, 4097) end,
	function() CodeNum.mul(-math.huge, 1, 0) end,
	function() CodeNum.div(1, math.huge, 4097) end,
	function() CodeNum.pow(2, 0, 0) end,
	function() CodeNum.addInto(CodeNum.createRegister(), math.huge, 1, 0) end,
	function() CodeNum.subInto(CodeNum.createRegister(), 0 / 0, 1, 4097) end,
	function() CodeNum.mulInto(CodeNum.createRegister(), -math.huge, 1, 0) end,
	function() CodeNum.divInto(CodeNum.createRegister(), 1, math.huge, 4097) end,
}
for _, operation in invalid_precision_operations do
	assert(not pcall(operation), "invalid precision was accepted by an arithmetic operation")
end


local toom_operand_digits = 1600
local toom_operand_text = string.rep("9", toom_operand_digits)
local toom_operand = CodeNum.fromInteger(toom_operand_text)
local toom_square = CodeNum.mul(toom_operand, toom_operand, toom_operand_digits * 2)
local toom_square_expected = string.rep("9", toom_operand_digits - 1)
	.. "8"
	.. string.rep("0", toom_operand_digits - 1)
	.. "1"
assert(CodeNum.toString(toom_square) == toom_square_expected,
	"adaptive large-coefficient multiplication changed an exact square")
assert(CodeNum.toString(CodeNum.mul(CodeNum.fromInteger("-" .. toom_operand_text), toom_operand,
	toom_operand_digits * 2)) == "-" .. toom_square_expected,
	"adaptive large-coefficient multiplication changed a negative product")

local division_left = CodeNum.fromInteger(string.rep("9", 900))
local division_right = CodeNum.fromInteger(string.rep("8", 500))
local division_product = CodeNum.mul(division_left, division_right, 1400)
local division_recovered = CodeNum.div(division_product, division_right, 900)
assert(CodeNum.compare(division_recovered, division_left) == 0,
	"normalized multiprecision division did not recover an exact quotient")

local division_left_large = CodeNum.fromInteger(string.rep("7", 1900))
local division_right_large = CodeNum.fromInteger(string.rep("9", 1900))
local division_product_large = CodeNum.mul(division_left_large, division_right_large, 3800)
local division_recovered_large = CodeNum.div(division_product_large, division_right_large, 1900)
assert(CodeNum.compare(division_recovered_large, division_left_large) == 0,
	"large normalized division failed across the multi-limb quotient path")

for iteration = 1, 12 do
	local leftDigits = 100 + iteration * 73
	local rightDigits = 80 + iteration * 41
	local leftValue = CodeNum.fromInteger(string.rep("9", leftDigits))
	local rightValue = CodeNum.fromInteger(string.rep("7", rightDigits))
	local productValue = CodeNum.mul(leftValue, rightValue, leftDigits + rightDigits)
	local quotientValue = CodeNum.div(productValue, rightValue, leftDigits)
	assert(CodeNum.compare(quotientValue, leftValue) == 0,
		"pooled adaptive arithmetic changed a repeated multiply/divide result")
end

print("[CodeNum 0.6.0] native, Wide, precise arithmetic, range, codec, and register regressions passed")
