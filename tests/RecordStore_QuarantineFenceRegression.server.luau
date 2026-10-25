--!nocheck
local Shim = require("./RobloxShim")
local RecordStore = Shim.load()
local V2Module = require(
	game:GetService("ServerScriptService"):WaitForChild("PlayerDataInitializer"):WaitForChild("RecordStoreV2")
)
local V2 = V2Module.new(RecordStore.Mock, RecordStore.MailboxV2)

local function expect(value, message)
	assert(value, message)
end

local function clone(value, depth)
	depth = depth or 0
	assert(depth <= 48, "quarantine test store exceeded the clone depth bound")
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in pairs(value) do result[clone(key, depth + 1)] = clone(child, depth + 1) end
	return result
end

local function new_store()
	local store = {
		values = {},
		fail_next_update_response = false,
		fail_read_after_status = nil,
		fail_next_read = false,
	}
	function store:GetAsync(key)
		if self.fail_next_read then
			self.fail_next_read = false
			return nil, "injected audit manifest read failure"
		end
		return clone(self.values[key]), nil
	end
	function store:UpdateAsync(key, transform)
		local proposed = transform(clone(self.values[key]))
		if proposed ~= nil then self.values[key] = clone(proposed) end
		local current = self.values[key]
		if self.fail_read_after_status ~= nil and type(current) == "table"
			and current.status == self.fail_read_after_status
		then
			self.fail_read_after_status = nil
			self.fail_next_read = true
		end
		if self.fail_next_update_response then
			self.fail_next_update_response = false
			error("injected audit manifest response loss after commit")
		end
		return clone(current), nil
	end
	return store
end

local function open_profile(store_name, key)
	local record = RecordStore.Mock.new(store_name, "global", key, {
		schema_version = 1,
		user_ids = { 123456 },
		transactional_operations_enabled = true,
	})
	local opened, message = record:Open({ cash = 10, grant_count = 0 })
	expect(opened == "created" or opened == "loaded",
		"quarantine regression profile open failed: " .. tostring(message))
	return record
end

local function quarantine(record, manifest_store, id, expected_revision)
	return V2.ProfileDoctor.QuarantineAsync(
		record, manifest_store, id, "operator-1", "verified quarantine regression", expected_revision
	)
end

local writer_record = open_profile("QuarantineFenceRegression", "writer")
local writer_manifest = new_store()
writer_manifest.fail_next_update_response = true
RecordStore.Mock.set_update_commit_then_failures(1, "injected profile fence response loss after commit")

local fenced_result = quarantine(writer_record, writer_manifest, "quarantine-writer-001", writer_record:GetRevision())
expect(fenced_result.code == "committed" and fenced_result.reconciled == true,
	"same-key fence/audit response loss was not reconciled: " .. tostring(fenced_result.code))
local raw_fenced = RecordStore.Mock.get_record_raw("QuarantineFenceRegression", "global", "writer")
expect(type(raw_fenced) == "table"
	and raw_fenced.implementation_version == 2147483646
	and type(raw_fenced.__recordstore_quarantine_fence_v1) == "table",
	"quarantine did not persist a same-key fence before reporting success")
local first_marker = raw_fenced.__recordstore_quarantine_fence_v1
expect(first_marker.quarantine_id == "quarantine-writer-001"
	and first_marker.phase == "quarantined",
	"quarantine fence omitted its stable identity or phase")

local same_fence = quarantine(
	writer_record, writer_manifest, "quarantine-writer-001", writer_record:GetRevision()
)
expect(same_fence.code == "duplicate" or same_fence.code == "committed",
	"same quarantine retry was not idempotent: " .. tostring(same_fence.code))
local competing_fence = quarantine(
	writer_record, writer_manifest, "quarantine-writer-002", writer_record:GetRevision()
)
expect(competing_fence.code == "conflict",
	"a competing quarantine ID replaced an active same-key fence")
