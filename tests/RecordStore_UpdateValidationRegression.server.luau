--!nocheck
-- RecordStore.Update copy, shape validation, validator, and ownership regression.
local ServerScriptService = game:GetService("ServerScriptService")
local RecordStore = require(ServerScriptService.RecordStore)

RecordStore.Mock.reset()

local validator_calls = 0
local mutate_validator_input = false
local function validator(value)
	validator_calls += 1
	if mutate_validator_input and type(value) == "table"
		and type(value.Inventory) == "table" and type(value.Inventory[1]) == "table"
	then
		value.Inventory[1].Count = 777777
	end
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

local save_status, save_message = record:Save()
assert(save_status == "saved", save_message)
assert(validator_calls == 2, "Save did not validate its detached snapshot exactly once")

local saved_snapshot = record:GetLastSaved()
assert(saved_snapshot ~= nil, "Save did not publish a last-saved snapshot")
saved_snapshot.Data.Inventory[1].Count = 123456
assert(record.Data.Inventory[1].Count == 2,
	"mutating a caller-owned last-saved snapshot changed the live record")

retained_result.Inventory[1].Count = 9000
retained_result.Inventory[1].Stats.Attack = 9000
retained_result.Settings.Volume = 0
local detached = record:Get()
assert(detached.Inventory[1].Count == 2 and detached.Inventory[1].Stats.Attack == 15,
	"Update retained caller-owned nested references")
assert(detached.Settings.Volume == 0.5,
	"Update retained a caller-owned reference to an untouched nested table")

record.Data.Inventory[1].Count = 3
mutate_validator_input = true
local direct_mutation_snapshot = record:Get()
mutate_validator_input = false
assert(validator_calls == 3, "direct Data mutation did not invoke the custom validator exactly once")
assert(direct_mutation_snapshot.Inventory[1].Count == 3 and record.Data.Inventory[1].Count == 3,
	"custom validator mutation escaped its isolated argument or changed accepted public data")

local sparse = { [1] = "one", [3] = "three" }
status, message = record:Update(function(current)
	local next_data = table.clone(current)
	next_data.BadArray = sparse
	return next_data
end)
assert(status == "validation" and string.find(message or "", "dense arrays", 1, true) ~= nil,
	"sparse arrays were not rejected with the established shape-validation error")
assert(validator_calls == 3, "custom validator ran after a shape-validation failure")
assert(record.Data.Revision == 1, "invalid sparse update changed the live record")

local overlong = string.rep("x", 4_000_001)
status, message = record:Update(function(current)
	local next_data = table.clone(current)
	next_data.BadString = overlong
	return next_data
end)
assert(status == "validation" and string.find(message or "", "overlong string", 1, true) ~= nil,
	"overlong strings were not rejected with the established validation error")
assert(validator_calls == 3, "custom validator ran after an overlong-string failure")

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
assert(validator_calls == 3, "custom validator ran after a node-count failure")

local oversized_iteration_count = 0
local virtual_oversized = setmetatable({}, {
	__iter = function()
		local index = 0
		return function()
			index += 1
			if index > 250_000 then
				return nil
			end
			oversized_iteration_count += 1
			return index, index
		end
	end,
})
status, message = record:Update(function(current)
	local next_data = table.clone(current)
	next_data.VirtualOversized = virtual_oversized
	return next_data
end)
assert(status == "validation" and string.find(message or "", "maximum node count", 1, true) ~= nil,
	"virtual oversized values were not rejected by the node-count limit")
assert(oversized_iteration_count < 100_000,
	("node-limit validation continued traversing after rejection: %d entries"):format(oversized_iteration_count))
assert(validator_calls == 3, "custom validator ran after early node-limit rejection")

local cyclic = {}
cyclic.self = cyclic
status, message = record:Update(function()
	return cyclic
end)
assert(status == "validation" and string.find(message or "", "invalid data", 1, true) ~= nil,
	"cyclic callback results did not retain the existing invalid-data result")
assert(validator_calls == 3, "custom validator ran after cyclic-data rejection")

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
assert(validator_calls == 3, "custom validator ran after excessive-depth rejection")
assert(record.Data.Revision == 1, "invalid updates changed canonical data")

local retained_public_data = record.Data
local closed, close_message = record:Close()
assert(closed == "closed" or closed == "fenced", close_message)
assert(validator_calls == 4, "Close did not validate its detached snapshot exactly once")

retained_public_data.Inventory[1].Count = 7777
assert(record.Data.Inventory[1].Count == 3,
	"retained pre-close public Data reference mutated the detached record")

local reopened, reopen_message = record:Open({
	Revision = 0,
	Inventory = {
		{ Id = "first", Count = 1, Stats = { Attack = 10 } },
		{ Id = "second", Count = 2, Stats = { Attack = 20 } },
	},
	Settings = { Music = true, Volume = 0.5 },
})
assert(reopened == "loaded", reopen_message)
assert(record.Data.Inventory[1].Count == 3,
	"mutating a retained pre-close reference changed the persisted profile after reopen")

local closed_again, close_again_message = record:Close()
assert(closed_again == "closed" or closed_again == "fenced", close_again_message)
RecordStore.Mock.reset()
print("[RecordStore.Update] copy isolation and shape-validation regressions passed")
