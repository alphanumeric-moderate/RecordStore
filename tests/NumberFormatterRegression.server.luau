--!strict
-- Run this server Script in Roblox Studio through tests.project.json.

local ServerScriptService = game:GetService("ServerScriptService")
local NumberFormatter = require(ServerScriptService:WaitForChild("NumberFormatter"))

assert(NumberFormatter.format(999) == "999")
assert(NumberFormatter.format(1_000) == "1K")
assert(NumberFormatter.format(1_250) == "1.25K")
assert(NumberFormatter.format(999_999) == "999.99K")
assert(NumberFormatter.format(1_000_000) == "1M")
assert(NumberFormatter.format(1_000_000_000) == "1B")
assert(NumberFormatter.format(1_000_000_000_000) == "1T")
assert(NumberFormatter.format(-1_500_000_000) == "-1.5B")
assert(NumberFormatter.format(1_000_000_000_000_000) == "1Qa")
assert(NumberFormatter.format(math.huge) == "∞")
assert(NumberFormatter.format(-math.huge) == "-∞")
assert(NumberFormatter.format(0 / 0) == "NaN")
assert(NumberFormatter.format(1_000, { decimals = 0 }) == "1K")
assert(
	NumberFormatter.format(1_200_000, { decimals = 3, trim_trailing_zeros = false }) == "1.200M",
	"preserving trailing zeros failed"
)
assert(NumberFormatter.format(1_200_000, { decimals = 3 }) == "1.2M")
assert(not pcall(function()
	NumberFormatter.format(1, { decimals = 7 })
end), "invalid decimal precision was accepted")

print("[NumberFormatter] regression tests passed")
