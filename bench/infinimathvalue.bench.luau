--!nonstrict
-- CodSpeed scenario: InfiniteMathValue normalization, persistence and formatting.
local Shim = require("./infinimath_shim")
local InfiniteMathValue, InfiniteMath = Shim.load_infinitemath_value()

local large = InfiniteMath.new("1,1000000000000")
local large_payload = InfiniteMathValue.encode(large)
local iterations = 500

for _ = 1, iterations do
	local normalized = InfiniteMathValue.normalize(large_payload)
	local decoded = InfiniteMathValue.decode(normalized)
	assert(decoded.first == large.first and decoded.second == large.second,
		"InfiniteMathValue codec round-trip changed the number")
	local formatted = InfiniteMathValue.format(normalized)
	assert(type(formatted) == "string" and #formatted > 0,
		"InfiniteMathValue formatting returned an empty string")
end
