--!nocheck
local process = require("@lune/process")
local function assert(value, message)
	if not value then
		warn(message or "assertion failed")
		process.exit(1)
	end
	return value
end

local Shim = require("./RobloxShim")
local RecordStore = Shim.load()
local Mock = RecordStore.Mock
local MailboxV2 = RecordStore.MailboxV2

assert(type(Mock.get_session_status_async) == "function", "session status diagnostic API is missing")
assert(type(MailboxV2.MaintenanceAsync) == "function", "mailbox maintenance API is missing")
assert(type(RecordStore.inspect_profile_async) == "function", "Profile Doctor inspection API is missing")
assert(type(Mock.inspect_profile_async) == "function", "mock Profile Doctor inspection API is missing")
assert(type(RecordStore.diff_profile_versions_async) == "function", "Profile Doctor version diff API is missing")
assert(type(Mock.diff_profile_versions_async) == "function", "mock Profile Doctor version diff API is missing")
assert(type(RecordStore.register_migration) == "function", "migration registry API is missing")
assert(type(RecordStore.preview_migration_async) == "function", "migration preview API is missing")
assert(type(Mock.preview_migration_async) == "function", "mock migration preview API is missing")

Mock.reset()
Mock.set_test_clock(function()
	return 1000
end)

local function seed_record(key, session, tombstone)
	local envelope = {
		implementation_version = 2,
		schema_version = 1,
		revision = 4,
		fencing_generation = 2,
		created_at = 900,
		updated_at = 950,
		data = if tombstone ~= nil then nil else { value = 12 },
		non_finite_numbers = {},
		user_ids = {},
		tombstone = tombstone,
		write_id = "write-" .. key,
	}
	if session ~= nil then
		envelope.session = session
	end
	local result, message = Mock.seed_record_raw("SessionStatusTest", "global", key, envelope)
	assert(result == "success", tostring(message))
end

local active_session = {
	token = "do-not-return-this-token",
	generation = 2,
	job_id = "job-active",
	place_id = 100,
	acquired_at = 900,
	lease_until = 1100,
}
seed_record("active", active_session)
seed_record("expired", {
	token = "expired-token",
	generation = 2,
	job_id = "job-expired",
	place_id = 100,
	acquired_at = 800,
	lease_until = 900,
})
seed_record("unleased", nil)
seed_record("tombstoned", nil, { deleted_at = 950, generation = 2 })

local status, result, message = Mock.get_session_status_async("SessionStatusTest", "global", "active")
assert(result == "success", tostring(message))
assert(status.Observation == "active_lease_observed")
assert(status.LeaseRemainingSeconds == 100)
assert(status.LeaseAppearsAvailable == false)
assert(status.OwnerJobId == "job-active")
assert(status.Generation == 2)
assert(status.Revision == 4)
assert(status.IsAuthoritativeOwnershipDecision == false)
assert(status.SessionToken == nil, "session token must never be exposed")

local expired, expired_result, expired_message =
	Mock.get_session_status_async("SessionStatusTest", "global", "expired")
assert(expired_result == "success", tostring(expired_message))
assert(expired.Observation == "expired_lease_observed")
assert(expired.LeaseRemainingSeconds == 0)
assert(expired.LeaseAppearsAvailable == true)

local unleased, unleased_result, unleased_message =
	Mock.get_session_status_async("SessionStatusTest", "global", "unleased")
assert(unleased_result == "success", tostring(unleased_message))
assert(unleased.Observation == "no_session")
assert(unleased.LeaseAppearsAvailable == true)

local tombstoned, tombstoned_result, tombstoned_message =
	Mock.get_session_status_async("SessionStatusTest", "global", "tombstoned")
assert(tombstoned_result == "success", tostring(tombstoned_message))
assert(tombstoned.Observation == "tombstoned")
assert(tombstoned.LeaseAppearsAvailable == false, "tombstones must not be reported as available")

local missing, missing_result = Mock.get_session_status_async("SessionStatusTest", "global", "missing")
assert(missing_result == "not_found")
assert(missing.Observation == "not_found")
assert(missing.LeaseAppearsAvailable == true)

local invalid, invalid_result = Mock.get_session_status_async("", "global", "active")
assert(invalid == nil and invalid_result == "invalid")

Mock.set_get_failures(1, "injected read failure")
local unreadable, unreadable_result = Mock.get_session_status_async("SessionStatusTest", "global", "active")
assert(unreadable == nil and unreadable_result == "unknown", "read failures must not look like an unowned profile")

