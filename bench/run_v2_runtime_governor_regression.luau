--!nocheck
-- Verifies RecordStoreV2 delegates runtime policy to the one shared core RecordStore gate.
-- This tests configuration/reporting contracts only, not adaptive performance or live quotas.
local Shim = require("./RobloxShim")
local RecordStore = Shim.load_isolated("v2-runtime-governor")
local MailboxV2 = require("../src/PlayerDataInitializer/RecordStoreMailboxV2")
local V2Module = require("../src/PlayerDataInitializer/RecordStoreV2")

local now_ms = 1_800_000_000_000
local runtime_options = {
	now_ms = function() return now_ms end,
	now_unix = function() return math.floor(now_ms / 1000) end,
}
local V2 = V2Module.new(RecordStore, MailboxV2, { runtime = runtime_options })
local V2SecondFacade = V2Module.new(RecordStore, MailboxV2)
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

print("[PASS] RecordStoreV2 runtime policy and advanced adapter admission hooks.")
Shim.close()
