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
	if cursor ~= nil and (
		start == nil or start < 0 or math.floor(start) ~= start or tostring(start) ~= cursor
	) then
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
		lose_import_response_once = settings.lose_import_response_once == true,
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
		if state.lose_import_response_once then
			state.lose_import_response_once = false
			return { code = "unknown" }
		end
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
	local first_checkpoint = first.checkpoint
	expect(first.code == "progress" and first_checkpoint ~= nil
		and first_checkpoint.revision == 2
		and first_checkpoint.cursor == "1" and first_checkpoint.active_count == 1,
		("first active page did not produce a durable checkpoint: code=%s message=%s checkpoint=%s"):format(
			tostring(first.code), tostring(first.message),
			if first_checkpoint == nil then "nil" else ("revision=%s phase=%s cursor=%s active=%s dead=%s"):format(
				tostring(first_checkpoint.revision), tostring(first_checkpoint.phase),
				tostring(first_checkpoint.cursor), tostring(first_checkpoint.active_count),
				tostring(first_checkpoint.dead_letter_count)
			)
		))
	local second = runner:Step(1)
	local second_checkpoint = second.checkpoint
	expect(second.code == "progress" and second_checkpoint ~= nil
		and second_checkpoint.phase == "dead_letters"
		and second_checkpoint.cursor == nil and second_checkpoint.active_count == 2,
		("terminal active page did not advance to the dead-letter phase: code=%s message=%s checkpoint=%s"):format(
			tostring(second.code), tostring(second.message),
			if second_checkpoint == nil then "nil" else ("revision=%s phase=%s cursor=%s active=%s dead=%s"):format(
				tostring(second_checkpoint.revision), tostring(second_checkpoint.phase),
				tostring(second_checkpoint.cursor), tostring(second_checkpoint.active_count),
				tostring(second_checkpoint.dead_letter_count)
			)
		))
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
	local runner, state = fixture({ lose_import_response_once = true })
	local lost = runner:Step(1)
	expect(lost.code == "unknown" and state.checkpoint ~= nil
		and state.checkpoint.revision == 1 and state.checkpoint.cursor == nil
		and state.checkpoint.active_count == 0 and state.deliveries["active-a"] ~= nil,
		"lost successful import response advanced the checkpoint or lost the committed destination")
	local retry = runner:Step(1)
	expect(retry.code == "progress" and retry.checkpoint.revision == 2
		and retry.checkpoint.cursor == "1" and retry.checkpoint.active_count == 1
		and state.imports == 2,
		"duplicate retry did not read back and reconcile the previously committed import")
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

-- Reject malformed pagination before importing any record or advancing a cursor.
for _, case in {
	{ name = "sparse page", items = { [2] = active_item("sparse", 1, 100) }, complete = true },
	{ name = "keyed page", items = { extra = active_item("keyed", 1, 100) }, complete = true },
	{ name = "oversized page", items = { active_item("a", 1, 100), active_item("b", 2, 101) }, complete = true },
	{ name = "missing completion", items = {} },
	{ name = "nonboolean completion", items = {}, complete = "true" },
	{ name = "terminal cursor", items = {}, complete = true, cursor = "1" },
	{ name = "missing continuation", items = {}, complete = false },
	{ name = "empty continuation", items = {}, complete = false, cursor = "" },
	{ name = "oversized continuation", items = {}, complete = false, cursor = string.rep("c", 1025) },
} do
	local runner, state = fixture()
	runner.read_active_page = function() return case.items, case.cursor, case.complete end
	local result = runner:Step(1)
	expect(result.code == "blocked" and state.imports == 0
		and state.checkpoint.revision == 1 and state.checkpoint.active_count == 0
		and state.checkpoint.cursor == nil, "malformed source page advanced migration: " .. case.name)
end

do -- A cursor at the documented limit is valid, but it must advance on retry.
	local runner, state = fixture()
	local cursor = string.rep("c", 1024)
	runner.read_active_page = function() return {}, cursor, false end
	expect(runner:Step(1).code == "progress" and state.checkpoint.cursor == cursor,
		"migration rejected a cursor at the exact byte limit")
	local revision = state.checkpoint.revision
	expect(runner:Step(1).code == "blocked" and state.checkpoint.revision == revision and state.imports == 0,
		"migration accepted a nonadvancing continuation cursor")
end

-- A duplicate ID must still prove the entire imported record. In particular,
-- dead-letter metadata must survive migration, and extra payload fields conflict.
for _, phase in { "active", "dead_letters" } do
	local mutations = {
		{ field = "Id", value = "wrong-id" }, { field = "Type", value = "wrong-type" },
		{ field = "State", value = "claimed" }, { field = "Attempts", value = 99 },
		{ field = "TotalAttempts", value = 99 }, { field = "ReplayCount", value = 99 },
		{ field = "CreatedAt", value = 1 }, { field = "SenderJobId", value = "wrong-server" },
		{ field = "Data", value = { amount = 1, unexpected = true } },
	}
	if phase == "dead_letters" then
		table.insert(mutations, { field = "DeadLetteredAt", value = 1 })
		table.insert(mutations, { field = "LastError", value = "different-error" })
	end
	for _, mutation in ipairs(mutations) do
		local runner, state = fixture({ active = if phase == "active" then { active_item("one", 1, 100) } else {} })
		if phase == "dead_letters" then
			expect(runner:Step(1).code == "progress", "empty active phase did not advance")
		end
		if phase == "active" then
			runner.mailbox:ImportLegacyAsync(state.active_source[1], runner.migration_id)
		else
			runner.mailbox:ImportLegacyDeadLetterAsync(state.dead_source[1], runner.migration_id)
		end
		state.imports = 0
		local before = copy(state.checkpoint)
		local read = runner.mailbox.GetDeliveryAsync
		function runner.mailbox:GetDeliveryAsync(id)
			local snapshot, result = read(self, id)
			snapshot[mutation.field] = copy(mutation.value)
			return snapshot, result
		end
		local result = runner:Step(1)
		expect(result.code == "blocked" and state.imports == 1
			and state.checkpoint.revision == (if before then before.revision else 1)
			and state.checkpoint.cursor == nil and state.checkpoint.active_count == 0
			and state.checkpoint.dead_letter_count == 0 and state.activation_calls == 0,
			"mismatching imported receipt advanced " .. phase .. ": " .. mutation.field)
	end
