--!nocheck
local Shim = require("./RobloxShim")
local server_script_service = Shim.environment.game:GetService("ServerScriptService")
local initializer = server_script_service:WaitForChild("PlayerDataInitializer")
local Manifest = Shim.environment.require(initializer:WaitForChild("PurchaseInventoryManifest"))

local function expect(value, message)
	if not value then error(message, 2) end
end

local function valid_manifest()
	return {
		schema_version = 1,
		kind = "purchase_inventory",
		manifest_id = "purchase-inventory-regression-r1",
		source_revision = "export-revision-r1",
		source_snapshot_id = "immutable-export-snapshot-r1",
		source_systems = { "MarketplaceService.ProcessReceipt" },
		legacy_receipt_paths = { "none" },
		row_order = "purchase_id_asc_player_id_asc_product_id_asc",
		expected_purchase_count = 0,
		expected_inventory_digest = string.rep("a", 64),
		digest_algorithm = "sha256-chain-v1",
		exported_at_unix = 1792950000,
		review_status = "approved",
		reviewed_by = "independent-reviewer",
		reviewed_at_unix = 1792950100,
		source_evidence_ref = "evidence:export",
		end_of_inventory_evidence_ref = "evidence:end-of-inventory",
		duplicate_conflict_report_ref = "evidence:duplicate-conflicts",
		coverage_review_ref = "evidence:coverage",
		archived_accounts_included = true,
		deleted_accounts_included = true,
	}
end

local raw = valid_manifest()
local normalized, validation_error = Manifest.validate(raw)
expect(normalized ~= nil, validation_error or "valid purchase manifest was rejected")
expect(table.isfrozen(normalized)
	and table.isfrozen(normalized.source_systems)
	and table.isfrozen(normalized.legacy_receipt_paths),
	"normalized purchase manifest is not immutable")
raw.source_systems[1] = "mutated"
raw.legacy_receipt_paths[1] = "mutated"
expect(normalized.source_systems[1] == "MarketplaceService.ProcessReceipt"
	and normalized.legacy_receipt_paths[1] == "none",
	"manifest normalization retained mutable caller-owned arrays")

local malformed = valid_manifest()
malformed.expected_inventory_digest = "not-a-sha256-digest"
expect(Manifest.validate(malformed) == nil, "malformed digest was accepted")
malformed = valid_manifest()
malformed.deleted_accounts_included = false
expect(Manifest.validate(malformed) == nil, "manifest omitted deleted-account coverage")
malformed = valid_manifest()
malformed.unrecognized = true
expect(Manifest.validate(malformed) == nil, "manifest accepted unsupported fields")
malformed = valid_manifest()
malformed.legacy_receipt_paths = { "none", "old_receipt_store" }
expect(Manifest.validate(malformed) == nil, "manifest combined 'none' with a legacy path")

local source = {
	snapshot_id = "immutable-export-snapshot-r1",
	read_page = function()
		return { items = {}, next_cursor = nil, done = true, source_revision = "export-revision-r1" }
	end,
}
local processor = {
	BackfillExternalAuthorityAsync = function()
		return { code = "success", processed_count = 0, backfilled_count = 0, duplicate_count = 0 }
	end,
}
local checkpoint_store = {
	GetAsyncFresh = function() return nil, nil end,
	UpdateAsync = function() return nil, "unused in binding-only test" end,
}
local source_verifications = 0
local terminal_verifications = 0
local binding, bound_manifest, binding_error = Manifest.bind_runner_config(
	valid_manifest(),
	{
		job_id = "purchase-manifest-binding-r1",
		source = source,
		processor = processor,
		checkpoint_store = checkpoint_store,
		checkpoint_key = "purchase-checkpoint-r1",
		page_size = 4,
	},
	function(manifest, bound_source)
		source_verifications += 1
		return bound_source.snapshot_id == manifest.source_snapshot_id,
			"source snapshot differs from the reviewed manifest"
	end,
	function(manifest, manifest_id, source_revision, expected_count, observed_count, expected_digest, observed_digest)
		terminal_verifications += 1
		return manifest_id == manifest.manifest_id
			and source_revision == manifest.source_revision
			and expected_count == observed_count
			and expected_count == 0
			and expected_digest == observed_digest
			and observed_digest == manifest.expected_inventory_digest,
			"terminal inventory differs from the reviewed manifest"
	end
)
expect(binding ~= nil and bound_manifest ~= nil, binding_error or "manifest failed to bind the migration runner")
expect(table.isfrozen(binding) and bound_manifest.manifest_id == "purchase-inventory-regression-r1",
	"bound migration configuration or manifest was not immutable")
