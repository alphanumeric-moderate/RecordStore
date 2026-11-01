--!nocheck
-- RecordStore.Update copy, shape validation, validator, and ownership regression.
local ServerScriptService = game:GetService("ServerScriptService")
local RecordStore = require(ServerScriptService.RecordStore)

RecordStore.Mock.reset()

local validator_calls = 0
local function validator(_value)
	validator_calls += 1
	return true, nil
end

local record = RecordStore.Mock.new("RecordStore_UpdateValidation", "global", "copy-and-shape", {
	schema_version = 1,
	autosave_interval = 1000,
	lease_duration = 180,
	lease_renewal = 60,
	operation_deadline = 20,
	retry_attempts = 1,
	validator = validator,
})

local opened, open_message = record:Open({
	Revision = 0,
	Inventory = {
		{ Id = "first", Count = 1, Stats = { Attack = 10 } },
		{ Id = "second", Count = 2, Stats = { Attack = 20 } },
	},
	Settings = { Music = true, Volume = 0.5 },
})
assert(opened == "created" or opened == "loaded", open_message)
validator_calls = 0

local retained_result = nil
local status, message = record:Update(function(current)
	assert(type(current) == "table", "Update callback did not receive a table")
	local next_data = table.clone(current)
	next_data.Inventory = table.clone(current.Inventory)
	next_data.Inventory[1] = table.clone(next_data.Inventory[1])
	next_data.Inventory[1].Count += 1
	next_data.Inventory[1].Stats = table.clone(next_data.Inventory[1].Stats)
	next_data.Inventory[1].Stats.Attack += 5
	next_data.Revision += 1
	retained_result = next_data
	return next_data
end)
assert(status == "success", message)
assert(validator_calls == 1, "custom validator was not called exactly once for a valid update")
assert(record.Data.Revision == 1 and record.Data.Inventory[1].Count == 2,
	"valid Update did not publish the updated data")

retained_result.Inventory[1].Count = 9000
retained_result.Inventory[1].Stats.Attack = 9000
retained_result.Settings.Volume = 0
local detached = record:Get()
assert(detached.Inventory[1].Count == 2 and detached.Inventory[1].Stats.Attack == 15,
	"Update retained caller-owned nested references")
assert(detached.Settings.Volume == 0.5,
	"Update retained a caller-owned reference to an untouched nested table")

local sparse = { [1] = "one", [3] = "three" }
status, message = record:Update(function(current)
	local next_data = table.clone(current)
	next_data.BadArray = sparse
	return next_data
end)
assert(status == "validation" and string.find(message or "", "dense arrays", 1, true) ~= nil,
	"sparse arrays were not rejected with the established shape-validation error")
assert(validator_calls == 1, "custom validator ran after a shape-validation failure")
assert(record.Data.Revision == 1, "invalid sparse update changed the live record")

local overlong = string.rep("x", 4_000_001)
status, message = record:Update(function(current)
	local next_data = table.clone(current)
	next_data.BadString = overlong
	return next_data
end)
assert(status == "validation" and string.find(message or "", "overlong string", 1, true) ~= nil,
	"overlong strings were not rejected with the established validation error")
assert(validator_calls == 1, "custom validator ran after an overlong-string failure")

local too_many_nodes = table.create(100_001)
for index = 1, 100_001 do
	too_many_nodes[index] = index
end
status, message = record:Update(function(current)
	local next_data = table.clone(current)
	next_data.TooManyNodes = too_many_nodes
	return next_data
end)
assert(status == "validation" and string.find(message or "", "maximum node count", 1, true) ~= nil,
	"oversized values were not rejected by the node-count limit")
assert(validator_calls == 1, "custom validator ran after a node-count failure")

local cyclic = {}
cyclic.self = cyclic
status, message = record:Update(function()
	return cyclic
end)
assert(status == "validation" and string.find(message or "", "invalid data", 1, true) ~= nil,
	"cyclic callback results did not retain the existing invalid-data result")
assert(validator_calls == 1, "custom validator ran after cyclic-data rejection")

local too_deep = {}
local cursor = too_deep
for _ = 1, 66 do
	local child = {}
	cursor.child = child
	cursor = child
end
status, message = record:Update(function()
	return too_deep
end)
assert(status == "validation" and string.find(message or "", "invalid data", 1, true) ~= nil,
	"excessive nesting did not retain the existing invalid-data result")
assert(validator_calls == 1, "custom validator ran after excessive-depth rejection")
assert(record.Data.Revision == 1, "invalid updates changed canonical data")

local closed, close_message = record:Close()
assert(closed == "closed" or closed == "fenced", close_message)
RecordStore.Mock.reset()
print("[RecordStore.Update] copy isolation and shape-validation regressions passed")
