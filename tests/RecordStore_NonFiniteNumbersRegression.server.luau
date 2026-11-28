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
		deep = {
			branch = {
				array = { math.huge },
			},
		},
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
assert(loaded.nested.deep.branch.array[1] == math.huge, "deeply nested positive infinity was not preserved")
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
local raw_json_ok, raw_json = pcall(function()
	return game:GetService("HttpService"):JSONEncode(raw)
end)
assert(raw_json_ok and type(raw_json) == "string",
	"durable UpdateAsync transform produced an envelope that is not JSON-encodable")
assert(type(raw.data) == "table", "serialized data is missing")
assert(type(raw.non_finite_numbers) == "table" and #raw.non_finite_numbers >= 6, "non-finite sidecar markers were not written")
assert(raw.data.positive == 0 and raw.data.negative == 0 and raw.data.not_a_number == 0, "serialized placeholders must be JSON-safe")
assert(raw.data.zero == 0 and raw.data.nested.array[4] == 0, "ordinary zeros must remain ordinary zeros")
assert(raw.data.direct_positive_infinity == 0, "direct positive infinity placeholder is not JSON-safe")
assert(raw.data.direct_negative_infinity == 0, "direct negative infinity placeholder is not JSON-safe")
assert(raw.data.direct_nan == 0, "direct NaN placeholder is not JSON-safe")
assert(raw.data.nested.deep.branch.array[1] == 0, "deeply nested non-finite placeholder is not JSON-safe")
assert(raw.data.nested.ordinary.non_finite_numbers == initial.nested.ordinary.non_finite_numbers, "user data was modified by sidecar storage")

local deep_marker_found = false
for _, marker in ipairs(raw.non_finite_numbers) do
	if marker.kind == "positive_infinity" and #marker.path == 5 then
		local path = marker.path
		if path[1].kind == "string" and path[1].key == "nested"
			and path[2].kind == "string" and path[2].key == "deep"
			and path[3].kind == "string" and path[3].key == "branch"
			and path[4].kind == "string" and path[4].key == "array"
			and path[5].kind == "number" and path[5].key == 1
		then
			deep_marker_found = true
			break
		end
	end
end
assert(deep_marker_found, "deep non-finite marker path changed its persisted segment format")

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
assert(reloaded.nested.deep.branch.array[1] == math.huge,
	"deeply nested positive infinity failed the persistence round trip")
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

-- The documented depth limit is 64 edges from the profile root. Copying,
-- encoding, and restoring a non-finite value at that exact boundary must agree.
local function make_nested_value(child_tables: number, value: number)
	local root = {}
	local cursor = root
	for _ = 1, child_tables do
		local child = {}
		cursor.child = child
		cursor = child
	end
	cursor.value = value
	return root
end

local function read_nested_value(root, child_tables: number)
	local cursor = root
	for _ = 1, child_tables do
		cursor = cursor.child
	end
	return cursor.value
end

local boundary_key = "depth-boundary"
local boundary = RecordStore.Mock.new(store_name, scope, boundary_key, { schema_version = 1 })
local boundary_open, boundary_open_message = boundary:Open({})
assert_opened(boundary_open, boundary_open_message, "created")
local boundary_update, boundary_update_message = boundary:Update(function(current)
	current.boundary = make_nested_value(62, math.huge)
	return current
end)
assert_opened(boundary_update, boundary_update_message, "success")
local boundary_close, boundary_close_message = boundary:Close()
assert_opened(boundary_close, boundary_close_message, "closed")

local boundary_raw = RecordStore.Mock.get_record_raw(store_name, scope, boundary_key)
assert(type(boundary_raw) == "table" and type(boundary_raw.non_finite_numbers) == "table",
	"depth-boundary save did not write its non-finite sidecar")
local maximum_depth_marker_found = false
for _, marker in ipairs(boundary_raw.non_finite_numbers) do
	if marker.kind == "positive_infinity" and #marker.path == 64
		and marker.path[1].kind == "string" and marker.path[1].key == "boundary"
		and marker.path[64].kind == "string" and marker.path[64].key == "value"
	then
		maximum_depth_marker_found = true
		break
	end
end
assert(maximum_depth_marker_found, "the maximum supported depth did not preserve its 64-segment sidecar path")

local boundary_reload, boundary_reload_message = boundary:Open({})
assert_opened(boundary_reload, boundary_reload_message, "loaded")
assert(read_nested_value(boundary.Data.boundary, 62) == math.huge,
	"non-finite value at the maximum supported depth did not round-trip")

local over_depth_update, over_depth_message = boundary:Update(function(current)
	current.over_depth = make_nested_value(63, math.huge)
	return current
end)
assert(over_depth_update == "validation" and string.find(over_depth_message or "", "invalid data", 1, true) ~= nil,
	"a value one level beyond the depth limit was not rejected")
assert(boundary.Data.over_depth == nil and read_nested_value(boundary.Data.boundary, 62) == math.huge,
	"rejecting an over-depth mutation changed the existing profile")
local boundary_close_again, boundary_close_again_message = boundary:Close()
assert_opened(boundary_close_again, boundary_close_again_message, "closed")

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
