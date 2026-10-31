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


-- Shutdown may occur while the acceleration adapter is created, starts, or cleans up.
for _, scenario in ipairs({ "constructor_yields", "success", "failure", "error", "cleanup_yields" }) do
	local stop_calls = 0
	local start_calls = 0
	local acceleration = {}
	function acceleration:Start()
		start_calls += 1
		if scenario ~= "cleanup_yields" then coroutine.yield() end
		if scenario == "error" then error("startup failed") end
		return scenario == "success", "startup failed"
	end
	function acceleration:Stop()
		stop_calls += 1
		if scenario == "cleanup_yields" then coroutine.yield() end
	end
	local harness = create_harness(true, nil, {
		MailboxWakeupsEnabled = true,
		QueueMessageHandler = function() return true end,
		MessagingService = {},
		HttpService = {},
		RecordStoreV2 = { new = function()
			return { Mailbox = { new = function() end }, Canonicalize = function() end }
		end },
		RecordStoreV2Acceleration = { new = function()
			if scenario == "constructor_yields" then coroutine.yield() end
			return acceleration
		end },
	}, true)
	local connections = 0
	for _, signal in ipairs({ harness.players.PlayerAdded, harness.players.PlayerRemoving }) do
		local connect = signal.Connect
		function signal:Connect(callback)
			connections += 1
			return connect(self, callback)
		end
	end
	local startup = coroutine.create(function() return harness.controller:Start() end)
	local ok, result = coroutine.resume(startup)
	assert(ok and coroutine.status(startup) == "suspended", "startup did not pause: " .. scenario)
	assert(harness.controller:Shutdown(), "shutdown during startup failed: " .. scenario)
	ok, result = coroutine.resume(startup)
	assert(ok and coroutine.status(startup) == "dead" and result == false,
		"startup did not stop after shutdown: " .. scenario .. ": " .. tostring(result))
	assert(stop_calls == 1, "acceleration was not stopped exactly once: " .. scenario)
	assert(start_calls == (if scenario == "constructor_yields" then 0 else 1),
		"unexpected acceleration startup calls: " .. scenario)
	assert(connections == 0, "player signals were connected after shutdown: " .. scenario)
	assert(harness.get_record_options() == nil, "player loading began after shutdown: " .. scenario)
end

