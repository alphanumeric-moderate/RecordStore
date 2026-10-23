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
local open_result, open_message = record:Open({ Revision = 0, Archive = make_archive() })
assert(open_result == "created", open_message)

local subscription, subscribe_result, subscribe_message = record:SubscribeChanges(function(_event)
	return
end)
assert(subscription ~= nil and subscribe_result == "success", subscribe_message)

local ITERATIONS = 16
for _ = 1, ITERATIONS do
	local result, message = record:Update(function(data)
		local next_data = table.clone(data)
		local next_archive = table.clone(data.Archive)
		local key = "item-0500"
		local item = table.clone(next_archive[key])
		item.Count += 1
		next_archive[key] = item
		next_data.Archive = next_archive
		next_data.Revision += 1
		return next_data
	end)
	assert(result == "success", message)
end
local final_data = record:Get()
local final_archive = final_data.Archive
assert(final_data.Revision == ITERATIONS, "not all sparse profile updates were applied")
assert(final_archive["item-0500"].Count == 500 + ITERATIONS, "target counter update was not applied")
subscription:Disconnect()
assert(record:Close() == "closed")
RecordStore.Mock.reset()
Shim.close()
