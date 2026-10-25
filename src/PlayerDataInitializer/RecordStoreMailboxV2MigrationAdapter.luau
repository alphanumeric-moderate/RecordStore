--!strict
-- Concrete source bridge for RecordStoreMailboxV2Migration.
-- The existing q2 record is frozen in place; application-owned checkpoint CAS,
-- old-worker drain proof and the V2 activation gate remain explicit requirements.

local Adapter = {}

type Config = {
	record_store: any,
	store_name: string,
	scope: string,
	profile_key: string,
	migration_id: string,
	mailbox: any,
	queue_store_name: string?,
	max_queue_bytes: number?,
	operation_deadline: number?,
	page_size: number?,
	now_ms: (() -> number)?,
	legacy_writers_drained: (string) -> (boolean, string?),
	load_checkpoint: (string) -> (any?, string?),
	save_checkpoint: (string, number?, any) -> (boolean, string?),
	activate_v2: (string) -> (boolean, string?),
	verify_complete: ((string, number, number) -> (boolean, string?))?,
}

local function fail_result(code: string, message: string?): string
	return code .. ": " .. (message or "migration source operation did not succeed")
end

function Adapter.bind(config: Config)
	if type(config) ~= "table" then error("migration adapter config must be a table", 2) end
	local record_store = config.record_store
	if type(record_store) ~= "table"
		or type(record_store.begin_mailbox_v2_migration_async) ~= "function"
		or type(record_store.get_mailbox_v2_migration_status_async) ~= "function"
		or type(record_store.get_mailbox_v2_migration_source_page_async) ~= "function"
	then
		error("record_store does not expose the Mailbox V2 migration source APIs", 2)
	end
	if type(config.store_name) ~= "string" or config.store_name == ""
		or type(config.scope) ~= "string"
		or type(config.profile_key) ~= "string" or config.profile_key == ""
		or type(config.migration_id) ~= "string" or config.migration_id == ""
	then
		error("store_name, scope, profile_key and migration_id are required", 2)
	end
	for _, field in ipairs({ "legacy_writers_drained", "load_checkpoint", "save_checkpoint", "activate_v2" }) do
		if type(config[field]) ~= "function" then error(field .. " callback is required", 2) end
	end
	local function args()
		return config.store_name, config.scope, config.profile_key, config.migration_id,
			config.queue_store_name, config.max_queue_bytes, config.operation_deadline
	end
	local function source_page(kind: string, migration_id: string, cursor: string?, limit: number): ({ [number]: { [string]: unknown } }?, string?, boolean, string?)
		if migration_id ~= config.migration_id then return nil, nil, false, "migration ID mismatch" end
		local name, scope, key, id, queue_store, max_bytes, deadline = args()
		local items, next_cursor, complete, status, message =
			record_store.get_mailbox_v2_migration_source_page_async(
				name, scope, key, id, kind, cursor, limit, queue_store, max_bytes, deadline
			)
		if status ~= "success" then return nil, nil, false, fail_result(status, message) end
		return items, next_cursor, complete, nil
	end
	local function freeze_legacy(migration_id: string): (boolean, string?)
		if migration_id ~= config.migration_id then return false, "migration ID mismatch" end
		local name, scope, key, id, queue_store, max_bytes, deadline = args()
		local status, message = record_store.begin_mailbox_v2_migration_async(
			name, scope, key, id, queue_store, max_bytes, deadline
		)
		return status == "success", if status == "success" then nil else fail_result(status, message)
	end
	local function verify_source_frozen(migration_id: string): (boolean, string?)
		if migration_id ~= config.migration_id then return false, "migration ID mismatch" end
		local name, scope, key, id, queue_store, max_bytes, deadline = args()
		local snapshot, status, message = record_store.get_mailbox_v2_migration_status_async(
			name, scope, key, id, queue_store, max_bytes, deadline
		)
		if status ~= "success" or snapshot == nil then return false, fail_result(status, message) end
		return snapshot.MigrationId == migration_id,
			if snapshot.MigrationId == migration_id then nil else "freeze marker identity mismatch"
	end
	local function verify_complete(migration_id: string, active_count: number, dead_letter_count: number): (boolean, string?)
		if migration_id ~= config.migration_id then return false, "migration ID mismatch" end
		local name, scope, key, id, queue_store, max_bytes, deadline = args()
		local snapshot, status, message = record_store.get_mailbox_v2_migration_status_async(
			name, scope, key, id, queue_store, max_bytes, deadline
		)
		if status ~= "success" or snapshot == nil then return false, fail_result(status, message) end
		if snapshot.ActiveCount ~= active_count or snapshot.DeadLetterCount ~= dead_letter_count then
			return false, "imported counts do not match the frozen source counts"
		end
		if type(config.verify_complete) == "function" then
			return config.verify_complete(migration_id, active_count, dead_letter_count)
		end
		return true, nil
	end
	return {
		migration_id = config.migration_id,
		mailbox = config.mailbox,
		page_size = config.page_size,
		now_ms = config.now_ms,
		freeze_legacy = freeze_legacy,
		verify_source_frozen = verify_source_frozen,
		legacy_writers_drained = config.legacy_writers_drained,
		read_active_page = function(migration_id: string, cursor: string?, limit: number)
			return source_page("active", migration_id, cursor, limit)
		end,
		read_dead_letter_page = function(migration_id: string, cursor: string?, limit: number)
			return source_page("dead_letter", migration_id, cursor, limit)
		end,
		load_checkpoint = config.load_checkpoint,
		save_checkpoint = config.save_checkpoint,
		verify_complete = verify_complete,
		activate_v2 = config.activate_v2,
	}
end

return Adapter
