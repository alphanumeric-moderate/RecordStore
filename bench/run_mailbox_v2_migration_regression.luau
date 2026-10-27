--!nocheck
local Shim = require("./RobloxShim")
local initializer = Shim.environment.game:GetService("ServerScriptService"):WaitForChild("PlayerDataInitializer")
local Runner = Shim.environment.require(initializer:WaitForChild("RecordStoreMailboxV2Migration"))
local Adapter = Shim.environment.require(initializer:WaitForChild("RecordStoreMailboxV2MigrationAdapter"))

local function expect(value, message)
	assert(value, message)
end

local function copy(value, seen)
	if type(value) ~= "table" then return value end
	local memo = seen or {}
	if memo[value] ~= nil then return memo[value] end
	local result = {}
	memo[value] = result
	for key, item in pairs(value) do result[copy(key, memo)] = copy(item, memo) end
	return result
end

local function active_item(id, amount, created_at)
	return {
		id = id,
		type = "award",
		data = { amount = amount },
		attempts = 0,
		total_attempts = 0,
		replay_count = 0,
		created_at = created_at,
		sender_job_id = "legacy-server",
	}
end

local function dead_item(id, created_at)
	return {
		id = id,
		type = "legacy-dead-letter",
		data = { amount = 9 },
		attempts = 3,
		total_attempts = 3,
		replay_count = 1,
		created_at = created_at,
		sender_job_id = "legacy-server",
		dead_lettered_at = created_at + 1,
		last_error = "legacy-handler-failed",
	}
end

