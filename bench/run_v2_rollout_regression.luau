--!nocheck
-- Verifies durable rollout gating, phase fencing, evidence requirements and rollback.
-- Uses deterministic storage; does not establish real mixed-version writer drain.
local Shim = require("./RobloxShim")
local serde = require("@lune/serde")
local task = require("@lune/task")
local RecordStore = Shim.load_isolated("rollout-regression")
local V2Module = require("../src/PlayerDataInitializer/RecordStoreV2")
local MailboxV2 = require("../src/PlayerDataInitializer/RecordStoreMailboxV2")
local V2 = V2Module.new(RecordStore, MailboxV2, { allow_unattested_activation = true })

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

local guarded_v2 = V2Module.new(RecordStore, MailboxV2, {
	activation_guard = function(operation) return rollout:ActivationGuard("rollout-main", operation) end,
})
local child_bypass_constructed = pcall(function()
	return guarded_v2.Mailbox.new(MailboxV2.MockStore(), {
		store_name = "RolloutTest",
		scope = "global",
		profile_key = "player-child-bypass",
		user_id = 778897,
	}, {
		encode = function(value) return serde.encode("json", value) end,
		allow_unattested_activation = true,
	})
end)
assert(child_bypass_constructed == false,
	"a child mailbox bypassed the activation gate of its guarded V2 facade")
local hostile_guard_mailbox = guarded_v2.Mailbox.new(MailboxV2.MockStore(), {
	store_name = "RolloutTest",
	scope = "global",
	profile_key = "player-hostile-guard",
	user_id = 778896,
}, {
	encode = function(value) return serde.encode("json", value) end,
	activation_guard = function(_operation) return true, nil end,
	guid = function() return "hostile-child-guard" end,
})
local hostile_guard_enqueue = hostile_guard_mailbox:EnqueueAsync("reward", { coins = 1 }, {
	idempotency_key = "hostile-child-guard",
})
assert(hostile_guard_enqueue.code == "disabled",
	"a caller-supplied permissive child guard replaced the facade's authoritative gate")

local gate_record = { transaction_calls = 0, dispatch_calls = 0 }
function gate_record:TransactAsync(_operation_id, _fingerprint, _transform, _material)
	self.transaction_calls += 1
	return "success", nil
end
function gate_record:DispatchOutboxBatchAsync(dispatcher, _batch_size)
	self.dispatch_calls += 1
	local accepted, receipt = dispatcher({ EventId = "frozen-drain-event", Data = { coins = 1 } })
	assert(accepted == true and receipt == "frozen-drain-receipt", "frozen drain dispatcher rejected its event")
	return 1, "success", nil
end
local blocked_transaction = guarded_v2.Transactions.Run(
	gate_record, "tx-before-activation", { kind = "guard-test" }, function(current) return current end
)
assert(blocked_transaction.code == "disabled" and gate_record.transaction_calls == 0,
	"V2 transaction entrypoint bypassed the prepared rollout gate")
local blocked_inbox = guarded_v2.Inbox.ApplyAsync(nil, "pre-activation-message", { kind = "coins" }, function(current) return current end)
assert(blocked_inbox.code == "disabled", "V2 inbox entrypoint bypassed the prepared rollout gate")
local blocked_maintenance = guarded_v2.ScheduleMaintenance("maintenance-owner", "pre-activation", function()
	return { code = "committed" }
end)
assert(blocked_maintenance.code == "disabled", "maintenance scheduling bypassed the prepared rollout gate")

local accelerator_registered = 0
local mailbox_wakeup_bound = 0
local fake_accelerator = {
	Register = function(_self, _owner, _callback)
		accelerator_registered += 1
		return true
	end,
}
local fake_wakeup_mailbox = {
	ProcessNextAsync = function() return { code = "empty" } end,
	BindWakeups = function()
		mailbox_wakeup_bound += 1
		return true
	end,
}
local wakeup_bound, wakeup_error = guarded_v2.BindMailboxWakeups(
	fake_accelerator, "wakeup-owner", fake_wakeup_mailbox, function() end, 1
)
assert(wakeup_bound == false and wakeup_error ~= nil,
	"BindMailboxWakeups did not preserve its false/message return contract when rollout denied it")
assert(accelerator_registered == 0 and mailbox_wakeup_bound == 0,
	"denied mailbox wakeup registration still changed accelerator/mailbox state")

local compactor_next_page_calls = 0
local compactor_persist_calls = 0
local compactor = guarded_v2.Maintenance.NewCompactor({
	next_page = function()
		compactor_next_page_calls += 1
		return nil, nil, true
	end,
	inspect = function() return "retain" end,
	persist_progress = function()
		compactor_persist_calls += 1
		return true
	end,
})
local blocked_compaction = compactor:RunStep(1, 1)
assert(type(blocked_compaction) == "table" and blocked_compaction.code == "disabled",
	"compactor ran while rollout was still prepared")
