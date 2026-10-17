--!nocheck

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local task = require("@lune/task")

local SOURCES = {
	PlayerData = fs.readFile("src/PlayerDataInitializer/PlayerData.luau"),
	PlayerDataCore = fs.readFile("src/PlayerDataInitializer/PlayerDataCore.luau"),
	IntegerInfinityValue = fs.readFile("src/PlayerDataInitializer/IntegerInfinityValue.luau"),
	NumberFormatter = fs.readFile("src/PlayerDataInitializer/NumberFormatter.luau"),
	CodeNumValue = fs.readFile("src/PlayerDataInitializer/CodeNumValue.luau"),
	Initializer = fs.readFile("src/PlayerDataInitializer/init.server.luau"),
}

local MODULE_PATHS = {
	RecordStore = "mock",
	PlayerData = "src/PlayerDataInitializer/PlayerData.luau",
	PlayerDataCore = "src/PlayerDataInitializer/PlayerDataCore.luau",
	IntegerInfinityValue = "src/PlayerDataInitializer/IntegerInfinityValue.luau",
	NumberFormatter = "src/PlayerDataInitializer/NumberFormatter.luau",
	CodeNumValue = "src/PlayerDataInitializer/CodeNumValue.luau",
}

local function make_signal()
	local signal = {}

	function signal:Connect(_callback)
		return { Disconnect = function() end }
	end

	return signal
end

local function cold_start(eager_code_num)
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

	local game = {
		GetService = function(_self, name)
			assert(name == "Players", "unexpected startup service: " .. tostring(name))
			return players
		end,
		BindToClose = function(_self, _callback) end,
	}

	local instance = {
		new = function(class_name)
			return { ClassName = class_name }
		end,
	}

	local require_counts = { CodeNumValue = 0 }
	local cache = {}
	local core_source = SOURCES.PlayerDataCore

	if eager_code_num then
		local needle = 'local NumberFormatterFactory = require(script.Parent.NumberFormatter)\n'
		local index = string.find(core_source, needle, 1, true)
		assert(index ~= nil, "could not find PlayerDataCore's formatter dependency")
		local insert_at = index + #needle
		core_source = string.sub(core_source, 1, insert_at - 1)
			.. 'local _legacy_eager_code_num_value_factory = require(script.Parent.CodeNumValue)\n'
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

		if module.Name == "CodeNumValue" then
			require_counts.CodeNumValue += 1
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
		require_counts.CodeNumValue == (eager_code_num and 1 or 0),
		"optional CodeNumValue module-load count does not match the selected startup path"
	)
end

return function(eager_code_num)
	local ITERATIONS = 25

	for _ = 1, ITERATIONS do
		cold_start(eager_code_num)
	end

	print(if eager_code_num
		then "[PlayerData startup] legacy eager CodeNumValue dependency passed"
		else "[PlayerData startup] lazy optional CodeNumValue dependency passed")
end
