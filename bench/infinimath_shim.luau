--!nonstrict

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local builtin_require = require

local Shim = {}

local function load_module(path, name, environment)
	return luau.load(fs.readFile(path), {
		debugName = name,
		environment = environment or {},
	})()
end

function Shim.load_infinitemath()
	local suffixes_token = {}
	local full_names_token = {}
	local int_token = {}
	local module_script = {
		Values = {
			Suffixes = suffixes_token,
			FullNames = full_names_token,
		},
		Int = int_token,
	}

	local function shim_require(target)
		if target == suffixes_token then
			return load_module("src/InfiniteMath/Values/Suffixes.luau", "InfiniteMath.Suffixes")
		elseif target == full_names_token then
			return load_module("src/InfiniteMath/Values/FullNames.luau", "InfiniteMath.FullNames")
		elseif target == int_token then
			return load_module("src/InfiniteMath/Int.luau", "InfiniteMath.Int")
		end
		return builtin_require(target)
	end

	return luau.load(fs.readFile("src/InfiniteMath/init.luau"), {
		debugName = "InfiniteMath",
		environment = {
			script = module_script,
			require = shim_require,
		},
	})()
end

function Shim.load_infinitemath_value()
	local api = Shim.load_infinitemath()

	local http_service = {
		JSONEncode = function(_self, value)
			return serde.encode("json", value)
		end,
		JSONDecode = function(_self, value)
			return serde.decode("json", value)
		end,
	}
	local api_token = { ClassName = "ModuleScript", Name = "InfiniteMath" }
	function api_token:IsA(class_name)
		return class_name == "ModuleScript"
	end

	local replicated_storage = {
		FindFirstChild = function(_self, name)
			return if name == "InfiniteMath" then api_token else nil
		end,
	}
	local game = {
		GetService = function(_self, name)
			if name == "HttpService" then return http_service end
			if name == "ReplicatedStorage" then return replicated_storage end
			error("unexpected service: " .. tostring(name), 2)
		end,
	}
	local instance = {
		new = function(class_name)
			local object = {
				__mock_instance = true,
				ClassName = class_name,
				Name = "",
				Value = "",
			}
			function object:IsA(expected)
				return self.ClassName == expected
			end
			function object:Destroy()
				self.Destroyed = true
			end
			return object
		end,
	}
	local script = {
		Parent = {},
	}
	local function shim_require(target)
		if target == api_token then return api end
		return builtin_require(target)
	end
	local builtin_typeof = typeof
	local function shim_typeof(value)
		if type(value) == "table" and rawget(value, "__mock_instance") == true then
			return "Instance"
		end
		return builtin_typeof(value)
	end

	local value_factory = load_module("src/PlayerDataInitializer/InfiniteMathValue.luau", "InfiniteMathValue", {
		game = game,
		script = script,
		Instance = instance,
		typeof = shim_typeof,
		require = shim_require,
	})
	return value_factory, api
end

return Shim
