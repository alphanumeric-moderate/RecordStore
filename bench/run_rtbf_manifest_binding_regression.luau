--!nocheck
local Shim = require("./RobloxShim")
local RecordStore = Shim.load()
local initializer = Shim.environment.game:GetService("ServerScriptService"):WaitForChild("PlayerDataInitializer")
local RecordStoreV2Factory = Shim.environment.require(initializer:WaitForChild("RecordStoreV2"))
local Manifest = Shim.environment.require(initializer:WaitForChild("RecordStoreApplicationInventory"))
local ErasureBinding = Shim.environment.require(initializer:WaitForChild("PlayerDataErasureManifestBinding"))

local function expect(value, message)
	if not value then error(message, 2) end
end

local function clone(value, seen)
	if type(value) ~= "table" then return value end
	local memo = seen or {}
	if memo[value] ~= nil then return memo[value] end
	local copy_value = {}
	memo[value] = copy_value
	for key, child in pairs(value) do copy_value[clone(key, memo)] = clone(child, memo) end
	return copy_value
end

local function manifest()
	return {
		schema_version = 1,
		kind = "rtbf",
		manifest_id = "rtbf-inventory-regression-r1",
		revision = "inventory-review-r1",
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

local function external_manifest()
	local value = manifest()
	value.families[#value.families + 1] = {
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
	value.writers[#value.writers + 1] = {
		id = "purchase-authority-writer",
		source_path = "src/PlayerDataInitializer/PurchaseDataStoreAuthority.luau",
		family_ids = { "purchase-authority" },
		fence_mode = "same_key_update_async",
		fence_evidence_ref = "evidence:purchase-authority-writer-fence",
	}
	return value
end

local function runtime(rendered_count)
	return {
		verify_templates = function(user_id, rendered)
			return user_id > 0 and type(rendered) == "table" and #rendered == rendered_count
		end,
	}
end

local function adapter(family_id, action)
	return {
		family_id = family_id,
		action = action or "tombstone",
		inventory = function() return {}, true end,
		fence_user = function() return true end,
		dependencies_clear = function() return true end,
		redact_or_delete_if_generation = function() return "deleted" end,
	}
end

local raw = manifest()
local normalized, validation_error = Manifest.validate(raw)
expect(normalized ~= nil, validation_error or "valid reviewed RTBF manifest was rejected")
expect(table.isfrozen(normalized) and table.isfrozen(normalized.families)
	and table.isfrozen(normalized.families[1]) and table.isfrozen(normalized.writers[1])
	and table.isfrozen(normalized.families[1].writer_ids)
	and table.isfrozen(normalized.writers[1].family_ids),
	"normalized RTBF manifest and relationship arrays were not deeply frozen")
raw.families[1].key_template = "Changed_{user_id}"
raw.writers[1].family_ids[1] = "changed"
expect(normalized.families[1].key_template == "Player_{user_id}"
	and normalized.writers[1].family_ids[1] == "player-profile",
	"normalized manifest retained caller-owned nested arrays")

local activated, activation_error = Manifest.verify_for_activation(manifest(), function(value)
	return value.manifest_id == "rtbf-inventory-regression-r1" and value.revision == "inventory-review-r1"
end)
expect(activated ~= nil, activation_error or "independent activation verifier did not accept reviewed manifest")

local no_live = manifest()
no_live.live_acceptance_complete = false
no_live.live_acceptance_evidence_ref = nil
expect(Manifest.validate(no_live) ~= nil, "staged manifest without live acceptance should remain structurally valid")
expect(Manifest.verify_for_activation(no_live, function() return true end) == nil,
	"activation succeeded without explicit live Roblox acceptance evidence")
expect(Manifest.verify_for_activation(manifest(), function() return false, "evidence mismatch" end) == nil,
	"activation ignored independent attestation rejection")

local missing_family_writer = manifest()
missing_family_writer.writers[1].family_ids = {}
expect(Manifest.validate(missing_family_writer) == nil,
	"family/writer reciprocal coverage mismatch was accepted")
local missing_writer = manifest()
missing_writer.writers = {}
expect(Manifest.validate(missing_writer) == nil, "family with no inventoried writer was accepted")
local bad_template = manifest()
bad_template.families[1].key_template = "Player_{user_id}_{user_id}"
expect(Manifest.validate(bad_template) == nil, "duplicate UserId placeholders were accepted")
local overlong_template = manifest()
overlong_template.families[1].key_template = string.rep("x", 42) .. "{user_id}"
expect(Manifest.validate(overlong_template) == nil, "expanded Roblox key over 50 bytes was accepted")
local aliased_fields = manifest()
aliased_fields.families[1].fence_field = aliased_fields.families[1].generation_field
expect(Manifest.validate(aliased_fields) == nil, "generation and erasure fence fields were allowed to alias")
local unsupported_field = manifest()
unsupported_field.unreviewed_override = true
expect(Manifest.validate(unsupported_field) == nil, "unrecognized manifest field was accepted")

local verifier_calls = 0
local bound, bound_manifest, bind_error = ErasureBinding.bind(
	Manifest,
	manifest(),
	runtime(1),
	{},
	function(value, adapters, options)
		verifier_calls += 1
		return value.manifest_id == "rtbf-inventory-regression-r1"
			and #adapters == 0 and table.isfrozen(adapters)
			and options.verify_templates ~= nil,
			"RTBF activation attestation failed"
	end
)
expect(bound ~= nil and bound_manifest ~= nil, bind_error or "reviewed profile manifest did not bind")
expect(bound.profile_store_name == "PlayerData_Test1"
	and bound.profile_scope == "global"
	and bound.key_prefix == "Player_"
	and bound.profile_family_verified == true
	and bound.writer_inventory_verified == true
	and bound.application_inventory_manifest_id == bound_manifest.manifest_id
	and #bound.additional_families == 0 and table.isfrozen(bound),
	"erasure config did not derive the exact profile identity and reviewed attestations")
expect(verifier_calls == 1, "RTBF verifier did not run exactly once")

local dynamic = external_manifest()
local dynamic_config, dynamic_activated, dynamic_error = ErasureBinding.bind(
	Manifest,
	dynamic,
	runtime(2),
	{ adapter("purchase-authority") },
	function(value, adapters)
		return value.families[2].locator_mode == "external_inventory"
			and #adapters == 1 and table.isfrozen(adapters),
			"external inventory verifier rejected the explicit source binding"
	end
)
expect(dynamic_config ~= nil and dynamic_activated ~= nil,
	dynamic_error or "reviewed external inventory family did not bind")
local external_template = dynamic_config.additional_families[1].templates[1]
expect(external_template.locator_mode == "external_inventory"
	and external_template.inventory_source_ref == "evidence:purchase-user-index"
	and external_template.key == "__rtbf_external__{user_id}"
	and dynamic_config.additional_families[1].templates_verified == true,
	"dynamic inventory binding lost its explicit mode or source evidence")

local sidecar = manifest()
sidecar.families[2] = {
	id = "player-sidecar",
	store_name = "PlayerSidecars",
	scope = "global",
	locator_mode = "user_id_template",
	key_template = "Sidecar_{user_id}",
	generation_field = "generation",
	fence_field = "erasure_fence",
	action = "redact",
	writer_ids = { "sidecar-writer" },
	evidence_ref = "evidence:sidecar-family",
}
sidecar.writers[2] = {
	id = "sidecar-writer",
	source_path = "src/PlayerSidecar.luau",
	family_ids = { "player-sidecar" },
	fence_mode = "same_key_update_async",
	fence_evidence_ref = "evidence:sidecar-writer-fence",
}
local sidecar_config = ErasureBinding.bind(
	Manifest, sidecar, runtime(2), { adapter("player-sidecar", "redact") },
	function(value, adapters)
		return value.families[2].id == "player-sidecar" and #adapters == 1
	end
)
expect(sidecar_config ~= nil and #sidecar_config.additional_families == 1
	and sidecar_config.additional_families[1].templates[1].key == "Sidecar_{user_id}"
	and sidecar_config.additional_families[1].templates_verified == true
	and table.isfrozen(sidecar_config.additional_families[1].templates[1]),
	"reviewed static sidecar family did not bind an immutable exact template")

local missing_adapter_verifier_called = false
local missing_adapter = ErasureBinding.bind(
	Manifest, external_manifest(), runtime(2), {},
	function()
		missing_adapter_verifier_called = true
		return true
	end
)
expect(missing_adapter == nil and not missing_adapter_verifier_called,
	"unbound user-associated family reached the independent activation verifier")

local mismatched_action = ErasureBinding.bind(
	Manifest, sidecar, runtime(2), { adapter("player-sidecar", "tombstone") },
	function() return true end
)
expect(mismatched_action == nil, "family adapter action mismatch was accepted")

local identity_override_called = false
local identity_override = ErasureBinding.bind(
	Manifest,
	manifest(),
	{ profile_store_name = "UnreviewedStore", verify_templates = runtime(1).verify_templates },
	{},
	function()
		identity_override_called = true
		return true
	end
)
expect(identity_override == nil and not identity_override_called,
	"runtime option bypassed the manifest's reviewed profile identity")

local retention_manifest = external_manifest()
retention_manifest.families[2].action = "retain_fence"
expect(Manifest.validate(retention_manifest) ~= nil,
	"retain-fence inventory could not be staged for review")
local retention_config, retention_activated, retention_error = ErasureBinding.bind(
	Manifest, retention_manifest, runtime(2), { adapter("purchase-authority", "retain_fence") },
	function(value, adapters)
		return value.families[2].action == "retain_fence"
			and #adapters == 1 and adapters[1].action == "retain_fence",
			"retain-fence action was not preserved through RTBF binding"
	end
)
expect(retention_config ~= nil and retention_activated ~= nil,
	retention_error or "retain-fence action was not bound as an explicit application policy")
expect(retention_config.additional_families[1].action == "retain_fence"
	and retention_config.additional_families[1].locator_mode == "external_inventory",
	"bound retain-fence family lost its action or opaque-locator semantics")

local opaque_key = "purchase_authority_0123456789abcdef"
local row = {
	purchase_id = "historical-purchase-opaque-77",
	player_id = 77,
	product_id = 9001,
	fencing_generation = 4,
	status = "committed",
	outcome = "granted",
}
local manifest_store = { values = {} }
function manifest_store:GetAsyncFresh(key)
	return clone(self.values[key]), nil
end
function manifest_store:UpdateAsync(key, transform)
	local proposed = transform(clone(self.values[key]))
	if proposed ~= nil then self.values[key] = clone(proposed) end
	return clone(self.values[key]), nil
end

local external_family = {
	name = "purchase-authority",
	templates = {
		{
			name = "PurchaseAuthority",
			scope = "global",
			key = "__rtbf_external__{user_id}",
			locator_mode = "external_inventory",
			inventory_source_ref = "evidence:purchase-user-index",
		},
	},
	templates_verified = true,
	inventory = function(user_id, maximum)
		if user_id ~= 77 or maximum < 1 then return nil, "inventory identity or bound is invalid" end
		return {
			{
				name = "PurchaseAuthority",
				scope = "global",
				key = opaque_key,
				generation = row.fencing_generation,
			},
		}, true
	end,
	fence_user = function(user_id, erasure_id, planned_items)
		if user_id ~= 77 or erasure_id ~= "erase-purchase-user-77"
			or type(planned_items) ~= "table" or #planned_items ~= 1
			or planned_items[1].key ~= opaque_key
			or planned_items[1].generation ~= row.fencing_generation
			or row.player_id ~= user_id
		then
			return false, "opaque purchase inventory/fence identity mismatch"
		end
		if row.erasure_fence ~= nil and row.erasure_fence ~= erasure_id then
			return false, "another erasure owns the purchase authority fence"
		end
		row.erasure_fence = erasure_id
		return true
	end,
	dependencies_clear = function(item, user_id)
		return user_id == 77 and item.key == opaque_key and row.player_id == user_id
	end,
	redact_or_delete_if_generation = function(item, user_id, erasure_id)
		if item.key ~= opaque_key or user_id ~= 77 or row.player_id ~= user_id
			or item.generation ~= row.fencing_generation or row.erasure_fence ~= erasure_id
		then
			return "skipped", "opaque purchase row identity, generation, or fence changed"
		end
		row.player_id = nil
		row.fencing_generation += 1
		row.retained_uniqueness_fence = true
		return "redacted"
	end,
}
local v2 = RecordStoreV2Factory.new(RecordStore, RecordStore.MailboxV2)
local coordinator = v2.Erasure.new(manifest_store, { external_family }, {
	verify_templates = function(user_id, templates)
		return user_id == 77 and #templates == 1
			and templates[1].template.locator_mode == "external_inventory"
			and templates[1].template.inventory_source_ref == "evidence:purchase-user-index"
	end,
	require_inventory_attestation = true,
	application_inventory_manifest_id = "rtbf-inventory-regression-r1",
	writer_inventory_verified = true,
})
local plan = coordinator:PlanAsync(77, "erase-purchase-user-77")
expect(plan.code == "success" and plan.rtbf_coverage_verified == true,
	plan.message or "complete external inventory was rejected during erasure planning")
expect(plan.coverage["purchase-authority"].unmatched_count == 0
	and plan.coverage["purchase-authority"].count == 1,
	"opaque purchase key was not reconciled against its explicit inventory source")
local executed = coordinator:ExecuteAsync(77, "erase-purchase-user-77", 8)
expect(executed.code == "committed" and executed.rtbf_coverage_verified == true,
	executed.message or "valid external-inventory erasure could not resume and complete")
expect(row.player_id == nil and row.purchase_id == "historical-purchase-opaque-77"
	and row.status == "committed" and row.retained_uniqueness_fence == true
	and row.erasure_fence == "erase-purchase-user-77",
	"retain-fence action did not remove the user identity while preserving purchase uniqueness")
print("[RTBFManifest] external inventory planning/resume, retained uniqueness fence, manifest binding, and fail-closed activation passed")