-- V2 mailbox wake-ups are opt-in, handler-backed, and cleaned up with each session.
do
	local default_harness = create_harness(true)
	local default_options = default_harness.get_record_options()
	assert(default_options.durable_queue_enabled == false,
		"the default PlayerDataCore configuration must not enable the durable queue")
	assert(default_options.on_queue_message == nil and default_options.on_queue_message_async == nil,
		"the default PlayerDataCore configuration must not install queue handlers")
	assert(default_harness.controller:Shutdown(), "default mailbox regression controller failed to shut down")

	local missing_handler_ok = pcall(function()
		create_harness(true, nil, { MailboxWakeupsEnabled = true })
	end)
	assert(not missing_handler_ok,
		"MailboxWakeupsEnabled must reject startup configuration without an application queue handler")
	local missing_wakeup_ok = pcall(function()
		create_harness(true, nil, { MemoryStoreAccelerationHintsEnabled = true })
	end)
	assert(not missing_wakeup_ok,
		"MemoryStore hints must require MailboxWakeupsEnabled")

	local received = {}
	local acceleration_options = nil
	local registration_callback = nil
	local registration = nil
	local stop_calls = 0
	local fake_acceleration = {}
	function fake_acceleration:Start()
		self.started = true
		return true, nil
	end
	function fake_acceleration:Register(owner, callback)
		self.owner = owner
		registration_callback = callback
		registration = { Connected = true }
		function registration:Disconnect()
			self.Connected = false
		end
		return true, registration
	end
	function fake_acceleration:Stop()
		stop_calls += 1
		self.started = false
		return true
	end

	local fake_acceleration_factory = {
		new = function(options)
			acceleration_options = options
			return fake_acceleration
		end,
	}
	local captured_mailbox_options = nil
	local fake_v2_factory = {
		new = function(_record_store, mailbox_module, options)
			assert(type(mailbox_module) == "table" and type(mailbox_module.new) == "function",
				"PlayerDataCore did not supply the embedded Mailbox V2 module")
			assert(options.acceleration_module == fake_acceleration_factory,
				"PlayerDataCore did not pass the acceleration adapter to RecordStoreV2")
			local api = {
				Canonicalize = function(owner)
					return owner.profile_key
				end,
			}
			api.Mailbox = {
				new = function(store, owner, mailbox_options)
					assert(store ~= nil, "PlayerDataCore did not create a mailbox storage adapter")
					captured_mailbox_options = mailbox_options
					local mailbox = {}
					function mailbox:BindWakeups(adapter)
						self.wakeups = adapter
						return true, nil
					end
					mailbox._owner = owner
					return mailbox
				end,
			}
			return api
		end,
	}

	local messaging_service = {}
	local memory_store_service = {}
	local http_service = {}
	local wakeup_harness = create_harness(true, nil, {
		MailboxWakeupsEnabled = true,
		MemoryStoreAccelerationHintsEnabled = true,
		MessagingService = messaging_service,
		MemoryStoreService = memory_store_service,
		HttpService = http_service,
		ServerId = "playerdata-mailbox-regression",
		RecordStoreV2 = fake_v2_factory,
		RecordStoreV2Acceleration = fake_acceleration_factory,
		QueueMessageHandler = function(
			message_player,
			message_type,
			payload,
			attempts,
			message_id,
			sender_job_id,
			created_at,
			context
		)
			received[#received + 1] = {
				player = message_player,
				message_type = message_type,
				payload = payload,
				attempts = attempts,
				message_id = message_id,
				sender_job_id = sender_job_id,
				created_at = created_at,
				context = context,
			}
			if message_type == "AwardKill" then
				return true, nil
			end
			return false, "unsupported message type"
		end,
	})

	local wakeup_record_options = wakeup_harness.get_record_options()
	assert(wakeup_record_options.durable_queue_enabled == true,
		"enabling PlayerDataCore mailbox wake-ups must enable the durable queue")
	assert(type(wakeup_record_options.on_queue_message) == "function",
		"legacy durable-queue polling handler was not installed")
	assert(type(wakeup_record_options.on_queue_message_async) == "function",
		"asynchronous V2 queue handler was not installed")
	assert(acceleration_options ~= nil and acceleration_options.enabled == true,
		"PlayerDataCore did not enable the V2 acceleration adapter")
	assert(acceleration_options.enable_memory_store == true
		and acceleration_options.memory_store_service == memory_store_service,
		"PlayerDataCore did not enable MemoryStore acceleration hints")
	assert(acceleration_options.messaging_service == messaging_service
		and acceleration_options.http_service == http_service
		and acceleration_options.server_id == "playerdata-mailbox-regression",
		"PlayerDataCore did not pass its injected Roblox services to acceleration")
	assert(wakeup_record_options ~= nil and wakeup_harness.record._mailbox_v2 ~= nil,
		"PlayerDataCore did not bind a V2 mailbox to the active Record")
	assert(captured_mailbox_options ~= nil
		and captured_mailbox_options.active_record == wakeup_harness.record,
		"PlayerDataCore did not bind the mailbox to the exact active Record")
	local active_allowed, active_guard_error = captured_mailbox_options.activation_guard("enqueue")
	assert(active_allowed == true, active_guard_error)
	assert(wakeup_harness.record._mailbox_v2.wakeups == fake_acceleration,
		"PlayerDataCore did not bind the wake-up adapter to Mailbox V2")
	assert(registration ~= nil and registration.Connected,
		"PlayerDataCore did not register the V2 mailbox wake-up callback")

	local legacy_ok, legacy_error = wakeup_record_options.on_queue_message(
		"AwardKill", { amount = 2 }, 1, "legacy-message-1", "legacy-server", 123
	)
	assert(legacy_ok, legacy_error)
	local async_context = { source = "legacy-async" }
	local async_ok, async_error = wakeup_record_options.on_queue_message_async(
		"AwardKill", { amount = 3 }, 2, "legacy-message-2", "legacy-server", 124, async_context
	)
	assert(async_ok, async_error)
	assert(#received == 2, "legacy queue messages were not routed through the application handler")
	assert(received[1].player == wakeup_harness.player and received[2].context == async_context,
		"legacy queue handler did not receive the player and delivery context")

	registration_callback()
	assert(wakeup_harness.record._queue_process_calls == 1
		and wakeup_harness.record._queue_process_limit == 4,
		"wake-up callback did not enter Record:ProcessQueueAsync with the configured batch cap")
	assert(#received == 3 and received[3].message_id == "mailbox-message-1"
		and received[3].context.source == "record-process",
		"wake-up callback did not drain through RecordStore's queue processing path")

	wakeup_harness.players.PlayerRemoving:Fire(wakeup_harness.player)
	task.wait(0.1)
	assert(registration.Connected == false,
		"PlayerDataCore did not disconnect a player's wake-up registration on leave")
	local inactive_guard = captured_mailbox_options.activation_guard("process")
	assert(inactive_guard == false, "mailbox activation guard remained open after player removal")
	local rejected_after_leave = wakeup_record_options.on_queue_message(
		"AwardKill", { amount = 5 }, 1, "late-message", "remote-server", 126
	)
	assert(rejected_after_leave == false,
		"PlayerDataCore accepted a queue message after its player session had been removed")
	assert(wakeup_harness.controller:Shutdown(), "mailbox wake-up controller failed to shut down")
	assert(stop_calls == 1 and fake_acceleration.started == false,
		"PlayerDataCore did not stop the shared acceleration adapter exactly once on shutdown")
end

print("[PlayerData.Set] Lune integration regression passed")

