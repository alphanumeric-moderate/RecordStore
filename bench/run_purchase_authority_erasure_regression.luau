--!nocheck
local Shim = require("./RobloxShim")
local RecordStore = Shim.load()
local initializer = Shim.environment.game:GetService("ServerScriptService"):WaitForChild("PlayerDataInitializer")
local AuthorityModule = Shim.environment.require(initializer:WaitForChild("PurchaseDataStoreAuthority"))

local function expect(value, message)
	if not value then error(message, 2) end
end

local function clone(value, depth)
	depth = depth or 0
	if depth > 32 then error("purchase authority fixture exceeded clone depth", 2) end
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in pairs(value) do result[key] = clone(child, depth + 1) end
	return result
end

local function new_store()
	local store = {
		values = {},
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
		local next_value = transform(clone(self.values[key]))
		if next_value ~= nil then self.values[key] = clone(next_value) end
		if self.faults.lose_next_update_response then
			self.faults.lose_next_update_response = false
			return nil, "injected update response loss after commit"
		end
		return clone(self.values[key]), nil
	end
	return store
end

local backing = new_store()
local now = 1000
local authority = AuthorityModule.new({
	store_name = "PurchaseAuthorityRTBFRegression",
	scope = "global",
	store_adapter = backing,
	now_unix = function() return now end,
})

local claimed, claim_error = authority:ClaimAsync("purchase-rtbf-001", 77001, 9001)
expect(claimed ~= nil and claimed.Status == "claimed",
	"initial claim failed: " .. tostring(claim_error))
local committed, commit_error = authority:CommitAsync("purchase-rtbf-001", 77001, 9001, "granted")
expect(committed ~= nil and committed.Status == "committed" and committed.Generation == 2,
	"commit did not advance the durable row generation: " .. tostring(commit_error))

local locator, locator_error = authority:GetErasureLocatorAsync("purchase-rtbf-001", 77001, 9001)
expect(locator ~= nil and locator.name == "PurchaseAuthorityRTBFRegression"
	and locator.scope == "global" and locator.generation == 2
	and type(locator.key) == "string" and #locator.key <= 50,
	"exact RTBF locator was not returned: " .. tostring(locator_error))
local stale, stale_error = authority:EraseRetainFenceAsync(
	"purchase-rtbf-001", 77001, 9001, locator.generation - 1, "erase-stale-rtbf-001"
)
expect(stale ~= nil and stale.Status == "conflict",
	"stale generation did not fail closed: " .. tostring(stale_error))
local unchanged = backing.values[locator.key]
expect(unchanged ~= nil and unchanged.status == "committed" and unchanged.player_id == 77001,
	"stale erasure changed the active authority row")

backing.faults.lose_next_update_response = true
local erased, erase_error = authority:EraseRetainFenceAsync(
	"purchase-rtbf-001", 77001, 9001, locator.generation, "erase-purchase-rtbf-001"
)
expect(erased ~= nil and erased.Status == "erased" and erased.Generation == 3,
	"commit-then-error erasure did not reconcile its tombstone: " .. tostring(erase_error))
local tombstone = backing.values[locator.key]
expect(tombstone ~= nil and tombstone.status == "erased"
	and tombstone.purchase_id == nil and tombstone.player_id == nil
	and tombstone.product_id == nil and tombstone.outcome == nil,
	"the retained uniqueness fence kept raw purchase or user fields")
expect(tombstone.fencing_generation == 3
	and tombstone.erasure_fence.erasure_id == "erase-purchase-rtbf-001"
	and tombstone.erasure_fence.source_generation == 2
	and tombstone.erasure_fence.fenced_generation == 3
	and type(tombstone.purchase_identity_digest) == "string"
	and #tombstone.purchase_identity_digest == 64,
	"the erasure tombstone lacks its permanent generation fence or one-way identity digest")

local read_status = authority:GetStatusAsync("purchase-rtbf-001", 77001, 9001)
expect(read_status ~= nil and read_status.Status == "conflict" and read_status.Generation == 3,
	"status lookup did not fail closed on the permanent tombstone")
local receipt_replay = authority:ClaimAsync("purchase-rtbf-001", 77001, 9001)
expect(receipt_replay ~= nil and receipt_replay.Status == "conflict",
	"ClaimAsync reopened an erased PurchaseId")
local late_commit = authority:CommitAsync("purchase-rtbf-001", 77001, 9001, "granted")
expect(late_commit ~= nil and late_commit.Status == "conflict",
	"CommitAsync overwrote an erased PurchaseId")
local historical_replay = authority:BackfillAsync("purchase-rtbf-001", 77001, 9001)
expect(historical_replay ~= nil and historical_replay.Status == "conflict",
	"BackfillAsync recreated an erased PurchaseId")
local repeated_erasure = authority:EraseRetainFenceAsync(
	"purchase-rtbf-001", 77001, 9001, locator.generation, "erase-purchase-rtbf-001"
)
expect(repeated_erasure ~= nil and repeated_erasure.Status == "erased"
	and repeated_erasure.Generation == 3,
	"same-ID erasure retry was not idempotent")

local claimed_unknown, claim_unknown_error = authority:ClaimAsync("purchase-rtbf-unknown", 77002, 9002)
expect(claimed_unknown ~= nil and claimed_unknown.Status == "claimed",
	"uncertain-result fixture could not claim a second receipt: " .. tostring(claim_unknown_error))
local committed_unknown = authority:CommitAsync("purchase-rtbf-unknown", 77002, 9002, "granted")
expect(committed_unknown ~= nil and committed_unknown.Status == "committed",
	"uncertain-result fixture could not commit its second receipt")
local unknown_locator = authority:GetErasureLocatorAsync("purchase-rtbf-unknown", 77002, 9002)
expect(unknown_locator ~= nil, "uncertain-result locator was unavailable")
backing.faults.fail_next_fresh_read = true
local unconfirmed, unconfirmed_error = authority:EraseRetainFenceAsync(
	"purchase-rtbf-unknown", 77002, 9002, unknown_locator.generation, "erase-purchase-rtbf-unknown"
)
expect(unconfirmed == nil and unconfirmed_error ~= nil,
	"erasure claimed success without a required uncached confirmation")
local recovered = authority:EraseRetainFenceAsync(
	"purchase-rtbf-unknown", 77002, 9002, unknown_locator.generation, "erase-purchase-rtbf-unknown"
)
expect(recovered ~= nil and recovered.Status == "erased",
	"same-ID retry did not recover the tombstone after readback became available")

print("[PurchaseAuthorityErasure] generation CAS, PII minimization, durable uniqueness fence, replay rejection, and ambiguous-write recovery passed")
Shim.close()
