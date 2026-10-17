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

print("[PASS] Erasure coverage gating, bounded inventory, writer fence and generation-aware callback contracts.")
Shim.close()
