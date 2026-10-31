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
assert(CodeNum.toString(product) == "121932631112635269", "precise coefficient multiplication is incorrect")
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

print("[CodeNum 0.6.0] native, Wide, precise arithmetic, range, codec, and register regressions passed")
