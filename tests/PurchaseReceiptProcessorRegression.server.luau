--!nocheck
local Shim = require("./RobloxShim")
local RecordStore = Shim.load()
local Mock = RecordStore.Mock
local ServerScriptService = game:GetService("ServerScriptService")
local ReceiptProcessor = require(
	ServerScriptService:WaitForChild("PlayerDataInitializer"):WaitForChild("PurchaseReceiptProcessor")
)

local function expect(value, message)
	assert(value, message)
end

Mock.reset()
Mock.set_test_clock(function()
	return 1000
end)

local record = Mock.new("PurchaseReceiptProcessorRegression", "global", "player-123", {
	schema_version = 1,
	autosave_interval = 1000,
	lease_duration = 180,
	lease_renewal = 60,
	transactional_operations_enabled = true,
})
local open_result, open_message = record:Open({ coins = 0 })
expect(open_result == "created" or open_result == "loaded", tostring(open_message))

local records = { [123] = record }
local diagnostics = {}
local processor = ReceiptProcessor.new({
	get_record = function(user_id)
		return records[user_id]
	end,
	receipt_retention_seconds = 3600,
	on_diagnostic = function(diagnostic)
		table.insert(diagnostics, diagnostic)
	end,
})

local grant_calls = 0
local handler = processor:CreateHandler({
	[1001] = function(data, receipt)
		grant_calls += 1
		local next_data = table.clone(data)
		next_data.coins += 25
		next_data.last_purchase_id = receipt.PurchaseId
		return next_data, { granted = 25 }
	end,
	[1002] = function(data, receipt)
		local next_data = table.clone(data)
		next_data.coins += 100
		next_data.last_purchase_id = receipt.PurchaseId
		return next_data, { granted = 100 }
	end,
	[1003] = function(data)
		local next_data = table.clone(data)
		next_data.coins += 1
		return next_data, { recordstore_internal_purchase_ledger_status_v1 = "capacity" }
	end,
})

local purchase = {
	PurchaseId = "purchase-001",
	PlayerId = 123,
	ProductId = 1001,
}
local granted = handler(purchase)
expect(granted == Enum.ProductPurchaseDecision.PurchaseGranted, "valid durable purchase was not granted")
expect(record:Get().coins == 25, "purchase grant was not committed to profile data")
local receipt_lookup = record:GetTransactionStatusAsync("purchase:" .. purchase.PurchaseId, {
	receipt_type = "developer_product",
	purchase_id = purchase.PurchaseId,
	player_id = purchase.PlayerId,
	product_id = purchase.ProductId,
})
expect(receipt_lookup.code == "committed" and receipt_lookup.result.granted == 25,
	"developer-product durable receipt could not be queried read-only")
expect(record:Get().last_purchase_id == purchase.PurchaseId, "grant reducer did not receive the validated receipt")
expect(grant_calls == 1, "grant reducer did not run exactly once")

local durable = Mock.get_record_raw("PurchaseReceiptProcessorRegression", "global", "player-123")
expect(
	durable.sidecars.transaction_receipts["purchase:" .. purchase.PurchaseId] ~= nil,
	"purchase receipt was not recorded durably with the profile mutation"
)

local duplicate_result = handler(purchase)
expect(duplicate_result == Enum.ProductPurchaseDecision.PurchaseGranted, "matching retry was not acknowledged as duplicate")
expect(record:Get().coins == 25, "duplicate purchase granted currency twice")
expect(grant_calls == 1, "duplicate purchase re-executed its grant reducer")

