--!nocheck
local Shim = require("./RobloxShim")
local RecordStore = Shim.load()
local V2Module = require(
	game:GetService("ServerScriptService"):WaitForChild("PlayerDataInitializer"):WaitForChild("RecordStoreV2")
)
local V2 = V2Module.new(RecordStore, RecordStore.MailboxV2)

local function expect(value, message)
	assert(value, message)
end

local function clone(value, depth)
	depth = depth or 0
	assert(depth <= 64, "test store value exceeds depth bound")
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in pairs(value) do result[clone(key, depth + 1)] = clone(child, depth + 1) end
	return result
end

local function new_store()
	local values = {}
	local store = { values = values, fail_after_next_update = false, update_calls = 0 }
	function store:GetAsync(key)
		return clone(self.values[key]), nil
	end
	function store:UpdateAsync(key, transform)
		self.update_calls += 1
		local next_value = transform(clone(self.values[key]))
		if next_value ~= nil then self.values[key] = clone(next_value) end
		if self.fail_after_next_update then
			self.fail_after_next_update = false
			error("injected response loss after durable update")
		end
		return clone(if next_value == nil then self.values[key] else next_value), nil
	end
	return store
end

local function assert_leg_outcome(sagas_service, transfer_id, leg, state)
	local status = sagas_service:GetStatus(transfer_id)
	local outcome = type(status.leg_outcomes) == "table" and status.leg_outcomes[leg] or nil
	expect(type(outcome) == "table" and outcome.state == state,
		("transfer %s did not persist %s leg state %s"):format(transfer_id, leg, state))
	return outcome
end

local policy_status, policy_message = V2.ApplyRuntimePolicy({
	revision = 2,
	max_dirty_age_seconds = 120,
})
expect(policy_status == "success", "versioned runtime policy rejected: " .. tostring(policy_message))
local runtime_snapshot = V2.GetRuntimeSnapshot()
expect(runtime_snapshot.policy.revision == 2 and runtime_snapshot.policy.max_dirty_age_seconds == 120,
	"runtime snapshot did not reflect the validated policy")
expect(type(runtime_snapshot.scheduler) == "table", "runtime snapshot omitted the core scheduler snapshot")
expect(V2.ApplyRuntimePolicy({ revision = 2, max_dirty_age_seconds = 120 }) == "invalid",
	"runtime policy accepted a stale revision")
expect(V2.ApplyRuntimePolicy({ revision = 3, max_dirty_age_seconds = math.huge }) == "invalid",
	"runtime policy accepted a non-finite dirty-age threshold")

