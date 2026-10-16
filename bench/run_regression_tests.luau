--!nocheck
-- Runs RecordStore regressions and syntax-checks the PlayerData modules under Lune.
-- Usage (from the repository root): lune run bench/run_regression_tests.luau
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Shim = require("./RobloxShim")

for _, path in {
	"src/PlayerDataCore.luau",
	"src/IntegerInfinityValue.luau",
	"src/NumberFormatter.luau",
	"examples/PlayerData.server.luau",
	"tests/IntegerInfinityValueRegression.server.luau",
	"tests/NumberFormatterRegression.server.luau",
} do
	local chunk = luau.load(fs.readFile(path), {
		debugName = path,
	})
	assert(type(chunk) == "function", ("failed to compile %s"):format(path))
end

-- Exercise the same normalizer used by PlayerDataCore, without relying on
-- Roblox Instance behavior. The separate Studio Script covers NumberValue.
local integer_infinity_chunk = luau.load(fs.readFile("src/IntegerInfinityValue.luau"), {
	debugName = "IntegerInfinityValue",
})
local IntegerInfinityValue = integer_infinity_chunk()
assert(IntegerInfinityValue.normalize(math.huge, "nearest") == math.huge, "positive infinity normalization failed")
assert(IntegerInfinityValue.normalize(-math.huge, "nearest") == -math.huge, "negative infinity normalization failed")
assert(math.isnan(IntegerInfinityValue.normalize(0 / 0, "nearest")), "NaN was normalized to a finite number")
assert(IntegerInfinityValue.normalize(17.4, "nearest") == 17, "finite rounding changed")
assert(IntegerInfinityValue.normalize(-17.6, "nearest") == -18, "negative finite rounding changed")

local number_formatter_chunk = luau.load(fs.readFile("src/NumberFormatter.luau"), {
	debugName = "NumberFormatter",
})
local NumberFormatter = number_formatter_chunk()
assert(NumberFormatter.format(999) == "999", "sub-thousand values must remain unabridged")
assert(NumberFormatter.format(1000) == "1K", "thousand abbreviation failed")
assert(NumberFormatter.format(1250) == "1.25K", "decimal abbreviation failed")
assert(NumberFormatter.format(999_999) == "999.99K", "near-million formatting changed")
assert(NumberFormatter.format(1_000_000) == "1M", "million abbreviation failed")
assert(NumberFormatter.format(1_000_000_000) == "1B", "billion abbreviation failed")
assert(NumberFormatter.format(1_000_000_000_000) == "1T", "trillion rollover failed")
assert(NumberFormatter.format(-1_500_000_000) == "-1.5B", "negative number formatting failed")
assert(NumberFormatter.format(1_000_000_000_000_000) == "1Qa", "quadrillion abbreviation failed")
assert(NumberFormatter.format(math.huge) == "∞", "infinity formatting failed")
assert(NumberFormatter.format(-math.huge) == "-∞", "negative infinity formatting failed")
assert(NumberFormatter.format(0 / 0) == "NaN", "NaN formatting failed")
assert(NumberFormatter.format(1_000, { decimals = 0 }) == "1K", "zero-decimal formatting failed")
assert(
	NumberFormatter.format(1_200_000, { decimals = 3, trim_trailing_zeros = false }) == "1.200M",
	"preserving trailing zeros failed"
)
assert(
	NumberFormatter.format(1_200_000, { decimals = 3 }) == "1.2M",
	"trailing zero trimming failed"
)
assert(NumberFormatter.format(1e36) == "1.00e+36", "large-number scientific fallback failed")
local invalid_options_ok = pcall(function()
	NumberFormatter.format(1, { decimals = 7 })
end)
assert(not invalid_options_ok, "invalid decimal precision was accepted")

Shim.run_script("tests/RecordStore_OpenCorrupt_CompatibilityRegression.server.luau")
Shim.run_script("tests/RecordStore_NonFiniteNumbersRegression.server.luau")
Shim.close()
