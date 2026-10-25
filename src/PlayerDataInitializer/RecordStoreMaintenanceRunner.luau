--!nocheck
-- Independently invoked bounded maintenance runner.
-- The application supplies enumeration, inspection, dependency, durable-checkpoint and
-- generation-aware delete adapters. This module never guesses key layouts or deletes data itself.
local Runner = {}
local MAX_JOB_ID_BYTES = 96
local MAX_CURSOR_BYTES = 512

local function call(fn, ...)
	local result = table.pack(pcall(fn, ...))
	if not result[1] then return nil, tostring(result[2]) end
	return table.unpack(result, 2, result.n)
end

local function valid_text(value, max_bytes)
	return type(value) == "string" and value ~= "" and #value <= max_bytes
end

local function valid_integer(value, minimum)
	return type(value) == "number" and math.isfinite(value)
		and math.floor(value) == value and value >= minimum
end

local function validate_checkpoint(value, job_id)
	if type(value) ~= "table" then return nil end
	if value.version ~= 1 or value.job_id ~= job_id
		or not valid_integer(value.revision, 1)
		or (value.cursor ~= nil and not valid_text(value.cursor, MAX_CURSOR_BYTES))
		or not valid_integer(value.processed, 0) or not valid_integer(value.removed, 0)
		or type(value.status) ~= "string"
	then
		return nil
	end
	return table.clone(value)
end

local function same_checkpoint(left, right)
	return type(left) == "table"
		and left.version == right.version
		and left.job_id == right.job_id
		and left.revision == right.revision
		and left.cursor == right.cursor
		and left.processed == right.processed
		and left.removed == right.removed
		and left.status == right.status
end

