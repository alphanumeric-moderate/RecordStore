--!nocheck
-- Verifies RecordStoreV2 delegates runtime policy to the one shared core RecordStore gate.
-- This tests configuration/reporting contracts only, not adaptive performance or live quotas.
local Shim = require("./RobloxShim")
local task = require("@lune/task")
local RecordStore = Shim.load_isolated("v2-runtime-governor")
local MailboxV2 = require("../src/PlayerDataInitializer/RecordStoreMailboxV2")
local V2Module = require("../src/PlayerDataInitializer/RecordStoreV2")

local now_ms = 1_800_000_000_000
local runtime_options = {
	now_ms = function() return now_ms end,
	now_unix = function() return math.floor(now_ms / 1000) end,
}
local V2 = V2Module.new(RecordStore, MailboxV2, { runtime = runtime_options, allow_unattested_activation = true })
local V2SecondFacade = V2Module.new(RecordStore, MailboxV2, { allow_unattested_activation = true })
assert(V2.RuntimeGovernor.get_shared() == V2SecondFacade.RuntimeGovernor.get_shared(),
	"multiple V2 facades created independent server-local advanced governors")

local before = V2.GetRuntimeSnapshot()
assert(type(before) == "table" and type(before.policy) == "table",
	"V2 did not expose the core runtime snapshot")
assert(before.policy.max_dirty_age_seconds ~= nil, "core runtime snapshot omitted dirty-age policy")

local next_revision = before.policy.revision + 1
local apply_code, apply_message = V2.ApplyRuntimePolicy({
	revision = next_revision,
	max_dirty_age_seconds = 120,
})
assert(apply_code == "success", tostring(apply_message))
local after = V2.GetRuntimeSnapshot()
assert(after.policy.revision == next_revision, "V2 policy did not update the shared core revision")
assert(after.policy.max_dirty_age_seconds == 120, "V2 policy did not update the shared core dirty-age threshold")

local record = RecordStore.new("V2RuntimeGovernorRegression", "global", "profile", {
	schema_version = 1,
	retry_attempts = 1,
	lease_duration = 10,
	lease_renewal = 1,
	operation_deadline = 5,
	user_ids = { 123456 },
	messaging_enabled = false,
	takeover_enabled = false,
})
local opened, open_message = record:Open({ coins = 0 })
assert(opened == "created" or opened == "loaded", tostring(open_message))
local status, status_code, status_message = record:GetDurabilityStatus()
assert(status_code == "success", tostring(status_message))
assert(status ~= nil and status.max_dirty_age_seconds == 120,
	"Record durability status did not use the shared V2-applied runtime policy")

local live_revision = next_revision + 1
local live_apply_code, live_apply_message = V2.ApplyRuntimePolicy({
	revision = live_revision,
	max_dirty_age_seconds = 90,
})
assert(live_apply_code == "success", tostring(live_apply_message))
local live_status, live_status_code, live_status_message = record:GetDurabilityStatus()
assert(live_status_code == "success", tostring(live_status_message))
assert(live_status ~= nil and live_status.max_dirty_age_seconds == 90,
	"runtime policy update did not affect an already-open Record")
local stale_code = V2.ApplyRuntimePolicy({
	revision = next_revision,
	max_dirty_age_seconds = 120,
})
assert(stale_code == "invalid", "stale runtime policy revision was accepted")

local snapshot_after_open = V2.GetRuntimeSnapshot()
assert(snapshot_after_open.active_requests == 0, "runtime request counter leaked after Open")
assert(snapshot_after_open.policy.revision == live_revision,
	"runtime snapshot did not retain the newest applied policy revision")

local change_code = record:Update(function(current)
	local next_data = table.clone(current)
	next_data.coins += 1
	return next_data
end)
assert(change_code == "success", "Record update failed after runtime policy application")
local save_code, save_message = record:Save("v2-runtime-policy")
assert(save_code == "success" or save_code == "saved", tostring(save_message))
local final_snapshot = V2.GetRuntimeSnapshot()
assert(final_snapshot.policy.revision == live_revision and final_snapshot.active_requests == 0,
	"runtime snapshot did not remain consistent after profile persistence")

