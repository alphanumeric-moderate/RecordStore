--!nocheck
-- Erasure protocol regressions. This file is authored for the final verification phase;
-- do not execute it until the remaining implementation and regression slices are present.
local Shim = require("./RobloxShim")
local RecordStore = Shim.load()
local V2Module = require(
	game:GetService("ServerScriptService"):WaitForChild("PlayerDataInitializer"):WaitForChild("RecordStoreV2")
)
local ErasureModule = require(
	game:GetService("ServerScriptService"):WaitForChild("PlayerDataInitializer"):WaitForChild("PlayerDataErasure")
)

local function expect(value, message)
	assert(value, message)
end

local function clone(value, depth)
	depth = depth or 0
	assert(depth <= 64, "test manifest value exceeds maximum depth")
	if type(value) ~= "table" then return value end
	local result = {}
	for key, item in pairs(value) do
		result[clone(key, depth + 1)] = clone(item, depth + 1)
	end
	return result
end

local function create_profile(user_id, initial_kills)
	local key = "Player_" .. tostring(user_id)
	local record = RecordStore.Mock.new("PlayerData_Test1", "global", key, {
		schema_version = 1,
		user_ids = { user_id },
		autosave_interval = 3600,
		lease_duration = 180,
		lease_renewal = 60,
		retry_attempts = 3,
		operation_deadline = 10,
	})
	local opened, open_message = record:Open({
		kills = initial_kills,
		equipped = "Default",
		admin = false,
	})
	expect(opened == "created" or opened == "loaded",
		"mock profile open failed: " .. tostring(open_message))
	for _ = 1, 2 do
		local update_result, update_message = record:Update(function(current)
			local next_data = clone(current)
			next_data.kills += 1
			return next_data
		end)
		expect(update_result == "success", "mock profile update failed: " .. tostring(update_message))
		local save_result, save_message = record:Save()
		expect(save_result == "saved", "mock profile save failed: " .. tostring(save_message))
	end
	return record, key
end

local function new_manifest_store()
	local store = { values = {}, update_calls = 0 }
	function store:GetAsyncFresh(key)
		return clone(self.values[key]), nil
	end
	function store:UpdateAsync(key, transform)
		self.update_calls += 1
		local next_value = transform(clone(self.values[key]))
		if next_value ~= nil then self.values[key] = clone(next_value) end
		return clone(self.values[key]), nil
	end
	return store
end

RecordStore.Mock.reset()

-- Same-profile fencing validates the exact inventoried generation and never
-- exposes the prior profile payload through the latest version afterward.
do
	local user_id = 101
	local record, key = create_profile(user_id, 10)
	local before, before_code = RecordStore.Mock.get_erasure_status_async(
		"PlayerData_Test1", "global", key, user_id, 10
	)
	expect(before_code == "success" and before ~= nil and not before.Erased,
		"active profile erasure status was not readable")
	expect(before.Generation >= 1, "active profile did not have a fencing generation")

	local stale, stale_code = RecordStore.Mock.erase_user_data_async(
		"PlayerData_Test1", "global", key, user_id, "erase-generation-101",
		before.Generation + 1, 10
	)
	expect(stale == nil and stale_code == "conflict",
		"erasure accepted a stale inventory generation")
	local unchanged, unchanged_code = RecordStore.Mock.get_erasure_status_async(
		"PlayerData_Test1", "global", key, user_id, 10
	)
	expect(unchanged_code == "success" and unchanged ~= nil and not unchanged.Erased,
		"generation conflict still installed a destructive erasure fence")

	local erased, erase_code, erase_message = RecordStore.Mock.erase_user_data_async(
		"PlayerData_Test1", "global", key, user_id, "erase-generation-101",
		before.Generation, 10
	)
	expect(erase_code == "success" and erased ~= nil and erased.Erased,
		"generation-matched profile erase failed: " .. tostring(erase_message))
	expect(erased.SourceGeneration == before.Generation, "erasure fence lost its source generation")

	local latest_raw = RecordStore.Mock.get_record_raw("PlayerData_Test1", "global", key)
	expect(type(latest_raw) == "table" and latest_raw.data == nil,
		"erased latest value still contains a profile data payload")
	expect(latest_raw.implementation_version == 2147483647
		and type(latest_raw.__recordstore_erasure_fence) == "table",
		"erasure did not leave the permanent fail-closed marker")
	local readable, readable_code = RecordStore.Mock.read_async(
		"PlayerData_Test1", "global", key, 10
	)
	expect(readable == nil and readable_code == "future_schema",
		"ordinary RecordStore reads did not fail closed on the permanent erasure marker")

	local replacement = RecordStore.Mock.new("PlayerData_Test1", "global", key, {
		schema_version = 1,
		user_ids = { user_id },
	})
	local recreate_result = replacement:Open({ kills = 999, equipped = "Default", admin = false }, true)
	expect(recreate_result == "future_schema",
		"Open(recreate=true) recreated a permanently erased profile")
	expect(replacement:Close() ~= nil, "replacement record close should return a result")
	replacement:Close()

	local idempotent, idempotent_code = RecordStore.Mock.erase_user_data_async(
		"PlayerData_Test1", "global", key, user_id, "erase-generation-101",
		before.Generation, 10
	)
	expect(idempotent_code == "success" and idempotent ~= nil and idempotent.Erased,
		"same-ID erasure retry was not idempotent")
	local conflicting, conflict_code = RecordStore.Mock.erase_user_data_async(
		"PlayerData_Test1", "global", key, user_id, "different-erasure-id",
		before.Generation, 10
	)
	expect(conflicting == nil and conflict_code == "conflict",
		"a different erasure ID replaced the permanent erasure fence")

	local loops, latest_progress = 0, nil
	repeat
		latest_progress, erase_code, erase_message = RecordStore.Mock.purge_erased_versions_async(
			"PlayerData_Test1", "global", key, user_id, "erase-generation-101", 1, 10
		)
		expect(erase_code == "success" and latest_progress ~= nil,
			"bounded historical purge failed: " .. tostring(erase_message))
		loops += 1
		expect(loops <= 20, "historical purge failed to make bounded progress")
	until latest_progress.Complete
	expect(latest_progress.Complete == true, "historical version purge did not reach completion")
	local history, history_code = RecordStore.Mock.list_versions_async(
		"PlayerData_Test1", "global", key, Enum.SortDirection.Descending, nil, nil, 100, 10
	)
	expect(history_code == "success" and history ~= nil and #history == 1,
		"historical profile versions remain after a verified purge")
	expect(history[1].Version == latest_progress.CurrentVersion,
		"purge removed the latest durable erasure fence version")
	record:Close()
