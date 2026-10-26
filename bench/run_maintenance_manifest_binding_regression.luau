--!nocheck
local Shim = require("./RobloxShim")
local initializer = Shim.environment.game:GetService("ServerScriptService"):WaitForChild("PlayerDataInitializer")
local Binder = Shim.environment.require(initializer:WaitForChild("RecordStoreMaintenanceManifestBinding"))

local function expect(value, message)
	if not value then error(message, 2) end
end

local function clone(value, seen)
	if type(value) ~= "table" then return value end
	local memo = seen or {}
	if memo[value] ~= nil then return memo[value] end
	local copy_value = {}
	memo[value] = copy_value
	for key, child in pairs(value) do copy_value[clone(key, memo)] = clone(child, memo) end
	return copy_value
end

local now = 1792951000

local function manifest()
	return {
		schema_version = 1,
		kind = "maintenance_job",
		manifest_id = "maintenance-inventory-regression-r1",
		revision = "maintenance-review-r1",
		source_commit = string.rep("a", 40),
		job_id = "maintenance-job-regression-r1",
		catalog_revision = "catalog-regression-r1",
		review_status = "approved",
		reviewed_by = "independent-reviewer",
		reviewed_at_unix = now,
		inventory_evidence_ref = "evidence:maintenance-inventory",
		policy_review_evidence_ref = "evidence:maintenance-policy",
		fence_protocol_evidence_ref = "evidence:maintenance-fence",
		checkpoint_protocol_evidence_ref = "evidence:maintenance-checkpoint",
		checkpoint_store_name = "MaintenanceCheckpoints",
		checkpoint_scope = "global",
		checkpoint_key = "maintenance-job-regression-r1",
		families = {
			{
				name = "player-profiles",
				store_name = "Profiles",
				scope = "global",
				prefix = "Player_",
				generation_field = "fencing_generation",
				job_fence_field = "maintenance_fence_job_id",
				tombstone_field = "maintenance_tombstone",
				tombstone_job_field = "maintenance_tombstone_job_id",
				tombstone_source_generation_field = "maintenance_tombstone_source_generation",
				action = "tombstone",
				inventory_evidence_ref = "evidence:profiles-inventory",
				policy_evidence_ref = "evidence:profiles-policy",
			},
		},
	}
end

local function runtime(overrides)
	local policy = {
		family_name = "player-profiles",
		is_eligible = function(value)
			value.payload.mutated_by_policy = true
			return value.eligible == true
		end,
		dependencies_clear = function(value)
			return value.payload.token == "keep" and value.dependencies_clear == true
		end,
	}
	local value = {
		maintenance = { NewCompactor = function() return {} end },
		maintenance_runner = { new = function() return {} end },
		policies = { policy },
		mode = "dry_run",
	}
	for key, child in pairs(overrides or {}) do value[key] = child end
	return value, policy
end

local function verify_ok(manifest_value, families)
	return manifest_value.job_id == "maintenance-job-regression-r1"
		and #families == 1 and table.isfrozen(families) and table.isfrozen(families[1]),
		"maintenance attestation did not reconcile the frozen family catalog"
end

local raw_manifest = manifest()
local bound_runtime, policy = runtime()
local verifier_calls = 0
local config, normalized, bind_error = Binder.bind(raw_manifest, bound_runtime, function(value, families)
	verifier_calls += 1
	return verify_ok(value, families)
end)
expect(config ~= nil and normalized ~= nil, bind_error or "reviewed maintenance manifest did not bind")
expect(normalized.manifest_id == raw_manifest.manifest_id
	and config.job_id == normalized.job_id
	and config.catalog_revision == normalized.catalog_revision
	and config.mode == "dry_run" and #config.families == 1 and verifier_calls == 1,
	"bound maintenance config did not preserve reviewed identity and dry-run default")
expect(table.isfrozen(config) and table.isfrozen(config.families),
	"bound maintenance config or family list is mutable")
expect(table.isfrozen(normalized) and table.isfrozen(normalized.families),
	"normalized manifest or family list is mutable")

raw_manifest.families[1].prefix = "Changed_"
bound_runtime.policies[1].family_name = "changed-policy"
expect(normalized.families[1].prefix == "Player_"
	and config.families[1].prefix == "Player_"
	and config.families[1].name == "player-profiles",
	"bound callbacks retained mutable caller-owned manifest or policy data")

local family = config.families[1]
local row = {
	fencing_generation = 4,
	maintenance_fence_job_id = "maintenance-job-regression-r1",
	eligible = true,
	dependencies_clear = true,
	payload = { token = "keep" },
}
local inspection, inspect_error = family.inspect("Player_1001", row, nil)
expect(inspection ~= nil and inspect_error == nil and inspection.status == "success"
	and inspection.eligible == true and inspection.dependencies_clear == true
	and inspection.generation == 4,
	inspect_error or "eligible and dependency-free profile did not inspect successfully")
expect(row.payload.mutated_by_policy == nil and row.payload.token == "keep",
	"policy callback mutated the input record during inspection")
expect(family.can_delete(row, nil, 4, "maintenance-job-regression-r1"),
	"same-generation, same-job-fenced eligible record was refused")

