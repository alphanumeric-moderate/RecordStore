local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Shim = require("./RobloxShim")

local function clone(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in pairs(value) do result[key] = clone(child) end
	return result
end

local function make_service(initial_stores)
	local service = { stores = {} }
	for name, data in pairs(initial_stores) do
		service.stores[name .. "\n" .. "global"] = { data = clone(data) }
	end
	function service:GetDataStore(name, scope)
		local identity = name .. "\n" .. (scope or "")
		local store = self.stores[identity]
		if store == nil then
			store = { data = {} }
			self.stores[identity] = store
		end
		function store:ListKeysAsync(prefix, page_size, cursor, _exclude_deleted)
			local matching = {}
			for key in pairs(self.data) do
				if prefix == "" or string.sub(key, 1, #prefix) == prefix then
					matching[#matching + 1] = key
				end
			end
			table.sort(matching)
			local start = if cursor == nil then 1 else tonumber(cursor)
			assert(start ~= nil and start >= 1, "cursor did not round-trip")
			local finish = math.min(#matching, start + page_size - 1)
			local page = {}
			for index = start, finish do
				page[#page + 1] = { KeyName = matching[index] }
			end
			local is_finished = finish >= #matching
			return {
				IsFinished = is_finished,
				Cursor = if is_finished then nil else tostring(finish + 1),
				GetCurrentPage = function() return page end,
			}
		end
		function store:GetAsync(key, options)
			assert(options ~= nil and options.UseCache == false, "adapter did not force uncached reads")
			return clone(self.data[key]), { Version = "v1" }
		end
		function store:UpdateAsync(key, transform)
			local proposed = transform(clone(self.data[key]), { Version = "v1" })
			if proposed ~= nil then self.data[key] = clone(proposed) end
			return clone(self.data[key])
		end
		return store
	end
	return service
end

local function make_family(name, store_name, prefix)
	return {
		name = name,
		store_name = store_name,
		scope = "global",
		prefix = prefix,
		get_generation = function(value)
			return if type(value) == "table" then value.generation else nil
		end,
		inspect = function(_key, value)
			return {
				status = "success",
				eligible = false,
				dependencies_clear = true,
				generation = value.generation,
			}, nil
		end,
		can_delete = function() return false end,
		make_tombstone = function(value, _info, generation)
			return { generation = generation + 1, tombstone = true, previous = value }
		end,
		is_tombstone = function(value, generation)
			return type(value) == "table" and value.tombstone == true and value.generation == generation + 1
		end,
	}
end

local function make_config(service, families)
	return {
		job_id = "maintenance-regression",
		catalog_revision = "inventory-r1",
		families = families,
		checkpoint_store_name = "MaintenanceCheckpoints",
		checkpoint_scope = "global",
		checkpoint_key = "maintenance-regression",
		maintenance = { NewCompactor = function() return {} end },
		maintenance_runner = { new = function() return {} end },
		data_store_service = service,
		instance_factory = function() return {} end,
	}
end

local service = make_service({
	Profiles = {
		Player_1 = { generation = 3 },
		Player_2 = { generation = 4 },
	},
	OtherStore = {
		Other_1 = { generation = 9 },
	},
})
Shim.set_service("DataStoreService", service)
local AdapterModule = luau.load(fs.readFile("src/PlayerDataInitializer/RecordStoreMaintenanceDataStoreAdapter.luau"), {
	debugName = "RecordStoreMaintenanceDataStoreAdapter",
	environment = Shim.environment,
})()

local original_family = make_family("profiles", "Profiles", "Player_")
local adapter = AdapterModule.new(make_config(service, { original_family }))
original_family.store_name = "OtherStore"
original_family.prefix = "Other_"
original_family.scope = "redirected"

local page, cursor, complete = adapter:NextPage(nil, 10)
assert(#page == 2 and page[1].store_name == "Profiles" and page[1].scope == "global"
	and page[1].key == "Player_1" and page[2].key == "Player_2",
	"mutating caller-owned family configuration changed the bound catalog after adapter creation")
assert(cursor == nil and complete == true, "single-family catalog did not terminate after its only page")

local family_one = make_family("one", "Profiles", "Player_")
local family_two = make_family("two", "OtherStore", "Other_")
local sparse_families = { [1] = family_one, [3] = family_two }
local sparse_ok, sparse_error = pcall(function()
	AdapterModule.new(make_config(service, sparse_families))
end)
assert(not sparse_ok and string.find(tostring(sparse_error), "dense", 1, true) ~= nil,
	"adapter accepted a sparse family inventory instead of rejecting incomplete enumeration")

print("RecordStoreMaintenanceDataStoreAdapter regression checks passed")
Shim.close()
