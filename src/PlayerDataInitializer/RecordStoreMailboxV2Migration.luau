--!strict
-- Bounded V3-to-V2 mailbox migration coordinator.
-- The application owns every legacy storage layout, source freeze/writer fence,
-- durable compare-and-swap checkpoint, inventory verification, and activation gate.
-- This module never deletes the legacy source.

local Runner = {}

type LegacyMessage = { [string]: any }
type Checkpoint = {
	version: number,
	migration_id: string,
	revision: number,
	phase: string,
	status: string,
	cursor: string?,
	active_count: number,
	dead_letter_count: number,
	updated_at_ms: number,
	activated_at_ms: number?,
}

type Config = {
	migration_id: string,
	mailbox: any,
	freeze_legacy: (string) -> (boolean, string?),
	legacy_writers_drained: (string) -> (boolean, string?),
	verify_source_frozen: (string) -> (boolean, string?),
	read_active_page: (string, string?, number) -> ({ LegacyMessage }, string?, boolean, string?),
	read_dead_letter_page: (string, string?, number) -> ({ LegacyMessage }, string?, boolean, string?),
	load_checkpoint: (string) -> (Checkpoint?, string?),
	save_checkpoint: (string, number?, Checkpoint) -> (boolean, string?),
	verify_complete: (string, number, number) -> (boolean, string?),
	activate_v2: (string) -> (boolean, string?),
	now_ms: (() -> number)?,
	page_size: number?,
}

local MAX_PAGE_SIZE = 100
local MAX_CURSOR_BYTES = 1024

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function valid_text(value: any, maximum: number): boolean
	return type(value) == "string" and value ~= "" and #value <= maximum
end

local function now_default(): number
	return DateTime.now().UnixTimestampMillis
end

local function copy_checkpoint(value: Checkpoint): Checkpoint
	return {
		version = value.version,
		migration_id = value.migration_id,
		revision = value.revision,
		phase = value.phase,
		status = value.status,
		cursor = value.cursor,
		active_count = value.active_count,
		dead_letter_count = value.dead_letter_count,
		updated_at_ms = value.updated_at_ms,
		activated_at_ms = value.activated_at_ms,
	}
end

local function validate_checkpoint(value: any, migration_id: string): (Checkpoint?, string?)
	if type(value) ~= "table" or value.version ~= 1 or value.migration_id ~= migration_id then
		return nil, "migration checkpoint version or identity is invalid"
	end
	if not finite(value.revision) or value.revision < 1 or math.floor(value.revision) ~= value.revision then
		return nil, "migration checkpoint revision is malformed"
	end
	if value.phase ~= "active" and value.phase ~= "dead_letters"
		and value.phase ~= "ready_to_activate" and value.phase ~= "activated"
	then
		return nil, "migration checkpoint phase is unsupported"
	end
	if value.cursor ~= nil and not valid_text(value.cursor, MAX_CURSOR_BYTES) then
		return nil, "migration checkpoint cursor is malformed"
	end
	for _, field in ipairs({ "active_count", "dead_letter_count" }) do
		local amount = value[field]
		if not finite(amount) or amount < 0 or math.floor(amount) ~= amount then
			return nil, "migration checkpoint counters are malformed"
		end
	end
	if not finite(value.updated_at_ms) or value.updated_at_ms < 0 then
		return nil, "migration checkpoint timestamp is malformed"
	end
	if value.phase == "activated" and (not finite(value.activated_at_ms) or value.activated_at_ms < 0) then
		return nil, "activated checkpoint lacks its activation timestamp"
	end
	return copy_checkpoint(value :: Checkpoint), nil
end

local function same_checkpoint(left: Checkpoint?, right: Checkpoint): boolean
	return left ~= nil
		and left.version == right.version
		and left.migration_id == right.migration_id
		and left.revision == right.revision
		and left.phase == right.phase
		and left.status == right.status
		and left.cursor == right.cursor
		and left.active_count == right.active_count
		and left.dead_letter_count == right.dead_letter_count
		and left.updated_at_ms == right.updated_at_ms
		and left.activated_at_ms == right.activated_at_ms
