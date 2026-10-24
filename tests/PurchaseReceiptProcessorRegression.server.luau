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

expect(not pcall(function()
	ReceiptProcessor.new({
		get_record = function()
			return record
		end,
		receipt_retention_seconds = 31536001,
	})
end), "receipt processor accepted a retention window beyond the transaction limit")

record:Close()
