--!nocheck
-- Legacy numeric payload persistence regression. Uses RecordStore.Mock only.
local ServerScriptService = game:GetService("ServerScriptService")
local RecordStore = require(ServerScriptService.RecordStore)
RecordStore.Mock.reset()
local store_name, scope, key = "RecordStore_LegacyPayloadRegression", "global", "cash"

local invalid_options = {
	{
		options = { schema_version = 1, messaging_enabled = "false" },
		expected = "messaging_enabled",
	},
	{
		options = { schema_version = 1, durable_queue_enabled = 0 },
		expected = "durable_queue_enabled",
	},
	{
		options = { schema_version = 1, message_topic_prefix = string.rep("x", 73) },
		expected = "message_topic_prefix",
	},
	{
		options = { schema_version = 1, metadata = 123 },
		expected = "metadata must be a table",
	},
}
for index, fixture in ipairs(invalid_options) do
	local accepted, err = pcall(function()
		RecordStore.Mock.new(store_name, scope, "invalid-options-" .. tostring(index), fixture.options)
	end)
	assert(not accepted, "invalid RecordStore options were accepted: " .. fixture.expected)
	assert(
		string.find(tostring(err), fixture.expected, 1, true) ~= nil,
		"invalid RecordStore options returned an unexpected error: " .. tostring(err)
	)
end

local serialized = '{"schema":"CodeNum","version":2,"value":{"kind":"hyper","base":{"kind":"finite","value":10},"arrows":{"kind":"integer","sign":1,"digits":"100"},"height":{"kind":"finite","value":10}}}'
local record = RecordStore.Mock.new(store_name, scope, key, { schema_version = 1 })
local opened, open_message = record:Open({ cash = serialized, untouched = 42 })
assert(opened == "created", tostring(open_message))
assert(record:Get().cash == serialized, "initial legacy numeric payload changed")
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
assert(record:Get().cash == serialized, "legacy numeric payload failed close/reopen")
assert(record:Get().untouched == 43, "other data changed after reload")
local closed_again, close_again_message = record:Close()
assert(closed_again == "closed", tostring(close_again_message))
RecordStore.Mock.reset()
print("[RecordStore] CodeNum JSON persistence regression passed")
