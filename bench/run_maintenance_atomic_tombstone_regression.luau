--!nocheck
local Shim = require("./RobloxShim")
local initializer = Shim.environment.game:GetService("ServerScriptService"):WaitForChild("PlayerDataInitializer")
local AtomicTombstone = Shim.environment.require(initializer:WaitForChild("RecordStoreMaintenanceAtomicTombstone"))

local function expect(value, message)
	if not value then error(message, 2) end
end

local function clone(value, seen)
	if type(value) ~= "table" then return value end
	local memo = seen or {}
	if memo[value] ~= nil then return memo[value] end
	local result = {}
	memo[value] = result
	for key, child in pairs(value) do result[clone(key, memo)] = clone(child, memo) end
	return result
end

local function make_store(initial)
	local store = {
		row = clone(initial),
		lose_next_response = false,
		fail_reads = false,
		throw_before_update = false,
		before_update = nil,
	}
	function store:GetAsync(_key, options)
		expect(options ~= nil and options.UseCache == false, "tombstone readback did not bypass DataStore cache")
		if self.fail_reads then error("injected uncached read failure") end
		return clone(self.row), { Version = "1" }
	end
	function store:UpdateAsync(_key, transform)
		if self.throw_before_update then error("injected failure before commit") end
		if self.before_update ~= nil then
			local callback = self.before_update
			self.before_update = nil
			callback(self)
		end
		local candidate = transform(clone(self.row), { Version = "1" })
		if candidate ~= nil then self.row = clone(candidate) end
		if self.lose_next_response then
			self.lose_next_response = false
			error("injected response loss after tombstone commit")
		end
		return clone(self.row), { Version = "2" }
	end
	return store
end

local function make_adapter(overrides)
	local options = {
		store_name = "Profiles",
		scope = "global",
		key_prefix = "Player_",
		job_id = "job-atomic-1",
		generation_field = "fencing_generation",
		job_fence_field = "maintenance_fence_job_id",
		new_get_options = function() return { UseCache = true } end,
		now_unix = function() return 1792951000 end,
		is_eligible = function(value)
			return type(value) == "table" and value.eligible == true
		end,
		dependencies_clear = function(value)
			return type(value) == "table" and value.dependencies_clear == true
		end,
		make_tombstone = function(value, _info, expected_generation, job_id, now)
			return {
				fencing_generation = expected_generation + 1,
				maintenance_fence_job_id = job_id,
				tombstone = true,
				tombstone_job_id = job_id,
				tombstone_source_generation = expected_generation,
				tombstoned_at = now,
				payload = clone(value.payload),
			}
		end,
		is_tombstone = function(value, expected_generation, job_id)
			return type(value) == "table"
				and value.tombstone == true
				and value.tombstone_job_id == job_id
				and value.tombstone_source_generation == expected_generation
				and value.fencing_generation == expected_generation + 1
				and value.maintenance_fence_job_id == job_id
		end,
	}
	for key, value in pairs(overrides or {}) do options[key] = value end
	return AtomicTombstone.new(options)
end

local function profile(generation, job_id, eligible, dependencies_clear)
	return {
		fencing_generation = generation,
		maintenance_fence_job_id = job_id,
		eligible = eligible,
		dependencies_clear = dependencies_clear,
		payload = { coins = 100, flags = { keep = true } },
	}
end

local item = { name = "Profiles", scope = "global", key = "Player_1" }
local adapter = make_adapter()
local store = make_store(profile(4, nil, true, true))
local fence, fenced_generation, fence_error = adapter:FenceIfGeneration(store, item, 4, "job-atomic-1")
expect(fence == "fenced" and fenced_generation == 5, fence_error or "same-key fence did not commit")
expect(store.row.fencing_generation == 5
	and store.row.maintenance_fence_job_id == "job-atomic-1"
	and store.row.tombstone ~= true,
	"fence mutation advanced state incorrectly")
expect(store.row.payload.coins == 100, "eligibility callback mutated the authoritative payload")
local deleted, delete_error = adapter:DeleteIfGeneration(store, item, fenced_generation, "job-atomic-1")
expect(deleted == "deleted", delete_error or "fenced tombstone did not commit")
expect(store.row.fencing_generation == 6
	and store.row.tombstone_source_generation == 5
	and store.row.maintenance_fence_job_id == "job-atomic-1"
	and store.row.payload.coins == 100 and store.row.payload.flags.keep,
	"tombstone did not advance fencing generation while preserving payload")

local retry, retry_error = adapter:FenceAndDeleteIfGeneration(store, item, 4, "job-atomic-1")
expect(retry == "deleted", retry_error or "composite retry did not recognize the confirmed tombstone")
local composite_store = make_store(profile(2, nil, true, true))
local composite, composite_error = adapter:FenceAndDeleteIfGeneration(
	composite_store, item, 2, "job-atomic-1"
)
expect(composite == "deleted", composite_error or "composite fence-plus-tombstone failed")
expect(composite_store.row.fencing_generation == 4
	and composite_store.row.tombstone_source_generation == 3,
	"composite operation did not advance the generation twice")

