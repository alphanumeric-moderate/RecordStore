--!strict
local PurchaseManifest = {}

export type Checkpoint = {
	done: boolean,
	revision: number,
	source_revision: string,
	inventory_manifest_id: string,
	purchases_processed: number,
	expected_purchase_count: number,
	inventory_digest: string,
	expected_inventory_digest: string,
	inventory_verified: boolean,
}

export type RunnerBindings = {
	job_id: string,
	source: any,
	processor: any,
	checkpoint_store: any,
	checkpoint_key: string,
	initial_cursor: string?,
	page_size: number?,
}

export type TerminalVerifier = (
	manifest: { [string]: any },
	manifest_id: string,
	source_revision: string,
	expected_count: number,
	observed_count: number,
	expected_digest: string,
	observed_digest: string
) -> (boolean, string?)

local MAX_TEXT = 512
local MAX_ID = 128
local MAX_SOURCES = 32
local MAX_LEGACY_PATHS = 128
local MAX_CURSOR_BYTES = 512
local MAX_PAGE_SIZE = 16

local MANIFEST_FIELDS = {
	schema_version = true,
	kind = true,
	manifest_id = true,
	source_revision = true,
	source_snapshot_id = true,
	source_systems = true,
	legacy_receipt_paths = true,
	row_order = true,
	expected_purchase_count = true,
	expected_inventory_digest = true,
	exported_at_unix = true,
	review_status = true,
	reviewed_by = true,
	reviewed_at_unix = true,
	source_evidence_ref = true,
	end_of_inventory_evidence_ref = true,
	duplicate_conflict_report_ref = true,
	coverage_review_ref = true,
	archived_accounts_included = true,
	deleted_accounts_included = true,
}

local COMPLETION_FIELDS = {
	manifest_id = true,
	source_revision = true,
	observed_purchase_count = true,
	observed_inventory_digest = true,
	checkpoint_revision = true,
	conflicts_reconciled = true,
	conflict_reconciliation_evidence_ref = true,
	live_acceptance_complete = true,
	live_acceptance_evidence_ref = true,
}

local RUNNER_BINDING_FIELDS = {
	job_id = true,
	source = true,
	processor = true,
	checkpoint_store = true,
	checkpoint_key = true,
	initial_cursor = true,
	page_size = true,
}

local function valid_text(value: unknown, maximum: number): boolean
	return type(value) == "string" and value ~= "" and #value <= maximum
		and string.find(value, "%c") == nil
end

local function nonnegative_integer(value: unknown): boolean
	return type(value) == "number" and math.isfinite(value)
		and value >= 0 and value <= 9007199254740991 and math.floor(value) == value
end

local function positive_timestamp(value: unknown): boolean
	return type(value) == "number" and math.isfinite(value) and value > 0
end

local function valid_digest(value: unknown): boolean
	if type(value) ~= "string" or #value ~= 32 then return false end
	for index = 1, #value do
		local byte = string.byte(value, index)
		if not ((byte >= 48 and byte <= 57) or (byte >= 97 and byte <= 102)) then return false end
	end
	return true
end

local function exact_fields(value: { [string]: any }, allowed: { [string]: boolean }): boolean
	for key in pairs(value) do
		if type(key) ~= "string" or allowed[key] ~= true then return false end
	end
	return true
end

local function dense_string_array(value: unknown, minimum: number, maximum: number): ({ string }?, string?)
	if type(value) ~= "table" then return nil, "expected a string array" end
	local rows = value :: { [any]: any }
	local length = #rows
	if length < minimum or length > maximum then
		return nil, "array must contain " .. tostring(minimum) .. " to " .. tostring(maximum) .. " entries"
	end
	local count = 0
	local copied: { string } = {}
	local seen: { [string]: boolean } = {}
	for key, entry in pairs(rows) do
		if type(key) ~= "number" or not math.isfinite(key)
			or math.floor(key) ~= key or key < 1 or key > length
		then
			return nil, "array must be dense"
		end
		if type(entry) ~= "string" or not valid_text(entry, MAX_TEXT) then
			return nil, "array contains an invalid entry"
		end
		if seen[entry] then return nil, "array contains a duplicate entry" end
		seen[entry] = true
		count += 1
	end
	if count ~= length then return nil, "array must be dense" end
	for index, entry in ipairs(rows) do copied[index] = entry :: string end
	return copied, nil
