--!nocheck
-- Verifies that erasure refuses unverified coverage and never silently truncates inventories.
-- Uses deterministic in-memory storage; this is not Roblox service acceptance evidence.
local Shim = require("./RobloxShim")
local Fake = Shim.FakeDataStore
local RecordStore = Shim.load_isolated("erasure-regression")
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
		history_inventory_verified = verified,
		inventory = inventory or function(user_id)
			return { { store_name = "PlayerData", scope = "global", key = "Player_" .. tostring(user_id), generation = 1 } }
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
		clear_history_if_generation = function(_item, _user_id, _erasure_id) return true end,
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
		history_inventory_verified = true,
		inventory = function(user_id)
			return { { store_name = "PlayerData", scope = "global", key = "Player_" .. tostring(user_id), generation = 1 } }
		end,
		fence_user = function() return true end,
		dependencies_clear = function() return true end,
		redact_or_delete_if_generation = function() delete_calls += 1; return "deleted" end,
		clear_history_if_generation = function() return true end,
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
		items[i] = { store_name = "PlayerData", scope = "global", key = ("Player_%d_%d"):format(user_id, i), generation = 1 }
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

local missing_history = family(true)
missing_history.history_inventory_verified = false
missing_history.clear_history_if_generation = nil
local history_unverified = V2.Erasure.new(new_store(), { missing_history }, {
	verify_templates = function(_user_id, rendered) return type(rendered) == "table" and #rendered == 1 end,
})
local history_plan = history_unverified:PlanAsync(120, "erasure-history-unverified")
assert(history_plan.code == "success" and history_plan.rtbf_coverage_verified == false
	and history_plan.coverage.player_profiles.history_verified == false,
	"erasure was marked complete without historical-version inventory and cleanup adapter")
assert(history_unverified:ExecuteAsync(120, "erasure-history-unverified", 8).code == "blocked",
	"erasure executed without verified history inventory")

local history_retry_allowed = false
local history_retry_family = family(true)
history_retry_family.clear_history_if_generation = function(_item, _user_id, _erasure_id)
	if history_retry_allowed then return true end
	return false, "injected historical-version cleanup failure"
end
local history_retry_store = new_store()
local history_retry = V2.Erasure.new(history_retry_store, { history_retry_family }, {
	verify_templates = function(_user_id, rendered) return type(rendered) == "table" and #rendered == 1 end,
})
local history_retry_plan = history_retry:PlanAsync(124, "erasure-history-retry")
assert(history_retry_plan.rtbf_coverage_verified == true, "history retry fixture should start fully attested")
local history_block = history_retry:ExecuteAsync(124, "erasure-history-retry", 1)
assert(history_block.code == "retryable" and history_block.cursor == 0,
	"history cleanup failure advanced the durable erasure cursor")
history_retry_allowed = true
local history_resume = history_retry:ExecuteAsync(124, "erasure-history-retry", 1)
assert(history_resume.code == "committed" and history_resume.cursor == 1,
	"history cleanup retry did not resume and commit")

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

local untemplated = V2.Erasure.new(new_store(), {
	family(true, function(user_id)
		return { { store_name = "PlayerData", scope = "global", key = "Player_" .. tostring(user_id) .. "_unexpected", generation = 1 } }
	end),
}, {
	verify_templates = function() return true end,
})
local untemplated_plan = untemplated:PlanAsync(121, "erasure-untemplated-inventory")
assert(untemplated_plan.code == "success" and untemplated_plan.rtbf_coverage_verified == false,
	"inventory key outside the declared template set was incorrectly marked complete")
assert(untemplated_plan.coverage.player_profiles.unmatched_count == 1
	and untemplated_plan.coverage.player_profiles.missing_count == 1,
	"untemplated inventory did not report both the uncovered and missing identities")
assert(untemplated:ExecuteAsync(121, "erasure-untemplated-inventory", 8).code == "blocked",
	"erasure executed with an untemplated inventory key")

