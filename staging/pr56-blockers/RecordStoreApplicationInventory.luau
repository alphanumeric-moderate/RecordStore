--!strict
local Manifest = {}

local MAX_FAMILIES = 128
local MAX_WRITERS = 512
local MAX_ID_BYTES = 128
local MAX_EVIDENCE_BYTES = 512
local MAX_NAME_BYTES = 50
local MAX_ROBLOX_USER_ID = "9007199254740991"
local HEX = "0123456789abcdef"

local TOP_FIELDS = {
	schema_version = true,
	kind = true,
	manifest_id = true,
	revision = true,
	source_commit = true,
	review_status = true,
	reviewed_by = true,
	reviewed_at_unix = true,
	inventory_complete = true,
	inventory_evidence_ref = true,
	writer_audit_complete = true,
	writer_audit_evidence_ref = true,
	review_attestation_ref = true,
	live_acceptance_complete = true,
	live_acceptance_evidence_ref = true,
	families = true,
	writers = true,
}

local FAMILY_FIELDS = {
	id = true,
	store_name = true,
	scope = true,
	locator_mode = true,
	key_template = true,
	inventory_source_ref = true,
	generation_field = true,
	fence_field = true,
	action = true,
	writer_ids = true,
	evidence_ref = true,
}

local WRITER_FIELDS = {
	id = true,
	source_path = true,
	family_ids = true,
	fence_mode = true,
	fence_evidence_ref = true,
	retired_source_commit = true,
}

local function valid_text(value: unknown, maximum: number): boolean
	return type(value) == "string" and value ~= "" and #value <= maximum
		and string.find(value, "%c") == nil
end

local function positive_timestamp(value: unknown): boolean
	return type(value) == "number" and math.isfinite(value) and value > 0
end

local function valid_commit(value: unknown): boolean
	if type(value) ~= "string" or value == "" or #value ~= 40
		or string.find(value, "%c") ~= nil
	then
		return false
	end
	for index = 1, #value do
		if string.find(HEX, string.sub(value, index, index), 1, true) == nil then
			return false
		end
	end
	return true
end

local function exact_fields(value: { [string]: any }, allowed: { [string]: boolean }): boolean
	for key in pairs(value) do
		if type(key) ~= "string" or allowed[key] ~= true then return false end
	end
	return true
end

local function dense_array(value: unknown, minimum: number, maximum: number): boolean
	if type(value) ~= "table" then return false end
	local rows = value :: { [any]: any }
	local length = #rows
	if length < minimum or length > maximum then return false end
	local count = 0
	for key in pairs(rows) do
		if type(key) ~= "number" or not math.isfinite(key)
			or math.floor(key) ~= key or key < 1 or key > length
		then
			return false
		end
		count += 1
	end
	return count == length
end

