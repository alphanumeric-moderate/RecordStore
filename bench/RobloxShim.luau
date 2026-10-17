--!nocheck
-- Minimal Roblox engine shim so RecordStore can run under Lune (https://lune-org.github.io/docs)
-- for CodSpeed benchmarks. Only the services used by the RecordStore.Mock backend are
-- implemented; live DataStore/MessagingService calls are not available here.

local datetime = require("@lune/datetime")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")

local Shim = {}

local REPO_ROOT = "."
local SOURCE_PATH = REPO_ROOT .. "/src/PlayerDataInitializer/RecordStore.luau"

-- Deterministic GUIDs keep benchmark runs reproducible.
local guid_counter = 0
local function generate_guid(_self, wrap_in_braces: boolean?): string
	guid_counter += 1
	local id = string.format("00000000-0000-4000-8000-%012x", guid_counter)
	if wrap_in_braces then
		return "{" .. id .. "}"
	end
	return id
end

local HttpService = {
	GenerateGUID = generate_guid,
	JSONEncode = function(_self, value: any): string
		return serde.encode("json", value)
	end,
	JSONDecode = function(_self, value: string): any
		return serde.decode("json", value)
	end,
}

local DataStoreService = {
	GetDataStore = function()
		error("DataStoreService is not available outside Roblox; use RecordStore.Mock", 2)
	end,
	GetRequestBudgetForRequestType = function()
		return math.huge
	end,
}

local MessagingService = {
	PublishAsync = function()
		error("MessagingService is not available outside Roblox", 2)
	end,
	SubscribeAsync = function()
		error("MessagingService is not available outside Roblox", 2)
	end,
}

local bind_to_close: { () -> () } = {}

local function make_enum(enum_name: string, items: { string })
	local enum = {}
	for _, item in items do
		enum[item] = table.freeze({ Name = item, EnumType = enum_name })
	end
	return table.freeze(enum)
end

local Enum = table.freeze({
	DataStoreRequestType = make_enum("DataStoreRequestType", {
		"GetAsync",
		"SetIncrementAsync",
		"UpdateAsync",
		"GetSortedAsync",
		"SetIncrementSortedAsync",
		"OnUpdate",
		"ListAsync",
		"GetVersionAsync",
		"RemoveVersionAsync",
		"StandardRead",
		"StandardWrite",
		"StandardList",
		"StandardRemove",
	}),
	SortDirection = make_enum("SortDirection", { "Ascending", "Descending" }),
})

local DateTime = table.freeze({
	now = function()
		return { UnixTimestampMillis = datetime.now().unixTimestampMillis }
	end,
})

local Instance = table.freeze({
	new = function(class_name: string)
		return { ClassName = class_name }
	end,
})

local loaded_module: any = nil

local function load_record_store(source_path: string?)
	if loaded_module ~= nil then
		return loaded_module
	end
	local source = fs.readFile(source_path or SOURCE_PATH)
	local chunk = luau.load(source, {
		debugName = "RecordStore",
		environment = Shim.environment,
	})
	loaded_module = chunk()
	return loaded_module
end

local RecordStoreInstance = table.freeze({ Name = "RecordStore", ClassName = "ModuleScript" })

local ServerScriptService = {
	RecordStore = RecordStoreInstance,
	WaitForChild = function(_self, name: string)
		assert(name == "RecordStore", "only the RecordStore ModuleScript is available")
		return RecordStoreInstance
	end,
	FindFirstChild = function(_self, name: string)
		return if name == "RecordStore" then RecordStoreInstance else nil
	end,
}

local services = {
	DataStoreService = DataStoreService,
	HttpService = HttpService,
	MessagingService = MessagingService,
	ServerScriptService = ServerScriptService,
}

local game = {
	JobId = "",
	PlaceId = 0,
	GetService = function(_self, name: string)
		local service = services[name]
		if service == nil then
			error("service " .. tostring(name) .. " is not shimmed", 2)
		end
		return service
	end,
	BindToClose = function(_self, callback: () -> ())
		table.insert(bind_to_close, callback)
	end,
}

local function shim_require(target: any)
	if target == RecordStoreInstance then
		return load_record_store()
	end
	return require(target)
end

Shim.environment = {
	game = game,
	task = task,
	Enum = Enum,
	DateTime = DateTime,
	Instance = Instance,
	require = shim_require,
}

-- Returns the RecordStore module, loaded inside the shimmed environment.
function Shim.load(source_path: string?): any
	return load_record_store(source_path)
end

-- Runs a Roblox-style script (e.g. the regression tests) inside the shimmed environment.
function Shim.run_script(path: string)
	local chunk = luau.load(fs.readFile(path), {
		debugName = path,
		environment = Shim.environment,
	})
	chunk()
end

-- Mirrors game:BindToClose, then exits right away instead of waiting for the
-- RecordStore background scheduler to wake up and notice the shutdown.
function Shim.close()
	for _, callback in bind_to_close do
		callback()
	end
	process.exit(0)
end

return Shim