end

function PurchaseManifest.validate(raw: unknown): ({ [string]: any }?, string?)
	if type(raw) ~= "table" then return nil, "purchase inventory manifest must be a table" end
	local value = raw :: { [string]: any }
	if not exact_fields(value, MANIFEST_FIELDS) then return nil, "manifest contains an unsupported field" end
	if value.schema_version ~= 1 or value.kind ~= "purchase_inventory"
		or not valid_text(value.manifest_id, MAX_ID)
		or not valid_text(value.source_revision, MAX_ID)
		or not valid_text(value.source_snapshot_id, MAX_ID)
	then
		return nil, "manifest identity, kind, schema version, or immutable snapshot revision is invalid"
	end
	if value.review_status ~= "approved" or not valid_text(value.reviewed_by, MAX_ID)
		or not positive_timestamp(value.reviewed_at_unix)
	then
		return nil, "manifest lacks independent review metadata"
	end
	if not nonnegative_integer(value.expected_purchase_count)
		or not valid_digest(value.expected_inventory_digest)
		or not positive_timestamp(value.exported_at_unix)
	then
		return nil, "manifest purchase count, rolling digest, or export timestamp is invalid"
	end
	if value.row_order ~= "purchase_id_asc_player_id_asc_product_id_asc" then
		return nil, "manifest must declare stable PurchaseId/PlayerId/ProductId ordering"
	end
	if value.archived_accounts_included ~= true or value.deleted_accounts_included ~= true then
		return nil, "manifest must account for archived and deleted users"
	end
	if not valid_text(value.source_evidence_ref, MAX_TEXT)
		or not valid_text(value.end_of_inventory_evidence_ref, MAX_TEXT)
		or not valid_text(value.duplicate_conflict_report_ref, MAX_TEXT)
		or not valid_text(value.coverage_review_ref, MAX_TEXT)
	then
		return nil, "manifest is missing source, terminal-pagination, conflict, or coverage evidence"
	end
	local source_systems, source_error = dense_string_array(value.source_systems, 1, MAX_SOURCES)
	if source_systems == nil then return nil, "source_systems: " .. tostring(source_error) end
	local legacy_paths, legacy_error = dense_string_array(value.legacy_receipt_paths, 1, MAX_LEGACY_PATHS)
	if legacy_paths == nil then return nil, "legacy_receipt_paths must explicitly enumerate paths or declare 'none': " .. tostring(legacy_error) end
	if not table.find(legacy_paths, "none") then
		for _, path in ipairs(legacy_paths) do
			if string.lower(path) == "none" then return nil, "'none' must be declared lowercase and alone" end
		end
	end
	if table.find(legacy_paths, "none") and #legacy_paths > 1 then
		return nil, "'none' cannot be combined with real legacy receipt paths"
	end
	local normalized = {
		schema_version = 1,
		kind = "purchase_inventory",
		manifest_id = value.manifest_id,
		source_revision = value.source_revision,
		source_snapshot_id = value.source_snapshot_id,
		source_systems = table.freeze(source_systems),
		legacy_receipt_paths = table.freeze(legacy_paths),
		row_order = value.row_order,
		expected_purchase_count = value.expected_purchase_count,
		expected_inventory_digest = value.expected_inventory_digest,
		exported_at_unix = value.exported_at_unix,
		review_status = value.review_status,
		reviewed_by = value.reviewed_by,
		reviewed_at_unix = value.reviewed_at_unix,
		source_evidence_ref = value.source_evidence_ref,
		end_of_inventory_evidence_ref = value.end_of_inventory_evidence_ref,
		duplicate_conflict_report_ref = value.duplicate_conflict_report_ref,
		coverage_review_ref = value.coverage_review_ref,
		archived_accounts_included = true,
		deleted_accounts_included = true,
	}
	return table.freeze(normalized), nil
end

