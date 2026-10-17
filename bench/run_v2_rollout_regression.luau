--!nocheck
-- Verifies durable rollout gating, phase fencing, evidence requirements and rollback.
-- Uses deterministic storage; does not establish real mixed-version writer drain.
local Shim = require("./RobloxShim")
local RecordStore = Shim.load_isolated("rollout-regression")
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
	function store:GetAsync(key) return clone(values[key]) end
	function store:UpdateAsync(key, transform)
		local next_value = transform(clone(values[key]))
		values[key] = clone(next_value)
		return clone(next_value)
	end
	return store
end

local function verifier(name, enabled)
	return function(rollout_id, manifest)
		assert(type(rollout_id) == "string" and type(manifest) == "table", "verifier input missing")
		if enabled == false then return false, "unverified:" .. name end
		return true, "evidence:" .. name .. ":" .. rollout_id
	end
end

local function rollout_options()
	return {
		verify_compatibility = verifier("compatibility"),
		verify_writers_drained = verifier("writers-drained"),
		verify_activation_frozen = verifier("activation-freeze"),
		verify_rollback_rehearsed = verifier("rollback-rehearsed"),
		verify_profile_key_fencing = verifier("profile-key-fencing"),
		verify_rollback_completed = verifier("rollback-completed"),
	}
end

local store = new_store()
local rollout = V2.Rollout.new(store, rollout_options())
local prepared = rollout:PrepareAsync("rollout-main", "matrix-digest-v2")
assert(prepared.code == "prepared", "rollout did not start in the closed prepared phase")
local permitted, denied_message = rollout:CanUseAsync("rollout-main", "enqueue")
assert(permitted == false and string.find(denied_message, "prepared", 1, true) ~= nil,
	"prepared rollout unexpectedly authorized enqueue")

local mailbox_store = MailboxV2.MockStore()
local mailbox = MailboxV2.new(mailbox_store, {
	store_name = "RolloutTest",
	scope = "global",
	profile_key = "player-rollout",
	user_id = 778899,
}, {
	encode = function(value) return Shim.JSONEncode(value) end,
	guid = function() return "rollout-mailbox-guid" end,
	activation_guard = function(operation) return rollout:ActivationGuard("rollout-main", operation) end,
})
local blocked_enqueue = mailbox:EnqueueAsync("reward", { coins = 1 }, { idempotency_key = "pre-activation" })
assert(blocked_enqueue.code == "disabled", "mailbox ignored a closed rollout gate")

local attested = rollout:AttestAsync("rollout-main")
assert(attested.code == "committed" and attested.phase == "ready", "rollout did not persist all preflight attestations")
local premature_enqueue = mailbox:EnqueueAsync("reward", { coins = 2 }, { idempotency_key = "pre-activation-2" })
assert(premature_enqueue.code == "disabled", "ready-but-not-active rollout authorized mailbox writes")

local activated = rollout:ActivateAsync("rollout-main", "activate-main-1")
assert(activated.code == "committed" and activated.phase == "active", "verified rollout did not activate")
local duplicate_activation = rollout:ActivateAsync("rollout-main", "activate-main-1")
assert(duplicate_activation.code == "duplicate", "activation retry was not idempotent")
local accepted = mailbox:EnqueueAsync("reward", { coins = 3 }, { idempotency_key = "post-activation" })
assert(accepted.code == "accepted", "active rollout did not authorize mailbox enqueue: " .. tostring(accepted.error))

local frozen = rollout:FreezeAsync("rollout-main", "freeze-main-1")
assert(frozen.code == "committed" and frozen.phase == "frozen", "rollout freeze failed")
assert(rollout:CanUseAsync("rollout-main", "enqueue") == false, "frozen rollout accepted new enqueue")
assert(rollout:CanUseAsync("rollout-main", "process") == true, "frozen rollout blocked draining existing messages")
assert(rollout:CanUseAsync("rollout-main", "renew_claim") == true, "frozen rollout blocked claim renewal")
local frozen_enqueue = mailbox:EnqueueAsync("reward", { coins = 4 }, { idempotency_key = "frozen" })
assert(frozen_enqueue.code == "disabled", "mailbox bypassed freeze for new writes")

local rollback = rollout:BeginRollbackAsync("rollout-main", "rollback-main-1")
assert(rollback.code == "committed" and rollback.phase == "rollback_pending", "rollback did not start from frozen state")
assert(rollout:CanUseAsync("rollout-main", "process") == true, "rollback blocked drain/ack operations")
assert(rollout:CanUseAsync("rollout-main", "enqueue") == false, "rollback reopened new enqueue")
local rolled_back = rollout:CompleteRollbackAsync("rollout-main", "rollback-main-1")
assert(rolled_back.code == "committed" and rolled_back.phase == "rolled_back", "rollback completion attestation failed")
assert(rollout:CanUseAsync("rollout-main", "process") == false, "rolled-back deployment still authorized V2 processing")

local conflicting = rollout:PrepareAsync("rollout-main", "different-matrix")
assert(conflicting.code == "conflict", "rollout ID was allowed to change the compatibility matrix")

local blocked_store = new_store()
local blocked = V2.Rollout.new(blocked_store, {
	verify_compatibility = verifier("compatibility"),
	verify_writers_drained = verifier("writers-drained", false),
	verify_activation_frozen = verifier("activation-freeze"),
	verify_rollback_rehearsed = verifier("rollback-rehearsed"),
	verify_profile_key_fencing = verifier("profile-key-fencing"),
})
assert(blocked:PrepareAsync("rollout-blocked", "matrix-digest").code == "prepared")
local denied_attestation = blocked:AttestAsync("rollout-blocked")
assert(denied_attestation.code == "blocked", "failed writer-drain attestation did not block readiness")
assert(blocked:CanUseAsync("rollout-blocked", "enqueue") == false,
	"failed writer-drain evidence nevertheless authorized writes")

local unavailable_store = {}
function unavailable_store:GetAsync(_key) error("rollout store unavailable") end
function unavailable_store:UpdateAsync(_key, _transform) error("rollout store unavailable") end
local unavailable = V2.Rollout.new(unavailable_store, rollout_options())
local unavailable_allowed = unavailable:CanUseAsync("rollout-unavailable", "enqueue")
assert(unavailable_allowed == false, "unavailable rollout manifest did not fail closed")

local incomplete = V2.Rollout.new(new_store(), {})
assert(incomplete:PrepareAsync("rollout-no-verifiers", "matrix").code == "prepared")
assert(incomplete:AttestAsync("rollout-no-verifiers").code == "unsupported",
	"rollout activated without required compatibility/drain/fencing verifiers")

print("[PASS] Durable rollout gate, evidence requirements, freeze/drain and rollback transitions.")
Shim.close()
