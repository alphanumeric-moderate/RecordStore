--!nocheck
-- Exercises cross-profile transfer safety, ambiguous credit resolution and compensation recovery.
-- Uses a deterministic DataStore fake; it does not establish live multi-server guarantees.
local Shim = require("./RobloxShim")
local Fake = Shim.FakeDataStore
local RecordStore = Shim.load_isolated("saga-regression")
local V2Module = require("../src/PlayerDataInitializer/RecordStoreV2")
local MailboxV2 = require("../src/PlayerDataInitializer/RecordStoreMailboxV2")
local V2 = V2Module.new(RecordStore, MailboxV2, { allow_unattested_activation = true })

local now_ms = 1_800_000_000_000
Fake:Reset()
Fake:SetClock(function() return now_ms end)

local PROFILE_STORE = "RecordStoreSagaMatrixProfiles"
local SAGA_STORE = "RecordStoreSagaMatrixState"
local SCOPE = "global"
local ABORT_FIELD = "__recordstore_v2_transfer_credit_aborts"
local DECISION_FIELD = "__recordstore_v2_transfer_credit_decisions"
local RECEIVED_FIELD = "__recordstore_v2_received_transfers"
local passed = 0

local function group(name, callback)
	local ok, message = pcall(callback)
	assert(ok, ("[SAGA FAILURE MATRIX] %s failed: %s"):format(name, tostring(message)))
	passed += 1
end

local function new_record(key, balance)
	local record = RecordStore.new(PROFILE_STORE, SCOPE, key, {
		schema_version = 1,
		retry_attempts = 2,
		lease_duration = 60,
		lease_renewal = 10,
		operation_deadline = 5,
		user_ids = {},
		metadata = { fixture = "saga-regression" },
		messaging_enabled = false,
		takeover_enabled = false,
		autosave_interval = 3600,
		queue_poll_interval = 3600,
	})
	local code, message = record:Open({ Balance = balance, note = "saga fixture" })
	assert(code == "created" or code == "loaded", tostring(message))
	return record
end

local function new_saga()
	return V2.Sagas.new(Fake:GetDataStore(SAGA_STORE, SCOPE))
end

