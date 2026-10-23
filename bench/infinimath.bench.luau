--!nonstrict
-- CodSpeed scenario: InfiniteMath Revised high-range arithmetic.
local Shim = require("./infinimath_shim")
local InfiniteMath = Shim.load_infinitemath()

local seed = InfiniteMath.new("1,1000000000000")
local multiplier = InfiniteMath.new(987654321)
local iterations = 300

for index = 1, iterations do
	local input = seed * InfiniteMath.new(index + 1)
	local product = input * multiplier
	local restored = InfiniteMath.new({ product.first, product.second })
	assert(restored.first == product.first and restored.second == product.second,
		"InfiniteMath high-range representation changed during reconstruction")
end

local high_power = InfiniteMath.new(10) ^ 1000
assert(high_power.second == 1000, "InfiniteMath upper-range benchmark correctness guard failed")