local Adapter = require("../src/PlayerDataInitializer/RecordStoreV2DataStoreAdapter")
local adapter = Adapter.new(RecordStore, "V2RuntimeGovernorProbe", "global", 5, Shim.FakeDataStore)
local shared_governor = V2.RuntimeGovernor.get_shared()
local scheduler_before = shared_governor:Stats()
local invalid_scheduler_code = V2.ApplySchedulerPolicy({
	revision = scheduler_before.policy.revision + 1,
	unsupported_field = true,
})
assert(invalid_scheduler_code == "invalid", "advanced scheduler policy accepted an unknown field")
local invalid_burst_code = V2.ApplySchedulerPolicy({
	revision = scheduler_before.policy.revision + 1,
	high_burst = 0,
})
assert(invalid_burst_code == "invalid", "advanced scheduler policy accepted an out-of-range high_burst")
local invalid_budget_code = V2.ApplySchedulerPolicy({
	revision = scheduler_before.policy.revision + 1,
	minimum_budget = -1,
})
assert(invalid_budget_code == "invalid", "advanced scheduler policy accepted a negative minimum budget")
local reject_revision = scheduler_before.policy.revision + 1
local reject_code, reject_message = V2.ApplySchedulerPolicy({
	revision = reject_revision,
	mode = "reject_noncritical",
})
assert(reject_code == "success", tostring(reject_message))
local stale_scheduler_code = V2.ApplySchedulerPolicy({
	revision = reject_revision,
	mode = "normal",
})
assert(stale_scheduler_code == "invalid", "advanced scheduler accepted a repeated policy revision")
local before_fake_gets = Shim.FakeDataStore:Stats().calls.get
local admitted, admission_message = pcall(function()
	adapter:GetAsync("should-be-rejected")
end)
assert(not admitted and string.find(tostring(admission_message), "budget", 1, true) ~= nil,
	"advanced governor did not reject noncritical adapter work in reject_noncritical mode")
assert(Shim.FakeDataStore:Stats().calls.get == before_fake_gets,
	"rejected governor admission still invoked the DataStore callback")
local normal_code, normal_message = V2.ApplySchedulerPolicy({
	revision = reject_revision + 1,
	mode = "normal",
})
assert(normal_code == "success", tostring(normal_message))
local completed_before = shared_governor:Stats().stats.completed
adapter:GetAsync("admitted-after-recovery")
assert(shared_governor:Stats().stats.completed == completed_before + 1,
	"successful adapter request did not release its governor ticket")

local completed_before_fault = shared_governor:Stats().stats.completed
local errors_before_fault = shared_governor:Stats().stats.errors
Shim.FakeDataStore:ScheduleFault("get", "V2RuntimeGovernorProbe", "global", "injected-read-failure", "before")
local failed_read_ok = pcall(function()
	adapter:GetAsync("injected-read-failure")
end)
assert(not failed_read_ok, "injected live-backend read failure was hidden by the adapter")
local governor_after_fault = shared_governor:Stats()
assert(governor_after_fault.stats.completed == completed_before_fault + 1,
	"failed adapter request did not release its governor ticket")
assert(governor_after_fault.stats.errors == errors_before_fault + 1,
	"failed adapter request was not observed by the advanced governor")
assert((governor_after_fault.classes.messaging or 0) == 0,
	"failed adapter request leaked the messaging work-class counter")

shared_governor:Observe("read", true, 1, nil, 100)
shared_governor:Observe("write", true, 1, nil, 1)
local read_ticket = shared_governor:Admit("messaging", "read", 1, false)
assert(read_ticket.code == "admitted", "healthy read budget was hidden by the lower write budget")
assert(shared_governor:Release(read_ticket), "read budget test ticket did not release")
local low_write_ticket = shared_governor:Admit("messaging", "write", 1, true)
assert(low_write_ticket.code == "backpressure", "low write budget was hidden by the healthy read budget")
assert((shared_governor:Stats().classes.messaging or 0) == 0,
	"budget rejections modified work-class in-flight counters")

local circuit_revision = reject_revision + 2
local circuit_policy_code, circuit_policy_message = V2.ApplySchedulerPolicy({
	revision = circuit_revision,
	mode = "normal",
	minimum_budget = 2,
	circuit_threshold = 1,
	circuit_cooldown_ms = 100,
})
assert(circuit_policy_code == "success", tostring(circuit_policy_message))
shared_governor:Observe("write", false, 2, "throttled", 100)
assert(shared_governor:Stats().circuits.write.state == "open", "write failure did not open its circuit")
now_ms += 101
shared_governor:Observe("write", true, 1, nil, 0)
local blocked_probe = shared_governor:Admit("messaging", "write", 1, true)
assert(blocked_probe.code == "backpressure", "probe bypassed the per-write request budget")
assert(shared_governor:Stats().circuits.write.state == "open",
	"budget rejection stranded the circuit in half-open state")
