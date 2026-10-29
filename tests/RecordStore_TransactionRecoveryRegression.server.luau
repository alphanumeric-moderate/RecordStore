--!strict

local ServerScriptService = game:GetService("ServerScriptService")
local RecordStore = require(ServerScriptService.RecordStore)

RecordStore.Mock.reset()

local store_name = "RecordStore_TransactionRecoveryRegression"
local scope = "global"
local profile_key = "commit-then-error"
local operation_id = "transaction-commit-then-error"
local request: RecordStore.JsonValue = { kind = "increment-coins", amount = 10 }
local record = RecordStore.Mock.new(store_name, scope, profile_key, {
	schema_version = 1,
	autosave_interval = 1000,
	lease_duration = 180,
	lease_renewal = 60,
	operation_deadline = 20,
	retry_attempts = 3,
	transactional_operations_enabled = true,
})

local open_result, open_message = record:Open({ coins = 10, label = "initial" })
assert(open_result == "created" or open_result == "loaded", open_message)
local base_revision = record:GetRevision()

local function increment_coins(
	current: RecordStore.JsonValue?,
	_input: RecordStore.JsonValue?
): (RecordStore.JsonValue?, RecordStore.JsonValue?)
	if type(current) ~= "table" then return nil, nil end
	local data = current :: { [string]: RecordStore.JsonValue }
	data.coins = (data.coins :: number) + 10
	return data, { coins = data.coins }
end

RecordStore.Mock.set_update_commit_then_failures(1)
RecordStore.Mock.set_get_failures(100, "hold verification after transaction commit")
local first_result, first_status, first_message = record:TransactAsync(
	operation_id,
	increment_coins,
	{ request = request }
)
assert(first_status == "unknown",
	("committed transaction with unavailable verification must remain unknown, got %s: %s"):format(
		first_status,
		tostring(first_message)
	))
assert(first_result == nil, "unverified transaction must not expose a confirmed result")
assert(record.State == "unknown", "unverified transaction must retain the unknown state")

local durable = RecordStore.Mock.get_record_raw(store_name, scope, profile_key) :: { [string]: any }
assert((durable.data :: { [string]: any }).coins == 20,
	"fault injection did not commit the transaction before losing its response")
assert(durable.revision == base_revision + 1, "uncertain transaction should commit exactly one revision")

RecordStore.Mock.set_get_failures(0)
local retry_result, retry_status, retry_message = record:TransactAsync(
	operation_id,
	increment_coins,
	{ request = request }
)
assert(retry_status == "duplicate", retry_message)
assert(type(retry_result) == "table" and (retry_result :: { [string]: any }).coins == 20,
	"retry did not return the original transaction receipt")
assert(record.State == "active", "verified duplicate receipt did not restore active state")
assert(record:GetRevision() == base_revision + 1, "retry duplicated the committed revision")
assert((record:Get() :: { [string]: any }).coins == 20,
	"retry did not refresh the local profile from the durable transaction envelope")

local receipt_status = record:GetTransactionStatusAsync(operation_id, request)
assert(receipt_status.code == "committed", "transaction receipt lookup did not confirm the commit")
assert(receipt_status.result_present == true, "transaction receipt result was not preserved")
assert(type(receipt_status.result) == "table"
	and (receipt_status.result :: { [string]: any }).coins == 20,
	"transaction receipt lookup returned a result different from the committed transaction")

local duplicate_result, duplicate_status, duplicate_message = record:TransactAsync(
	operation_id,
	increment_coins,
	{ request = request }
)
assert(duplicate_status == "duplicate", duplicate_message)
assert(type(duplicate_result) == "table" and (duplicate_result :: { [string]: any }).coins == 20,
	"subsequent duplicate call did not return the stable result")
assert((RecordStore.Mock.get_record_raw(store_name, scope, profile_key) :: { [string]: any }).revision
	== base_revision + 1, "subsequent duplicate call wrote another revision")

local close_result, close_message = record:Close()
assert(close_result == "closed" or close_result == "fenced", close_message)
RecordStore.Mock.reset()

print("[PASS] Transaction recovery preserves durable state and the original idempotent receipt after response loss.")