local trace_store = new_store()
local trace_a_id = 0
local tracer = V2.Tracing.new({
	max_events = 16, success_sample_every = 1, store = trace_store,
	new_event_id = function() trace_a_id += 1; return "trace-a-" .. tostring(trace_a_id) end,
})
local trace_ok = tracer:Emit({
	operation_id = "operation-1", correlation_id = "correlation-1", causation_id = "cause-1",
	component = "transaction", operation = "commit", result = "unknown", duration_ms = 27,
	timestamp_unix = 1700000000,
	payload = { private = "must not be stored" }, player_name = "must not be stored",
})
expect(trace_ok == true, "trace event was rejected")
local local_trace = tracer:GetOperationTrace("correlation-1", 8)
expect(local_trace.code == "success" and #local_trace.events == 1, "local trace could not be queried by correlation ID")
expect(local_trace.events[1].payload == nil and local_trace.events[1].player_name == nil,
	"trace captured raw payload or player identity")
expect(local_trace.events[1].evidence_source == "process_local"
	and local_trace.evidence_summary.process_local_events == 1,
	"local trace did not label its process-local evidence")
local flush = tracer:FlushAsync("operation-1", 8)
expect(flush.code == "committed", "durable trace flush failed: " .. tostring(flush.message))

local trace_b = V2.Tracing.new({
	max_events = 16, success_sample_every = 1, store = trace_store,
	new_event_id = function() return "trace-b-1" end,
})
expect(trace_b:Emit({
	operation_id = "operation-1", correlation_id = "correlation-1",
	component = "mailbox", operation = "claim", result = "unknown", duration_ms = 19,
	timestamp_unix = 1700000000,
}), "second process trace event was rejected")
local cross_process_flush = trace_b:FlushAsync("operation-1", 8)
expect(cross_process_flush.code == "committed" and cross_process_flush.retained == 2,
	"traces from separate processes collided on their local sequence numbers")
local durable_trace = tracer:GetOperationTraceAsync("operation-1", 8)
expect(durable_trace.durable_read == "success" and #durable_trace.events == 2,
	"durable trace read/merge dropped an event from another process")
expect(durable_trace.events[1].payload == nil and durable_trace.events[2].payload == nil,
	"durable trace stored raw payload data")
expect(durable_trace.events[1].evidence_source == "durable_store_and_local"
	and durable_trace.events[2].evidence_source == "durable_store",
	"merged traces did not distinguish persisted evidence from local-only observations")
expect(durable_trace.evidence_summary.process_local_events == 1
	and durable_trace.evidence_summary.process_local_only_events == 0,
	"trace evidence summary did not count the locally observed durable event")
expect(durable_trace.evidence_summary.durable_events == 2
	and durable_trace.evidence_summary.durable_only_events == 1
	and durable_trace.evidence_summary.durable_and_local_events == 1,
	"durable trace evidence summary did not count unique persisted events consistently")

local transaction_contract_record = RecordStore.Mock.new("V2TransactionContract", "global", "primary", {
	schema_version = 1, transactional_operations_enabled = true,
})
local transaction_contract_open, transaction_contract_message = transaction_contract_record:Open({ Balance = 0 })
expect(transaction_contract_open == "created" or transaction_contract_open == "loaded",
	"transaction contract Record open failed: " .. tostring(transaction_contract_message))
local transaction_reducer_calls = 0
local transaction_contract_request = { amount = 7, reason = "test" }
local transaction_contract = V2.Transactions.Run(
	transaction_contract_record, "v2-transaction-contract-001", transaction_contract_request,
	function(current, request)
		transaction_reducer_calls += 1
		local updated = clone(current)
		updated.Balance += request.amount
		return updated
	end
)
expect(transaction_contract.code == "committed" and transaction_contract.result.Balance == 7,
	"V2 transaction wrapper did not expose the durable Record transaction result: " .. tostring(transaction_contract.code))
local transaction_contract_duplicate = V2.Transactions.Run(
	transaction_contract_record, "v2-transaction-contract-001", transaction_contract_request,
	function(current, request)
		transaction_reducer_calls += 1
		local updated = clone(current)
		updated.Balance += request.amount
		return updated
	end
)
expect(transaction_contract_duplicate.code == "duplicate",
	"V2 transaction retry did not use the public RecordStore idempotency receipt")
expect(transaction_reducer_calls == 1 and transaction_contract_record:Get().Balance == 7,
	"V2 transaction retry reapplied the reducer")

local inbox_contract_record = RecordStore.Mock.new("V2InboxContract", "global", "primary", {
	schema_version = 1, transactional_operations_enabled = true,
})
local inbox_contract_open, inbox_contract_message = inbox_contract_record:Open({ total = 0 })
expect(inbox_contract_open == "created" or inbox_contract_open == "loaded",
	"inbox contract Record open failed: " .. tostring(inbox_contract_message))
local inbox_contract = V2.Inbox.ApplyBatch(
	inbox_contract_record, "inbox-contract-batch-001",
	{ { message_id = "inbox-contract-message-001", message_type = "delta", payload = { amount = 4 }, payload_version = 1 } },
	function(current, payload)
		local updated = clone(current)
		updated.total += payload.amount
		return updated
	end
)
expect(inbox_contract.code == "committed" and inbox_contract.applied == 1,
	"V2 inbox batch did not commit mutation plus its idempotency receipt: " .. tostring(inbox_contract.code))
local inbox_duplicate = V2.Inbox.ApplyBatch(
	inbox_contract_record, "inbox-contract-batch-001",
	{ { message_id = "inbox-contract-message-001", message_type = "delta", payload = { amount = 4 }, payload_version = 1 } },
	function(current, payload)
		local updated = clone(current)
		updated.total += payload.amount
		return updated
	end
)
expect(inbox_duplicate.code == "duplicate" and inbox_contract_record:Get().total == 4,
	"V2 inbox batch replay duplicated its profile mutation")

local outbox_contract_record = RecordStore.Mock.new("V2OutboxTransactionContract", "global", "primary", {
	schema_version = 1, transactional_operations_enabled = true,
})
local outbox_contract_open, outbox_contract_message = outbox_contract_record:Open({ Balance = 0 })
expect(outbox_contract_open == "created" or outbox_contract_open == "loaded",
	"outbox contract Record open failed: " .. tostring(outbox_contract_message))
local outbox_transaction = V2.Transactions.CommitWithOutbox(
	outbox_contract_record, "v2-outbox-contract-001", { reason = "credit", amount = 9 },
	function(current, request)
		local updated = clone(current)
		updated.Balance += request.amount
		return updated
	end,
	{ {
		type = "balance.changed",
		payload_version = 1,
		payload = { amount = 9 },
		target_store = "V2OutboxTransactionContract",
		target_scope = "global",
		target_key = "destination",
		target_user_id = 456,
	} }
)
expect(outbox_transaction.code == "committed" and outbox_transaction.result.Balance == 9,
	"V2 outbox transaction did not atomically commit the mutation and intent: " .. tostring(outbox_transaction.code))
local outbox_events = outbox_contract_record:GetOutboxAsync(4)
expect(type(outbox_events) == "table" and #outbox_events == 1,
	"V2 outbox transaction omitted its durable outbox intent")
local outbox_revision_before_invalid = outbox_contract_record:GetRevision()
local invalid_outbox_key = V2.Transactions.CommitWithOutbox(
	outbox_contract_record, string.rep("x", 65), { reason = "too long", amount = 1 },
	function(current, request)
		local updated = clone(current)
		updated.Balance += request.amount
		return updated
	end,
	{ {
		type = "balance.changed", payload_version = 1, payload = { amount = 1 },
		target_store = "V2OutboxTransactionContract", target_scope = "global", target_key = "destination",
	} }
)
expect(invalid_outbox_key.code == "invalid"
	and outbox_contract_record:GetRevision() == outbox_revision_before_invalid
	and outbox_contract_record:Get().Balance == 9,
	"oversized V2 outbox id was not rejected before transaction mutation")
expect(outbox_contract_record:Close() == "closed", "outbox transaction contract Record did not close")
expect(inbox_contract_record:Close() == "closed", "inbox contract Record did not close")
expect(transaction_contract_record:Close() == "closed", "transaction contract Record did not close")

local sender = RecordStore.Mock.new("V2SagaProfiles", "global", "sender", {
	schema_version = 1, transactional_operations_enabled = true,
})
local recipient = RecordStore.Mock.new("V2SagaProfiles", "global", "recipient", {
	schema_version = 1, transactional_operations_enabled = true,
})
local sender_open, sender_open_message = sender:Open({ Balance = 100 })
local recipient_open, recipient_open_message = recipient:Open({ Balance = 25 })
expect(sender_open == "created" or sender_open == "loaded", "sender open failed: " .. tostring(sender_open_message))
expect(recipient_open == "created" or recipient_open == "loaded", "recipient open failed: " .. tostring(recipient_open_message))
local saga_store = new_store()
local sagas = V2.Sagas.new(saga_store)
local transfer = sagas:TransferAsync("transfer-stable-001", sender, recipient, 15, {
	sender_id = "sender", recipient_id = "recipient",
})
expect(transfer.code == "settled", "transfer saga did not settle: " .. tostring(transfer.code) .. " " .. tostring(transfer.message))
expect(sender:Get().Balance == 85 and recipient:Get().Balance == 40,
	"settled transfer violated balance conservation")
local settled_transfer_status = sagas:GetStatus("transfer-stable-001")
for _, leg in ipairs({ "reserve", "credit", "settle" }) do
	assert_leg_outcome(sagas, "transfer-stable-001", leg, "committed")
end
local duplicate_transfer = sagas:TransferAsync("transfer-stable-001", sender, recipient, 15, {
	sender_id = "sender", recipient_id = "recipient",
})
expect(duplicate_transfer.code == "settled", "settled saga retry was not idempotent")
expect(sender:Get().Balance == 85 and recipient:Get().Balance == 40,
	"duplicate transfer changed balances")
local conflicting_transfer = sagas:TransferAsync("transfer-stable-001", sender, recipient, 20, {
	sender_id = "sender", recipient_id = "recipient",
})
expect(conflicting_transfer.code == "conflict", "saga ID reuse with a different request was accepted")

saga_store.fail_after_next_update = true
local response_loss_transfer = sagas:TransferAsync("transfer-response-loss-002", sender, recipient, 5, {
	sender_id = "sender", recipient_id = "recipient",
})
expect(response_loss_transfer.code == "settled",
	"saga failed to reconcile response loss after durable state creation: " .. tostring(response_loss_transfer.code))
expect(sender:Get().Balance == 80 and recipient:Get().Balance == 45,
	"saga response-loss recovery did not conserve balances")
local durable_transfer_status = sagas:GetStatus("transfer-response-loss-002")
expect(durable_transfer_status.code == "settled", "saga status read did not return the durable terminal phase")

local terminal_loss_store = new_store()
local terminal_loss_sagas = V2.Sagas.new(terminal_loss_store)
local terminal_loss_enabled = true
local terminal_base_update = terminal_loss_store.UpdateAsync
terminal_loss_store.UpdateAsync = function(self, key, transform)
	return terminal_base_update(self, key, function(old)
		local proposed = transform(old)
		if terminal_loss_enabled and type(proposed) == "table"
			and proposed.transfer_id == "transfer-terminal-unknown-003" and proposed.phase == "settled"
		then
			terminal_loss_enabled = false
			error("injected pre-commit rejection of terminal saga state")
		end
		return proposed
	end)
end
local uncertain_terminal = terminal_loss_sagas:TransferAsync(
	"transfer-terminal-unknown-003", sender, recipient, 2,
	{ sender_id = "sender", recipient_id = "recipient" }
)
expect(uncertain_terminal.code == "unknown" and uncertain_terminal.phase == "credited",
	"saga reported a terminal phase that was not durably committed")
local uncertain_terminal_status = terminal_loss_sagas:GetStatus("transfer-terminal-unknown-003")
expect(uncertain_terminal_status.phase == "credited",
	"saga status did not retain the last durable phase after an uncommitted terminal update")
expect(sender:Get().Balance == 78 and recipient:Get().Balance == 47,
	"uncertain terminal status changed the already-applied transfer legs")
local terminal_request = {
	transfer_id = "transfer-terminal-unknown-003",
	sender_id = "sender",
	recipient_id = "recipient",
	amount = 2,
	balance_field = "Balance",
}
local manual_request = terminal_loss_sagas:RequireManualResolutionAsync(
	"transfer-terminal-unknown-003", terminal_request, "credited", "pending",
	"manual-request-003", "operator-7", "terminal state needs durable profile verification"
)
expect(manual_request.code == "committed" and manual_request.phase == "manual_resolution_required",
	"saga did not durably enter the explicit manual-resolution state")
local duplicate_manual_request = terminal_loss_sagas:RequireManualResolutionAsync(
	"transfer-terminal-unknown-003", terminal_request, "credited", "pending",
	"manual-request-003", "operator-7", "terminal state needs durable profile verification"
)
expect(duplicate_manual_request.code == "duplicate",
	"manual-resolution request retry was not idempotent")
local conflicting_manual_request = terminal_loss_sagas:RequireManualResolutionAsync(
	"transfer-terminal-unknown-003", terminal_request, "credited", "pending",
	"manual-request-003", "operator-7", "changed reason under the same manual-request ID"
)
expect(conflicting_manual_request.code == "conflict",
	"manual request ID reuse with a changed reason was incorrectly accepted as duplicate")
local blocked_transfer_retry = terminal_loss_sagas:TransferAsync(
	"transfer-terminal-unknown-003", sender, recipient, 2,
	{ sender_id = "sender", recipient_id = "recipient" }
)
expect(blocked_transfer_retry.code == "manual_resolution_required",
	"normal saga retry bypassed the explicit manual-resolution state")
local stale_manual_resolution = terminal_loss_sagas:ResolveManualAsync(
	"transfer-terminal-unknown-003", terminal_request, "wrong-manual-request", "manual-result-003",
	"confirm_settled", "operator-8", "stale review request",
	function() return true, "evidence-should-not-be-used" end
)
expect(stale_manual_resolution.code == "conflict",
	"manual resolution accepted a mismatched durable manual-request ID")
local rejected_manual_verification = terminal_loss_sagas:ResolveManualAsync(
	"transfer-terminal-unknown-003", terminal_request, "manual-request-003", "manual-result-003",
	"confirm_settled", "operator-8", "profile receipts have not been reconciled",
	function() return false, "missing-durable-evidence" end
)
expect(rejected_manual_verification.code == "verification_failed"
	and terminal_loss_sagas:GetStatus("transfer-terminal-unknown-003").phase == "manual_resolution_required",
	"manual terminal resolution did not fail closed when the verifier rejected the outcome")
local confirmed_manual_resolution = terminal_loss_sagas:ResolveManualAsync(
	"transfer-terminal-unknown-003", terminal_request, "manual-request-003", "manual-result-003",
	"confirm_settled", "operator-8", "verified durable settlement evidence",
	function(state, decision)
		if decision ~= "confirm_settled" or state.transfer_id ~= "transfer-terminal-unknown-003" then return false end
		local sender_data = sender:Get()
		local recipient_data = recipient:Get()
		local escrow = sender_data.__recordstore_v2_escrow
		local receipts = recipient_data.__recordstore_v2_received_transfers
		if type(escrow) == "table" and escrow[state.transfer_id] ~= nil then return false end
		if type(receipts) ~= "table" or receipts[state.transfer_id] ~= state.amount then return false end
		return true, "verified-profile-state:" .. state.transfer_id
	end
)
expect(confirmed_manual_resolution.code == "committed" and confirmed_manual_resolution.phase == "settled",
	"manual resolution did not durably record its verified terminal outcome")
local durable_manual_resolution = terminal_loss_sagas:GetStatus("transfer-terminal-unknown-003")
expect(durable_manual_resolution.manual_resolution.resolution.operator_id == "operator-8"
	and durable_manual_resolution.manual_resolution.resolution.evidence_id == "verified-profile-state:transfer-terminal-unknown-003",
	"manual resolution did not persist the operator audit and evidence reference")
local transition_history = durable_manual_resolution.transition_history
expect(type(transition_history) == "table" and #transition_history >= 2 and #transition_history <= 32,
	"saga did not persist a bounded durable phase/status transition history")
local saw_manual_transition, saw_settled_transition = false, false
for _, transition in ipairs(transition_history) do
	if transition.from_phase == "credited" and transition.to_phase == "manual_resolution_required" then
		saw_manual_transition = true
	end
	if transition.from_phase == "manual_resolution_required" and transition.to_phase == "settled" then
		saw_settled_transition = true
	end
end
expect(saw_manual_transition and saw_settled_transition,
	"saga transition history omitted the manual pause or verified settlement")
local previous_transition_attempt = 0
for _, transition in ipairs(transition_history) do
	expect(transition.attempt > previous_transition_attempt,
		"saga transition history must be strictly increasing, but may have gaps between transitions")
	previous_transition_attempt = transition.attempt
end
local duplicate_manual_resolution = terminal_loss_sagas:ResolveManualAsync(
	"transfer-terminal-unknown-003", terminal_request, "manual-request-003", "manual-result-003",
	"confirm_settled", "operator-8", "verified durable settlement evidence",
	function() error("duplicate resolution must not invoke the verifier again") end
)
expect(duplicate_manual_resolution.code == "duplicate",
	"manual resolution retry did not return its stable duplicate outcome")
local conflicting_manual_resolution = terminal_loss_sagas:ResolveManualAsync(
	"transfer-terminal-unknown-003", terminal_request, "manual-request-003", "manual-result-003",
	"confirm_settled", "operator-9", "different reason under the same resolution ID",
	function() error("conflicting resolution must be rejected before verifier invocation") end
)
expect(conflicting_manual_resolution.code == "conflict",
	"resolution ID reuse with changed operator/reason was incorrectly accepted as duplicate")
expect(sender:Get().Balance == 78 and recipient:Get().Balance == 47,
	"manual resolution altered a profile balance")
local resumed_terminal = terminal_loss_sagas:TransferAsync(
	"transfer-terminal-unknown-003", sender, recipient, 2,
	{ sender_id = "sender", recipient_id = "recipient" }
)
expect(resumed_terminal.phase == "settled" and terminal_loss_sagas:GetStatus("transfer-terminal-unknown-003").phase == "settled",
	"confirmed saga did not remain settled on retry")
expect(sender:Get().Balance == 78 and recipient:Get().Balance == 47,
	"retry after manual resolution applied a transfer leg more than once")

local function new_leg_pair(store_name)
	local source = RecordStore.Mock.new(store_name, "global", "sender", {
		schema_version = 1, transactional_operations_enabled = true,
	})
	local target = RecordStore.Mock.new(store_name, "global", "recipient", {
		schema_version = 1, transactional_operations_enabled = true,
	})
	local source_open, source_message = source:Open({ Balance = 100 })
	local target_open, target_message = target:Open({ Balance = 25 })
	expect(source_open == "created" or source_open == "loaded", "leg-test sender open failed: " .. tostring(source_message))
	expect(target_open == "created" or target_open == "loaded", "leg-test recipient open failed: " .. tostring(target_message))
	return source, target
end

local function inject_post_commit_unknown(record, suffix)
	local original = record.TransactAsync
	local armed = true
	record.TransactAsync = function(self, operation_id, reducer, options)
		local result, status, message = original(self, operation_id, reducer, options)
		if armed and type(operation_id) == "string"
			and string.sub(operation_id, -#suffix) == suffix and status == "committed"
		then
			armed = false
			return nil, "unknown", "injected post-commit response loss for " .. suffix
		end
		return result, status, message
	end
	return function() return not armed end
end

do
	local source, target = new_leg_pair("V2SagaReserveResponseLoss")
	local source_loss_seen = inject_post_commit_unknown(source, ":reserve")
	local saga_service = V2.Sagas.new(new_store())
	local initial = saga_service:TransferAsync("reserve-loss", source, target, 100, {
		sender_id = "sender", recipient_id = "recipient",
	})
	expect(initial.code == "reconciliation_required",
		"reserve response loss was not surfaced as unresolved: " .. tostring(initial.code))
	expect(source:Get().Balance == 0 and target:Get().Balance == 25,
		"reserve response-loss fixture did not commit only the reservation leg")
	expect(assert_leg_outcome(saga_service, "reserve-loss", "reserve", "unknown").attempts == 1,
		"reserve response loss was not recorded durably")
	local resumed = saga_service:TransferAsync("reserve-loss", source, target, 100, {
		sender_id = "sender", recipient_id = "recipient",
	})
	expect(source_loss_seen() and resumed.code == "settled" and source:Get().Balance == 0 and target:Get().Balance == 125,
		"reserve retry did not reconcile its stable operation ID without re-reserving")
	expect(assert_leg_outcome(saga_service, "reserve-loss", "reserve", "committed").attempts == 2,
		"reserve duplicate reconciliation did not update the durable leg outcome")
	expect(source:Close() == "closed" and target:Close() == "closed", "reserve response-loss records did not close")
end

do
	local source, target = new_leg_pair("V2SagaCreditResponseLoss")
	local credit_loss_seen = inject_post_commit_unknown(target, ":credit")
	local saga_service = V2.Sagas.new(new_store())
	local initial = saga_service:TransferAsync("credit-loss", source, target, 10, {
		sender_id = "sender", recipient_id = "recipient",
	})
	expect(initial.code == "reconciliation_required",
		"credit response loss was not surfaced as unresolved: " .. tostring(initial.code))
	expect(source:Get().Balance == 90 and target:Get().Balance == 35,
		"credit response-loss fixture violated the reserved balance transition")
	expect(assert_leg_outcome(saga_service, "credit-loss", "credit", "unknown").attempts == 1,
		"credit response loss was not recorded durably")
	local resumed = saga_service:TransferAsync("credit-loss", source, target, 10, {
		sender_id = "sender", recipient_id = "recipient",
	})
	expect(credit_loss_seen() and resumed.code == "settled" and source:Get().Balance == 90 and target:Get().Balance == 35,
		"credit retry did not reconcile the durable receipt without granting twice")
	expect(assert_leg_outcome(saga_service, "credit-loss", "credit", "committed").attempts == 2,
		"credit duplicate reconciliation did not update the durable leg outcome")
	expect(source:Close() == "closed" and target:Close() == "closed", "credit response-loss records did not close")
end

do
	local source, target = new_leg_pair("V2SagaSettleResponseLoss")
	local settle_loss_seen = inject_post_commit_unknown(source, ":settle")
	local saga_service = V2.Sagas.new(new_store())
	local initial = saga_service:TransferAsync("settle-loss", source, target, 10, {
		sender_id = "sender", recipient_id = "recipient",
	})
	expect(initial.code == "reconciliation_required",
		"settlement response loss was not surfaced as unresolved: " .. tostring(initial.code))
	expect(source:Get().Balance == 90 and target:Get().Balance == 35,
		"settlement response-loss fixture violated balance conservation")
	expect(assert_leg_outcome(saga_service, "settle-loss", "settle", "unknown").attempts == 1,
		"settlement response loss was not recorded durably")
	local resumed = saga_service:TransferAsync("settle-loss", source, target, 10, {
		sender_id = "sender", recipient_id = "recipient",
	})
	expect(settle_loss_seen() and resumed.code == "settled" and source:Get().Balance == 90 and target:Get().Balance == 35,
		"settlement retry did not reconcile the durable source escrow receipt")
	expect(assert_leg_outcome(saga_service, "settle-loss", "settle", "committed").attempts == 2,
		"settlement duplicate reconciliation did not update the durable leg outcome")
	expect(source:Close() == "closed" and target:Close() == "closed", "settlement response-loss records did not close")
end

do
	local source, target = new_leg_pair("V2SagaRefundResponseLoss")
	local saga_store = new_store()
	local saga_service = V2.Sagas.new(saga_store)
	local source_base = source.TransactAsync
	local refund_loss_armed = true
	local compensation_phase_was_durable_before_refund = false
	source.TransactAsync = function(self, operation_id, reducer, options)
		if type(operation_id) == "string" and string.sub(operation_id, -#":refund") == ":refund" then
			compensation_phase_was_durable_before_refund = saga_service:GetStatus("refund-loss").phase == "compensation_pending"
			expect(compensation_phase_was_durable_before_refund,
				"refund operation started before compensation_pending was durable")
		end
		local result, status, message = source_base(self, operation_id, reducer, options)
		if refund_loss_armed and type(operation_id) == "string"
			and string.sub(operation_id, -#":refund") == ":refund" and status == "committed"
		then
			refund_loss_armed = false
			return nil, "unknown", "injected post-commit refund response loss"
		end
		return result, status, message
	end
	local target_base = target.TransactAsync
	local credit_attempts, reject_credit_once = 0, true
	target.TransactAsync = function(self, operation_id, reducer, options)
		if type(operation_id) == "string" and string.sub(operation_id, -#":credit") == ":credit" then
			credit_attempts += 1
			if reject_credit_once then
				reject_credit_once = false
				return nil, "invalid", "injected definitive credit rejection"
			end
		end
		return target_base(self, operation_id, reducer, options)
	end
	local initial = saga_service:TransferAsync("refund-loss", source, target, 10, {
		sender_id = "sender", recipient_id = "recipient",
	})
	expect(initial.code == "reconciliation_required"
		and saga_service:GetStatus("refund-loss").phase == "compensation_pending",
		"refund response loss did not enter the dedicated compensation-pending phase")
	expect(source:Get().Balance == 100 and target:Get().Balance == 25
		and (source:Get().__recordstore_v2_escrow or {})["refund-loss"] == nil,
		"refund response-loss fixture did not durably restore the source balance")
	expect(assert_leg_outcome(saga_service, "refund-loss", "credit", "failed").attempts == 1
		and assert_leg_outcome(saga_service, "refund-loss", "refund", "unknown").attempts == 1,
		"failed credit and uncertain refund outcomes were not durably recorded")
	local resumed = saga_service:TransferAsync("refund-loss", source, target, 10, {
		sender_id = "sender", recipient_id = "recipient",
	})
	expect(refund_loss_armed == false and resumed.code == "rejected"
		and saga_service:GetStatus("refund-loss").phase == "rejected",
		"refund recovery did not reach a durable rejected terminal phase")
	expect(credit_attempts == 1 and source:Get().Balance == 100 and target:Get().Balance == 25,
		"compensation recovery incorrectly retried credit after refund might have committed")
	expect(assert_leg_outcome(saga_service, "refund-loss", "refund", "committed").attempts == 2,
		"refund retry did not reconcile its stable receipt")
	expect(source:Close() == "closed" and target:Close() == "closed", "refund response-loss records did not close")
end

local projection_store = new_store()
local projections = V2.Projections.new(projection_store)
local registered = projections:Register("balance_projection_v1", 1, function(current, event)
	local updated = clone(current)
	updated.total = (updated.total or 0) + event.amount
	return updated
end, { source = "profile-outbox" })
expect(registered == true, "projection registration failed")
local projection_event = { event_id = "projection-event-1", entity_id = "user-1", source_revision = 1, amount = 10 }
local projection_result = projections:ApplyAsync("balance_projection_v1", projection_event)
expect(projection_result.code == "committed", "projection application failed: " .. tostring(projection_result.code))
local duplicate_projection = projections:ApplyAsync("balance_projection_v1", projection_event)
expect(duplicate_projection.code == "duplicate", "projection duplicate was reapplied")
local projected = projections:GetAsync("balance_projection_v1", "user-1")
expect(projected.code == "success" and projected.row.value.total == 10,
	"projection did not retain its idempotent value")
local conflicting_projection_event = projections:ApplyAsync("balance_projection_v1", {
	event_id = "projection-event-1", entity_id = "user-1", source_revision = 1, amount = 999,
})
expect(conflicting_projection_event.code == "conflict",
	"projection reused an event ID for a different payload without conflict")
local unchanged_projection = projections:GetAsync("balance_projection_v1", "user-1")
expect(unchanged_projection.code == "success" and unchanged_projection.row.value.total == 10,
	"conflicting projection event mutated the materialized value")
local rebuild_store = new_store()
local rebuild_projections = V2.Projections.new(rebuild_store)
expect(rebuild_projections:Register("durable_balance_v1", 1, function(current, event)
	local updated = clone(current)
	updated.total = (updated.total or 0) + event.amount
	return updated
end) == true, "durable rebuild projection registration failed")
local function read_rebuild_page(cursor, _maximum, snapshot_id)
	if snapshot_id ~= "snapshot-17" then error("unexpected snapshot ID") end
	if cursor == nil then
		return {
			{ event_id = "rebuild-e1", entity_id = "entity-a", source_revision = 1, amount = 3 },
		}, "page-2", false, snapshot_id
	end
	if cursor == "page-2" then
		return {
			{ event_id = "rebuild-e2", entity_id = "entity-a", source_revision = 2, amount = 4 },
		}, nil, true, snapshot_id
	end
	error("unexpected rebuild cursor")
end
local first_rebuild_page = rebuild_projections:RebuildDurableAsync(
	"durable_balance_v1", "rebuild-stable-1", "snapshot-17", read_rebuild_page, 1
)
expect(first_rebuild_page.code == "incomplete" and first_rebuild_page.status == "in_progress"
	and first_rebuild_page.cursor == "page-2" and first_rebuild_page.pages == 1,
	"durable projection rebuild did not checkpoint its bounded page cursor")
local durable_rebuild_status = rebuild_projections:GetRebuildStatusAsync("durable_balance_v1", "rebuild-stable-1")
expect(durable_rebuild_status.code == "success" and durable_rebuild_status.cursor == "page-2"
	and durable_rebuild_status.source_snapshot_id == "snapshot-17",
	"durable projection rebuild status did not expose its saved cursor and snapshot")
local restarted_rebuild_projections = V2.Projections.new(rebuild_store)
expect(restarted_rebuild_projections:Register("durable_balance_v1", 1, function(current, event)
	local updated = clone(current)
	updated.total = (updated.total or 0) + event.amount
	return updated
end) == true, "restarted rebuild projection registration failed")
local resumed_rebuild = restarted_rebuild_projections:RebuildDurableAsync(
	"durable_balance_v1", "rebuild-stable-1", "snapshot-17", read_rebuild_page, 1
)
expect(resumed_rebuild.code == "committed" and resumed_rebuild.status == "completed"
	and resumed_rebuild.processed == 2,
	"durable projection rebuild did not resume and persist terminal status")
local completed_rebuild_status = restarted_rebuild_projections:GetRebuildStatusAsync("durable_balance_v1", "rebuild-stable-1")
expect(completed_rebuild_status.code == "success" and completed_rebuild_status.status == "completed"
	and completed_rebuild_status.cursor == nil,
	"completed projection rebuild status is not durable")
local wrong_snapshot = restarted_rebuild_projections:RebuildDurableAsync(
	"durable_balance_v1", "rebuild-stable-1", "snapshot-18", read_rebuild_page, 1
)
expect(wrong_snapshot.code == "conflict",
	"durable rebuild ID was reused with a different source snapshot")

local malformed_rebuild_store = new_store()
local malformed_rebuilds = V2.Projections.new(malformed_rebuild_store)
expect(malformed_rebuilds:Register("malformed_cursor_v1", 1, function(current, event)
	local updated = clone(current)
	updated.total = (updated.total or 0) + event.amount
	return updated
end) == true, "malformed cursor projection registration failed")
local missing_cursor_page = malformed_rebuilds:RebuildDurableAsync(
	"malformed_cursor_v1", "rebuild-missing-cursor", "snapshot-17",
	function() return {}, nil, false, "snapshot-17" end,
	1
)
expect(missing_cursor_page.code == "invalid" and missing_cursor_page.status == "blocked",
	"durable rebuild accepted an incomplete page without a continuation cursor")
expect(malformed_rebuilds:GetRebuildStatusAsync("malformed_cursor_v1", "rebuild-missing-cursor").status == "blocked",
	"durable rebuild did not persist its malformed page contract failure")
local extra_cursor_page = malformed_rebuilds:RebuildDurableAsync(
	"malformed_cursor_v1", "rebuild-extra-cursor", "snapshot-17",
	function() return {}, "unexpected-page", true, "snapshot-17" end,
	1
)
expect(extra_cursor_page.code == "invalid" and extra_cursor_page.status == "blocked",
	"durable rebuild accepted a completed page with a continuation cursor")
projection_store.fail_after_next_update = true
local response_loss_projection = projections:ApplyAsync("balance_projection_v1", {
	event_id = "projection-event-2", entity_id = "user-1", source_revision = 2, amount = 5,
})
expect(response_loss_projection.code == "committed" and response_loss_projection.reconciled == true,
	"projection did not reconcile commit-then-response-loss")
local unique_first = projections:ReserveUnique("username", "barcode", "user-1", "reserve-1")
local unique_duplicate = projections:ReserveUnique("username", "barcode", "user-1", "reserve-1")
local unique_conflict = projections:ReserveUnique("username", "barcode", "user-2", "reserve-2")
expect(unique_first.code == "committed" and unique_duplicate.code == "duplicate" and unique_conflict.code == "conflict",
	"unique projection reservation outcomes were incorrect")

local erase_store = new_store()
local deleted_items = {}
local families = {
	{
		name = "player_profiles",
		templates = {
			{ name = "PlayerData", scope = "global", key = "Player_{user_id}" },
			{ name = "PlayerData", scope = "global", key = "PlayerArchive_{user_id}" },
		},
		templates_verified = true,
		inventory = function(user_id, maximum)
			return {
				{ name = "PlayerData", scope = "global", key = "Player_" .. tostring(user_id), generation = 4 },
				{ name = "PlayerData", scope = "global", key = "PlayerArchive_" .. tostring(user_id), generation = 8 },
			}, true
		end,
		fence_user = function() return true end,
		dependencies_clear = function() return true end,
		redact_or_delete_if_generation = function(item, user_id, erasure_id)
			deleted_items[#deleted_items + 1] = { key = item.key, user_id = user_id, erasure_id = erasure_id }
			return "deleted"
		end,
	},
}
local erasure = V2.Erasure.new(erase_store, families, {
	verify_templates = function(_user_id, rendered) return type(rendered) == "table" and #rendered == 2 end,
})
local erasure_plan = erasure:PlanAsync(123456, "erase-stable-1")
expect(erasure_plan.code == "success" and erasure_plan.rtbf_coverage_verified == true,
	"verified erasure plan was not recorded")
local partial_erasure = erasure:ExecuteAsync(123456, "erase-stable-1", 1)
expect(partial_erasure.code == "incomplete" and partial_erasure.cursor == 1,
	"bounded erasure execution did not checkpoint its first item")
local retried_erasure_plan = erasure:PlanAsync(123456, "erase-stable-1")
expect(retried_erasure_plan.cursor == 1 and #retried_erasure_plan.entries == 2
	and retried_erasure_plan.status == "in_progress",
	"replanning an in-progress erasure reset its durable cursor or inventory")
local erasure_result = erasure:ExecuteAsync(123456, "erase-stable-1", 1)
expect(erasure_result.code == "committed" and erasure_result.completed_count == 2,
	"bounded erasure execution did not complete after resuming")
expect(#deleted_items == 2 and deleted_items[1].key == "Player_123456"
	and deleted_items[2].key == "PlayerArchive_123456",
	"erasure failed to invoke each generation-aware deletion adapter")
expect(erasure:GetStatus(123456).status == "completed", "erasure manifest status was not durable")

expect(not pcall(function()
	V2.Erasure.new(new_store(), {
		{
			name = "underspecified_family",
			templates = { { key = "Player_{user_id}" } },
		},
	})
end), "erasure accepted a key-only template that wildcarded DataStore name and scope")

local unmatched_deleted = 0
local unmatched_erasure = V2.Erasure.new(new_store(), {
	{
		name = "profile_family",
		templates = { { name = "PlayerData", scope = "global", key = "Player_{user_id}" } },
		templates_verified = true,
		inventory = function(user_id)
			return { { name = "UnexpectedStore", scope = "global", key = "Orphan_" .. tostring(user_id), generation = 2 } }, true
		end,
		fence_user = function() return true end,
		redact_or_delete_if_generation = function()
			unmatched_deleted += 1
			return "deleted"
		end,
	},
}, { verify_templates = function() return true end })
local unmatched_plan = unmatched_erasure:PlanAsync(777, "erase-unmatched")
expect(unmatched_plan.code == "success" and unmatched_plan.rtbf_coverage_verified == false
	and unmatched_plan.coverage.profile_family.status == "unmatched_inventory"
	and unmatched_plan.coverage.profile_family.unmatched_count == 1,
	"erasure did not report an inventory locator that matched no verified template")
local unmatched_execution = unmatched_erasure:ExecuteAsync(777, "erase-unmatched", 8)
expect(unmatched_execution.code == "coverage_unverified" and unmatched_deleted == 0,
	"erasure executed a destructive delete with an inventory locator outside the verified templates")
expect(unmatched_erasure:GetStatus(777).status == "planned",
	"unverified erasure advanced its durable manifest")
local unmatched_is_erased, unmatched_status = unmatched_erasure:IsErased(777)
expect(unmatched_is_erased == true and unmatched_status.status == "planned",
	"planned erasure did not continue to fence restoration while coverage is unresolved")

local legacy_completed_store = new_store()
legacy_completed_store.values["rv2erase-u780"] = {
	version = 1, user_id = 780, erasure_id = "legacy-incomplete-completion",
	status = "completed", cursor = 0, completed_count = 0, entries = {}, coverage = {},
	rtbf_coverage_verified = false,
}
local legacy_completed_erasure = V2.Erasure.new(legacy_completed_store, {}, {
	verify_templates = function() return false end,
})
local legacy_erased, legacy_erasure_status = legacy_completed_erasure:IsErased(780)
expect(legacy_erased == nil and legacy_erasure_status.code == "coverage_unverified",
	"legacy completed manifest without RTBF coverage proof was reported as erased")
local legacy_execute = legacy_completed_erasure:ExecuteAsync(780, "legacy-incomplete-completion", 8)
expect(legacy_execute.code == "coverage_unverified",
	"legacy completed manifest without RTBF coverage proof was reported as committed")

local incomplete_deleted = 0
local incomplete_erasure = V2.Erasure.new(new_store(), {
	{
		name = "partial_family",
		templates = { { name = "PlayerData", scope = "global", key = "Player_{user_id}" } },
		templates_verified = true,
		inventory = function(user_id)
			return { { name = "PlayerData", scope = "global", key = "Player_" .. tostring(user_id), generation = 1 } }, false
		end,
		fence_user = function() return true end,
		redact_or_delete_if_generation = function()
			incomplete_deleted += 1
			return "deleted"
		end,
	},
}, { verify_templates = function() return true end })
local incomplete_plan = incomplete_erasure:PlanAsync(778, "erase-incomplete")
expect(incomplete_plan.rtbf_coverage_verified == false
	and incomplete_plan.coverage.partial_family.status == "inventory_incomplete",
	"erasure claimed complete coverage without an explicit exhaustive inventory acknowledgement")
local incomplete_execution = incomplete_erasure:ExecuteAsync(778, "erase-incomplete", 8)
expect(incomplete_execution.code == "coverage_unverified" and incomplete_deleted == 0,
	"erasure deleted from a partial inventory without an explicit completeness acknowledgment")

local per_item_fence_store = new_store()
local per_item_fence_calls = 0
local per_item_delete_calls = 0
local per_item_fence_erasure = V2.Erasure.new(per_item_fence_store, {
	{
		name = "fenced_family",
		templates = { { name = "PlayerData", scope = "global", key = "Fence_{user_id}" } },
		templates_verified = true,
		inventory = function(user_id)
			return { { name = "PlayerData", scope = "global", key = "Fence_" .. tostring(user_id), generation = 4 } }, true
		end,
		fence_user = function()
			per_item_fence_calls += 1
			return per_item_fence_calls == 1
		end,
		redact_or_delete_if_generation = function()
			per_item_delete_calls += 1
			return "deleted"
		end,
	},
}, { verify_templates = function() return true end })
expect(per_item_fence_erasure:PlanAsync(781, "erase-fence-expiry").rtbf_coverage_verified == true,
	"writer-fence regression could not create a verified inventory")
local per_item_fence_result = per_item_fence_erasure:ExecuteAsync(781, "erase-fence-expiry", 1)
expect(per_item_fence_result.code == "retryable" and per_item_fence_calls == 2 and per_item_delete_calls == 0,
	"erasure did not recheck a lost writer fence immediately before deletion")
expect(per_item_fence_erasure:GetStatus(781).cursor == 0,
	"erasure advanced progress after losing the per-item writer fence")

local oversize_items = {}
for index = 1, 513 do
	table.insert(oversize_items, {
		name = "PlayerData", scope = "global", key = "Player_" .. tostring(index), generation = index,
	})
end
local oversize_store = new_store()
local oversize_erasure = V2.Erasure.new(oversize_store, {
	{
		name = "oversized_family",
		templates = { { name = "PlayerData", scope = "global", key = "Player_{user_id}" } },
		templates_verified = true,
		inventory = function() return oversize_items, true end,
		fence_user = function() return true end,
		redact_or_delete_if_generation = function() return "deleted" end,
	},
}, { verify_templates = function() return true end })
local oversized_plan = oversize_erasure:PlanAsync(779, "erase-oversized")
expect(oversized_plan.code == "capacity" and oversized_plan.family == "oversized_family",
	"erasure silently truncated an oversized inventory instead of failing closed")
expect(oversize_store.values["rv2erase-u779"] == nil,
	"erasure persisted a truncated manifest after inventory overflow")

local concurrent_erase_store = new_store()
local concurrent_eraser
local nested_erasure_result
local reenter_erasure = true
local concurrent_deleted = {}
local concurrent_family = {
	{
		name = "concurrent_profiles",
		templates = {
			{ name = "PlayerData", scope = "global", key = "Player_{user_id}" },
			{ name = "PlayerData", scope = "global", key = "PlayerArchive_{user_id}" },
		},
		templates_verified = true,
		inventory = function(user_id)
			return {
				{ name = "PlayerData", scope = "global", key = "Player_" .. tostring(user_id), generation = 4 },
				{ name = "PlayerData", scope = "global", key = "PlayerArchive_" .. tostring(user_id), generation = 8 },
			}, true
		end,
		fence_user = function() return true end,
		dependencies_clear = function() return true end,
		redact_or_delete_if_generation = function(item)
			concurrent_deleted[#concurrent_deleted + 1] = item.key
			if reenter_erasure then
				reenter_erasure = false
				nested_erasure_result = concurrent_eraser:ExecuteAsync(654321, "erase-concurrent-1", 2)
			end
			return "deleted"
		end,
	},
}
concurrent_eraser = V2.Erasure.new(concurrent_erase_store, concurrent_family, {
	verify_templates = function() return true end,
})
expect(concurrent_eraser:PlanAsync(654321, "erase-concurrent-1").code == "success",
	"concurrent erasure plan creation failed")
local outer_erasure_result = concurrent_eraser:ExecuteAsync(654321, "erase-concurrent-1", 1)
expect(nested_erasure_result.code == "committed", "nested erasure did not complete both items")
expect(outer_erasure_result.code == "committed" and outer_erasure_result.completed_count == 2,
	"stale erasure worker overwrote newer terminal progress")
expect(concurrent_eraser:GetStatus(654321).status == "completed"
	and concurrent_eraser:GetStatus(654321).cursor == 2,
	"concurrent erasure execution regressed the durable cursor");

local unverified_erasure = V2.Erasure.new(new_store(), {
	{
		name = "unverified_family",
		templates = { { name = "SharedStore", scope = "global", key = "shared-key-{user_id}" } },
		templates_verified = false,
		inventory = function() return {}, true end,
		fence_user = function() return true end,
		redact_or_delete_if_generation = function() return "deleted" end,
	},
}, { verify_templates = function() return true end })
local unverified_plan = unverified_erasure:PlanAsync(123456, "erase-unverified")
expect(unverified_plan.rtbf_coverage_verified == false,
	"erasure claimed complete coverage for an unverified key template")

local compaction_store = new_store()
local removed = {}
local compactor = V2.Maintenance.NewCompactor({
	next_page = function(cursor, maximum)
		return { { key = "expired-a", generation = 4 }, { key = "active-b", generation = 7 } }, nil, true
	end,
	inspect = function(item)
		return { status = "success", eligible = item.key == "expired-a", dependencies_clear = item.key == "expired-a", generation = item.generation }
	end,
	delete_if_generation = function(item, generation)
		removed[#removed + 1] = { key = item.key, generation = generation }
		return "deleted"
	end,
	persist_progress = function(cursor, processed, removed_count, status)
		compaction_store.values.checkpoint = { cursor = cursor, processed = processed, removed = removed_count, status = status }
		return true
	end,
})
local compacted = compactor:RunStep(16, 500)
expect(compacted.code == "completed" and compacted.processed == 2 and compacted.removed == 1,
	"bounded compactor did not report its progress")
expect(#removed == 1 and removed[1].generation == 4, "compactor deleted an ineligible generation")
expect(compaction_store.values.checkpoint.status == "completed",
	"compactor checkpoint did not persist its final completion status")

local checkpoint_loss_store = new_store()
local checkpoint_calls = 0
local delete_applied = false
local requested_cursors = {}
local durable_cursor = "cursor-a"
local checkpoint_loss_compactor = V2.Maintenance.NewCompactor({
	initial_cursor = "cursor-a",
	next_page = function(cursor, maximum)
		table.insert(requested_cursors, cursor)
		return { { key = "checkpoint-loss", generation = 9 } }, "cursor-b", false
	end,
	inspect = function(item)
		return { status = "success", eligible = true, dependencies_clear = true, generation = item.generation }
	end,
	delete_if_generation = function(item, generation)
		if delete_applied then return "already_absent" end
		delete_applied = true
		return "deleted"
	end,
	persist_progress = function(cursor, processed, removed_count, status)
		checkpoint_calls += 1
		if checkpoint_calls == 1 then return false, "injected checkpoint write failure after deletion" end
		durable_cursor = cursor
		checkpoint_loss_store.values.checkpoint = {
			cursor = cursor, processed = processed, removed = removed_count, status = status,
		}
		return true
	end,
})
local checkpoint_lost = checkpoint_loss_compactor:RunStep(1, 500)
expect(checkpoint_lost.code == "unknown" and checkpoint_lost.cursor == "cursor-a",
	"checkpoint failure after deletion did not return the last durable cursor")
expect(checkpoint_loss_compactor:Stats().cursor == "cursor-a",
	"in-memory compaction cursor advanced after its durable checkpoint failed")
expect(durable_cursor == "cursor-a" and delete_applied,
	"checkpoint-loss fixture did not separate the committed delete from the durable cursor")
local checkpoint_retried = checkpoint_loss_compactor:RunStep(1, 500)
expect(#requested_cursors == 2 and requested_cursors[1] == "cursor-a" and requested_cursors[2] == "cursor-a",
	"compactor skipped the uncheckpointed page on same-process retry")
expect(checkpoint_retried.code == "incomplete" and checkpoint_retried.cursor == "cursor-b",
	"compactor did not advance after a retry durably checkpointed the page")
expect(durable_cursor == "cursor-b" and checkpoint_loss_store.values.checkpoint.cursor == "cursor-b",
	"retry failed to persist the recovered compaction cursor")

local unknown_compaction_store = new_store()
local unknown_compactor = V2.Maintenance.NewCompactor({
	next_page = function(cursor)
		return { { key = "uncertain", generation = 2 } }, cursor, false
	end,
	inspect = function()
		return { status = "unknown" }, "injected inspection uncertainty"
	end,
	delete_if_generation = function() error("unknown inspection must not reach delete adapter") end,
	persist_progress = function(cursor, processed, removed_count, status)
		unknown_compaction_store.values.checkpoint = {
			cursor = cursor, processed = processed, removed = removed_count, status = status,
		}
		return true
	end,
})
local unknown_compacted = unknown_compactor:RunStep(1, 500)
expect(unknown_compacted.code == "unknown", "compactor hid an unresolved inspection")
expect(unknown_compaction_store.values.checkpoint.status == "unknown",
	"compactor failed to durably checkpoint its unresolved state")
expect(unknown_compaction_store.values.checkpoint.cursor == nil,
	"compactor advanced its cursor after an unresolved inspection")

local migration_record = RecordStore.Mock.new("V2MigrationProfiles", "global", "profile", {
	schema_version = 1, transactional_operations_enabled = true,
})
local migration_open, migration_open_message = migration_record:Open({
	cash = 10,
	__recordstore_reserved_do_not_restore = "preserve",
	__recordstore_legacy_receipts = { purchase_1 = "durable-receipt" },
	__recordstore_fencing_state = { generation = 17 },
	__recordstore_erasure_tombstone = { status = "completed" },
})
expect(migration_open == "created" or migration_open == "loaded", "migration profile open failed: " .. tostring(migration_open_message))
local migration_manifest_store = new_store()
local manifest_update = migration_manifest_store.UpdateAsync
migration_manifest_store.UpdateAsync = function(self, key, transform)
	return manifest_update(self, key, function(old)
		local proposed = transform(old)
		if type(proposed) == "table" and proposed.status == "committed" then
			self.fail_after_next_update = true
		end
		return proposed
	end)
end
local migrations = V2.Migrations.new({
	manifest_store = migration_manifest_store,
	require_durable_manifest = true,
})
local migration_registered, migration_register_message = migrations:Register(
	"V2MigrationProfiles", 0, 1, "cash-v1-upgrade", "revision-1",
	function(data)
		local updated = clone(data)
		updated.cash += 5
		return updated
	end,
	function(data) return type(data.cash) == "number", "cash must be numeric" end
)
expect(migration_registered == true, "migration registration failed: " .. tostring(migration_register_message))
local preview = migrations:Preview(migration_record, "V2MigrationProfiles", 1)
expect(preview.code == "success" and preview.preview_only == true, "migration preview failed")
expect(migration_record:Get().cash == 10, "migration preview mutated durable profile data")
local migrated = migrations:MigrateAsync(migration_record, "V2MigrationProfiles", 1)
expect(migrated.code == "committed" and migration_record:Get().cash == 15,
	"transactional migration did not commit its profile transformation")
local successful_manifest = nil
for _, candidate in pairs(migration_manifest_store.values) do
	if type(candidate) == "table" and candidate.id == "cash-v1-upgrade" then successful_manifest = candidate end
end
expect(successful_manifest ~= nil and successful_manifest.status == "committed",
	"durable migration manifest did not reconcile a response lost after commit")
expect(type(successful_manifest.operation_id) == "string", "durable migration manifest omitted its stable operation ID")
local durable_migration_status = migrations:GetStatus(successful_manifest.operation_id)
expect(durable_migration_status.status == "committed",
	"migration status API disagreed with its durable committed manifest")
local duplicate_registration, duplicate_registration_message = migrations:Register(
	"V2MigrationProfiles", 0, 1, "cash-v1-upgrade", "revision-1",
	function(data) return data end,
	function(data) return type(data.cash) == "number" end
)
expect(duplicate_registration == true and duplicate_registration_message == "duplicate",
	"same stable migration manifest did not register idempotently")

local failed_migration_record = RecordStore.Mock.new("V2MigrationFailureProfiles", "global", "profile", {
	schema_version = 1, transactional_operations_enabled = true,
})
local failed_migration_open, failed_migration_open_message = failed_migration_record:Open({ cash = 1 })
expect(failed_migration_open == "created" or failed_migration_open == "loaded",
	"failure migration profile open failed: " .. tostring(failed_migration_open_message))
local failed_registration, failed_registration_message = migrations:Register(
	"V2MigrationFailureProfiles", 0, 1, "cash-v1-invalid", "revision-1",
	function(data)
		local updated = clone(data)
		updated.cash = -1
		return updated
	end,
	function() return false, "intentional migration validation rejection" end
)
expect(failed_registration == true, "failing migration registration failed: " .. tostring(failed_registration_message))
local failed_migration = migrations:MigrateAsync(failed_migration_record, "V2MigrationFailureProfiles", 1)
expect(failed_migration.manifest_status == "quarantined",
	"failed migration was not durably quarantined: " .. tostring(failed_migration.manifest_status))
local quarantined_manifest = nil
for _, candidate in pairs(migration_manifest_store.values) do
	if type(candidate) == "table" and candidate.id == "cash-v1-invalid" then quarantined_manifest = candidate end
end
expect(quarantined_manifest ~= nil and quarantined_manifest.status == "quarantined",
	"failed migration quarantine did not persist")
local quarantine_resolution = migrations:ResolveQuarantine(
	"V2MigrationFailureProfiles", "cash-v1-invalid", "revision-1", "operator-1", "reviewed migration validator failure"
)
expect(quarantine_resolution.code == "committed",
	"migration quarantine resolution failed: " .. tostring(quarantine_resolution.code))
local resolved_migration_manifest = nil
for _, candidate in pairs(migration_manifest_store.values) do
	if type(candidate) == "table" and candidate.id == "cash-v1-invalid" then resolved_migration_manifest = candidate end
end
expect(resolved_migration_manifest ~= nil and resolved_migration_manifest.status == "registered"
	and type(resolved_migration_manifest.resolution) == "table",
	"migration quarantine resolution was not durably audited")

local repair_preview = V2.ProfileDoctor.PreviewRepair(migration_record, {
	id = "cash-repair", revision = "v1",
	preview = function(data) local updated = clone(data); updated.cash = 20; return updated end,
	validate = function(data) return type(data.cash) == "number" and data.cash >= 0 end,
}, { expected_revision = migration_record:GetRevision() })
expect(repair_preview.code == "success" and repair_preview.preview_only == true,
	"profile repair preview did not remain read-only")
local restore_revision = migration_record:GetRevision()
local missing_authorizer = V2.ProfileDoctor.Restore(
	migration_record, { cash = 99 }, restore_revision,
	"restore-no-auth", "operator-1", "missing authorizer",
	{ subject_user_id = 123456, is_erased = function() return false end }
)
expect(missing_authorizer.code == "disabled",
	"restore did not fail closed when no application authorizer was supplied")
local denied_restore = V2.ProfileDoctor.Restore(
	migration_record, { cash = 99 }, restore_revision,
	"restore-denied", "operator-1", "authorization should be denied",
	{
		subject_user_id = 123456,
		is_erased = function() return false end,
		authorize = function() return false, "operator is not authorized" end,
	}
)
expect(denied_restore.code == "denied", "restore ignored an explicit authorization denial")
local stale_restore = V2.ProfileDoctor.Restore(
	migration_record, { cash = 99 }, restore_revision - 1,
	"restore-stale-revision", "operator-1", "stale revision",
	{
		subject_user_id = 123456,
		is_erased = function() return false end,
		authorize = function() return true end,
	}
)
expect(stale_restore.code == "conflict", "restore accepted a stale profile revision")
local restored = V2.ProfileDoctor.Restore(
	migration_record, {
		cash = 99,
		__recordstore_reserved_do_not_restore = "historical-overwrite",
		__recordstore_legacy_receipts = { purchase_1 = "historical-receipt" },
		__recordstore_fencing_state = { generation = 1 },
		__recordstore_erasure_tombstone = { status = "cleared" },
	}, migration_record:GetRevision(),
	"restore-stable-1", "operator-1", "verified historical restore",
	{
		subject_user_id = 123456,
		is_erased = function() return false end,
		authorize = function(operator_id, reason, expected_revision, user_id)
			return operator_id == "operator-1" and reason ~= "" and expected_revision ~= nil and user_id == 123456
		end,
	}
)
expect(restored.code == "committed" and migration_record:Get().cash == 99,
	"guarded restore failed to commit an audited historical value")
local restored_data = migration_record:Get()
expect(restored_data["__recordstore_reserved_do_not_restore"] == "preserve",
	"historical restore overwrote RecordStore-reserved metadata")
expect(restored_data["__recordstore_legacy_receipts"].purchase_1 == "durable-receipt",
	"historical restore overwrote durable receipt metadata")
expect(restored_data["__recordstore_fencing_state"].generation == 17,
	"historical restore overwrote session fencing metadata")
expect(restored_data["__recordstore_erasure_tombstone"].status == "completed",
	"historical restore removed or overwrote an erasure tombstone")
expect(restored_data.cash == 99, "historical restore did not replace the intended user-data field")

local profile_quarantine_store = new_store()
local diagnosed_revision = migration_record:GetRevision()
local quarantined_profile = V2.ProfileDoctor.QuarantineAsync(
	migration_record, profile_quarantine_store, "profile-quarantine-001",
	"operator-1", "manual diagnosis requires writer fencing", diagnosed_revision
)
expect(quarantined_profile.code == "committed",
	"profile quarantine manifest was not committed: " .. tostring(quarantined_profile.code))
local profile_quarantine_status = V2.ProfileDoctor.GetQuarantineStatusAsync(migration_record, profile_quarantine_store)
expect(profile_quarantine_status.code == "success" and profile_quarantine_status.status == "quarantined",
	"profile quarantine status could not be read durably")
local blocked_writer = V2.ProfileDoctor.CheckWritableAsync(migration_record, profile_quarantine_store)
expect(blocked_writer.code == "quarantined" and blocked_writer.allowed == false,
	"quarantine writer gate allowed writes while the profile was quarantined")
local fail_closed_writer = V2.ProfileDoctor.CheckWritableAsync(migration_record, {
	GetAsync = function() error("injected quarantine read failure") end,
	UpdateAsync = function() error("unexpected write") end,
})
expect(fail_closed_writer.allowed == false and fail_closed_writer.code == "unknown",
	"quarantine writer gate allowed writes when status was unknown")
local profile_quarantine_resolved = V2.ProfileDoctor.ResolveQuarantineAsync(
	migration_record, profile_quarantine_store, "profile-quarantine-001",
	"operator-1", "write paths inspected", migration_record:GetRevision()
)
expect(profile_quarantine_resolved.code == "committed",
	"profile quarantine resolution failed: " .. tostring(profile_quarantine_resolved.code))
expect(V2.ProfileDoctor.GetQuarantineStatusAsync(migration_record, profile_quarantine_store).status == "resolved",
	"profile quarantine resolution was not persisted")
local resumed_writer = V2.ProfileDoctor.CheckWritableAsync(migration_record, profile_quarantine_store)
expect(resumed_writer.code == "success" and resumed_writer.allowed == true,
	"writer gate remained blocked after an audited quarantine resolution")

sender:Close()
recipient:Close()
migration_record:Close()
failed_migration_record:Close()
RecordStore.Mock.reset()
Shim.close()