local function digest(text)
	local a, b = 5381, 1
	for i = 1, #text do
		local byte = string.byte(text, i)
		a = (a * 33 + byte) % 2147483647
		b = (b * 65599 + byte) % 2147483629
	end
	return tostring(#text) .. "-" .. string.format("%08x%08x", a, b)
end

local function transfer_operation(id, leg)
	return "rv2:transfer:" .. digest(id) .. ":" .. leg
end

local function proxy_record(base, intercept)
	local proxy = {}
	function proxy:Get() return base:Get() end
	function proxy:Stats() return base:Stats() end
	function proxy:TransactAsync(operation_id, ...)
		if intercept ~= nil then
			local handled, a, b = intercept(base, operation_id, ...)
			if handled then return a, b end
		end
		return base:TransactAsync(operation_id, ...)
	end
	return proxy
end

local function credit_request(id, amount, recipient_id)
	return { transfer_id = id, amount = amount, leg = "credit", recipient_id = recipient_id }
end

local function durable_late_credit(base, id, amount, recipient_id)
	local request = credit_request(id, amount, recipient_id)
	local material = V2.Canonicalize(request)
	return base:TransactAsync(transfer_operation(id, "credit"), digest(material), function(current)
		assert(type(current) == "table", "late credit received a non-table profile")
		local changed = table.clone(current)
		local aborts = changed[ABORT_FIELD] or {}
		if aborts[id] ~= nil then error("durable transfer-abort marker fences late credit") end
		local received = changed[RECEIVED_FIELD] or {}
		if received[id] ~= nil then
			assert(received[id] == amount, "late credit receipt conflicts")
			return changed
		end
		changed.Balance += amount
		received[id] = amount
		changed[RECEIVED_FIELD] = received
		local decisions = changed[DECISION_FIELD] or {}
		decisions[id] = { state = "credited", transfer_id = id, amount = amount, decided_at = os.time() }
		changed[DECISION_FIELD] = decisions
		return changed
	end, material)
end

local function balances(sender, recipient)
	return sender:Get().Balance, recipient:Get().Balance
end

group("01 successful transfer conserves value and repeated IDs are terminal", function()
	Fake:Reset()
	local sender = new_record("saga-success-source", 100)
	local recipient = new_record("saga-success-destination", 10)
	local saga = new_saga()
	local first = saga:TransferAsync("transfer-success-1", sender, recipient, 30, {
		sender_id = "source-user-1",
		recipient_id = "destination-user-1",
	})
	assert(first.code == "settled" and first.phase == "settled", "happy-path transfer did not settle: " .. tostring(first.message))
	local source_balance, destination_balance = balances(sender, recipient)
	assert(source_balance == 70 and destination_balance == 40, "settled transfer produced incorrect balances")
	assert(next(sender:Get().__recordstore_v2_escrow or {}) == nil, "settled transfer left source escrow")
	local duplicate = saga:TransferAsync("transfer-success-1", sender, recipient, 30, {
		sender_id = "source-user-1",
		recipient_id = "destination-user-1",
	})
	assert(duplicate.code == "settled", "repeated stable transfer ID did not return terminal settled state")
	local source_after, destination_after = balances(sender, recipient)
	assert(source_after == 70 and destination_after == 40, "repeated transfer changed balances")
end)

group("02 lost recipient-credit response resolves as credited, never refunded", function()
	Fake:Reset()
	local sender_base = new_record("saga-credit-loss-source", 100)
	local recipient_base = new_record("saga-credit-loss-destination", 5)
	local transfer_id = "transfer-credit-commit-response-loss"
	local amount = 23
	local recipient = proxy_record(recipient_base, function(base, operation_id, ...)
		if operation_id == transfer_operation(transfer_id, "credit") then
			local code, message = base:TransactAsync(operation_id, ...)
			assert(code == "success" or code == "duplicate", "fixture credit did not actually commit: " .. tostring(message))
			return true, "unknown", "injected lost response after recipient credit committed"
		end
		return false
	end)
	local sender = sender_base
	local saga = new_saga()
	local result = saga:TransferAsync(transfer_id, sender, recipient, amount, {
		sender_id = "source-credit-loss",
		recipient_id = "destination-credit-loss",
	})
	assert(result.code == "settled", "committed-but-unknown credit was not recovered: " .. tostring(result.message))
	local source_balance, destination_balance = balances(sender_base, recipient_base)
	assert(source_balance == 100 - amount and destination_balance == 5 + amount,
		"credit response loss caused duplicate value or source refund")
	assert(sender_base:Get()[ABORT_FIELD] == nil, "source unexpectedly received recipient abort metadata")
	assert(recipient_base:Get()[RECEIVED_FIELD][transfer_id] == amount, "recipient receipt was not durable")
	assert(recipient_base:Get()[DECISION_FIELD][transfer_id].state == "credited", "credit decision was not durable")
end)

group("03 uncertain pre-commit credit writes abort before refund and fence late credit", function()
	Fake:Reset()
	local sender = new_record("saga-late-credit-source", 100)
	local recipient_base = new_record("saga-late-credit-destination", 0)
	local transfer_id = "transfer-credit-abort-fence"
	local amount = 17
	local skip_credit_once = true
	local recipient = proxy_record(recipient_base, function(_base, operation_id, ...)
		if operation_id == transfer_operation(transfer_id, "credit") and skip_credit_once then
			skip_credit_once = false
			return true, "retry_exhausted", "injected unknown pre-commit recipient credit"
		end
		return false
	end)
	local saga = new_saga()
	local result = saga:TransferAsync(transfer_id, sender, recipient, amount, {
		sender_id = "source-late-credit",
		recipient_id = "destination-late-credit",
	})
	assert(result.code == "rejected" and result.phase == "rejected",
		"confirmed abort and compensation did not reach a rejected terminal state: " .. tostring(result.message))
	local source_balance, destination_balance = balances(sender, recipient_base)
	assert(source_balance == 100 and destination_balance == 0, "compensation did not restore exactly the source funds")
	local recipient_data = recipient_base:Get()
	assert(recipient_data[ABORT_FIELD][transfer_id].amount == amount, "recipient abort marker was not durable")
	assert(recipient_data[DECISION_FIELD][transfer_id].state == "aborted", "recipient abort decision was not durable")
	assert(recipient_data[RECEIVED_FIELD] == nil or recipient_data[RECEIVED_FIELD][transfer_id] == nil,
		"recipient unexpectedly received a credit before abort")

	local late_code, late_message = durable_late_credit(recipient_base, transfer_id, amount, "destination-late-credit")
	assert(late_code ~= "success" and late_code ~= "duplicate",
		"late recipient credit succeeded after source compensation: " .. tostring(late_message))
	local after_late_source, after_late_destination = balances(sender, recipient_base)
	assert(after_late_source == 100 and after_late_destination == 0, "late credit escaped the abort fence")
end)

group("04 refund failure resumes from refund_pending without re-crediting", function()
	Fake:Reset()
	local sender_base = new_record("saga-resume-refund-source", 80)
	local recipient_base = new_record("saga-resume-refund-destination", 0)
	local transfer_id = "transfer-resume-refund"
	local amount = 19
	local skip_credit_once = true
	local skip_refund_once = true
	local recipient = proxy_record(recipient_base, function(_base, operation_id, ...)
		if operation_id == transfer_operation(transfer_id, "credit") and skip_credit_once then
			skip_credit_once = false
			return true, "retry_exhausted", "injected credit failure"
		end
		return false
	end)
	local sender = proxy_record(sender_base, function(_base, operation_id, ...)
		if operation_id == transfer_operation(transfer_id, "refund") and skip_refund_once then
			skip_refund_once = false
			return true, "retry_exhausted", "injected refund failure"
		end
		return false
	end)
	local saga = new_saga()
	local first = saga:TransferAsync(transfer_id, sender, recipient, amount, {
		sender_id = "source-resume-refund",
		recipient_id = "destination-resume-refund",
	})
	assert(first.phase == "refund_pending" and first.code ~= "rejected",
		"uncommitted refund was reported as final rejection: " .. tostring(first.message))
	local after_first_source, after_first_destination = balances(sender_base, recipient_base)
	assert(after_first_source == 80 - amount and after_first_destination == 0,
		"source compensation happened despite the injected failed refund")
	assert(recipient_base:Get()[ABORT_FIELD][transfer_id] ~= nil, "refund-pending saga lost the recipient abort marker")

	local resumed = saga:RecoverAsync(transfer_id, sender, recipient, {
		sender_id = "source-resume-refund",
		recipient_id = "destination-resume-refund",
	})
	assert(resumed.code == "rejected" and resumed.phase == "rejected",
		"explicit saga recovery did not resume compensation: " .. tostring(resumed.message))
	local final_source, final_destination = balances(sender_base, recipient_base)
	assert(final_source == 80 and final_destination == 0, "resumed refund did not conserve value")
	local late_code = durable_late_credit(recipient_base, transfer_id, amount, "destination-resume-refund")
	assert(late_code ~= "success" and late_code ~= "duplicate", "late credit escaped the resumed abort fence")
	local duplicate = saga:RecoverAsync(transfer_id, sender, recipient, {
		sender_id = "source-resume-refund",
		recipient_id = "destination-resume-refund",
	})
	assert(duplicate.code == "rejected", "recovery did not preserve the terminal rejection")
	local repeated_source, repeated_destination = balances(sender_base, recipient_base)
	assert(repeated_source == 80 and repeated_destination == 0, "repeated recovery duplicated the refund")
end)

group("05 transfer ID binds immutable request identity", function()
	Fake:Reset()
	local sender = new_record("saga-request-conflict-source", 100)
	local recipient = new_record("saga-request-conflict-destination", 0)
	local saga = new_saga()
	local first = saga:TransferAsync("transfer-request-conflict", sender, recipient, 10, {
		sender_id = "source-conflict",
		recipient_id = "destination-conflict",
	})
	assert(first.code == "settled", "first request did not settle")
	local conflict = saga:TransferAsync("transfer-request-conflict", sender, recipient, 11, {
		sender_id = "source-conflict",
		recipient_id = "destination-conflict",
	})
	assert(conflict.code == "conflict", "stable transfer ID accepted a different amount")
	local source_balance, destination_balance = balances(sender, recipient)
	assert(source_balance == 90 and destination_balance == 10, "conflicting request changed balances")
end)

print(("[PASS] %d saga recovery and cross-profile compensation groups using the deterministic DataStore fake."):format(passed))
Shim.close()
