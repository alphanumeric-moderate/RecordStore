--!nocheck

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local task = require("@lune/task")
local serde = require("@lune/serde")

local SOURCES = {
	PlayerData = fs.readFile("src/PlayerDataInitializer/PlayerData.luau"),
	PlayerDataCore = fs.readFile("src/PlayerDataInitializer/PlayerDataCore.luau"),
	IntegerInfinityValue = fs.readFile("src/PlayerDataInitializer/IntegerInfinityValue.luau"),
	InfiniteMathValue = fs.readFile("src/PlayerDataInitializer/InfiniteMathValue.luau"),
	Initializer = fs.readFile("src/PlayerDataInitializer/init.server.luau"),
}

local MODULE_PATHS = {
	RecordStore = "mock",
	PlayerData = "src/PlayerDataInitializer/PlayerData.luau",
	PlayerDataCore = "src/PlayerDataInitializer/PlayerDataCore.luau",
	IntegerInfinityValue = "src/PlayerDataInitializer/IntegerInfinityValue.luau",
	InfiniteMathValue = "src/PlayerDataInitializer/InfiniteMathValue.luau",
}

local function make_signal()
	local signal = {}

	function signal:Connect(_callback)
		return { Disconnect = function() end }
	end

	return signal
end

local function cold_start(eager_infinimath_value)
	local parent = {}
	local modules = {}

	for name in pairs(MODULE_PATHS) do
		local module = { Name = name, ClassName = "ModuleScript", Parent = parent }
		modules[name] = module
		parent[name] = module
	end

	local player_added = make_signal()
	local player_removing = make_signal()
	local players = {
		PlayerAdded = player_added,
		PlayerRemoving = player_removing,
		GetPlayers = function()
			return {}
		end,
	}

	local http_service = {
		JSONEncode = function(_self, value)
			return serde.encode("json", value)
		end,
		JSONDecode = function(_self, value)
			return serde.decode("json", value)
		end,
	}

	local game = {
		GetService = function(_self, name)
			if name == "Players" then return players end
			if name == "HttpService" then return http_service end
			error("unexpected startup service: " .. tostring(name), 2)
		end,
		BindToClose = function(_self, _callback) end,
	}

	local instance = {
		new = function(class_name)
			return { ClassName = class_name }
		end,
	}

	local require_counts = { InfiniteMathValue = 0 }
	local cache = {}
	local core_source = SOURCES.PlayerDataCore

	if eager_infinimath_value then
		local needle = 'local IntegerInfinityValueFactory = require(script.Parent.IntegerInfinityValue)\n'
		local index = string.find(core_source, needle, 1, true)
		assert(index ~= nil, "could not find PlayerDataCore's dependency insertion point")
		local insert_at = index + #needle
		core_source = string.sub(core_source, 1, insert_at - 1)
			.. 'local _legacy_eager_infinitemath_value_factory = require(script.Parent.InfiniteMathValue)\n'
			.. string.sub(SOURCES.PlayerDataCore, insert_at)
	end

	local require_module
	require_module = function(module)
		assert(type(module) == "table" and type(module.Name) == "string", "unexpected module reference")

		local cached = cache[module]
		if cached ~= nil then
			return cached
		end

		if module.Name == "RecordStore" then
			local record_store_stub = {}
			cache[module] = record_store_stub
			return record_store_stub
		end

		assert(MODULE_PATHS[module.Name] ~= nil, "unexpected module: " .. module.Name)

		if module.Name == "InfiniteMathValue" then
			require_counts.InfiniteMathValue += 1
		end

		local source = if module.Name == "PlayerDataCore" then core_source else SOURCES[module.Name]
		local result = luau.load(source, {
			debugName = module.Name,
			environment = {
				script = module,
				game = game,
				task = task,
				Instance = instance,
				require = require_module,
			},
		})()

		cache[module] = result
		return result
	end

	local initializer = luau.load(SOURCES.Initializer, {
		debugName = "PlayerDataInitializer",
		environment = {
			script = parent,
			game = game,
			task = task,
			Instance = instance,
			require = require_module,
		},
	})

	initializer()

	assert(
		require_counts.InfiniteMathValue == (eager_infinimath_value and 1 or 0),
		"optional InfiniteMathValue module-load count does not match the selected startup path"
	)
end

return function(eager_infinimath_value)
	local ITERATIONS = 25

	for _ = 1, ITERATIONS do
		cold_start(eager_infinimath_value)
	end

	print(if eager_infinimath_value
		then "[PlayerData startup] legacy eager InfiniteMathValue dependency passed"
		else "[PlayerData startup] lazy optional InfiniteMathValue dependency passed")
end
