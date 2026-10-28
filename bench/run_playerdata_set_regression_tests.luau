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
task.wait(0.1)
local saved_key = "PlayerData_Test1|global|Player_" .. tostring(player.UserId)
local pending_recovery_kills = previous_kills + 17
local original_record_update = record.Update
record.Update = function(self, transform)
	self.State = "unknown"
	return "unknown", "injected ambiguous save outcome"
end
kills.Value = pending_recovery_kills
task.wait(0.1)
assert(saved_records[saved_key].kills == previous_kills,
	"uncertain record must not accept a pending PlayerData flush")
record.Update = original_record_update
record.State = "active"
record_options.on_event("reconcile", record.Key, "success", nil)
task.wait(0.1)
assert(saved_records[saved_key].kills == pending_recovery_kills,
	"successful reconciliation must reschedule retained PlayerData changes")
success, message = controller.Set(player, "kills", previous_kills)
assert(success, message)
task.wait(0.1)
assert(saved_records[saved_key].kills == previous_kills,
	"PlayerData.Set should persist the restored baseline after recovery")

-- A removed cached value must trigger a safe child lookup rather than being reused.
local lookups_before_removed_value = get_find_first_child_calls()
kills:Destroy()
local removed_value_ok = controller.Set(player, "kills", 12500124)
assert(not removed_value_ok, "Set accepted a removed cached value instance")
assert(
	get_find_first_child_calls() == lookups_before_removed_value + 1,
	"Set did not re-resolve a removed cached value instance"
)

-- A leave during an ambiguous PlayerData flush must retain queued values until recovery.
local players = harness.players
local baseline_equipped = saved_records[saved_key].equipped
local leave_pending_equipped = baseline_equipped .. "-leave"
local original_leave_update = record.Update
record.Update = function(self, transform)
	self.State = "unknown"
	return "unknown", "injected ambiguous save during player removal"
end
equipped_display.Value = leave_pending_equipped
task.wait(0.1)
assert(saved_records[saved_key].equipped == baseline_equipped,
	"unknown record must not accept a queued leave-time mutation")
players.PlayerRemoving:Fire(player)
task.wait(0.1)
assert(saved_records[saved_key].equipped == baseline_equipped,
	"leave cleanup must not falsely persist the ambiguous mutation")
record.Update = original_leave_update
record.State = "active"
record_options.on_event("reconcile", record.Key, "success", nil)
task.wait(0.5)
assert(saved_records[saved_key].equipped == leave_pending_equipped,
	"successful reconciliation must flush retained values before closing a departed player's record")
assert(record.State == "closed", "deferred leave cleanup must close the record after flushing")

task.wait(0.1)
assert(controller:Shutdown(), "controller failed to shut down")
local stored = saved_records["PlayerData_Test1|global|Player_" .. tostring(player.UserId)]
assert(stored ~= nil, "mock record was not saved")
assert(stored.kills == 12500124, "kills was not persisted")
assert(stored.equipped == leave_pending_equipped, "leave-time equipped value was not persisted")
assert(stored.admin == true, "non-leaderstat admin value was not persisted")

-- An aged buffer must recover after a non-busy failure without admitting new mutations.
local deferred_flushes = {}
local pressure = create_harness(true, nil, {
	DurabilityMode = "read_only_on_risk",
	MaxDirtyAgeSeconds = 0.01,
	task = {
		spawn = task.spawn,
		wait = task.wait,
		defer = function(callback) table.insert(deferred_flushes, callback) end,
	},
})
local pressure_record = pressure.record
local pressure_key = "PlayerData_Test1|global|Player_" .. tostring(pressure.player.UserId)
local pressure_update = pressure_record.Update
pressure_record.GetDurabilityStatus = function()
	return { mutation_admission = "allow", dirty = false }
end
pressure_record.Update = function() return "capacity", "injected backend outage" end
local pressure_baseline = pressure.saved_records[pressure_key].kills
assert(pressure.controller.Set(pressure.player, "kills", pressure_baseline + 1))
assert(#deferred_flushes == 1, "accepted value should schedule one flush")
table.remove(deferred_flushes, 1)()
assert(#deferred_flushes == 0, "a failed flush must not retry itself indefinitely")
task.wait(0.02)
local rejected, rejection = pressure.controller.Set(pressure.player, "kills", pressure_baseline + 2)
assert(not rejected and string.find(rejection, "pending PlayerData changes", 1, true),
	"an aged buffer must reject new mutations even while requesting recovery")
assert(#deferred_flushes == 1, "aged mutation rejection must retry the stranded buffer")
table.remove(deferred_flushes, 1)()
assert(#deferred_flushes == 0, "a failed recovery flush must stop without another request")
assert(pressure.saved_records[pressure_key].kills == pressure_baseline,
	"failed recovery must not fabricate a persisted change")

local pressure_kills = pressure.player:FindFirstChild("PlayerDataValues"):FindFirstChild("kills")
pressure_kills.Value = pressure_baseline + 3
assert(pressure_kills.Value == pressure_baseline + 1,
	"an aged Value.Changed mutation must be restored while requesting recovery")
assert(#deferred_flushes == 1, "Value.Changed rejection must request recovery")
pressure_record.Update = function()
	assert(not pressure.controller.Set(pressure.player, "kills", pressure_baseline + 4),
		"a recovery request during a running flush must still reject mutations")
	return "capacity", "injected in-flight backend failure"
end
table.remove(deferred_flushes, 1)()
assert(#deferred_flushes == 1, "a recovery request during a running flush must retain one follow-up")
pressure_record.Update = pressure_update
table.remove(deferred_flushes, 1)()
assert(#deferred_flushes == 0 and pressure.saved_records[pressure_key].kills == pressure_baseline + 1,
	"recovery must flush only the earlier accepted value without a reconciliation event")
assert(pressure.controller.Set(pressure.player, "kills", pressure_baseline + 5),
	"mutation admission must resume after the pending buffer drains")
table.remove(deferred_flushes, 1)()
assert(pressure.saved_records[pressure_key].kills == pressure_baseline + 5,
	"newly admitted mutations must persist after recovery")
-- A transient busy Save must retry the accepted dirty snapshot within this flush.
assert(pressure.controller.Set(pressure.player, "kills", pressure_baseline + 6))
local save_calls, drain_saved = 0, false
pressure_record.GetDurabilityStatus = function()
	return { mutation_admission = if drain_saved then "allow" else "read_only", dirty = not drain_saved }
end
pressure_record.Save = function()
	save_calls += 1
	if save_calls <= 2 then return "busy", "injected transient write gate" end
	drain_saved = true
	return "saved"
end
table.remove(deferred_flushes, 1)()
assert(save_calls == 3 and pressure.saved_records[pressure_key].kills == pressure_baseline + 6,
	"busy drain Save must retry and flush accepted values without another event")
assert(#deferred_flushes == 0, "busy drain retry unnecessarily scheduled another flush")

assert(pressure.controller.Set(pressure.player, "kills", pressure_baseline + 7))
drain_saved = false
save_calls = 0
pressure_record.Save = function()
	save_calls += 1
	return "capacity", "injected non-busy drain failure"
end
table.remove(deferred_flushes, 1)()
assert(save_calls == 1 and pressure.saved_records[pressure_key].kills == pressure_baseline + 6,
	"non-busy Save failure must stop while preserving accepted values")
drain_saved = true
assert(pressure.controller:Shutdown(), "pressure controller failed to shut down")

print("[PlayerData.Set] Lune integration regression passed")
