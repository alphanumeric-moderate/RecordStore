--!nocheck
-- CodSpeed benchmark for repeated PlayerData.Set runtime path resolution.
local create_harness = require("./playerdata_set_harness")

-- The previous commit measured the legacy path; this commit measures the
-- cached path with the same benchmark URI for a controlled CodSpeed comparison.
-- The repeated value stabilizes persistence work so this measures Set path lookup.
local USE_CACHED_PATHS = true
local ITERATIONS = 10000

local harness = create_harness(USE_CACHED_PATHS)
local controller = harness.controller
local player = harness.player
local task = harness.task
local calls_before = harness.get_find_first_child_calls()

for _ = 1, ITERATIONS do
	local success, message = controller.Set(player, "kills", 12500124)
	if not success then
		error(message or "PlayerData.Set path benchmark failed")
	end
end

local calls_after = harness.get_find_first_child_calls()
if USE_CACHED_PATHS then
	assert(calls_after == calls_before, "cached PlayerData.Set should not perform child lookups")
else
	assert(
		calls_after - calls_before == ITERATIONS * 2,
		"legacy Set path should resolve root and child on every iteration"
	)
end

-- Let the coalesced value-change flush settle before graceful shutdown.
task.wait(0.1)
assert(controller:Shutdown(), "PlayerData path benchmark shutdown failed")
print("[PlayerData.Set path benchmark] completed")