local writer_gate = V2.ProfileDoctor.CheckWritableAsync(writer_record, writer_manifest)
expect(writer_gate.allowed == false and writer_gate.code == "quarantined",
	"writer gate ignored the authoritative same-key quarantine fence")
local fenced_data, fenced_read_code = RecordStore.Mock.read_async(
	"QuarantineFenceRegression", "global", "writer"
)
expect(fenced_data == nil and fenced_read_code == "future_schema",
	"ordinary RecordStore reads did not fail closed on the quarantine sentinel")

local _, fenced_write_code = writer_record:TransactAsync(
	"quarantine-regression-forbidden-write",
	function(current)
		local updated = clone(current)
		updated.cash += 1000
		return updated
	end,
	{}
)
expect(fenced_write_code ~= "committed" and fenced_write_code ~= "duplicate",
	"RecordStore committed a profile transaction after the durable quarantine fence")
local after_forbidden_write = RecordStore.Mock.get_record_raw(
	"QuarantineFenceRegression", "global", "writer"
)
expect(type(after_forbidden_write) == "table"
	and type(after_forbidden_write.__recordstore_quarantine_fence_v1) == "table"
	and after_forbidden_write.__recordstore_quarantine_fence_v1.quarantine_id == "quarantine-writer-001",
	"failed writer recreated or replaced the durable quarantine fence")

local resolving_record = open_profile("QuarantineFenceRegression", "resolving")
local resolving_manifest = new_store()
local resolving_quarantine = quarantine(
	resolving_record, resolving_manifest, "quarantine-resolve-001", resolving_record:GetRevision()
)
expect(resolving_quarantine.code == "committed",
	"resolution profile quarantine did not commit: " .. tostring(resolving_quarantine.code))
local source_revision = resolving_quarantine.fence.SourceRevision
expect(type(source_revision) == "number", "quarantine result omitted the durable source revision")

resolving_manifest.fail_read_after_status = "release_pending"
RecordStore.Mock.set_update_commit_then_failures(1, "injected release-pending fence response loss after commit")
local interrupted_resolution = V2.ProfileDoctor.ResolveQuarantineAsync(
	resolving_record, resolving_manifest, "quarantine-resolve-001",
	"operator-2", "release after reconciliation", source_revision
)
expect(interrupted_resolution.code == "unknown" and interrupted_resolution.status == "release_pending",
	"manifest response loss did not stop resolution while keeping the same-key fence active: "
		.. tostring(interrupted_resolution.code))
local pending_raw = RecordStore.Mock.get_record_raw("QuarantineFenceRegression", "global", "resolving")
expect(type(pending_raw) == "table"
	and type(pending_raw.__recordstore_quarantine_fence_v1) == "table"
	and pending_raw.__recordstore_quarantine_fence_v1.phase == "release_pending",
	"interrupted resolution removed the fence before the audit manifest was confirmed")
local pending_status = V2.ProfileDoctor.GetQuarantineStatusAsync(resolving_record, resolving_manifest)
expect(pending_status.code == "success" and pending_status.status == "release_pending",
	"release-pending quarantine was not visible after recovery")
local pending_writer = V2.ProfileDoctor.CheckWritableAsync(resolving_record, resolving_manifest)
expect(pending_writer.allowed == false and pending_writer.code == "quarantined",
	"writer gate allowed mutation while quarantine release was pending")

local resumed_resolution = V2.ProfileDoctor.ResolveQuarantineAsync(
	resolving_record, resolving_manifest, "quarantine-resolve-001",
	"operator-2", "release after reconciliation", source_revision
)
expect(resumed_resolution.code == "committed" and resumed_resolution.status == "resolved",
	"same-resolution retry did not complete safely: " .. tostring(resumed_resolution.code))