expect(binding.source_revision == "export-revision-r1"
	and binding.inventory_manifest_id == "purchase-inventory-regression-r1"
	and binding.expected_purchase_count == 0
	and binding.expected_inventory_digest == string.rep("a", 64),
	"migration config did not derive immutable fields from the manifest")
expect(source_verifications == 1, "immutable source verifier was not called exactly once")

local untrusted_bindings = {
	job_id = "purchase-manifest-untrusted-r1",
	source = source,
	processor = processor,
	checkpoint_store = checkpoint_store,
	checkpoint_key = "purchase-checkpoint-untrusted",
	source_revision = "caller-controlled-override",
}
source_verifications = 0
expect(Manifest.bind_runner_config(
	valid_manifest(),
	untrusted_bindings,
	function() source_verifications += 1; return true end,
	function() return true end
) == nil, "caller-provided source revision override was accepted")
expect(source_verifications == 0, "source verifier ran before rejecting unsupported caller binding")

local rejected_source = Manifest.bind_runner_config(
	valid_manifest(),
	{
		job_id = "purchase-manifest-rejected-r1",
		source = source,
		processor = processor,
		checkpoint_store = checkpoint_store,
		checkpoint_key = "purchase-checkpoint-rejected",
	},
	function() return false, "source export failed independent reconciliation" end,
	function() return true end
)
expect(rejected_source == nil, "a rejected source verifier still produced a runner config")

local checkpoint = {
	version = 4,
	job_id = "purchase-manifest-binding-r1",
	done = true,
	revision = 1,
	cursor = nil,
	source_revision = "export-revision-r1",
	inventory_manifest_id = "purchase-inventory-regression-r1",
	purchases_processed = 0,
	last_purchase_id = nil,
	last_player_id = nil,
	last_product_id = nil,
	expected_purchase_count = 0,
	inventory_digest = string.rep("a", 64),
	expected_inventory_digest = string.rep("a", 64),
	digest_algorithm = "sha256-chain-v1",
	inventory_verified = true,
}
local completion = {
	manifest_id = "purchase-inventory-regression-r1",
	source_revision = "export-revision-r1",
	observed_purchase_count = 0,
	observed_inventory_digest = string.rep("a", 64),
	checkpoint_revision = 1,
	conflicts_reconciled = true,
	conflict_reconciliation_evidence_ref = "evidence:conflicts-reconciled",
	live_acceptance_complete = true,
	live_acceptance_evidence_ref = "evidence:live-acceptance",
}
local accepted, completion_error = Manifest.verify_completion(
	valid_manifest(),
	checkpoint,
	completion,
	function(manifest, verified_checkpoint, verified_completion)
		terminal_verifications += 1
		return manifest.manifest_id == verified_completion.manifest_id
			and verified_checkpoint.revision == verified_completion.checkpoint_revision
	end
)
expect(accepted ~= nil, completion_error or "complete manifest/checkpoint pair was rejected")
expect(terminal_verifications == 1, "independent completion verifier was not called")

completion.live_acceptance_complete = false
expect(Manifest.verify_completion(valid_manifest(), checkpoint, completion, function() return true end) == nil,
	"purchase completion accepted without live fulfillment acceptance evidence")
checkpoint.inventory_digest = string.rep("b", 64)
completion.live_acceptance_complete = true
expect(Manifest.verify_completion(valid_manifest(), checkpoint, completion, function() return true end) == nil,
	"purchase completion accepted a checkpoint digest mismatch")

print("Purchase inventory manifest regression passed")
