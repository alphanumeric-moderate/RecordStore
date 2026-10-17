--!nocheck
-- Drives RecordStoreMailboxV2 through RecordStoreV2DataStoreAdapter and the real core request gate,
-- backed by the deterministic per-key DataStore model. This is not live Roblox service evidence.
local Shim = require("./RobloxShim")
local Fake = Shim.FakeDataStore
local HttpService = game:GetService("HttpService")
local RecordStore = Shim.load_isolated("live-mailbox-server")
local MailboxV2 = require("../src/PlayerDataInitializer/RecordStoreMailboxV2")
local Adapter = require("../src/PlayerDataInitializer/RecordStoreV2DataStoreAdapter")
local V2Module = require("../src/PlayerDataInitializer/RecordStoreV2")

local now_ms = 1_800_000_000_000
local guid_counter = 0
local function guid(): string
	guid_counter += 1
	return string.format("mailbox-guid-%08d", guid_counter)
end
Fake:Reset()
Fake:SetClock(function() return now_ms end)

local PROFILE_STORE = "RecordStoreV2MailboxOwner"
local MAILBOX_STORE = "RecordStoreV2MailboxLive"
local SCOPE = "global"
local USER_ID = 789456123
local owner = {
	store_name = PROFILE_STORE,
	scope = SCOPE,
	profile_key = "mailbox-owner",
	user_id = USER_ID,
}
local active_record = RecordStore.new(PROFILE_STORE, SCOPE, owner.profile_key, {
	schema_version = 1,
	retry_attempts = 2,
	lease_duration = 10,
	lease_renewal = 1,
	operation_deadline = 5,
	user_ids = { USER_ID },
	metadata = { source = "live-mailbox-failure-matrix" },
	messaging_enabled = false,
	takeover_enabled = false,
	autosave_interval = 3600,
	queue_poll_interval = 3600,
})
local open_code, open_message = active_record:Open({ processed_coins = 0 })
assert(open_code == "created" or open_code == "loaded", tostring(open_message))

local adapter = Adapter.new(RecordStore, MAILBOX_STORE, SCOPE, 5, Fake)
local V2 = V2Module.new(RecordStore, MailboxV2, {
	runtime = { now_ms = function() return now_ms end },
})
local mailbox = V2.Mailbox.new(adapter, owner, {
	active_record = active_record,
	sender_job_id = "live-mailbox-server",
	now_ms = function() return now_ms end,
	guid = guid,
	encode = function(value) return HttpService:JSONEncode(value) end,
	max_segments = 4,
	segment_max_messages = 4,
	preparation_shard_count = 4,
	preparation_max_entries_per_shard = 8,
	lease_ms = 30000,
	clock_skew_grace_ms = 1000,
	max_attempts = 3,
	retry_base_ms = 10,
	retry_max_ms = 100,
})

local function assert_stable_retry(key, payload)
	Fake:ScheduleFault("update", MAILBOX_STORE, SCOPE, nil, "before")
	local first = mailbox:EnqueueAsync("reward", payload, { idempotency_key = key })
	assert(first.code == "unknown" or first.code == "accepted" or first.code == "duplicate",
		"before-commit reservation fault returned an invalid outcome: " .. tostring(first.code))
	local second = mailbox:EnqueueAsync("reward", payload, { idempotency_key = key })
	assert(second.code == "accepted" or second.code == "duplicate",
		"same idempotency key did not recover after before-commit failure: " .. tostring(second.code))
	assert(first.message_id == nil or first.message_id == second.message_id,
		"retry after before-commit failure changed the canonical route")
	return second
end

local baseline = mailbox:EnqueueAsync("reward", { coins = 10 }, { idempotency_key = "mailbox-baseline" })
assert(baseline.code == "accepted", tostring(baseline.error))
local duplicate = mailbox:EnqueueAsync("reward", { coins = 10 }, { idempotency_key = "mailbox-baseline" })
assert(duplicate.code == "duplicate" and duplicate.message_id == baseline.message_id,
	"live adapter did not preserve canonical idempotent routing")
local conflict = mailbox:EnqueueAsync("reward", { coins = 11 }, { idempotency_key = "mailbox-baseline" })
assert(conflict.code == "conflict", "live adapter accepted a payload conflict under the same producer key")

-- Reconcile a commit-then-error while reserving a submission, then retry the same key.
Fake:ScheduleFault("update", MAILBOX_STORE, SCOPE, nil, "after")
local ambiguous = mailbox:EnqueueAsync("reward", { coins = 20 }, { idempotency_key = "mailbox-ambiguous-reservation" })
assert(ambiguous.code == "unknown" or ambiguous.code == "accepted" or ambiguous.code == "duplicate",
	"commit-then-error reservation returned an invalid outcome: " .. tostring(ambiguous.code))
local ambiguous_retry = mailbox:EnqueueAsync("reward", { coins = 20 }, { idempotency_key = "mailbox-ambiguous-reservation" })
assert(ambiguous_retry.code == "accepted" or ambiguous_retry.code == "duplicate",
	"same-key retry failed to reconcile ambiguous reservation: " .. tostring(ambiguous_retry.code))
assert(ambiguous.message_id == nil or ambiguous.message_id == ambiguous_retry.message_id,
	"ambiguous reservation retry changed the canonical route")

local before_commit_retry = assert_stable_retry("mailbox-before-commit", { coins = 30 })

