--!nocheck
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Shim = require("./RobloxShim")
local RecordStore = Shim.load()
local V2Module = require(game:GetService("ServerScriptService"):WaitForChild("PlayerDataInitializer"):WaitForChild("RecordStoreV2"))
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

print("[OfflineMaintenanceRunner] bounded pages, dry-run isolation, resume, checkpoint response-loss reconciliation, and writer-fence checks passed.")
Shim.close()