local tombstone = family.make_tombstone(row, nil, 4, "maintenance-job-regression-r1")
expect(type(tombstone) == "table"
	and tombstone.fencing_generation == 5
	and tombstone.maintenance_fence_job_id == "maintenance-job-regression-r1"
	and tombstone.maintenance_tombstone == true
	and tombstone.maintenance_tombstone_job_id == "maintenance-job-regression-r1"
	and tombstone.maintenance_tombstone_source_generation == 4
	and tombstone.payload.token == "keep",
	"bound tombstone did not advance generation and preserve record payload")
expect(family.is_tombstone(tombstone, 4, "maintenance-job-regression-r1"),
	"bound tombstone did not validate its exact source generation and job identity")
expect(not family.can_delete(tombstone, nil, 5, "maintenance-job-regression-r1"),
	"already tombstoned row was accepted for another tombstone")

local stale = clone(row)
expect(not family.can_delete(stale, nil, 3, "maintenance-job-regression-r1"),
	"stale expected generation bypassed the same-mutation check")
local foreign = clone(row)
foreign.maintenance_fence_job_id = "another-job"
expect(not family.can_delete(foreign, nil, 4, "maintenance-job-regression-r1"),
	"foreign job fence was accepted")
local ineligible = clone(row)
ineligible.eligible = false
expect(not family.can_delete(ineligible, nil, 4, "maintenance-job-regression-r1"),
	"ineligible record passed the application policy")
local dependent = clone(row)
dependent.dependencies_clear = false
expect(not family.can_delete(dependent, nil, 4, "maintenance-job-regression-r1"),
	"record with unresolved dependencies passed the application policy")
local unfenced = clone(row)
unfenced.maintenance_fence_job_id = nil
local unfenced_inspection = family.inspect("Player_1001", unfenced, nil)
expect(unfenced_inspection ~= nil and unfenced_inspection.eligible == false
	and unfenced_inspection.dependencies_clear == false,
	"inspection did not fail closed for a missing same-key job fence")

local rejected_calls = 0
local rejected_config = Binder.bind(manifest(), runtime(), function()
	rejected_calls += 1
	return false, "independent reconciliation failed"
end)
expect(rejected_config == nil and rejected_calls == 1,
	"manifest was accepted despite independent attestation rejection")

local verifier_called_for_missing_policy = false
local no_policy = Binder.bind(manifest(), runtime({ policies = {} }), function()
	verifier_called_for_missing_policy = true
	return true
end)
expect(no_policy == nil and not verifier_called_for_missing_policy,
	"missing application policy reached the independent attestation gate")

local malformed = manifest()
malformed.unreviewed_override = true
expect(Binder.bind(malformed, runtime(), function() return true end) == nil,
	"unsupported manifest fields were accepted")
malformed = manifest()
malformed.source_commit = "not-a-commit"
expect(Binder.bind(malformed, runtime(), function() return true end) == nil,
	"invalid source commit was accepted")
malformed = manifest()
malformed.families[1].action = "physical_delete"
expect(Binder.bind(malformed, runtime(), function() return true end) == nil,
	"physical deletion was accepted rather than durable tombstoning")
malformed = manifest()
malformed.families[1].job_fence_field = malformed.families[1].generation_field
expect(Binder.bind(malformed, runtime(), function() return true end) == nil,
	"overlapping generation and job-fence fields were accepted")
malformed = manifest()
malformed.checkpoint_store_name = "Profiles"
malformed.checkpoint_scope = "global"
expect(Binder.bind(malformed, runtime(), function() return true end) == nil,
	"checkpoint store overlapping target store/scope was accepted")

local overlapping = manifest()
overlapping.families[2] = clone(overlapping.families[1])
overlapping.families[2].name = "overlapping-family"
overlapping.families[2].prefix = "Player_Archive_"
overlapping.families[2].inventory_evidence_ref = "evidence:second-inventory"
overlapping.families[2].policy_evidence_ref = "evidence:second-policy"
local overlap_attestation_called = false
expect(Binder.bind(overlapping, runtime({ policies = {
	policy,
	{
		family_name = "overlapping-family",
		is_eligible = function() return true end,
		dependencies_clear = function() return true end,
	},
} }), function()
	overlap_attestation_called = true
	return true
end) == nil and not overlap_attestation_called,
	"overlapping same-store prefixes reached independent attestation")

local bad_exec = Binder.bind(manifest(), runtime({ mode = "execute" }), function() return true end)
expect(bad_exec == nil,
	"execute mode was enabled without authorization and durable fence preflight")
local authorized_exec = Binder.bind(manifest(), runtime({
	mode = "execute",
	authorize = function() return true end,
	assert_fence = function() return true end,
}), function() return true end)
expect(authorized_exec ~= nil, "execute mode rejected explicit authorization and fence callbacks")

local yielding_runtime, _ = runtime({ policies = {{
	family_name = "player-profiles",
	is_eligible = function()
		coroutine.yield()
		return true
	end,
	dependencies_clear = function() return true end,
}} })
local yielding_config = Binder.bind(manifest(), yielding_runtime, function() return true end)
expect(yielding_config ~= nil, "valid callback with runtime failure could not bind")
local yielding_inspection = yielding_config.families[1].inspect("Player_1001", row, nil)
expect(yielding_inspection == nil,
	"yielding application policy produced an actionable maintenance inspection")

print("[MaintenanceManifestBinding] immutable manifest, policy binding, eligibility/dependency checks, tombstone schema, attestation gates, and fail-closed execute mode regressions passed")
