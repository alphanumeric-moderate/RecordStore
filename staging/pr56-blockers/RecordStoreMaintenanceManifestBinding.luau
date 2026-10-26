--!strict
local Binder = {}

export type FamilyPolicy = {
	family_name: string,
	is_eligible: (unknown, any, number, string) -> boolean,
	dependencies_clear: (unknown, any, number, string) -> boolean,
}

export type Runtime = {
	maintenance: any,
	maintenance_runner: any,
	policies: { FamilyPolicy },
	mode: string?,
	authorize: ((string) -> (boolean, string?))?,
	assert_fence: ((string) -> (boolean, string?))?,
	data_store_service: any?,
	instance_factory: ((string) -> Instance)?,
}

export type AttestationVerifier = (
	manifest: { [string]: any },
	families: { any }
) -> (boolean, string?)

local MAX_FAMILIES = 128
local MAX_NAME_BYTES = 50
local MAX_FIELD_BYTES = 128
local MAX_EVIDENCE_BYTES = 512
local MAX_JOB_ID_BYTES = 96
local MAX_REVISION_BYTES = 80
local MAX_INTEGER = 9007199254740991

local MANIFEST_FIELDS = {
	schema_version = true,
	kind = true,
	manifest_id = true,
	revision = true,
	source_commit = true,
	job_id = true,
	catalog_revision = true,
	review_status = true,
	reviewed_by = true,
	reviewed_at_unix = true,
	inventory_evidence_ref = true,
	policy_review_evidence_ref = true,
	fence_protocol_evidence_ref = true,
	checkpoint_protocol_evidence_ref = true,
	checkpoint_store_name = true,
	checkpoint_scope = true,
	checkpoint_key = true,
	families = true,
}

local FAMILY_FIELDS = {
	name = true,
	store_name = true,
	scope = true,
	prefix = true,
	generation_field = true,
	job_fence_field = true,
	tombstone_field = true,
	tombstone_job_field = true,
	tombstone_source_generation_field = true,
	action = true,
	inventory_evidence_ref = true,
	policy_evidence_ref = true,
}

local RUNTIME_FIELDS = {
	maintenance = true,
	maintenance_runner = true,
	policies = true,
	mode = true,
	authorize = true,
	assert_fence = true,
	data_store_service = true,
	instance_factory = true,
}

local POLICY_FIELDS = {
	family_name = true,
	is_eligible = true,
	dependencies_clear = true,
}

local function exact_fields(value: { [string]: any }, allowed: { [string]: boolean }): boolean
	for key in pairs(value) do
		if type(key) ~= "string" or allowed[key] ~= true then return false end
	end
	return true
end

local function text(value: unknown, maximum: number, allow_empty: boolean?): boolean
	return type(value) == "string"
		and (allow_empty == true or value ~= "")
		and #value <= maximum
		and string.find(value, "%c") == nil
end

local function positive_integer(value: unknown): boolean
	return type(value) == "number" and math.isfinite(value)
		and value >= 1 and value <= MAX_INTEGER and math.floor(value) == value
end

local function generation(value: unknown): boolean
	return type(value) == "number" and math.isfinite(value)
		and value >= 0 and value < MAX_INTEGER and math.floor(value) == value
end

local function timestamp(value: unknown): boolean
	return type(value) == "number" and math.isfinite(value) and value > 0
end

local function valid_commit(value: unknown): boolean
	if type(value) ~= "string" or #value ~= 40 then return false end
	for index = 1, #value do
		local byte = string.byte(value, index)
		if not ((byte >= 48 and byte <= 57)
			or (byte >= 97 and byte <= 102)
			or (byte >= 65 and byte <= 70)
		) then
			return false
		end
	end
	return true
end

