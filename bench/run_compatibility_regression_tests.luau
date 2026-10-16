--!nocheck
-- Fixed-workload compatibility benchmark.
-- Keep expanded/new regression tests in run_regression_tests.luau, outside CodSpeed
-- timing so the measured workload stays comparable with the historical baseline.
local Shim = require("./RobloxShim")

Shim.run_script("tests/RecordStore_OpenCorrupt_CompatibilityRegression.server.luau")
Shim.close()