local wrong_fence_store = make_store(profile(4, "different-job", true, true))
local wrong_fence = adapter:DeleteIfGeneration(wrong_fence_store, item, 4, "job-atomic-1")
expect(wrong_fence == "skipped" and wrong_fence_store.row.tombstone ~= true,
	"foreign same-key job fence did not block deletion")

local stale_store = make_store(profile(4, nil, true, true))
stale_store.before_update = function(target)
	target.row.fencing_generation = 5
	target.row.payload.coins = 999
end
local stale = adapter:DeleteIfGeneration(stale_store, item, 4, "job-atomic-1")
expect(stale == "skipped" and stale_store.row.payload.coins == 999
	and stale_store.row.tombstone ~= true,
	"stale generation overwrote a concurrent writer")

for _, fixture in ipairs({
	{ label = "ineligible", eligible = false, dependencies_clear = true },
	{ label = "dependent", eligible = true, dependencies_clear = false },
}) do
	local target = make_store(profile(4, nil, fixture.eligible, fixture.dependencies_clear))
	local status = adapter:FenceIfGeneration(target, item, 4, "job-atomic-1")
	expect(status == "skipped" and target.row.fencing_generation == 4
		and target.row.maintenance_fence_job_id == nil,
		fixture.label .. " record acquired a maintenance fence")
	local remove = adapter:DeleteIfGeneration(target, item, 4, "job-atomic-1")
	expect(remove == "skipped" and target.row.tombstone ~= true,
		fixture.label .. " record was tombstoned")
end

local lost_fence_store = make_store(profile(4, nil, true, true))
lost_fence_store.lose_next_response = true
local lost_fence, lost_generation, lost_fence_error = adapter:FenceIfGeneration(
	lost_fence_store, item, 4, "job-atomic-1"
)
expect(lost_fence == "fenced" and lost_generation == 5,
	lost_fence_error or "lost fence response was not reconciled with an uncached read")

local lost_delete_store = make_store(profile(4, nil, true, true))
local before_delete, delete_generation = adapter:FenceIfGeneration(lost_delete_store, item, 4, "job-atomic-1")
expect(before_delete == "fenced" and delete_generation == 5, "response-loss fixture could not acquire fence")
lost_delete_store.lose_next_response = true
local lost_delete, lost_delete_error = adapter:DeleteIfGeneration(
	lost_delete_store, item, delete_generation, "job-atomic-1"
)
expect(lost_delete == "deleted", lost_delete_error or "lost tombstone response was not reconciled")
expect(adapter:FenceAndDeleteIfGeneration(lost_delete_store, item, 4, "job-atomic-1") == "deleted",
	"retry failed to recognize an already committed tombstone")

local unavailable = make_store(profile(4, "job-atomic-1", true, true))
unavailable.throw_before_update = true
unavailable.fail_reads = true
expect(adapter:DeleteIfGeneration(unavailable, item, 4, "job-atomic-1") == "unknown",
	"unreconciled storage failure was not reported as unknown")
expect(unavailable.row.tombstone ~= true, "unresolved storage failure fabricated a committed tombstone")

local malformed_adapter = make_adapter({
	make_tombstone = function(value) return clone(value) end,
})
local malformed = make_store(profile(4, "job-atomic-1", true, true))
expect(malformed_adapter:DeleteIfGeneration(malformed, item, 4, "job-atomic-1") == "unknown",
	"malformed tombstone was accepted")
expect(malformed.row.tombstone ~= true, "malformed tombstone was written")

expect(adapter:DeleteIfGeneration(
	make_store(profile(4, "job-atomic-1", true, true)),
	{ name = "Profiles", scope = "global", key = "Other_1" }, 4, "job-atomic-1"
) == "skipped", "out-of-prefix locator was accepted")
expect(adapter:DeleteIfGeneration(
	make_store(profile(4, "job-atomic-1", true, true)), item, 4, "other-job"
) == "skipped", "wrong maintenance job identity was accepted")

local yielding_adapter = make_adapter({
	is_eligible = function()
		coroutine.yield()
		return true
	end,
})
local yielding_store = make_store(profile(4, nil, true, true))
expect(yielding_adapter:FenceIfGeneration(yielding_store, item, 4, "job-atomic-1") == "unknown",
	"yielding maintenance callback was accepted")
expect(yielding_store.row.fencing_generation == 4 and yielding_store.row.maintenance_fence_job_id == nil,
	"yielding callback mutated the record before returning unknown")

print("[MaintenanceAtomicTombstone] same-key fencing, generation CAS, callback isolation, fail-closed policy, tombstone verification and ambiguous-write recovery regressions passed")