local conflicting_purchase = table.clone(purchase)
conflicting_purchase.ProductId = 1002
local conflict_result = handler(conflicting_purchase)
expect(conflict_result == Enum.ProductPurchaseDecision.NotProcessedYet, "receipt identity conflict was acknowledged")
expect(record:Get().coins == 25, "conflicting product mutated the profile")
expect(diagnostics[#diagnostics].category == "transaction_conflict", "receipt conflict was not diagnosed")

local absent_player_result = handler({
	PurchaseId = "purchase-absent-player",
	PlayerId = 404,
	ProductId = 1001,
})
expect(absent_player_result == Enum.ProductPurchaseDecision.NotProcessedYet, "missing active profile was acknowledged")

local unknown_product_result = handler({
	PurchaseId = "purchase-unknown-product",
	PlayerId = 123,
	ProductId = 9999,
})
expect(unknown_product_result == Enum.ProductPurchaseDecision.NotProcessedYet, "unconfigured product was acknowledged")

local malformed_result = handler({
	PurchaseId = "",
	PlayerId = 123,
	ProductId = 1001,
})
expect(malformed_result == Enum.ProductPurchaseDecision.NotProcessedYet, "malformed purchase ID was acknowledged")
expect(record:Get().coins == 25, "rejected receipt changed profile data")

local unsafe_player_receipt = table.clone(purchase)
unsafe_player_receipt.PurchaseId = "purchase-unsafe-player-id"
unsafe_player_receipt.PlayerId = 9007199254740992
expect(handler(unsafe_player_receipt) == Enum.ProductPurchaseDecision.NotProcessedYet,
	"receipt processor accepted a PlayerId beyond the safe-integer range")
local unsafe_product_receipt = table.clone(purchase)
unsafe_product_receipt.PurchaseId = "purchase-unsafe-product-id"
unsafe_product_receipt.ProductId = 9007199254740992
expect(handler(unsafe_product_receipt) == Enum.ProductPurchaseDecision.NotProcessedYet,
	"receipt processor accepted a ProductId beyond the safe-integer range")
expect(record:Get().coins == 25 and grant_calls == 1,
	"unsafe receipt identifiers mutated profile data or invoked a grant")

local marker_result = handler({
	PurchaseId = "purchase-marker-is-user-data",
	PlayerId = 123,
	ProductId = 1003,
})
expect(marker_result == Enum.ProductPurchaseDecision.PurchaseGranted,
	"an application reducer result using the ledger marker key changed no-ledger behavior")
expect(record:Get().coins == 26, "valid purchase with a marker-shaped result was not committed")

expect(not pcall(function()
	ReceiptProcessor.new({
		get_record = function()
			return record
		end,
		receipt_retention_seconds = 31536001,
	})
end), "receipt processor accepted a retention window beyond the transaction limit")

-- The permanent application-owned ledger remains effective after sidecar receipt expiry.
local ledger_record = Mock.new("PurchasePermanentLedgerRegression", "global", "player-123", {
	schema_version = 1,
	autosave_interval = 1000,
	lease_duration = 180,
	lease_renewal = 60,
	transactional_operations_enabled = true,
})
local ledger_open, ledger_open_message = ledger_record:Open({ coins = 0 })
expect(ledger_open == "created" or ledger_open == "loaded", tostring(ledger_open_message))
local ledger_records = { [123] = ledger_record }
local ledger_grants = 0
local ledger_processor = ReceiptProcessor.new({
	get_record = function(user_id) return ledger_records[user_id] end,
	receipt_retention_seconds = 1,
	permanent_purchase_ledger_key = "purchase_ledger",
	permanent_purchase_ledger_capacity = 2,
	permanent_purchase_ledger_migration_complete = true,
	on_diagnostic = function(diagnostic) table.insert(diagnostics, diagnostic) end,
})
local ledger_handler = ledger_processor:CreateHandler({
	[1001] = function(data)
		ledger_grants += 1
		local changed = table.clone(data)
		changed.coins += 10
		return changed, { granted = 10 }
	end,
	[1002] = function(data)
		local changed = table.clone(data)
		changed.coins += 100
		return changed, { granted = 100 }
	end,
	[1003] = function()
		return { "not-a-profile-map" }, { granted = 999 }
	end,
})
local ledger_clock = 1000
Mock.set_test_clock(function() return ledger_clock end)

-- A sidecar receipt from a pre-ledger processor cannot prove that the permanent
-- ledger was populated, so the upgraded processor must fail closed on that result.
local original_ledger_transact = ledger_record.TransactAsync
ledger_record.TransactAsync = function()
	return { granted = 10 }, "duplicate", nil
end
local unmarked_receipt = ledger_handler({
	PurchaseId = "permanent-legacy-unmarked",
	PlayerId = 123,
	ProductId = 1001,
})
expect(unmarked_receipt == Enum.ProductPurchaseDecision.NotProcessedYet,
	"ledger-enabled processor acknowledged a duplicate receipt without permanent-ledger proof")
expect(ledger_record:Get().coins == 0 and ledger_record:Get().purchase_ledger == nil,
	"unmarked legacy receipt mutated profile data or silently populated the ledger")
expect(diagnostics[#diagnostics].category == "permanent_purchase_ledger_marker_missing",
	"legacy receipt without ledger proof was not diagnosed")
ledger_record.TransactAsync = original_ledger_transact

local permanent_purchase = { PurchaseId = "permanent-001", PlayerId = 123, ProductId = 1001 }
expect(ledger_handler(permanent_purchase) == Enum.ProductPurchaseDecision.PurchaseGranted,
	"first permanently tracked purchase was not granted")
expect(ledger_record:Get().coins == 10 and ledger_grants == 1,
	"first permanently tracked purchase did not apply exactly one grant")
local invalid_shape_purchase = {
	PurchaseId = "permanent-invalid-map",
	PlayerId = 123,
	ProductId = 1003,
}
expect(ledger_handler(invalid_shape_purchase) == Enum.ProductPurchaseDecision.NotProcessedYet,
	"permanent ledger accepted a grant reducer that returned an array instead of a profile map")
expect(ledger_record:Get().coins == 10 and ledger_grants == 1,
	"invalid grant output mutated profile data")
expect(diagnostics[#diagnostics].category == "purchase_grant_rejected",
	"invalid grant output was not diagnosed")
expect(type(ledger_record:Get().purchase_ledger) == "table"
	and ledger_record:Get().purchase_ledger["permanent-001"].product_id == 1001,
	"permanent ledger did not record purchase identity atomically with the grant")
ledger_clock = 1002
expect(ledger_handler(permanent_purchase) == Enum.ProductPurchaseDecision.PurchaseGranted,
	"same purchase was not acknowledged after bounded transaction-receipt expiry")
expect(ledger_record:Get().coins == 10 and ledger_grants == 1,
	"permanent ledger failed to suppress a grant after transaction-receipt expiry")
ledger_clock = 1003
local permanent_conflict = table.clone(permanent_purchase)
permanent_conflict.ProductId = 1002
expect(ledger_handler(permanent_conflict) == Enum.ProductPurchaseDecision.NotProcessedYet,
	"permanent ledger acknowledged a purchase ID rebound to another product")
expect(ledger_record:Get().coins == 10 and ledger_grants == 1,
	"permanent-ledger identity conflict changed profile data")
local second_permanent = { PurchaseId = "permanent-002", PlayerId = 123, ProductId = 1001 }
expect(ledger_handler(second_permanent) == Enum.ProductPurchaseDecision.PurchaseGranted,
	"second distinct purchase did not fit in the configured permanent ledger")
expect(ledger_record:Get().coins == 20 and ledger_grants == 2,
	"second distinct purchase was not granted once")
local overflow_permanent = { PurchaseId = "permanent-003", PlayerId = 123, ProductId = 1001 }
expect(ledger_handler(overflow_permanent) == Enum.ProductPurchaseDecision.NotProcessedYet,
	"permanent purchase ledger overflow was acknowledged instead of failing closed")
expect(ledger_record:Get().coins == 20 and ledger_grants == 2,
	"ledger capacity failure mutated currency")
expect(diagnostics[#diagnostics].category == "permanent_purchase_ledger_capacity",
	"ledger capacity failure was not diagnosed")
expect(not pcall(function()
	ReceiptProcessor.new({
		get_record = function() return ledger_record end,
		receipt_retention_seconds = 60,
		permanent_purchase_ledger_capacity = 2,
	})
end), "ledger capacity was accepted without an application data field")
local blocked_ledger_processor = ReceiptProcessor.new({
	get_record = function() return ledger_record end,
	receipt_retention_seconds = 60,
	permanent_purchase_ledger_key = "purchase_ledger",
	on_diagnostic = function(diagnostic) table.insert(diagnostics, diagnostic) end,
})
local blocked_ledger_handler = blocked_ledger_processor:CreateHandler({
	[1001] = function(data)
		local changed = table.clone(data)
		changed.coins += 500
		return changed, { granted = 500 }
	end,
})
local blocked_ledger_decision = blocked_ledger_handler({
	PurchaseId = "permanent-migration-gate",
	PlayerId = 123,
	ProductId = 1001,
})
expect(blocked_ledger_decision == Enum.ProductPurchaseDecision.NotProcessedYet,
	"permanent-ledger receipt was acknowledged before historical PurchaseId reconciliation")
expect(ledger_record:Get().coins == 20 and ledger_grants == 2,
	"receipt without historical-migration acknowledgement mutated profile data")
expect(diagnostics[#diagnostics].category == "permanent_purchase_ledger_migration_required",
	"blocked permanent-ledger receipt was not diagnosed")
expect(not pcall(function()
	ReceiptProcessor.new({
		get_record = function() return ledger_record end,
		receipt_retention_seconds = 60,
		permanent_purchase_ledger_migration_complete = true,
	})
end), "migration acknowledgement was accepted without a permanent ledger key")
expect(not pcall(function()
	ReceiptProcessor.new({
		get_record = function() return ledger_record end,
		receipt_retention_seconds = 60,
		permanent_purchase_ledger_key = "__recordstore_bad",
		permanent_purchase_ledger_migration_complete = true,
	})
end), "reserved internal data namespace was accepted for the purchase ledger")
expect(ledger_record:Close() == "closed", "permanent purchase ledger profile did not close")
Mock.set_test_clock(function() return 1000 end)

local original_transact = record.TransactAsync
local original_status_lookup = record.GetTransactionStatusAsync
record.TransactAsync = function()
	return nil, "unknown", "injected unresolved transaction"
end
record.GetTransactionStatusAsync = function()
	return nil
end
local unresolved_result = handler({
	PurchaseId = "purchase-status-unavailable",
	PlayerId = 123,
	ProductId = 1001,
})
expect(unresolved_result == Enum.ProductPurchaseDecision.NotProcessedYet,
	"nil transaction-status lookup raised or incorrectly acknowledged an uncertain purchase")
expect(diagnostics[#diagnostics].category == "transaction_status_unresolved",
	"nil transaction-status lookup was not diagnosed as unresolved")
record.TransactAsync = original_transact
record.GetTransactionStatusAsync = original_status_lookup

record:Close()


-- Optional external authority adds a globally shared PurchaseId identity fence.
-- This regression is intentionally deferred until all implementation is present.
local authority_store = {}
local authority_faults = {
	drop_commit_response_once = false,
	fail_status_once = false,
}
local function authority_copy(entry)
	if entry == nil then return nil end
	return table.clone(entry)
end
local function authority_identity(purchase_id, player_id, product_id, status)
	return {
		PurchaseId = purchase_id,
		PlayerId = player_id,
		ProductId = product_id,
		Status = status,
	}
end
local authority = {}
function authority:ClaimAsync(purchase_id, player_id, product_id)
	local current = authority_store[purchase_id]
	if current ~= nil and (current.PlayerId ~= player_id or current.ProductId ~= product_id) then
		return authority_identity(purchase_id, player_id, product_id, "conflict")
	end
	if current ~= nil then return authority_copy(current) end
	current = authority_identity(purchase_id, player_id, product_id, "claimed")
	authority_store[purchase_id] = current
	return authority_copy(current)
end
function authority:CommitAsync(purchase_id, player_id, product_id, outcome)
	local current = authority_store[purchase_id]
	if current == nil then return nil, "claim does not exist" end
	if current.PlayerId ~= player_id or current.ProductId ~= product_id then
		return authority_identity(purchase_id, player_id, product_id, "conflict")
	end
	if current.Status == "claimed" then
		current.Status = "committed"
		current.Outcome = outcome
	end
	if authority_faults.drop_commit_response_once then
		authority_faults.drop_commit_response_once = false
		return nil, "injected lost commit response"
	end
	return authority_copy(current)
end
function authority:GetStatusAsync(purchase_id, player_id, product_id)
	if authority_faults.fail_status_once then
		authority_faults.fail_status_once = false
		return nil, "injected status outage"
	end
	local current = authority_store[purchase_id]
	if current == nil then return nil, "not_found" end
	if current.PlayerId ~= player_id or current.ProductId ~= product_id then
		return authority_identity(purchase_id, player_id, product_id, "conflict")
	end
	return authority_copy(current)
end
function authority:BackfillAsync(purchase_id, player_id, product_id)
	local current = authority_store[purchase_id]
	if current ~= nil and (current.PlayerId ~= player_id or current.ProductId ~= product_id) then
		return authority_identity(purchase_id, player_id, product_id, "conflict")
	end
	if current ~= nil then return authority_copy(current) end
	current = authority_identity(purchase_id, player_id, product_id, "committed")
	current.Outcome = "historical"
	authority_store[purchase_id] = current
	local imported = authority_copy(current)
	imported.Status = "imported"
	return imported
end

local authority_record = Mock.new("PurchaseExternalAuthorityRegression", "global", "player-321", {
	schema_version = 1,
	user_ids = { 321 },
	autosave_interval = 1000,
	lease_duration = 180,
	lease_renewal = 60,
	transactional_operations_enabled = true,
})
local authority_open, authority_open_message = authority_record:Open({
	coins = 0,
	purchase_ledger = {},
})
expect(authority_open == "created" or authority_open == "loaded", tostring(authority_open_message))
local authority_grants = 0
local authority_processor = ReceiptProcessor.new({
	get_record = function(user_id)
		return if user_id == 321 then authority_record else nil
	end,
	receipt_retention_seconds = 1,
	permanent_purchase_ledger_key = "purchase_ledger",
	permanent_purchase_ledger_capacity = 16,
	permanent_purchase_ledger_migration_complete = true,
	external_purchase_authority = authority,
	external_purchase_authority_migration_complete = true,
	on_diagnostic = function(diagnostic) table.insert(diagnostics, diagnostic) end,
})
local authority_handler = authority_processor:CreateHandler({
	[2001] = function(data)
		authority_grants += 1
		local changed = table.clone(data)
		changed.coins += 50
		return changed, { granted = 50 }
	end,
	[2002] = function(data)
		local changed = table.clone(data)
		changed.coins += 500
		return changed, { granted = 500 }
	end,
})
local external_purchase = {
	PurchaseId = "global-authority-001",
	PlayerId = 321,
	ProductId = 2001,
}
expect(authority_handler(external_purchase) == Enum.ProductPurchaseDecision.PurchaseGranted,
	"external-authority receipt did not commit")
expect(authority_grants == 1 and authority_record:Get().coins == 50,
	"external-authority receipt did not grant exactly once")
expect(authority_store[external_purchase.PurchaseId].Status == "committed"
	and authority_store[external_purchase.PurchaseId].Outcome == "granted",
	"external authority did not durably commit the profile grant")
expect(authority_handler(external_purchase) == Enum.ProductPurchaseDecision.PurchaseGranted,
	"committed external-authority duplicate was not acknowledged")
expect(authority_grants == 1 and authority_record:Get().coins == 50,
	"duplicate external-authority receipt granted twice")

local rebound_purchase = table.clone(external_purchase)
rebound_purchase.ProductId = 2002
expect(authority_handler(rebound_purchase) == Enum.ProductPurchaseDecision.NotProcessedYet,
	"global PurchaseId rebound to a different product was acknowledged")
expect(authority_record:Get().coins == 50 and authority_grants == 1,
	"global PurchaseId conflict mutated profile data")
expect(diagnostics[#diagnostics].category == "external_purchase_conflict",
	"global PurchaseId conflict was not diagnosed")

-- Simulate a committed external write whose response and immediate status lookup
-- are lost. The next receipt delivery must reconcile without granting twice.
local uncertain_external = {
	PurchaseId = "global-authority-ambiguous-001",
	PlayerId = 321,
	ProductId = 2001,
}
authority_faults.drop_commit_response_once = true
authority_faults.fail_status_once = true
expect(authority_handler(uncertain_external) == Enum.ProductPurchaseDecision.NotProcessedYet,
	"unconfirmed external commit was acknowledged despite lost response and status")
expect(authority_store[uncertain_external.PurchaseId].Status == "committed",
	"fault fixture failed to preserve the committed authority row")
expect(authority_handler(uncertain_external) == Enum.ProductPurchaseDecision.PurchaseGranted,
	"retry did not reconcile the already committed external receipt")
expect(authority_grants == 2 and authority_record:Get().coins == 100,
	"ambiguous external commit retry re-granted the profile transaction")

local historical_batch = {
	{ PurchaseId = "external-historical-001", PlayerId = 321, ProductId = 2001 },
}
local history_result = authority_processor:BackfillExternalAuthorityAsync(historical_batch, 1)
expect(history_result.code == "complete" and history_result.backfilled_count == 1,
	"external historical PurchaseId backfill did not complete")
local before_historical = authority_record:Get().coins
expect(authority_handler(historical_batch[1]) == Enum.ProductPurchaseDecision.PurchaseGranted,
	"historical external authority entry was not acknowledged")
expect(authority_record:Get().coins == before_historical and authority_grants == 2,
	"historical PurchaseId backfill accidentally granted the product again")
local conflicting_history = {
	{ PurchaseId = "external-history-conflict", PlayerId = 321, ProductId = 2001 },
	{ PurchaseId = "external-history-conflict", PlayerId = 322, ProductId = 2001 },
}
local conflict_backfill = authority_processor:BackfillExternalAuthorityAsync(conflicting_history, 2)
expect(conflict_backfill.code == "conflict",
	"external backfill accepted conflicting PurchaseId identities in a single batch")
expect(authority_store["external-history-conflict"] == nil,
	"external backfill wrote before validating the entire batch")

local blocked_authority_processor = ReceiptProcessor.new({
	get_record = function(user_id)
		return if user_id == 321 then authority_record else nil
	end,
	receipt_retention_seconds = 60,
	permanent_purchase_ledger_key = "purchase_ledger",
	permanent_purchase_ledger_capacity = 16,
	permanent_purchase_ledger_migration_complete = true,
	external_purchase_authority = authority,
	external_purchase_authority_migration_complete = false,
	on_diagnostic = function(diagnostic) table.insert(diagnostics, diagnostic) end,
})
local blocked_authority_handler = blocked_authority_processor:CreateHandler({
	[2001] = function(data)
		local changed = table.clone(data)
		changed.coins += 900
		return changed, { granted = 900 }
	end,
})
local blocked_authority_receipt = {
	PurchaseId = "external-migration-block",
	PlayerId = 321,
	ProductId = 2001,
}
expect(blocked_authority_handler(blocked_authority_receipt) == Enum.ProductPurchaseDecision.NotProcessedYet,
	"external authority receipt was processed before historical migration was confirmed")
expect(authority_store[blocked_authority_receipt.PurchaseId] == nil,
	"external authority claim was created before its migration gate passed")
expect(diagnostics[#diagnostics].category == "external_purchase_authority_migration_required",
	"external migration gate failure was not diagnosed")

expect(authority_record:Close() == "closed", "external authority fixture profile did not close")
