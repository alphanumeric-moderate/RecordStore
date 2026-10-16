--!nocheck
-- CodeNum JSON payload persistence regression. Uses RecordStore.Mock only.
local RecordStore = require(game:GetService("ServerScriptService"):WaitForChild("RecordStore"))
RecordStore.Mock.reset()
local store_name, scope, key = "RecordStore_CodeNumRegression", "global", "cash"
local serialized = '{"schema":"CodeNum","version":2,"value":{"kind":"hyper","base":{"kind":"finite","value":10},"arrows":{"kind":"integer","sign":1,"digits":"100"},"height":{"kind":"finite","value":10}}}'
local record = RecordStore.Mock.new(store_name, scope, key, { schema_version = 1 })
local opened, open_message = record:Open({ cash = serialized, untouched = 42 })
assert(opened == "created", tostring(open_message))
assert(record:Get().cash == serialized, "initial CodeNum payload changed")
local updated, update_message = record:Update(function(current)
	current.untouched = 43
	return current
end)
assert(updated == "success", tostring(update_message))
local closed, close_message = record:Close()
assert(closed == "closed", tostring(close_message))
local raw = RecordStore.Mock.get_record_raw(store_name, scope, key)
assert(type(raw) == "table" and type(raw.data) == "table", "stored envelope missing")
assert(raw.data.cash == serialized, "raw CodeNum JSON payload changed")
local reloaded, reload_message = record:Open({ cash = "unused", untouched = 0 })
assert(reloaded == "loaded", tostring(reload_message))
assert(record:Get().cash == serialized, "CodeNum payload failed close/reopen")
assert(record:Get().untouched == 43, "other data changed after reload")
local closed_again, close_again_message = record:Close()
assert(closed_again == "closed", tostring(close_again_message))
RecordStore.Mock.reset()
print("[RecordStore] CodeNum JSON persistence regression passed")
