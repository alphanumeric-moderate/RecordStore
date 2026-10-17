--!nocheck
-- Exercises RecordStore.new() through the live backend path using a deterministic DataStore-shaped fake.
-- This is model-level evidence, not proof of live Roblox service quotas or Studio scheduling.
local Shim = require("./RobloxShim")
local Fake = Shim.FakeDataStore
local RecordStoreA = Shim.load_isolated("live-backend-a")
local RecordStoreB = Shim.load_isolated("live-backend-b")

local now_ms = 1_800_000_000_000
Fake:Reset()
Fake:SetClock(function() return now_ms end)

local STORE = "RecordStoreLiveBackendFailureMatrix"
local SCOPE = "global"
local USER_ID = 975318642
local passed = 0
local function group(name, callback)
	local ok, message = pcall(callback)
	assert(ok, ("[LIVE BACKEND MATRIX] %s failed: %s"):format(name, tostring(message)))
	passed += 1
end

local function new_record(module, key)
	return module.new(STORE, SCOPE, key, {
		schema_version = 1,
		retry_attempts = 2,
		lease_duration = 10,
		lease_renewal = 1,
		operation_deadline = 5,
		user_ids = { USER_ID },
		metadata = { fixture = "actual-live-backend" },
		messaging_enabled = false,
		takeover_enabled = false,
	})
end

local record = new_record(RecordStoreA, "profile-main")
group("01 fresh acquisition persists via GetDataStore", function()
	local code, message = record:Open({ coins = 0, note = "seed" })
	assert(code == "created" or code == "loaded", tostring(message))
	local raw = Fake:GetRaw(STORE, SCOPE, "profile-main")
	assert(type(raw) == "table" and type(raw.data) == "table" and raw.data.coins == 0,
		"RecordStore.new did not persist through DataStoreService:GetDataStore")
	assert(raw.session ~= nil and raw.session.job_id == "live-backend-a", "live session lease omitted server identity")
end)

group("02 live read path and DataStore key metadata", function()
	local snapshot, code, message = RecordStoreA.read_async(STORE, SCOPE, "profile-main")
	assert(code == "success", tostring(message))
	assert(snapshot ~= nil, "read_async did not return a snapshot from the fake live backend")
	local info = Fake:GetKeyInfo(STORE, SCOPE, "profile-main")
	assert(info ~= nil and info.UserIds[1] == USER_ID, "DataStore user IDs were not persisted")
	assert(info.Metadata.fixture == "actual-live-backend", "DataStore metadata was not persisted")
end)

group("03 before-commit open failure retries safely", function()
	Fake:ScheduleFault("update", STORE, SCOPE, "profile-before-commit", "before")
	local retry_record = new_record(RecordStoreA, "profile-before-commit")
	local code, message = retry_record:Open({ coins = 1 })
	assert(code == "created" or code == "loaded", tostring(message))
	assert(Fake:GetRaw(STORE, SCOPE, "profile-before-commit").data.coins == 1,
		"retry did not commit the intended envelope")
	retry_record:Close()
end)

group("04 commit-then-error during open is reconciled", function()
	Fake:ScheduleFault("update", STORE, SCOPE, "profile-open-ambiguous", "after")
	local ambiguous_record = new_record(RecordStoreA, "profile-open-ambiguous")
	local code, message = ambiguous_record:Open({ coins = 4 })
	assert(code == "created" or code == "loaded", tostring(message))
	local raw = Fake:GetRaw(STORE, SCOPE, "profile-open-ambiguous")
	assert(raw ~= nil and raw.data.coins == 4 and raw.session ~= nil,
		"committed open was not recovered from its ambiguous response")
	ambiguous_record:Close()
end)