local released_raw = RecordStore.Mock.get_record_raw("QuarantineFenceRegression", "global", "resolving")
expect(type(released_raw) == "table"
	and released_raw.__recordstore_quarantine_fence_v1 == nil
	and released_raw.implementation_version ~= 2147483646
	and type(released_raw.fencing_generation) == "number",
	"successful audited resolution did not release the durable same-key fence")
local resolved_writer = V2.ProfileDoctor.CheckWritableAsync(resolving_record, resolving_manifest)
expect(resolved_writer.code == "success" and resolved_writer.allowed == true
	and resolved_writer.status == "resolved",
	"resolved fence remained blocked after the confirmed release")
local duplicate_resolution = V2.ProfileDoctor.ResolveQuarantineAsync(
	resolving_record, resolving_manifest, "quarantine-resolve-001",
	"operator-2", "release after reconciliation", source_revision
)
expect(duplicate_resolution.code == "duplicate",
	"same resolution retry was not idempotent after release")

local recovery_record = open_profile("QuarantineFenceRegression", "identity-recovery")
local recovery_identity = {
	store_name = "QuarantineFenceRegression",
	scope = "global",
	profile_key = "identity-recovery",
}
local before_recovery_fence, before_recovery_code = RecordStore.Mock.get_quarantine_fence_status_async(
	recovery_identity.store_name, recovery_identity.scope, recovery_identity.profile_key
)
expect(before_recovery_code == "success" and before_recovery_fence ~= nil
	and before_recovery_fence.Quarantined == false,
	"identity-recovery profile did not expose its current durable revision/generation")
local orphaned_fence, orphaned_code = RecordStore.Mock.quarantine_profile_writes_async(
	recovery_identity.store_name, recovery_identity.scope, recovery_identity.profile_key,
	"quarantine-identity-recovery", "operator-3", "recover after server restart",
	before_recovery_fence.CurrentGeneration, before_recovery_fence.CurrentRevision
)
expect(orphaned_code == "success" and orphaned_fence ~= nil and orphaned_fence.Quarantined == true,
	"failed to create the simulated fence-before-manifest crash state")
local recovery_manifest_store = new_store()
local recovered_quarantine = V2.ProfileDoctor.QuarantineAsync(
	recovery_identity, recovery_manifest_store, "quarantine-identity-recovery",
	"operator-3", "recover after server restart", before_recovery_fence.CurrentRevision
)
expect(recovered_quarantine.code == "committed",
	"identity-only quarantine recovery did not repair the missing audit manifest: "
		.. tostring(recovered_quarantine.code))
local recovered_status = V2.ProfileDoctor.GetQuarantineStatusAsync(recovery_identity, recovery_manifest_store)
expect(recovered_status.code == "success" and recovered_status.status == "quarantined",
	"identity-only quarantine status failed after recovering an orphan fence")
local recovery_resolution = V2.ProfileDoctor.ResolveQuarantineAsync(
	recovery_identity, recovery_manifest_store, "quarantine-identity-recovery",
	"operator-3", "verified recovery after server restart", before_recovery_fence.CurrentRevision
)
expect(recovery_resolution.code == "committed" and recovery_resolution.status == "resolved",
	"identity-only resolution could not recover a durable quarantine after restart")
local recovered_writer = V2.ProfileDoctor.CheckWritableAsync(recovery_identity, recovery_manifest_store)
expect(recovered_writer.code == "success" and recovered_writer.allowed == true,
	"identity-only release remained blocked after confirmed audit and fence completion")

local pending_recovery_record = open_profile("QuarantineFenceRegression", "pending-recovery")
local pending_recovery_identity = {
	store_name = "QuarantineFenceRegression",
	scope = "global",
	profile_key = "pending-recovery",
}
local pending_initial, pending_initial_code = RecordStore.Mock.get_quarantine_fence_status_async(
	pending_recovery_identity.store_name, pending_recovery_identity.scope, pending_recovery_identity.profile_key
)
expect(pending_initial_code == "success" and pending_initial ~= nil
	and pending_initial.Quarantined == false,
	"pending-recovery fixture has no verified initial fence status")
