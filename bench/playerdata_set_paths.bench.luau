--!nocheck
-- CodSpeed benchmark for repeated PlayerData.Set runtime path resolution.
local create_harness = require("./playerdata_set_harness")

-- This first run is the legacy lookup baseline. The follow-up commit switches
-- the same benchmark URI to the cached implementation for a controlled diff.
local USE_CACHED_PATHS = false
local ITERATIONS = 25000

local harness = create_harness(USE_CACHED_PATHS)
local controller = harness.controller
local player = harness.player
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

assert(controller:Shutdown(), "PlayerData path benchmark shutdown failed")
print("[PlayerData.Set path benchmark] completed")