end

do
	local runner, state = fixture({ active = {}, dead = {} })
	expect(runner:Activate().code == "unknown" and state.activation_calls == 0,
		"migration activated without a checkpoint")
	expect(runner:Step(1).code == "progress" and runner:Activate().code == "blocked",
		"migration activated before scanning dead letters")
	expect(runner:Step(1).code == "ready_to_activate" and runner:Activate().code == "complete",
		"empty inventories could not complete migration")
	local revision, saves = state.checkpoint.revision, state.save_calls
	expect(runner:Activate().code == "complete" and runner:Step(1).code == "complete"
		and state.activation_calls == 1 and state.checkpoint.revision == revision and state.save_calls == saves,
		"replaying completed migration repeated activation or durable writes")
end

do -- The concrete bridge must preserve source locators and gate completion proof.
	local calls, verification_calls = {}, 0
	local status = "success"
	local snapshot = { MigrationId = "bridge", FrozenAt = 0, SourceImplementationVersion = 2,
		ActiveCount = 3, DeadLetterCount = 2 }
	local store = {
		begin_mailbox_v2_migration_async = function(...) calls.freeze = table.pack(...); return status, "source unavailable" end,
		get_mailbox_v2_migration_status_async = function(...) calls.status = table.pack(...); return copy(snapshot), status, "source unavailable" end,
		get_mailbox_v2_migration_source_page_async = function(...)
			calls.page = table.pack(...)
			return { { id = "source-row" } }, "next", false, status, "source unavailable"
		end,
	}
	local adapter = Adapter.bind({
		record_store = store, store_name = "Profiles", scope = "", profile_key = "Player_1",
		migration_id = "bridge", mailbox = {}, queue_store_name = "LegacyQueue",
		max_queue_bytes = 1000, operation_deadline = 7,
		legacy_writers_drained = function() return true end, load_checkpoint = function() return nil end,
		save_checkpoint = function() return true end, activate_v2 = function() return true end,
		verify_complete = function(id, active, dead)
			verification_calls += 1
			expect(id == "bridge" and active == 3 and dead == 2, "completion proof lost count/identity")
			return true
		end,
	})
	for _, method in { "freeze_legacy", "verify_source_frozen", "verify_complete", "read_active_page", "read_dead_letter_page" } do
		local result = table.pack(adapter[method]("other-migration", nil, 1))
		expect(not result[1] and type(result[result.n]) == "string" and next(calls) == nil and verification_calls == 0,
			"wrong migration ID reached the source: " .. method)
	end
	expect(adapter.freeze_legacy("bridge") == true and calls.freeze.n == 7
		and calls.freeze[1] == "Profiles" and calls.freeze[2] == "" and calls.freeze[3] == "Player_1"
		and calls.freeze[4] == "bridge" and calls.freeze[5] == "LegacyQueue"
		and calls.freeze[6] == 1000 and calls.freeze[7] == 7, "freeze lost source locator/options")
	for _, kind in { "active", "dead_letter" } do
		local read = if kind == "active" then adapter.read_active_page else adapter.read_dead_letter_page
		local items, cursor, complete, message = read("bridge", "previous", 4)
		expect(items[1].id == "source-row" and cursor == "next" and complete == false and message == nil
			and calls.page.n == 10 and calls.page[5] == kind and calls.page[6] == "previous"
			and calls.page[7] == 4 and calls.page[8] == "LegacyQueue" and calls.page[9] == 1000
			and calls.page[10] == 7, "page bridge lost pagination or queue options")
	end
	expect(adapter.verify_complete("bridge", 2, 2) == false and verification_calls == 0,
		"mismatched active count reached application completion proof")
	expect(adapter.verify_complete("bridge", 3, 1) == false and verification_calls == 0,
		"mismatched dead-letter count reached application completion proof")
	expect(adapter.verify_complete("bridge", 3, 2) == true and verification_calls == 1,
		"matching source counts did not reach completion proof")
	status = "unknown"
	local items, cursor, complete, message = adapter.read_active_page("bridge", nil, 1)
	expect(items == nil and cursor == nil and complete == false and string.find(message, "unknown", 1, true),
		"uncertain source read exposed unverified items")
	expect(adapter.freeze_legacy("bridge") == false and adapter.verify_source_frozen("bridge") == false
		and adapter.verify_complete("bridge", 3, 2) == false and verification_calls == 1,
		"uncertain source state passed a migration gate")
end

print("[MailboxV2Migration] pagination, import identity, replay, source bridge and migration recovery regressions passed")