-- Drain the three ready messages before targeting the acknowledgement message.
local processed_ids = {}
for _ = 1, 3 do
	local result = mailbox:ProcessNextAsync(function(payload, snapshot)
		table.insert(processed_ids, snapshot.Id)
		local update_code, update_message = active_record:Update(function(current)
			local next_data = table.clone(current)
			next_data.processed_coins += payload.coins
			return next_data
		end)
		assert(update_code == "success", tostring(update_message))
		local save_code, save_message = active_record:Save("live-mailbox-handler")
		assert(save_code == "success" or save_code == "saved", tostring(save_message))
		return true
	end)
	assert(result.code == "processed", "live mailbox could not process a prepared message: " .. tostring(result.code) .. " / " .. tostring(result.error))
end

local ack_message = mailbox:EnqueueAsync("reward", { coins = 40 }, { idempotency_key = "mailbox-ack-ambiguous" })
assert(ack_message.code == "accepted", tostring(ack_message.error))
local handler_calls = 0
Fake:ScheduleFault("update", MAILBOX_STORE, SCOPE, ack_message.message_id, "after", { skip_matches = 2 })
local ack_result = mailbox:ProcessNextAsync(function(payload, snapshot)
	handler_calls += 1
	return true
end)
assert(handler_calls == 1, "ack ambiguity replayed the handler within the same process attempt")
assert(ack_result.code == "unknown", "commit-then-error terminal acknowledgement was not reported unknown")
local recovery = mailbox:RecoverAsync()
assert(recovery.code == "success" or recovery.code == "empty", tostring(recovery.error))
local delivery, delivery_result = mailbox:GetDeliveryAsync(ack_message.message_id)
assert(delivery_result.code == "success", tostring(delivery_result.error))
assert(delivery ~= nil and delivery.State == "acknowledged",
	"acknowledgement recovery did not recognize committed terminal state")
assert(handler_calls == 1, "recovery re-executed an already acknowledged handler")

local profile_snapshot = RecordStore.read_async(PROFILE_STORE, SCOPE, owner.profile_key)
assert(profile_snapshot ~= nil and profile_snapshot.data.processed_coins == 60,
	"mailbox handler profile effects did not persist exactly once per test message")
-- The V2.Mailbox factory injects the same governor used by the core adapter hook.
local SCHEDULER_STORE = "RecordStoreV2MailboxScheduling"
local SCHEDULER_PROFILE = "mailbox-scheduler-owner"
local scheduler_owner = {
	store_name = PROFILE_STORE,
	scope = SCOPE,
	profile_key = SCHEDULER_PROFILE,
	user_id = USER_ID,
}
local scheduler_record = RecordStore.new(PROFILE_STORE, SCOPE, SCHEDULER_PROFILE, {
	schema_version = 1,
	retry_attempts = 2,
	lease_duration = 10,
	lease_renewal = 1,
	operation_deadline = 5,
	user_ids = { USER_ID },
	messaging_enabled = false,
	takeover_enabled = false,
	autosave_interval = 3600,
	queue_poll_interval = 3600,
})
local scheduler_open, scheduler_open_message = scheduler_record:Open({ processed_coins = 0 })
assert(scheduler_open == "created" or scheduler_open == "loaded", tostring(scheduler_open_message))
local scheduler_adapter = Adapter.new(RecordStore, SCHEDULER_STORE, SCOPE, 5, Fake)
local scheduler_mailbox = V2.Mailbox.new(scheduler_adapter, scheduler_owner, {
	active_record = scheduler_record,
	sender_job_id = "live-mailbox-scheduler",
	now_ms = function() return now_ms end,
	guid = guid,
	encode = function(value) return HttpService:JSONEncode(value) end,
	max_segments = 4,
	segment_max_messages = 4,
	preparation_shard_count = 4,
	preparation_max_entries_per_shard = 8,
	lease_ms = 30000,
	clock_skew_grace_ms = 1000,
	max_attempts = 3,
	retry_base_ms = 10,
	retry_max_ms = 100,
})
local scheduler_policy, scheduler_policy_message = V2.ApplySchedulerPolicy({
	revision = V2.RuntimeGovernor.get_shared():Stats().policy.revision + 1,
	high_burst = 1,
})
assert(scheduler_policy == "success", tostring(scheduler_policy_message))
for _, spec in ipairs({
	{ type = "high-first", priority = "high" },
	{ type = "high-second", priority = "high" },
	{ type = "normal-lane", priority = "normal" },
}) do
	local enqueued = scheduler_mailbox:EnqueueAsync(spec.type, { label = spec.type }, {
		idempotency_key = "scheduler-" .. spec.type,
		priority = spec.priority,
	})
	assert(enqueued.code == "accepted", tostring(enqueued.error))
end
local actual_order = {}
for _ = 1, 3 do
	local processed = scheduler_mailbox:ProcessNextAsync(function(payload)
		table.insert(actual_order, payload.label)
		return true
	end)
	assert(processed.code == "processed", "advanced selector failed to process an eligible message: " .. tostring(processed.code))
end
assert(actual_order[1] == "high-first" and actual_order[2] == "normal-lane" and actual_order[3] == "high-second",
	"V2 production candidate selector did not enforce the configured high-lane burst")
scheduler_record:Close()

local stats = Fake:Stats()
assert(stats.calls.update > 0 and stats.calls.get > 0, "mailbox path bypassed the deterministic DataStore backend")
active_record:Close()
print("[PASS] V2 production mailbox: shared request gate, idempotent submission, ambiguous reservations, ack recovery, high-burst candidate scheduling.")
Shim.close()
