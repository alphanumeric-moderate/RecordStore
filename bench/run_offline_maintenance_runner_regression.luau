--!nocheck
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Shim = require("./RobloxShim")
local RecordStore = Shim.load()
local V2Module = luau.load(fs.readFile("src/PlayerDataInitializer/RecordStoreV2.luau"), {
	debugName = "RecordStoreV2",
})()
local V2 = V2Module.new(RecordStore, RecordStore.MailboxV2)
local Runner = luau.load(fs.readFile("src/PlayerDataInitializer/RecordStoreMaintenanceRunner.luau"), {
	debugName = "RecordStoreMaintenanceRunner",
})()

local function expect(value, message)
	assert(value, message)
end

local durable_checkpoint = nil
local rows = {
	{ key = "expired-a", generation = 4, eligible = true },
	{ key = "active-b", generation = 5, eligible = false },
	{ key = "expired-c", generation = 6, eligible = true },
}
local delete_calls = {}
local checkpoint_response_lost = false

local function copy(value)
	if type(value) ~= "table" then return value end
	local out = {}
	for key, item in pairs(value) do out[key] = copy(item) end
	return out
end

local function common_config(job_id, mode)
	return {
		job_id = job_id,
		mode = mode,
		next_page = function(cursor, maximum)
			local start = 0
			if cursor ~= nil then start = tonumber(string.match(cursor, "^row:(%d+)$")) or 0 end
			local page = {}
			for i = start + 1, math.min(#rows, start + maximum) do table.insert(page, copy(rows[i])) end
			local finish = start + #page
			return page, if finish >= #rows then nil else "row:" .. tostring(finish), finish >= #rows
		end,
		inspect = function(item)
			local row = item
			return { status = "success", eligible = row.eligible, dependencies_clear = true, generation = row.generation }
		end,
		delete_if_generation = function(item, generation)
			delete_calls[#delete_calls + 1] = { key = item.key, generation = generation }
			for i, row in ipairs(rows) do
				if row.key == item.key then
					if row.generation ~= generation then return "skipped" end
					table.remove(rows, i)
					return "deleted"
				end
			end
			return "already_absent"
		end,
		load_checkpoint = function() return copy(durable_checkpoint) end,
		persist_checkpoint = function(checkpoint, expected_revision)
			local observed_revision = if durable_checkpoint == nil then 0 else durable_checkpoint.revision
			if observed_revision ~= expected_revision then return false, "checkpoint revision conflict" end
			durable_checkpoint = copy(checkpoint)
			if checkpoint_response_lost then
				checkpoint_response_lost = false
				return false, "injected response loss after checkpoint commit"
			end
			return true
		end,
	}
end

-- Dry-run persists bounded progress but never calls the destructive adapter.
local dry = Runner.new(V2.Maintenance, common_config("dry-run-1", "dry_run"))
local dry_result = dry:Run(1, 1, 500)
expect(dry_result.code == "yielded" and dry_result.cursor == "row:1",
	"dry-run failed to yield after its bounded first page")
expect(#delete_calls == 0 and dry_result.would_delete == 1,
	"dry-run invoked the destructive adapter or failed to count eligible rows")
expect(durable_checkpoint ~= nil and durable_checkpoint.job_id == "dry-run-1"
	and durable_checkpoint.revision == 1 and durable_checkpoint.cursor == "row:1",
	"dry-run did not persist an identity-bound checkpoint")

local exposed_checkpoint = dry:GetCheckpoint()
expect(exposed_checkpoint ~= nil and exposed_checkpoint.cursor == "row:1",
	"runner did not return its last durable checkpoint")
exposed_checkpoint.cursor = "row:999"
expect(dry:GetCheckpoint().cursor == "row:1",
	"mutating a returned checkpoint snapshot changed runner state")
local resumed_dry = Runner.new(V2.Maintenance, common_config("dry-run-1", "dry_run"))
local dry_complete = resumed_dry:Run(8, 1, 500)
expect(dry_complete.code == "completed" and #delete_calls == 0,
	"dry-run did not resume from its durable checkpoint without deleting data")

-- Execute mode cannot be constructed without both authorization and a durable writer fence.
expect(not pcall(function()
	Runner.new(V2.Maintenance, common_config("unguarded", "execute"))
end), "execute runner accepted missing authorization/fence callbacks")

-- A committed checkpoint with a lost response is accepted only after exact read-back.
durable_checkpoint = nil
checkpoint_response_lost = true
local loss_runner = Runner.new(V2.Maintenance, common_config("checkpoint-response-loss", "dry_run"))
local loss_result = loss_runner:Step(1, 500)
expect(loss_result.code == "incomplete" and loss_result.checkpoint_revision == 1,
	"runner did not reconcile a durable checkpoint whose response was lost")
expect(durable_checkpoint ~= nil and durable_checkpoint.cursor == "row:1",
	"checkpoint response-loss fixture did not persist the first page")

-- The run-level fence passes, then disappears immediately before deletion.
durable_checkpoint = nil
rows = { { key = "delete-me", generation = 10, eligible = true } }
local fence_checks = 0
local execute_config = common_config("execute-fenced", "execute")
execute_config.authorize = function() return true end
execute_config.assert_fence = function()
	fence_checks += 1
	return fence_checks == 1
end
local execute_runner = Runner.new(V2.Maintenance, execute_config)
local blocked = execute_runner:Step(1, 500)
expect(blocked.code == "unknown",
	"lost writer fence did not stop execution with an unresolved result")
expect(#delete_calls == 0,
	"runner deleted data after its writer fence was lost before the destructive operation")

do -- Slow storage reads must not starve single-key maintenance progress.
	local late_rows = {
		{ key = "late-a", generation = 1, eligible = true },
		{ key = "late-b", generation = 2, eligible = true },
	}
	local late_checkpoint = nil
	local late_page_calls = 0
	local late_config = {
		job_id = "slow-page-read",
		mode = "dry_run",
		next_page = function(cursor, maximum)
			late_page_calls += 1
			local deadline = os.clock() + 0.015
			while os.clock() < deadline do end
			local page = {}
			for _, row in ipairs(late_rows) do
				if cursor == nil or row.key > cursor then
					table.insert(page, copy(row))
					if #page >= maximum then break end
				end
			end
			local last_key = if #page > 0 then page[#page].key else cursor
			local more = false
			if last_key ~= nil then
				for _, row in ipairs(late_rows) do
					if row.key > last_key then more = true; break end
				end
			else
				more = #late_rows > 0
			end
			return page, if more then last_key else nil, not more
		end,
		inspect = function(item)
			return { status = "success", eligible = item.eligible, dependencies_clear = true, generation = item.generation }
		end,
		delete_if_generation = function() error("dry-run must never delete") end,
		load_checkpoint = function() return copy(late_checkpoint) end,
		persist_checkpoint = function(checkpoint, expected_revision)
			local revision = if late_checkpoint == nil then 0 else late_checkpoint.revision
			if revision ~= expected_revision then return false, "checkpoint revision conflict" end
			late_checkpoint = copy(checkpoint)
			return true
		end,
	}
	local slow_runner = Runner.new(V2.Maintenance, late_config)
	local first_yield = slow_runner:Run(8, 1, 1)
	expect(first_yield.code == "yielded" and late_checkpoint ~= nil
		and late_checkpoint.cursor == "late-a" and late_checkpoint.processed == 1,
		"slow single-key page read starved progress instead of checkpointing and yielding")
	local resumed_runner = Runner.new(V2.Maintenance, late_config)
	local resumed_result = resumed_runner:Run(8, 1, 500)
	expect(resumed_result.code == "completed" and late_checkpoint.status == "completed"
		and late_checkpoint.processed == 2 and late_page_calls == 2,
		"maintenance did not resume after a slow page read without replaying completed work")
end

do -- Validate generation-aware deletes in execute mode across resumable per-key checkpoints.
	local execute_rows = {
		{ key = "a-expired", generation = 1, eligible = true },
		{ key = "b-active", generation = 2, eligible = false },
		{ key = "c-race", generation = 3, eligible = true },
		{ key = "d-expired", generation = 4, eligible = true },
	}
	local execute_checkpoint = nil
	local delete_outcomes = {}
	local changed_race_generation = false
	local function execute_next_page(cursor, maximum)
		local page = {}
		for _, row in ipairs(execute_rows) do
			if cursor == nil or row.key > cursor then
				table.insert(page, copy(row))
				if #page >= maximum then break end
			end
		end
		local last_key = if #page > 0 then page[#page].key else cursor
		local more = false
		if last_key ~= nil then
			for _, row in ipairs(execute_rows) do
				if row.key > last_key then more = true; break end
			end
		else
			more = #execute_rows > 0
		end
		return page, if more then last_key else nil, not more
	end
	local live_config = {
		job_id = "execute-success",
		mode = "execute",
		next_page = execute_next_page,
		inspect = function(item)
			return {
				status = "success",
				eligible = item.eligible,
				dependencies_clear = true,
				generation = item.generation,
			}
		end,
		delete_if_generation = function(item, generation)
			for index, row in ipairs(execute_rows) do
				if row.key == item.key then
					if row.key == "c-race" and not changed_race_generation then
						row.generation += 1
						changed_race_generation = true
					end
					if row.generation ~= generation then
						table.insert(delete_outcomes, { key = item.key, outcome = "skipped" })
						return "skipped"
					end
					table.remove(execute_rows, index)
					table.insert(delete_outcomes, { key = item.key, outcome = "deleted" })
					return "deleted"
				end
			end
			return "already_absent"
		end,
		load_checkpoint = function() return copy(execute_checkpoint) end,
		persist_checkpoint = function(checkpoint, expected_revision)
			local current_revision = if execute_checkpoint == nil then 0 else execute_checkpoint.revision
			if current_revision ~= expected_revision then return false, "checkpoint revision conflict" end
			execute_checkpoint = copy(checkpoint)
			return true
		end,
		authorize = function() return true end,
		assert_fence = function() return true end,
	}
	local live_runner = Runner.new(V2.Maintenance, live_config)
	local live_result = live_runner:Run(8, 1, 500)
	local stats = live_runner:Stats()
	expect(live_result.code == "completed" and stats.status == "completed",
		"execute-mode runner failed to complete a bounded generation-aware scan")
	expect(stats.processed == 4 and stats.removed == 2 and #delete_outcomes == 3,
		"execute-mode counters did not reflect processed, deleted, and skipped rows")
	expect(delete_outcomes[1].key == "a-expired" and delete_outcomes[1].outcome == "deleted"
		and delete_outcomes[2].key == "c-race" and delete_outcomes[2].outcome == "skipped"
		and delete_outcomes[3].key == "d-expired" and delete_outcomes[3].outcome == "deleted",
		"execute mode did not preserve generation-change protection")
	expect(#execute_rows == 2 and execute_rows[1].key == "b-active"
		and execute_rows[2].key == "c-race" and execute_rows[2].generation == 4,
		"execute mode deleted an ineligible row or a generation that changed after inspection")
	expect(execute_checkpoint ~= nil and execute_checkpoint.status == "completed"
		and execute_checkpoint.revision == 4 and execute_checkpoint.processed == 4
		and execute_checkpoint.removed == 2,
		"execute mode did not persist durable progress after each key")
end

print("[OfflineMaintenanceRunner] dry-run, resume, checkpoint response-loss, fencing, and execute-mode generation checks passed.")
Shim.close()