local store = MailboxV2.MockStore()
local mailbox = MailboxV2.new(store, {
	store_name = "PlayerData",
	scope = "global",
	profile_key = "maintenance-owner",
}, {
	encode = function(value)
		return game:GetService("HttpService"):JSONEncode(value)
	end,
	activation_guard = function()
		return true, nil
	end,
})
local report, maintenance_result = mailbox:MaintenanceAsync()
assert(maintenance_result.code == "success", tostring(maintenance_result.error))
assert(report.recovery.code == "success")
assert(report.reclaim.code == "empty")
assert(report.stats.ready == 0)
assert(report.consistency == "bounded_non_linearizable")

local inspection, inspection_result, inspection_message =
	Mock.inspect_profile_async("SessionStatusTest", "global", "active")
assert(inspection_result == "success", tostring(inspection_message))
assert(inspection.Classification == "active_session")
assert(inspection.Consistency == "point_in_time_non_authoritative")
assert(inspection.DataNodeCount == 2, "inspection should report bounded data node count")
assert(inspection.DataDepth == 1, "inspection should report maximum data depth")
assert(inspection.ProfileKey == "active")

local missing_inspection, missing_inspection_result =
	Mock.inspect_profile_async("SessionStatusTest", "global", "missing")
assert(missing_inspection_result == "not_found")
assert(missing_inspection.Classification == "missing")

local malformed_seed_result = Mock.seed_record_raw("ProfileDoctorTest", "global", "future", {
	implementation_version = 999,
	schema_version = 1,
	revision = 1,
	fencing_generation = 1,
	created_at = 1,
	updated_at = 1,
	data = {},
	non_finite_numbers = {},
	user_ids = {},
	write_id = "future-write",
})
assert(malformed_seed_result == "success")
local future_inspection, future_result =
	Mock.inspect_profile_async("ProfileDoctorTest", "global", "future")
assert(future_result == "future_schema")
assert(future_inspection.Classification == "future_schema")

local doctor_record = Mock.new("ProfileDoctorTest", "global", "profile", {
	schema_version = 1,
	autosave_interval = 1000,
	lease_duration = 180,
	lease_renewal = 60,
})
local doctor_open, doctor_open_message = doctor_record:Open({
	coins = 10,
	nested = { label = "before" },
})
assert(doctor_open == "created" or doctor_open == "loaded", tostring(doctor_open_message))
local before_history, before_history_result, before_history_message =
	Mock.list_versions_async("ProfileDoctorTest", "global", "profile", Enum.SortDirection.Descending, nil, nil, 100)
