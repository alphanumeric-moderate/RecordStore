--!strict

local RecordStore = require(game:GetService("ServerScriptService"):WaitForChild("RecordStore"))

RecordStore.Mock.reset()
do
	local record = RecordStore.Mock.new("RecordStore_ReconcileInPlaceRegression", "global", "nested-template", { schema_version = 1 })
	local open_result, open_message = record:Open({
		Coins = 200,
		Inventory = {
			{ Id = "Sword", Count = 2, Stats = { Attack = 5 } },
		},
		Settings = { Music = true },
	})
	assert(open_result == "created" or open_result == "loaded", open_message)
	local reconcile_result, reconcile_message = record:Reconcile({
		Coins = 0,
		Inventory = {
			{ Count = 0, Equipped = false, Stats = { Attack = 0, Defense = 3, Durability = 100 } },
		},
		Settings = { Music = false, Sfx = true },
		Badges = { First = true },
	})
	assert(reconcile_result == "success", reconcile_message)
	local data = record:Get() :: { [string]: RecordStore.JsonValue }
	assert(data["Coins"] == 200, "Reconcile replaced an existing scalar with a template value")
	local inventory = data["Inventory"] :: { RecordStore.JsonValue }
	local item = inventory[1] :: { [string]: RecordStore.JsonValue }
	assert(item["Id"] == "Sword" and item["Count"] == 2, "Reconcile replaced existing inventory values")
	assert(item["Equipped"] == false, "Reconcile did not add a missing inventory field")
	local stats = item["Stats"] :: { [string]: RecordStore.JsonValue }
	assert(stats["Attack"] == 5 and stats["Defense"] == 3 and stats["Durability"] == 100, "Reconcile did not preserve and extend nested stats")
	local settings = data["Settings"] :: { [string]: RecordStore.JsonValue }
	assert(settings["Music"] == true and settings["Sfx"] == true, "Reconcile did not preserve and extend settings")
	local badges = data["Badges"] :: { [string]: RecordStore.JsonValue }
	assert(badges["First"] == true, "Reconcile did not add a missing subtree")

	local incompatible_result, incompatible_message = record:Reconcile({ Inventory = { Label = "ignored" } })
	assert(incompatible_result == "success", incompatible_message)
	local after_incompatible = record:Get() :: { [string]: RecordStore.JsonValue }
	local unchanged_inventory = after_incompatible["Inventory"] :: { RecordStore.JsonValue }
	assert(unchanged_inventory[1] ~= nil and (unchanged_inventory :: { [string]: RecordStore.JsonValue })["Label"] == nil, "incompatible template shape changed an array")

	local invalid_result = record:Reconcile({ Inventory = { [3] = { Count = 999 } } })
	assert(invalid_result == "validation", "sparse reconciled array should fail validation")
	local after_invalid = record:Get() :: { [string]: RecordStore.JsonValue }
	local valid_inventory = after_invalid["Inventory"] :: { RecordStore.JsonValue }
	assert(#valid_inventory == 1 and valid_inventory[2] == nil and valid_inventory[3] == nil, "failed Reconcile leaked partial mutations")
	local save_result, save_message = record:Save()
	assert(save_result == "saved", save_message)
	assert(record:Close() == "closed", "Reconcile regression record did not close")
	local reopen_result, reopen_message = record:Open({ Coins = 0, Inventory = {}, Settings = {} })
	assert(reopen_result == "loaded", reopen_message)
	local persisted = record:Get() :: { [string]: RecordStore.JsonValue }
	assert(persisted["Coins"] == 200, "Reconcile scalar preservation did not survive persistence")
	local persisted_inventory = persisted["Inventory"] :: { RecordStore.JsonValue }
	local persisted_item = persisted_inventory[1] :: { [string]: RecordStore.JsonValue }
	local persisted_stats = persisted_item["Stats"] :: { [string]: RecordStore.JsonValue }
	assert(persisted_stats["Defense"] == 3 and persisted_stats["Durability"] == 100, "Reconcile nested additions did not survive persistence")
	assert(record:Close() == "closed", "reopened Reconcile record did not close")
end

RecordStore.Mock.reset()
print("[PASS] Reconcile in-place merge preserves values, handles incompatible shapes, rejects invalid results atomically, and persists valid additions.")
