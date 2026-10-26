--!nocheck
local Shim = require("./RobloxShim")
local initializer = Shim.environment.game:GetService("ServerScriptService"):WaitForChild("PlayerDataInitializer")
local Authority = Shim.environment.require(initializer:WaitForChild("PurchaseEntitlementDataStoreAuthority"))
local SHA256 = Shim.environment.require(initializer:WaitForChild("RecordStoreSHA256"))

local function expect(value, message)
	if not value then error(message, 2) end
end

local function clone(value, seen)
	if type(value) ~= "table" then return value end
	local memo = seen or {}
	if memo[value] ~= nil then return memo[value] end
	local result = {}
	memo[value] = result
	for key, child in pairs(value) do result[clone(key, memo)] = clone(child, memo) end
	return result
end

local store = { rows = {}, lose_next_response = false, fail_reads = false }
function store:GetAsyncFresh(key)
	if self.fail_reads then return nil, "injected uncached read failure" end
	return clone(self.rows[key]), nil
end
function store:UpdateAsync(key, transform)
	local next_value = transform(clone(self.rows[key]))
	if next_value ~= nil then self.rows[key] = clone(next_value) end
	if self.lose_next_response then
		self.lose_next_response = false
		return nil, "injected response loss after durable mutation"
	end
	return clone(self.rows[key]), nil
end

local now = 1792952000
local authority = Authority.new({
	key_prefix = "ent:",
	store_adapter = store,
	now_unix = function() return now end,
})
local entitlement_id = "VIP_LIFETIME"
local player_id = 77001
local product_id = 9001
local purchase_id = "entitlement-erasure-receipt"

local reserved = authority:ReserveAsync(entitlement_id, player_id, product_id, purchase_id)
expect(reserved.code == "claimed", reserved.message or "initial entitlement reservation failed")
local committed = authority:CommitAsync(entitlement_id, player_id, product_id, purchase_id)
expect(committed.code == "committed" and committed.record ~= nil,
	committed.message or "initial entitlement ownership did not commit")

local locator, locator_error = authority:GetErasureLocatorAsync(entitlement_id, player_id)
expect(locator ~= nil and locator.generation == committed.record.revision
	and type(locator.key) == "string" and #locator.key <= 50,
	locator_error or "generation-bound entitlement erasure locator was not returned")
local original = clone(store.rows[locator.key])
expect(original.status == "owned" and original.player_id == player_id
	and original.entitlement_id == entitlement_id and original.purchase_id == purchase_id,
	"pre-erasure authority row was not the exact owner-bound entitlement")

local stale = authority:EraseRetainFenceAsync(
	entitlement_id, player_id, locator.generation - 1, "entitlement-erasure-stale"
)
expect(stale.code == "conflict", "stale entitlement generation was allowed to erase the row")
expect(store.rows[locator.key].status == "owned"
	and store.rows[locator.key].player_id == player_id,
	"stale erasure mutated the live entitlement")

now += 10
store.lose_next_response = true
local erased = authority:EraseRetainFenceAsync(
	entitlement_id, player_id, locator.generation, "entitlement-erasure-001"
)
expect(erased.code == "erased" and erased.record == nil,
	erased.message or "ambiguous tombstone write was not reconciled from an uncached read")
local tombstone = store.rows[locator.key]
expect(tombstone.version == 2 and tombstone.status == "erased"
	and tombstone.revision == locator.generation + 1
	and tombstone.identity_digest == SHA256.digest(tostring(player_id) .. ":" .. entitlement_id),
	"erasure did not persist a versioned, identity-bound retention fence")
expect(tombstone.entitlement_id == nil and tombstone.player_id == nil
	and tombstone.product_id == nil and tombstone.purchase_id == nil,
	"erasure tombstone retained user or receipt identifiers")
expect(type(tombstone.erasure_fence) == "table"
	and tombstone.erasure_fence.erasure_id == "entitlement-erasure-001"
	and tombstone.erasure_fence.source_revision == locator.generation
	and tombstone.erasure_fence.fenced_revision == tombstone.revision,
	"tombstone did not bind the erasure ID and generation transition")

local status = authority:GetStatusAsync(entitlement_id, player_id)
expect(status.code == "erased" and status.record == nil,
	"status lookup exposed a redacted entitlement as owned or corrupt")
local blocked_reserve = authority:ReserveAsync(entitlement_id, player_id, product_id, "later-receipt")
local blocked_backfill = authority:BackfillAsync(entitlement_id, player_id, product_id, "historical-receipt")
expect(blocked_reserve.code == "erased" and blocked_backfill.code == "erased",
	"post-erasure reserve/backfill was allowed to recreate identifying entitlement data")
expect(store.rows[locator.key].revision == tombstone.revision
	and store.rows[locator.key].purchase_id == nil,
	"post-erasure writes changed the permanent entitlement tombstone")

local repeated = authority:EraseRetainFenceAsync(
	entitlement_id, player_id, locator.generation, "entitlement-erasure-001"
)
expect(repeated.code == "erased", "same erasure ID could not reconcile an already-committed tombstone")
local competing = authority:EraseRetainFenceAsync(
	entitlement_id, player_id, locator.generation, "different-erasure-id"
)
expect(competing.code == "conflict", "a second erasure ID replaced the permanent tombstone identity")

local absent_player_id = 77002
local absent_locator, absent_error = authority:GetErasureLocatorAsync(entitlement_id, absent_player_id)
expect(absent_locator ~= nil and absent_locator.generation == 0,
	absent_error or "absent entitlement did not produce a generation-zero erasure locator")
local absent_erased = authority:EraseRetainFenceAsync(
	entitlement_id, absent_player_id, 0, "erase-never-created-entitlement"
)
expect(absent_erased.code == "erased", "erasure failed to fence a never-created entitlement key")
local absent_reserve = authority:ReserveAsync(
	entitlement_id, absent_player_id, product_id, "late-stale-receipt"
)
expect(absent_reserve.code == "erased",
	"late first-time write recreated an entitlement after its absent-key erasure fence")

local collision = store.rows[locator.key]
collision.identity_digest = string.rep("0", 64)
local collision_status = authority:GetStatusAsync(entitlement_id, player_id)
expect(collision_status.code ~= "owned" and collision_status.code ~= "pending"
	and collision_status.code ~= "erased",
	"malformed or mismatched erasure identity digest was treated as a valid fence")

print("[EntitlementErasure] redaction, absent-key fencing, stale-generation rejection, response-loss recovery and post-erasure write blocking passed")
