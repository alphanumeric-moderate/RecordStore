--!nocheck
local fs = require("@lune/fs")
local luau = require("@lune/luau")

local Manifest = luau.load(fs.readFile("staging/pr56-blockers/RecordStoreApplicationInventory.luau"), {
	debugName = "RecordStoreApplicationInventory",
})()
local Authority = luau.load(fs.readFile("staging/pr56-blockers/PurchaseEntitlementDataStoreAuthority.luau"), {
	debugName = "PurchaseEntitlementDataStoreAuthority",
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

print("PR56 staged blocker regression checks passed")
