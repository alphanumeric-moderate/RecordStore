--!nocheck
local Shim = require("./RobloxShim")
local RecordStore = Shim.load()

local WIDTH = 750

local function make_profile()
	local wide = table.create(WIDTH)
	for index = 1, WIDTH do
		wide["item-" .. string.format("%04d", index)] = {
			Count = index,
			Stable = index * 2,
		}
	end
	return { Wide = wide, Revision = 0 }
end

RecordStore.Mock.reset()
local record = RecordStore.Mock.new("Bench_ChangeDiff", "global", "wide-profile", { schema_version = 1 })
local open_result, open_message = record:Open(make_profile())
assert(open_result == "created", open_message)

local subscription, subscribe_result, subscribe_message = record:SubscribeChanges(function(_event)
	return
end)
assert(subscription ~= nil and subscribe_result == "success", subscribe_message)

local result, message = record:Update(function(data)
	local next_data = table.clone(data)
	local next_wide = table.clone(data.Wide)
	local key = "item-0375"
	local item = table.clone(next_wide[key])
	item.Count += 1
	next_wide[key] = item
	next_data.Wide = next_wide
	next_data.Revision += 1
	return next_data
end)
assert(result == "success", message)
subscription:Disconnect()
assert(record:Close() == "closed")
RecordStore.Mock.reset()
Shim.close()
