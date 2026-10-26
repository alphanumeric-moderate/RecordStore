--!nocheck
local fs = require("@lune/fs")
local luau = require("@lune/luau")

local Manifest = luau.load(fs.readFile("staging/pr56-blockers/RecordStoreApplicationInventory.luau"), {
	debugName = "RecordStoreApplicationInventory",
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
	and table.isfrozen(normalized.families[1]) and table.isfrozen(normalized.writers[1]),
	"normalized manifest and nested catalog entries must be immutable")

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
local atomic_store = make_atomic_store(make_atomic_profile(4, "job-atomic-1", true, true))
local atomic_action, atomic_error = atomic_adapter:DeleteIfGeneration(
	atomic_store, atomic_item, 4, "job-atomic-1"
)
expect(atomic_action == "deleted", atomic_error or "same-key fenced tombstone did not commit")
expect(atomic_store.row.fencing_generation == 5
	and atomic_store.row.maintenance_fence_job_id == "job-atomic-1"
	and atomic_store.row.tombstone_source_generation == 4,
	"tombstone did not advance the generation and retain the same-key job fence")
expect(atomic_store.row.payload.coins == 100 and atomic_store.row.payload.flags.keep == true,
	"tombstone callback did not preserve its explicitly retained payload")

local atomic_retry, atomic_retry_error = atomic_adapter:DeleteIfGeneration(
	atomic_store, atomic_item, 4, "job-atomic-1"
)
expect(atomic_retry == "deleted", atomic_retry_error or "tombstone response-loss retry was not idempotent")

local wrong_fence_store = make_atomic_store(make_atomic_profile(4, "different-job", true, true))
local wrong_fence_action = atomic_adapter:DeleteIfGeneration(
	wrong_fence_store, atomic_item, 4, "job-atomic-1"
)
expect(wrong_fence_action == "skipped" and wrong_fence_store.row.tombstone ~= true,
	"a foreign same-key job fence did not block deletion")

local stale_generation_store = make_atomic_store(make_atomic_profile(4, "job-atomic-1", true, true))
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

local ineligible_store = make_atomic_store(make_atomic_profile(4, "job-atomic-1", false, true))
local ineligible_action = atomic_adapter:DeleteIfGeneration(ineligible_store, atomic_item, 4, "job-atomic-1")
expect(ineligible_action == "skipped" and ineligible_store.row.tombstone ~= true,
	"a record that was not eligible was tombstoned")

local dependent_store = make_atomic_store(make_atomic_profile(4, "job-atomic-1", true, false))
local dependent_action = atomic_adapter:DeleteIfGeneration(dependent_store, atomic_item, 4, "job-atomic-1")
expect(dependent_action == "skipped" and dependent_store.row.tombstone ~= true,
	"a record with unresolved dependencies was tombstoned")

local lost_response_store = make_atomic_store(make_atomic_profile(4, "job-atomic-1", true, true))
lost_response_store.lose_next_response = true
local lost_response_action, lost_response_error = atomic_adapter:DeleteIfGeneration(
	lost_response_store, atomic_item, 4, "job-atomic-1"
)
expect(lost_response_action == "deleted", lost_response_error or "tombstone commit response loss was not reconciled")

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
		expected_inventory_digest = string.rep("c", 32),
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
	done = true,
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

print("PR56 staged blocker regression checks passed")