function PurchaseManifest.verify_import_source(
	raw: unknown,
	verify_source: ({ [string]: any }) -> (boolean, string?)
): ({ [string]: any }?, string?)
	local manifest, validation_error = PurchaseManifest.validate(raw)
	if manifest == nil then return nil, validation_error end
	if type(verify_source) ~= "function" then return nil, "an independent immutable-source verifier is required" end
	local ok, accepted, message = pcall(verify_source, manifest)
	if not ok then return nil, "source verifier failed: " .. tostring(accepted) end
	if accepted ~= true then return nil, tostring(message or "source inventory was not independently verified") end
	return manifest, nil
end

function PurchaseManifest.bind_runner_config(
	raw_manifest: unknown,
	raw_bindings: unknown,
	verify_source: ({ [string]: any }) -> (boolean, string?),
	verify_terminal_inventory: TerminalVerifier
): ({ [string]: any }?, { [string]: any }?, string?)
	if type(raw_bindings) ~= "table" then return nil, nil, "runner bindings must be a table" end
	local bindings = raw_bindings :: { [string]: any }
	if not exact_fields(bindings, RUNNER_BINDING_FIELDS) then
		return nil, nil, "runner bindings contain an unsupported or pre-bound manifest field"
	end
	if not valid_text(bindings.job_id, 96) then return nil, nil, "job_id must be 1 to 96 bytes" end
	if type(bindings.source) ~= "table" or type(bindings.source.read_page) ~= "function" then
		return nil, nil, "source must implement read_page over the reviewed immutable snapshot"
	end
	if type(bindings.processor) ~= "table" or type(bindings.processor.BackfillExternalAuthorityAsync) ~= "function" then
		return nil, nil, "processor must implement BackfillExternalAuthorityAsync"
	end
	if type(bindings.checkpoint_store) ~= "table"
		or type(bindings.checkpoint_store.GetAsyncFresh) ~= "function"
		or type(bindings.checkpoint_store.UpdateAsync) ~= "function"
	then
		return nil, nil, "checkpoint_store must implement uncached GetAsyncFresh and atomic UpdateAsync"
	end
	if not valid_text(bindings.checkpoint_key, 50) then return nil, nil, "checkpoint_key must be 1 to 50 bytes" end
	if bindings.initial_cursor ~= nil and not valid_text(bindings.initial_cursor, MAX_CURSOR_BYTES) then
		return nil, nil, "initial_cursor exceeds the 512-byte cursor limit"
	end
	if bindings.page_size ~= nil and (not nonnegative_integer(bindings.page_size)
		or bindings.page_size < 1 or bindings.page_size > MAX_PAGE_SIZE)
	then
		return nil, nil, "page_size must be an integer from 1 to 16"
	end
	if type(verify_source) ~= "function" then return nil, nil, "an independent source verifier is required" end
	if type(verify_terminal_inventory) ~= "function" then
		return nil, nil, "an independent terminal inventory verifier is required"
	end
	local manifest, source_error = PurchaseManifest.verify_import_source(raw_manifest, verify_source)
	if manifest == nil then return nil, nil, source_error end

	local runner_config = {
		job_id = bindings.job_id,
		source_revision = manifest.source_revision,
		source = bindings.source,
		processor = bindings.processor,
		checkpoint_store = bindings.checkpoint_store,
		checkpoint_key = bindings.checkpoint_key,
		initial_cursor = bindings.initial_cursor,
		page_size = bindings.page_size,
		inventory_manifest_id = manifest.manifest_id,
		expected_purchase_count = manifest.expected_purchase_count,
		expected_inventory_digest = manifest.expected_inventory_digest,
		verify_complete_inventory = function(
			manifest_id: string,
			source_revision: string,
			expected_count: number,
			observed_count: number,
			expected_digest: string,
			observed_digest: string
		): (boolean, string?)
			if manifest_id ~= manifest.manifest_id or source_revision ~= manifest.source_revision
				or expected_count ~= manifest.expected_purchase_count
				or observed_count ~= manifest.expected_purchase_count
				or expected_digest ~= manifest.expected_inventory_digest
				or observed_digest ~= manifest.expected_inventory_digest
			then
				return false, "terminal source page does not match the reviewed purchase manifest"
			end
			local ok, accepted, message = pcall(
				verify_terminal_inventory,
				manifest,
				manifest_id,
				source_revision,
				expected_count,
				observed_count,
				expected_digest,
				observed_digest
			)
			if not ok then return false, "terminal inventory verifier failed: " .. tostring(accepted) end
			if accepted ~= true then return false, tostring(message or "terminal inventory verifier rejected the source") end
			return true, nil
		end,
	}
	return table.freeze(runner_config), manifest, nil
