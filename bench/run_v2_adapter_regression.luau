--!nocheck
-- Contract tests for the V2 DataStore adapter and shared RecordStore request gate.
-- This runs against an explicit fake store; it does not prove live Roblox quotas or behavior.
local Adapter = require("../src/PlayerDataInitializer/RecordStoreV2DataStoreAdapter")

local request_calls = {}
local runner = {
	run_runtime_request = function(kind, callback, deadline, work_class)
		table.insert(request_calls, {
			kind = kind,
			deadline = deadline,
			work_class = work_class,
		})
		local ok, value = pcall(callback)
		if not ok then
			return nil, "request_failed", tostring(value)
		end
		return value, nil, nil
	end,
}

local key_info = {
	GetUserIds = function()
		return { 1234, 5678 }
	end,
	GetMetadata = function()
		return { schema = "v4", owner = "profile" }
	end,
}
local value = { balance = 10 }
local persisted_user_ids = { 1234, 5678 }
local persisted_metadata = { schema = "v4", owner = "profile" }
local update_callback_count = 0

local store = {
	GetAsync = function(_, key)
		assert(key == "valid-key", "GetAsync received an unexpected key")
		return value
	end,
	UpdateAsync = function(_, key, transform)
		assert(key == "valid-key", "UpdateAsync received an unexpected key")
		local next_value, next_user_ids, next_metadata
		for _ = 1, 2 do
			update_callback_count += 1
			next_value, next_user_ids, next_metadata = transform(value, key_info)
		end
		if next_value ~= nil then
			value = next_value
			persisted_user_ids = next_user_ids
			persisted_metadata = next_metadata
		end
		return value
	end,
}
local service = {
	GetDataStore = function(_, name, scope)
		assert(name == "AdapterRegressionStore", "unexpected DataStore name")
		assert(scope == "global", "unexpected DataStore scope")
		return store
	end,
}
local adapter = Adapter.new(runner, "AdapterRegressionStore", "global", 5000, service)

-- Read calls must use the shared gate and messaging work class.
local loaded = adapter:GetAsync("valid-key")
assert(loaded.balance == 10, "adapter read returned the wrong value")
assert(#request_calls == 1 and request_calls[1].kind == "read", "read bypassed the shared request gate")
assert(request_calls[1].deadline == 5000 and request_calls[1].work_class == "messaging",
	"read did not carry the deadline and messaging work class")

-- An UpdateAsync transform may replay, while prior key metadata and UserIds are preserved.
local saved = adapter:UpdateAsync("valid-key", function(current)
	return { balance = current.balance + 1 }
end)
assert(update_callback_count == 2, "adapter transform replay was not exercised by the fake store")
assert(saved.balance == 11, "replayed update applied the mutation incorrectly")
assert(#persisted_user_ids == 2 and persisted_user_ids[1] == 1234 and persisted_user_ids[2] == 5678,
	"adapter failed to preserve existing UserIds")
assert(persisted_metadata.schema == "v4" and persisted_metadata.owner == "profile",
	"adapter failed to preserve existing metadata")
assert(request_calls[2].kind == "update" and request_calls[2].work_class == "messaging",
	"update bypassed the shared request gate")

-- Explicit metadata/UserIds replacements must take effect; nil cancels a later update.
adapter:UpdateAsync("valid-key", function(current)
	return { balance = current.balance + 4 }, { 999 }, { schema = "v5" }
end)
assert(value.balance == 15 and #persisted_user_ids == 1 and persisted_user_ids[1] == 999,
	"explicit UserIds replacement was ignored")
assert(persisted_metadata.schema == "v5", "explicit metadata replacement was ignored")

local before_cancel = value.balance
adapter:UpdateAsync("valid-key", function()
	return nil
end)
assert(value.balance == before_cancel, "nil transform result changed the persisted value")

-- Invalid DataStore keys must be rejected before consuming request-gate capacity.
local calls_before_invalid = #request_calls
local invalid_ok = pcall(function()
	adapter:GetAsync(string.rep("k", 51))
end)
assert(not invalid_ok, "51-byte DataStore key was accepted")
assert(#request_calls == calls_before_invalid, "invalid key consumed request-gate capacity")

local stats = adapter:Stats()
assert(stats.request_gate == "RecordStore shared runtime governor", "adapter stats hid the shared gate")
assert(stats.physical_delete_supported == false, "adapter unexpectedly advertises physical deletion")

print("[PASS] V2 DataStore adapter request gating, key bounds, UpdateAsync replay, and metadata/UserIds preservation.")
