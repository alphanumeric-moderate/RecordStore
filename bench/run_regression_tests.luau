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

Shim.run_script("tests/RecordStore_OpenCorrupt_CompatibilityRegression.server.luau")
Shim.run_script("tests/RecordStore_NonFiniteNumbersRegression.server.luau")
Shim.close()