end

local function dense_page(items: any, maximum: number): (boolean, number)
	if type(items) ~= "table" then return false, 0 end
	local count, highest = 0, 0
	for key in pairs(items) do
		if type(key) ~= "number" or not finite(key) or key < 1 or math.floor(key) ~= key then return false, 0 end
		count += 1
		highest = math.max(highest, key)
	end
	return count == highest and count <= maximum, count
end

local function deep_equal(left: any, right: any, depth: number?): boolean
	local level = depth or 0
	if level > 64 then return false end
	if left == right then return true end
	if type(left) ~= type(right) or type(left) ~= "table" then return false end
	local left_count, right_count = 0, 0
	for key, value in pairs(left) do
		left_count += 1
		if not deep_equal(value, right[key], level + 1) then return false end
	end
	for _ in pairs(right) do right_count += 1 end
	return left_count == right_count
end

local function legacy_fields(item: LegacyMessage): (string?, string?, any, number, number, number, number, string?)
	local id = if type(item.id) == "string" then item.id else item.Id
	local message_type = if type(item.type) == "string" then item.type else item.Type
	local payload = if item.data ~= nil then item.data else item.Data
	local attempts = if finite(item.attempts) then item.attempts else 0
	local total = if finite(item.total_attempts) then item.total_attempts else attempts
	local replay = if finite(item.replay_count) then item.replay_count else 0
	local created_seconds = if finite(item.created_at) then item.created_at else item.CreatedAt
	local error_message = if type(item.last_error) == "string" then item.last_error else item.LastError
	if not valid_text(id, 50) or not valid_text(message_type, 100)
		or not finite(created_seconds) or created_seconds < 0 or created_seconds > 9_007_199_254_740
		or not finite(attempts) or attempts < 0 or math.floor(attempts) ~= attempts
		or not finite(total) or total < attempts or math.floor(total) ~= total
		or not finite(replay) or replay < 0 or math.floor(replay) ~= replay
	then
		return nil, nil, nil, 0, 0, 0, 0, "legacy message fields are malformed"
	end
	return id, message_type, payload, attempts, total, replay, math.floor(created_seconds * 1000), error_message
end

local function adapter_call(callback: (...any) -> ...any, ...: any): (boolean, any, any, any, any)
	local packed = table.pack(pcall(callback, ...))
	if not packed[1] then return false, nil, nil, nil, nil end
	return true, packed[2], packed[3], packed[4], packed[5]
end