shared_governor:Observe("write", true, 1, nil, 100)
local half_open_ticket = shared_governor:Admit("messaging", "write", 1, true)
assert(half_open_ticket.code == "admitted", "write circuit did not admit one probe after budget recovery")
assert(shared_governor:Stats().circuits.write.state == "half_open",
	"post-cooldown admission did not reserve a single half-open probe")
shared_governor:Observe("write", true, 1, nil, 100)
assert(shared_governor:Stats().circuits.write.state == "closed",
	"successful half-open probe did not close its circuit")
assert(shared_governor:Release(half_open_ticket), "half-open probe ticket did not release")

local scheduled_outbox_commit, scheduled_outbox_message = record:CommitWithOutboxAsync(
	"scheduled-outbox-commit",
	"scheduled-outbox-request",
	function(current) return table.clone(current) end,
	{
		{
			EventId = "scheduled-outbox-event",
			DestinationStoreName = "V2ScheduledDestination",
			DestinationScope = "global",
			DestinationProfileKey = "scheduled-recipient",
			MessageType = "scheduled-reward",
			Data = { coins = 4 },
		},
	}
)
assert(scheduled_outbox_commit == "success", tostring(scheduled_outbox_message))
local scheduled_outbox_result = nil
local scheduled_outbox_submitted = V2.ScheduleOutboxDispatch(
	"scheduled-outbox-owner",
	record,
	function(event)
		assert(event.EventId == "scheduled-outbox-event", "scheduler selected an unexpected outbox event")
		return true, "scheduled-outbox-destination-receipt"
	end,
	1,
	2,
	function(result) scheduled_outbox_result = result end,
	{ lane = "background" }
)
assert(scheduled_outbox_submitted.code == "accepted", "outbox dispatch did not enter the shared selector")
now_ms += 10 -- advance the injected clock through the opt-in outbox batch window
for _ = 1, 100 do
	if scheduled_outbox_result ~= nil then break end
	task.wait(0.01)
end
assert(type(scheduled_outbox_result) == "table" and scheduled_outbox_result.code == "committed"
	and scheduled_outbox_result.dispatched == 1,
	"scheduled outbox dispatch did not complete through the shared selector")
local scheduled_maintenance_result = nil
local scheduled_maintenance = V2.ScheduleMaintenance(
	"maintenance-owner",
	"prune-receipts-chunk-1",
	function(maintenance_id)
		return { code = "committed", maintenance_id = maintenance_id, cursor = 1 }
	end,
	{
		lane = "background",
		on_complete = function(result) scheduled_maintenance_result = result end,
	}
)
assert(scheduled_maintenance.code == "accepted", "bounded maintenance chunk did not enter the shared selector")
for _ = 1, 100 do
	if scheduled_maintenance_result ~= nil then break end
	task.wait(0.01)
end
assert(type(scheduled_maintenance_result) == "table"
	and scheduled_maintenance_result.code == "committed"
	and scheduled_maintenance_result.cursor == 1,
	"bounded maintenance chunk did not complete through the shared selector")

local future_result = nil
local future_due_ms = now_ms + 30
local future_job = V2.ScheduleMaintenance(
	"maintenance-owner",
	"future-due-chunk",
	function(maintenance_id)
		return { code = "committed", maintenance_id = maintenance_id, ran_at_ms = now_ms }
	end,
	{
		due_at_ms = future_due_ms,
		on_complete = function(result) future_result = result end,
	}
)
assert(future_job.code == "accepted", "future-due maintenance was not accepted")
task.wait(0.01)
assert(future_result == nil, "future-due work ran before its due time")
for _ = 1, 100 do
	now_ms += 10
	if future_result ~= nil then break end
	task.wait(0.01)
end
assert(type(future_result) == "table" and future_result.code == "committed"
	and future_result.ran_at_ms >= future_due_ms,
	"future-due work was not awakened and dispatched at or after its due time")
