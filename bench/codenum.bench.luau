--!nocheck
-- CodSpeed scenario: CodeNum 0.5 arithmetic and extended-exponent reconstruction.
local Shim = require("./codenum_shim")
local CodeNum = Shim.load_codenum()
local seed = CodeNum.fromScientific(1.25, "100000")
local multiplier = CodeNum.parse("987654321")
local iterations = 500
for index = 1, iterations do
	local input = CodeNum.add(seed, index)
	local product = CodeNum.mul(input, multiplier)
	local restored = CodeNum.decode(CodeNum.encode(product))
	assert(CodeNum.compare(product, restored) == 0,
		"CodeNum arithmetic codec round-trip changed the value")
end
local wide = CodeNum.fromScientific(1.25, "1000")
assert(CodeNum.toNumber(wide) == math.huge, "wide CodeNum conversion boundary changed")