local function dense_array(value: unknown, minimum: number, maximum: number): ({ any }?, string?)
	if type(value) ~= "table" then return nil, "expected a bounded dense array" end
	local rows = value :: { [any]: any }
	local length = #rows
	if length < minimum or length > maximum then
		return nil, "array entry count is outside the permitted bounds"
	end
	local count = 0
	for key in pairs(rows) do
		if type(key) ~= "number" or not math.isfinite(key)
			or math.floor(key) ~= key or key < 1 or key > length
		then
			return nil, "array must be dense and contain only numeric indices"
		end
		count += 1
	end
	if count ~= length then return nil, "array must be dense" end
	return rows, nil
end

local function freeze_family(raw: unknown): ({ [string]: any }?, string?)
	if type(raw) ~= "table" then return nil, "maintenance family must be a table" end
	local row = raw :: { [string]: any }
	if not exact_fields(row, FAMILY_FIELDS) then return nil, "maintenance family contains an unsupported field" end
	if not text(row.name, MAX_NAME_BYTES)
		or not text(row.store_name, MAX_NAME_BYTES)
		or not text(row.scope, MAX_NAME_BYTES, true)
		or not text(row.prefix, MAX_NAME_BYTES, true)
		or not text(row.generation_field, MAX_FIELD_BYTES)
		or not text(row.job_fence_field, MAX_FIELD_BYTES)
		or not text(row.tombstone_field, MAX_FIELD_BYTES)
		or not text(row.tombstone_job_field, MAX_FIELD_BYTES)
		or not text(row.tombstone_source_generation_field, MAX_FIELD_BYTES)
		or not text(row.inventory_evidence_ref, MAX_EVIDENCE_BYTES)
		or not text(row.policy_evidence_ref, MAX_EVIDENCE_BYTES)
	then
		return nil, "maintenance family identity, schema fields, or evidence reference is invalid"
	end
	if row.action ~= "tombstone" then return nil, "only durable tombstone actions are supported by this adapter" end
	local fields = {
		row.generation_field,
		row.job_fence_field,
		row.tombstone_field,
		row.tombstone_job_field,
		row.tombstone_source_generation_field,
	}
	local seen: { [string]: boolean } = {}
	for _, field in ipairs(fields) do
		if seen[field] then return nil, "generation, fence, and tombstone fields must all be distinct" end
		seen[field] = true
	end
	return table.freeze({
		name = row.name,
		store_name = row.store_name,
		scope = row.scope,
		prefix = row.prefix,
		generation_field = row.generation_field,
		job_fence_field = row.job_fence_field,
		tombstone_field = row.tombstone_field,
		tombstone_job_field = row.tombstone_job_field,
		tombstone_source_generation_field = row.tombstone_source_generation_field,
		action = "tombstone",
		inventory_evidence_ref = row.inventory_evidence_ref,
		policy_evidence_ref = row.policy_evidence_ref,
	}), nil
end

