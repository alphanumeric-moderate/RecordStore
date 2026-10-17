--!strict
-- Production DataStore adapter for RecordStoreMailboxV2.
-- All reads/updates pass through RecordStore's shared request gate.
-- Physical deletion is intentionally not exposed; callers must use generation/tombstone fencing.

local DataStoreAdapter = {}
DataStoreAdapter.__index = DataStoreAdapter

type RequestRunner = {
	run_runtime_request: (
		kind: string,
		callback: () -> unknown,
		operation_deadline: number?,
		work_class: string?
	) -> (unknown, string?, string?),
}
type Store = {
	GetAsync: (self: Store, key: string) -> unknown,
	UpdateAsync: (self: Store, key: string, transform: (unknown, unknown?) -> (unknown, { number }?, { [string]: (boolean | number | string) }?)) -> unknown,
}
type Adapter = typeof(setmetatable({} :: {
	record_store: RequestRunner,
	store: Store,
	operation_deadline: number?,
	store_name: string,
	scope: string,
}, DataStoreAdapter))

local function valid_text(value: unknown, maximum: number): boolean
	return type(value) == "string" and value ~= "" and #value <= maximum
end

local function validate_key(key: unknown): (boolean, string?)
	if not valid_text(key, 50) then
		return false, "DataStore key must be 1 to 50 bytes"
	end
	return true, nil
end

function DataStoreAdapter.new(
	record_store: RequestRunner,
	store_name: string,
	scope: string,
	operation_deadline: number?,
	data_store_service: unknown?
): Adapter
	if type(record_store) ~= "table" or type(record_store.run_runtime_request) ~= "function" then
		error("RecordStoreV2DataStoreAdapter requires RecordStore.run_runtime_request", 2)
	end
	if not valid_text(store_name, 50) then error("store_name must be 1 to 50 bytes", 2) end
	if not valid_text(scope, 50) then error("scope must be 1 to 50 bytes", 2) end
	if operation_deadline ~= nil and (
		type(operation_deadline) ~= "number"
		or not math.isfinite(operation_deadline)
		or operation_deadline <= 0
	) then
		error("operation_deadline must be a positive finite number", 2)
	end

	local service = data_store_service or game:GetService("DataStoreService")
	if type(service) ~= "table" and typeof(service) ~= "Instance" then
		error("data_store_service is invalid", 2)
	end
	local store = service:GetDataStore(store_name, scope)
	if store == nil then error("GetDataStore returned no store", 2) end

	return setmetatable({
		record_store = record_store,
		store = store,
		operation_deadline = operation_deadline,
		store_name = store_name,
		scope = scope,
	}, DataStoreAdapter) :: Adapter
end

local function run_request(self: Adapter, kind: string, callback: () -> unknown): unknown
	local value, code, message = self.record_store.run_runtime_request(
		kind,
		callback,
		self.operation_deadline,
		"messaging"
	)
	if code ~= nil then
		error(("RecordStore request gate returned %s: %s"):format(tostring(code), tostring(message or "")), 3)
	end
	return value
end

function DataStoreAdapter.GetAsync(self: Adapter, key: string): unknown
	local valid, message = validate_key(key)
	if not valid then error(message, 2) end
	return run_request(self, "read", function()
		return self.store:GetAsync(key)
	end)
end

function DataStoreAdapter.UpdateAsync(
	self: Adapter,
	key: string,
	transform: (unknown, unknown?) -> (unknown, { number }?, { [string]: (boolean | number | string) }?)
): unknown
	local valid, message = validate_key(key)
	if not valid then error(message, 2) end
	if type(transform) ~= "function" then error("transform must be a function", 2) end
	return run_request(self, "update", function()
		return self.store:UpdateAsync(key, function(raw, key_info)
			-- The adapter's transform stays synchronous and may be re-executed by Roblox.
			local next_value, user_ids, metadata = transform(raw, key_info)
			if next_value == nil then return nil end
			-- Preserve existing key metadata unless the protocol explicitly returns replacements.
			if key_info ~= nil then
				if user_ids == nil then user_ids = key_info:GetUserIds() end
				if metadata == nil then metadata = key_info:GetMetadata() end
			end
			return next_value, user_ids, metadata
		end)
	end)
end

function DataStoreAdapter.Stats(self: Adapter): { [string]: unknown }
	return {
		store_name = self.store_name,
		scope = self.scope,
		request_gate = "RecordStore shared runtime governor",
		physical_delete_supported = false,
	}
end

return DataStoreAdapter
