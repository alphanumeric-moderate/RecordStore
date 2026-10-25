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

Mock.reset()
Shim.close()