local orphan_pending_id = "quarantine-orphan-release-pending"
local orphan_pending_operator = "operator-4"
local orphan_pending_reason = "recover release-pending fence after process restart"
local resolution_fingerprint = V2.Fingerprint({
	quarantine_id = orphan_pending_id,
	operator_id = orphan_pending_operator,
	reason = orphan_pending_reason,
	source_revision = pending_initial.CurrentRevision,
})
expect(type(resolution_fingerprint) == "string" and #resolution_fingerprint >= 48,
	"could not derive the stable quarantine resolution identity")
local orphan_pending_resolution_id = "qr-" .. string.sub(resolution_fingerprint, 1, 48)
local orphan_pending_fence, orphan_pending_code = RecordStore.Mock.quarantine_profile_writes_async(
	pending_recovery_identity.store_name, pending_recovery_identity.scope, pending_recovery_identity.profile_key,
	orphan_pending_id, orphan_pending_operator, orphan_pending_reason,
	pending_initial.CurrentGeneration, pending_initial.CurrentRevision
)
expect(orphan_pending_code == "success" and orphan_pending_fence ~= nil,
	"could not install the pre-resolution quarantine fence")
local orphan_pending_updated, orphan_pending_update_code = RecordStore.Mock.mark_quarantine_release_pending_async(
	pending_recovery_identity.store_name, pending_recovery_identity.scope, pending_recovery_identity.profile_key,
	orphan_pending_id, orphan_pending_resolution_id, orphan_pending_operator, orphan_pending_reason,
	pending_initial.CurrentRevision
)
expect(orphan_pending_update_code == "success" and orphan_pending_updated ~= nil
	and orphan_pending_updated.Phase == "release_pending",
	"could not simulate a process crash after the release-pending fence but before the audit update")
local orphan_pending_manifest_store = new_store()
local recovered_pending_resolution = V2.ProfileDoctor.ResolveQuarantineAsync(
	pending_recovery_identity, orphan_pending_manifest_store, orphan_pending_id,
	orphan_pending_operator, orphan_pending_reason, pending_initial.CurrentRevision
)
expect(recovered_pending_resolution.code == "committed"
	and recovered_pending_resolution.status == "resolved",
	"identity-only resolution failed to recover an orphan release-pending fence: "
		.. tostring(recovered_pending_resolution.code))
local orphan_pending_writer = V2.ProfileDoctor.CheckWritableAsync(
	pending_recovery_identity, orphan_pending_manifest_store
)
expect(orphan_pending_writer.code == "success" and orphan_pending_writer.allowed == true
	and orphan_pending_writer.status == "resolved",
	"recovered release-pending fence did not become writable after durable resolution")

local erase_record = open_profile("QuarantineFenceRegression", "erase-over-quarantine")
local erase_manifest = new_store()
local erase_quarantine = quarantine(
	erase_record, erase_manifest, "quarantine-before-erasure", erase_record:GetRevision()
)
expect(erase_quarantine.code == "committed", "erasure override fixture quarantine failed")
local erased, erase_code = RecordStore.Mock.erase_user_data_async(
	"QuarantineFenceRegression", "global", "erase-over-quarantine", 123456,
	"erase-over-quarantine-001", nil
)
expect(erase_code == "success" and erased ~= nil and erased.Erased == true,
	"permanent RTBF erasure could not supersede a valid quarantine fence: " .. tostring(erase_code))
local erased_raw = RecordStore.Mock.get_record_raw(
	"QuarantineFenceRegression", "global", "erase-over-quarantine"
)
expect(type(erased_raw) == "table"
	and erased_raw.implementation_version == 2147483647
	and type(erased_raw.__recordstore_erasure_fence) == "table"
	and erased_raw.__recordstore_quarantine_fence_v1 == nil,
	"permanent erasure fence did not take precedence over quarantine")

RecordStore.Mock.reset()
Shim.close()
