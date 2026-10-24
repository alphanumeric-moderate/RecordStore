--!nocheck
local Shim = require("./RobloxShim")
local RecordStore = Shim.load()
local V2Module = require(
	game:GetService("ServerScriptService"):WaitForChild("PlayerDataInitializer"):WaitForChild("RecordStoreV2")
)
local V2 = V2Module.new(RecordStore, RecordStore.MailboxV2)

local function expect(value, message)
	assert(value, message)
end

local function clone(value, depth)
	depth = depth or 0
	assert(depth <= 64, "test store value exceeds depth bound")
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in pairs(value) do result[clone(key, depth + 1)] = clone(child, depth + 1) end
	return result
end

local function new_store()
	local values = {}
	local store = { values = values, fail_after_next_update = false, update_calls = 0 }
	function store:GetAsync(key)
		return clone(self.values[key]), nil
	end
	function store:UpdateAsync(key, transform)
		self.update_calls += 1
		local next_value = transform(clone(self.values[key]))
		self.values[key] = clone(next_value)
		if self.fail_after_next_update then
			self.fail_after_next_update = false
			error("injected response loss after durable update")
		end
		return clone(next_value), nil
	end
	return store
end

local policy_status, policy_message = V2.ApplyRuntimePolicy({
	revision = 2,
	max_dirty_age_seconds = 120,
})
expect(policy_status == "success", "versioned runtime policy rejected: " .. tostring(policy_message))
local runtime_snapshot = V2.GetRuntimeSnapshot()
expect(runtime_snapshot.policy.revision == 2 and runtime_snapshot.policy.max_dirty_age_seconds == 120,
	"runtime snapshot did not reflect the validated policy")
expect(type(runtime_snapshot.scheduler) == "table", "runtime snapshot omitted the core scheduler snapshot")
expect(V2.ApplyRuntimePolicy({ revision = 2, max_dirty_age_seconds = 120 }) == "invalid",
	"runtime policy accepted a stale revision")
expect(V2.ApplyRuntimePolicy({ revision = 3, max_dirty_age_seconds = math.huge }) == "invalid",
	"runtime policy accepted a non-finite dirty-age threshold")

