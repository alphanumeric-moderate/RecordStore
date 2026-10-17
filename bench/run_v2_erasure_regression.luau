--!nocheck
-- Verifies that erasure refuses unverified coverage and never silently truncates inventories.
-- Uses deterministic in-memory storage; this is not Roblox service acceptance evidence.
local Shim = require("./RobloxShim")
local RecordStore = Shim.load_isolated("erasure-regression")
local V2Module = require("../src/PlayerDataInitializer/RecordStoreV2")
local MailboxV2 = require("../src/PlayerDataInitializer/RecordStoreMailboxV2")
local V2 = V2Module.new(RecordStore, MailboxV2)

local function clone(value, depth)
	depth = depth or 0
	assert(depth <= 64, "fixture exceeds maximum depth")
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in pairs(value) do result[clone(key, depth + 1)] = clone(child, depth + 1) end
	return result
end

local function new_store()
	local values = {}
	local store = {}
	function store:GetAsync(key)
		return clone(values[key])
	end
	function store:UpdateAsync(key, transform)
		local next_value = transform(clone(values[key]))
		values[key] = clone(next_value)
		return clone(next_value)
	end
	return store
end

local delete_calls = 0
local fence_calls = 0
local function family(verified, inventory)
	return {
		name = "player_profiles",
		templates = {
			{ name = "PlayerData", scope = "global", key = "Player_{user_id}" },
		},
		templates_verified = verified,
		inventory_verified = verified,
		inventory = inventory or function(user_id)
			return { { key = "Player_" .. tostring(user_id), generation = 1 } }
		end,
		fence_user = function(_user_id, _erasure_id)
			fence_calls += 1
			return true
		end,
		dependencies_clear = function(_item, _user_id)
			return true
		end,
		redact_or_delete_if_generation = function(item, _user_id, _erasure_id)
			assert(type(item.generation) == "number", "delete callback did not receive observed generation")
			delete_calls += 1
			return "deleted"
		end,
	}
end

local store = new_store()
local unverified = V2.Erasure.new(store, { family(false) }, {
	verify_templates = function(_user_id, _templates) return true end,
})
local plan = unverified:PlanAsync(111, "erasure-unverified-coverage")
assert(plan.code == "success", "plan should be recorded even when coverage is not verified")
assert(plan.rtbf_coverage_verified == false, "unverified family was incorrectly marked complete")
local execution = unverified:ExecuteAsync(111, "erasure-unverified-coverage", 16)
assert(execution.code == "blocked", "erasure with incomplete template coverage was not blocked: " .. tostring(execution.code))
assert(delete_calls == 0, "erasure invoked deletion before coverage verification")

local long_template_coordinator = V2.Erasure.new(new_store(), {
	{
		name = "long_rendered_template",
		templates = {
			{ name = "PlayerData", scope = "global", key = string.rep("x", 38) .. "{user_id}" },
		},
		templates_verified = true,
		inventory_verified = true,
		inventory = function(user_id)
			return { { key = "Player_" .. tostring(user_id), generation = 1 } }
		end,
		fence_user = function() return true end,
		dependencies_clear = function() return true end,
		redact_or_delete_if_generation = function() delete_calls += 1; return "deleted" end,
	},
}, {
	verify_templates = function() return true end,
})
local invalid_rendered_plan = long_template_coordinator:PlanAsync(1234567890123456, "erasure-long-rendered-key")
assert(invalid_rendered_plan.code == "invalid",
	"an RTBF template that exceeds the 50-byte DataStore key bound after substitution was accepted")
assert(long_template_coordinator:ExecuteAsync(1234567890123456, "erasure-long-rendered-key", 1).code == "not_found",
	"invalid rendered key unexpectedly created an executable erasure plan")

local overflow_store = new_store()
local overflow_family = family(true, function(user_id, maximum)
	local items = table.create(maximum + 1)
	for i = 1, maximum + 1 do
		items[i] = { key = ("Player_%d_%d"):format(user_id, i), generation = 1 }
	end
	return items
end)
local overflow = V2.Erasure.new(overflow_store, { overflow_family }, {
	verify_templates = function(_user_id, _templates) return true end,
})
local overflow_plan = overflow:PlanAsync(112, "erasure-overflow")
assert(overflow_plan.code == "capacity", "oversized inventory was silently truncated: " .. tostring(overflow_plan.code))
assert(overflow:ExecuteAsync(112, "erasure-overflow", 16).code == "not_found",
	"overflowed inventory unexpectedly created an executable erasure plan")