local function page(records, cursor, limit)
	local start = if cursor == nil then 0 else tonumber(cursor)
	if start == nil or start < 0 or math.floor(start) ~= start or tostring(start) ~= cursor then
		return nil, nil, false, "invalid source cursor"
	end
	local items = {}
	local finish = math.min(#records, start + limit)
	for index = start + 1, finish do items[#items + 1] = copy(records[index]) end
	local complete = finish >= #records
	return items, if complete then nil else tostring(finish), complete, nil
end

local function fixture(options)
	local settings = options or {}
	local state = {
		frozen = false,
		drained = settings.drained ~= false,
		freeze_valid = true,
		verify_calls = 0,
		freeze_calls = 0,
		imports = 0,
		active_source = settings.active or {
			active_item("active-a", 1, 100),
			active_item("active-b", 2, 101),
		},
		dead_source = settings.dead or { dead_item("dead-a", 110) },
		deliveries = {},
		checkpoint = nil,
		save_calls = 0,
		activation_calls = 0,
		v2_enabled = false,
		fail_import_once = settings.fail_import_once == true,
		lose_page_checkpoint_response = settings.lose_page_checkpoint_response == true,
		complete_verified = settings.complete_verified ~= false,
	}

	local mailbox = {}
	local function import(item, expected_state)
		state.imports += 1
		if state.fail_import_once then
			state.fail_import_once = false
			return { code = "unknown" }
		end
		local id = item.id or item.Id
		if state.deliveries[id] ~= nil then return { code = "duplicate" } end
		local created = item.created_at or item.CreatedAt
		local created_ms = math.floor(created * 1000)
		local deadlettered = item.dead_lettered_at or item.DeadLetteredAt
		local snapshot = {
			Id = id,
			Type = item.type or item.Type,
			State = expected_state,
			Attempts = item.attempts or item.Attempts or 0,
			TotalAttempts = item.total_attempts or item.TotalAttempts or item.attempts or item.Attempts or 0,
			ReplayCount = item.replay_count or item.ReplayCount or 0,
			CreatedAt = created_ms,
			SenderJobId = item.sender_job_id or item.SenderJobId or "",
			Data = copy(item.data ~= nil and item.data or item.Data),
		}
		if expected_state == "dead_lettered" then
			snapshot.DeadLetteredAt = if type(deadlettered) == "number" then math.floor(deadlettered * 1000) else created_ms
			snapshot.LastError = item.last_error or item.LastError or "Imported from legacy V3 dead-letter queue"
		end
		state.deliveries[id] = snapshot
		return { code = if expected_state == "ready" then "accepted" else "dead_lettered" }
	end

	function mailbox:ImportLegacyAsync(item, _migration_id)
		return import(item, "ready")
	end

	function mailbox:ImportLegacyDeadLetterAsync(item, _migration_id)
		return import(item, "dead_lettered")
	end

	function mailbox:GetDeliveryAsync(id)
		local found = state.deliveries[id]
		if found == nil then return nil, { code = "not_found" } end
		return copy(found), { code = "success" }
	end

	local config = {
		migration_id = "migration-regression-r1",
		mailbox = mailbox,
		freeze_legacy = function(migration_id)
			if migration_id ~= "migration-regression-r1" then return false, "wrong migration id" end
			state.freeze_calls += 1
			state.frozen = true
			return true
		end,
		legacy_writers_drained = function()
			return state.drained, if state.drained then nil else "legacy writers are still active"
		end,
		verify_source_frozen = function()
			state.verify_calls += 1
			if settings.lose_freeze_on_verify_call == state.verify_calls then
				return false, "injected source freeze loss"
			end
			return state.frozen and state.freeze_valid, "legacy source freeze is not confirmed"
		end,
		read_active_page = function(_migration_id, cursor, limit)
			return page(state.active_source, cursor, limit)
		end,
		read_dead_letter_page = function(_migration_id, cursor, limit)
			return page(state.dead_source, cursor, limit)
		end,
		load_checkpoint = function(_migration_id)
			return copy(state.checkpoint), nil
		end,
		save_checkpoint = function(_migration_id, expected_revision, candidate)
			state.save_calls += 1
			if expected_revision == nil then
				if state.checkpoint ~= nil then return false, "checkpoint already exists" end
			elseif state.checkpoint == nil or state.checkpoint.revision ~= expected_revision then
				return false, "checkpoint revision compare-and-set conflict"
			end
			state.checkpoint = copy(candidate)
			if expected_revision ~= nil and state.lose_page_checkpoint_response then
				state.lose_page_checkpoint_response = false
				return false, "injected checkpoint response loss after commit"
			end
			return true
		end,
		verify_complete = function(_migration_id, active_count, dead_count)
			return state.complete_verified
				and active_count == #state.active_source
				and dead_count == #state.dead_source,
				"source/destination counts or completion evidence did not reconcile"
		end,
		activate_v2 = function()
			state.activation_calls += 1
			state.v2_enabled = true
			return true
		end,
		now_ms = function() return 1800000000000 + state.save_calls end,
		page_size = 1,
	}
	return Runner.new(config), state
end

do
	local runner, state = fixture()
	local first = runner:Step(1)
	expect(first.code == "progress" and first.checkpoint.revision == 2
		and first.checkpoint.cursor == "1" and first.checkpoint.active_count == 1,
		"first active page did not produce a durable checkpoint")
	local second = runner:Step(1)
	expect(second.code == "progress" and second.checkpoint.phase == "dead_letters"
		and second.checkpoint.cursor == nil and second.checkpoint.active_count == 2,
		"terminal active page did not advance to the dead-letter phase")
	local third = runner:Step(1)
	expect(third.code == "ready_to_activate" and third.checkpoint.dead_letter_count == 1,
		"terminal dead-letter page did not enter the activation gate")
	local blocked = runner:Activate()
	expect(blocked.code == "complete" and state.v2_enabled and state.activation_calls == 1,
		"verified migration did not activate V2")
	local final = runner:GetStatus()
	expect(final ~= nil and final.phase == "activated" and final.revision == 5
		and final.active_count == 2 and final.dead_letter_count == 1,
		"durable activated checkpoint did not preserve reconciled source counts")
end

do
	local runner, state = fixture({ drained = false })
	local result = runner:Step(1)
	expect(result.code == "unknown" and state.frozen and state.checkpoint == nil
		and state.imports == 0,
		"migration advanced before legacy writers were confirmed drained")
end

do
	local runner, state = fixture({ fail_import_once = true })
	local failed = runner:Step(1)
	expect(failed.code == "unknown" and state.checkpoint ~= nil
		and state.checkpoint.revision == 1 and state.checkpoint.cursor == nil
		and state.checkpoint.active_count == 0,
		"unknown import outcome advanced its durable migration checkpoint")
	local retry = runner:Step(1)
	expect(retry.code == "progress" and retry.checkpoint.revision == 2
		and retry.checkpoint.cursor == "1" and retry.checkpoint.active_count == 1,
		"migration did not resume the same page after an unknown import")
	local snapshot, read_result = runner.mailbox:GetDeliveryAsync("active-a")
	expect(read_result.code == "success" and snapshot.State == "ready",
		"retry failed to produce a durable destination delivery")
end

do
	local runner, state = fixture({ lose_page_checkpoint_response = true })
	local result = runner:Step(1)
	expect(result.code == "progress" and result.checkpoint.revision == 2
		and state.checkpoint.revision == 2 and state.checkpoint.cursor == "1",
		"lost checkpoint response was not reconciled by uncached checkpoint readback")
	expect(state.imports == 1, "checkpoint response reconciliation repeated the page import")
end

do
	local runner, state = fixture({ lose_freeze_on_verify_call = 3 })
	local result = runner:Step(1)
	expect(result.code == "blocked" and state.checkpoint ~= nil
		and state.checkpoint.revision == 1 and state.checkpoint.cursor == nil
		and state.imports == 0,
		"source freeze loss before import allowed the migration checkpoint to advance")
end

do
	local runner, state = fixture({ complete_verified = false })
	while true do
		local status = runner:Step(1)
		if status.code == "ready_to_activate" then break end
		expect(status.code == "progress", "migration did not reach the completion gate")
	end
	local blocked = runner:Activate()
	expect(blocked.code == "blocked" and not state.v2_enabled and state.activation_calls == 0
		and state.checkpoint.phase == "ready_to_activate",
		"migration activated without independent completion verification")
end

do
	local fake_status = { MigrationId = "migration-adapter-contract" }
	local fake_store = {
		begin_mailbox_v2_migration_async = function() return "success", nil end,
		get_mailbox_v2_migration_status_async = function()
			return copy(fake_status), "success", nil
		end,
		get_mailbox_v2_migration_source_page_async = function()
			return {}, nil, true, "success", nil
		end,
	}
	local adapter = Adapter.bind({
		record_store = fake_store,
		store_name = "Profiles",
		scope = "global",
		profile_key = "Player_123",
		migration_id = "migration-adapter-contract",
		mailbox = {},
		legacy_writers_drained = function() return true end,
		load_checkpoint = function() return nil end,
		save_checkpoint = function() return true end,
		activate_v2 = function() return true end,
		verify_complete = function() return true end,
	})
	local invalid, invalid_message = adapter.verify_source_frozen("migration-adapter-contract")
	expect(invalid == false and invalid_message ~= nil,
		"adapter accepted a matching migration ID without durable freeze metadata")
	fake_status = {
		MigrationId = "migration-adapter-contract",
		FrozenAt = 0,
		SourceImplementationVersion = 2,
		ActiveCount = 0,
		DeadLetterCount = 0,
	}
	local valid, valid_message = adapter.verify_source_frozen("migration-adapter-contract")
	expect(valid == true and valid_message == nil,
		"adapter rejected a well-formed durable freeze marker")
	fake_status.FrozenAt = math.huge
	local malformed, malformed_message = adapter.verify_source_frozen("migration-adapter-contract")
	expect(malformed == false and malformed_message ~= nil,
		"adapter accepted a non-finite freeze timestamp")
end

print("[MailboxV2Migration] page migration, frozen-writer gate, unknown import retry, checkpoint response-loss recovery, freeze loss, completion gate, and adapter metadata regressions passed")
