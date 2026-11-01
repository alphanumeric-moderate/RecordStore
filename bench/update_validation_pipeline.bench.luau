--!nocheck
-- Isolated RecordStore.Update workload for a large nested profile.
-- This measures the in-memory callback/copy/validation path plus final close.
local Shim = require("./RobloxShim")
local RecordStore = Shim.load()

local ITEM_COUNT = 240
local UPDATE_COUNT = 32

local inventory = table.create(ITEM_COUNT)
for index = 1, ITEM_COUNT do
	inventory[index] = {
		Id = "item-" .. tostring(index),
		Count = index % 7 + 1,
		Rarity = if index % 10 == 0 then "Legendary" else "Common",
		Stats = {
			Attack = index % 17,
			Defense = index % 13,
			Durability = 100,
			Modifiers = { Fire = index % 3, Ice = index % 5, Wind = index % 7 },
		},
	}
end

local quests = {}
for index = 1, 80 do
	quests["quest_" .. tostring(index)] = {
		Progress = index % 100,
		Completed = false,
		Rewards = { Coins = index * 10, Gems = index % 4 },
	}
end

local initial = {
	Revision = 0,
	Coins = 0,
	Gems = 0,
	Level = 1,
	Inventory = inventory,
	Quests = quests,
	Settings = { Music = true, Sfx = true, Volume = 0.5 },
}

RecordStore.Mock.reset()
local record = RecordStore.Mock.new("Bench_UpdateValidationPipeline", "global", "large-player", {
	schema_version = 1,
	autosave_interval = 1000,
	lease_duration = 180,
	lease_renewal = 60,
	operation_deadline = 20,
	retry_attempts = 1,
})
local opened, open_message = record:Open(initial)
assert(opened == "created" or opened == "loaded", open_message)

local expected_coins = 0
for step = 1, UPDATE_COUNT do
	local status, message = record:Update(function(current)
		current.Revision += 1
		current.Coins += step * 3
		current.Gems += step % 5
		local item_index = (step * 37) % ITEM_COUNT + 1
		current.Inventory[item_index].Count += 1
		current.Inventory[item_index].Stats.Attack += 2
		local quest_key = "quest_" .. tostring((step * 11) % 80 + 1)
		current.Quests[quest_key].Progress += 1
		return current
	end)
	assert(status == "success", message)
	expected_coins += step * 3
end

assert(record.Data.Revision == UPDATE_COUNT, "Update workload lost a revision")
assert(record.Data.Coins == expected_coins, "Update workload coin checksum mismatch")
assert(record.Data.Inventory ~= nil and record.Data.Quests ~= nil,
	"Update workload lost nested data")
local checksum = record.Data.Revision + record.Data.Coins + record.Data.Gems
assert(checksum > 0, "Update workload checksum is empty")

local closed, close_message = record:Close()
assert(closed == "closed" or closed == "fenced", close_message)
RecordStore.Mock.reset()
Shim.close()
print(string.format("[update-validation] updates=%d items=%d checksum=%d",
	UPDATE_COUNT, ITEM_COUNT, checksum))
