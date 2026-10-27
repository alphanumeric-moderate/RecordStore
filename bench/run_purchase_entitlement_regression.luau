--!nocheck
local Shim = require("./RobloxShim")
local initializer = Shim.environment.game:GetService("ServerScriptService"):WaitForChild("PlayerDataInitializer")
local Authority = Shim.environment.require(initializer:WaitForChild("PurchaseEntitlementDataStoreAuthority"))
local Coordinator = Shim.environment.require(initializer:WaitForChild("PurchaseEntitlementReceiptCoordinator"))
local ReceiptHandler = Shim.environment.require(initializer:WaitForChild("PurchaseEntitlementReceiptHandler"))
local Enum = Shim.environment.Enum
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

local now = 1792951000
local function make_store()
	local store = { rows = {}, lose_next_response = false, fail_reads = false, fail_writes = false }
	function store:GetAsyncFresh(key)
		if self.fail_reads then return nil, "injected uncached read failure" end
		return clone(self.rows[key]), nil
	end
	function store:UpdateAsync(key, transform)
		if self.fail_writes then return nil, "injected UpdateAsync failure" end
		local next_value = transform(clone(self.rows[key]))
		if next_value ~= nil then self.rows[key] = clone(next_value) end
		if self.lose_next_response then
			self.lose_next_response = false
			return nil, "injected response loss after durable mutation"
		end
		return clone(self.rows[key]), nil
	end
	return store
end

local function make_purchase_authority()
	local authority = { rows = {}, lose_next_commit_response = false }
	function authority:ClaimAsync(purchase_id, player_id, product_id)
		local current = self.rows[purchase_id]
		if current ~= nil then
			if current.PlayerId ~= player_id or current.ProductId ~= product_id then
				return {
					PurchaseId = purchase_id, PlayerId = current.PlayerId,
					ProductId = current.ProductId, Status = "conflict",
				}, nil
			end
			return clone(current), nil
		end
		local row = {
			PurchaseId = purchase_id, PlayerId = player_id,
			ProductId = product_id, Status = "claimed",
		}
		self.rows[purchase_id] = row
		return clone(row), nil
	end
	function authority:CommitAsync(purchase_id, player_id, product_id, outcome)
		local current = self.rows[purchase_id]
		if current == nil then return nil, "not_found" end
		if current.PlayerId ~= player_id or current.ProductId ~= product_id then
			return {
				PurchaseId = purchase_id, PlayerId = current.PlayerId,
				ProductId = current.ProductId, Status = "conflict",
			}, nil
		end
		if current.Status == "claimed" then
			current.Status = "committed"
			current.Outcome = outcome
		end
		if self.lose_next_commit_response then
			self.lose_next_commit_response = false
			return nil, "injected PurchaseId commit response loss"
		end
		return clone(current), nil
	end
	function authority:GetStatusAsync(purchase_id, player_id, product_id)
		local current = self.rows[purchase_id]
		if current == nil then return nil, "not_found" end
		if current.PlayerId ~= player_id or current.ProductId ~= product_id then
			return {
				PurchaseId = purchase_id, PlayerId = current.PlayerId,
				ProductId = current.ProductId, Status = "conflict",
			}, nil
		end
		return clone(current), nil
	end
	return authority
end

local function make_coordinator(purchase_authority, entitlement_store, grant_results, activation_verifier)
	local entitlement_authority = Authority.new({
		key_prefix = "ent:",
		store_adapter = entitlement_store,
		now_unix = function() return now end,
	})
	local grant_calls = {}
	local coordinator = Coordinator.new({
		purchase_authority = purchase_authority,
		entitlement_authority = entitlement_authority,
		entitlement_by_product_id = {
			[501] = "VIP_LIFETIME",
			[502] = "FOUNDERS_LIFETIME",
		},
		grant_profile_once = function(receipt, operation_id)
			expect(operation_id == "purchase:" .. receipt.PurchaseId,
				"profile grant did not use stable PurchaseId-derived operation identity")
			grant_calls[receipt.PurchaseId] = (grant_calls[receipt.PurchaseId] or 0) + 1
			local override = grant_results[receipt.PurchaseId]
			if type(override) == "function" then return override(receipt, operation_id) end
			local code = override or "granted"
			return code, if code == "unknown" then "injected unresolved grant" else nil
		end,
		verify_activation = activation_verifier or function() return true end,
	})
	return coordinator, entitlement_authority, grant_calls
end

local function find_owned(store, entitlement_id, player_id)
	for _, row in pairs(store.rows) do
		if row.entitlement_id == entitlement_id and row.player_id == player_id then
			return row.status == "owned", row
		end
	end
	return false, nil
end

