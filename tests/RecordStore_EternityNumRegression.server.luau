--!nocheck
-- Regression test: a classic EternityNum triplet survives RecordStore save and reopen.
-- Uses RecordStore.Mock only; no live DataStore request is made.

local RecordStore = require(game:GetService("ServerScriptService"):WaitForChild("RecordStore"))

RecordStore.Mock.reset()

local store_name = "RecordStore_EternityNumRegression"
local scope = "global"
local key = "cash"
local initial = { cash = { 1, 1, 11 }, untouched = 42 }

local record = RecordStore.Mock.new(store_name, scope, key, { schema_version = 1 })
local open_result, open_message = record:Open(initial)
assert(open_result == "created", tostring(open_message))

local loaded = record:Get()
assert(type(loaded.cash) == "table", "EternityNum tuple should remain a table")
assert(loaded.cash[1] == 1 and loaded.cash[2] == 1 and loaded.cash[3] == 11, "initial tuple changed")
assert(loaded.untouched == 42, "other player data changed")

local update_result, update_message = record:Update(function(current)
	current.cash = { 1, 2, 15 }
	return current
end)
assert(update_result == "success", tostring(update_message))

local close_result, close_message = record:Close()
assert(close_result == "closed", tostring(close_message))

local raw = RecordStore.Mock.get_record_raw(store_name, scope, key)
assert(type(raw) == "table" and type(raw.data) == "table", "persisted envelope is missing")
assert(raw.data.cash[1] == 1 and raw.data.cash[2] == 2 and raw.data.cash[3] == 15, "raw tuple changed")

local reload_result, reload_message = record:Open({ cash = { 1, 0, 0 }, untouched = 0 })
assert(reload_result == "loaded", tostring(reload_message))
local reloaded = record:Get()
assert(
	type(reloaded.cash) == "table"
		and reloaded.cash[1] == 1
		and reloaded.cash[2] == 2
		and reloaded.cash[3] == 15,
	"EternityNum tuple failed to survive save/close/reopen"
)
assert(reloaded.untouched == 42, "other data changed after reload")

local close_again, close_again_message = record:Close()
assert(close_again == "closed", tostring(close_again_message))
RecordStore.Mock.reset()
print("[RecordStore] EternityNum tuple persistence regression passed")
