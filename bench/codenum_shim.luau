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

local CodeNum = load_module("src/CodeNum/init.luau", "CodeNum")
local HttpService = {
	JSONEncode = function(_self, value) return serde.encode("json", value) end,
	JSONDecode = function(_self, value) return serde.decode("json", value) end,
}
local code_num_token = { ClassName = "ModuleScript", Name = "CodeNum" }
local formatter_token = { ClassName = "ModuleScript", Name = "CodeNumFormatter" }
function code_num_token:IsA(class_name) return class_name == "ModuleScript" end
function formatter_token:IsA(class_name) return class_name == "ModuleScript" end

local ReplicatedStorage = {
	FindFirstChild = function(_self, name)
		return if name == "CodeNum" then code_num_token else nil
	end,
}
local services = { HttpService = HttpService, ReplicatedStorage = ReplicatedStorage }
local game = {
	GetService = function(_self, name)
		local service = services[name]
		assert(service ~= nil, "unexpected service: " .. tostring(name))
		return service
	end,
}
local Instance = {
	new = function(class_name)
		local object = { __mock_instance = true, ClassName = class_name, Name = "", Value = "" }
		function object:IsA(expected) return self.ClassName == expected end
		function object:Destroy() self.Destroyed = true end
		return object
	end,
}
local function shim_typeof(value)
	if type(value) == "table" and rawget(value, "__mock_instance") == true then
		return "Instance"
	end
	return builtin_typeof(value)
end

local CodeNumFormatter = load_module(
	"src/PlayerDataInitializer/CodeNumFormatter.luau",
	"CodeNumFormatter",
	{
		game = game,
		require = function(target)
			if target == code_num_token then return CodeNum end
			return builtin_require(target)
		end,
	}
)

local CodeNumValue = load_module(
	"src/PlayerDataInitializer/CodeNumValue.luau",
	"CodeNumValue",
	{
		game = game,
		script = { Parent = { CodeNumFormatter = formatter_token } },
		Instance = Instance,
		typeof = shim_typeof,
		require = function(target)
			if target == code_num_token then return CodeNum end
			if target == formatter_token then return CodeNumFormatter end
			return builtin_require(target)
		end,
	}
)

function Shim.load_codenum()
	return CodeNum, CodeNumFormatter
end
function Shim.load_codenum_value()
	return CodeNumValue, CodeNum, CodeNumFormatter
end
return Shim
