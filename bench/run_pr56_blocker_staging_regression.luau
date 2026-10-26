--!nocheck
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Shim = require("./RobloxShim")
local CoreRecordStore = Shim.load()
local server_script_service = Shim.environment.game:GetService("ServerScriptService")
local player_data_initializer = server_script_service:WaitForChild("PlayerDataInitializer")
local v2_module_instance = player_data_initializer:WaitForChild("RecordStoreV2")
local RecordStoreV2Factory = Shim.environment.require(v2_module_instance)
local RecordStoreV2 = RecordStoreV2Factory.new(CoreRecordStore, CoreRecordStore.MailboxV2)
local sha256_instance = player_data_initializer:WaitForChild("RecordStoreSHA256")
local SHA256 = Shim.environment.require(sha256_instance)
local migration_runner_instance = player_data_initializer:WaitForChild("PurchaseAuthorityMigrationRunner")
local MigrationRunner = Shim.environment.require(migration_runner_instance)

local Manifest = luau.load(fs.readFile("staging/pr56-blockers/RecordStoreApplicationInventory.luau"), {
	debugName = "RecordStoreApplicationInventory",
})()
local ErasureBinding = luau.load(fs.readFile("staging/pr56-blockers/PlayerDataErasureManifestBinding.luau"), {
	debugName = "PlayerDataErasureManifestBinding",
})()
local Authority = luau.load(fs.readFile("staging/pr56-blockers/PurchaseEntitlementDataStoreAuthority.luau"), {
	debugName = "PurchaseEntitlementDataStoreAuthority",
})()
local AtomicTombstone = luau.load(fs.readFile("staging/pr56-blockers/RecordStoreMaintenanceAtomicTombstone.luau"), {
	debugName = "RecordStoreMaintenanceAtomicTombstone",
})()
local PurchaseManifest = luau.load(fs.readFile("staging/pr56-blockers/PurchaseInventoryManifest.luau"), {
	debugName = "PurchaseInventoryManifest",
})()
local EntitlementCoordinator = luau.load(fs.readFile("staging/pr56-blockers/PurchaseEntitlementReceiptCoordinator.luau"), {
	debugName = "PurchaseEntitlementReceiptCoordinator",
})()

local function expect(value, message)
	if not value then error(message, 2) end
end

