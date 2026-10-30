--!nocheck

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local builtin_require = require
local builtin_typeof = typeof

local Shim = {}

local function load_module(path, name, environment)
	return luau.load(fs.readFile(path), {
		debugName = name,
		environment = environment or {},
	})()
end

local function load_bundle()
	local AlyaNum = load_module("src/AlyaNum/init.luau", "AlyaNum")
	local http_service = {
		JSONEncode = function(_self, value)
			return serde.encode("json", value)
		end,
		JSONDecode = function(_self, value)
			return serde.decode("json", value)
		end,
	}
	local api_token = { ClassName = "ModuleScript", Name = "AlyaNum" }
	local formatter_token = { ClassName = "ModuleScript", Name = "AlyaNumFormatter" }

	function api_token:IsA(class_name)
		return class_name == "ModuleScript"
	end
	function formatter_token:IsA(class_name)
		return class_name == "ModuleScript"
	end

	local replicated_storage = {
		FindFirstChild = function(_self, name)
			if name == "AlyaNum" then return api_token end
			return nil
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
	local formatter
	local function shim_require(target)
		if target == api_token then return AlyaNum end
		if target == formatter_token then return formatter end
		return builtin_require(target)
	end
	local function shim_typeof(value)
		if type(value) == "table" and rawget(value, "__mock_instance") == true then
			return "Instance"
		end
		return builtin_typeof(value)
	end

	formatter = load_module("src/PlayerDataInitializer/AlyaNumFormatter.luau", "AlyaNumFormatter", {
		game = game,
		require = shim_require,
	})
	local script = {
		Parent = {
			AlyaNumFormatter = formatter_token,
		},
	}
	local AlyaNumValue = load_module(
		"src/PlayerDataInitializer/AlyaNumValue.luau",
		"AlyaNumValue",
		{
			game = game,
			script = script,
			Instance = instance,
			typeof = shim_typeof,
			require = shim_require,
		}
	)
	return AlyaNum, formatter, AlyaNumValue
end

function Shim.load_alyanum()
	local AlyaNum, formatter = load_bundle()
	return AlyaNum, formatter
end

function Shim.load_alyanum_value()
	local AlyaNum, formatter, AlyaNumValue = load_bundle()
	return AlyaNumValue, AlyaNum, formatter
end

return Shim