local function valid_id_list(value: unknown, minimum: number, maximum: number): ({ string }?, string?)
	if not dense_array(value, minimum, maximum) then return nil, "relationship list is not a dense bounded array" end
	local rows = value :: { any }
	local copied: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, item in ipairs(rows) do
		if not valid_text(item, MAX_ID_BYTES) then return nil, "relationship list contains an invalid ID" end
		local id = item :: string
		if seen[id] then return nil, "relationship list contains a duplicate ID" end
		seen[id] = true
		copied[#copied + 1] = id
	end
	return copied, nil
end

local function normalize_family(raw: unknown): ({ [string]: any }?, string?)
	if type(raw) ~= "table" then return nil, "family is not a table" end
	local row = raw :: { [string]: any }
	if not exact_fields(row, FAMILY_FIELDS) then return nil, "family contains an unsupported field" end
	if not valid_text(row.id, MAX_ID_BYTES)
		or not valid_text(row.store_name, MAX_NAME_BYTES)
		or type(row.scope) ~= "string" or #row.scope > MAX_NAME_BYTES
		or string.find(row.scope, "%c") ~= nil
		or not valid_text(row.generation_field, MAX_ID_BYTES)
		or not valid_text(row.fence_field, MAX_ID_BYTES)
		or not valid_text(row.evidence_ref, MAX_EVIDENCE_BYTES)
	then
		return nil, "family identity, schema path, or evidence reference is invalid"
	end
	if row.action ~= "tombstone" and row.action ~= "redact" and row.action ~= "retain_fence" then
		return nil, "family action is not supported"
	end
	local locator_mode = row.locator_mode
	if locator_mode == "user_id_template" then
		if not valid_text(row.key_template, MAX_NAME_BYTES) then
			return nil, "user ID key template must be 1 to 50 bytes"
		end
		local key_template = row.key_template :: string
		if select(2, string.gsub(key_template, "{user_id}", "")) ~= 1 then
			return nil, "user ID key templates must contain exactly one {user_id} placeholder"
		end
		local max_key = string.gsub(key_template, "{user_id}", MAX_ROBLOX_USER_ID)
		if #max_key > MAX_NAME_BYTES then
			return nil, "expanded user ID key template exceeds Roblox's 50-byte key bound"
		end
		if row.inventory_source_ref ~= nil then return nil, "template locator must not include an external inventory source" end
	elseif locator_mode == "external_inventory" then
		if row.key_template ~= nil or not valid_text(row.inventory_source_ref, MAX_EVIDENCE_BYTES) then
			return nil, "external inventory locators require an inventory evidence reference and no guessed key template"
		end
	else
		return nil, "family locator mode is unsupported"
	end
	local writer_ids, writer_error = valid_id_list(row.writer_ids, 1, MAX_WRITERS)
	if writer_ids == nil then return nil, writer_error end
	local family: { [string]: any } = {
		id = row.id,
		store_name = row.store_name,
		scope = row.scope,
		locator_mode = locator_mode,
		key_template = row.key_template,
		generation_field = row.generation_field,
		fence_field = row.fence_field,
		action = row.action,
		writer_ids = table.freeze(writer_ids),
		evidence_ref = row.evidence_ref,
	}
	if row.inventory_source_ref ~= nil then family.inventory_source_ref = row.inventory_source_ref end
	return table.freeze(family), nil
end

local function normalize_writer(raw: unknown): ({ [string]: any }?, string?)
	if type(raw) ~= "table" then return nil, "writer is not a table" end
	local row = raw :: { [string]: any }
	if not exact_fields(row, WRITER_FIELDS) then return nil, "writer contains an unsupported field" end
	if not valid_text(row.id, MAX_ID_BYTES)
		or not valid_text(row.source_path, 256)
		or not valid_text(row.fence_evidence_ref, MAX_EVIDENCE_BYTES)
	then
		return nil, "writer identity, source path, or fence evidence reference is invalid"
	end
	local family_ids, family_error = valid_id_list(row.family_ids, 1, MAX_FAMILIES)
	if family_ids == nil then return nil, family_error end
	if row.fence_mode == "same_key_update_async" then
		if row.retired_source_commit ~= nil then return nil, "active writer cannot declare a retirement commit" end
	elseif row.fence_mode == "disabled_and_drained" then
		if not valid_commit(row.retired_source_commit) then
			return nil, "disabled writer requires a 40-character retirement commit"
		end
	else
		return nil, "writer fence mode must be same_key_update_async or disabled_and_drained"
	end
	local writer = {
		id = row.id,
		source_path = row.source_path,
		family_ids = table.freeze(family_ids),
		fence_mode = row.fence_mode,
		fence_evidence_ref = row.fence_evidence_ref,
	}
	if row.retired_source_commit ~= nil then writer.retired_source_commit = row.retired_source_commit end
	return table.freeze(writer), nil
end

function Manifest.validate(raw: unknown): ({ [string]: any }?, string?)
	if type(raw) ~= "table" then return nil, "manifest must be a table" end
	local value = raw :: { [string]: any }
	if not exact_fields(value, TOP_FIELDS) then return nil, "manifest contains an unsupported field" end
	if value.schema_version ~= 1 or value.kind ~= "rtbf"
		or not valid_text(value.manifest_id, MAX_ID_BYTES)
		or not valid_text(value.revision, MAX_ID_BYTES)
		or not valid_commit(value.source_commit)
	then
		return nil, "manifest identity, schema version, or source commit is invalid"
	end
	if value.review_status ~= "approved" or not valid_text(value.reviewed_by, MAX_ID_BYTES)
		or not positive_timestamp(value.reviewed_at_unix)
	then
		return nil, "manifest has no recorded independent review"
	end
	if value.inventory_complete ~= true
		or not valid_text(value.inventory_evidence_ref, MAX_EVIDENCE_BYTES)
	then
		return nil, "manifest does not provide a complete bounded inventory and evidence reference"
	end
	if value.writer_audit_complete ~= true
		or not valid_text(value.writer_audit_evidence_ref, MAX_EVIDENCE_BYTES)
		or not valid_text(value.review_attestation_ref, MAX_EVIDENCE_BYTES)
	then
		return nil, "manifest does not provide a complete writer audit and review attestation"
	end
	if type(value.live_acceptance_complete) ~= "boolean" then
		return nil, "live_acceptance_complete must be explicit"
	end
	if value.live_acceptance_complete then
		if not valid_text(value.live_acceptance_evidence_ref, MAX_EVIDENCE_BYTES) then
			return nil, "completed live acceptance requires an evidence reference"
		end
	elseif value.live_acceptance_evidence_ref ~= nil then
		return nil, "incomplete live acceptance must not claim completed evidence"
	end
	if not dense_array(value.families, 1, MAX_FAMILIES) then
		return nil, "manifest must declare 1 to 128 key families"
	end
	if not dense_array(value.writers, 1, MAX_WRITERS) then
		return nil, "manifest must declare 1 to 512 writer or recreation paths"
	end
	local families: { any } = {}
	local family_by_id: { [string]: any } = {}
	local locator_by_identity: { [string]: boolean } = {}
	for _, raw_family in ipairs(value.families) do
		local family, family_error = normalize_family(raw_family)
		if family == nil then return nil, family_error end
		if family_by_id[family.id] ~= nil then return nil, "manifest contains a duplicate family ID" end
		local locator_key = if family.locator_mode == "user_id_template"
			then family.key_template
			else "external:" .. family.inventory_source_ref
		local locator = family.store_name .. "\0" .. family.scope .. "\0" .. locator_key
		if locator_by_identity[locator] then return nil, "manifest contains duplicate key-family locators" end
		locator_by_identity[locator] = true
		family_by_id[family.id] = family
		families[#families + 1] = family
	end
	local writers: { any } = {}
	local writer_by_id: { [string]: any } = {}
	for _, raw_writer in ipairs(value.writers) do
		local writer, writer_error = normalize_writer(raw_writer)
		if writer == nil then return nil, writer_error end
		if writer_by_id[writer.id] ~= nil then return nil, "manifest contains a duplicate writer ID" end
		for _, family_id in ipairs(writer.family_ids) do
			if family_by_id[family_id] == nil then
				return nil, "writer references a family absent from the reviewed manifest"
			end
		end
		writer_by_id[writer.id] = writer
		writers[#writers + 1] = writer
	end
	for _, family in ipairs(families) do
		for _, writer_id in ipairs(family.writer_ids) do
			local writer = writer_by_id[writer_id]
			if writer == nil then return nil, "family references a writer absent from the reviewed manifest" end
			if not table.find(writer.family_ids, family.id) then
				return nil, "family and writer inventories do not have reciprocal coverage"
			end
		end
	end
	for _, writer in ipairs(writers) do
		for _, family_id in ipairs(writer.family_ids) do
			local family = family_by_id[family_id]
			if not table.find(family.writer_ids, writer.id) then
				return nil, "writer and family inventories do not have reciprocal coverage"
			end
		end
	end
	local normalized: { [string]: any } = {
		schema_version = 1,
		kind = "rtbf",
		manifest_id = value.manifest_id,
		revision = value.revision,
		source_commit = value.source_commit,
		review_status = value.review_status,
		reviewed_by = value.reviewed_by,
		reviewed_at_unix = value.reviewed_at_unix,
		inventory_complete = true,
		inventory_evidence_ref = value.inventory_evidence_ref,
		writer_audit_complete = true,
		writer_audit_evidence_ref = value.writer_audit_evidence_ref,
		review_attestation_ref = value.review_attestation_ref,
		live_acceptance_complete = value.live_acceptance_complete,
		families = table.freeze(families),
		writers = table.freeze(writers),
	}
	if value.live_acceptance_evidence_ref ~= nil then
		normalized.live_acceptance_evidence_ref = value.live_acceptance_evidence_ref
	end
	return table.freeze(normalized), nil
end

function Manifest.verify_for_activation(
	raw: unknown,
	verify_attestation: (manifest: { [string]: any }) -> (boolean, string?)
): ({ [string]: any }?, string?)
	local manifest, validation_error = Manifest.validate(raw)
	if manifest == nil then return nil, validation_error end
	if manifest.live_acceptance_complete ~= true
		or not valid_text(manifest.live_acceptance_evidence_ref, MAX_EVIDENCE_BYTES)
	then
		return nil, "live Roblox acceptance has not been completed for this inventory revision"
	end
	if type(verify_attestation) ~= "function" then
		return nil, "an independent attestation verifier is required"
	end
	local ok, accepted, message = pcall(verify_attestation, manifest)
	if not ok then return nil, "independent manifest attestation verifier failed: " .. tostring(accepted) end
	if accepted ~= true then return nil, tostring(message or "independent manifest attestation was not accepted") end
	return manifest, nil
end

return Manifest