function Runner.new(maintenance, config)
	if type(maintenance) ~= "table" or type(maintenance.NewCompactor) ~= "function" then
		error("RecordStoreV2 maintenance API with NewCompactor is required", 2)
	end
	if type(config) ~= "table" or not valid_text(config.job_id, MAX_JOB_ID_BYTES) then
		error("config.job_id must be 1 to 96 bytes", 2)
	end
	for _, field in ipairs({ "next_page", "inspect", "delete_if_generation", "load_checkpoint", "persist_checkpoint" }) do
		if type(config[field]) ~= "function" then error(field .. " callback is required", 2) end
	end
	local mode = if config.mode == nil then "dry_run" else config.mode
	if mode ~= "dry_run" and mode ~= "execute" then error("mode must be dry_run or execute", 2) end
	if config.initial_cursor ~= nil and not valid_text(config.initial_cursor, MAX_CURSOR_BYTES) then
		error("initial_cursor must be a string of at most 512 bytes", 2)
	end
	if mode == "execute" and (type(config.authorize) ~= "function" or type(config.assert_fence) ~= "function") then
		error("execute mode requires authorize and assert_fence callbacks", 2)
	end

	local loaded, load_error = call(config.load_checkpoint)
	if load_error ~= nil then error("maintenance checkpoint read failed: " .. tostring(load_error), 2) end
	local checkpoint = nil
	if loaded ~= nil then
		checkpoint = validate_checkpoint(loaded, config.job_id)
		if checkpoint == nil then error("maintenance checkpoint is malformed or belongs to another job", 2) end
	end
	local revision = if checkpoint then checkpoint.revision else 0
	local last_checkpoint = checkpoint
	local cursor = if checkpoint then checkpoint.cursor else config.initial_cursor
	local processed = if checkpoint then checkpoint.processed else 0
	local removed = if checkpoint then checkpoint.removed else 0
	local status = if checkpoint then checkpoint.status else "idle"
	local last_error = nil
	local would_delete = 0

	local function guard()
		if mode == "dry_run" then return true, nil end
		local authorized, authorization_error = call(config.authorize, config.job_id)
		if authorized ~= true then return false, authorization_error or "maintenance authorization denied" end
		local fenced, fence_error = call(config.assert_fence, config.job_id)
		if fenced ~= true then return false, fence_error or "durable writer fence is not held" end
		return true, nil
	end

	local compactor = maintenance.NewCompactor({
		initial_cursor = cursor,
		initial_processed = processed,
		initial_removed = removed,
		next_page = config.next_page,
		inspect = config.inspect,
		delete_if_generation = function(item, generation)
			if mode == "dry_run" then
				would_delete += 1
				return "dry_run", nil
			end
			local allowed, guard_error = guard()
			if not allowed then return "unknown", guard_error end
			local action, action_error = call(config.delete_if_generation, item, generation)
			if action ~= "deleted" and action ~= "already_absent" and action ~= "skipped" and action ~= "unknown" then
				return "unknown", action_error or "unsupported delete adapter result"
			end
			return action, action_error
		end,
		persist_progress = function(next_cursor, next_processed, next_removed, next_status)
			if next_cursor ~= nil and not valid_text(next_cursor, MAX_CURSOR_BYTES) then
				return false, "maintenance cursor must be a string of at most 512 bytes"
			end
			local proposed = {
				version = 1,
				job_id = config.job_id,
				revision = revision + 1,
				cursor = next_cursor,
				processed = next_processed,
				removed = next_removed,
				status = next_status,
			}
			local saved, save_error = call(config.persist_checkpoint, proposed, revision)
			if saved == true then
				revision = proposed.revision
				last_checkpoint = proposed
				cursor, processed, removed, status = next_cursor, next_processed, next_removed, next_status
				return true, nil
			end
			-- Resolve a lost response by accepting only the exact proposed checkpoint.
			local observed, read_error = call(config.load_checkpoint)
			local verified = validate_checkpoint(observed, config.job_id)
			if same_checkpoint(verified, proposed) then
				revision = proposed.revision
				last_checkpoint = proposed
				cursor, processed, removed, status = next_cursor, next_processed, next_removed, next_status
				return true, nil
			end
			last_error = tostring(save_error or read_error or "maintenance checkpoint result unresolved")
			return false, last_error
		end,
	})
	if type(compactor) ~= "table" or type(compactor.RunStep) ~= "function" or type(compactor.Stats) ~= "function" then
		error("maintenance compactor did not provide RunStep and Stats", 2)
	end

	local runner = { job_id = config.job_id, mode = mode, status = status }
	function runner:Step(max_items, budget_ms)
		if self.status == "completed" then
			return { code = "completed", job_id = config.job_id, mode = mode, cursor = cursor }
		end
		local allowed, guard_error = guard()
		if not allowed then
			self.status = "blocked"
			last_error = tostring(guard_error)
			return { code = "blocked", job_id = config.job_id, mode = mode, message = last_error }
		end
		local result, step_error = call(function() return compactor:RunStep(max_items, budget_ms) end)
		if type(result) ~= "table" then
			self.status = "unknown"
			last_error = tostring(step_error or "compactor returned no result")
			return { code = "unknown", job_id = config.job_id, mode = mode, message = last_error }
		end
		self.status = tostring(result.code or "unknown")
		if result.message ~= nil then last_error = tostring(result.message) end
		local output = table.clone(result)
		output.job_id = config.job_id
		output.mode = mode
		output.would_delete = would_delete
		output.checkpoint_revision = revision
		return output
	end
	function runner:Run(max_steps, batch_size, budget_ms)
		local step_limit = math.clamp(math.floor(max_steps or 8), 1, 64)
		local size = math.clamp(math.floor(batch_size or 32), 1, 256)
		local per_step_budget = math.clamp(math.floor(budget_ms or 25), 1, 1000)
		local result = { code = "yielded", job_id = config.job_id, mode = mode }
		for _ = 1, step_limit do
			result = self:Step(size, per_step_budget)
			if result.code ~= "incomplete" then return result end
		end
		result.code = "yielded"
		result.max_steps = step_limit
		return result
	end
	function runner:Stats()
		local result = table.clone(compactor:Stats())
		result.job_id = config.job_id
		result.mode = mode
		result.checkpoint_revision = revision
		result.would_delete = would_delete
		result.last_error = last_error or result.last_error
		return result
	end
	function runner:GetCheckpoint()
		return last_checkpoint
	end
	return runner
end

return Runner