local function validate_manifest(raw: unknown): ({ [string]: any }?, string?)
	if type(raw) ~= "table" then return nil, "maintenance manifest must be a table" end
	local value = raw :: { [string]: any }
	if not exact_fields(value, MANIFEST_FIELDS) then return nil, "maintenance manifest contains an unsupported field" end
	if value.schema_version ~= 1 or value.kind ~= "maintenance_job"
		or not text(value.manifest_id, 128)
		or not text(value.revision, 128)
		or not valid_commit(value.source_commit)
		or not text(value.job_id, MAX_JOB_ID_BYTES)
		or not text(value.catalog_revision, MAX_REVISION_BYTES)
		or string.find(value.catalog_revision, "|", 1, true) ~= nil
	then
		return nil, "maintenance manifest identity, job ID, catalog revision, or source commit is invalid"
	end
	if value.review_status ~= "approved" or not text(value.reviewed_by, 128)
		or not timestamp(value.reviewed_at_unix)
	then
		return nil, "maintenance manifest lacks independent review metadata"
	end
	for _, field in ipairs({
		"inventory_evidence_ref",
		"policy_review_evidence_ref",
		"fence_protocol_evidence_ref",
		"checkpoint_protocol_evidence_ref",
	}) do
		if not text(value[field], MAX_EVIDENCE_BYTES) then
			return nil, "maintenance manifest is missing " .. field
		end
	end
	if not text(value.checkpoint_store_name, MAX_NAME_BYTES)
		or not text(value.checkpoint_scope, MAX_NAME_BYTES, true)
		or not text(value.checkpoint_key, MAX_NAME_BYTES)
	then
		return nil, "maintenance checkpoint store, scope, or key is invalid"
	end
	local raw_families, family_array_error = dense_array(value.families, 1, MAX_FAMILIES)
	if raw_families == nil then return nil, "families: " .. tostring(family_array_error) end
	local families: { any } = {}
	local names: { [string]: boolean } = {}
	for _, raw_family in ipairs(raw_families) do
		local family, family_error = freeze_family(raw_family)
		if family == nil then return nil, family_error end
		if names[family.name] then return nil, "maintenance family names must be unique" end
		names[family.name] = true
		for _, prior in ipairs(families) do
			if family.store_name == prior.store_name and family.scope == prior.scope then
				local left = family.prefix
				local right = prior.prefix
				if left == "" or right == ""
					or string.sub(left, 1, #right) == right
					or string.sub(right, 1, #left) == left
				then
					return nil, "maintenance family prefixes overlap within one store and scope"
				end
			end
		end
		if family.store_name == value.checkpoint_store_name and family.scope == value.checkpoint_scope then
			return nil, "checkpoint store and scope must be separate from every target family"
		end
		families[#families + 1] = family
	end
	return table.freeze({
		schema_version = 1,
		kind = "maintenance_job",
		manifest_id = value.manifest_id,
		revision = value.revision,
		source_commit = value.source_commit,
		job_id = value.job_id,
		catalog_revision = value.catalog_revision,
		review_status = value.review_status,
		reviewed_by = value.reviewed_by,
		reviewed_at_unix = value.reviewed_at_unix,
		inventory_evidence_ref = value.inventory_evidence_ref,
		policy_review_evidence_ref = value.policy_review_evidence_ref,
		fence_protocol_evidence_ref = value.fence_protocol_evidence_ref,
		checkpoint_protocol_evidence_ref = value.checkpoint_protocol_evidence_ref,
		checkpoint_store_name = value.checkpoint_store_name,
		checkpoint_scope = value.checkpoint_scope,
		checkpoint_key = value.checkpoint_key,
		families = table.freeze(families),
	}), nil
end

local function clone(value: unknown, seen: { [any]: any }?): any
	if type(value) ~= "table" then return value end
	local source = value :: { [any]: any }
	local memo = seen or {}
	if memo[source] ~= nil then return memo[source] end
	local copy_value: { [any]: any } = {}
	memo[source] = copy_value
	for key, child in pairs(source) do
		copy_value[clone(key, memo)] = clone(child, memo)
	end
	return copy_value
end

local function invoke_non_yielding(callback: (...any) -> any, ...: any): (boolean, any, string?)
	local args = table.pack(...)
	local returned: { [number]: any }? = nil
	local thread = coroutine.create(function()
		returned = table.pack(pcall(callback, table.unpack(args, 1, args.n)))
	end)
	local resumed, resume_error = coroutine.resume(thread)
	if not resumed then return false, nil, tostring(resume_error) end
	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		return false, nil, "maintenance family policy callbacks must not yield"
	end
	local result = returned
	if result == nil then return false, nil, "maintenance callback did not return" end
	if result[1] ~= true then return false, nil, tostring(result[2]) end
	return true, result[2], nil
end

local function policy_boolean(
	callback: (...any) -> any,
	value: unknown,
	key_info: any,
	expected_generation: number,
	job_id: string
): (boolean, string?)
	local ok, allowed, message = invoke_non_yielding(
		callback, clone(value), key_info, expected_generation, job_id
	)
	if not ok then return false, message end
	if type(allowed) ~= "boolean" then return false, "maintenance policy callback did not return a boolean" end
	return allowed, if type(message) == "string" then message else nil
end

function Binder.bind(
	raw_manifest: unknown,
	raw_runtime: unknown,
	verify_attestation: AttestationVerifier
): ({ [string]: any }?, { [string]: any }?, string?)
	local manifest, manifest_error = validate_manifest(raw_manifest)
	if manifest == nil then return nil, nil, manifest_error end
	if type(raw_runtime) ~= "table" then return nil, nil, "maintenance runtime options must be a table" end
	local runtime = raw_runtime :: { [string]: any }
	if not exact_fields(runtime, RUNTIME_FIELDS) then return nil, nil, "maintenance runtime options contain unsupported fields" end
	if type(runtime.maintenance) ~= "table" or type(runtime.maintenance.NewCompactor) ~= "function"
		or type(runtime.maintenance_runner) ~= "table" or type(runtime.maintenance_runner.new) ~= "function"
	then
		return nil, nil, "RecordStoreV2 maintenance and maintenance runner APIs are required"
	end
	if runtime.mode ~= nil and runtime.mode ~= "dry_run" and runtime.mode ~= "execute" then
		return nil, nil, "maintenance mode must be dry_run or execute"
	end
	if runtime.mode == "execute" and (type(runtime.authorize) ~= "function" or type(runtime.assert_fence) ~= "function") then
		return nil, nil, "execute mode requires authorization and a durable job-fence preflight"
	end
	if runtime.data_store_service ~= nil and type(runtime.data_store_service) ~= "table" then
		return nil, nil, "data_store_service must be a table"
	end
	if runtime.instance_factory ~= nil and type(runtime.instance_factory) ~= "function" then
		return nil, nil, "instance_factory must be a function"
	end
	local policies, policies_error = dense_array(runtime.policies, MAX_FAMILIES)
	if policies == nil or #policies ~= #manifest.families then
		return nil, nil, policies_error or "provide exactly one policy binding for every maintenance family"
	end
	local policy_by_name: { [string]: any } = {}
	for _, raw_policy in ipairs(policies) do
		if type(raw_policy) ~= "table" then return nil, nil, "family policy must be a table" end
		local policy = raw_policy :: { [string]: any }
		if not exact_fields(policy, POLICY_FIELDS)
			or not text(policy.family_name, MAX_NAME_BYTES)
			or type(policy.is_eligible) ~= "function"
			or type(policy.dependencies_clear) ~= "function"
		then
			return nil, nil, "family policy needs a family name, eligibility callback, and dependency callback"
		end
		if policy_by_name[policy.family_name] ~= nil then return nil, nil, "family policy names must be unique" end
		policy_by_name[policy.family_name] = policy
	end
	for _, family in ipairs(manifest.families) do
		if policy_by_name[family.name] == nil then return nil, nil, "maintenance family has no matching application policy" end
	end
	if type(verify_attestation) ~= "function" then return nil, nil, "independent maintenance manifest verifier is required" end

	local bound_families: { any } = {}
	for _, family in ipairs(manifest.families) do
		local policy = policy_by_name[family.name]
		local function read_generation(value: unknown): number?
			if type(value) ~= "table" then return nil end
			local candidate = (value :: { [string]: unknown })[family.generation_field]
			return if generation(candidate) then candidate else nil
		end
		local function inspect(key: string, value: unknown, key_info: any): ({ [string]: any }?, string?)
			if type(value) ~= "table" then return nil, "record is not a table" end
			local row = value :: { [string]: any }
			local observed_generation = read_generation(row)
			if observed_generation == nil then return nil, "record has no valid generation" end
			if row[family.tombstone_field] == true then
				return {
					status = "success",
					eligible = false,
					dependencies_clear = true,
					generation = observed_generation,
					message = nil,
				}, nil
			end
			if row[family.job_fence_field] ~= manifest.job_id then
				return {
					status = "success",
					eligible = false,
					dependencies_clear = false,
					generation = observed_generation,
					message = "same-key maintenance job fence is not installed",
				}, nil
			end
			local eligible, eligibility_error = policy_boolean(
				policy.is_eligible, row, key_info, observed_generation, manifest.job_id
			)
			local clear, dependency_error = policy_boolean(
				policy.dependencies_clear, row, key_info, observed_generation, manifest.job_id
			)
			if eligibility_error ~= nil or dependency_error ~= nil then
				return nil, eligibility_error or dependency_error
			end
			return {
				status = "success",
				eligible = eligible,
				dependencies_clear = clear,
				generation = observed_generation,
				message = nil,
			}, nil
		end
		local function can_delete(value: unknown, key_info: any, expected_generation: number, job_id: string): boolean
			if job_id ~= manifest.job_id or not generation(expected_generation) or type(value) ~= "table" then return false end
			local row = value :: { [string]: any }
			if read_generation(row) ~= expected_generation
				or row[family.job_fence_field] ~= manifest.job_id
				or row[family.tombstone_field] == true
			then
				return false
			end
			local eligible = policy_boolean(policy.is_eligible, row, key_info, expected_generation, job_id)
			if not eligible then return false end
			local clear = policy_boolean(policy.dependencies_clear, row, key_info, expected_generation, job_id)
			return clear
		end
		local function make_tombstone(value: unknown, _key_info: any, expected_generation: number, job_id: string): unknown?
			if job_id ~= manifest.job_id or not generation(expected_generation) or expected_generation >= MAX_INTEGER
				or type(value) ~= "table"
			then
				return nil
			end
			local row = value :: { [string]: any }
			if read_generation(row) ~= expected_generation
				or row[family.job_fence_field] ~= manifest.job_id
				or row[family.tombstone_field] == true
			then
				return nil
			end
			local result = clone(row) :: { [string]: any }
			result[family.generation_field] = expected_generation + 1
			result[family.job_fence_field] = manifest.job_id
			result[family.tombstone_field] = true
			result[family.tombstone_job_field] = manifest.job_id
			result[family.tombstone_source_generation_field] = expected_generation
			return result
		end
		local function is_tombstone(value: unknown, expected_generation: number, job_id: string): boolean
			if job_id ~= manifest.job_id or not generation(expected_generation) or type(value) ~= "table" then return false end
			local row = value :: { [string]: any }
			return row[family.tombstone_field] == true
				and row[family.tombstone_job_field] == manifest.job_id
				and row[family.tombstone_source_generation_field] == expected_generation
				and read_generation(row) == expected_generation + 1
				and row[family.job_fence_field] == manifest.job_id
		end
		bound_families[#bound_families + 1] = table.freeze({
			name = family.name,
			store_name = family.store_name,
			scope = family.scope,
			prefix = family.prefix,
			get_generation = function(value: unknown, _key_info: any): number?
				return read_generation(value)
			end,
			inspect = inspect,
			can_delete = can_delete,
			make_tombstone = make_tombstone,
			is_tombstone = is_tombstone,
		})
	end
	table.freeze(bound_families)
	local ok, accepted, message = pcall(verify_attestation, manifest, bound_families)
	if not ok then return nil, nil, "maintenance manifest verifier failed: " .. tostring(accepted) end
	if accepted ~= true then return nil, nil, tostring(message or "maintenance manifest was not independently accepted") end
	local config: { [string]: any } = {
		job_id = manifest.job_id,
		catalog_revision = manifest.catalog_revision,
		families = bound_families,
		checkpoint_store_name = manifest.checkpoint_store_name,
		checkpoint_scope = manifest.checkpoint_scope,
		checkpoint_key = manifest.checkpoint_key,
		maintenance = runtime.maintenance,
		maintenance_runner = runtime.maintenance_runner,
		mode = runtime.mode or "dry_run",
	}
	if runtime.authorize ~= nil then config.authorize = runtime.authorize end
	if runtime.assert_fence ~= nil then config.assert_fence = runtime.assert_fence end
	if runtime.data_store_service ~= nil then config.data_store_service = runtime.data_store_service end
	if runtime.instance_factory ~= nil then config.instance_factory = runtime.instance_factory end
	return table.freeze(config), manifest, nil
end

return Binder
