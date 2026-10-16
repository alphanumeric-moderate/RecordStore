--!nocheck
-- Benchmark: full mock session lifecycle (create, update, save, close, reopen) for many keys.
local Shim = require("./RobloxShim")
local RecordStore = Shim.load()

local RECORDS = 40
local UPDATES_PER_SESSION = 5

local function expect(result: string, message: string?, ...: string)
	for _, accepted in { ... } do
		if result == accepted then
			return
		end
	end
	error(("unexpected result %s: %s"):format(result, message or "no message"), 2)
end

RecordStore.Mock.reset()
for i = 1, RECORDS do
	local record = RecordStore.Mock.new("Bench_Sessions", "global", "player-" .. i, { schema_version = 1 })
	expect(record:Open({ Coins = 0, Level = 1, Inventory = {} }), nil, "created")
	for step = 1, UPDATES_PER_SESSION do
		expect(record:Update(function(data)
			local next_data = table.clone(data)
			next_data.Coins += step * 10
			next_data.Level += 1
			next_data.Inventory = table.clone(data.Inventory)
			table.insert(next_data.Inventory, "item-" .. step)
			return next_data
		end), nil, "success")
	end
	expect(record:Save(), nil, "saved")
	expect(record:Close(), nil, "closed")

	expect(record:Open({ Coins = 0, Level = 1, Inventory = {} }), nil, "loaded")
	local data = record:Get()
	assert(data.Level == 1 + UPDATES_PER_SESSION, "updates were not persisted")
	expect(record:Close(), nil, "closed")
end
RecordStore.Mock.reset()
Shim.close()
