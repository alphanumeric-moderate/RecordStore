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

assert(record_options.transactional_operations_enabled == false,
	"PlayerDataCore must keep transactional operations disabled by default")
local default_status, default_status_error = controller.GetStatus(player)
assert(default_status ~= nil, default_status_error)
assert(default_status.state == "active", "PlayerDataCore diagnostics returned the wrong session state")
assert(default_status.pending_change_count == 0, "new PlayerData session should not have pending mutations")
assert(default_status.ownership == "owned", "PlayerDataCore diagnostics omitted ownership state")
assert(default_status.kills == nil and default_status.profile == nil,
	"PlayerDataCore diagnostics must not expose player profile contents")
local disabled_result, disabled_status = controller.Transact(player, "disabled-operation", {}, function(data)
	return data, nil
end)
assert(disabled_result == nil and disabled_status == "disabled",
	"PlayerDataCore must not enable transactions by default")
local disabled_receipt = controller.GetTransactionStatus(player, "disabled-operation", {})
assert(disabled_receipt.code == "disabled", "disabled transaction status leaked a receipt")

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

-- A reconciliation event can arrive while the active flush has moved its batch out of pending_changes.
-- It must schedule another flush even though the buffer is temporarily empty at event time.
local recovery_race = create_harness(true)
local recovery_race_controller = recovery_race.controller
local recovery_race_player = recovery_race.player
local recovery_race_record = recovery_race.record
local recovery_race_options = recovery_race.get_record_options()
local recovery_race_task = recovery_race.task
local recovery_race_key = "PlayerData_Test1|global|Player_" .. tostring(recovery_race_player.UserId)
local recovery_race_baseline = recovery_race.saved_records[recovery_race_key].kills
local recovery_race_update = recovery_race_record.Update
local recovery_race_attempts = 0

recovery_race_record.Update = function(self, transform)
	recovery_race_attempts += 1
	if recovery_race_attempts == 1 then
		recovery_race_options.on_event("reconcile", self.Key, "success", nil)
		recovery_race_task.wait(0.05)
		return "capacity", "injected transient failure after reconciliation notification"
	end
	return recovery_race_update(self, transform)
end

local recovery_race_target = recovery_race_baseline + 23
local recovery_race_set, recovery_race_message = recovery_race_controller.Set(
	recovery_race_player,
	"kills",
	recovery_race_target
)
assert(recovery_race_set, recovery_race_message)
recovery_race_task.wait(0.2)
assert(recovery_race_attempts >= 2,
	"reconciliation during an in-flight flush did not trigger an automatic retry")
assert(recovery_race.saved_records[recovery_race_key].kills == recovery_race_target,
	"accepted PlayerData changes remained blocked after successful reconciliation")
assert(recovery_race_controller:Shutdown(), "recovery-race controller failed to shut down")

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

local transactions = create_harness(true, nil, { TransactionalOperationsEnabled = true })
local tx_controller = transactions.controller
local tx_player = transactions.player
local tx_record = transactions.record
local tx_record_options = transactions.get_record_options()
local tx_key = "PlayerData_Test1|global|Player_" .. tostring(tx_player.UserId)
assert(tx_record_options.transactional_operations_enabled == true,
	"PlayerDataCore did not opt the record into transactions")
local tx_initial_data = tx_record:Get()
local tx_initial_kills = tx_initial_data.kills
local tx_request = { operation = "increment-kills", amount = 12 }
local tx_operation_id = "playerdata-set-regression-increment-1"
local function increment_kills(current)
	local data = current :: { [string]: any }
	data.kills = (data.kills :: number) + 12
	return data, { kills = data.kills }
end

local tx_result, tx_status, tx_message = tx_controller.Transact(
	tx_player,
	tx_operation_id,
	tx_request,
	increment_kills
)
assert(tx_status == "committed", tx_message)
assert(type(tx_result) == "table" and tx_result.kills == tx_initial_kills + 12,
	"PlayerDataCore transaction returned an incorrect result")
assert(transactions.saved_records[tx_key].kills == tx_initial_kills + 12,
	"PlayerDataCore transaction did not persist its updated profile")
local tx_values = tx_player:FindFirstChild("PlayerDataValues")
local tx_kills = if tx_values ~= nil then tx_values:FindFirstChild("kills") else nil
assert(tx_kills ~= nil and tx_kills.Value == tx_initial_kills + 12,
	"PlayerDataCore did not sync committed transaction values to the live backing instance")