expect(SHA256.digest("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
	"SHA-256 empty-message vector did not match the standard result")
expect(SHA256.digest("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
	"SHA-256 abc vector did not match the standard result")
expect(SHA256.digest("The quick brown fox jumps over the lazy dog")
	== "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592",
	"SHA-256 multi-block padding vector did not match the standard result")

local function clone(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in pairs(value) do result[key] = clone(child) end
	return result
end

local function valid_manifest()
	return {
		schema_version = 1,
		kind = "rtbf",
		manifest_id = "rtbf-inventory-2026-10-26",
		revision = "inventory-r3",
		source_commit = string.rep("a", 40),
		review_status = "approved",
		reviewed_by = "independent-reviewer",
		reviewed_at_unix = 1792950000,
		review_attestation_ref = "evidence:review-attestation",
		inventory_complete = true,
		inventory_evidence_ref = "evidence:rtbf-inventory",
		writer_audit_complete = true,
		writer_audit_evidence_ref = "evidence:writer-audit",
		live_acceptance_complete = true,
		live_acceptance_evidence_ref = "evidence:live-acceptance",
		families = {
			{
				id = "player-profile",
				store_name = "PlayerData_Test1",
				scope = "global",
				locator_mode = "user_id_template",
				key_template = "Player_{user_id}",
				generation_field = "fencing_generation",
				fence_field = "erasure_fence",
				action = "tombstone",
				writer_ids = { "playerdata-core" },
				evidence_ref = "evidence:profile-family",
			},
		},
		writers = {
			{
				id = "playerdata-core",
				source_path = "src/PlayerDataInitializer/PlayerDataCore.luau",
				family_ids = { "player-profile" },
				fence_mode = "same_key_update_async",
				fence_evidence_ref = "evidence:profile-writer-fence",
			},
		},
	}
end

local function valid_manifest_with_external_family()
	local manifest = valid_manifest()
	manifest.families[#manifest.families + 1] = {
		id = "purchase-authority",
		store_name = "PurchaseAuthority",
		scope = "global",
		locator_mode = "external_inventory",
		inventory_source_ref = "evidence:purchase-user-index",
		generation_field = "fencing_generation",
		fence_field = "erasure_fence",
		action = "tombstone",
		writer_ids = { "purchase-authority-writer" },
		evidence_ref = "evidence:purchase-authority-family",
	}
	manifest.writers[#manifest.writers + 1] = {
		id = "purchase-authority-writer",
		source_path = "src/PlayerDataInitializer/PurchaseDataStoreAuthority.luau",
		family_ids = { "purchase-authority" },
		fence_mode = "same_key_update_async",
		fence_evidence_ref = "evidence:purchase-authority-writer-fence",
	}
	return manifest
end

do
local empty_scope_manifest = valid_manifest()
empty_scope_manifest.families[1].scope = ""
expect(Manifest.validate(empty_scope_manifest) ~= nil,
	"exact empty DataStore scope was rejected")

local external_inventory_manifest = valid_manifest()
external_inventory_manifest.families[1].locator_mode = "external_inventory"
external_inventory_manifest.families[1].key_template = nil
external_inventory_manifest.families[1].inventory_source_ref = "evidence:external-key-inventory"
expect(Manifest.validate(external_inventory_manifest) ~= nil,
	"externally enumerated user-key families required a guessed key template")

local normalized, manifest_error = Manifest.validate(valid_manifest())
expect(normalized ~= nil and manifest_error == nil, manifest_error or "valid reviewed inventory manifest was rejected")
expect(normalized.manifest_id == "rtbf-inventory-2026-10-26", "manifest identity changed")
expect(table.isfrozen(normalized) and table.isfrozen(normalized.families)
	and table.isfrozen(normalized.families[1]) and table.isfrozen(normalized.writers[1])
	and table.isfrozen(normalized.families[1].writer_ids)
	and table.isfrozen(normalized.writers[1].family_ids),
	"normalized manifest, nested catalog entries, and relationship lists must be immutable")

local activation, activation_error = Manifest.verify_for_activation(valid_manifest(), function(value)
	return value.manifest_id == "rtbf-inventory-2026-10-26"
		and value.revision == "inventory-r3"
		and value.review_status == "approved"
end)
expect(activation ~= nil and activation_error == nil, activation_error or "independent verification did not accept a complete manifest")

local rejected, rejected_error = Manifest.verify_for_activation(valid_manifest(), function()
	return false, "independent evidence did not reconcile"
end)
expect(rejected == nil and string.find(rejected_error or "", "reconcile") ~= nil,
	"activation proceeded without independent verifier approval")

local awaiting_live_acceptance = valid_manifest()
awaiting_live_acceptance.live_acceptance_complete = false
awaiting_live_acceptance.live_acceptance_evidence_ref = nil
expect(Manifest.validate(awaiting_live_acceptance) ~= nil,
	"an inventory with pending live acceptance could not be independently staged")
local not_live_ready = Manifest.verify_for_activation(awaiting_live_acceptance, function()
	return true
end)
expect(not_live_ready == nil, "activation bypassed the live Roblox acceptance gate")

local erasure_runtime = {
	verify_templates = function(user_id, rendered)
		return user_id > 0 and type(rendered) == "table" and #rendered == 1
	end,
}
local erasure_attestation_calls = 0
local erasure_config, erasure_manifest, erasure_bind_error = ErasureBinding.bind(
	Manifest,
	valid_manifest(),
	erasure_runtime,
	{},
	function(verified_manifest, family_adapters, runtime_options)
		erasure_attestation_calls += 1
		return verified_manifest.manifest_id == "rtbf-inventory-2026-10-26"
			and #family_adapters == 0
			and table.isfrozen(family_adapters)
			and runtime_options.verify_templates == erasure_runtime.verify_templates,
			"RTBF runtime attestation failed"
	end
)
expect(erasure_config ~= nil, erasure_bind_error or "reviewed RTBF manifest did not bind to PlayerDataErasure")
expect(erasure_manifest.manifest_id == "rtbf-inventory-2026-10-26"
	and erasure_config.profile_store_name == "PlayerData_Test1"
	and erasure_config.profile_scope == "global"
	and erasure_config.key_prefix == "Player_"
	and erasure_config.profile_family_verified == true
	and erasure_config.writer_inventory_verified == true
	and erasure_config.application_inventory_manifest_id == erasure_manifest.manifest_id,
	"bound PlayerDataErasure options did not derive their profile identity and attestations from the reviewed manifest")
expect(erasure_attestation_calls == 1
	and table.isfrozen(erasure_config)
	and table.isfrozen(erasure_config.additional_families),
	"RTBF erasure config was not verified once and frozen")

local external_manifest = valid_manifest_with_external_family()
local external_runtime = {
	verify_templates = function(user_id, rendered)
		if user_id ~= 1001 or type(rendered) ~= "table" or #rendered ~= 2 then return false end
		for _, entry in ipairs(rendered) do
			if entry.family == "purchase-authority" then
				return entry.template.locator_mode == "external_inventory"
					and entry.template.inventory_source_ref == "evidence:purchase-user-index"
			end
		end
		return false
	end,
}
local external_adapter = {
	family_id = "purchase-authority",
	action = "tombstone",
	inventory = function() return {}, true end,
	fence_user = function() return true end,
	dependencies_clear = function() return true end,
	redact_or_delete_if_generation = function() return "deleted" end,
}
local external_config, activated_external, external_bind_error = ErasureBinding.bind(
	Manifest,
	external_manifest,
	external_runtime,
	{ external_adapter },
	function(verified_manifest, family_adapters)
		return verified_manifest.families[2].locator_mode == "external_inventory"
			and #family_adapters == 1 and table.isfrozen(family_adapters),
			"external inventory attestation did not reconcile"
	end
)
expect(external_config ~= nil,
	external_bind_error or "reviewed dynamic RTBF family did not bind")
expect(activated_external.manifest_id == external_manifest.manifest_id
	and #external_config.additional_families == 1
	and external_config.additional_families[1].templates[1].locator_mode == "external_inventory"
	and external_config.additional_families[1].templates[1].inventory_source_ref == "evidence:purchase-user-index"
	and external_config.additional_families[1].templates[1].key == "__rtbf_external__{user_id}",
	"dynamic RTBF binding lost its explicit inventory mode, source evidence, or reserved marker")

local override_verifier_called = false
local unsafe_erasure_override = ErasureBinding.bind(
	Manifest,
	valid_manifest(),
	{
		profile_store_name = "UnreviewedOverride",
		verify_templates = erasure_runtime.verify_templates,
	},
	{},
	function()
		override_verifier_called = true
		return true
	end
)
expect(unsafe_erasure_override == nil and not override_verifier_called,
	"erasure binding allowed an unreviewed profile identity override")

local external_profile_verifier_called = false
local external_profile_binding = ErasureBinding.bind(
	Manifest,
	external_inventory_manifest,
	erasure_runtime,
	{},
	function()
		external_profile_verifier_called = true
		return true
	end
)
expect(external_profile_binding == nil and not external_profile_verifier_called,
	"external inventory without exact templates was bound to the template-based erasure coordinator")

local manifest_with_sidecar = valid_manifest()
manifest_with_sidecar.families[2] = {
	id = "player-sidecar",
	store_name = "PlayerSidecars",
	scope = "global",
	locator_mode = "user_id_template",
	key_template = "Sidecar_{user_id}",
	generation_field = "generation",
	fence_field = "erasure_fence",
	action = "redact",
	writer_ids = { "player-sidecar-writer" },
	evidence_ref = "evidence:player-sidecar-inventory",
}
manifest_with_sidecar.writers[2] = {
	id = "player-sidecar-writer",
	source_path = "src/PlayerSidecar.luau",
	family_ids = { "player-sidecar" },
	fence_mode = "same_key_update_async",
	fence_evidence_ref = "evidence:player-sidecar-writer-fence",
}
local sidecar_adapter = {
	family_id = "player-sidecar",
	action = "redact",
	inventory = function()
		return {}, true
	end,
	fence_user = function()
		return true, nil
	end,
	dependencies_clear = function()
		return true, nil
	end,
	redact_or_delete_if_generation = function()
		return "redacted", nil
	end,
}
local sidecar_config, sidecar_manifest, sidecar_bind_error = ErasureBinding.bind(
	Manifest,
	manifest_with_sidecar,
	{
		verify_templates = function(user_id, rendered)
			return user_id > 0 and #rendered == 2
		end,
	},
	{ sidecar_adapter },
	function(verified_manifest, family_adapters)
		return verified_manifest.families[2].id == "player-sidecar"
			and #family_adapters == 1
			and table.isfrozen(family_adapters)
			and family_adapters[1].family_id == "player-sidecar",
			"sidecar writer/family binding failed review"
	end
)
expect(sidecar_config ~= nil,
	sidecar_bind_error or "reviewed static-template sidecar did not bind")
expect(sidecar_manifest.manifest_id == manifest_with_sidecar.manifest_id
	and #sidecar_config.additional_families == 1
	and sidecar_config.additional_families[1].name == "player-sidecar"
	and sidecar_config.additional_families[1].templates[1].name == "PlayerSidecars"
	and sidecar_config.additional_families[1].templates[1].key == "Sidecar_{user_id}"
	and sidecar_config.additional_families[1].templates_verified == true,
	"RTBF sidecar config did not preserve exact manifest templates and callbacks")
expect(table.isfrozen(sidecar_config.additional_families[1])
	and table.isfrozen(sidecar_config.additional_families[1].templates[1]),
	"bound RTBF sidecar adapter is mutable")

local missing_sidecar_verifier_called = false
local missing_sidecar_config = ErasureBinding.bind(
	Manifest,
	manifest_with_sidecar,
	{
		verify_templates = erasure_runtime.verify_templates,
	},
	{},
	function()
		missing_sidecar_verifier_called = true
		return true
	end
)
expect(missing_sidecar_config == nil and not missing_sidecar_verifier_called,
	"RTBF manifest with an unbound key family reached the activation verifier")

local mismatched_sidecar_action = ErasureBinding.bind(
	Manifest,
	manifest_with_sidecar,
	{ verify_templates = erasure_runtime.verify_templates },
	{ {
		family_id = "player-sidecar",
		action = "tombstone",
		inventory = sidecar_adapter.inventory,
		fence_user = sidecar_adapter.fence_user,
		dependencies_clear = sidecar_adapter.dependencies_clear,
		redact_or_delete_if_generation = sidecar_adapter.redact_or_delete_if_generation,
	} },
	function()
		return true
	end
)
expect(mismatched_sidecar_action == nil,
	"RTBF erasure adapter action did not match the reviewed manifest")


local verifier_called = false
local incomplete = valid_manifest()
incomplete.writers[1].family_ids = {}
local bad_manifest, bad_manifest_error = Manifest.verify_for_activation(incomplete, function()
	verifier_called = true
	return true
end)
expect(bad_manifest == nil and bad_manifest_error ~= nil and not verifier_called,
	"independent verifier ran before the malformed inventory manifest was rejected")

local no_families = valid_manifest()
no_families.families = {}
expect(Manifest.validate(no_families) == nil, "empty RTBF family inventory was accepted")

local bad_template = valid_manifest()
bad_template.families[1].key_template = "Player_{user_id}_{user_id}"
expect(Manifest.validate(bad_template) == nil, "duplicate user ID placeholders were accepted")

local aliased_generation_fence = valid_manifest()
aliased_generation_fence.families[1].fence_field = aliased_generation_fence.families[1].generation_field
expect(Manifest.validate(aliased_generation_fence) == nil,
	"RTBF generation and fence fields were allowed to alias")

local overlong_template = valid_manifest()
overlong_template.families[1].key_template = string.rep("x", 40) .. "{user_id}"
expect(Manifest.validate(overlong_template) == nil, "a key template that can exceed Roblox's key limit was accepted")

local missing_writer = valid_manifest()
missing_writer.writers = {}
expect(Manifest.validate(missing_writer) == nil, "a family with no inventoried active writer was accepted")

local wrong_reverse_link = valid_manifest()
wrong_reverse_link.writers[1].family_ids = {}
expect(Manifest.validate(wrong_reverse_link) == nil, "an unaccounted writer-to-family relationship was accepted")

local no_terminal_proof = valid_manifest()
no_terminal_proof.inventory_complete = false
expect(Manifest.validate(no_terminal_proof) == nil, "an inventory without a completeness attestation was accepted")

local invalid_writer = valid_manifest()
invalid_writer.writers[1].fence_mode = "preflight_only"
expect(Manifest.validate(invalid_writer) == nil, "a preflight-only writer fence was accepted")

end

local function make_store()
	local store = { rows = {}, lose_next_response = false, fail_reads = false }
	function store:GetAsyncFresh(key)
		if self.fail_reads then return nil, "injected read failure" end
		return clone(self.rows[key]), nil
	end
	function store:UpdateAsync(key, transform)
		if self.fail_reads then return nil, "injected write failure" end
		local candidate = transform(clone(self.rows[key]))
		if candidate ~= nil then self.rows[key] = clone(candidate) end
		local observed = clone(self.rows[key])
		if self.lose_next_response then
			self.lose_next_response = false
			return nil, "injected response loss after commit"
		end
		return observed, nil
	end
	return store
end


local function make_external_erasure(inventory_items)
	local manifest_store = make_store()
	local deleted = {}
	local fenced = {}
	local profile_items = {
		{ name = "PlayerData_Test1", scope = "global", key = "Player_1001", generation = 7 },
	}
	local function family(name, template, inventory)
		return {
			name = name,
			templates = { template },
			templates_verified = true,
			inventory = inventory,
			fence_user = function(user_id, erasure_id, planned)
				if user_id ~= 1001 or erasure_id == "" or type(planned) ~= "table" then
					return false, "invalid writer fence request"
				end
				fenced[name] = true
				return true
			end,
			dependencies_clear = function() return true end,
			redact_or_delete_if_generation = function(item, user_id, erasure_id)
				if fenced[name] ~= true or user_id ~= 1001 or erasure_id == ""
					or type(item) ~= "table" or type(item.generation) ~= "number"
				then
					return "skipped", "deletion attempted without a valid same-user fence"
				end
				deleted[#deleted + 1] = item.name .. "/" .. item.scope .. "/" .. item.key
				return "deleted"
			end,
		}
	end
	local families = {
		family("player-profile", {
			name = "PlayerData_Test1",
			scope = "global",
			key = "Player_{user_id}",
			locator_mode = "user_id_template",
		}, function() return clone(profile_items), true end),
		family("purchase-authority", {
			name = "PurchaseAuthority",
			scope = "global",
			key = "__rtbf_external__{user_id}",
			locator_mode = "external_inventory",
			inventory_source_ref = "evidence:purchase-user-index",
		}, function() return clone(inventory_items()), true end),
	}
	local erasure = RecordStoreV2.Erasure.new(manifest_store, families, {
		require_inventory_attestation = true,
		application_inventory_manifest_id = "rtbf-inventory-r4",
		writer_inventory_verified = true,
		verify_templates = function(user_id, rendered)
			if user_id ~= 1001 or type(rendered) ~= "table" or #rendered ~= 2 then return false end
			for _, entry in ipairs(rendered) do
				if entry.family == "purchase-authority" then
					return entry.template.locator_mode == "external_inventory"
						and entry.template.inventory_source_ref == "evidence:purchase-user-index"
				end
			end
			return false
		end,
	})
	return erasure, manifest_store, deleted, fenced
end

do
	local dynamic_items = {
		{ name = "PurchaseAuthority", scope = "global", key = "receipt-user-1001-a", generation = 3 },
		{ name = "PurchaseAuthority", scope = "global", key = "receipt-user-1001-b", generation = 9 },
	}
	local erasure, _, deleted = make_external_erasure(function() return dynamic_items end)
	local plan = erasure:PlanAsync(1001, "erasure-external-new-key")
	expect(plan.code == "success" and plan.rtbf_coverage_verified == true and #plan.entries == 3,
		"attested dynamic inventory did not produce an exhaustive exact-key erasure plan")

	dynamic_items[#dynamic_items + 1] = {
		name = "PurchaseAuthority", scope = "global", key = "receipt-user-1001-created-after-plan", generation = 2,
	}
	local blocked = erasure:ExecuteAsync(1001, "erasure-external-new-key", 16)
	expect(blocked.code == "inventory_changed" and #deleted == 0,
		"post-plan key creation was not detected after writer fencing before deletion")

	local stable_items = {
		{ name = "PurchaseAuthority", scope = "global", key = "receipt-user-1001-a", generation = 3 },
		{ name = "PurchaseAuthority", scope = "global", key = "receipt-user-1001-b", generation = 9 },
	}
	local complete_erasure, _, complete_deleted = make_external_erasure(function() return stable_items end)
	local complete_plan = complete_erasure:PlanAsync(1001, "erasure-external-complete")
	expect(complete_plan.code == "success" and complete_plan.rtbf_coverage_verified == true,
		"stable external inventory did not establish an attested plan")
	local completed = complete_erasure:ExecuteAsync(1001, "erasure-external-complete", 16)
	expect(completed.code == "committed" and completed.rtbf_coverage_verified == true
		and #complete_deleted == 3,
		"stable external inventory did not complete through exact locators after the post-fence scan")

	local without_attestation_ok = pcall(function()
		RecordStoreV2.Erasure.new(make_store(), {
			{
				name = "external",
				templates = {{
					name = "PurchaseAuthority", scope = "global",
					key = "__rtbf_external__{user_id}", locator_mode = "external_inventory",
					inventory_source_ref = "evidence:purchase-user-index",
				}},
				templates_verified = true,
				inventory = function() return {}, true end,
				fence_user = function() return true end,
				dependencies_clear = function() return true end,
				redact_or_delete_if_generation = function() return "deleted" end,
			},
		}, {
			verify_templates = function() return true end,
		})
	end)
	expect(not without_attestation_ok,
		"external inventory was accepted without an attested application manifest and writer audit")
end

local store = make_store()
local now = 1792951000
local authority = Authority.new({
	key_prefix = "ent:",
	store_adapter = store,
	now_unix = function() return now end,
})

local reserve, reserve_error = authority:ReserveAsync("VIP_LIFETIME", 1001, 501, "purchase-1")
expect(reserve.code == "claimed", reserve_error or "first entitlement reservation did not claim the entitlement")
local duplicate_reserve = authority:ReserveAsync("VIP_LIFETIME", 1001, 501, "purchase-1")
expect(duplicate_reserve.code == "claimed", "retrying the same entitlement reservation was not idempotent")

local competing_pending = authority:ReserveAsync("VIP_LIFETIME", 1001, 501, "purchase-2")
expect(competing_pending.code == "pending", "a competing purchase bypassed an unresolved entitlement claim")

store.lose_next_response = true
local committed, commit_error = authority:CommitAsync("VIP_LIFETIME", 1001, 501, "purchase-1")
expect(committed.code == "committed", commit_error or "commit-then-response-loss was not reconciled from durable state")
expect(committed.record.status == "owned" and committed.record.purchase_id == "purchase-1",
	"committed entitlement did not retain its permanent owner identity")

local committed_retry = authority:CommitAsync("VIP_LIFETIME", 1001, 501, "purchase-1")
expect(committed_retry.code == "committed", "repeated entitlement commit was not idempotent")

local another_purchase = authority:ReserveAsync("VIP_LIFETIME", 1001, 501, "purchase-2")
expect(another_purchase.code == "already_owned", "a user who already owns a lifetime entitlement was not deduplicated")

local status = authority:GetStatusAsync("VIP_LIFETIME", 1001)
expect(status.code == "owned" and status.record.purchase_id == "purchase-1",
	"fresh entitlement status read did not return the permanent ownership record")

local invalid_request = authority:ReserveAsync("VIP_LIFETIME", 1001, 0, "bad-product")
expect(invalid_request.code == "invalid", "malformed product identity was not rejected")
local unsafe_user_id = authority:ReserveAsync("VIP_LIFETIME", 9007199254740992, 501, "unsafe-user-id")
expect(unsafe_user_id.code == "invalid", "an inexact integer identity beyond the safe range was accepted")
local purchase_id_reuse = authority:ReserveAsync("VIP_LIFETIME", 1001, 501, "purchase-1")
expect(purchase_id_reuse.code == "owned", "an already committed original purchase was not recognized")

local other_user = authority:ReserveAsync("VIP_LIFETIME", 1002, 501, "purchase-3")
expect(other_user.code == "claimed", "one user's entitlement claim incorrectly blocked another user")

local imported, import_error = authority:BackfillAsync("PREEXISTING_LIFETIME", 1003, 502, "historical-purchase-1")
expect(imported.code == "imported", import_error or "historical entitlement was not imported as already owned")
local imported_retry = authority:BackfillAsync("PREEXISTING_LIFETIME", 1003, 503, "historical-purchase-2")
expect(imported_retry.code == "already_owned", "historical entitlement backfill was not idempotent")

local pending_import_store = make_store()
local pending_import_authority = Authority.new({
	key_prefix = "ent:",
	store_adapter = pending_import_store,
	now_unix = function() return now end,
})
local pending_first = pending_import_authority:ReserveAsync("PACK_LIFETIME", 1004, 505, "live-purchase")
expect(pending_first.code == "claimed", "pending import scenario did not establish a claim")
local blocked_import = pending_import_authority:BackfillAsync("PACK_LIFETIME", 1004, 505, "historical-purchase")
expect(blocked_import.code == "pending", "historical backfill overwrote a live unresolved entitlement claim")

local unknown_store = make_store()
local unknown_authority = Authority.new({
	key_prefix = "ent:",
	store_adapter = unknown_store,
	now_unix = function() return now end,
})
unknown_store.fail_reads = true
local unavailable = unknown_authority:GetStatusAsync("UNAVAILABLE", 1005)
expect(unavailable.code == "unknown", "an unavailable authoritative read was reported as not found")

local corrupt_store = make_store()
local corrupt_authority = Authority.new({
	key_prefix = "ent:",
	store_adapter = corrupt_store,
	now_unix = function() return now end,
})
local seeded = corrupt_authority:ReserveAsync("COLLISION", 1006, 501, "seed-purchase")
expect(seeded.code == "claimed", "collision fixture could not create a durable row")
local key_digest = next(corrupt_store.rows)
expect(key_digest ~= nil, "collision fixture did not write a key")
corrupt_store.rows[key_digest] = {
	version = 1,
	entitlement_id = "DIFFERENT",
	player_id = 1006,
	purchase_id = "unrelated",
	product_id = 501,
	status = "owned",
	revision = 1,
	created_at = now,
	updated_at = now,
}
local collision = corrupt_authority:ReserveAsync("COLLISION", 1006, 501, "purchase-4")
expect(collision.code == "conflict", "hashed-key identity collision did not fail closed")
local collision_status = corrupt_authority:GetStatusAsync("COLLISION", 1006)
expect(collision_status.code == "conflict",
	"uncached entitlement status read misclassified a hashed-key identity collision")


local function make_atomic_store(initial)
	local store = {
		row = clone(initial),
		lose_next_response = false,
		fail_reads = false,
		throw_before_update = false,
		before_update = nil,
	}
	function store:GetAsync(key, options)
		expect(options ~= nil and options.UseCache == false, "atomic tombstone verification read must bypass cache")
		if self.fail_reads then error("injected uncached read failure") end
		return clone(self.row), { Version = "1" }
	end
	function store:UpdateAsync(key, transform)
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

local function make_atomic_adapter(overrides)
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
				payload = value.payload,
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

local function make_atomic_profile(generation, job_id, eligible, dependencies_clear)
	return {
		fencing_generation = generation,
		maintenance_fence_job_id = job_id,
		eligible = eligible,
		dependencies_clear = dependencies_clear,
		payload = { coins = 100, flags = { keep = true } },
	}
end

local atomic_item = { name = "Profiles", scope = "global", key = "Player_1" }
local atomic_adapter = make_atomic_adapter()
local atomic_store = make_atomic_store(make_atomic_profile(4, nil, true, true))
local acquired_fence, fenced_generation, fence_error = atomic_adapter:FenceIfGeneration(
	atomic_store, atomic_item, 4, "job-atomic-1"
)
expect(acquired_fence == "fenced" and fenced_generation == 5,
	fence_error or "same-key generation fence was not atomically acquired")
expect(atomic_store.row.fencing_generation == 5
	and atomic_store.row.maintenance_fence_job_id == "job-atomic-1"
	and atomic_store.row.tombstone ~= true,
	"maintenance fencing did not atomically advance the generation and claim the job")
local atomic_action, atomic_error = atomic_adapter:DeleteIfGeneration(
	atomic_store, atomic_item, fenced_generation, "job-atomic-1"
)
expect(atomic_action == "deleted", atomic_error or "same-key fenced tombstone did not commit")
expect(atomic_store.row.fencing_generation == 6
	and atomic_store.row.maintenance_fence_job_id == "job-atomic-1"
	and atomic_store.row.tombstone_source_generation == 5,
	"tombstone did not advance the fenced generation and retain the same-key job fence")
expect(atomic_store.row.payload.coins == 100 and atomic_store.row.payload.flags.keep == true,
	"tombstone callback did not preserve its explicitly retained payload")

local atomic_retry, atomic_retry_error = atomic_adapter:FenceAndDeleteIfGeneration(
	atomic_store, atomic_item, 4, "job-atomic-1"
)
expect(atomic_retry == "deleted", atomic_retry_error or "composite fence/tombstone retry was not idempotent")

local composite_store = make_atomic_store(make_atomic_profile(2, nil, true, true))
local composite_action, composite_error = atomic_adapter:FenceAndDeleteIfGeneration(
	composite_store, atomic_item, 2, "job-atomic-1"
)
expect(composite_action == "deleted",
	composite_error or "single-call fence-and-tombstone did not acquire its fence before deletion")
expect(composite_store.row.fencing_generation == 4
	and composite_store.row.tombstone_source_generation == 3
	and composite_store.row.maintenance_fence_job_id == "job-atomic-1",
	"composite maintenance operation did not advance both fence and tombstone generations safely")
local composite_retry = atomic_adapter:FenceAndDeleteIfGeneration(
	composite_store, atomic_item, 2, "job-atomic-1"
)
expect(composite_retry == "deleted", "composite maintenance retry failed to recognize its durable tombstone")

local wrong_fence_store = make_atomic_store(make_atomic_profile(4, "different-job", true, true))
local wrong_fence_action = atomic_adapter:DeleteIfGeneration(
	wrong_fence_store, atomic_item, 4, "job-atomic-1"
)
expect(wrong_fence_action == "skipped" and wrong_fence_store.row.tombstone ~= true,
	"a foreign same-key job fence did not block deletion")

local stale_generation_store = make_atomic_store(make_atomic_profile(4, nil, true, true))
stale_generation_store.before_update = function(store)
	store.row.fencing_generation = 5
	store.row.payload.coins = 999
end
local stale_generation_action = atomic_adapter:DeleteIfGeneration(
	stale_generation_store, atomic_item, 4, "job-atomic-1"
)
expect(stale_generation_action == "skipped" and stale_generation_store.row.payload.coins == 999
	and stale_generation_store.row.tombstone ~= true,
	"a concurrent generation change was overwritten by a stale deletion")

local ineligible_store = make_atomic_store(make_atomic_profile(4, nil, false, true))
local ineligible_fence = atomic_adapter:FenceIfGeneration(ineligible_store, atomic_item, 4, "job-atomic-1")
expect(ineligible_fence == "skipped" and ineligible_store.row.fencing_generation == 4
	and ineligible_store.row.maintenance_fence_job_id == nil,
	"an ineligible record acquired a maintenance fence")
local ineligible_action = atomic_adapter:DeleteIfGeneration(ineligible_store, atomic_item, 4, "job-atomic-1")
expect(ineligible_action == "skipped" and ineligible_store.row.tombstone ~= true,
	"a record that was not eligible was tombstoned")

local dependent_store = make_atomic_store(make_atomic_profile(4, nil, true, false))
local dependent_fence = atomic_adapter:FenceIfGeneration(dependent_store, atomic_item, 4, "job-atomic-1")
expect(dependent_fence == "skipped" and dependent_store.row.fencing_generation == 4
	and dependent_store.row.maintenance_fence_job_id == nil,
	"a record with unresolved dependencies acquired a maintenance fence")
local dependent_action = atomic_adapter:DeleteIfGeneration(dependent_store, atomic_item, 4, "job-atomic-1")
expect(dependent_action == "skipped" and dependent_store.row.tombstone ~= true,
	"a record with unresolved dependencies was tombstoned")

local lost_fence_store = make_atomic_store(make_atomic_profile(4, nil, true, true))
lost_fence_store.lose_next_response = true
local lost_fence_action, lost_fence_generation, lost_fence_error = atomic_adapter:FenceIfGeneration(
	lost_fence_store, atomic_item, 4, "job-atomic-1"
)
expect(lost_fence_action == "fenced" and lost_fence_generation == 5,
	lost_fence_error or "fence commit response loss was not reconciled from fresh state")

local lost_response_store = make_atomic_store(make_atomic_profile(4, nil, true, true))
local before_lost_delete, before_lost_delete_generation = atomic_adapter:FenceIfGeneration(
	lost_response_store, atomic_item, 4, "job-atomic-1"
)
expect(before_lost_delete == "fenced" and before_lost_delete_generation == 5,
	"tombstone response-loss fixture could not acquire the writer fence")
lost_response_store.lose_next_response = true
local lost_response_action, lost_response_error = atomic_adapter:DeleteIfGeneration(
	lost_response_store, atomic_item, before_lost_delete_generation, "job-atomic-1"
)
expect(lost_response_action == "deleted", lost_response_error or "tombstone commit response loss was not reconciled")
local lost_response_retry = atomic_adapter:FenceAndDeleteIfGeneration(
	lost_response_store, atomic_item, 4, "job-atomic-1"
)
expect(lost_response_retry == "deleted", "composite operation did not reconcile an already committed tombstone")

local unavailable_store = make_atomic_store(make_atomic_profile(4, "job-atomic-1", true, true))
unavailable_store.throw_before_update = true
unavailable_store.fail_reads = true
local unavailable_action = atomic_adapter:DeleteIfGeneration(
	unavailable_store, atomic_item, 4, "job-atomic-1"
)
expect(unavailable_action == "unknown" and unavailable_store.row.tombstone ~= true,
	"unreconciled storage errors were not reported as unknown")

local malformed_tombstone_adapter = make_atomic_adapter({
	make_tombstone = function(value, _info, _expected_generation, _job_id, _now)
		return clone(value)
	end,
})
local malformed_tombstone_store = make_atomic_store(make_atomic_profile(4, "job-atomic-1", true, true))
local malformed_tombstone_action = malformed_tombstone_adapter:DeleteIfGeneration(
	malformed_tombstone_store, atomic_item, 4, "job-atomic-1"
)
expect(malformed_tombstone_action == "unknown" and malformed_tombstone_store.row.tombstone ~= true,
	"a malformed tombstone lacking the next generation was committed")

local outside_prefix_action = atomic_adapter:DeleteIfGeneration(
	make_atomic_store(make_atomic_profile(4, "job-atomic-1", true, true)),
	{ name = "Profiles", scope = "global", key = "Other_1" },
	4,
	"job-atomic-1"
)
expect(outside_prefix_action == "skipped", "same-key deletion accepted an out-of-prefix locator")

local wrong_job_action = atomic_adapter:DeleteIfGeneration(
	make_atomic_store(make_atomic_profile(4, "job-atomic-1", true, true)),
	atomic_item,
	4,
	"other-job"
)
expect(wrong_job_action == "skipped", "same-key deletion accepted a different job identity")


do
local function valid_purchase_manifest()
	return {
		schema_version = 1,
		kind = "purchase_inventory",
		manifest_id = "purchase-inventory-2026-10-26",
		source_revision = "purchase-export-r2",
		source_snapshot_id = "immutable-snapshot-2026-10-26",
		source_systems = { "marketplace-receipts" },
		legacy_receipt_paths = { "legacy-dev-product-receipts" },
		row_order = "purchase_id_asc_player_id_asc_product_id_asc",
		expected_purchase_count = 2,
		expected_inventory_digest = string.rep("c", 64),
		digest_algorithm = "sha256-chain-v1",
		exported_at_unix = 1792950000,
		review_status = "approved",
		reviewed_by = "independent-reviewer",
		reviewed_at_unix = 1792950010,
		source_evidence_ref = "evidence:purchase-source-export",
		end_of_inventory_evidence_ref = "evidence:purchase-terminal-page",
		duplicate_conflict_report_ref = "evidence:purchase-duplicates-conflicts",
		coverage_review_ref = "evidence:purchase-coverage-review",
		archived_accounts_included = true,
		deleted_accounts_included = true,
	}
end


local bound_manifest_raw = valid_purchase_manifest()
bound_manifest_raw.source_revision = "purchase-export-bound-r3"
bound_manifest_raw.source_snapshot_id = "immutable-source-snapshot-r3"
bound_manifest_raw.expected_purchase_count = 3
local bound_rows = {
	{ PurchaseId = "purchase-bound-001", PlayerId = 2001, ProductId = 501 },
	{ PurchaseId = "purchase-bound-002", PlayerId = 2002, ProductId = 501 },
	{ PurchaseId = "purchase-bound-003", PlayerId = 2003, ProductId = 501 },
}
local bound_digest, bound_digest_error = MigrationRunner.ComputeInventoryDigest(bound_rows)
expect(bound_digest ~= nil, bound_digest_error or "could not compute SHA-256 chain digest for bound purchase fixture")
bound_manifest_raw.expected_inventory_digest = bound_digest :: string
local source_verification_calls = 0
local terminal_verification_calls = 0
local source_reader = { snapshot_id = "immutable-source-snapshot-r3" }
function source_reader:read_page(cursor, maximum)
	expect(maximum == 2, "bound purchase runner did not preserve its configured page bound")
	if cursor == nil then
		return {
			items = { clone(bound_rows[1]) },
			next_cursor = "bound-page-2",
			done = false,
			source_revision = bound_manifest_raw.source_revision,
		}, nil
	elseif cursor == "bound-page-2" then
		return {
			items = { clone(bound_rows[2]), clone(bound_rows[3]) },
			next_cursor = nil,
			done = true,
			source_revision = bound_manifest_raw.source_revision,
		}, nil
	end
	return nil, "unrecognized source cursor"
end
local migration_processor = { calls = 0, imported_ids = {} }
function migration_processor:BackfillExternalAuthorityAsync(items, maximum)
	self.calls += 1
	expect(maximum == #items, "purchase migration processor received an unbounded batch")
	for _, item in ipairs(items) do
		self.imported_ids[#self.imported_ids + 1] = item.PurchaseId
	end
	return {
		code = "complete",
		processed_count = #items,
		backfilled_count = #items,
		duplicate_count = 0,
		failed_index = nil,
		message = nil,
	}
end
local migration_checkpoint_store = { value = nil }
function migration_checkpoint_store:GetAsyncFresh(key)
	return clone(self.value), nil
end
function migration_checkpoint_store:UpdateAsync(key, transform)
	local changed = transform(clone(self.value))
	if changed ~= nil then self.value = clone(changed) end
	return clone(self.value), nil
end

local binding_source_verified, source_manifest_error
local bound_runner_config, bound_manifest, binding_error = PurchaseManifest.bind_runner_config(
	bound_manifest_raw,
	{
		job_id = "purchase-bound-migration-r3",
		source = source_reader,
		processor = migration_processor,
		checkpoint_store = migration_checkpoint_store,
		checkpoint_key = "purchase-migration:bound-r3",
		page_size = 2,
	},
	function(manifest, source)
		source_verification_calls += 1
		return source.snapshot_id == manifest.source_snapshot_id
			and manifest.source_snapshot_id == "immutable-source-snapshot-r3"
			and manifest.source_revision == "purchase-export-bound-r3"
			and manifest.expected_purchase_count == 3
			and manifest.expected_inventory_digest == bound_manifest_raw.expected_inventory_digest,
			"immutable source snapshot did not reconcile"
	end,
	function(manifest, manifest_id, source_revision, expected_count, observed_count, expected_digest, observed_digest)
		terminal_verification_calls += 1
		return manifest.manifest_id == manifest_id
			and manifest.source_revision == source_revision
			and expected_count == 3
			and observed_count == 3
			and expected_digest == bound_manifest_raw.expected_inventory_digest
			and observed_digest == bound_manifest_raw.expected_inventory_digest,
			"terminal inventory evidence did not match the immutable manifest"
	end
)
binding_source_verified = bound_runner_config ~= nil
source_manifest_error = binding_error
expect(binding_source_verified, source_manifest_error or "purchase manifest did not bind to the migration runner")
expect(bound_manifest.manifest_id == bound_manifest_raw.manifest_id
	and bound_runner_config.source_revision == bound_manifest_raw.source_revision
	and bound_runner_config.inventory_manifest_id == bound_manifest_raw.manifest_id
	and bound_runner_config.expected_purchase_count == 3
	and bound_runner_config.expected_inventory_digest == bound_manifest_raw.expected_inventory_digest,
	"bound runner config did not derive immutable inventory values from the reviewed manifest")
expect(source_verification_calls == 1, "immutable source verifier did not run exactly once before migration")

local unbound_config = {
	job_id = "purchase-unbound",
	source = source_reader,
	processor = migration_processor,
	checkpoint_store = migration_checkpoint_store,
	checkpoint_key = "purchase-migration:unbound",
	source_revision = "untrusted-override",
}
local unbound_verifier_calls = 0
local unbound_result = PurchaseManifest.bind_runner_config(
	bound_manifest_raw,
	unbound_config,
	function()
		unbound_verifier_calls += 1
		return true
	end,
	function() return true end
)
expect(unbound_result == nil and unbound_verifier_calls == 0,
	"caller could override manifest-bound source revision before source verification")

local bound_runner = MigrationRunner.new(bound_runner_config)
local bound_first_page = bound_runner:RunBatchAsync(1)
expect(bound_first_page.code == "incomplete" and bound_first_page.done == false
	and bound_first_page.cursor == "bound-page-2",
	"first bound purchase page did not persist a resumable cursor")
expect(migration_processor.calls == 1 and bound_first_page.purchases_processed == 1,
	"first bound purchase page did not reconcile its import counters")
local bound_terminal_page = bound_runner:RunBatchAsync(1)
expect(bound_terminal_page.code == "completed" and bound_terminal_page.done == true
	and bound_terminal_page.cursor == nil and bound_terminal_page.inventory_verified == true,
	bound_terminal_page.message or "manifest-bound purchase migration did not complete")
expect(bound_terminal_page.purchases_processed == 3 and bound_terminal_page.observed_inventory_digest == bound_manifest_raw.expected_inventory_digest,
	"completed bound purchase migration does not match manifest count/digest")
expect(migration_processor.calls == 2 and #migration_processor.imported_ids == 3,
	"manifest-bound purchase migration did not import exactly the declared rows")
expect(terminal_verification_calls == 1, "terminal verifier did not run exactly once for the terminal page")

local bound_checkpoint = migration_checkpoint_store.value
local bound_completion_evidence = {
	manifest_id = bound_manifest.manifest_id,
	source_revision = bound_manifest.source_revision,
	observed_purchase_count = 3,
	observed_inventory_digest = bound_manifest.expected_inventory_digest,
	checkpoint_revision = bound_checkpoint.revision,
	conflicts_reconciled = true,
	conflict_reconciliation_evidence_ref = "evidence:bound-conflicts-reconciled",
	live_acceptance_complete = true,
	live_acceptance_evidence_ref = "evidence:bound-live-acceptance",
}
local bound_completion, bound_completion_error = PurchaseManifest.verify_completion(
	bound_manifest_raw,
	bound_checkpoint,
	bound_completion_evidence,
	function(manifest, checkpoint, completion)
		return manifest.manifest_id == checkpoint.inventory_manifest_id
			and checkpoint.done == true
			and checkpoint.revision == completion.checkpoint_revision
			and checkpoint.purchases_processed == manifest.expected_purchase_count
			and checkpoint.inventory_verified == true
	end
)
expect(bound_completion ~= nil,
	bound_completion_error or "durable purchase checkpoint was not accepted by the final completion verifier")

local rejected_checkpoint_store = { value = nil }
function rejected_checkpoint_store:GetAsyncFresh(key)
	return clone(self.value), nil
end
function rejected_checkpoint_store:UpdateAsync(key, transform)
	local changed = transform(clone(self.value))
	if changed ~= nil then self.value = clone(changed) end
	return clone(self.value), nil
end
local rejected_processor = { calls = 0 }
function rejected_processor:BackfillExternalAuthorityAsync(items, maximum)
	self.calls += 1
	return {
		code = "complete",
		processed_count = #items,
		backfilled_count = #items,
		duplicate_count = 0,
		failed_index = nil,
		message = nil,
	}
end
local rejected_config, rejected_manifest, rejected_binding_error = PurchaseManifest.bind_runner_config(
	bound_manifest_raw,
	{
		job_id = "purchase-bound-rejected-r3",
		source = source_reader,
		processor = rejected_processor,
		checkpoint_store = rejected_checkpoint_store,
		checkpoint_key = "purchase-migration:reject-r3",
		page_size = 2,
	},
	function() return true end,
	function() return false, "independent terminal evidence was rejected" end
)
expect(rejected_config ~= nil and rejected_manifest ~= nil and rejected_binding_error == nil,
	"valid purchase manifest could not prepare a terminal-rejection test")
local rejected_runner = MigrationRunner.new(rejected_config)
local rejected_first = rejected_runner:RunBatchAsync(1)
expect(rejected_first.code == "incomplete", "terminal rejection fixture did not persist its first page")
local rejected_terminal = rejected_runner:RunBatchAsync(1)
expect(rejected_terminal.code == "incomplete_inventory" and rejected_terminal.done == false,
	"purchase migration advanced terminal checkpoint after its independent verifier rejected")
expect(rejected_processor.calls == 1 and rejected_checkpoint_store.value.revision == 1
	and rejected_checkpoint_store.value.cursor == "bound-page-2",
	"rejected terminal inventory caused imports or cursor advancement beyond the last proven checkpoint")

local purchase_manifest = valid_purchase_manifest()
local purchase_manifest_normalized, purchase_manifest_error = PurchaseManifest.validate(purchase_manifest)
expect(purchase_manifest_normalized ~= nil, purchase_manifest_error or "valid purchase inventory manifest was rejected")
expect(table.isfrozen(purchase_manifest_normalized)
	and table.isfrozen(purchase_manifest_normalized.source_systems)
	and table.isfrozen(purchase_manifest_normalized.legacy_receipt_paths),
	"purchase inventory manifest was not deeply frozen")

local import_manifest, import_manifest_error = PurchaseManifest.verify_import_source(
	purchase_manifest,
	function(manifest)
		return manifest.manifest_id == purchase_manifest.manifest_id
			and manifest.source_snapshot_id == purchase_manifest.source_snapshot_id
	end
)
expect(import_manifest ~= nil, import_manifest_error or "independently verified purchase source could not be accepted")

local unverified_import = PurchaseManifest.verify_import_source(purchase_manifest, function()
	return false, "source snapshot did not reconcile"
end)
expect(unverified_import == nil, "purchase import accepted a rejected immutable-source verifier")

local missing_legacy_inventory = valid_purchase_manifest()
missing_legacy_inventory.legacy_receipt_paths = {}
expect(PurchaseManifest.validate(missing_legacy_inventory) == nil,
	"purchase inventory omitted the explicit legacy receipt-path inventory")

local incomplete_accounts = valid_purchase_manifest()
incomplete_accounts.archived_accounts_included = false
expect(PurchaseManifest.validate(incomplete_accounts) == nil,
	"purchase inventory omitted archived accounts")

local unsupported_order = valid_purchase_manifest()
unsupported_order.row_order = "page_order_without_stable_sort"
expect(PurchaseManifest.validate(unsupported_order) == nil,
	"purchase inventory accepted an unstable order for its rolling digest")

local source_checkpoint = {
	version = 3,
	digest_algorithm = "sha256-chain-v1",
	job_id = "purchase-manifest-checkpoint-test",
	done = true,
	cursor = nil,
	revision = 3,
	source_revision = purchase_manifest.source_revision,
	inventory_manifest_id = purchase_manifest.manifest_id,
	purchases_processed = purchase_manifest.expected_purchase_count,
	expected_purchase_count = purchase_manifest.expected_purchase_count,
	inventory_digest = purchase_manifest.expected_inventory_digest,
	expected_inventory_digest = purchase_manifest.expected_inventory_digest,
	inventory_verified = true,
}
local source_completion = {
	manifest_id = purchase_manifest.manifest_id,
	source_revision = purchase_manifest.source_revision,
	observed_purchase_count = purchase_manifest.expected_purchase_count,
	observed_inventory_digest = purchase_manifest.expected_inventory_digest,
	checkpoint_revision = 3,
	conflicts_reconciled = true,
	conflict_reconciliation_evidence_ref = "evidence:reconciled-conflicts",
	live_acceptance_complete = true,
	live_acceptance_evidence_ref = "evidence:roblox-purchase-acceptance",
}
local activated_purchase_manifest, activation_manifest_error = PurchaseManifest.verify_completion(
	purchase_manifest,
	source_checkpoint,
	source_completion,
	function(manifest, checkpoint, completion)
		return manifest.manifest_id == checkpoint.inventory_manifest_id
			and checkpoint.revision == completion.checkpoint_revision
	end
)
expect(activated_purchase_manifest ~= nil,
	activation_manifest_error or "verified purchase completion could not be activated")
expect(not table.isfrozen(source_completion),
	"purchase verifier validation froze the caller-owned completion table")

local terminal_cursor_checkpoint = clone(source_checkpoint)
terminal_cursor_checkpoint.cursor = "not-terminal"
expect(PurchaseManifest.verify_completion(
	purchase_manifest,
	terminal_cursor_checkpoint,
	source_completion,
	function() return true end
) == nil, "purchase migration activation accepted a completed checkpoint with a cursor")

local wrong_checkpoint_revision = clone(source_checkpoint)
wrong_checkpoint_revision.revision = 4
expect(PurchaseManifest.verify_completion(
	purchase_manifest,
	wrong_checkpoint_revision,
	source_completion,
	function() return true end
) == nil, "purchase completion ignored a different durable checkpoint revision")

local wrong_completion_count = clone(source_completion)
wrong_completion_count.observed_purchase_count -= 1
expect(PurchaseManifest.verify_completion(
	purchase_manifest,
	source_checkpoint,
	wrong_completion_count,
	function() return true end
) == nil, "purchase completion accepted a count mismatch")

local no_live_acceptance = clone(source_completion)
no_live_acceptance.live_acceptance_complete = false
no_live_acceptance.live_acceptance_evidence_ref = nil
expect(PurchaseManifest.verify_completion(
	purchase_manifest,
	source_checkpoint,
	no_live_acceptance,
	function() return true end
) == nil, "purchase migration activated without live fulfillment acceptance")

local function make_purchase_authority()
	local authority = { rows = {}, lose_next_commit = false }
	function authority:ClaimAsync(purchase_id, player_id, product_id)
		local existing = self.rows[purchase_id]
		if existing ~= nil then
			if existing.PlayerId ~= player_id or existing.ProductId ~= product_id then
				return {
					PurchaseId = purchase_id,
					PlayerId = player_id,
					ProductId = product_id,
					Status = "conflict",
				}, nil
			end
			return clone(existing), nil
		end
		local row = {
			PurchaseId = purchase_id,
			PlayerId = player_id,
			ProductId = product_id,
			Status = "claimed",
		}
		self.rows[purchase_id] = row
		return clone(row), nil
	end
	function authority:CommitAsync(purchase_id, player_id, product_id, outcome)
		local existing = self.rows[purchase_id]
		if existing == nil then return nil, "not_found" end
		if existing.PlayerId ~= player_id or existing.ProductId ~= product_id then
			return {
				PurchaseId = purchase_id,
				PlayerId = player_id,
				ProductId = product_id,
				Status = "conflict",
			}, nil
		end
		if existing.Status == "claimed" then
			existing.Status = "committed"
			existing.Outcome = outcome
		end
		if self.lose_next_commit then
			self.lose_next_commit = false
			return nil, "injected response loss after purchase commit"
		end
		return clone(existing), nil
	end
	function authority:GetStatusAsync(purchase_id, player_id, product_id)
		local existing = self.rows[purchase_id]
		if existing == nil then return nil, "not_found" end
		if existing.PlayerId ~= player_id or existing.ProductId ~= product_id then
			return {
				PurchaseId = purchase_id,
				PlayerId = player_id,
				ProductId = product_id,
				Status = "conflict",
			}, nil
		end
		return clone(existing), nil
	end
	return authority
end

local function make_coordinator(purchase_authority, entitlement_store, grant_result, activation_ready)
	local entitlement_authority = Authority.new({
		key_prefix = "ent:",
		store_adapter = entitlement_store,
		now_unix = function() return now end,
	})
	local grant_calls = {}
	local coordinator = EntitlementCoordinator.new({
		purchase_authority = purchase_authority,
		entitlement_authority = entitlement_authority,
		entitlement_by_product_id = {
			[501] = "VIP_LIFETIME",
		},
		grant_profile_once = function(receipt, operation_id)
			expect(operation_id == "purchase:" .. receipt.PurchaseId,
				"profile grant was not bound to the stable PurchaseId")
			grant_calls[receipt.PurchaseId] = (grant_calls[receipt.PurchaseId] or 0) + 1
			local status = grant_result[receipt.PurchaseId] or "granted"
			if type(status) == "function" then return status(receipt, operation_id) end
			return status, if status == "unknown" then "injected grant uncertainty" else nil
		end,
		verify_activation = activation_ready or function() return true end,
	})
	return coordinator, entitlement_authority, grant_calls
end

local receipt_auth = make_purchase_authority()
local receipt_store = make_store()
local receipt_grants = {}
local receipt_coordinator, receipt_entitlements, receipt_grant_calls = make_coordinator(
	receipt_auth, receipt_store, receipt_grants
)
local receipt_one = { PurchaseId = "purchase-lifetime-1", PlayerId = 1101, ProductId = 501 }
local receipt_one_decision = receipt_coordinator:Process(receipt_one)
expect(receipt_one_decision.action == "acknowledge",
	receipt_one_decision.message or "valid lifetime purchase was not durably acknowledged")
expect(receipt_auth.rows[receipt_one.PurchaseId].Status == "committed"
	and receipt_auth.rows[receipt_one.PurchaseId].Outcome == "granted",
	"purchase authority was not committed after profile grant and entitlement")
expect(receipt_grant_calls[receipt_one.PurchaseId] == 1, "profile grant callback was not run exactly once in this attempt")
local found_owned_entitlement = false
for _, row in pairs(receipt_store.rows) do
	if row.entitlement_id == "VIP_LIFETIME" and row.player_id == 1101 then
		found_owned_entitlement = row.status == "owned" and row.purchase_id == receipt_one.PurchaseId
	end
end
expect(found_owned_entitlement, "lifetime entitlement was not marked owned for the exact receipt")

local replay_decision = receipt_coordinator:Process(receipt_one)
expect(replay_decision.action == "acknowledge", "replayed lifetime purchase was not acknowledged")
expect(receipt_grant_calls[receipt_one.PurchaseId] == 1, "committed purchase replay called profile grant again")

local second_lifetime_receipt = {
	PurchaseId = "purchase-lifetime-2",
	PlayerId = 1101,
	ProductId = 501,
}
local second_lifetime_decision = receipt_coordinator:Process(second_lifetime_receipt)
expect(second_lifetime_decision.action == "acknowledge"
	and second_lifetime_decision.status == "lifetime_entitlement_already_owned",
	"separate purchase for an already-owned lifetime entitlement was not safely deduplicated")
expect(receipt_auth.rows[second_lifetime_receipt.PurchaseId].Status == "committed"
	and receipt_auth.rows[second_lifetime_receipt.PurchaseId].Outcome == "duplicate",
	"already-owned lifetime receipt was acknowledged without a durable duplicate authority record")
expect(receipt_grant_calls[second_lifetime_receipt.PurchaseId] == nil,
	"duplicate lifetime purchase incorrectly repeated its profile grant")

local reused_receipt_decision = receipt_coordinator:Process({
	PurchaseId = receipt_one.PurchaseId,
	PlayerId = 9999,
	ProductId = 501,
})
expect(reused_receipt_decision.action == "defer",
	"cross-user PurchaseId reuse was acknowledged by the lifetime coordinator")

local gated_auth = make_purchase_authority()
local gated_store = make_store()
local gated_coordinator = make_coordinator(
	gated_auth,
	gated_store,
	{},
	function() return false, "manifest migration not accepted" end
)
local gated_decision = gated_coordinator:Process({
	PurchaseId = "purchase-gated",
	PlayerId = 1102,
	ProductId = 501,
})
expect(gated_decision.action == "defer" and next(gated_auth.rows) == nil and next(gated_store.rows) == nil,
	"disabled purchase activation gate allowed receipt side effects")

local unmapped_decision = receipt_coordinator:Process({
	PurchaseId = "purchase-unmapped",
	PlayerId = 1101,
	ProductId = 999,
})
expect(unmapped_decision.action == "not_applicable",
	"lifetime coordinator intercepted a product without an entitlement mapping")

local invalid_coordinator_config_ok = pcall(function()
	EntitlementCoordinator.new({
		purchase_authority = make_purchase_authority(),
		entitlement_authority = receipt_entitlements,
		entitlement_by_product_id = { [501] = "VIP_LIFETIME" },
		grant_profile_once = function() return "granted" end,
		verify_activation = function() return true end,
		product_entitlement_by_id = { [501] = "VIP_LIFETIME" },
	})
end)
expect(not invalid_coordinator_config_ok,
	"coordinator silently accepted an unsupported/typoed option")

local uncertain_auth = make_purchase_authority()
local uncertain_store = make_store()
local uncertain_grants = { ["purchase-grant-retry"] = "unknown" }
local uncertain_coordinator, _, uncertain_calls = make_coordinator(
	uncertain_auth, uncertain_store, uncertain_grants
)
local uncertain_receipt = { PurchaseId = "purchase-grant-retry", PlayerId = 1201, ProductId = 501 }
local first_uncertain_decision = uncertain_coordinator:Process(uncertain_receipt)
expect(first_uncertain_decision.action == "defer"
	and uncertain_auth.rows[uncertain_receipt.PurchaseId].Status == "claimed",
	"uncertain profile grant was prematurely acknowledged or globally committed")
local pending_owner = false
for _, row in pairs(uncertain_store.rows) do
	if row.entitlement_id == "VIP_LIFETIME" and row.player_id == 1201 then
		pending_owner = row.status == "pending" and row.purchase_id == uncertain_receipt.PurchaseId
	end
end
expect(pending_owner, "uncertain grant did not retain the exact recoverable entitlement claim")
uncertain_grants[uncertain_receipt.PurchaseId] = "granted"
local retry_grant_decision = uncertain_coordinator:Process(uncertain_receipt)
expect(retry_grant_decision.action == "acknowledge",
	retry_grant_decision.message or "receipt did not recover after the profile grant became confirmable")
expect(uncertain_calls[uncertain_receipt.PurchaseId] == 2,
	"unknown profile grant was not retried under the same idempotency key")

local competing_auth = make_purchase_authority()
local competing_store = make_store()
local competing_grants = { ["purchase-owner-pending"] = "unknown" }
local competing_coordinator = make_coordinator(competing_auth, competing_store, competing_grants)
local pending_receipt = { PurchaseId = "purchase-owner-pending", PlayerId = 1301, ProductId = 501 }
expect(competing_coordinator:Process(pending_receipt).action == "defer",
	"fixture did not create a pending lifetime entitlement")
local competing_receipt = { PurchaseId = "purchase-owner-next", PlayerId = 1301, ProductId = 501 }
local competing_decision = competing_coordinator:Process(competing_receipt)
expect(competing_decision.action == "defer"
	and competing_auth.rows[competing_receipt.PurchaseId].Status == "claimed"
	and competing_grants[competing_receipt.PurchaseId] == nil,
	"a competing receipt bypassed an unresolved lifetime entitlement reservation")

local loss_auth = make_purchase_authority()
local loss_store = make_store()
local loss_grants = {
	["purchase-two-commits"] = function()
		loss_store.lose_next_response = true
		loss_auth.lose_next_commit = true
		return "granted"
	end,
}
local loss_coordinator = make_coordinator(loss_auth, loss_store, loss_grants)
local loss_decision = loss_coordinator:Process({
	PurchaseId = "purchase-two-commits",
	PlayerId = 1401,
	ProductId = 501,
})
expect(loss_decision.action == "acknowledge",
	loss_decision.message or "cross-key entitlement and purchase commit response loss was not reconciled")
expect(loss_auth.rows["purchase-two-commits"].Status == "committed",
	"purchase authority did not reconcile a response lost after terminal commit")


end

local budget_calls = {}
local budget_store = make_store()
local budget_limited_authority = Authority.new({
	key_prefix = "ent:",
	store_adapter = budget_store,
	now_unix = function() return now end,
	get_request_budget = function(operation)
		budget_calls[#budget_calls + 1] = operation
		return 0
	end,
})
local budget_limited_result = budget_limited_authority:ReserveAsync(
	"BUDGETED", 1501, 501, "purchase-budgeted"
)
expect(budget_limited_result.code == "unknown" and #budget_calls >= 2,
	"exhausted request budget did not block entitlement mutation and reconciliation reads")
expect(budget_calls[1] == "update" and budget_calls[2] == "read",
	"entitlement request budget callback was not called with shared governor operation names")
expect(next(budget_store.rows) == nil, "budget exhaustion still mutated durable entitlement state")

local governed_store = make_store()
local governed_calls = {}
local governed_authority = Authority.new({
	key_prefix = "ent:",
	store_adapter = governed_store,
	now_unix = function() return now end,
	get_request_budget = function(operation)
		governed_calls[#governed_calls + 1] = "budget:" .. operation
		return 2
	end,
	request_runner = function(operation, call)
		governed_calls[#governed_calls + 1] = "run:" .. operation
		return call()
	end,
})
local governed_result = governed_authority:ReserveAsync("GOVERNED", 1502, 501, "purchase-governed")
expect(governed_result.code == "claimed", "shared-governor entitlement write failed despite available budget")
expect(table.find(governed_calls, "budget:update") ~= nil
	and table.find(governed_calls, "run:update") ~= nil,
	"entitlement request did not flow through shared budget/governor hooks")

local mutation_isolation_adapter = make_atomic_adapter({
	is_eligible = function(value)
		value.dependencies_clear = false
		value.payload.coins = -1
		return value.eligible == true
	end,
	dependencies_clear = function(value)
		return value.dependencies_clear == true and value.payload.coins == 100
	end,
})
local mutation_isolation_store = make_atomic_store(make_atomic_profile(4, "job-atomic-1", true, true))
local mutation_isolation_action = mutation_isolation_adapter:DeleteIfGeneration(
	mutation_isolation_store, atomic_item, 4, "job-atomic-1"
)
expect(mutation_isolation_action == "deleted" and mutation_isolation_store.row.payload.coins == 100,
	"one maintenance policy callback could mutate the snapshot seen by later checks or tombstone creation")

local exhausted_generation_store = make_atomic_store(make_atomic_profile(9007199254740991, "job-atomic-1", true, true))
local exhausted_generation_action = atomic_adapter:DeleteIfGeneration(
	exhausted_generation_store,
	atomic_item,
	9007199254740991,
	"job-atomic-1"
)
expect(exhausted_generation_action == "skipped" and exhausted_generation_store.row.tombstone ~= true,
	"maintenance tombstone attempted to increment a generation beyond the exact integer range")

local yielding_policy_adapter = make_atomic_adapter({
	is_eligible = function()
		coroutine.yield()
		return true
	end,
})
local yielding_policy_store = make_atomic_store(make_atomic_profile(4, "job-atomic-1", true, true))
local yielding_policy_action = yielding_policy_adapter:DeleteIfGeneration(
	yielding_policy_store, atomic_item, 4, "job-atomic-1"
)
expect(yielding_policy_action == "unknown" and yielding_policy_store.row.tombstone ~= true,
	"yielding maintenance policy callback led to deletion")

do
	local MaintenanceBinder = luau.load(fs.readFile("staging/pr56-blockers/RecordStoreMaintenanceManifestBinding.luau"), {
		debugName = "RecordStoreMaintenanceManifestBinding",
	})()

	local function maintenance_manifest()
		return {
			schema_version = 1,
			kind = "maintenance_job",
			manifest_id = "maintenance-inventory-2026-10-26",
			revision = "maintenance-review-r2",
			source_commit = string.rep("a", 40),
			job_id = "maintenance-job-r2",
			catalog_revision = "catalog-r2",
			review_status = "approved",
			reviewed_by = "independent-reviewer",
			reviewed_at_unix = now,
			inventory_evidence_ref = "evidence:maintenance-inventory",
			policy_review_evidence_ref = "evidence:maintenance-policy",
			fence_protocol_evidence_ref = "evidence:maintenance-writer-fence",
			checkpoint_protocol_evidence_ref = "evidence:maintenance-checkpoint",
			checkpoint_store_name = "MaintenanceCheckpoints",
			checkpoint_scope = "global",
			checkpoint_key = "maintenance-job-r2",
			families = {
				{
					name = "player-profiles",
					store_name = "Profiles",
					scope = "global",
					prefix = "Player_",
					generation_field = "fencing_generation",
					job_fence_field = "maintenance_fence_job_id",
					tombstone_field = "maintenance_tombstone",
					tombstone_job_field = "maintenance_tombstone_job_id",
					tombstone_source_generation_field = "maintenance_tombstone_source_generation",
					action = "tombstone",
					inventory_evidence_ref = "evidence:profiles-inventory",
					policy_evidence_ref = "evidence:profiles-policy",
				},
			},
		}
	end

	local function maintenance_runtime(overrides)
		local policy = {
			family_name = "player-profiles",
			is_eligible = function(value)
				value.payload.mutated_by_policy = true
				return value.eligible == true
			end,
			dependencies_clear = function(value)
				return value.payload.token == "keep" and value.dependencies_clear == true
			end,
		}
		local runtime = {
			maintenance = { NewCompactor = function() end },
			maintenance_runner = { new = function() end },
			policies = { policy },
			mode = "dry_run",
		}
		for key, value in pairs(overrides or {}) do runtime[key] = value end
		return runtime, policy
	end

	local maintenance_runtime_value, maintenance_policy = maintenance_runtime()
	local verifier_calls = 0
	local maintenance_config, maintenance_manifest_value, maintenance_bind_error = MaintenanceBinder.bind(
		maintenance_manifest(),
		maintenance_runtime_value,
		function(manifest, families)
			verifier_calls += 1
			return manifest.job_id == "maintenance-job-r2"
				and #families == 1
				and table.isfrozen(families)
				and table.isfrozen(families[1]),
				"maintenance attestation did not reconcile"
		end
	)
	expect(maintenance_config ~= nil,
		maintenance_bind_error or "reviewed maintenance manifest did not bind to adapter callbacks")
	expect(maintenance_manifest_value.manifest_id == "maintenance-inventory-2026-10-26"
		and maintenance_config.job_id == maintenance_manifest_value.job_id
		and maintenance_config.catalog_revision == maintenance_manifest_value.catalog_revision
		and maintenance_config.mode == "dry_run"
		and #maintenance_config.families == 1
		and verifier_calls == 1,
		"bound maintenance config did not inherit reviewed identity or remain dry-run by default")
	expect(table.isfrozen(maintenance_config) and table.isfrozen(maintenance_config.families),
		"bound maintenance configuration is mutable")

	local maintenance_family = maintenance_config.families[1]
	local maintenance_row = {
		fencing_generation = 4,
		maintenance_fence_job_id = "maintenance-job-r2",
		eligible = true,
		dependencies_clear = true,
		payload = { token = "keep" },
	}
	local inspection, inspection_error = maintenance_family.inspect(
		"Player_1001", maintenance_row, nil
	)
	expect(inspection ~= nil and inspection_error == nil
		and inspection.status == "success"
		and inspection.eligible == true and inspection.dependencies_clear == true
		and inspection.generation == 4,
		inspection_error or "maintenance family inspection did not confirm safe eligibility")
	expect(maintenance_row.payload.token == "keep"
		and maintenance_row.payload.mutated_by_policy == nil,
		"maintenance policy mutated the source record during inspection")
	expect(maintenance_family.can_delete(
		maintenance_row, nil, 4, "maintenance-job-r2"
	), "same-row generation/job-fence check refused an eligible record")

	local maintenance_tombstone = maintenance_family.make_tombstone(
		maintenance_row, nil, 4, "maintenance-job-r2"
	)
	expect(type(maintenance_tombstone) == "table"
		and maintenance_tombstone.fencing_generation == 5
		and maintenance_tombstone.maintenance_fence_job_id == "maintenance-job-r2"
		and maintenance_tombstone.maintenance_tombstone == true
		and maintenance_tombstone.maintenance_tombstone_job_id == "maintenance-job-r2"
		and maintenance_tombstone.maintenance_tombstone_source_generation == 4
		and maintenance_tombstone.payload.token == "keep",
		"maintenance tombstone did not advance generation while preserving the payload")
	expect(maintenance_family.is_tombstone(maintenance_tombstone, 4, "maintenance-job-r2"),
		"maintenance tombstone identity did not validate")
	expect(not maintenance_family.can_delete(
		maintenance_tombstone, nil, 5, "maintenance-job-r2"
	), "already tombstoned row could be tombstoned again")

	local stale_record = clone(maintenance_row)
	expect(not maintenance_family.can_delete(stale_record, nil, 3, "maintenance-job-r2"),
		"stale expected generation bypassed the same-mutation generation fence")
	local foreign_fence_record = clone(maintenance_row)
	foreign_fence_record.maintenance_fence_job_id = "other-job"
	expect(not maintenance_family.can_delete(foreign_fence_record, nil, 4, "maintenance-job-r2"),
		"record without this job's same-key fence was eligible")
	local ineligible_record = clone(maintenance_row)
	ineligible_record.eligible = false
	expect(not maintenance_family.can_delete(ineligible_record, nil, 4, "maintenance-job-r2"),
		"application eligibility callback was bypassed")
	local dependent_record = clone(maintenance_row)
	dependent_record.dependencies_clear = false
	expect(not maintenance_family.can_delete(dependent_record, nil, 4, "maintenance-job-r2"),
		"dependency callback was bypassed")

	local rejected_attestation_calls = 0
	local rejected_config = MaintenanceBinder.bind(
		maintenance_manifest(),
		maintenance_runtime_value,
		function()
			rejected_attestation_calls += 1
			return false, "fence protocol did not reconcile"
		end
	)
	expect(rejected_config == nil and rejected_attestation_calls == 1,
		"maintenance manifest was accepted after independent attestation rejection")

	local missing_policy_called = false
	local missing_policy = MaintenanceBinder.bind(
		maintenance_manifest(),
		maintenance_runtime({ policies = {} }),
		function()
			missing_policy_called = true
			return true
		end
	)
	expect(missing_policy == nil and not missing_policy_called,
		"maintenance manifest reached attestation with a missing family policy")

	local overlap_manifest = maintenance_manifest()
	overlap_manifest.families[2] = clone(overlap_manifest.families[1])
	overlap_manifest.families[2].name = "overlapping-family"
	overlap_manifest.families[2].prefix = "Player_Archive_"
	overlap_manifest.families[2].inventory_evidence_ref = "evidence:second-inventory"
	overlap_manifest.families[2].policy_evidence_ref = "evidence:second-policy"
	local overlap_verified = false
	expect(MaintenanceBinder.bind(
		overlap_manifest,
		maintenance_runtime({ policies = {
			maintenance_policy,
			{
				family_name = "overlapping-family",
				is_eligible = function() return true end,
				dependencies_clear = function() return true end,
			},
		} }),
		function()
			overlap_verified = true
			return true
		end
	) == nil and not overlap_verified,
	"overlapping same-store family prefixes reached independent attestation")

	local same_checkpoint_store = maintenance_manifest()
	same_checkpoint_store.checkpoint_store_name = "Profiles"
	same_checkpoint_store.checkpoint_scope = "global"
	expect(MaintenanceBinder.bind(
		same_checkpoint_store, maintenance_runtime(), function() return true end
	) == nil, "checkpoint store sharing a target store/scope was accepted")

	local unsupported_action = maintenance_manifest()
	unsupported_action.families[1].action = "physical_delete"
	expect(MaintenanceBinder.bind(
		unsupported_action, maintenance_runtime(), function() return true end
	) == nil, "physical deletion was accepted instead of durable tombstoning")

	local execute_without_fence = MaintenanceBinder.bind(
		maintenance_manifest(),
		maintenance_runtime({ mode = "execute" }),
		function() return true end
	)
	expect(execute_without_fence == nil,
		"execute mode was enabled without authorization and durable fence preflight")

	local yielding_runtime = maintenance_runtime({
		policies = {{
			family_name = "player-profiles",
			is_eligible = function()
				coroutine.yield()
				return true
			end,
			dependencies_clear = function() return true end,
		}},
	})
	local yielding_config = MaintenanceBinder.bind(
		maintenance_manifest(), yielding_runtime, function() return true end
	)
	expect(yielding_config ~= nil, "valid maintenance policy callback could not be bound")
	local yielding_inspection = yielding_config.families[1].inspect(
		"Player_1001", maintenance_row, nil
	)
	expect(yielding_inspection == nil,
		"yielding maintenance policy callback produced an actionable inspection")

	print("PR56 maintenance manifest binding regressions passed")
end

print("PR56 staged blocker regression checks passed")
