--!strict
-- Run this server Script in Roblox Studio through tests.project.json.
-- It verifies the NumberValue-backed path that PlayerDataCore uses for integer infinities.

local ServerScriptService = game:GetService("ServerScriptService")
local IntegerInfinityValue = require(ServerScriptService:WaitForChild("IntegerInfinityValue"))

local value = IntegerInfinityValue.new("Kills", math.huge)
assert(value.Value == math.huge, "positive infinity was not preserved by NumberValue")

value.Value = -math.huge
assert(value.Value == -math.huge, "negative infinity was not preserved by NumberValue")

local nan = 0 / 0
value.Value = nan
assert(math.isnan(value.Value), "NaN was normalized or rejected instead of being preserved")

value.Value = 17.4
assert(value.Value == 17, "finite values must still use configured integer rounding")

value.Value = -17.6
assert(value.Value == -18, "negative finite values must still use configured integer rounding")

value.Value = math.nan
assert(math.isnan(value.Value), "NaN failed after a finite assignment")

value:Destroy()
print("[IntegerInfinityValue] infinity and NaN regression tests passed")