assert(before_history_result == "success", tostring(before_history_message))
assert(before_history ~= nil and #before_history >= 1, "Profile Doctor fixture has no original version")
local before_version = before_history[1].Version

local doctor_update, doctor_update_message = doctor_record:Update(function(data)
	(data :: { [string]: any }).coins = 20
	(data :: { [string]: any }).nested.label = "after"
	return data
end)
assert(doctor_update == "success", tostring(doctor_update_message))
local doctor_save, doctor_save_message = doctor_record:Save("profile-doctor-diff")
assert(doctor_save == "saved", tostring(doctor_save_message))
local after_history, after_history_result, after_history_message =
	Mock.list_versions_async("ProfileDoctorTest", "global", "profile", Enum.SortDirection.Descending, nil, nil, 100)
assert(after_history_result == "success", tostring(after_history_message))
assert(after_history ~= nil and #after_history >= 2, "Profile Doctor fixture did not create a new version")
local after_version = after_history[1].Version
assert(after_version ~= before_version, "Profile Doctor fixture reused the same version")

local diff, diff_result, diff_message = Mock.diff_profile_versions_async(
	"ProfileDoctorTest", "global", "profile", before_version, after_version, {
		max_nodes = 100,
		max_changes = 20,
		max_depth = 16,
	}
)
assert(diff_result == "success", tostring(diff_message))
assert(diff.Consistency == "bounded_historical_diff")
assert(diff.Truncated == false)
local changed_paths = {}
for _, change in ipairs(diff.Changes) do
	changed_paths[change.Path] = change.Kind
	assert(change.BeforeValue == nil and change.AfterValue == nil,
		"Profile Doctor version diffs must not expose raw values by default")
end
assert(changed_paths["$.coins"] == "changed", "Profile Doctor missed the changed scalar path")
assert(changed_paths["$.nested.label"] == "changed", "Profile Doctor missed the nested changed path")

local bounded_diff, bounded_result, bounded_message = Mock.diff_profile_versions_async(
	"ProfileDoctorTest", "global", "profile", before_version, after_version, {
		max_nodes = 100,
		max_changes = 1,
		max_depth = 16,
	}
)
assert(bounded_result == "success", tostring(bounded_message))
assert(#bounded_diff.Changes <= 1)
assert(bounded_diff.Truncated == true, "diff must report truncation when the change cap is reached")

local migration_record = Mock.new("MigrationTest", "global", "profile", {
	schema_version = 1,
	autosave_interval = 1000,
	lease_duration = 180,
	lease_renewal = 60,
})
local migration_open, migration_open_message = migration_record:Open({
	coins = 10,
	nested = { label = "before" },
})
assert(migration_open == "created" or migration_open == "loaded", tostring(migration_open_message))
local migration_before = Mock.get_record_raw("MigrationTest", "global", "profile")
local migration_before_revision = migration_record:GetRevision()

local migration_1_to_2 = {
	id = "migration-test-v1-v2",
	from_version = 1,
	to_version = 2,
	implementation_revision = "test-implementation-1",
	compatible_schema_min = 1,
	compatible_schema_max = 3,
	transform = function(_from_version, data)
		local next_data = table.clone(data)
		next_data.coins += 5
		next_data.nested = table.clone(next_data.nested)
		next_data.nested.label = "middle"
		return next_data
	end,
}
local migration_2_to_3 = {
	id = "migration-test-v2-v3",
	from_version = 2,
	to_version = 3,
	implementation_revision = "test-implementation-1",
	compatible_schema_min = 1,
	compatible_schema_max = 3,
	transform = function(_from_version, data)
		local next_data = table.clone(data)
		next_data.coins += 7
		next_data.nested = table.clone(next_data.nested)
		next_data.nested.label = "after"
		next_data.schema_marker = 3
		return next_data
	end,
}
local migration_register_1, migration_register_1_message =
	RecordStore.register_migration("MigrationTest", migration_1_to_2)
assert(migration_register_1 == "success", tostring(migration_register_1_message))
local migration_register_2, migration_register_2_message =
	RecordStore.register_migration("MigrationTest", migration_2_to_3)
assert(migration_register_2 == "success", tostring(migration_register_2_message))
local duplicate_registration, duplicate_message =
	RecordStore.register_migration("MigrationTest", migration_1_to_2)
assert(duplicate_registration == "duplicate", tostring(duplicate_message))

local invalid_backward = table.clone(migration_2_to_3)
invalid_backward.id = "migration-test-v3-v2"
invalid_backward.from_version = 3
invalid_backward.to_version = 2
assert(RecordStore.register_migration("MigrationTest", invalid_backward) == "invalid",
	"registry must reject backwards migration edges")

local ambiguous_registration = table.clone(migration_2_to_3)
ambiguous_registration.id = "migration-test-v1-v3-ambiguous"
ambiguous_registration.from_version = 1
ambiguous_registration.to_version = 3
assert(RecordStore.register_migration("MigrationTest", ambiguous_registration) == "conflict",
	"registry must reject a second route between already connected schema versions")

local preview, preview_result, preview_message = Mock.preview_migration_async(
	"MigrationTest", "global", "profile", 3, {
		max_nodes = 100,
		max_depth = 16,
		max_changes = 20,
	}
)
assert(preview_result == "success", tostring(preview_message))
assert(preview.Consistency == "read_only_non_authoritative_preview")
assert(preview.SourceSchemaVersion == 1 and preview.TargetSchemaVersion == 3)
assert(#preview.Steps == 2)
assert(preview.TargetDataNodeCount ~= nil and preview.TargetDataNodeCount > 0)
assert(preview.Truncated == false)
local preview_paths = {}
for _, change in ipairs(preview.Changes) do
	preview_paths[change.Path] = change.Kind
	assert(change.BeforeValue == nil and change.AfterValue == nil,
		"migration preview must not expose raw profile values")
end
assert(preview_paths["$.coins"] == "changed")
assert(preview_paths["$.nested.label"] == "changed")
assert(preview_paths["$.schema_marker"] == "added")

local preview_gap, preview_gap_result =
	Mock.preview_migration_async("MigrationTest", "global", "profile", 4)
assert(preview_gap == nil and preview_gap_result == "migration",
	"preview must reject a target with no unique registered migration path")
local migration_after = Mock.get_record_raw("MigrationTest", "global", "profile")
assert(migration_after.schema_version == migration_before.schema_version,
	"dry-run migration preview modified the durable schema version")
assert(migration_after.revision == migration_before.revision,
	"dry-run migration preview modified the durable revision")
assert((migration_after.data :: { [string]: any }).coins == (migration_before.data :: { [string]: any }).coins,
	"dry-run migration preview modified durable profile data")
assert(migration_record:GetRevision() == migration_before_revision,
	"dry-run migration preview mutated the live mock Record")

Mock.reset()
Shim.close()
