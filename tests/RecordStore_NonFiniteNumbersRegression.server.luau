--!nocheck
-- Regression tests for RecordStore non-finite number persistence.
-- Uses RecordStore.Mock only; this never reads or writes live DataStore records.

local ServerScriptService = game:GetService("ServerScriptService")
local RecordStore = require(ServerScriptService.RecordStore)

local function assert_opened(result, message, expected)
	assert(result == expected, ("expected %s, got %s: %s"):format(expected, tostring(result), tostring(message)))
end

RecordStore.Mock.reset()

local store_name = "RecordStore_NonFiniteRegression"
local scope = "global"
local key = "nested-round-trip"
local nan = 0 / 0
local initial = {
	positive = math.huge,
	negative = -math.huge,
	not_a_number = nan,
	zero = 0,
	nested = {
		array = { math.huge, -math.huge, 0 / 0, 0 },
		ordinary = {
			non_finite_numbers = "user-owned field; must not collide with RecordStore metadata",
		},
	},
}

local record = RecordStore.Mock.new(store_name, scope, key, { schema_version = 1 })
local open_result, open_message = record:Open(initial)
assert_opened(open_result, open_message, "created")

local loaded = record:Get()
assert(type(loaded) == "table", "record data must remain a table")
assert(loaded.positive == math.huge, "positive infinity did not survive in-memory open")
assert(loaded.negative == -math.huge, "negative infinity did not survive in-memory open")
assert(type(loaded.not_a_number) == "number" and math.isnan(loaded.not_a_number), "NaN did not survive in-memory open")
assert(loaded.zero == 0, "ordinary zero was changed")
assert(loaded.nested.array[1] == math.huge, "nested positive infinity was not preserved")
assert(loaded.nested.array[2] == -math.huge, "nested negative infinity was not preserved")
assert(math.isnan(loaded.nested.array[3]), "nested NaN was not preserved")
assert(loaded.nested.array[4] == 0, "ordinary nested zero was changed")
assert(loaded.nested.ordinary.non_finite_numbers == initial.nested.ordinary.non_finite_numbers, "user data collided with RecordStore metadata")

local update_result, update_message = record:Update(function(current)
	current.updated_to_nan = 0 / 0
	current.updated_to_positive_infinity = math.huge
	current.updated_to_negative_infinity = -math.huge
	return current
end)
assert_opened(update_result, update_message, "success")

-- Direct public Data mutation must preserve non-finite values too.
record.Data.direct_positive_infinity = math.huge
record.Data.direct_negative_infinity = -math.huge
record.Data.direct_nan = 0 / 0

local close_result, close_message = record:Close()
assert_opened(close_result, close_message, "closed")

local raw = RecordStore.Mock.get_record_raw(store_name, scope, key)
assert(type(raw) == "table", "raw durable mock envelope is missing")
assert(raw.implementation_version == 2, "new envelope implementation version was not written")
assert(type(raw.data) == "table", "serialized data is missing")
assert(type(raw.non_finite_numbers) == "table" and #raw.non_finite_numbers >= 6, "non-finite sidecar markers were not written")
assert(raw.data.positive == 0 and raw.data.negative == 0 and raw.data.not_a_number == 0, "serialized placeholders must be JSON-safe")
assert(raw.data.zero == 0 and raw.data.nested.array[4] == 0, "ordinary zeros must remain ordinary zeros")
assert(raw.data.direct_positive_infinity == 0, "direct positive infinity placeholder is not JSON-safe")
assert(raw.data.direct_negative_infinity == 0, "direct negative infinity placeholder is not JSON-safe")
assert(raw.data.direct_nan == 0, "direct NaN placeholder is not JSON-safe")
assert(raw.data.nested.ordinary.non_finite_numbers == initial.nested.ordinary.non_finite_numbers, "user data was modified by sidecar storage")

local reload_result, reload_message = record:Open(initial)
assert_opened(reload_result, reload_message, "loaded")
local reloaded = record:Get()
assert(reloaded.positive == math.huge, "positive infinity failed the persistence round trip")
assert(reloaded.negative == -math.huge, "negative infinity failed the persistence round trip")
assert(math.isnan(reloaded.not_a_number), "NaN failed the persistence round trip")
assert(reloaded.updated_to_positive_infinity == math.huge, "updated positive infinity failed the persistence round trip")
assert(reloaded.updated_to_negative_infinity == -math.huge, "updated negative infinity failed the persistence round trip")
assert(math.isnan(reloaded.updated_to_nan), "updated NaN failed the persistence round trip")
assert(reloaded.direct_positive_infinity == math.huge, "direct positive infinity failed the persistence round trip")
assert(reloaded.direct_negative_infinity == -math.huge, "direct negative infinity failed the persistence round trip")
assert(math.isnan(reloaded.direct_nan), "direct NaN failed the persistence round trip")
assert(math.isnan(reloaded.nested.array[3]), "nested NaN failed the persistence round trip")
local second_close_result, second_close_message = record:Close()
assert_opened(second_close_result, second_close_message, "closed")

-- A scalar root value uses an empty marker path and must also round-trip.
local scalar = RecordStore.Mock.new(store_name, scope, "scalar-root", { schema_version = 1 })
local scalar_open, scalar_open_message = scalar:Open(-math.huge)
assert_opened(scalar_open, scalar_open_message, "created")
local scalar_close, scalar_close_message = scalar:Close()
assert_opened(scalar_close, scalar_close_message, "closed")
local scalar_reload, scalar_reload_message = scalar:Open(0)
assert_opened(scalar_reload, scalar_reload_message, "loaded")
assert(scalar:Get() == -math.huge, "root-level negative infinity failed the persistence round trip")
local scalar_close_2, scalar_close_message_2 = scalar:Close()
assert_opened(scalar_close_2, scalar_close_message_2, "closed")

-- Invalid sidecar paths must fail closed instead of silently corrupting the payload.
local bad_seed, bad_seed_message = RecordStore.Mock.seed_record_raw(store_name, scope, "bad-sidecar", {
	implementation_version = 2,
	schema_version = 1,
	revision = 0,
	fencing_generation = 0,
	created_at = 100,
	updated_at = 100,
	data = { value = 0 },
	user_ids = {},
	write_id = "bad-sidecar",
	non_finite_numbers = {
		{ path = { { kind = "string", key = "missing" } }, kind = "nan" },
	},
})
assert(bad_seed == "success", bad_seed_message or "failed to seed malformed sidecar fixture")
local corrupt = RecordStore.Mock.new(store_name, scope, "bad-sidecar", { schema_version = 1 })
local bad_open, bad_open_message = corrupt:Open({ value = 0 })
assert(bad_open == "corrupt", ("malformed sidecar should be rejected as corrupt, got %s: %s"):format(tostring(bad_open), tostring(bad_open_message)))

RecordStore.Mock.reset()
print("[RecordStore] non-finite numeric persistence regression tests passed")
