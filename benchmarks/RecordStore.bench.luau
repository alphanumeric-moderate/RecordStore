local serde = require("@lune/serde")

local guid_counter = 0
local http_service = {
	GenerateGUID = function()
		guid_counter += 1
		return ("00000000-0000-4000-8000-%012d"):format(guid_counter)
	end,
	JSONEncode = function(_, value)
		return serde.encode("json", value)
	end,
	JSONDecode = function(_, value)
		return serde.decode("json", value)
	end,
}

local data_store_service = {
	GetRequestBudgetForRequestType = function()
		return 100
	end,
	GetDataStore = function()
		error("RecordStore benchmark must use the mock backend")
	end,
}

local messaging_service = {
	PublishAsync = function()
		return true
	end,
	SubscribeAsync = function()
		return { Disconnect = function() end }
	end,
}

local services = {
	DataStoreService = data_store_service,
	HttpService = http_service,
	MessagingService = messaging_service,
}

local globals = getfenv(0)

-- Model the ModuleScript relationship expected by the Roblox source while
-- keeping this benchmark runnable under Lune's filesystem-based require.
local original_require = require
local scheduler_module_token = {}
globals.script = {
	Parent = {
		RecordStoreScheduler = scheduler_module_token,
	},
}
globals.require = function(target)
	if target == scheduler_module_token then
		return original_require("../src/PlayerDataInitializer/RecordStoreScheduler")
	end
	return original_require(target)
end

globals.game = {
	JobId = "recordstore-codspeed-benchmark",
	PlaceId = 1,
	GetService = function(_, name)
		local service = services[name]
		assert(service ~= nil, ("unexpected service request: %s"):format(name))
		return service
	end,
	BindToClose = function() end,
}
globals.Enum = {
	DataStoreRequestType = {
		StandardRead = "StandardRead",
		StandardWrite = "StandardWrite",
		StandardList = "StandardList",
	},
	SortDirection = {
		Ascending = "Ascending",
		Descending = "Descending",
	},
}
globals.DateTime = {
	now = function()
		return { UnixTimestampMillis = os.time() * 1000 }
	end,
}
globals.task = {
	spawn = function() end,
	wait = function(seconds)
		return seconds or 0
	end,
}

local variant = "optimized"
local module_path = "../src/PlayerDataInitializer/RecordStore"
local RecordStore = require(module_path)
local iterations = 3000
local inventory = {}

for index = 1, 32 do
	inventory[index] = {
		Id = ("item-%03d"):format(index),
		Count = index % 5 + 1,
		Flags = { Bound = index % 2 == 0, Rare = index % 7 == 0 },
	}
end

RecordStore.Mock.reset()

local record = RecordStore.Mock.new("RecordStore_CodSpeedBenchmark", "global", "update-batch", {
	schema_version = 1,
})

local open_result, open_message = record:Open({
	Kills = 0,
	Coins = 10000,
	Inventory = inventory,
	Stats = { Wins = 100, Losses = 20, Playtime = 3600 },
	Settings = { Music = true, Effects = true, Sensitivity = 1 },
})

assert(open_result == "created" or open_result == "loaded", ("benchmark open failed: %s: %s"):format(open_result, open_message or "no message"))

for _ = 1, iterations do
	local result, message = record:Update(function(data)
		assert(type(data) == "table", "benchmark record data is not a table")
		data.Kills += 1
		data.Stats.Playtime += 1
		return data
	end)
	assert(result == "success", ("benchmark Update failed: %s: %s"):format(result, message or "no message"))
end

local close_result, close_message = record:Close()
assert(close_result == "closed", ("benchmark close failed: %s: %s"):format(close_result, close_message or "no message"))

print(("RecordStore.Mock Update batch completed: %d updates (%s)"):format(iterations, variant))
