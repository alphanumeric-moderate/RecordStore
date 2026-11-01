--!nocheck
local Shim = require("./codenum_shim")
local CodeNum = Shim.load_codenum()

local seed = CodeNum.parse("1.234567890123456789012345678901234567890123456789", 50)
local multiplier = CodeNum.fromInteger("12345678901234567890")
local offset = CodeNum.fromInteger("9007199254740993")

for _ = 1, 200 do
	local sum = CodeNum.add(seed, offset, 50)
	local product = CodeNum.mul(sum, multiplier, 50)
	local restored = CodeNum.decode(CodeNum.encode(product))
	assert(CodeNum.compare(product, restored) == 0,
		"precise arithmetic codec round-trip changed the value")

	local quotient = CodeNum.div(product, multiplier, 34)
	assert(CodeNum.isPrecise(quotient), "precise division returned a non-precise value")
	assert(CodeNum.isFinite(quotient), "precise division produced a non-finite value")

	offset = CodeNum.add(offset, 1)
end