local resume_allowed, resume_error = compactor:Resume(0)
assert(resume_allowed == false and resume_error ~= nil,
	"compactor Resume did not preserve its boolean/message return contract when blocked")
assert(compactor_next_page_calls == 0 and compactor_persist_calls == 0,
	"blocked compactor invoked its work or checkpoint callbacks")

local no_guard_constructed = pcall(function()
	return MailboxV2.new(MailboxV2.MockStore(), {
		store_name = "RolloutTest",
		scope = "global",
		profile_key = "player-no-guard",
		user_id = 778898,
	}, {
		encode = function(value) return serde.encode("json", value) end,
	})
end)
assert(no_guard_constructed == false,
	"mailbox constructor allowed V2 activation without a durable guard or explicit test bypass")

local mailbox_store = MailboxV2.MockStore()
local mailbox = MailboxV2.new(mailbox_store, {
	store_name = "RolloutTest",
	scope = "global",
	profile_key = "player-rollout",
	user_id = 778899,
}, {
	encode = function(value) return serde.encode("json", value) end,
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
local allowed_transaction = guarded_v2.Transactions.Run(
	gate_record, "tx-after-activation", { kind = "guard-test" }, function(current) return current end
)
assert(allowed_transaction.code == "committed" and gate_record.transaction_calls == 1,
	"active rollout did not authorize the guarded V2 transaction entrypoint")

local frozen = rollout:FreezeAsync("rollout-main", "freeze-main-1")
assert(frozen.code == "committed" and frozen.phase == "frozen", "rollout freeze failed")
assert(rollout:CanUseAsync("rollout-main", "enqueue") == false, "frozen rollout accepted new enqueue")
assert(rollout:CanUseAsync("rollout-main", "process") == true, "frozen rollout blocked draining existing messages")
assert(rollout:CanUseAsync("rollout-main", "renew_claim") == true, "frozen rollout blocked claim renewal")
local frozen_enqueue = mailbox:EnqueueAsync("reward", { coins = 4 }, { idempotency_key = "frozen" })
assert(frozen_enqueue.code == "disabled", "mailbox bypassed freeze for new writes")
local frozen_transaction = guarded_v2.Transactions.Run(
	gate_record, "tx-during-freeze", { kind = "guard-test" }, function(current) return current end
)
assert(frozen_transaction.code == "disabled" and gate_record.transaction_calls == 1,
	"freeze did not block new V2 transactions")
local maintenance_during_freeze = guarded_v2.ScheduleMaintenance("maintenance-owner", "during-freeze", function()
	return { code = "committed" }
end)
assert(maintenance_during_freeze.code == "disabled", "freeze did not block new maintenance")

local drain_result = nil
local scheduled_drain = guarded_v2.ScheduleOutboxDispatch(
	"outbox-owner",
	gate_record,
	function(event)
		assert(event.EventId == "frozen-drain-event", "wrong outbox event drained during freeze")
		return true, "frozen-drain-receipt"
	end,
	2,
	1,
	function(result) drain_result = result end,
	{ lane = "background" }
)
assert(scheduled_drain.code == "accepted", "freeze blocked scheduling of already-accepted outbox work")
for _ = 1, 100 do
	if drain_result ~= nil then break end
	task.wait(0.01)
end
assert(type(drain_result) == "table" and drain_result.code == "committed" and drain_result.dispatched == 1
	and gate_record.dispatch_calls == 1,
	"frozen rollout did not allow existing outbox work to drain through the shared selector")

local rollback = rollout:BeginRollbackAsync("rollout-main", "rollback-main-1")
assert(rollback.code == "committed" and rollback.phase == "rollback_pending", "rollback did not start from frozen state")
assert(rollout:CanUseAsync("rollout-main", "process") == true, "rollback blocked drain/ack operations")
assert(rollout:CanUseAsync("rollout-main", "enqueue") == false, "rollback reopened new enqueue")
local rolled_back = rollout:CompleteRollbackAsync("rollout-main", "rollback-main-1")
assert(rolled_back.code == "committed" and rolled_back.phase == "rolled_back", "rollback completion attestation failed")
assert(rollout:CanUseAsync("rollout-main", "process") == false, "rolled-back deployment still authorized V2 processing")
local rolled_back_transaction = guarded_v2.Transactions.Run(
	gate_record, "tx-after-rollback", { kind = "guard-test" }, function(current) return current end
)
assert(rolled_back_transaction.code == "disabled" and gate_record.transaction_calls == 1,
	"completed rollback still authorized V2 transactions")

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
