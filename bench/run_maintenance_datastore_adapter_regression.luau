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
			store = { data = {}, lose_next_response = false, before_next_update = nil }
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
			if self.before_next_update ~= nil then
				local before = self.before_next_update
				self.before_next_update = nil
				before(self, key)
			end
			local proposed = transform(clone(self.data[key]), { Version = "v1" })
			if proposed ~= nil then self.data[key] = clone(proposed) end
			local observed = clone(self.data[key])
			if self.lose_next_response then
				self.lose_next_response = false
				return nil, "injected response loss after commit"
			end
			return observed
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
				eligible = value.eligible == true,
				dependencies_clear = value.dependencies_clear == true,
				generation = value.generation,
			}, nil
		end,
		can_delete = function(value, _info, expected_generation, job_id)
			return type(value) == "table"
				and value.generation == expected_generation
				and value.maintenance_job_id == job_id
		end,
		make_tombstone = function(_value, _info, generation, job_id)
			return { generation = generation + 1, tombstone = true, maintenance_job_id = job_id }
		end,
		is_tombstone = function(value, generation, job_id)
			return type(value) == "table" and value.tombstone == true
				and value.generation == generation + 1 and value.maintenance_job_id == job_id
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
		Player_1 = { generation = 3, eligible = true, dependencies_clear = true, maintenance_job_id = "maintenance-regression" },
		Player_2 = { generation = 4, eligible = true, dependencies_clear = true, maintenance_job_id = "maintenance-regression" },
	},
	OtherStore = {
		Other_1 = { generation = 9, eligible = true, dependencies_clear = true, maintenance_job_id = "maintenance-regression" },
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

local inspected, inspect_error = adapter:Inspect(page[1])
assert(inspect_error == nil and inspected ~= nil and inspected.status == "success"
	and inspected.eligible == true and inspected.dependencies_clear == true and inspected.generation == 3,
	"fresh inspection did not preserve generation and application eligibility")
local missing_inspection, missing_error = adapter:Inspect({
	family_name = "profiles", store_name = "Profiles", scope = "global", key = "Player_Missing",
})
assert(missing_error == nil and missing_inspection ~= nil
	and missing_inspection.status == "success" and missing_inspection.eligible == false,
	"missing key was treated as a destructive candidate")

local deleted, delete_error = adapter:DeleteIfGeneration(page[1], 3)
assert(deleted == "deleted", delete_error or "generation- and job-fenced deletion did not commit")
local after_delete = service.stores["Profiles\nglobal"].data.Player_1
assert(after_delete.tombstone == true and after_delete.generation == 4
	and after_delete.maintenance_job_id == "maintenance-regression",
	"atomic delete did not write the expected same-key tombstone")
local profiles_store = service.stores["Profiles\nglobal"]
profiles_store.before_next_update = function(store, key)
	if key == "Player_2" then
		store.data.Player_2.generation = 99
		store.data.Player_2.maintenance_job_id = "replacement-job"
	end
end
local stale_delete, stale_delete_error = adapter:DeleteIfGeneration(page[2], 4)
assert(stale_delete == "skipped", stale_delete_error or "generation change inside UpdateAsync was not fenced")
assert(profiles_store.data.Player_2.generation == 99 and profiles_store.data.Player_2.tombstone ~= true,
	"stale delete overwrote a replacement generation during the conditional mutation")

local checkpoint_before, checkpoint_before_error = adapter:LoadCheckpoint()
assert(checkpoint_before == nil and checkpoint_before_error == nil,
	"fresh checkpoint store did not load as absent")
local checkpoint_store = service.stores["MaintenanceCheckpoints\nglobal"]
assert(checkpoint_store ~= nil, "adapter did not isolate checkpoint storage")
checkpoint_store.lose_next_response = true
local checkpoint_written, checkpoint_error = adapter:PersistCheckpoint({
	version = 1,
	job_id = "maintenance-regression",
	revision = 1,
	cursor = "inventory-r1|1:2",
	processed = 1,
	removed = 0,
	status = "incomplete",
}, 0)
assert(checkpoint_written == true, checkpoint_error or "committed checkpoint with a lost response was not reconciled")
local durable_checkpoint, checkpoint_read_error = adapter:LoadCheckpoint()
assert(checkpoint_read_error == nil and type(durable_checkpoint) == "table"
	and durable_checkpoint.revision == 1 and durable_checkpoint.cursor == "inventory-r1|1:2",
	"checkpoint response-loss recovery did not return the committed checkpoint")
local checkpoint_advanced, advance_error = adapter:PersistCheckpoint({
	version = 1,
	job_id = "maintenance-regression",
	revision = 2,
	cursor = nil,
	processed = 2,
	removed = 1,
	status = "completed",
}, 1)
assert(checkpoint_advanced == true, advance_error or "checkpoint revision did not advance")
local conflict_checkpoint, conflict_error = adapter:PersistCheckpoint({
	version = 1,
	job_id = "maintenance-regression",
	revision = 2,
	cursor = nil,
	processed = 2,
	removed = 0,
	status = "completed",
}, 1)
assert(conflict_checkpoint == false and string.find(tostring(conflict_error), "revision changed", 1, true) ~= nil,
	"checkpoint compare-and-swap accepted a conflicting revision")

local family_one = make_family("one", "Profiles", "Player_")
local family_two = make_family("two", "OtherStore", "Other_")
local multi_family_adapter = AdapterModule.new(make_config(service, { family_one, family_two }))
local first_family_page, first_family_cursor, first_family_complete = multi_family_adapter:NextPage(nil, 1)
assert(#first_family_page == 1 and first_family_page[1].store_name == "Profiles"
	and first_family_page[1].key == "Player_1" and first_family_cursor ~= nil
	and first_family_complete == false,
	"first family page did not return a bounded continuation")
local final_first_family_page, second_family_cursor, second_family_complete = multi_family_adapter:NextPage(first_family_cursor, 1)
assert(#final_first_family_page == 1 and final_first_family_page[1].key == "Player_2"
	and second_family_cursor == "inventory-r1|2:" and second_family_complete == false,
	"finished first-family page did not advance to the next catalog family")
local second_family_page, terminal_cursor, terminal_complete = multi_family_adapter:NextPage(second_family_cursor, 1)
assert(#second_family_page == 1 and second_family_page[1].store_name == "OtherStore"
	and second_family_page[1].key == "Other_1" and terminal_cursor == nil
	and terminal_complete == true,
	"multi-family pagination did not finish the final family")
local stale_cursor_ok, stale_cursor_error = pcall(function()
	multi_family_adapter:NextPage("inventory-r2|1:1", 1)
end)
assert(not stale_cursor_ok and string.find(tostring(stale_cursor_error), "catalog revision", 1, true) ~= nil,
	"adapter accepted a cursor from a different catalog revision")

local sparse_families = { [1] = make_family("sparse-one", "Profiles", "Player_"), [3] = make_family("sparse-two", "OtherStore", "Other_") }
local sparse_ok, sparse_error = pcall(function()
	AdapterModule.new(make_config(service, sparse_families))
end)
assert(not sparse_ok and string.find(tostring(sparse_error), "dense", 1, true) ~= nil,
	"adapter accepted a sparse family inventory instead of rejecting incomplete enumeration")

local runner_store = service:GetDataStore("RunnerProfiles", "global")
runner_store.data.Profile_1 = {
	generation = 7,
	eligible = true,
	dependencies_clear = true,
	maintenance_job_id = "maintenance-runner-integration",
}
runner_store.data.Profile_2 = {
	generation = 8,
	eligible = true,
	dependencies_clear = true,
	maintenance_job_id = "maintenance-runner-integration",
}
local RecordStore = Shim.load()
local V2Module = luau.load(fs.readFile("src/PlayerDataInitializer/RecordStoreV2.luau"), {
	debugName = "RecordStoreV2",
})()
local V2 = V2Module.new(RecordStore, RecordStore.MailboxV2)
local Runner = luau.load(fs.readFile("src/PlayerDataInitializer/RecordStoreMaintenanceRunner.luau"), {
	debugName = "RecordStoreMaintenanceRunner",
})()
local runner_config = make_config(service, {
	make_family("runner-profiles", "RunnerProfiles", "Profile_"),
})
runner_config.job_id = "maintenance-runner-integration"
runner_config.catalog_revision = "runner-inventory-v1"
runner_config.checkpoint_key = "maintenance-runner-integration"
runner_config.maintenance = V2.Maintenance
runner_config.maintenance_runner = Runner
local runner_adapter = AdapterModule.new(runner_config)
local runner = runner_adapter:NewRunner()
local run_result = runner:Run(8, 1, 500)
assert(run_result.code == "completed" and run_result.would_delete == 2 and run_result.removed == 0,
	"NewRunner did not wire the multi-family DataStore adapter into a bounded dry run")
assert(runner:Stats().processed == 2,
	"the integrated dry run did not preserve processed-item progress")
assert(runner_store.data.Profile_1.tombstone ~= true and runner_store.data.Profile_2.tombstone ~= true,
	"dry-run integration unexpectedly mutated profile records")

print("RecordStoreMaintenanceDataStoreAdapter regression checks passed")
Shim.close()