group("05 commit-then-error during Save is reconciled", function()
	local update, message = record:Update(function(current)
		local next_data = table.clone(current)
		next_data.coins += 7
		return next_data
	end)
	assert(update == "success", tostring(message))
	Fake:ScheduleFault("update", STORE, SCOPE, "profile-main", "after")
	local saved, save_message = record:Save("live-backend-ambiguous")
	assert(saved == "success" or saved == "saved", tostring(save_message))
	assert(Fake:GetRaw(STORE, SCOPE, "profile-main").data.coins == 7,
		"ambiguous save did not persist the snapshot exactly once")
	local info = Fake:GetKeyInfo(STORE, SCOPE, "profile-main")
	assert(info ~= nil and info.UserIds[1] == USER_ID and info.Metadata.fixture == "actual-live-backend",
		"repeated Save failed to preserve DataStore key metadata/UserIds")
end)

group("06 before-commit Save failure preserves the retry", function()
	local update, message = record:Update(function(current)
		local next_data = table.clone(current)
		next_data.coins += 2
		return next_data
	end)
	assert(update == "success", tostring(message))
	Fake:ScheduleFault("update", STORE, SCOPE, "profile-main", "before")
	local saved, save_message = record:Save("live-backend-before-commit")
	assert(saved == "success" or saved == "saved", tostring(save_message))
	assert(Fake:GetRaw(STORE, SCOPE, "profile-main").data.coins == 9,
		"before-commit failure partially applied or lost the retry")
end)

group("07 UpdateAsync transform replay applies one snapshot", function()
	local update, message = record:Update(function(current)
		local next_data = table.clone(current)
		next_data.coins += 3
		return next_data
	end)
	assert(update == "success", tostring(message))
	Fake:SetTransformReplayCount(3)
	local saved, save_message = record:Save("live-backend-transform-replay")
	assert(saved == "success" or saved == "saved", tostring(save_message))
	assert(Fake:GetRaw(STORE, SCOPE, "profile-main").data.coins == 12,
		"UpdateAsync transform replay applied the mutation more than once")
end)

group("08 DataStore budget exhaustion does not advance durable data", function()
	local budget_record = new_record(RecordStoreA, "profile-budget")
	local opened, open_message = budget_record:Open({ coins = 0 })
	assert(opened == "created" or opened == "loaded", tostring(open_message))
	local changed, change_message = budget_record:Update(function(current)
		local next_data = table.clone(current)
		next_data.coins = 3
		return next_data
	end)
	assert(changed == "success", tostring(change_message))
	Fake:SetBudget("StandardWrite", 0)
	local blocked, _ = budget_record:Save("budget-exhausted")
	assert(blocked ~= "success" and blocked ~= "saved",
		"Save reported success when the DataStore write budget was exhausted")
	local raw_before_retry = Fake:GetRaw(STORE, SCOPE, "profile-budget")
	assert(raw_before_retry ~= nil and raw_before_retry.data.coins == 0,
		"budget rejection changed the durable snapshot")
	Fake:SetBudget("StandardWrite", math.huge)
	local recovered, recover_message = budget_record:Save("budget-recovered")
	assert(recovered == "success" or recovered == "saved", tostring(recover_message))
	assert(Fake:GetRaw(STORE, SCOPE, "profile-budget").data.coins == 3,
		"dirty snapshot was not retained for a retry after budget recovery")
	budget_record:Close()
end)

group("09 ambiguous release response is reconciled", function()
	local release_record = new_record(RecordStoreA, "profile-release-ambiguous")
	local opened, open_message = release_record:Open({ coins = 2 })
	assert(opened == "created" or opened == "loaded", tostring(open_message))
	Fake:ScheduleFault("update", STORE, SCOPE, "profile-release-ambiguous", "after")
	local released, release_message = release_record:Close()
	assert(released == "closed", tostring(release_message))
	local raw = Fake:GetRaw(STORE, SCOPE, "profile-release-ambiguous")
	assert(raw ~= nil and raw.session == nil,
		"ambiguous release was not reconciled to a durable released session")
end)

