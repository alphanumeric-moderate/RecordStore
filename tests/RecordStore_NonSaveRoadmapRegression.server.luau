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

Mock.reset()
Shim.close()
