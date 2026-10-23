--!nocheck
-- Runs RecordStore regressions and syntax-checks the PlayerData modules under Lune.
-- Usage (from the repository root): lune run bench/run_regression_tests.luau; high-range adapter suites run as separate CodSpeed entries.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Shim = require("./RobloxShim")

for _, path in {
	"src/PlayerDataInitializer/PlayerDataCore.luau",
	"src/PlayerDataInitializer/IntegerInfinityValue.luau",
	"src/PlayerDataInitializer/NumberFormatter.luau",
	"src/InfiniteMath/init.luau",
	"src/InfiniteMath/Int.luau",
	"src/InfiniteMath/Values/Suffixes.luau",
	"src/InfiniteMath/Values/FullNames.luau",
	"src/PlayerDataInitializer/InfiniteMathValue.luau",
	"bench/infinimath_shim.luau",
	"src/PlayerDataInitializer/init.server.luau",
	"src/PlayerDataInitializer/PlayerData.luau",
	"tests/PlayerDataSetRegression.server.luau",
	"tests/IntegerInfinityValueRegression.server.luau",
	"tests/InfiniteMathValueRegression.server.luau",
	"tests/NumberFormatterRegression.server.luau",
	"tests/RecordStore_EventQueueRegression.server.luau",
	"bench/playerdata_set_harness.luau",
	"bench/playerdata_set_paths.bench.luau",
	"bench/playerdata_startup_common.luau",
	"bench/playerdata_startup_eager.bench.luau",
	"bench/playerdata_startup_lazy.bench.luau",
} do
	local chunk = luau.load(fs.readFile(path), {
		debugName = path,
	})
	assert(type(chunk) == "function", ("failed to compile %s"):format(path))
end

-- Exercise the same normalizer used by PlayerDataCore, without relying on
-- Roblox Instance behavior. The separate Studio Script covers NumberValue.
local integer_infinity_chunk = luau.load(fs.readFile("src/PlayerDataInitializer/IntegerInfinityValue.luau"), {
	debugName = "IntegerInfinityValue",
})
local IntegerInfinityValue = integer_infinity_chunk()
assert(IntegerInfinityValue.normalize(math.huge, "nearest") == math.huge, "positive infinity normalization failed")
assert(IntegerInfinityValue.normalize(-math.huge, "nearest") == -math.huge, "negative infinity normalization failed")
assert(math.isnan(IntegerInfinityValue.normalize(0 / 0, "nearest")), "NaN was normalized to a finite number")
assert(IntegerInfinityValue.normalize(17.4, "nearest") == 17, "finite rounding changed")
assert(IntegerInfinityValue.normalize(-17.6, "nearest") == -18, "negative finite rounding changed")

local number_formatter_chunk = luau.load(fs.readFile("src/PlayerDataInitializer/NumberFormatter.luau"), {
	debugName = "NumberFormatter",
})
local NumberFormatter = number_formatter_chunk()
assert(NumberFormatter.format(999) == "999", "sub-thousand values must remain unabridged")
assert(NumberFormatter.format(1000) == "1K", "thousand abbreviation failed")
assert(NumberFormatter.format(1250) == "1.25K", "decimal abbreviation failed")
assert(NumberFormatter.format(999_999) == "999.99K", "near-million formatting changed")
assert(NumberFormatter.format(1_000_000) == "1M", "million abbreviation failed")
assert(NumberFormatter.format(1_000_000_000) == "1B", "billion abbreviation failed")
assert(NumberFormatter.format(1_000_000_000_000) == "1T", "custom suffix rollover failed")
assert(NumberFormatter.format(-1_500_000_000) == "-1.5B", "negative number formatting failed")
assert(NumberFormatter.format(1_000_000_000_000_000) == "1Qa", "custom suffix abbreviation failed")
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
assert(NumberFormatter.format(1e36) == "1Ud", "custom suffix sequence failed")
assert(NumberFormatter.formatInteger("123456789012345678901234567890123456789") == "123.45Ud", "exact integer suffix failed")
assert(NumberFormatter.formatScientific(1, 1.25, "12") == "1.25T", "scientific suffix failed")

assert(
	NumberFormatter.formatScientific(1, 1.259, "12", { decimals = 2 }) == "1.25T",
	"scientific formatting with resolved options changed"
)
local huge_exponent = string.rep("9", 80)
assert(
	NumberFormatter.formatScientific(1, 1.25, huge_exponent, { decimals = 3, trim_trailing_zeros = false })
		== "1.250e+" .. huge_exponent,
	"unrepresentable scientific exponent fallback changed"
)

local invalid_scientific_mantissa = pcall(function()
	NumberFormatter.formatScientific(1, "1.25", "12")
end)
assert(not invalid_scientific_mantissa, "non-numeric scientific mantissa was accepted")
local invalid_scientific_range = pcall(function()
	NumberFormatter.formatScientific(1, 10, "12")
end)
assert(not invalid_scientific_range, "unnormalized scientific mantissa was accepted")
local invalid_scientific_exponent = pcall(function()
	NumberFormatter.formatScientific(1, 1.25, 12)
end)
assert(not invalid_scientific_exponent, "non-string scientific exponent was accepted")
assert(#NumberFormatter.getSuffixes() == 202, "suffix sequence length changed")
local invalid_options_ok = pcall(function()
	NumberFormatter.format(1, { decimals = 7 })
end)
assert(not invalid_options_ok, "invalid decimal precision was accepted")

Shim.run_script("tests/RecordStore_OpenCorrupt_CompatibilityRegression.server.luau")
Shim.run_script("tests/RecordStore_EventQueueRegression.server.luau")
Shim.run_script("tests/RecordStore_NonFiniteNumbersRegression.server.luau")
Shim.run_script("tests/RecordStore_LegacyPayloadRegression.server.luau")
Shim.run_script("tests/RecordStore_UnknownSaveRecoveryRegression.server.luau")
Shim.close()