group("10 canceled UpdateAsync does not create a version", function()
	local store = Fake:GetDataStore(STORE, SCOPE)
	local before = Fake:GetKeyInfo(STORE, SCOPE, "profile-main")
	local before_value = Fake:GetRaw(STORE, SCOPE, "profile-main")
	local cancelled = store:UpdateAsync("profile-main", function()
		return nil
	end)
	local after = Fake:GetKeyInfo(STORE, SCOPE, "profile-main")
	local after_value = Fake:GetRaw(STORE, SCOPE, "profile-main")
	assert(cancelled == nil, "nil transform result should cancel UpdateAsync")
	assert(before.Version == after.Version and before_value.data.coins == after_value.data.coins,
		"canceled UpdateAsync changed durable value/version")
end)

group("11 saved generations are confirmed", function()
	local status, code, message = record:GetDurabilityStatus()
	assert(code == "success", tostring(message))
	assert(status ~= nil and not status.dirty and status.dirty_generation == status.durable_generation,
		"Save returned without confirming the current dirty generation")
end)

group("12 live history listing and version reads", function()
	local history, code, message = RecordStoreA.list_versions_async(
		STORE, SCOPE, "profile-main", Shim.environment.Enum.SortDirection.Descending, nil, nil, 10
	)
	assert(code == "success", tostring(message))
	assert(history ~= nil and #history >= 2, "ListVersionsAsync did not expose version history")
	local snapshot, version_code, version_message = RecordStoreA.get_version_async(
		STORE, SCOPE, "profile-main", history[1].Version
	)
	assert(version_code == "success", tostring(version_message))
	assert(snapshot ~= nil, "GetVersionAsync did not return the selected version")
	local by_time, version_at_time, time_code, time_message = RecordStoreA.get_version_at_time_async(
		STORE, SCOPE, "profile-main", now_ms
	)
	assert(time_code == "success", tostring(time_message))
	assert(by_time ~= nil and type(version_at_time) == "string", "GetVersionAtTimeAsync did not return a version")
	assert(version_at_time == history[1].Version,
		"equal-timestamp history lookup did not return the newest committed version")
end)

group("13 another server sees contention without gaining authority", function()
	local contender = new_record(RecordStoreB, "profile-main")
	local wait_result, wait_code, wait_message = contender:WaitForSessionAsync({ coins = 99 }, {
		max_wait_seconds = 5,
		max_attempts = 1,
	})
	assert(wait_code == "locked" or wait_code == "retry_exhausted", tostring(wait_message))
	assert(wait_result.Outcome == "competing_session_observed", "contender did not report the live durable lease")
	assert(contender:GetState() ~= "active", "contender acquired the session prematurely")
	now_ms += 30_000
	local acquired, acquired_code, acquired_message = contender:WaitForSessionAsync(nil, {
		max_wait_seconds = 5,
		max_attempts = 1,
	})
	assert(acquired_code == "success" and acquired.Outcome == "ownership_acquired",
		tostring(acquired_message) .. " / " .. tostring(acquired.Outcome))
	local changed, changed_message = contender:Update(function(current)
		local next_data = table.clone(current)
		next_data.coins += 10
		return next_data
	end)
	assert(changed == "success", tostring(changed_message))
	local saved, saved_message = contender:Save("new-owner")
	assert(saved == "success" or saved == "saved", tostring(saved_message))
	local stale_update = record:Update(function(current)
		local next_data = table.clone(current)
		next_data.coins = 999
		return next_data
	end)
	local stale_save, stale_save_message = record:Save("stale-owner")
	assert(stale_update ~= "success" or stale_save == "fenced" or stale_save == "conflict",
		"stale owner overwrote the newer fencing generation: " .. tostring(stale_save_message))
	assert(Fake:GetRaw(STORE, SCOPE, "profile-main").data.coins == 22,
		"stale writer changed the durable new-owner value")
	contender:Close()
end)

print(("[PASS] %d live-backend fault/contract groups using deterministic DataStoreService fake."):format(passed))
Shim.close()