local tx_live_status, tx_live_status_error = tx_controller.GetStatus(tx_player)
assert(tx_live_status ~= nil, tx_live_status_error)
assert(tx_live_status.pending_change_count == 0,
	"transaction value synchronization queued a duplicate PlayerData mutation")

local duplicate_result, duplicate_status, duplicate_message = tx_controller.Transact(
	tx_player,
	tx_operation_id,
	tx_request,
	increment_kills
)
assert(duplicate_status == "duplicate", duplicate_message)
assert(type(duplicate_result) == "table" and duplicate_result.kills == tx_initial_kills + 12,
	"duplicate PlayerData transaction did not return the original receipt result")
assert(transactions.saved_records[tx_key].kills == tx_initial_kills + 12,
	"duplicate PlayerData transaction applied the mutation twice")
local conflicting_result, conflicting_status = tx_controller.Transact(
	tx_player,
	tx_operation_id,
	{ operation = "increment-kills", amount = 13 },
	increment_kills
)
assert(conflicting_result == nil and conflicting_status == "conflict",
	"PlayerDataCore accepted an operation ID bound to a different request")
local tx_receipt = tx_controller.GetTransactionStatus(tx_player, tx_operation_id, tx_request)
assert(tx_receipt.code == "committed", "PlayerDataCore transaction receipt status was incorrect")
assert(tx_controller:Shutdown(), "transaction-enabled PlayerData controller failed to shut down")

-- Gameplay edits accepted while TransactAsync yields must survive its live-value refresh.
local transaction_flushes = {}
local concurrent = create_harness(true, nil, {
	TransactionalOperationsEnabled = true,
	task = {
		spawn = task.spawn,
		wait = task.wait,
		defer = function(callback) table.insert(transaction_flushes, callback) end,
	},
})
local concurrent_controller = concurrent.controller
local concurrent_player = concurrent.player
local concurrent_record = concurrent.record
local concurrent_key = "PlayerData_Test1|global|Player_" .. tostring(concurrent_player.UserId)
local concurrent_kills = concurrent_player:FindFirstChild("PlayerDataValues"):FindFirstChild("kills")
local concurrent_equipped = concurrent_player:FindFirstChild("leaderstats"):FindFirstChild("Equipped")
local original_transact = concurrent_record.TransactAsync
concurrent_record.TransactAsync = function(self, ...)
	local result, status, message = original_transact(self, ...)
	coroutine.yield()
	return result, status, message
end
local function change_profile(current)
	current.kills += 12
	current.equipped = "TransactionGlove"
	return current, { kills = current.kills }
end
for _, expected_status in { "committed", "duplicate" } do
	local pending_kills = concurrent_kills.Value + 100
	local transaction_thread = coroutine.create(function()
		local _, status, message = concurrent_controller.Transact(
			concurrent_player, "concurrent-gameplay-edit", tx_request, change_profile
		)
		assert(status == expected_status, message or status)
	end)
	local started, start_error = coroutine.resume(transaction_thread)
	assert(started, start_error)
	assert(coroutine.status(transaction_thread) == "suspended", "transaction did not yield before refresh")
	if expected_status == "committed" then
		assert(concurrent_controller.Set(concurrent_player, "kills", pending_kills))
	else
		concurrent_kills.Value = pending_kills
	end
	assert(#transaction_flushes == 1, "concurrent gameplay edit did not schedule its normal flush")
	local resumed, resume_error = coroutine.resume(transaction_thread)
	assert(resumed, resume_error)
	assert(coroutine.status(transaction_thread) == "dead", "transaction did not finish")
	assert(concurrent_kills.Value == pending_kills,
		"transaction refresh overwrote a buffered gameplay edit")
	assert(concurrent_equipped.Value == "TransactionGlove",
		"transaction refresh skipped a field without buffered changes")
	local concurrent_status = concurrent_controller.GetStatus(concurrent_player)
	assert(concurrent_status.pending_change_count == 1,
		"transaction refresh discarded a buffered edit or queued an extra mutation")
	table.remove(transaction_flushes, 1)()
	assert(concurrent.saved_records[concurrent_key].kills == pending_kills,
		"normal flush did not persist the gameplay edit accepted during the transaction")
	assert(concurrent.saved_records[concurrent_key].equipped == "TransactionGlove",
		"normal flush lost the transaction change to an unbuffered field")
end
assert(concurrent_controller:Shutdown(), "concurrent-transaction controller failed to shut down")

print("[PlayerData.Set] Lune integration regression passed")
