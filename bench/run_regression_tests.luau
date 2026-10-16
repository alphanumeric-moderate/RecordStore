--!nocheck
-- Runs the Roblox Studio regression script under Lune using the engine shim.
-- Usage (from the repository root): lune run bench/run_regression_tests.luau
local Shim = require("./RobloxShim")

Shim.run_script("tests/RecordStore_OpenCorrupt_CompatibilityRegression.server.luau")
Shim.close()