local retry_calls = 0
local retry_result = nil
local retry_job = V2.ScheduleMaintenance(
	"maintenance-owner",
	"retryable-chunk",
	function(maintenance_id)
		retry_calls += 1
		if retry_calls < 3 then return { code = "retryable", message = "transient pre-commit failure" } end
		return { code = "committed", maintenance_id = maintenance_id, attempts = retry_calls }
	end,
	{
		lane = "background",
		max_retries = 2,
		retry_delay_ms = 10,
		on_complete = function(result) retry_result = result end,
	}
)
assert(retry_job.code == "accepted", "retryable maintenance job was not accepted")
for _ = 1, 200 do
	now_ms += 10
	if retry_result ~= nil then break end
	task.wait(0.01)
end
assert(retry_calls == 3, "explicit retryable results were not retried up to the configured cap")
assert(type(retry_result) == "table" and retry_result.code == "committed" and retry_result.attempts == 3,
	"scheduled retry did not report the final committed result")

local unknown_calls = 0
local unknown_result = nil
local unknown_job = V2.ScheduleMaintenance(
	"maintenance-owner",
	"unknown-result-must-not-retry",
	function()
		unknown_calls += 1
		return { code = "unknown", message = "the write may have committed" }
	end,
	{
		max_retries = 3,
		retry_delay_ms = 10,
		on_complete = function(result) unknown_result = result end,
	}
)
assert(unknown_job.code == "accepted", "unknown-outcome fixture was not accepted")
for _ = 1, 100 do
	now_ms += 10
	if unknown_result ~= nil then break end
	task.wait(0.01)
end
assert(unknown_calls == 1, "scheduler retried an unknown outcome and risked duplicating side effects")
assert(type(unknown_result) == "table" and unknown_result.code == "unknown",
	"scheduler did not preserve the unknown outcome")

local thrown_calls = 0
local thrown_result = nil
local thrown_job = V2.ScheduleMaintenance(
	"maintenance-owner",
	"callback-error-must-not-retry",
	function()
		thrown_calls += 1
		error("ambiguous callback failure")
	end,
	{
		max_retries = 3,
		retry_delay_ms = 10,
		on_complete = function(result) thrown_result = result end,
	}
)
assert(thrown_job.code == "accepted", "throwing callback fixture was not accepted")
for _ = 1, 100 do
	now_ms += 10
	if thrown_result ~= nil then break end
	task.wait(0.01)
end
assert(thrown_calls == 1, "scheduler retried a thrown callback with potentially ambiguous side effects")
assert(type(thrown_result) == "table" and thrown_result.code == "unknown",
	"thrown callback did not surface an unknown outcome")

local exhausted_calls = 0
local exhausted_result = nil
local exhausted_job = V2.ScheduleMaintenance(
	"maintenance-owner",
	"retry-cap-exhaustion",
	function()
		exhausted_calls += 1
		return { code = "retryable", message = "known pre-commit failure" }
	end,
	{
		max_retries = 1,
		retry_delay_ms = 10,
		on_complete = function(result) exhausted_result = result end,
	}
)
assert(exhausted_job.code == "accepted", "retry exhaustion fixture was not accepted")
for _ = 1, 100 do
	now_ms += 10
	if exhausted_result ~= nil then break end
	task.wait(0.01)
end
assert(exhausted_calls == 2, "scheduler did not stop at the configured retry cap")
assert(type(exhausted_result) == "table" and exhausted_result.code == "retry_exhausted",
	"retry cap did not return a typed retry_exhausted result")

local invalid_retry_cap = V2.ScheduleMaintenance(
	"maintenance-owner", "invalid-retry-cap", function() return { code = "committed" } end,
	{ max_retries = 9 }
)
assert(invalid_retry_cap.code == "invalid", "scheduler accepted max_retries above the documented bound")
local invalid_maintenance_options = V2.ScheduleMaintenance(
	"maintenance-owner", "invalid-options", function() return { code = "committed" } end, true
)
assert(invalid_maintenance_options.code == "invalid", "maintenance scheduler crashed on non-table options")
local invalid_outbox_options = V2.ScheduleOutboxDispatch(
	"outbox-owner", record, function() return true end, 1, 1, nil, true
)
assert(invalid_outbox_options.code == "invalid", "outbox scheduler crashed on non-table options")

local dispatch_stats = V2.GetSchedulerDispatchStats()
assert(dispatch_stats.accepted >= 7 and dispatch_stats.dispatched >= 6,
	"shared scheduler did not account for outbox, maintenance, delayed and retried work")
assert(dispatch_stats.retries == 3, "scheduler retry metric did not count explicit retries")

print("[PASS] RecordStoreV2 runtime policy and advanced adapter admission hooks.")
Shim.close()