local incomplete_family = family(true, function(user_id)
	return { { store_name = "PlayerData", scope = "global", key = "Player_" .. tostring(user_id), generation = 1 } }
end)
incomplete_family.templates = {
	{ name = "PlayerData", scope = "global", key = "Player_{user_id}" },
	{ name = "PlayerData", scope = "global", key = "Backup_{user_id}" },
}
local incomplete = V2.Erasure.new(new_store(), { incomplete_family }, {
	verify_templates = function() return true end,
})
local incomplete_plan = incomplete:PlanAsync(122, "erasure-missing-template-row")
assert(incomplete_plan.rtbf_coverage_verified == false
	and incomplete_plan.coverage.player_profiles.missing_count == 1,
	"missing inventory row for a declared template was treated as verified coverage")
assert(incomplete:ExecuteAsync(122, "erasure-missing-template-row", 8).code == "blocked",
	"erasure executed without a row for every declared template")

local deleted_before_resume = delete_calls
local multi_item_family = family(true, function(user_id)
	return {
		{ store_name = "PlayerData", scope = "global", key = "Player_" .. tostring(user_id) .. "_one", generation = 1 },
		{ store_name = "PlayerData", scope = "global", key = "Player_" .. tostring(user_id) .. "_two", generation = 2 },
	}
end)
multi_item_family.templates = {
	{ name = "PlayerData", scope = "global", key = "Player_{user_id}_one" },
	{ name = "PlayerData", scope = "global", key = "Player_{user_id}_two" },
}
local resumable = V2.Erasure.new(new_store(), { multi_item_family }, {
	verify_templates = function(_user_id, rendered) return type(rendered) == "table" and #rendered == 2 end,
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
		{ store_name = "PlayerData", scope = "global", key = "Player_" .. tostring(user_id) .. "_first", generation = 1 },
		{ store_name = "PlayerData", scope = "global", key = "Player_" .. tostring(user_id) .. "_second", generation = 2 },
	}
end)
concurrent_family.templates = {
	{ name = "PlayerData", scope = "global", key = "Player_{user_id}_first" },
	{ name = "PlayerData", scope = "global", key = "Player_{user_id}_second" },
}
concurrent_family.redact_or_delete_if_generation = function(item, user_id, erasure_id)
	delete_calls += 1
	local outer_first_action = false
	if item.key:find("_first", 1, true) and not nested_started then
		nested_started = true
		outer_first_action = true
		local nested = concurrent_coordinator:ExecuteAsync(user_id, erasure_id, 2)
		assert(nested.code == "committed", "nested worker failed to finish the immutable erasure plan")
	end
	if outer_first_action then return "unknown", "late ambiguous action response after another worker completed" end
	return "deleted"
