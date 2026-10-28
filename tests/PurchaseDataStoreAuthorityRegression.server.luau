--!nocheck
-- Deferred until the remaining PR #56 implementation slices are complete.
local Shim = require("./RobloxShim")
local RecordStore = Shim.load()
local Mock = RecordStore.Mock
local PurchaseAuthorityModule = require(
	game:GetService("ServerScriptService"):WaitForChild("PlayerDataInitializer"):WaitForChild("PurchaseDataStoreAuthority")
)

local function expect(value, message)
	assert(value, message)
end

local function clone(value, depth)
	depth = depth or 0
	assert(depth <= 32, "authority fixture exceeded clone depth")
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in pairs(value) do result[key] = clone(child, depth + 1) end
	return result
end

local function new_store()
	local store = {
		values = {},
		update_calls = 0,
		faults = {
			lose_next_update_response = false,
			fail_next_fresh_read = false,
		},
	}
	function store:GetAsyncFresh(key)
		if self.faults.fail_next_fresh_read then
			self.faults.fail_next_fresh_read = false
			return nil, "injected fresh-read failure"
		end
		return clone(self.values[key]), nil
	end
	function store:UpdateAsync(key, transform)
		self.update_calls += 1
		local current = clone(self.values[key])
		local changed = transform(current)
		if changed ~= nil then self.values[key] = clone(changed) end
		if self.faults.lose_next_update_response then
			self.faults.lose_next_update_response = false
			return nil, "injected update response loss after commit"
		end
		return clone(self.values[key]), nil
	end
	return store
end

local now = 1000
local backing = new_store()
local authority = PurchaseAuthorityModule.new({
	store_name = "PurchaseAuthorityRegression",
	scope = "global",
	store_adapter = backing,
	now_unix = function() return now end,
})

local writes_before_invalid_identity = backing.update_calls
local unsafe_player, unsafe_player_error = authority:ClaimAsync(
	"purchase-unsafe-player-id", 9007199254740992, 1001
)
expect(unsafe_player == nil and unsafe_player_error ~= nil,
	"global purchase authority accepted a PlayerId beyond the safe-integer range")
local unsafe_product, unsafe_product_error = authority:ClaimAsync(
	"purchase-unsafe-product-id", 123, 9007199254740992
)
expect(unsafe_product == nil and unsafe_product_error ~= nil,
	"global purchase authority accepted a ProductId beyond the safe-integer range")
expect(backing.update_calls == writes_before_invalid_identity,
	"invalid numeric receipt identities reached the durable purchase authority")
local claimed, claim_error = authority:ClaimAsync("purchase-global-001", 123, 1001)
expect(claimed ~= nil and claimed.Status == "claimed",
	"first global purchase claim failed: " .. tostring(claim_error))
local same_claim, same_claim_error = authority:ClaimAsync("purchase-global-001", 123, 1001)
expect(same_claim ~= nil and same_claim.Status == "claimed",
	"same identity did not idempotently reuse the durable claim: " .. tostring(same_claim_error))
local rebound, rebound_error = authority:ClaimAsync("purchase-global-001", 123, 1002)
expect(rebound ~= nil and rebound.Status == "conflict",
	"PurchaseId rebinding to another product was not rejected: " .. tostring(rebound_error))
expect(rebound.PurchaseId == "purchase-global-001" and rebound.PlayerId == 123 and rebound.ProductId == 1002,
	"conflict record did not echo the requested identity tuple")

backing.faults.lose_next_update_response = true
local committed, commit_error = authority:CommitAsync("purchase-global-001", 123, 1001, "granted")
expect(committed ~= nil and committed.Status == "committed" and committed.Outcome == "granted",
	"commit response loss was not reconciled through uncached read-back: " .. tostring(commit_error))
local confirmed, confirm_error = authority:GetStatusAsync("purchase-global-001", 123, 1001)
expect(confirmed ~= nil and confirmed.Status == "committed" and confirmed.Outcome == "granted",
	"fresh status did not confirm the globally committed receipt: " .. tostring(confirm_error))
local wrong_status, wrong_status_error = authority:GetStatusAsync("purchase-global-001", 124, 1001)
expect(wrong_status ~= nil and wrong_status.Status == "conflict",
	"identity-bound status lookup did not report a PlayerId mismatch: " .. tostring(wrong_status_error))
expect(wrong_status.PurchaseId == "purchase-global-001" and wrong_status.PlayerId == 124
	and wrong_status.ProductId == 1001,
	"status conflict did not echo the requested identity tuple")
local duplicate_commit, duplicate_commit_error = authority:CommitAsync(
	"purchase-global-001", 123, 1001, "duplicate"
)
expect(duplicate_commit ~= nil and duplicate_commit.Status == "committed",
	"repeated commit was not idempotent: " .. tostring(duplicate_commit_error))
expect(duplicate_commit.Outcome == "granted",
	"repeated commit rewrote an already terminal outcome")

local read_failure_id = "purchase-read-back-failure"
local second_claim, second_claim_error = authority:ClaimAsync(read_failure_id, 123, 1001)
expect(second_claim ~= nil and second_claim.Status == "claimed",
	"read-failure fixture could not claim PurchaseId: " .. tostring(second_claim_error))
backing.faults.fail_next_fresh_read = true
local unresolved, unresolved_error = authority:CommitAsync(read_failure_id, 123, 1001, "granted")
expect(unresolved == nil and unresolved_error ~= nil,
	"commit was reported successful without its required uncached confirmation")