end

function PurchaseManifest.verify_completion(
	raw: unknown,
	raw_checkpoint: unknown,
	raw_completion: unknown,
	verify_completion: ({ [string]: any }, Checkpoint, { [string]: any }) -> (boolean, string?)
): ({ [string]: any }?, string?)
	local manifest, validation_error = PurchaseManifest.validate(raw)
	if manifest == nil then return nil, validation_error end
	if type(raw_checkpoint) ~= "table" or type(raw_completion) ~= "table" then
		return nil, "durable terminal checkpoint and completion evidence are required"
	end
	local checkpoint = raw_checkpoint :: { [string]: any }
	local completion = raw_completion :: { [string]: any }
	if not exact_fields(completion, COMPLETION_FIELDS) then return nil, "completion evidence contains an unsupported field" end
	if checkpoint.done ~= true or checkpoint.cursor ~= nil
		or not nonnegative_integer(checkpoint.revision) or checkpoint.revision < 1
		or checkpoint.source_revision ~= manifest.source_revision
		or checkpoint.inventory_manifest_id ~= manifest.manifest_id
		or checkpoint.expected_purchase_count ~= manifest.expected_purchase_count
		or checkpoint.expected_inventory_digest ~= manifest.expected_inventory_digest
		or checkpoint.purchases_processed ~= manifest.expected_purchase_count
		or checkpoint.inventory_digest ~= manifest.expected_inventory_digest
		or checkpoint.inventory_verified ~= true
	then
		return nil, "durable migration checkpoint does not match the reviewed source inventory manifest"
	end
	if completion.manifest_id ~= manifest.manifest_id
		or completion.source_revision ~= manifest.source_revision
		or completion.observed_purchase_count ~= manifest.expected_purchase_count
		or completion.observed_inventory_digest ~= manifest.expected_inventory_digest
		or not nonnegative_integer(completion.checkpoint_revision) or completion.checkpoint_revision < 1
		or completion.checkpoint_revision ~= checkpoint.revision
	then
		return nil, "completion evidence does not reconcile to the reviewed source inventory"
	end
	if completion.conflicts_reconciled ~= true
		or not valid_text(completion.conflict_reconciliation_evidence_ref, MAX_TEXT)
	then
		return nil, "purchase conflicts have not been independently reconciled"
	end
	if completion.live_acceptance_complete ~= true
		or not valid_text(completion.live_acceptance_evidence_ref, MAX_TEXT)
	then
		return nil, "live Roblox purchase fulfillment acceptance is not recorded"
	end
	if type(verify_completion) ~= "function" then return nil, "an independent completion verifier is required" end
	local normalized_checkpoint: Checkpoint = {
		done = true,
		revision = checkpoint.revision,
		source_revision = checkpoint.source_revision,
		inventory_manifest_id = checkpoint.inventory_manifest_id,
		purchases_processed = checkpoint.purchases_processed,
		expected_purchase_count = manifest.expected_purchase_count,
		inventory_digest = checkpoint.inventory_digest,
		expected_inventory_digest = manifest.expected_inventory_digest,
		inventory_verified = true,
	}
	local normalized_completion = table.freeze({
		manifest_id = completion.manifest_id,
		source_revision = completion.source_revision,
		observed_purchase_count = completion.observed_purchase_count,
		observed_inventory_digest = completion.observed_inventory_digest,
		checkpoint_revision = completion.checkpoint_revision,
		conflicts_reconciled = true,
		conflict_reconciliation_evidence_ref = completion.conflict_reconciliation_evidence_ref,
		live_acceptance_complete = true,
		live_acceptance_evidence_ref = completion.live_acceptance_evidence_ref,
	})
	local ok, accepted, message = pcall(verify_completion, manifest, normalized_checkpoint, normalized_completion)
	if not ok then return nil, "completion verifier failed: " .. tostring(accepted) end
	if accepted ~= true then return nil, tostring(message or "purchase migration completion was not independently accepted") end
	return manifest, nil
end

return PurchaseManifest
