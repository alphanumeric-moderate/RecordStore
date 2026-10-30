--!strict

local ServerScriptService = game:GetService("ServerScriptService")
local RecordStore = require(ServerScriptService.RecordStore)

RecordStore.Mock.reset()

local store_name = "RecordStore_TransactionMutationReconciliation"
local scope = "global"

local function new_record(key: string)
	local record = RecordStore.Mock.new(store_name, scope, key, {
		schema_version = 1,
		autosave_interval = 1000,
		lease_duration = 180,
		lease_renewal = 60,
		operation_deadline = 20,
		retry_attempts = 3,
		transactional_operations_enabled = true,
	})
	local opened, message = record:Open({
		coins = 10,
		settings = { label = "initial" },
	})
	assert(opened == "created" or opened == "loaded", message)
	return record
end

local function increment_coins(
	current: RecordStore.JsonValue?,
	_input: RecordStore.JsonValue?
): (RecordStore.JsonValue?, RecordStore.JsonValue?)
	if type(current) ~= "table" then return nil, nil end
	local data = table.clone(current :: { [string]: RecordStore.JsonValue })
	data.coins = (data.coins :: number) + 10
	data.transaction_marker = true
	return data, { coins = data.coins }
end

local function assert_merged_data(record: any, expected_label: string)
	local data = record:Get() :: { [string]: any }
	assert(data.coins == 20, "transaction mutation was lost while merging newer local changes")
	assert(data.transaction_marker == true, "transaction result was not retained in local data")
	assert(type(data.settings) == "table" and data.settings.label == expected_label,
		"newer nested local mutation was overwritten during transaction reconciliation")
end

local committed = new_record("committed-during-mutation")
local committed_revision = committed:GetRevision()
RecordStore.Mock.set_before_next_update(function()
	local data = committed.Data :: { [string]: any }
	data.settings.label = "during-commit"
end)
local committed_result, committed_status, committed_message = committed:TransactAsync(
	"commit-with-concurrent-mutation",
	increment_coins,
	{ request = { kind = "increment-coins", amount = 10 } }
)
assert(committed_status == "committed", committed_message)
assert(type(committed_result) == "table", "committed transaction did not return its result")
assert_merged_data(committed, "during-commit")
assert(committed:IsDirty(), "post-flush mutation must remain dirty after transaction commit")
local committed_save, committed_save_message = committed:Save("transaction-concurrent-mutation")
assert(committed_save == "saved", committed_save_message)
local committed_durable = RecordStore.Mock.get_record_raw(store_name, scope, "committed-during-mutation") :: { [string]: any }
assert(committed_durable.revision == committed_revision + 2, "concurrent mutation was not saved after the transaction")
assert((committed_durable.data :: { [string]: any }).coins == 20,
	"later save overwrote the committed transaction mutation")
assert(((committed_durable.data :: { [string]: any }).settings :: { [string]: any }).label == "during-commit",
	"later save did not persist the concurrent local mutation")
local committed_close, committed_close_message = committed:Close()
assert(committed_close == "closed" or committed_close == "fenced", committed_close_message)

RecordStore.Mock.reset()

local duplicate = new_record("duplicate-during-mutation")
local duplicate_revision = duplicate:GetRevision()
local request: RecordStore.JsonValue = { kind = "increment-coins", amount = 10 }
RecordStore.Mock.set_update_commit_then_failures(1)
RecordStore.Mock.set_get_failures(100, "hold verification after transaction commit")
RecordStore.Mock.set_before_next_update(function()
	local data = duplicate.Data :: { [string]: any }
	data.settings.label = "during-first-attempt"
end)
local first_result, first_status, first_message = duplicate:TransactAsync(
	"commit-then-reconcile-with-mutation",
	increment_coins,
	{ request = request }
)
assert(first_status == "unknown", ("first transaction must remain unknown, got %s: %s"):format(
	tostring(first_status), tostring(first_message)))
assert(first_result == nil, "unverified transaction must not expose a confirmed result")
local first_durable = RecordStore.Mock.get_record_raw(store_name, scope, "duplicate-during-mutation") :: { [string]: any }
assert((first_durable.data :: { [string]: any }).coins == 20, "fault injection did not commit the transaction")
assert(first_durable.revision == duplicate_revision + 1, "uncertain transaction did not commit exactly one revision")

RecordStore.Mock.set_get_failures(0)
local retry_result, retry_status, retry_message = duplicate:TransactAsync(
	"commit-then-reconcile-with-mutation",
	increment_coins,
	{ request = request }
)
assert(retry_status == "duplicate", retry_message)
assert(type(retry_result) == "table", "verified duplicate did not return its original result")
assert_merged_data(duplicate, "during-first-attempt")
assert(duplicate:IsDirty(), "post-flush mutation must remain dirty after duplicate reconciliation")
local duplicate_save, duplicate_save_message = duplicate:Save("transaction-duplicate-concurrent-mutation")
assert(duplicate_save == "saved", duplicate_save_message)
local duplicate_durable = RecordStore.Mock.get_record_raw(store_name, scope, "duplicate-during-mutation") :: { [string]: any }
assert(duplicate_durable.revision == duplicate_revision + 2,
	"duplicate reconciliation must not repeat the transaction and the newer mutation must save once")
assert((duplicate_durable.data :: { [string]: any }).coins == 20,
	"duplicate reconciliation caused the transaction mutation to be applied more than once")
assert(((duplicate_durable.data :: { [string]: any }).settings :: { [string]: any }).label
	== "during-first-attempt", "duplicate reconciliation lost the newer local mutation")
local duplicate_close, duplicate_close_message = duplicate:Close()
assert(duplicate_close == "closed" or duplicate_close == "fenced", duplicate_close_message)

RecordStore.Mock.reset()
print("[PASS] Transaction reconciliation preserves post-flush mutations and committed transaction data.")
