--!nocheck
local Shim = require("./RobloxShim")
local RecordStore = Shim.load("./src/RecordStore.preoptimization.luau")

local WIDTH = 750
local UPDATES = 8

local function make_profile()
	local wide = table.create(WIDTH)
	for index = 1, WIDTH do
		wide["item-" .. string.format("%04d", index)] = {
			Count = index,
			Stable = index * 2,
			Nested = { Rank = index % 13, Active = true },
		}
	end
	return { Wide = wide, Coins = 0, Revision = 0 }
end

RecordStore.Mock.reset()
local record = RecordStore.Mock.new("Bench_UpdateSync", "global", "no-observers", { schema_version = 1 })
local open_result, open_message = record:Open(make_profile())
assert(open_result == "created", open_message)

for _ = 1, UPDATES do
	local result, message = record:Update(function(data)
		data.Coins += 1
		data.Revision += 1
		return data
	end)
	assert(result == "success", message)
end

local data = record.Data
assert(type(data) == "table" and data.Coins == UPDATES and data.Revision == UPDATES, "Update benchmark produced incorrect data")
assert(record:Close() == "closed")
RecordStore.Mock.reset()
Shim.close()