function Runner.new(config: Config)
	if type(config) ~= "table" then error("migration config must be a table", 2) end
	if not valid_text(config.migration_id, 96) then error("migration_id must be 1 to 96 bytes", 2) end
	if type(config.mailbox) ~= "table"
		or type(config.mailbox.ImportLegacyAsync) ~= "function"
		or type(config.mailbox.ImportLegacyDeadLetterAsync) ~= "function"
		or type(config.mailbox.GetDeliveryAsync) ~= "function"
	then
		error("mailbox must expose legacy import and delivery APIs", 2)
	end
	for _, field in ipairs({
		"freeze_legacy", "legacy_writers_drained", "verify_source_frozen",
		"read_active_page", "read_dead_letter_page", "load_checkpoint",
		"save_checkpoint", "verify_complete", "activate_v2",
	}) do
		if type(config[field]) ~= "function" then error(field .. " callback is required", 2) end
	end
	local page_size = config.page_size or 16
	if not finite(page_size) or math.floor(page_size) ~= page_size or page_size < 1 or page_size > MAX_PAGE_SIZE then
		error("page_size must be an integer from 1 to 100", 2)
	end
	local now_ms = config.now_ms or now_default
	if type(now_ms) ~= "function" then error("now_ms must be a function", 2) end

	local self = {
		migration_id = config.migration_id,
		mailbox = config.mailbox,
		freeze_legacy = config.freeze_legacy,
		legacy_writers_drained = config.legacy_writers_drained,
		verify_source_frozen = config.verify_source_frozen,
		read_active_page = config.read_active_page,
		read_dead_letter_page = config.read_dead_letter_page,
		load_checkpoint = config.load_checkpoint,
		save_checkpoint = config.save_checkpoint,
		verify_complete = config.verify_complete,
		activate_v2 = config.activate_v2,
		now_ms = now_ms,
		page_size = page_size,
		busy = false,
	}

	local function load()
		local ok, raw, message = adapter_call(self.load_checkpoint, self.migration_id)
		if not ok then return nil, "checkpoint read callback failed" end
		if raw == nil then
			if message ~= nil then return nil, tostring(message) end
			return nil, nil
		end
		local checkpoint, validation_error = validate_checkpoint(raw, self.migration_id)
		if checkpoint == nil then return nil, validation_error end
		return checkpoint, nil
	end

	local function verify_frozen()
		local frozen_ok, frozen, frozen_message = adapter_call(self.verify_source_frozen, self.migration_id)
		if not frozen_ok or frozen ~= true then
			return false, if type(frozen_message) == "string" then frozen_message else "legacy source freeze is not confirmed"
		end
		local drained_ok, drained, drained_message = adapter_call(self.legacy_writers_drained, self.migration_id)
		if not drained_ok or drained ~= true then
			return false, if type(drained_message) == "string" then drained_message else "legacy writer drain is not confirmed"
		end
		return true, nil
	end

	local function persist(expected_revision: number?, candidate: Checkpoint): (boolean, string?)
		local ok, saved, save_message = adapter_call(self.save_checkpoint, self.migration_id, expected_revision, candidate)
		if ok and saved == true then return true, nil end
		local observed, read_error = load()
		if observed ~= nil and same_checkpoint(observed, candidate) then return true, nil end
		return false, if type(save_message) == "string" then save_message
			elseif read_error ~= nil then read_error
			else "checkpoint commit is not yet proven"
	end

	local function advance(checkpoint: Checkpoint, patch: { [string]: any }): (Checkpoint?, string?)
		local next_checkpoint = copy_checkpoint(checkpoint)
		next_checkpoint.revision += 1
		next_checkpoint.updated_at_ms = self.now_ms()
		for key, value in pairs(patch) do
			(next_checkpoint :: any)[key] = value
		end
		if not finite(next_checkpoint.updated_at_ms) or next_checkpoint.updated_at_ms < 0 then
			return nil, "clock returned an invalid timestamp"
		end
		local saved, save_error = persist(checkpoint.revision, next_checkpoint)
		if not saved then return nil, "unknown: " .. (save_error or "checkpoint write unresolved") end
		return next_checkpoint, nil
	end

	local function ensure_checkpoint(): (Checkpoint?, string?)
		local checkpoint, load_error = load()
		if load_error ~= nil then return nil, load_error end
		if checkpoint ~= nil then return checkpoint, nil end

		local freeze_ok, frozen, freeze_message = adapter_call(self.freeze_legacy, self.migration_id)
		if not freeze_ok or frozen ~= true then
			return nil, if type(freeze_message) == "string" then freeze_message else "legacy source could not be frozen"
		end
		local verify_ok, message = verify_frozen()
		if not verify_ok then return nil, message end
		local now = self.now_ms()
		if not finite(now) or now < 0 then return nil, "clock returned an invalid timestamp" end
		local initial: Checkpoint = {
			version = 1,
			migration_id = self.migration_id,
			revision = 1,
			phase = "active",
			status = "copying",
			cursor = nil,
			active_count = 0,
			dead_letter_count = 0,
			updated_at_ms = now,
		}
		local saved, save_error = persist(nil, initial)
		if not saved then return nil, "unknown: " .. (save_error or "initial checkpoint write unresolved") end
		return initial, nil
	end

	local function verify_import(item: LegacyMessage, expected_state: string): (boolean, string?)
		local id, message_type, payload, attempts, total, replay, created_ms, _last_error = legacy_fields(item)
		if id == nil then return false, "legacy message failed field validation" end
		local ok, snapshot, result = adapter_call(self.mailbox.GetDeliveryAsync, self.mailbox, id)
		if not ok or type(snapshot) ~= "table" or type(result) ~= "table" or result.code ~= "success" then
			return false, "imported message could not be read back by its original public ID"
		end
		local raw_sender = if type(item.sender_job_id) == "string" then item.sender_job_id
			else if type(item.SenderJobId) == "string" then item.SenderJobId else ""
		if snapshot.Id ~= id or snapshot.Type ~= message_type or snapshot.State ~= expected_state
			or snapshot.Attempts ~= attempts or snapshot.TotalAttempts ~= total
			or snapshot.ReplayCount ~= replay or snapshot.CreatedAt ~= created_ms
			or snapshot.SenderJobId ~= raw_sender
			or not deep_equal(snapshot.Data, payload)
		then
			return false, "imported message does not match the frozen legacy record"
		end
		if expected_state == "dead_lettered" then
			local deadlettered = if finite(item.dead_lettered_at) then item.dead_lettered_at else item.DeadLetteredAt
			local expected_deadlettered = if finite(deadlettered) then math.floor(deadlettered * 1000) else created_ms
			local raw_error = if type(item.last_error) == "string" then item.last_error
				else if type(item.LastError) == "string" then item.LastError else "Imported from legacy V3 dead-letter queue"
			if snapshot.DeadLetteredAt ~= expected_deadlettered or snapshot.LastError ~= raw_error then
				return false, "imported dead-letter timestamp or error does not match the frozen source"
			end
		end
		return true, nil
	end

	local function step_page(checkpoint: Checkpoint, page_limit: number): (Checkpoint?, string?)
		local page_reader = if checkpoint.phase == "active" then self.read_active_page else self.read_dead_letter_page
		local read_ok, items, next_cursor, complete, read_message = adapter_call(page_reader, self.migration_id, checkpoint.cursor, page_limit)
		if not read_ok then return nil, "unknown: legacy page reader failed" end
		if read_message ~= nil then return nil, "unknown: " .. tostring(read_message) end
		local valid, count = dense_page(items, page_limit)
		if not valid then return nil, "legacy page is not a dense bounded array" end
		if type(complete) ~= "boolean" then return nil, "legacy page reader did not return a completion flag" end
		if complete then
			if next_cursor ~= nil then return nil, "complete legacy page must not return a next cursor" end
		elseif not valid_text(next_cursor, MAX_CURSOR_BYTES) or next_cursor == checkpoint.cursor then
			return nil, "incomplete legacy page must advance its bounded cursor"
		end
		local verify_ok, verify_message = verify_frozen()
		if not verify_ok then return nil, verify_message end

		for index = 1, count do
			local item = items[index]
			if type(item) ~= "table" then return nil, "legacy page contains a non-table message" end
			local id = if type(item.id) == "string" then item.id else item.Id
			if not valid_text(id, 50) then return nil, "legacy page contains an invalid public message ID" end
			local imported_ok, imported_result = adapter_call(
				if checkpoint.phase == "active" then self.mailbox.ImportLegacyAsync else self.mailbox.ImportLegacyDeadLetterAsync,
				self.mailbox, item, self.migration_id
			)
			if not imported_ok or type(imported_result) ~= "table" then return nil, "legacy import callback failed" end
			local allowed = if checkpoint.phase == "active"
				then imported_result.code == "accepted" or imported_result.code == "duplicate"
				else imported_result.code == "dead_lettered" or imported_result.code == "duplicate"
			if not allowed then
				local code = tostring(imported_result.code)
				local prefix = if code == "unknown" then "unknown: " else "blocked: "
				return nil, prefix .. "legacy import paused with status " .. code
			end
			local verified, verify_error = verify_import(item, if checkpoint.phase == "active" then "ready" else "dead_lettered")
			if not verified then return nil, verify_error end
			if not valid_text(id, 50) then return nil, "legacy page contains an invalid public message ID" end
		end

		local phase = checkpoint.phase
		local cursor = next_cursor
		if complete then
			if phase == "active" then
				phase = "dead_letters"
				cursor = nil
			else
				phase = "ready_to_activate"
				cursor = nil
			end
		end
		local patch = {
			phase = phase,
			status = if phase == "ready_to_activate" then "ready_to_activate" else "copying",
			cursor = cursor,
			active_count = checkpoint.active_count + (if checkpoint.phase == "active" then count else 0),
			dead_letter_count = checkpoint.dead_letter_count + (if checkpoint.phase == "dead_letters" then count else 0),
		}
		return advance(checkpoint, patch)
	end

	function self:Step(max_items: number?)
		if self.busy then return { code = "busy" } end
		local limit = max_items or self.page_size
		if not finite(limit) or math.floor(limit) ~= limit or limit < 1 or limit > MAX_PAGE_SIZE then
			return { code = "invalid", message = "max_items must be an integer from 1 to 100" }
		end
		self.busy = true
		local ok_call, output = pcall(function()
			local checkpoint, checkpoint_error = ensure_checkpoint()
			if checkpoint_error ~= nil or checkpoint == nil then
				return { code = "unknown", message = checkpoint_error or "migration checkpoint is unavailable" }
			end
			if checkpoint.phase == "activated" then return { code = "complete", checkpoint = checkpoint } end
			if checkpoint.phase == "ready_to_activate" then return { code = "ready_to_activate", checkpoint = checkpoint } end
			local frozen, frozen_error = verify_frozen()
			if not frozen then return { code = "fenced", message = frozen_error } end
			local next_checkpoint, step_error = step_page(checkpoint, limit)
			if next_checkpoint == nil then
				local detail = step_error or "migration step could not be verified"
				return {
					code = if string.sub(detail, 1, 9) == "unknown: " then "unknown" else "blocked",
					message = detail,
					checkpoint = checkpoint,
				}
			end
			return {
				code = if next_checkpoint.phase == "ready_to_activate" then "ready_to_activate" else "progress",
				checkpoint = next_checkpoint,
			}
		end)
		self.busy = false
		if not ok_call then return { code = "unknown", message = "migration step raised an unexpected error" } end
		return output
	end

	function self:Activate()
		if self.busy then return { code = "busy" } end
		self.busy = true
		local ok_call, output = pcall(function()
			local checkpoint, checkpoint_error = load()
			if checkpoint_error ~= nil or checkpoint == nil then
				return { code = "unknown", message = checkpoint_error or "migration checkpoint is unavailable" }
			end
			if checkpoint.phase == "activated" then return { code = "complete", checkpoint = checkpoint } end
			if checkpoint.phase ~= "ready_to_activate" then
				return { code = "blocked", message = "all active and dead-letter pages must be verified before activation" }
			end
			local frozen, frozen_error = verify_frozen()
			if not frozen then return { code = "fenced", message = frozen_error } end
			local verify_ok, verification, verify_message = adapter_call(
				self.verify_complete, self.migration_id, checkpoint.active_count, checkpoint.dead_letter_count
			)
			if not verify_ok or verification ~= true then
				return { code = "blocked", message = if type(verify_message) == "string" then verify_message else "destination/source inventory verification failed" }
			end
			local activate_ok, activated, activate_message = adapter_call(self.activate_v2, self.migration_id)
			if not activate_ok or activated ~= true then
				return { code = "unknown", message = if type(activate_message) == "string" then activate_message else "V2 activation outcome is not confirmed" }
			end
			local now = self.now_ms()
			if not finite(now) or now < 0 then return { code = "unknown", message = "clock returned an invalid timestamp" } end
			local next_checkpoint = copy_checkpoint(checkpoint)
			next_checkpoint.revision += 1
			next_checkpoint.phase = "activated"
			next_checkpoint.status = "activated"
			next_checkpoint.updated_at_ms = now
			next_checkpoint.activated_at_ms = now
			local saved, save_error = persist(checkpoint.revision, next_checkpoint)
			if not saved then return { code = "unknown", message = save_error or "activation checkpoint is unresolved" } end
			return { code = "complete", checkpoint = next_checkpoint }
		end)
		self.busy = false
		if not ok_call then return { code = "unknown", message = "migration activation raised an unexpected error" } end
		return output
	end

	function self:GetStatus()
		local checkpoint, load_error = load()
		if load_error ~= nil then return nil, load_error end
		return checkpoint, nil
	end

	return self
end

return Runner