local trace_store = new_store()
local tracer = V2.Tracing.new({ max_events = 16, success_sample_every = 1, store = trace_store })
local trace_ok = tracer:Emit({
	operation_id = "operation-1", correlation_id = "correlation-1", causation_id = "cause-1",
	component = "transaction", operation = "commit", result = "unknown", duration_ms = 27,
	payload = { private = "must not be stored" }, player_name = "must not be stored",
})
expect(trace_ok == true, "trace event was rejected")
local local_trace = tracer:GetOperationTrace("correlation-1", 8)
expect(local_trace.code == "success" and #local_trace.events == 1, "local trace could not be queried by correlation ID")
expect(local_trace.events[1].payload == nil and local_trace.events[1].player_name == nil,
	"trace captured raw payload or player identity")
local flush = tracer:FlushAsync("operation-1", 8)
expect(flush.code == "committed", "durable trace flush failed: " .. tostring(flush.message))
local durable_trace = tracer:GetOperationTraceAsync("operation-1", 8)
expect(durable_trace.durable_read == "success" and #durable_trace.events == 1,
	"durable trace read/merge failed")
expect(durable_trace.events[1].payload == nil, "durable trace stored payload data")

local sender = RecordStore.Mock.new("V2SagaProfiles", "global", "sender", {
	schema_version = 1, transactional_operations_enabled = true,
})
local recipient = RecordStore.Mock.new("V2SagaProfiles", "global", "recipient", {
	schema_version = 1, transactional_operations_enabled = true,
})
local sender_open, sender_open_message = sender:Open({ Balance = 100 })
local recipient_open, recipient_open_message = recipient:Open({ Balance = 25 })
expect(sender_open == "created" or sender_open == "loaded", "sender open failed: " .. tostring(sender_open_message))
expect(recipient_open == "created" or recipient_open == "loaded", "recipient open failed: " .. tostring(recipient_open_message))
local saga_store = new_store()
local sagas = V2.Sagas.new(saga_store)
local transfer = sagas:TransferAsync("transfer-stable-001", sender, recipient, 15, {
	sender_id = "sender", recipient_id = "recipient",
})
expect(transfer.code == "settled", "transfer saga did not settle: " .. tostring(transfer.code) .. " " .. tostring(transfer.message))
expect(sender:Get().Balance == 85 and recipient:Get().Balance == 40,
	"settled transfer violated balance conservation")
local duplicate_transfer = sagas:TransferAsync("transfer-stable-001", sender, recipient, 15, {
	sender_id = "sender", recipient_id = "recipient",
})
expect(duplicate_transfer.code == "settled", "settled saga retry was not idempotent")
expect(sender:Get().Balance == 85 and recipient:Get().Balance == 40,
	"duplicate transfer changed balances")
local conflicting_transfer = sagas:TransferAsync("transfer-stable-001", sender, recipient, 20, {
	sender_id = "sender", recipient_id = "recipient",
})
expect(conflicting_transfer.code == "conflict", "saga ID reuse with a different request was accepted")

saga_store.fail_after_next_update = true
local response_loss_transfer = sagas:TransferAsync("transfer-response-loss-002", sender, recipient, 5, {
	sender_id = "sender", recipient_id = "recipient",
})
expect(response_loss_transfer.code == "settled",
	"saga failed to reconcile response loss after durable state creation: " .. tostring(response_loss_transfer.code))
expect(sender:Get().Balance == 80 and recipient:Get().Balance == 45,
	"saga response-loss recovery did not conserve balances")
local durable_transfer_status = sagas:GetStatus("transfer-response-loss-002")
expect(durable_transfer_status.code == "settled", "saga status read did not return the durable terminal phase")

local projection_store = new_store()
local projections = V2.Projections.new(projection_store)
local registered = projections:Register("balance_projection_v1", 1, function(current, event)
	local updated = clone(current)
	updated.total = (updated.total or 0) + event.amount
	return updated
end, { source = "profile-outbox" })
expect(registered == true, "projection registration failed")
local projection_event = { event_id = "projection-event-1", entity_id = "user-1", source_revision = 1, amount = 10 }
local projection_result = projections:ApplyAsync("balance_projection_v1", projection_event)
expect(projection_result.code == "committed", "projection application failed: " .. tostring(projection_result.code))
local duplicate_projection = projections:ApplyAsync("balance_projection_v1", projection_event)
expect(duplicate_projection.code == "duplicate", "projection duplicate was reapplied")
local projected = projections:GetAsync("balance_projection_v1", "user-1")
expect(projected.code == "success" and projected.row.value.total == 10,
	"projection did not retain its idempotent value")
projection_store.fail_after_next_update = true
local response_loss_projection = projections:ApplyAsync("balance_projection_v1", {
	event_id = "projection-event-2", entity_id = "user-1", source_revision = 2, amount = 5,
})
expect(response_loss_projection.code == "committed" and response_loss_projection.reconciled == true,
	"projection did not reconcile commit-then-response-loss")
local unique_first = projections:ReserveUnique("username", "barcode", "user-1", "reserve-1")
local unique_duplicate = projections:ReserveUnique("username", "barcode", "user-1", "reserve-1")
local unique_conflict = projections:ReserveUnique("username", "barcode", "user-2", "reserve-2")
expect(unique_first.code == "committed" and unique_duplicate.code == "duplicate" and unique_conflict.code == "conflict",
	"unique projection reservation outcomes were incorrect")

local erase_store = new_store()
local deleted_items = {}
local families = {
	{
		name = "player_profiles",
		templates = { { name = "PlayerData", scope = "global", key = "Player_{user_id}" } },
		templates_verified = true,
		inventory = function(user_id, maximum)
			return { { key = "Player_" .. tostring(user_id), generation = 4 } }
		end,
		fence_user = function() return true end,
		dependencies_clear = function() return true end,
		redact_or_delete_if_generation = function(item, user_id, erasure_id)
			deleted_items[#deleted_items + 1] = { key = item.key, user_id = user_id, erasure_id = erasure_id }
			return "deleted"
		end,
	},
}
local erasure = V2.Erasure.new(erase_store, families, {
	verify_templates = function(_user_id, rendered) return type(rendered) == "table" and #rendered == 1 end,
})
local erasure_plan = erasure:PlanAsync(123456, "erase-stable-1")
expect(erasure_plan.code == "success" and erasure_plan.rtbf_coverage_verified == true,
	"verified erasure plan was not recorded")
local erasure_result = erasure:ExecuteAsync(123456, "erase-stable-1", 1)
expect(erasure_result.code == "committed" and erasure_result.completed_count == 1,
	"bounded erasure execution did not complete")
expect(#deleted_items == 1 and deleted_items[1].key == "Player_123456",
	"erasure failed to invoke its generation-aware deletion adapter")
expect(erasure:GetStatus(123456).status == "completed", "erasure manifest status was not durable")
local unverified_erasure = V2.Erasure.new(new_store(), {
	{
		name = "unverified_family",
		templates = { { name = "SharedStore", scope = "global", key = "shared-key" } },
		templates_verified = false,
		inventory = function() return {} end,
		fence_user = function() return true end,
		redact_or_delete_if_generation = function() return "deleted" end,
	},
}, { verify_templates = function() return true end })
local unverified_plan = unverified_erasure:PlanAsync(123456, "erase-unverified")
expect(unverified_plan.rtbf_coverage_verified == false,
	"erasure claimed complete coverage for an unverified key template")

local compaction_store = new_store()
local removed = {}
local compactor = V2.Maintenance.NewCompactor({
	next_page = function(cursor, maximum)
		return { { key = "expired-a", generation = 4 }, { key = "active-b", generation = 7 } }, nil, true
	end,
	inspect = function(item)
		return { status = "success", eligible = item.key == "expired-a", dependencies_clear = item.key == "expired-a", generation = item.generation }
	end,
	delete_if_generation = function(item, generation)
		removed[#removed + 1] = { key = item.key, generation = generation }
		return "deleted"
	end,
	persist_progress = function(cursor, processed, removed_count, status)
		compaction_store.values.checkpoint = { cursor = cursor, processed = processed, removed = removed_count, status = status }
		return true
	end,
})
local compacted = compactor:RunStep(16, 500)
expect(compacted.code == "completed" and compacted.processed == 2 and compacted.removed == 1,
	"bounded compactor did not report its progress")
expect(#removed == 1 and removed[1].generation == 4, "compactor deleted an ineligible generation")
expect(compaction_store.values.checkpoint.status == "running" or compaction_store.values.checkpoint.status == "completed",
	"compactor did not persist progress")

local migration_record = RecordStore.Mock.new("V2MigrationProfiles", "global", "profile", {
	schema_version = 1, transactional_operations_enabled = true,
})
local migration_open, migration_open_message = migration_record:Open({ cash = 10 })
expect(migration_open == "created" or migration_open == "loaded", "migration profile open failed: " .. tostring(migration_open_message))
local migration_manifest_store = new_store()
local manifest_update = migration_manifest_store.UpdateAsync
migration_manifest_store.UpdateAsync = function(self, key, transform)
	return manifest_update(self, key, function(old)
		local proposed = transform(old)
		if type(proposed) == "table" and proposed.status == "committed" then
			self.fail_after_next_update = true
		end
		return proposed
	end)
end
local migrations = V2.Migrations.new({
	manifest_store = migration_manifest_store,
	require_durable_manifest = true,
})
local migration_registered, migration_register_message = migrations:Register(
	"V2MigrationProfiles", 0, 1, "cash-v1-upgrade", "revision-1",
	function(data)
		local updated = clone(data)
		updated.cash += 5
		return updated
	end,
	function(data) return type(data.cash) == "number", "cash must be numeric" end
)
expect(migration_registered == true, "migration registration failed: " .. tostring(migration_register_message))
local preview = migrations:Preview(migration_record, "V2MigrationProfiles", 1)
expect(preview.code == "success" and preview.preview_only == true, "migration preview failed")
expect(migration_record:Get().cash == 10, "migration preview mutated durable profile data")
local migrated = migrations:MigrateAsync(migration_record, "V2MigrationProfiles", 1)
expect(migrated.code == "committed" and migration_record:Get().cash == 15,
	"transactional migration did not commit its profile transformation")
local successful_manifest = nil
for _, candidate in pairs(migration_manifest_store.values) do
	if type(candidate) == "table" and candidate.id == "cash-v1-upgrade" then successful_manifest = candidate end
end
expect(successful_manifest ~= nil and successful_manifest.status == "committed",
	"durable migration manifest did not reconcile a response lost after commit")
expect(type(successful_manifest.operation_id) == "string", "durable migration manifest omitted its stable operation ID")
local durable_migration_status = migrations:GetStatus(successful_manifest.operation_id)
expect(durable_migration_status.status == "committed",
	"migration status API disagreed with its durable committed manifest")
local duplicate_registration, duplicate_registration_message = migrations:Register(
	"V2MigrationProfiles", 0, 1, "cash-v1-upgrade", "revision-1",
	function(data) return data end,
	function(data) return type(data.cash) == "number" end
)
expect(duplicate_registration == true and duplicate_registration_message == "duplicate",
	"same stable migration manifest did not register idempotently")

local failed_migration_record = RecordStore.Mock.new("V2MigrationFailureProfiles", "global", "profile", {
	schema_version = 1, transactional_operations_enabled = true,
})
local failed_migration_open, failed_migration_open_message = failed_migration_record:Open({ cash = 1 })
expect(failed_migration_open == "created" or failed_migration_open == "loaded",
	"failure migration profile open failed: " .. tostring(failed_migration_open_message))
local failed_registration, failed_registration_message = migrations:Register(
	"V2MigrationFailureProfiles", 0, 1, "cash-v1-invalid", "revision-1",
	function(data)
		local updated = clone(data)
		updated.cash = -1
		return updated
	end,
	function() return false, "intentional migration validation rejection" end
)
expect(failed_registration == true, "failing migration registration failed: " .. tostring(failed_registration_message))
local failed_migration = migrations:MigrateAsync(failed_migration_record, "V2MigrationFailureProfiles", 1)
expect(failed_migration.manifest_status == "quarantined",
	"failed migration was not durably quarantined: " .. tostring(failed_migration.manifest_status))
local quarantined_manifest = nil
for _, candidate in pairs(migration_manifest_store.values) do
	if type(candidate) == "table" and candidate.id == "cash-v1-invalid" then quarantined_manifest = candidate end
end
expect(quarantined_manifest ~= nil and quarantined_manifest.status == "quarantined",
	"failed migration quarantine did not persist")
local quarantine_resolution = migrations:ResolveQuarantine(
	"V2MigrationFailureProfiles", "cash-v1-invalid", "revision-1", "operator-1", "reviewed migration validator failure"
)
expect(quarantine_resolution.code == "committed",
	"migration quarantine resolution failed: " .. tostring(quarantine_resolution.code))
local resolved_migration_manifest = nil
for _, candidate in pairs(migration_manifest_store.values) do
	if type(candidate) == "table" and candidate.id == "cash-v1-invalid" then resolved_migration_manifest = candidate end
end
expect(resolved_migration_manifest ~= nil and resolved_migration_manifest.status == "registered"
	and type(resolved_migration_manifest.resolution) == "table",
	"migration quarantine resolution was not durably audited")

local repair_preview = V2.ProfileDoctor.PreviewRepair(migration_record, {
	id = "cash-repair", revision = "v1",
	preview = function(data) local updated = clone(data); updated.cash = 20; return updated end,
	validate = function(data) return type(data.cash) == "number" and data.cash >= 0 end,
}, { expected_revision = migration_record:GetRevision() })
expect(repair_preview.code == "success" and repair_preview.preview_only == true,
	"profile repair preview did not remain read-only")
local restored = V2.ProfileDoctor.Restore(
	migration_record, { cash = 99 }, migration_record:GetRevision(),
	"restore-stable-1", "operator-1", "verified historical restore",
	{ subject_user_id = 123456, is_erased = function() return false end }
)
expect(restored.code == "committed" and migration_record:Get().cash == 99,
	"guarded restore failed to commit an audited historical value")
expect(migration_record:Get().cash ~= nil, "restored profile lost user data")

local profile_quarantine_store = new_store()
local diagnosed_revision = migration_record:GetRevision()
local quarantined_profile = V2.ProfileDoctor.QuarantineAsync(
	migration_record, profile_quarantine_store, "profile-quarantine-001",
	"operator-1", "manual diagnosis requires writer fencing", diagnosed_revision
)
expect(quarantined_profile.code == "committed",
	"profile quarantine manifest was not committed: " .. tostring(quarantined_profile.code))
local profile_quarantine_status = V2.ProfileDoctor.GetQuarantineStatusAsync(migration_record, profile_quarantine_store)
expect(profile_quarantine_status.code == "success" and profile_quarantine_status.status == "quarantined",
	"profile quarantine status could not be read durably")
local profile_quarantine_resolved = V2.ProfileDoctor.ResolveQuarantineAsync(
	migration_record, profile_quarantine_store, "profile-quarantine-001",
	"operator-1", "write paths inspected", migration_record:GetRevision()
)
expect(profile_quarantine_resolved.code == "committed",
	"profile quarantine resolution failed: " .. tostring(profile_quarantine_resolved.code))
expect(V2.ProfileDoctor.GetQuarantineStatusAsync(migration_record, profile_quarantine_store).status == "resolved",
	"profile quarantine resolution was not persisted")

sender:Close()
recipient:Close()
migration_record:Close()
failed_migration_record:Close()
RecordStore.Mock.reset()
Shim.close()
