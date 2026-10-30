--!nocheck
-- CodSpeed scenario: AlyaNumValue normalization, persistence, and formatting.
local Shim = require("./alyanum_shim")
local AlyaNumValue, AlyaNum = Shim.load_alyanum_value()
local large = AlyaNum.new(10):pow(1000)
local payload = AlyaNumValue.encode(large)
local iterations = 500

for _ = 1, iterations do
	local normalized = AlyaNumValue.normalize(payload)
	local decoded = AlyaNumValue.decode(normalized)
	assert(AlyaNum.toString(decoded) == AlyaNum.toString(large),
		"AlyaNumValue codec round-trip changed the number")
	local formatted = AlyaNumValue.format(normalized)
	assert(type(formatted) == "string" and #formatted > 0,
		"AlyaNumValue formatting returned an empty string")
end
