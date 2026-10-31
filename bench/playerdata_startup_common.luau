--!nocheck
-- Measures module initialization with zero players; profiles and legacy migration are not opened.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local task = require("@lune/task")
local serde = require("@lune/serde")

local SOURCES = {
	PlayerData = fs.readFile("src/PlayerDataInitializer/PlayerData.luau"),
	PlayerDataCore = fs.readFile("src/PlayerDataInitializer/PlayerDataCore.luau"),
	IntegerInfinityValue = fs.readFile("src/PlayerDataInitializer/IntegerInfinityValue.luau"),
	CodeNumValue = fs.readFile("src/PlayerDataInitializer/CodeNumValue.luau"),
	Initializer = fs.readFile("src/PlayerDataInitializer/init.server.luau"),
}

local MODULE_PATHS = {
	RecordStore = "mock",
	PlayerData = "src/PlayerDataInitializer/PlayerData.luau",
	PlayerDataCore = "src/PlayerDataInitializer/PlayerDataCore.luau",
	IntegerInfinityValue = "src/PlayerDataInitializer/IntegerInfinityValue.luau",
	CodeNumValue = "src/PlayerDataInitializer/CodeNumValue.luau",
}

local function make_signal()
	local signal = {}

	function signal:Connect(_callback)
		return { Disconnect = function() end }
	end

	return signal
end

local function cold_start(eager_codenum_value)
	local scheduler_state = {
		enabled = false,
		policy = {
			revision = 1,
			algorithm = "fifo",
			shadow_algorithm = "weighted",
			shadow_enabled = false,
			shadow_sample_rate = 0,
		},
		rollout = {
			revision = 1,
			percent = 0,
			salt = "initial",
			cohort_included = false,
		},
	}
	local scheduler_calls = { snapshot = 0, policy = 0, rollout = 0, enable = 0 }
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

	local require_counts = { CodeNumValue = 0 }
	local cache = {}
	local core_source = SOURCES.PlayerDataCore

	if eager_codenum_value then
		local needle = 'local IntegerInfinityValueFactory = require(script.Parent.IntegerInfinityValue)\n'
		local index = string.find(core_source, needle, 1, true)
		assert(index ~= nil, "could not find PlayerDataCore's dependency insertion point")
		local insert_at = index + #needle
		core_source = string.sub(core_source, 1, insert_at - 1)
			.. 'local _codenum_value_factory_eager_test = require(script.Parent.CodeNumValue)\n'
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
			function record_store_stub.get_scheduler_snapshot()
				scheduler_calls.snapshot += 1
				return {
					enabled = scheduler_state.enabled,
					policy = table.clone(scheduler_state.policy),
					rollout = table.clone(scheduler_state.rollout),
				}
			end
			function record_store_stub.configure_scheduler_policy(policy)
				scheduler_calls.policy += 1
				scheduler_state.policy = table.clone(policy)
				return "success", nil
			end
			function record_store_stub.configure_scheduler_rollout(rollout)
				scheduler_calls.rollout += 1
				scheduler_state.rollout = {
					revision = rollout.revision,
					percent = rollout.percent,
					salt = rollout.salt,
					cohort_included = rollout.percent == 100,
				}
				return "success", nil
			end
			function record_store_stub.set_scheduler_enabled(enabled)
				scheduler_calls.enable += 1
				scheduler_state.enabled = enabled
				return true, nil
			end
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

	assert(scheduler_calls.snapshot >= 2,
		"startup did not inspect and verify the advanced scheduler configuration")
	assert(scheduler_calls.policy == 1 and scheduler_calls.rollout == 1 and scheduler_calls.enable == 1,
		"startup did not configure the production scheduler capabilities exactly once")
	assert(scheduler_state.enabled == true
		and scheduler_state.policy.algorithm == "drr"
		and scheduler_state.policy.shadow_enabled == true
		and scheduler_state.rollout.percent == 100
		and scheduler_state.rollout.cohort_included == true,
		"startup benchmark scheduler fixture did not reach the configured production state")

	assert(
		require_counts.CodeNumValue == (eager_codenum_value and 1 or 0),
		"optional CodeNumValue module-load count does not match the selected startup path"
	)
end

return function(eager_codenum_value)
	local ITERATIONS = 25

	for _ = 1, ITERATIONS do
		cold_start(eager_codenum_value)
	end

	print(if eager_codenum_value
		then "[PlayerData module initialization] eager optional CodeNumValue require passed"
		else "[PlayerData module initialization] lazy optional CodeNumValue require passed")
end
