--!nocheck
-- CodSpeed scenario: AlyaNum high-range arithmetic and reconstruction.
local Shim = require("./alyanum_shim")
local AlyaNum = Shim.load_alyanum()
local seed = AlyaNum.new(10):pow(1000)
local multiplier = AlyaNum.new(987654321)
local iterations = 300

for index = 1, iterations do
	local input = seed * AlyaNum.new(index + 1)
	local product = input * multiplier
	local reconstructed = AlyaNum.fix(AlyaNum.toBaseAlya(product))
	assert(AlyaNum.toString(reconstructed) == AlyaNum.toString(product),
		"AlyaNum high-range representation changed during reconstruction")
end

local high_power = AlyaNum.new(10):pow(1000)
assert(AlyaNum.toNumber(high_power) == math.huge,
	"AlyaNum high-range benchmark correctness guard failed")
