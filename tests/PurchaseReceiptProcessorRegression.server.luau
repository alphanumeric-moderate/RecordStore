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
	receipt_retention_seconds = 60,
	permanent_purchase_ledger_key = "purchase_ledger",
	permanent_purchase_ledger_capacity = 2,
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
ledger_clock = 2000
expect(ledger_handler(permanent_purchase) == Enum.ProductPurchaseDecision.PurchaseGranted,
	"same purchase was not acknowledged after bounded transaction-receipt expiry")
expect(ledger_record:Get().coins == 10 and ledger_grants == 1,
	"permanent ledger failed to suppress a grant after transaction-receipt expiry")
ledger_clock = 3000
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
expect(not pcall(function()
	ReceiptProcessor.new({
		get_record = function() return ledger_record end,
		receipt_retention_seconds = 60,
		permanent_purchase_ledger_key = "__recordstore_bad",
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