local after_read_recovery, after_read_error = authority:GetStatusAsync(read_failure_id, 123, 1001)
expect(after_read_recovery ~= nil and after_read_recovery.Status == "committed"
	and after_read_recovery.Outcome == "granted",
	"later uncached status failed to reconcile committed-but-unobserved state: " .. tostring(after_read_error))

local history = authority:BackfillAsync("purchase-historical-001", 123, 1001)
expect(history ~= nil and history.Status == "imported",
	"first historical import did not report imported")
local history_status = authority:GetStatusAsync("purchase-historical-001", 123, 1001)
expect(history_status ~= nil and history_status.Status == "committed"
	and history_status.Outcome == "historical",
	"historical PurchaseId was not durably marked complete without a grant")
local repeated_history = authority:BackfillAsync("purchase-historical-001", 123, 1001)
expect(repeated_history ~= nil and repeated_history.Status == "committed"
	and repeated_history.Outcome == "historical",
	"repeated historical import did not return the prior completed record")
local history_conflict = authority:BackfillAsync("purchase-historical-001", 123, 1002)
expect(history_conflict ~= nil and history_conflict.Status == "conflict",
	"historical import overwrote a PurchaseId already bound to another product")

local in_flight = authority:ClaimAsync("purchase-inflight-history", 123, 1001)
expect(in_flight ~= nil and in_flight.Status == "claimed",
	"in-flight historical fixture claim failed")
local in_flight_backfill = authority:BackfillAsync("purchase-inflight-history", 123, 1001)
expect(in_flight_backfill ~= nil and in_flight_backfill.Status == "claimed",
	"historical backfill incorrectly converted an in-flight claim into terminal completion")
local still_claimed = authority:GetStatusAsync("purchase-inflight-history", 123, 1001)
expect(still_claimed ~= nil and still_claimed.Status == "claimed",
	"in-flight authority record changed during historical import")

local erasure_locator, locator_error = authority:GetErasureLocatorAsync(
	"purchase-global-001", 123, 1001
)
expect(erasure_locator ~= nil and erasure_locator.name == "PurchaseAuthorityRegression"
	and erasure_locator.scope == "global" and erasure_locator.generation == 2
	and type(erasure_locator.key) == "string",
	"purchase authority did not expose an exact generation-bound RTBF locator: " .. tostring(locator_error))
local stale_erasure, stale_erasure_error = authority:EraseRetainFenceAsync(
	"purchase-global-001", 123, 1001, erasure_locator.generation - 1, "erase-stale-purchase"
)
expect(stale_erasure ~= nil and stale_erasure.Status == "conflict",
	"stale purchase generation was allowed to install an erasure fence: " .. tostring(stale_erasure_error))
local before_erase = backing.values[erasure_locator.key]
expect(before_erase ~= nil and before_erase.status == "committed" and before_erase.player_id == 123,
	"stale-generation rejection changed the authority record")

backing.faults.lose_next_update_response = true
local retained_fence, retain_error = authority:EraseRetainFenceAsync(
	"purchase-global-001", 123, 1001, erasure_locator.generation, "erase-purchase-global-001"
)
expect(retained_fence ~= nil and retained_fence.Status == "erased"
	and retained_fence.Generation == erasure_locator.generation + 1,
	"purchase erasure did not reconcile a lost tombstone response: " .. tostring(retain_error))
local erased_raw = backing.values[erasure_locator.key]
expect(erased_raw ~= nil and erased_raw.status == "erased"
	and erased_raw.purchase_id == nil and erased_raw.player_id == nil
	and erased_raw.product_id == nil and erased_raw.outcome == nil,
	"erasure tombstone retained the raw PurchaseId, PlayerId, ProductId or receipt outcome")
expect(erased_raw.fencing_generation == erasure_locator.generation + 1
	and erased_raw.erasure_fence.erasure_id == "erase-purchase-global-001"
	and erased_raw.erasure_fence.source_generation == erasure_locator.generation
	and type(erased_raw.purchase_identity_digest) == "string"
	and #erased_raw.purchase_identity_digest == 64,
	"erasure tombstone lost its durable generation fence or non-reversible identity digest")

local replay_after_erasure = authority:ClaimAsync("purchase-global-001", 123, 1001)
expect(replay_after_erasure ~= nil and replay_after_erasure.Status == "conflict",
	"receipt replay recreated or reclaimed an erased PurchaseId")
local commit_after_erasure = authority:CommitAsync("purchase-global-001", 123, 1001, "granted")
expect(commit_after_erasure ~= nil and commit_after_erasure.Status == "conflict",
	"late receipt commit overwrote a permanent erasure tombstone")
local backfill_after_erasure = authority:BackfillAsync("purchase-global-001", 123, 1001)
expect(backfill_after_erasure ~= nil and backfill_after_erasure.Status == "conflict",
	"historical import recreated an erased PurchaseId")
local repeated_erasure = authority:EraseRetainFenceAsync(
	"purchase-global-001", 123, 1001, erasure_locator.generation, "erase-purchase-global-001"
)
expect(repeated_erasure ~= nil and repeated_erasure.Status == "erased"
	and repeated_erasure.Generation == erasure_locator.generation + 1,
	"same-ID erasure retry was not idempotent")

Mock.reset()
Shim.close()
