--!nocheck
-- ResetOnJoin normalization and persistence regression.
local create_harness = require("./playerdata_set_harness")

local previous_data = {
	kills = 41,
	equipped = "PreviouslySavedGlove",
	admin = true,
}
local harness = create_harness(true, previous_data)
local player = harness.player
local record = harness.record
local saved_records = harness.saved_records
local task = harness.task
local controller = harness.controller
local saved_key = "PlayerData_Test1|global|Player_" .. tostring(player.UserId)

local leaderstats = player:FindFirstChild("leaderstats")
assert(leaderstats ~= nil, "leaderstats folder is missing")
local equipped = leaderstats:FindFirstChild("Equipped")
assert(equipped ~= nil and equipped:IsA("StringValue"), "Equipped StringValue is missing")
assert(
	(equipped :: StringValue).Value == "Default",
	"ResetOnJoin must replace the previously saved Equipped value before loading completes"
)
assert(saved_records[saved_key].equipped == "Default",
	"ResetOnJoin must durably persist the default, not only change the visible value")
assert(saved_records[saved_key].kills == 41, "ResetOnJoin changed an unrelated numeric field")
assert(saved_records[saved_key].admin == true, "ResetOnJoin changed an unrelated boolean field")
assert(record._update_calls == 1, "ResetOnJoin should issue exactly one normalization update")

local set_ok, set_error = controller.Set(player, "equipped", "SessionGlove")
assert(set_ok, set_error)
local persistence_deadline = os.clock() + 3
while os.clock() < persistence_deadline and saved_records[saved_key].equipped ~= "SessionGlove" do
	task.wait(0.01)
end
assert(saved_records[saved_key].equipped == "SessionGlove",
	"Equipped must remain writable and persistent during the current session")
assert(controller:Shutdown(), "controller failed to shut down after persistence verification")

local default_data = {
	kills = 41,
	equipped = "Default",
	admin = true,
}
local unchanged_harness = create_harness(true, default_data)
assert(unchanged_harness.record._update_calls == 0,
	"ResetOnJoin must not issue a redundant write when the saved value already equals its default")
assert(
	unchanged_harness.saved_records["PlayerData_Test1|global|Player_" .. tostring(unchanged_harness.player.UserId)].equipped
		== "Default",
	"ResetOnJoin modified an already-default field"
)
assert(unchanged_harness.controller:Shutdown(), "unchanged-value controller failed to shut down")

print("[PlayerData.ResetOnJoin] regression passed")
