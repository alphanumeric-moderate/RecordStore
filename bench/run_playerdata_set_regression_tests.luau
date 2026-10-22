--!nocheck
-- PlayerData.Set path and persistence regression.
local create_harness = require("./playerdata_set_harness")
local harness = create_harness(true)
local controller = harness.controller
local player = harness.player
local record = harness.record
local saved_records = harness.saved_records
local task = harness.task
local get_find_first_child_calls = harness.get_find_first_child_calls

local record_options = harness.get_record_options()
assert(record_options ~= nil, "PlayerDataCore did not create a RecordStore session")

assert(record_options.autosave_interval == 90, "unexpected autosave interval")
assert(record_options.lease_duration == 180, "unexpected session lease duration")
assert(record_options.lease_renewal == 60, "unexpected session lease renewal interval")
assert(record_options.operation_deadline == 20, "unexpected operation deadline")
assert(record_options.retry_attempts == 5, "unexpected operation retry count")
assert(record_options.shutdown_deadline == 25, "unexpected shutdown deadline")
assert(record_options.shutdown_attempts == 2, "unexpected shutdown attempt count")
assert(record_options.budget_wait == 2, "unexpected DataStore budget wait")
assert(
	record_options.lease_duration > record_options.lease_renewal + record_options.operation_deadline,
	"lease duration must exceed renewal interval plus operation deadline"
)

local path_lookups_before_set = get_find_first_child_calls()
local success, message = controller.Set(player, "kills", 12500124)
assert(success, message)
success, message = controller.Set(player, "equipped", "Hi")
assert(success, message)
success, message = controller.Set(player, "admin", true)
assert(success, message)
assert(
	get_find_first_child_calls() == path_lookups_before_set,
	"PlayerData.Set should reuse cached folder and value paths on the steady path"
)
assert(not controller.Set(player, "admin", "true"), "invalid boolean value was accepted")
assert(not controller.Set(player, "not_a_field", 1), "unknown field was accepted")

local values = player:FindFirstChild("PlayerDataValues")
local leaderstats = player:FindFirstChild("leaderstats")
assert(values ~= nil and leaderstats ~= nil, "runtime folders are missing")
local kills = values:FindFirstChild("kills")
local kills_display = leaderstats:FindFirstChild("Kills")
local equipped_display = leaderstats:FindFirstChild("Equipped")
assert(kills ~= nil and kills.Value == 12500124, "kills backing value did not update")
assert(equipped_display ~= nil and equipped_display.Value == "Hi", "Equipped did not update")
assert(kills_display ~= nil and kills_display.Value == "12.5M", "formatted Kills display did not refresh")

-- A detached cached folder must be re-resolved, not used as a stale path.
local lookups_before_detach = get_find_first_child_calls()
values.Parent = nil
local detached_ok = controller.Set(player, "kills", 12500124)
assert(not detached_ok, "Set accepted a value whose backing folder was detached")
assert(
	get_find_first_child_calls() == lookups_before_detach + 1,
	"Set did not fall back to root lookup after the cached folder was detached"
)
values.Parent = player
local lookups_before_refresh = get_find_first_child_calls()
success, message = controller.Set(player, "kills", 12500124)
assert(success, message)
assert(
	get_find_first_child_calls() == lookups_before_refresh + 1,
	"Set did not rebuild the root path after the folder was restored"
)
local lookups_before_cached_set = get_find_first_child_calls()
success, message = controller.Set(player, "kills", 12500124)
assert(success, message)
assert(
	get_find_first_child_calls() == lookups_before_cached_set,
	"Set did not reuse the rebuilt folder and value path"
)

-- Public PlayerData changes must be rejected and restored while durability is uncertain.
local previous_kills = kills.Value
local previous_equipped = equipped_display.Value
record.State = "unknown"
kills.Value = previous_kills + 1
equipped_display.Value = previous_equipped .. "-uncertain"
assert(kills.Value == previous_kills,
	"PlayerData backing numeric mutation must be reverted while ownership is uncertain")
assert(equipped_display.Value == previous_equipped,
	"PlayerData backing string mutation must be reverted while ownership is uncertain")
assert(not controller.Set(player, "kills", previous_kills + 2),
	"PlayerData.Set must reject mutation while record ownership is uncertain")
record.State = "active"

-- A coalesced change must be retried after an unknown save is reconciled.
local pending_recovery_kills = previous_kills + 17
kills.Value = pending_recovery_kills
record.State = "unknown"
task.wait(0.1)
local saved_key = "PlayerData_Test1|global|Player_" .. tostring(player.UserId)
assert(saved_records[saved_key].kills == previous_kills,
	"uncertain record must not accept a pending PlayerData flush")
record.State = "active"
record_options.on_event("reconcile", record.Key, "success", nil)
task.wait(0.1)
assert(saved_records[saved_key].kills == pending_recovery_kills,
	"successful reconciliation must reschedule retained PlayerData changes")

-- A removed cached value must trigger a safe child lookup rather than being reused.
local lookups_before_removed_value = get_find_first_child_calls()
kills:Destroy()
local removed_value_ok = controller.Set(player, "kills", 12500124)
assert(not removed_value_ok, "Set accepted a removed cached value instance")
assert(
	get_find_first_child_calls() == lookups_before_removed_value + 1,
	"Set did not re-resolve a removed cached value instance"
)

task.wait(0.1)
assert(controller:Shutdown(), "controller failed to shut down")
local stored = saved_records["PlayerData_Test1|global|Player_" .. tostring(player.UserId)]
assert(stored ~= nil, "mock record was not saved")
assert(stored.kills == 12500124, "kills was not persisted")
assert(stored.equipped == "Hi", "equipped was not persisted")
assert(stored.admin == true, "non-leaderstat admin value was not persisted")

print("[PlayerData.Set] Lune integration regression passed")
