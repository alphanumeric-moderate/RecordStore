--!nocheck
local Shim = require("./RobloxShim")
local RecordStore = Shim.load()

local WIDTH = 500

local function make_inventory()
	local inventory = table.create(WIDTH)
	for index = 1, WIDTH do
		inventory[index] = {
			Id = "item-" .. string.format("%04d", index),
			Count = index % 7 + 1,
			Stats = { Attack = index % 17 },
		}
	end
	return inventory
end

local function make_template()
	local inventory = table.create(WIDTH)
	for index = 1, WIDTH do
		inventory[index] = {
			Count = 0,
			Equipped = false,
			Stats = {
				Attack = 0,
				Defense = index % 13,
				Durability = 100,
			},
		}
	end
	return {
		Inventory = inventory,
		Settings = { Music = true, Sfx = true, Volume = 0.5 },
		Flags = { FirstJoin = true, TutorialComplete = false },
	}
end

RecordStore.Mock.reset()
local record = RecordStore.Mock.new("Bench_Reconcile", "global", "large-profile", { schema_version = 1 })
local open_result, open_message = record:Open({ Inventory = make_inventory(), Coins = 100 })
assert(open_result == "created", open_message)

local result, message = record:Reconcile(make_template())
assert(result == "success", message)
local data = record.Data
local first_item = data.Inventory[1]
assert(first_item.Id == "item-0001" and first_item.Count == 2 and first_item.Equipped == false, "Reconcile changed existing values or missed defaults")
assert(first_item.Stats.Attack == 1 and first_item.Stats.Defense == 1 and first_item.Stats.Durability == 100, "Reconcile nested defaults missing")
assert(data.Settings.Sfx == true and data.Flags.FirstJoin == true, "Reconcile subtree defaults missing")
assert(record:Close() == "closed")
RecordStore.Mock.reset()
Shim.close()
