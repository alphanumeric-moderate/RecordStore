--!nocheck
-- RecordStore.Patch copy-on-write, validation, sequential operation, and public ownership regression.
local ServerScriptService = game:GetService("ServerScriptService")
local RecordStore = require(ServerScriptService.RecordStore)

RecordStore.Mock.reset()

local validator_calls = 0
local reject_validation = false
local function validator(_value)
	validator_calls += 1
	if reject_validation then
		return false, "test validator rejected the patch"
	end
	return true, nil
end

local record = RecordStore.Mock.new("RecordStore_Patch", "global", "copy-on-write", {
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
	Stats = { Coins = 100 },
	Inventory = {
		{ Id = "first", Count = 1 },
		{ Id = "second", Count = 2 },
	},
	Settings = { Music = true, Volume = 0.5 },
	Tags = { "alpha", "beta", "gamma" },
})
assert(opened == "created" or opened == "loaded", open_message)
validator_calls = 0

local retained_before_patch = record.Data
local caller_owned_value = { Nested = { Items = { 1, 2 } } }
local status, message = record:Patch({
	{ op = "set", path = { "Stats", "Coins" }, value = 125 },
	{ op = "set", path = { "Inventory", 1, "Count" }, value = 5 },
	{ op = "remove", path = { "Settings", "Music" } },
	{ op = "remove", path = { "Tags", 2 } },
	{ op = "set", path = { "Tags", 3 }, value = "delta" },
	{ op = "set", path = { "Profile" }, value = caller_owned_value },
})
assert(status == "success", message)
assert(validator_calls == 1, "custom validator was not called exactly once for a valid patch")
assert(record.Data.Stats.Coins == 125, "set did not update the requested dictionary path")
assert(record.Data.Inventory[1].Count == 5, "set did not update the requested nested array path")
assert(record.Data.Settings.Music == nil, "remove did not delete the requested dictionary field")
assert(#record.Data.Tags == 3 and record.Data.Tags[1] == "alpha"
	and record.Data.Tags[2] == "gamma" and record.Data.Tags[3] == "delta",
	"array remove/append did not preserve dense array ordering")
assert(record.Data.Profile.Nested.Items[1] == 1, "set did not copy the supplied nested value")

caller_owned_value.Nested.Items[1] = 999
assert(record.Data.Profile.Nested.Items[1] == 1,
	"Patch retained a caller-owned reference to its value payload")

retained_before_patch.Stats.Coins = 9000
retained_before_patch.Inventory[1].Count = 9000
assert(record.Data.Stats.Coins == 125 and record.Data.Inventory[1].Count == 5,
	"Patch shared mutable subtrees with an older public Data reference")

record.Data.Stats.Coins = 150
status, message = record:Patch({
	{ op = "set", path = { "Revision" }, value = 2 },
})
assert(status == "success", message)
assert(record.Data.Stats.Coins == 150 and record.Data.Revision == 2,
	"Patch did not preserve direct public Data mutations observed before the patch")
assert(validator_calls == 3,
	"external Data mutation and the following valid patch must each run the validator once")

local before_invalid = record:Get()
local validator_calls_before_invalid = validator_calls
status, message = record:Patch({
	{ op = "set", path = { "Missing", "Child" }, value = true },
})
assert(status == "invalid", "Patch accepted a path whose intermediate parent does not exist")
assert(record:Get().Stats.Coins == before_invalid.Stats.Coins
	and record:Get().Revision == before_invalid.Revision,
	"invalid path partially changed canonical data")
assert(validator_calls == validator_calls_before_invalid,
	"custom validator ran for a patch rejected before data validation")

status, message = record:Patch({
	{ op = "set", path = { "Profile", "BadArray" }, value = { [1] = "one", [3] = "three" } },
})
assert(status == "validation" and string.find(message or "", "dense arrays", 1, true) ~= nil,
	"Patch did not reject a sparse array value using the established shape-validation error")
assert(validator_calls == validator_calls_before_invalid,
	"custom validator ran after patch shape-validation failure")
assert(record.Data.Profile.BadArray == nil, "invalid patch value changed the live record")

local first_replacement_payload = table.create(50_001)
local final_replacement_payload = table.create(50_001)
for index = 1, 50_001 do
	first_replacement_payload[index] = index
	final_replacement_payload[index] = index + 1
end
status, message = record:Patch({
	{ op = "set", path = { "Profile", "BatchPayload" }, value = first_replacement_payload },
	{ op = "set", path = { "Profile", "BatchPayload" }, value = final_replacement_payload },
})
assert(status == "success", message)
assert(#record.Data.Profile.BatchPayload == 50_001
	and record.Data.Profile.BatchPayload[1] == 2
	and record.Data.Profile.BatchPayload[50_001] == 50_002,
	"replacing a large payload within one batch produced the wrong final value")

local validator_calls_before_limits = validator_calls
local deep_payload: any = true
for _ = 1, 63 do
	deep_payload = { Child = deep_payload }
