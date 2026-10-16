--!nocheck
local Shim = require("./RobloxShim")
local RecordStore = Shim.load("./src/RecordStore.preoptimization.luau")

local INVENTORY_SIZE = 150
local UPDATES = 5

local function make_profile()
	local inventory = table.create(INVENTORY_SIZE)
	for i = 1, INVENTORY_SIZE do
		inventory[i] = {
			Id = "item-" .. i,
			Count = i % 7 + 1,
			Rarity = if i % 10 == 0 then "Legendary" else "Common",
			Stats = { Attack = i % 13, Defense = i % 11, Durability = 100 },
		}
	end
	local quests = {}
	for i = 1, 50 do
		quests["quest_" .. i] = { Progress = 0, Completed = false }
	end
	return {
		Coins = 0,
		Gems = 0,
		Level = 1,
		Inventory = inventory,
		Quests = quests,
		Settings = { Music = true, Sfx = true, Volume = 0.5 },
	}
end

RecordStore.Mock.reset()
local changes = 0
local record = RecordStore.Mock.new("Bench_LargeProfile", "global", "player-large", { schema_version = 1 })
local subscription = record:SubscribeChanges(function()
	changes += 1
end)
local open_result, open_message = record:Open(make_profile())
assert(open_result == "created", open_message)

for step = 1, UPDATES do
	local result, message = record:Update(function(data)
		local next_data = table.clone(data)
		next_data.Coins += 25
		next_data.Inventory = table.clone(data.Inventory)
		local index = (step * 37) % INVENTORY_SIZE + 1
		local item = table.clone(next_data.Inventory[index])
		item.Count += 1
		next_data.Inventory[index] = item
		next_data.Quests = table.clone(data.Quests)
		next_data.Quests["quest_" .. step] = { Progress = 100, Completed = true }
		return next_data
	end)
	assert(result == "success", message)
	local save_result, save_message = record:Save()
	assert(save_result == "saved", save_message)
end

-- Direct mutation of the public Data table is captured on Close.
record.Data.Gems = 999
local close_result, close_message = record:Close()
assert(close_result == "closed", close_message)
if subscription ~= nil then
	subscription:Disconnect()
end

local reopen_result, reopen_message = record:Open(make_profile())
assert(reopen_result == "loaded", reopen_message)
assert(record:Get().Gems == 999, "direct mutation was not persisted")
assert(record:Get().Coins == 25 * UPDATES, "updates were not persisted")
record:Close()
RecordStore.Mock.reset()
Shim.close()
