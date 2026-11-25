--!nocheck
-- Isolated Record:Reconcile workloads for large profiles.
-- No-op reconciliation and default insertion are timed separately; setup is outside the timed intervals.
local Shim = require("./RobloxShim")
local RecordStore = Shim.load()

local ITEM_COUNT = 480
local QUEST_COUNT = 120
local NOOP_ITERATIONS = 32

local function build_profile()
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

	return {
		Revision = 0,
		Coins = 0,
		Gems = 0,
		Level = 1,
		Inventory = inventory,
		Quests = quests,
		Settings = { Music = true, Sfx = true, Volume = 0.5 },
	}
end

RecordStore.Mock.reset()
local initial = build_profile()
local template = build_profile()
local record = RecordStore.Mock.new("Bench_ReconcilePipeline", "global", "large-player", {
	schema_version = 1,
	autosave_interval = 1000,
	lease_duration = 180,
	lease_renewal = 60,
	operation_deadline = 20,
	retry_attempts = 1,
})
local opened, open_message = record:Open(initial)
assert(opened == "created" or opened == "loaded", open_message)

local warmup_status, warmup_message = record:Reconcile(template)
assert(warmup_status == "success", warmup_message)

local noop_start = os.clock()
for _ = 1, NOOP_ITERATIONS do
	local status, message = record:Reconcile(template)
	assert(status == "success", message)
end
local noop_elapsed = os.clock() - noop_start

template.ReconcileDefaults = {
	Enabled = true,
	Nested = { Value = 17, Label = "inserted" },
	List = { "one", "two", "three" },
}
local defaults_start = os.clock()
local defaults_status, defaults_message = record:Reconcile(template)
local defaults_elapsed = os.clock() - defaults_start
assert(defaults_status == "success", defaults_message)
assert(record.Data.ReconcileDefaults.Nested.Value == 17
	and record.Data.ReconcileDefaults.List[3] == "three",
	"Reconcile failed to insert nested defaults")

local checksum = record.Data.Revision + record.Data.Coins + record.Data.Gems
	+ record.Data.Inventory[ITEM_COUNT].Count + record.Data.Quests["quest_" .. tostring(QUEST_COUNT)].Progress
assert(checksum > 0, "Reconcile benchmark checksum is empty")

local closed, close_message = record:Close()
assert(closed == "closed" or closed == "fenced", close_message)
RecordStore.Mock.reset()
Shim.close()

print(string.format(
	"[reconcile-pipeline] noop_iterations=%d noop_total_ms=%.4f noop_mean_ms=%.4f defaults_total_ms=%.4f checksum=%d",
	NOOP_ITERATIONS,
	noop_elapsed * 1000,
	noop_elapsed * 1000 / NOOP_ITERATIONS,
	defaults_elapsed * 1000,
	checksum
))
