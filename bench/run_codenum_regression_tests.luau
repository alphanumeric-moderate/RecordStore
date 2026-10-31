--!nocheck
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local CodeNum = luau.load(fs.readFile("src/CodeNum/init.luau"), {
	debugName = "CodeNumRegression",
})()

assert(CodeNum.VERSION == "0.5.0", "wrong CodeNum version")
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

print("[CodeNum 0.5.0] arithmetic, range, codec, and register regressions passed")
