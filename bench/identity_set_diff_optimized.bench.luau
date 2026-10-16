--!nocheck
local Shim = require("./RobloxShim")
local RecordStore = Shim.load()

local WIDTH = 500

local function make_profile()
	local inventory = table.create(WIDTH)
	local quests = {}
	for index = 1, WIDTH do
		inventory[index] = {
			Id = "item-" .. string.format("%04d", index),
			Count = index % 7 + 1,
			Stats = { Attack = index % 17, Defense = index % 11, Durability = 100 },
		}
		quests["quest_" .. index] = {
			Progress = index % 100,
			Completed = index % 3 == 0,
		}
	end
	return {
		Coins = 100,
		Inventory = inventory,
		Quests = quests,
		Settings = { Music = true, Sfx = true, Volume = 0.5 },
	}
end

RecordStore.Mock.reset()
local record = RecordStore.Mock.new("Bench_IdentitySetDiff", "global", "large-profile", { schema_version = 1 })
local subscription, subscribe_result, subscribe_message = record:SubscribeChanges(function(_event)
end)
assert(subscription ~= nil and subscribe_result == "success", subscribe_message)
local open_result, open_message = record:Open(make_profile())
assert(open_result == "created", open_message)
local update_result, update_message = record:Update(function(data)
	data.Coins += 1
	return data
end)
assert(update_result == "success", update_message)
subscription:Disconnect()
assert(record:Close() == "closed")
RecordStore.Mock.reset()
Shim.close()