local purchase_authority = make_purchase_authority()
local entitlement_store = make_store()
local grants = {}
local coordinator, entitlement_authority, grant_calls = make_coordinator(
	purchase_authority, entitlement_store, grants
)
local receipt = { PurchaseId = "entitlement-purchase-1", PlayerId = 4101, ProductId = 501 }
local first = coordinator:Process(receipt)
expect(first.action == "acknowledge" and first.status == "grant_committed",
	first.message or "first lifetime entitlement did not complete")

local expected_entitlement_key = "ent:" .. string.sub(
	SHA256.digest(tostring(receipt.PlayerId) .. ":VIP_LIFETIME"), 1, 32
)
expect(entitlement_store.rows[expected_entitlement_key] ~= nil,
	"lifetime entitlement authority must use the documented truncated SHA-256 key derivation")
expect(#expected_entitlement_key <= 50,
	"SHA-256 entitlement locator exceeded Roblox's key-length bound")
expect(purchase_authority.rows[receipt.PurchaseId].Status == "committed"
	and purchase_authority.rows[receipt.PurchaseId].Outcome == "granted",
	"global PurchaseId authority was not terminally committed")
local owned, owner_row = find_owned(entitlement_store, "VIP_LIFETIME", receipt.PlayerId)
expect(owned and owner_row.purchase_id == receipt.PurchaseId and owner_row.product_id == receipt.ProductId,
	"durable lifetime entitlement was not bound to the exact receipt")
expect(grant_calls[receipt.PurchaseId] == 1, "profile grant did not run exactly once on first receipt")

local replay = coordinator:Process(receipt)
expect(replay.action == "acknowledge" and replay.status == "entitlement_already_committed",
	"replayed committed receipt did not reconcile to its owned entitlement")
expect(grant_calls[receipt.PurchaseId] == 1, "replayed committed receipt invoked the profile grant twice")

local duplicate = { PurchaseId = "entitlement-purchase-duplicate", PlayerId = 4101, ProductId = 501 }
local duplicate_decision = coordinator:Process(duplicate)
expect(duplicate_decision.action == "acknowledge"
	and duplicate_decision.status == "lifetime_entitlement_already_owned",
	"second PurchaseId for an already-owned lifetime entitlement did not resolve as a duplicate")
expect(purchase_authority.rows[duplicate.PurchaseId].Status == "committed"
	and purchase_authority.rows[duplicate.PurchaseId].Outcome == "duplicate",
	"duplicate receipt was acknowledged without terminal PurchaseId commit")
expect(grant_calls[duplicate.PurchaseId] == nil, "duplicate lifetime receipt invoked the profile grant")

do
	local committed_without_entitlement = make_purchase_authority()
	committed_without_entitlement.rows["historical-no-entitlement"] = {
		PurchaseId = "historical-no-entitlement", PlayerId = 4102, ProductId = 501,
		Status = "committed", Outcome = "historical",
	}
	local missing_store = make_store()
	local missing_coordinator, _, missing_grants = make_coordinator(
		committed_without_entitlement, missing_store, {}
	)
	local missing = missing_coordinator:Process({
		PurchaseId = "historical-no-entitlement", PlayerId = 4102, ProductId = 501,
	})
	expect(missing.action == "defer" and missing.status == "purchase_committed_entitlement_unverified",
		"committed historical PurchaseId bypassed missing lifetime-entitlement reconciliation")
	expect(missing_grants["historical-no-entitlement"] == nil,
		"unverified historical entitlement caused a profile grant")
end

do
	local conflict_authority = make_purchase_authority()
	conflict_authority.rows["reused-purchase-id"] = {
		PurchaseId = "reused-purchase-id", PlayerId = 4103, ProductId = 501,
		Status = "committed", Outcome = "granted",
	}
	local conflict_coordinator, _, conflict_grants = make_coordinator(conflict_authority, make_store(), {})
	local conflict = conflict_coordinator:Process({
		PurchaseId = "reused-purchase-id", PlayerId = 4104, ProductId = 501,
	})
	expect(conflict.action == "defer", "cross-user PurchaseId reuse was not rejected")
	expect(conflict_grants["reused-purchase-id"] == nil, "cross-user PurchaseId conflict invoked a grant")
end

do
	local unknown_auth = make_purchase_authority()
	local unknown_store = make_store()
	local unknown_grants = { ["grant-unknown"] = "unknown" }
	local unknown_coordinator, _, unknown_calls = make_coordinator(unknown_auth, unknown_store, unknown_grants)
	local unknown = { PurchaseId = "grant-unknown", PlayerId = 4105, ProductId = 502 }
	local deferred = unknown_coordinator:Process(unknown)
	expect(deferred.action == "defer" and deferred.status == "profile_grant_unconfirmed",
		"unknown profile-grant outcome was treated as committed")
	expect(unknown_auth.rows[unknown.PurchaseId].Status == "claimed",
		"unresolved grant incorrectly committed the global PurchaseId")
	expect(unknown_calls[unknown.PurchaseId] == 1, "unresolved grant did not make exactly one attempt")