end
concurrent_coordinator = V2.Erasure.new(concurrent_store, { concurrent_family }, {
	verify_templates = function(_user_id, rendered) return type(rendered) == "table" and #rendered == 2 end,
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

local restore_tombstone_key = "__recordstore_v2_erasure_tombstone"
local restore_record = {
	data = {
		Coins = 5,
		[restore_tombstone_key] = { erasure_id = "restore-race", generation = 2 },
	},
}
function restore_record:Get() return clone(self.data) end
function restore_record:Stats() return { state = "active", revision = 1 } end
function restore_record:TransactAsync(_operation_id, _fingerprint, transform, _canonical_request)
	local ok, next_data = pcall(transform, self.data)
	if not ok then return "validation", tostring(next_data) end
	self.data = next_data
	return "success", nil
end
local restore_result = V2.ProfileDoctor.Restore(
	restore_record,
	{ Coins = 999, RestoredField = true },
	1,
	"restore-after-erasure-fence",
	"operator-test",
	"verify that profile-key tombstones win",
	{
		subject_user_id = 118,
		is_erased = function() return false end,
	}
)
assert(restore_result.code ~= "committed" and restore_result.code ~= "success",
	"historical restore bypassed the durable profile-key erasure tombstone")
assert(restore_record.data.Coins == 5, "blocked restore still replaced profile data")
assert(restore_record.data[restore_tombstone_key] ~= nil,
	"blocked restore removed the durable erasure tombstone")

local transaction_after_tombstone = V2.Transactions.Run(
	restore_record,
	"transaction-after-erasure-fence",
	{ kind = "increment_after_erasure", amount = 10 },
	function(current)
		local next_data = clone(current)
		next_data.Coins += 10
		return next_data
	end
)
assert(transaction_after_tombstone.code ~= "committed" and transaction_after_tombstone.code ~= "duplicate",
	"generic V2 transaction bypassed the atomic profile-key erasure tombstone")
assert(restore_record.data.Coins == 5,
	"generic V2 transaction mutated a profile after its erasure tombstone")

local absent = V2.Erasure.new(new_store(), {}, {})
local absent_result, absent_status = absent:IsErased(117)
assert(absent_result == false and absent_status.code == "not_found",
	"a provably absent erasure manifest did not return false")

local broken_store = {}
function broken_store:GetAsync(_key) error("transient read failure") end
function broken_store:UpdateAsync(_key, _transform) error("transient write failure") end
local unresolved = V2.Erasure.new(broken_store, {}, {})
local unresolved_result, unresolved_status = unresolved:IsErased(118)
assert(unresolved_result == nil and unresolved_status.code == "unknown",
	"unavailable erasure state was misreported as permission to write")

local projection_store = new_store()
local guarded_projections = V2.Projections.new(projection_store, {
	is_erased = function(user_id) return unresolved:IsErased(user_id) end,
})
assert(guarded_projections:Register("player_summary", 1, function(value, event)
	value.coins = event.coins
	return value
end))
local blocked_projection = guarded_projections:ApplyAsync("player_summary", {
	event_id = "unknown-erasure-projection",
	entity_id = "player-118",
	source_revision = 1,
	coins = 100,
	subject_user_ids = { 118 },
})
assert(blocked_projection.code == "unknown",
	"projection applied while authoritative erasure status was unavailable")

local unsupported_store = new_store()
unsupported_store:UpdateAsync("rv2erase-u119", function()
	return { version = 999, user_id = 119, erasure_id = "future-erasure", status = "future_state" }
end)
local unsupported = V2.Erasure.new(unsupported_store, {}, {})
local unsupported_result = unsupported:IsErased(119)
assert(unsupported_result == nil, "unknown/future erasure state did not fail closed")
local unsupported_execute = unsupported:ExecuteAsync(119, "future-erasure", 1)
assert(unsupported_execute.code == "unsupported_schema",
	"erasure execution accepted an unsupported manifest version")

Fake:Reset()
local profile_options = {
	schema_version = 1,
	retry_attempts = 2,
	lease_duration = 60,
	lease_renewal = 10,
	operation_deadline = 5,
	user_ids = { 123 },
	metadata = { private_marker = "must be cleared" },
	messaging_enabled = false,
	takeover_enabled = false,
	autosave_interval = 3600,
	queue_poll_interval = 3600,
}
local profile = RecordStore.new("RecordStoreErasureProfileTest", "global", "Player_123", profile_options)
local open_code, open_message = profile:Open({ Coins = 10 })
assert(open_code == "created" or open_code == "loaded", tostring(open_message))

local seeded_receipt, receipt_message = profile:TransactAsync(
	"erase-seed-receipt",
	"erase-seed-request",
	function(current) return table.clone(current) end,
	"erase-seed-receipt-material"
)
assert(seeded_receipt == "success", tostring(receipt_message))
local seeded_outbox, outbox_message = profile:CommitWithOutboxAsync(
	"erase-seed-outbox",
	"erase-seed-outbox-request",
	function(current) return table.clone(current) end,
	{
		{
			EventId = "erase-seed-event",
			DestinationStoreName = "ErasureDestination",
			DestinationScope = "global",
			DestinationProfileKey = "erase-subject-123",
			MessageType = "erase-fixture",
			Data = { subject_user_id = 123, private_payload = "must be cleared" },
		},
	},
	"erase-seed-outbox-material"
)
assert(seeded_outbox == "success", tostring(outbox_message))
local dispatched_count, dispatch_code, dispatch_message = profile:DispatchOutboxAsync(function(_event)
	return true, "erase-fixture-destination-receipt"
end, 1)
assert(dispatched_count == 1 and dispatch_code == "success", tostring(dispatch_message))
local before_raw = RecordStore.Mock.get_record_raw("RecordStoreErasureProfileTest", "global", "Player_123")
assert(type(before_raw) == "table" and type(before_raw.inbox_receipts) == "table"
	and before_raw.inbox_receipts["erase-seed-receipt"] ~= nil,
	"erasure fixture did not persist an inbox transaction receipt")
assert(type(before_raw.outbox) == "table" and before_raw.outbox["erase-seed-event"] ~= nil,
	"erasure fixture did not persist an outbox payload")
local before_erase = profile:Stats()
local profile_delete = V2.ProfileDoctor.DeleteIfGenerationAsync(profile, {
	store_name = "RecordStoreErasureProfileTest",
	scope = "global",
	key = "Player_123",
	generation = before_erase.generation,
	revision = before_erase.revision,
}, 123, "erase-profile-123")
assert(profile_delete.code == "deleted", "ProfileDoctor did not use generation-fenced core erasure: " .. tostring(profile_delete.message))
local after_erase = profile:Stats()
assert(after_erase.state == "tombstoned" and after_erase.generation == before_erase.generation + 1,
	"erase did not leave a higher-generation core tombstone")
assert(#profile:GetUserIds() == 0, "erasure tombstone retained DataStore UserIds")
assert(next(profile:GetMetadata()) == nil, "erasure tombstone retained custom DataStore metadata")
assert(profile:Get() == nil, "erased profile data remained readable through the old Record")
local after_raw = RecordStore.Mock.get_record_raw("RecordStoreErasureProfileTest", "global", "Player_123")
assert(type(after_raw) == "table" and after_raw.tombstone ~= nil,
	"generation-fenced core erasure did not persist its durable tombstone")
assert(next(after_raw.inbox_receipts or {}) == nil,
	"erasure tombstone retained canonical transaction/inbox request material")
assert(next(after_raw.outbox or {}) == nil,
	"erasure tombstone retained dispatched outbox payload material")

local stale_record = RecordStore.new("RecordStoreErasureProfileTest", "global", "Player_123", profile_options)
local stale_open, stale_message = stale_record:Open({ Coins = 0 })
assert(stale_open == "tombstoned", "normal Open recreated a generation-fenced erased profile: " .. tostring(stale_message))
local old_generation_delete = V2.ProfileDoctor.DeleteIfGenerationAsync(stale_record, {
	store_name = "RecordStoreErasureProfileTest",
	scope = "global",
	key = "Player_123",
	generation = before_erase.generation,
}, 123, "erase-profile-123")
assert(old_generation_delete.code == "deleted",
	"repeated erasure did not reconcile the already committed tombstone")
assert(stale_record:Stats().generation == before_erase.generation + 1,
	"repeated erasure changed the tombstone generation")

local tampered_manifest_store = new_store()
local tampered_manifest = V2.Erasure.new(tampered_manifest_store, { family(true) }, {
	verify_templates = function(_user_id, rendered) return type(rendered) == "table" and #rendered == 1 end,
})
local tampered_plan = tampered_manifest:PlanAsync(128, "erasure-tampered-entry")
assert(tampered_plan.code == "success" and tampered_plan.rtbf_coverage_verified == true,
	"tampered-manifest fixture did not create a verified plan")
tampered_manifest_store:UpdateAsync("rv2erase-u128", function(old)
	local changed = clone(old)
	changed.entries[1].item.key = "Unverified_128"
	return changed
end)
local deletes_before_tamper = delete_calls
local tampered_result = tampered_manifest:ExecuteAsync(128, "erasure-tampered-entry", 1)
assert(tampered_result.code == "corrupt",
	"erasure accepted a persisted entry outside the verified template inventory")
assert(delete_calls == deletes_before_tamper,
	"erasure performed a destructive action using a tampered manifest entry")

local mutating_adapter_family = family(true)
local mutating_adapter_calls = 0
mutating_adapter_family.redact_or_delete_if_generation = function(item, _user_id, _erasure_id)
	assert(item.generation == 1, "erasure adapter received a mutated manifest generation")
	item.generation = 999
	mutating_adapter_calls += 1
	if mutating_adapter_calls == 1 then return "retryable", "injected retry after adapter mutation" end
	return "deleted"
end
local mutating_adapter = V2.Erasure.new(new_store(), { mutating_adapter_family }, {
	verify_templates = function(_user_id, rendered) return type(rendered) == "table" and #rendered == 1 end,
})
local mutating_adapter_plan = mutating_adapter:PlanAsync(127, "erasure-adapter-mutation")
assert(mutating_adapter_plan.rtbf_coverage_verified == true, "adapter mutation fixture was not verified")
assert(mutating_adapter:ExecuteAsync(127, "erasure-adapter-mutation", 1).code == "retryable",
	"adapter mutation fixture did not pause for retry")
assert(mutating_adapter:ExecuteAsync(127, "erasure-adapter-mutation", 1).code == "committed",
	"mutating erasure adapter corrupted the immutable generation on retry")

local changed_contract_family = family(true)
local changed_contract_store = new_store()
local changed_contract = V2.Erasure.new(changed_contract_store, { changed_contract_family }, {
	verify_templates = function(_user_id, rendered) return type(rendered) == "table" and #rendered == 1 end,
})
local changed_contract_plan = changed_contract:PlanAsync(126, "erasure-template-contract-change")
assert(changed_contract_plan.code == "success" and changed_contract_plan.rtbf_coverage_verified == true,
	"template-contract fixture did not create a verified plan")
local deletes_before_contract_change = delete_calls
changed_contract_family.templates[1].key = "Backup_{user_id}"
local changed_contract_result = changed_contract:ExecuteAsync(126, "erasure-template-contract-change", 1)
assert(changed_contract_result.code == "conflict",
	"erasure proceeded after the declared template contract changed")
assert(delete_calls == deletes_before_contract_change,
	"erasure performed a destructive action after template-contract drift")

local corrupt_completed_store = new_store()
local corrupt_completed = V2.Erasure.new(corrupt_completed_store, { family(true) }, {
	verify_templates = function(_user_id, rendered) return type(rendered) == "table" and #rendered == 1 end,
})
local corrupt_plan = corrupt_completed:PlanAsync(125, "erasure-corrupt-completed")
assert(corrupt_plan.code == "success" and corrupt_plan.rtbf_coverage_verified == true,
	"corrupt-completed fixture did not create a verified plan")
corrupt_completed_store:UpdateAsync("rv2erase-u125", function(old)
	local changed = clone(old)
	changed.status = "completed"
	changed.cursor = 0
	changed.completed_count = 0
	return changed
end)
local corrupt_completed_result = corrupt_completed:ExecuteAsync(125, "erasure-corrupt-completed", 1)
assert(corrupt_completed_result.code == "corrupt",
	"erasure reported success for a completed manifest with incomplete durable checkpoints")

print("[PASS] Erasure coverage gating, bounded inventory, immutable checkpoints, writer fencing and generation-aware deletion.")
Shim.close()
