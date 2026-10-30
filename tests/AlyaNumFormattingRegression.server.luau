--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AlyaNum = require(ReplicatedStorage:WaitForChild("AlyaNum"))
local AlyaNumFormatter = require(
	ServerScriptService:WaitForChild("AlyaNumFormatter")
)

assert(AlyaNumFormatter.format(999) == "999")
assert(AlyaNumFormatter.format(1_000) == "1K")
assert(AlyaNumFormatter.format(1_250) == "1.25K")
assert(AlyaNumFormatter.format(1_000_000) == "1M")
assert(AlyaNumFormatter.format(1_000_000_000_000) == "1T")
assert(AlyaNumFormatter.format(-1_500_000_000) == "-1.5B")

assert(AlyaNumFormatter.format(math.huge) == "Infinity")
assert(AlyaNumFormatter.format(-math.huge) == "-Infinity")
assert(AlyaNumFormatter.format(0 / 0) == "NaN")
assert(AlyaNumFormatter.format("+Inf") == "Infinity")
assert(AlyaNumFormatter.format("-Inf") == "-Infinity")
assert(AlyaNumFormatter.format("NaN") == "NaN")

assert(AlyaNumFormatter.format(1_200_000, { decimals = 0 }) == "1M")
assert(AlyaNumFormatter.format(
	1_200_000,
	{ decimals = 3, trim_trailing_zeros = false }
) == "1.200M")
assert(AlyaNumFormatter.format(1_200_000, { decimals = 3 }) == "1.2M")
assert(AlyaNumFormatter.format(1, { decimals = 3, trim_trailing_zeros = false }) == "1.000")

local large = AlyaNum.new(10):pow(1000)
assert(AlyaNumFormatter.format(large) ~= "")
assert(AlyaNum.toNumber(large) == math.huge)
assert(not pcall(function() AlyaNumFormatter.format(1, { decimals = 7 }) end))
assert(not pcall(function() AlyaNumFormatter.format(1, { unknown = true }) end))

print("[AlyaNumFormatting] regression tests passed")
