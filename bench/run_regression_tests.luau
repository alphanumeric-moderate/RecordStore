--!nocheck
-- Runs RecordStore regressions and syntax-checks the PlayerData modules under Lune.
-- Usage (from the repository root): lune run bench/run_regression_tests.luau
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Shim = require("./RobloxShim")

for _, path in {
	"src/PlayerDataCore.luau",
	"src/IntegerInfinityValue.luau",
	"examples/PlayerData.server.luau",
	"tests/IntegerInfinityValueRegression.server.luau",
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

Shim.run_script("tests/RecordStore_OpenCorrupt_CompatibilityRegression.server.luau")
Shim.run_script("tests/RecordStore_NonFiniteNumbersRegression.server.luau")
Shim.close()
