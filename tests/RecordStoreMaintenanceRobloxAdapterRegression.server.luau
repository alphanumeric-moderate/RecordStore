--!nocheck
local ServerScriptService = game:GetService("ServerScriptService")
local AdapterModule = require(
	ServerScriptService:WaitForChild("PlayerDataInitializer"):WaitForChild("RecordStoreMaintenanceRobloxAdapter")
)

local function expect(value, message)
	assert(value, message)
end

local function clone(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in pairs(value) do result[key] = clone(child) end
	return result
end

local function make_service()
	local service = { stores = {}, fresh_reads = 0, list_calls = 0 }
	function service:GetDataStore(name, scope)
		local identity = tostring(name) .. "/" .. tostring(scope)
		if self.stores[identity] ~= nil then return self.stores[identity] end
		local store = {
			name = name,
			scope = scope,
				data = {},
				keys = {},
				lose_next_response = false,
		}
		function store:ListKeysAsync(prefix, page_size, cursor, exclude_deleted)
			service.list_calls += 1
			expect(exclude_deleted == false, "enumeration must retain deleted keys for safe reconciliation")
			local start_index = if cursor == nil then 1 else tonumber(cursor)
			expect(start_index ~= nil and start_index >= 1, "page cursor did not round-trip")
			local matching = {}
			for _, name in ipairs(self.keys) do
				if prefix == "" or string.sub(name, 1, #prefix) == prefix then
					matching[#matching + 1] = name
				end
			end
			local finish = math.min(#matching, start_index + page_size - 1)
			local page = {}
			for index = start_index, finish do
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
			expect(options ~= nil and options.UseCache == false, "adapter must bypass the local DataStore cache")
			service.fresh_reads += 1
			return clone(self.data[key]), { Version = "v1" }
		end
		function store:UpdateAsync(key, transform)
			local candidate = transform(clone(self.data[key]))
			if candidate ~= nil then self.data[key] = clone(candidate) end
			local observed = clone(self.data[key])
			if self.lose_next_response then
				self.lose_next_response = false
				return nil, "injected response loss after durable commit"
			end
			return observed, nil
		end
		self.stores[identity] = store
		return store
	end
	return service
end

local service = make_service()
local profile_store = service:GetDataStore("Profiles", "scope")
profile_store.data = {
	Player_A = { fencing_generation = 2, eligible = true, dependencies_clear = true, maintenance_fence_job_id = "job-adapter-1" },
	Player_B = { fencing_generation = 9, eligible = false, dependencies_clear = true, maintenance_fence_job_id = "job-adapter-1" },
	Player_D = { fencing_generation = 3, eligible = false, dependencies_clear = true, maintenance_fence_job_id = "job-adapter-1" },
	Other_C = { fencing_generation = 4, eligible = true, dependencies_clear = true, maintenance_fence_job_id = "job-adapter-1" },
}
profile_store.keys = { "Other_C", "Player_A", "Player_B", "Player_D" }

local atomic_delete_calls = 0
local adapter = AdapterModule.new({
	store_name = "Profiles",
	scope = "scope",
	key_prefix = "Player_",
	page_size = 2,
	checkpoint_store_name = "MaintenanceCheckpoints",
	checkpoint_scope = "scope",
	checkpoint_key = "job-adapter-1",
	job_id = "job-adapter-1",
	mode = "execute",
	data_store_service = service,
	new_get_options = function() return { UseCache = true } end,
	is_eligible = function(_item, value, _info)
		return value.eligible == true, nil
	end,
	dependencies_clear = function(_item, value, _info)
		return value.dependencies_clear == true, nil
	end,
	atomic_delete_if_generation = function(store, item, expected_generation, job_id)
		atomic_delete_calls += 1
		expect(job_id == "job-adapter-1", "delete did not receive its durable job identity")
		local result = "unknown"
		local updated = store:UpdateAsync(item.key, function(current)
			if type(current) ~= "table" then
				result = "already_absent"
				return nil
			end
			if current.maintenance_fence_job_id ~= job_id
				or current.fencing_generation ~= expected_generation
			then
				result = "skipped"
				return nil
			end
			result = "deleted"
			return {
				fencing_generation = expected_generation + 1,
				tombstone = true,
				maintenance_fence_job_id = job_id,
			}
		end)
		return result, if updated == nil and result == "deleted" then "tombstone response absent" else nil
	end,
	authorize = function(job_id) return job_id == "job-adapter-1", nil end,
	assert_fence = function(job_id) return job_id == "job-adapter-1", nil end,
})

local first, first_cursor, first_complete = adapter.next_page(nil, 2)
expect(#first == 2 and first_cursor ~= nil and first_complete == false,
	"first real-key page did not return a bounded continuation cursor")
expect(first[1].key == "Player_A" and first[2].key == "Player_B",
	"key enumeration did not filter the declared family prefix or preserve sorted order")
local second, second_cursor, second_complete = adapter.next_page(first_cursor, 2)
expect(#second == 1 and second[1].key == "Player_D" and second_cursor == nil and second_complete == true,
	"second page did not terminate correctly")

local inspected = adapter.inspect(first[1])
expect(inspected.status == "success" and inspected.generation == 2
	and inspected.eligible == true and inspected.dependencies_clear == true,
	"uncached record inspection did not return generation and policy results")
local unsupported = adapter.inspect({ name = "Profiles", scope = "scope", key = "Player_MissingEnvelope" })
expect(unsupported.status == "success" and unsupported.eligible == false,
	"an absent key must be treated as non-eligible instead of a destructive candidate")
local out_of_prefix = adapter.inspect({ name = "Profiles", scope = "scope", key = "Other_C" })
expect(out_of_prefix.status == "invalid" and out_of_prefix.eligible == false,
	"inspection accepted a key outside the declared prefix")

local checkpoint_store = adapter.checkpoint_store
checkpoint_store.lose_next_response = true
local persisted, persist_error = adapter.persist_checkpoint({
	version = 1,
	job_id = "job-adapter-1",
	revision = 1,
	cursor = "2",
	processed = 2,
	removed = 0,
	status = "incomplete",
}, 0)
expect(persisted == true, persist_error or "ambiguous checkpoint write was not reconciled")
local checkpoint, checkpoint_error = adapter.load_checkpoint()
expect(type(checkpoint) == "table" and checkpoint.revision == 1 and checkpoint.cursor == "2",
	checkpoint_error or "uncached checkpoint read did not return the committed checkpoint")

local action, action_error = adapter.delete_if_generation(first[1], 2)
expect(action == "deleted", action_error or "atomic generation-aware adapter callback was not invoked correctly")
expect(atomic_delete_calls == 1, "generation-aware delete callback call count changed")
local stale_action = adapter.delete_if_generation(first[1], 2)
expect(stale_action == "skipped", "generation mismatch was not rejected by the atomic delete callback")
expect(service.fresh_reads >= 3 and service.list_calls == 2,
	"adapter did not use bounded key enumeration and uncached inspection/checkpoint reads")

print("RecordStoreMaintenanceRobloxAdapter regression checks passed")