end
status, message = record:Patch({
	{ op = "set", path = { "Profile", "TooDeep" }, value = deep_payload },
})
assert(status == "validation", "Patch accepted data that exceeds the total nesting-depth limit")
assert(record.Data.Profile.TooDeep == nil, "depth-invalid patch changed live record data")

status, message = record:Patch({
	{ op = "set", path = { "Profile", "ExtraPayload" }, value = final_replacement_payload },
})
assert(status == "validation", "Patch accepted data that exceeds the total node-count limit")
assert(record.Data.Profile.ExtraPayload == nil, "node-limit-invalid patch changed live record data")
assert(validator_calls == validator_calls_before_limits,
	"custom validator ran for a patch rejected by aggregate shape limits")

status, message = record:Patch({
	{ op = "set", path = { "Profile", "PositiveInfinity" }, value = math.huge },
})
assert(status == "success", message)
assert(record.Data.Profile.PositiveInfinity == math.huge,
	"Patch did not preserve a non-finite value in the live record")

status, message = record:Patch({
	{ op = "set", path = { "Profile", "雪" }, value = "雪" },
})
assert(status == "success", message)
assert(record.Data.Profile["雪"] == "雪",
	"Patch rejected or changed valid non-ASCII dictionary data")

local caller_owned_buffer = buffer.fromstring("patch-buffer")
status, message = record:Patch({
	{ op = "set", path = { "Profile", "Binary" }, value = caller_owned_buffer },
})
assert(status == "validation" and string.find(message or "", "JSON-encodable", 1, true) ~= nil,
	"Patch accepted a buffer value that the persisted JSON format cannot encode")
assert(record.Data.Profile.Binary == nil,
	"Patch published a buffer payload rejected by persistence validation")
assert(buffer.tostring(caller_owned_buffer) == "patch-buffer",
	"Patch mutated a caller-owned buffer while rejecting it")

local oversized_payload = {
	Left = string.rep("x", 2_097_200),
	Right = string.rep("y", 2_097_200),
}
local validator_calls_before_oversized = validator_calls
status, message = record:Patch({
	{ op = "set", path = { "Profile", "Oversized" }, value = oversized_payload },
})
assert(status == "validation"
	and string.find(message or "", "serialized value exceeds", 1, true) ~= nil,
	"Patch did not reject a payload whose encoded lower bound exceeds the DataStore limit")
assert(record.Data.Profile.Oversized == nil,
	"oversized Patch payload changed the live record")
assert(validator_calls == validator_calls_before_oversized,
	"custom validator ran before the Patch size lower-bound rejection")

local before_atomic_failure = record:Get()
local validator_calls_before_atomic_failure = validator_calls
status, message = record:Patch({
	{ op = "set", path = { "Stats", "Coins" }, value = 999 },
	{ op = "set", path = { "Missing", "Child" }, value = true },
})
assert(status == "invalid", "Patch accepted a batch containing a later invalid operation")
assert(record.Data.Stats.Coins == before_atomic_failure.Stats.Coins,
	"a valid earlier operation was partially published before a later operation failed")
assert(validator_calls == validator_calls_before_atomic_failure,
	"custom validator ran for a batch rejected during path application")

reject_validation = true
status, message = record:Patch({
	{ op = "set", path = { "Revision" }, value = 99 },
})
reject_validation = false
assert(status == "validation" and string.find(message or "", "test validator rejected", 1, true) ~= nil,
	"Patch did not return the configured custom-validator rejection")
assert(record.Data.Revision == before_atomic_failure.Revision,
	"custom-validator rejection partially published the patched record")
assert(validator_calls == validator_calls_before_atomic_failure + 1,
	"custom validator was not called exactly once for a rejected, shape-valid patch")

status, message = record:Patch({
	{ op = "remove", path = {} },
})
assert(status == "invalid", "Patch accepted an empty/root path")

status, message = record:Patch({
	{ op = "replace", path = { "Revision" }, value = 3 },
})
assert(status == "invalid", "Patch accepted an unknown operation")

local retained_after_patch = record.Data
local save_status, save_message = record:Save()
assert(save_status == "saved", save_message)
local closed, close_message = record:Close()
assert(closed == "closed" or closed == "fenced", close_message)

retained_after_patch.Stats.Coins = 7777
assert(record.Data.Stats.Coins == 150,
	"a retained pre-close patched Data reference mutated the detached record")

local reopened, reopen_message = record:Open({
	Revision = 0,
	Stats = { Coins = 0 },
	Inventory = {},
	Settings = {},
	Tags = {},
})
assert(reopened == "loaded", reopen_message)
assert(record.Data.Stats.Coins == 150 and record.Data.Revision == 2
	and record.Data.Inventory[1].Count == 5 and record.Data.Tags[2] == "gamma"
	and record.Data.Profile.PositiveInfinity == math.huge
	and record.Data.Profile["雪"] == "雪",
	"patch data was not durably persisted or was affected by a retained reference")

local closed_again, close_again_message = record:Close()
assert(closed_again == "closed" or closed_again == "fenced", close_again_message)
RecordStore.Mock.reset()
print("[RecordStore.Patch] copy-on-write, validation, ordering, and isolation regressions passed")
