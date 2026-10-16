--!nocheck
local Shim = require("./RobloxShim")
local RecordStore = Shim.load()

local WIDTH = 1000

local function make_archive()
	local archive = table.create(WIDTH)
	for index = 1, WIDTH do
		archive["item-" .. string.format("%04d", index)] = {
			Count = index,
			Stats = {
				Attack = index % 17,
				Defense = index % 13,
				Durability = 100,
			},
		}
	end
	return archive
end

RecordStore.Mock.reset()
local record = RecordStore.Mock.new("Bench_EventPayloads", "global", "subtree-payloads", { schema_version = 1 })
local open_result, open_message = record:Open({ Revision = 0 })
assert(open_result == "created", open_message)

local subscription, subscribe_result, subscribe_message = record:SubscribeChanges(function(_event)
	return
end)
assert(subscription ~= nil and subscribe_result == "success", subscribe_message)

local archive = make_archive()
local result, message = record:Update(function(data)
	local next_data = table.clone(data)
	next_data.Revision += 1
	next_data.Archive = archive
	return next_data
end)
assert(result == "success", message)
assert(type(record.Data.Archive) == "table", "Archive update was not applied")
subscription:Disconnect()
assert(record:Close() == "closed")
RecordStore.Mock.reset()
Shim.close()