end

-- A previously absent deterministic profile key is fenced too, preventing a
-- late first-time join from recreating data after the erasure inventory.
do
	local user_id = 102
	local key = "Player_" .. tostring(user_id)
	local absent, absent_code = RecordStore.Mock.get_erasure_status_async(
		"PlayerData_Test1", "global", key, user_id, 10
	)
	expect(absent_code == "not_found" and absent ~= nil and not absent.Erased,
		"absent profile did not produce an explicit not-found status")
	local erased, erase_code = RecordStore.Mock.erase_user_data_async(
		"PlayerData_Test1", "global", key, user_id, "erase-absent-102", 0, 10
	)
	expect(erase_code == "success" and erased ~= nil and erased.Erased,
		"first-time-key erasure fence failed")
	local late_join = RecordStore.Mock.new("PlayerData_Test1", "global", key, {
		schema_version = 1,
		user_ids = { user_id },
	})
	local open_result = late_join:Open({ kills = 0, equipped = "Default", admin = false })
	expect(open_result == "future_schema",
		"late first-time join recreated a key already fenced by erasure")
	late_join:Close()
end

-- End-to-end integration through the generic manifest coordinator. The known
-- PlayerDataCore family is explicitly audited for this fixture only; this does
-- not certify any other application-owned key family or live Roblox behavior.
do
	local user_id = 203
	local record, key = create_profile(user_id, 30)
	local manifest_store = new_manifest_store()
	local v2 = V2Module.new(RecordStore, RecordStore.MailboxV2)
	local erasure = ErasureModule.new(manifest_store, {
		record_store = RecordStore.Mock,
		record_store_v2 = { new = function() return v2 end },
		mailbox_module = RecordStore.MailboxV2,
		profile_store_name = "PlayerData_Test1",
		profile_scope = "global",
		key_prefix = "Player_",
		profile_family_verified = true,
		verify_templates = function(rendered_user_id, templates)
			return rendered_user_id == user_id and #templates == 1
				and templates[1].family == "PlayerDataCore"
				and templates[1].template.name == "PlayerData_Test1"
				and templates[1].template.scope == "global"
				and templates[1].template.key == "Player_" .. tostring(user_id)
		end,
		kick_player = function(kicked_user_id, _erasure_id)
			return kicked_user_id == user_id
		end,
	})

	local plan = erasure:PlanAsync(user_id, "erase-coordinator-203")
	expect(plan.code == "success" and plan.rtbf_coverage_verified == true,
		"verified PlayerDataCore plan failed: " .. tostring(plan.message))
	expect(#plan.entries == 1 and plan.entries[1].item.key == key,
		"erasure plan omitted the deterministic PlayerDataCore profile key")
	local progress = erasure:ExecuteAsync(user_id, "erase-coordinator-203", 1)
	expect(progress.code == "committed" and progress.rtbf_coverage_verified == true,
		"PlayerDataCore coordinator did not commit: " .. tostring(progress.message))
	local status = erasure:GetStatus(user_id)
	expect(status.status == "completed" and status.rtbf_coverage_verified == true,
		"completed erasure manifest did not preserve its verified coverage state")
	local is_erased, erased_status = erasure:IsErased(user_id)
	expect(is_erased == true and erased_status.status == "completed",
		"IsErased did not report the completed verified fixture")
	local blocked, block_status = erasure:ShouldBlockWrites(user_id)
	expect(blocked == true and block_status.status == "completed",
		"completed profile fence incorrectly reported writes as safe to resume")
	local latest, latest_code = RecordStore.Mock.read_async(
		"PlayerData_Test1", "global", key, 10
	)
	expect(latest == nil and latest_code == "future_schema",
		"coordinator completion left a readable profile value")
	record:Close()
end

RecordStore.Mock.reset()