end

do
	local loss_auth = make_purchase_authority()
	local loss_store = make_store()
	loss_store.lose_next_response = true
	loss_auth.lose_next_commit_response = true
	local loss_coordinator, _, loss_grants = make_coordinator(loss_auth, loss_store, {})
	local lost = { PurchaseId = "response-loss-receipt", PlayerId = 4106, ProductId = 502 }
	local result = loss_coordinator:Process(lost)
	expect(result.action == "acknowledge",
		result.message or "durable response-loss outcomes were not reconciled")
	expect(loss_auth.rows[lost.PurchaseId].Status == "committed",
		"PurchaseId commit response loss was not reconciled from authoritative status")
	local is_owned, row = find_owned(loss_store, "FOUNDERS_LIFETIME", lost.PlayerId)
	expect(is_owned and row.purchase_id == lost.PurchaseId,
		"entitlement response loss did not reconcile to the durable owned row")
	expect(loss_grants[lost.PurchaseId] == 1, "response-loss recovery repeated the grant inside one attempt")
end

do
	local guarded_auth = make_purchase_authority()
	local guarded_coordinator, _, guarded_grants = make_coordinator(
		guarded_auth, make_store(), {},
		function() return false, "activation gate remains closed" end
	)
	local blocked = guarded_coordinator:Process({
		PurchaseId = "activation-blocked", PlayerId = 4107, ProductId = 501,
	})
	expect(blocked.action == "defer" and blocked.status == "activation_blocked",
		"lifetime receipt activation gate did not fail closed")
	expect(guarded_auth.rows["activation-blocked"] == nil
		and guarded_grants["activation-blocked"] == nil,
		"blocked receipt changed durable purchase state or invoked a grant")
end

do
	local route_auth = make_purchase_authority()
	local route_store = make_store()
	local route_coordinator, _, route_grants = make_coordinator(
		route_auth, route_store, { ["handler-deferred"] = "unknown" }
	)
	local fallback_calls = 0
	local handler = ReceiptHandler.new(route_coordinator, function()
		fallback_calls += 1
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end)
	local handled = { PurchaseId = "handler-committed", PlayerId = 4108, ProductId = 501 }
	expect(handler(handled) == Enum.ProductPurchaseDecision.PurchaseGranted,
		"committed mapped lifetime receipt was not translated to PurchaseGranted")
	expect(fallback_calls == 0, "mapped receipt incorrectly invoked fallback handler")
	local unrelated = { PurchaseId = "handler-unrelated", PlayerId = 4109, ProductId = 999 }
	expect(handler(unrelated) == Enum.ProductPurchaseDecision.PurchaseGranted and fallback_calls == 1,
		"unmapped product did not fall through to the ordinary receipt handler exactly once")
	local deferred = { PurchaseId = "handler-deferred", PlayerId = 4110, ProductId = 502 }
	expect(handler(deferred) == Enum.ProductPurchaseDecision.NotProcessedYet,
		"unresolved mapped receipt was acknowledged")
	expect(route_grants[deferred.PurchaseId] == 1,
		"deferred mapped receipt did not exercise its unresolved grant path")
end

