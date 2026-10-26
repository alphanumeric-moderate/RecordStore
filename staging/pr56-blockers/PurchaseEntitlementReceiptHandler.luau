--!strict

local Handler = {}

export type ReceiptDecision = {
	action: string,
	status: string,
	message: string?,
}

export type Coordinator = {
	HandlesProduct: (self: Coordinator, product_id: unknown) -> boolean,
	Process: (self: Coordinator, receipt: unknown) -> ReceiptDecision,
}

export type ReceiptHandler = (receipt_info: unknown) -> EnumItem

local function not_processed_yet(): EnumItem
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

function Handler.new(coordinator: Coordinator, fallback: ReceiptHandler): ReceiptHandler
	if type(coordinator) ~= "table"
		or type(coordinator.HandlesProduct) ~= "function"
		or type(coordinator.Process) ~= "function"
	then
		error("coordinator must implement HandlesProduct and Process", 2)
	end
	if type(fallback) ~= "function" then error("fallback receipt handler is required", 2) end

	return function(receipt_info: unknown): EnumItem
		local product_id: unknown = if type(receipt_info) == "table"
			then (receipt_info :: { [string]: unknown }).ProductId else nil
		local route_ok, handles_product = pcall(function()
			return coordinator:HandlesProduct(product_id)
		end)
		if not route_ok then return not_processed_yet() end
		if handles_product == false then
			local fallback_ok, fallback_decision = pcall(fallback, receipt_info)
			if not fallback_ok then return not_processed_yet() end
			if fallback_decision == Enum.ProductPurchaseDecision.PurchaseGranted then
				return Enum.ProductPurchaseDecision.PurchaseGranted
			end
			return not_processed_yet()
		end
		if handles_product ~= true then return not_processed_yet() end

		local process_ok, result = pcall(function()
			return coordinator:Process(receipt_info)
		end)
		if not process_ok or type(result) ~= "table" then return not_processed_yet() end
		local decision = result :: ReceiptDecision
		if decision.action == "acknowledge"
			and (decision.status == "grant_committed" or decision.status == "duplicate_grant_reconciled")
		then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
		return not_processed_yet()
	end
end

return table.freeze(Handler)
