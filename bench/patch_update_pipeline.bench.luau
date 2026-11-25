--!nocheck
-- Patch-only counterpart to update_validation_pipeline.bench.luau.
-- Uses the same profile shape, mutation count, and touched paths for a like-for-like comparison.
local Shim = require("./RobloxShim")
local RecordStore = Shim.load()

local ITEM_COUNT = 240
local QUEST_COUNT = 80
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
for index = 1, QUEST_COUNT do
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

local expected_inventory_counts = table.create(ITEM_COUNT)
local expected_inventory_attack = table.create(ITEM_COUNT)
for index = 1, ITEM_COUNT do
	expected_inventory_counts[index] = inventory[index].Count
	expected_inventory_attack[index] = inventory[index].Stats.Attack
end
local expected_quest_progress = {}
for index = 1, QUEST_COUNT do
	expected_quest_progress["quest_" .. tostring(index)] = quests["quest_" .. tostring(index)].Progress
end

local expected_coins = 0
local expected_gems = 0
local expected_gems_by_step = table.create(UPDATE_COUNT)
for step = 1, UPDATE_COUNT do
	expected_coins += step * 3
	expected_gems += step % 5
	expected_gems_by_step[step] = expected_gems
	local item_index = (step * 37) % ITEM_COUNT + 1
	expected_inventory_counts[item_index] += 1
	expected_inventory_attack[item_index] += 2
	local quest_key = "quest_" .. tostring((step * 11) % QUEST_COUNT + 1)
	expected_quest_progress[quest_key] += 1
end

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

for step = 1, UPDATE_COUNT do
	local item_index = (step * 37) % ITEM_COUNT + 1
	local quest_key = "quest_" .. tostring((step * 11) % QUEST_COUNT + 1)
	local status, message = record:Patch({
		{ op = "set", path = { "Revision" }, value = step },
		{ op = "set", path = { "Coins" }, value = step * (step + 1) * 3 / 2 },
		{ op = "set", path = { "Gems" }, value = expected_gems_by_step[step] },
		{ op = "set", path = { "Inventory", item_index, "Count" }, value = expected_inventory_counts[item_index] },
		{ op = "set", path = { "Inventory", item_index, "Stats", "Attack" }, value = expected_inventory_attack[item_index] },
		{ op = "set", path = { "Quests", quest_key, "Progress" }, value = expected_quest_progress[quest_key] },
	})
	assert(status == "success", message)
end

assert(record.Data.Revision == UPDATE_COUNT, "Patch workload lost a revision")
assert(record.Data.Coins == expected_coins, "Patch workload coin checksum mismatch")
assert(record.Data.Gems == expected_gems, "Patch workload gem checksum mismatch")
for index = 1, ITEM_COUNT do
	assert(record.Data.Inventory[index].Count == expected_inventory_counts[index],
		"Patch workload inventory count checksum mismatch")
	assert(record.Data.Inventory[index].Stats.Attack == expected_inventory_attack[index],
		"Patch workload inventory stat checksum mismatch")
end
for index = 1, QUEST_COUNT do
	local key = "quest_" .. tostring(index)
	assert(record.Data.Quests[key].Progress == expected_quest_progress[key],
		"Patch workload quest checksum mismatch")
end
local checksum = record.Data.Revision + record.Data.Coins + record.Data.Gems
assert(checksum > 0, "Patch workload checksum is empty")

local closed, close_message = record:Close()
assert(closed == "closed" or closed == "fenced", close_message)
RecordStore.Mock.reset()
Shim.close()
print(string.format("[patch-validation] updates=%d items=%d checksum=%d",
	UPDATE_COUNT, ITEM_COUNT, checksum))
