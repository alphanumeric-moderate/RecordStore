--!strict

local ServerScriptService = game:GetService("ServerScriptService")
local RecordStore = require(ServerScriptService.RecordStore)

RecordStore.Mock.reset()

local store_name = "RecordStore_TransactionMutationReconciliation"
local scope = "global"

local function new_record(key: string, initial_data: RecordStore.JsonValue?)
	local record = RecordStore.Mock.new(store_name, scope, key, {
		schema_version = 1,
		autosave_interval = 1000,
		lease_duration = 180,
		lease_renewal = 60,
		operation_deadline = 20,
		retry_attempts = 1,
		transactional_operations_enabled = true,
	})
	local opened, message = record:Open(initial_data or {
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

local preflush = new_record("direct-edit-before-transaction")
local preflush_revision = preflush:GetRevision()
local preflush_data_ref = preflush.Data :: { [string]: any }
preflush_data_ref.settings.label = "before-transaction"
local preflush_result, preflush_status, preflush_message = preflush:TransactAsync(
	"flush-direct-edit-before-transaction",
	increment_coins,
	{ request = { kind = "increment-coins", amount = 10 } }
)
assert(preflush_status == "committed", preflush_message)
assert(type(preflush_result) == "table", "pre-flush transaction did not return its result")
local preflush_data = preflush:Get() :: { [string]: any }
assert(preflush_data.coins == 20 and preflush_data.transaction_marker == true,
	"transaction did not apply after the direct-edit prerequisite flush")
assert(preflush_data.settings.label == "before-transaction",
	"direct record.Data edit made before TransactAsync was not flushed")
assert(not preflush:IsDirty(), "prerequisite direct edit should be included in the transaction's clean baseline")
local preflush_durable = RecordStore.Mock.get_record_raw(store_name, scope, "direct-edit-before-transaction") :: { [string]: any }
assert(preflush_durable.revision == preflush_revision + 2,
	"direct edit should flush once before the transaction commit")
assert(((preflush_durable.data :: { [string]: any }).settings :: { [string]: any }).label == "before-transaction",
	"prerequisite flush did not persist the direct edit")
local preflush_close, preflush_close_message = preflush:Close()
assert(preflush_close == "closed" or preflush_close == "fenced", preflush_close_message)

RecordStore.Mock.reset()

local array_record = new_record("array-mutation-during-commit", {
	coins = 10,
	inventory = { "first", "second" },
	settings = { label = "initial" },
})
local function append_transaction_item(
	current: RecordStore.JsonValue?,
	_input: RecordStore.JsonValue?
): (RecordStore.JsonValue?, RecordStore.JsonValue?)
	if type(current) ~= "table" then return nil, nil end
	local data = table.clone(current :: { [string]: RecordStore.JsonValue })
	local inventory = table.clone(data.inventory :: { RecordStore.JsonValue })
	table.insert(inventory, "transaction-item")
	data.inventory = inventory
	data.coins = (data.coins :: number) + 10
	return data, { coins = data.coins }
end
RecordStore.Mock.set_before_next_update(function()
	local data = array_record.Data :: { [string]: any }
	table.remove(data.inventory, 1)
end)
local array_result, array_status, array_message = array_record:TransactAsync(
	"array-merge-is-atomic",
	append_transaction_item,
	{ request = { kind = "array-update", amount = 10 } }
)
assert(array_status == "committed", array_message)
assert(type(array_result) == "table", "array transaction did not return its result")
local array_data = array_record:Get() :: { [string]: any }
assert(array_data.coins == 20, "array reconciliation lost the non-array transaction update")
assert(#array_data.inventory == 1 and array_data.inventory[1] == "second",
	"array reconciliation must preserve the newer local array atomically without creating holes")
assert(array_record:IsDirty(), "concurrent array mutation must remain dirty")
local array_save, array_save_message = array_record:Save("transaction-array-atomic")
assert(array_save == "saved", array_save_message)
local array_durable = RecordStore.Mock.get_record_raw(store_name, scope, "array-mutation-during-commit") :: { [string]: any }
local durable_inventory = (array_durable.data :: { [string]: any }).inventory :: { string }
assert(#durable_inventory == 1 and durable_inventory[1] == "second",
	"array save produced a sparse or incorrectly merged durable array")
local array_close, array_close_message = array_record:Close()
assert(array_close == "closed" or array_close == "fenced", array_close_message)

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