-- Unit-test the receipt decision boundary independently of durable authorities.
-- A new/unknown status must never acknowledge a purchase accidentally.
do
	local granted = Enum.ProductPurchaseDecision.PurchaseGranted
	local deferred = Enum.ProductPurchaseDecision.NotProcessedYet
	local receipt = table.freeze({ PurchaseId = "decision-boundary", PlayerId = 4111, ProductId = 501 })
	local terminal_statuses = {
		"grant_committed", "duplicate_grant_reconciled", "purchase_already_committed",
		"lifetime_entitlement_already_owned", "entitlement_already_committed",
	}
	local decisions = {}
	for _, status in ipairs(terminal_statuses) do
		table.insert(decisions, { name = status, result = { action = "acknowledge", status = status }, expected = granted })
		table.insert(decisions, { name = "defer/" .. status, result = { action = "defer", status = status }, expected = deferred })
	end
	for _, row in {
		{ action = "acknowledge", status = "unknown" },
		{ action = "acknowledge", status = "conflict" },
		{ action = "acknowledge", status = "future_terminal_status" },
		{ action = "acknowledge" },
		{ status = "grant_committed" },
		{},
	} do
		table.insert(decisions, { name = "unconfirmed/" .. tostring(row.status), result = row, expected = deferred })
	end
	for _, malformed in { false, "grant_committed", granted } do
		table.insert(decisions, { name = "malformed/" .. type(malformed), result = malformed, expected = deferred })
	end
	table.insert(decisions, { name = "missing result", expected = deferred })
	for _, case in ipairs(decisions) do
		local process_calls, fallback_calls = 0, 0
		local coordinator = {}
		function coordinator:HandlesProduct(product_id)
			expect(self == coordinator and product_id == receipt.ProductId, "routing lost coordinator/product identity")
			return true
		end
		function coordinator:Process(observed)
			expect(self == coordinator and observed == receipt, "processing did not receive the original receipt")
			process_calls += 1
			return case.result
		end
		local handler = ReceiptHandler.new(coordinator, function()
			fallback_calls += 1
			return granted
		end)
		expect(handler(receipt) == case.expected, "wrong receipt decision for " .. case.name)
		expect(process_calls == 1 and fallback_calls == 0, "mapped receipt escaped to fallback for " .. case.name)
	end

	-- Only an explicit false routes to fallback; truthy/nonboolean results and
	-- exceptions leave the receipt retryable without invoking either grant path.
	for _, route in {
		{ name = "nil" }, { name = "truthy string", value = "true" },
		{ name = "zero", value = 0 }, { name = "table", value = {} },
		{ name = "exception", raises = true },
	} do
		local calls = 0
		local handler = ReceiptHandler.new({
			HandlesProduct = function()
				if route.raises then error("injected routing failure") end
				return route.value
			end,
			Process = function() calls += 1; return { action = "acknowledge", status = "grant_committed" } end,
		}, function() calls += 1; return granted end)
		expect(handler(receipt) == deferred and calls == 0, "ambiguous product routing was accepted: " .. route.name)
	end
	local unexpected_fallback_calls = 0
	local throwing_processor = ReceiptHandler.new({
		HandlesProduct = function() return true end,
		Process = function() error("injected coordinator failure") end,
	}, function() unexpected_fallback_calls += 1; return granted end)
	expect(throwing_processor(receipt) == deferred and unexpected_fallback_calls == 0,
		"coordinator exception escaped, acknowledged the receipt or reached fallback")

	for _, fallback_case in {
		{ name = "granted enum", value = granted, expected = granted },
		{ name = "deferred enum", value = deferred, expected = deferred },
		{ name = "lookalike string", value = "PurchaseGranted", expected = deferred },
		{ name = "truthy boolean", value = true, expected = deferred },
		{ name = "table", value = { action = "acknowledge", status = "grant_committed" }, expected = deferred },
		{ name = "nil", expected = deferred },
		{ name = "exception", raises = true, expected = deferred },
	} do
		local fallback_calls = 0
		local handler = ReceiptHandler.new({
			HandlesProduct = function() return false end,
			Process = function() error("unmapped receipt reached the coordinator") end,
		}, function(observed)
			expect(observed == receipt, "fallback did not receive the original receipt")
			fallback_calls += 1
			if fallback_case.raises then error("injected fallback failure") end
			return fallback_case.value
		end)
		expect(handler(receipt) == fallback_case.expected and fallback_calls == 1,
			"fallback decision did not fail closed: " .. fallback_case.name)
	end

	local routed_product, route_calls, grant_calls = nil, 0, 0
	local malformed_handler = ReceiptHandler.new({
		HandlesProduct = function(_self, product_id)
			routed_product = product_id
			route_calls += 1
			return nil
		end,
		Process = function() grant_calls += 1; return { action = "acknowledge", status = "grant_committed" } end,
	}, function() grant_calls += 1; return granted end)
	for _, malformed in { false, 42, "receipt", {} } do
		local before_calls = route_calls
		expect(malformed_handler(malformed) == deferred and routed_product == nil
			and route_calls == before_calls + 1 and grant_calls == 0,
			"malformed receipt acquired a product identity or reached a grant path")
	end
	expect(malformed_handler(nil) == deferred and routed_product == nil and grant_calls == 0,
		"nil receipt did not defer without granting")

	for _, invalid in { false, {}, { HandlesProduct = true, Process = function() end },
		{ HandlesProduct = function() end, Process = false } } do
		expect(not pcall(ReceiptHandler.new, invalid, function() end), "invalid coordinator was accepted")
	end
	expect(not pcall(ReceiptHandler.new, nil, function() end), "nil coordinator was accepted")
	local valid_coordinator = { HandlesProduct = function() end, Process = function() end }
	for _, invalid in { false, "fallback", {} } do
		expect(not pcall(ReceiptHandler.new, valid_coordinator, invalid), "nonfunction fallback was accepted")
	end
	expect(not pcall(ReceiptHandler.new, valid_coordinator, nil), "missing fallback was accepted")
end

print("[PurchaseEntitlement] durable authority, receipt reconciliation, lifetime uniqueness, response loss, activation and fail-closed handler regressions passed")
