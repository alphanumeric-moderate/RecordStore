--!nocheck
-- Benchmark: opening records stored in legacy / corrupt envelopes, which go through
-- envelope parsing, migration and version-history recovery.
local Shim = require("./RobloxShim")
local RecordStore = Shim.load()

local KEYS_PER_CASE = 15
local STORE = "Bench_LegacyMigration"
local SCOPE = "global"

local function legacy_v2_envelope(i: number)
	return {
		__recordStore = "RecordStore",
		format = 1,
		revision = 7,
		fence = "old-string-fence",
		commitId = "old-commit-id-" .. i,
		deleted = false,
		version = 0,
		data = { Coins = i, Inventory = { "Sword", "Shield" } },
	}
end

local function previous_shape_envelope(i: number)
	return {
		implementation_version = 1,
		format = "RecordStore",
		schema_version = 1,
		revision = 13,
		generation = 7,
		created_at = 100,
		updated_at = 200,
		deleted = false,
		payload = { Coins = i, Inventory = { "LegacySword" } },
		last_operation_id = "legacy-write-" .. i,
		last_owner_job_id = "old-job",
		last_owner_place_id = 123,
		first_session_timestamp = 100,
		session_load_count = 4,
		user_ids = {},
	}
end

local function current_baseline(i: number)
	return {
		implementation_version = 1,
		schema_version = 1,
		revision = 9,
		fencing_generation = 0,
		created_at = 100,
		updated_at = 100,
		data = { Coins = i, Inventory = { "Staff" } },
		user_ids = {},
		write_id = "baseline-" .. i,
	}
end

local function open_and_close(key: string, schema_version: number, expected_coins: number)
	local record = RecordStore.Mock.new(STORE, SCOPE, key, { schema_version = schema_version })
	local result, message = record:Open({ Coins = 0, Inventory = {} })
	assert(result == "loaded", ("%s: %s: %s"):format(key, result, message or "no message"))
	assert(record:Get().Coins == expected_coins, key .. ": data was not preserved")
	local close_result, close_message = record:Close()
	assert(close_result == "closed", close_message)
end

RecordStore.Mock.reset()
for i = 1, KEYS_PER_CASE do
	-- pre-v4 envelope
	local key = "legacy-v2-" .. i
	assert(RecordStore.Mock.seed_record_raw(STORE, SCOPE, key, legacy_v2_envelope(i)) == "success")
	open_and_close(key, 0, i)

	-- previous generation/payload envelope
	key = "previous-shape-" .. i
	assert(RecordStore.Mock.seed_record_raw(STORE, SCOPE, key, previous_shape_envelope(i)) == "success")
	open_and_close(key, 1, i)

	-- corrupt current version recovered from history
	key = "corrupt-current-" .. i
	local baseline = current_baseline(i)
	assert(RecordStore.Mock.seed_record_raw(STORE, SCOPE, key, baseline) == "success")
	local corrupt = table.clone(baseline)
	corrupt.fencing_generation = "invalid"
	corrupt.write_id = "corrupt-" .. i
	assert(RecordStore.Mock.seed_record_raw(STORE, SCOPE, key, corrupt) == "success")
	open_and_close(key, 1, i)
end
RecordStore.Mock.reset()
Shim.close()