local verified_store = new_store()
local verified = V2.Erasure.new(verified_store, { family(true) }, {
	verify_templates = function(_user_id, rendered)
		return type(rendered) == "table" and #rendered == 1
	end,
})
local verified_plan = verified:PlanAsync(113, "erasure-verified")
assert(verified_plan.code == "success" and verified_plan.rtbf_coverage_verified == true,
	"verified family and template checks did not produce a verified plan")
local verified_result = verified:ExecuteAsync(113, "erasure-verified", 16)
assert(verified_result.code == "committed", "verified erasure did not finish: " .. tostring(verified_result.code))
assert(delete_calls == 1, "verified erasure did not perform exactly the one planned action")
assert(fence_calls >= 1, "verified erasure did not fence writers before deleting")

local deleted_before_resume = delete_calls
local multi_item_family = family(true, function(user_id)
	return {
		{ key = "Player_" .. tostring(user_id) .. "_one", generation = 1 },
		{ key = "Player_" .. tostring(user_id) .. "_two", generation = 2 },
	}
end)
local resumable = V2.Erasure.new(new_store(), { multi_item_family }, {
	verify_templates = function(_user_id, rendered) return type(rendered) == "table" and #rendered == 1 end,
})
local resumable_plan = resumable:PlanAsync(114, "erasure-resume")
assert(resumable_plan.rtbf_coverage_verified == true, "resumable fixture coverage was not verified")
local first_step = resumable:ExecuteAsync(114, "erasure-resume", 1)
assert(first_step.code == "incomplete" and first_step.cursor == 1, "bounded erasure step did not checkpoint progress")
local repeated_plan = resumable:PlanAsync(114, "erasure-resume")
assert(repeated_plan.cursor == 1, "repeating PlanAsync reset the immutable erasure cursor")
local final_step = resumable:ExecuteAsync(114, "erasure-resume", 1)
assert(final_step.code == "committed", "resumable erasure did not complete after its checkpoint")
assert(delete_calls == deleted_before_resume + 2, "resumed erasure did not perform one action per immutable plan entry")

local concurrent_store = new_store()
local concurrent_coordinator
local nested_started = false
local concurrent_family = family(true, function(user_id)
	return {
		{ key = "Player_" .. tostring(user_id) .. "_first", generation = 1 },
		{ key = "Player_" .. tostring(user_id) .. "_second", generation = 2 },
	}
end)
concurrent_family.redact_or_delete_if_generation = function(item, user_id, erasure_id)
	delete_calls += 1
	if item.key:find("_first", 1, true) and not nested_started then
		nested_started = true
		local nested = concurrent_coordinator:ExecuteAsync(user_id, erasure_id, 2)
		assert(nested.code == "committed", "nested worker failed to finish the immutable erasure plan")
	end
	return "deleted"
end
concurrent_coordinator = V2.Erasure.new(concurrent_store, { concurrent_family }, {
	verify_templates = function(_user_id, rendered) return type(rendered) == "table" and #rendered == 1 end,
})
local concurrent_plan = concurrent_coordinator:PlanAsync(116, "erasure-concurrent-progress")
assert(concurrent_plan.rtbf_coverage_verified == true, "concurrent fixture did not attest coverage")
local concurrent_result = concurrent_coordinator:ExecuteAsync(116, "erasure-concurrent-progress", 2)
assert(concurrent_result.code == "committed", "outer worker regressed a completed concurrent checkpoint")
local concurrent_status = concurrent_coordinator:GetStatus(116)
assert(concurrent_status.status == "completed" and concurrent_status.cursor == 2 and concurrent_status.completed_count == 2,
	"concurrent worker regressed erasure status/cursor/completed count")

local no_dependency_family = family(true)
no_dependency_family.dependencies_clear = nil
local dependency_guard = V2.Erasure.new(new_store(), { no_dependency_family }, {
	verify_templates = function(_user_id, rendered) return type(rendered) == "table" and #rendered == 1 end,
})
local no_dependency_plan = dependency_guard:PlanAsync(115, "erasure-missing-dependency-proof")
assert(no_dependency_plan.rtbf_coverage_verified == true, "fixture plan should isolate the missing dependency adapter")
local deleted_before_guard = delete_calls
local dependency_result = dependency_guard:ExecuteAsync(115, "erasure-missing-dependency-proof", 1)
assert(dependency_result.code == "unsupported", "missing dependency proof did not fail closed")
assert(delete_calls == deleted_before_guard, "erasure deleted a record without dependency-clearance proof")

print("[PASS] Erasure coverage gating, bounded inventory, immutable checkpoints, writer fencing and generation-aware deletion.")
Shim.close()
