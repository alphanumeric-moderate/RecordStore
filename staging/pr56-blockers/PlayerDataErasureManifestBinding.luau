--!strict
local ErasureBinding = {}

export type RuntimeOptions = {
	record_store: any?,
	record_store_v2: any?,
	mailbox_module: any?,
	operation_deadline: number?,
	verify_templates: (number, { any }) -> boolean,
	dependencies_clear: ((any, number) -> (boolean, string?))?,
	kick_player: ((number, string) -> (boolean, string?))?,
}

export type FamilyAdapter = {
	family_id: string,
	action: string,
	inventory: (number, number) -> ({ any }?, boolean | string),
	fence_user: (number, string, { any }?) -> (boolean, string?),
	dependencies_clear: (any, number) -> (boolean, string?),
	redact_or_delete_if_generation: (any, number, string) -> (string, string?),
}

export type AttestationVerifier = (
	manifest: { [string]: any },
	family_adapters: { FamilyAdapter },
	runtime_options: RuntimeOptions
) -> (boolean, string?)

local MAX_FAMILY_NAME_BYTES = 48
local MAX_KEY_BYTES = 50
local MAX_KEY_PREFIX_BYTES = 40
local MAX_ADAPTERS = 128

local RUNTIME_FIELDS = {
	record_store = true,
	record_store_v2 = true,
	mailbox_module = true,
	operation_deadline = true,
	verify_templates = true,
	dependencies_clear = true,
	kick_player = true,
}

local ADAPTER_FIELDS = {
	family_id = true,
	action = true,
	inventory = true,
	fence_user = true,
	dependencies_clear = true,
	redact_or_delete_if_generation = true,
}

local function valid_text(value: unknown, maximum: number): boolean
	return type(value) == "string" and value ~= "" and #value <= maximum
		and string.find(value, "%c") == nil
end

local function finite_positive(value: unknown): boolean
	return type(value) == "number" and math.isfinite(value) and value > 0
end

local function exact_fields(value: { [string]: any }, allowed: { [string]: boolean }): boolean
	for key in pairs(value) do
		if type(key) ~= "string" or allowed[key] ~= true then return false end
	end
	return true
end

local function dense_array(value: unknown, maximum: number): ({ any }?, string?)
	if type(value) ~= "table" then return nil, "family adapters must be a dense numeric array" end
	local rows = value :: { [any]: any }
	local length = #rows
	if length > maximum then return nil, "family adapters exceed the configured bound" end
	local count = 0
	for key in pairs(rows) do
		if type(key) ~= "number" or not math.isfinite(key)
			or math.floor(key) ~= key or key < 1 or key > length
		then
			return nil, "family adapters must be a dense numeric array"
		end
		count += 1
	end
	if count ~= length then return nil, "family adapters must be a dense numeric array" end
	return rows, nil
end

local function profile_prefix(family: { [string]: any }): (string?, string?)
	if family.locator_mode ~= "user_id_template" then
		return nil, "PlayerDataErasure cannot represent a dynamic external-inventory profile family"
	end
	if family.action ~= "tombstone" and family.action ~= "redact" then
		return nil, "PlayerDataErasure supports only tombstone or redaction actions"
	end
	local key_template = family.key_template
	if not valid_text(key_template, MAX_KEY_BYTES) then return nil, "profile key template is invalid" end
	local needle = "{user_id}"
	if select(2, string.gsub(key_template, needle, "")) ~= 1
		or string.sub(key_template, -#needle) ~= needle
	then
		return nil, "PlayerDataErasure requires a profile key template ending in exactly one {user_id} placeholder"
	end
	local prefix = string.sub(key_template, 1, #key_template - #needle)
	if not valid_text(prefix, MAX_KEY_PREFIX_BYTES) then
		return nil, "profile key prefix must be 1 to 40 non-control bytes"
	end
	return prefix, nil
end

local function normalize_runtime(raw: unknown): (RuntimeOptions?, string?)
	if type(raw) ~= "table" then return nil, "runtime options must be a table" end
	local value = raw :: { [string]: any }
	if not exact_fields(value, RUNTIME_FIELDS) then
		return nil, "runtime options contain an unsupported or identity-overriding field"
	end
	if type(value.verify_templates) ~= "function" then return nil, "verify_templates callback is required" end
	if value.operation_deadline ~= nil and not finite_positive(value.operation_deadline) then
		return nil, "operation_deadline must be finite and positive"
	end
	if value.dependencies_clear ~= nil and type(value.dependencies_clear) ~= "function" then
		return nil, "dependencies_clear must be a function"
	end
	if value.kick_player ~= nil and type(value.kick_player) ~= "function" then
		return nil, "kick_player must be a function"
	end
	if value.record_store ~= nil and type(value.record_store) ~= "table" then
		return nil, "record_store must be a table"
	end
	if value.record_store_v2 ~= nil and type(value.record_store_v2) ~= "table" then
		return nil, "record_store_v2 must be a table"
	end
	if value.mailbox_module ~= nil and type(value.mailbox_module) ~= "table" then
		return nil, "mailbox_module must be a table"
	end
	return table.freeze({
		record_store = value.record_store,
		record_store_v2 = value.record_store_v2,
		mailbox_module = value.mailbox_module,
		operation_deadline = value.operation_deadline,
		verify_templates = value.verify_templates,
		dependencies_clear = value.dependencies_clear,
		kick_player = value.kick_player,
	}), nil
end

function ErasureBinding.bind(
	inventory_module: any,
	raw_manifest: unknown,
	raw_runtime_options: unknown,
	raw_family_adapters: unknown,
	verify_attestation: AttestationVerifier
): ({ [string]: any }?, { [string]: any }?, string?)
	if type(inventory_module) ~= "table"
		or type(inventory_module.validate) ~= "function"
		or type(inventory_module.verify_for_activation) ~= "function"
	then
		return nil, nil, "inventory module must expose validate and verify_for_activation"
	end
	local runtime, runtime_error = normalize_runtime(raw_runtime_options)
	if runtime == nil then return nil, nil, runtime_error end
	if type(verify_attestation) ~= "function" then return nil, nil, "independent RTBF attestation verifier is required" end
	local raw_adapters, adapters_error = dense_array(raw_family_adapters, MAX_ADAPTERS)
	if raw_adapters == nil then return nil, nil, adapters_error end

	local manifest, manifest_error = inventory_module.validate(raw_manifest)
	if manifest == nil then return nil, nil, manifest_error end
	local profile_family_id = "player-profile"
	local profile_family = nil
	local families_by_id: { [string]: any } = {}
	for _, family in ipairs(manifest.families) do
		families_by_id[family.id] = family
		if family.id == profile_family_id then profile_family = family end
	end
	if profile_family == nil then return nil, nil, "manifest lacks the explicit player-profile family" end
	local key_prefix, prefix_error = profile_prefix(profile_family)
	if key_prefix == nil then return nil, nil, prefix_error end

	local adapters_by_id: { [string]: any } = {}
	local normalized_adapters: { any } = {}
	for _, raw_adapter in ipairs(raw_adapters) do
		if type(raw_adapter) ~= "table" then return nil, nil, "family adapter must be a table" end
		local adapter = raw_adapter :: { [string]: any }
		if not exact_fields(adapter, ADAPTER_FIELDS)
			or not valid_text(adapter.family_id, MAX_FAMILY_NAME_BYTES)
		then
			return nil, nil, "family adapter has an unsupported field or invalid family ID"
		end
		if adapters_by_id[adapter.family_id] ~= nil then return nil, nil, "duplicate family adapter ID" end
		local family = families_by_id[adapter.family_id]
		if family == nil then return nil, nil, "family adapter is absent from the reviewed inventory manifest" end
		if family.id == profile_family_id then return nil, nil, "profile family must be wired through PlayerDataErasure's built-in adapter" end
		if family.locator_mode ~= "user_id_template" and family.locator_mode ~= "external_inventory" then
			return nil, nil, "manifest family uses an unsupported locator mode"
		end
		if family.action ~= "tombstone" and family.action ~= "redact" then
			return nil, nil, "current erasure coordinator does not support the manifest's declared family action"
		end
		if adapter.action ~= family.action then return nil, nil, "family adapter action does not match the reviewed manifest" end
		if type(adapter.inventory) ~= "function" or type(adapter.fence_user) ~= "function"
			or type(adapter.dependencies_clear) ~= "function"
			or type(adapter.redact_or_delete_if_generation) ~= "function"
		then
			return nil, nil, "family adapter must supply inventory, writer fence, dependency and generation-aware erase callbacks"
		end
		local key_template = if family.locator_mode == "external_inventory"
			then "__rtbf_external__{user_id}" else family.key_template
		local template: { [string]: any } = {
			name = family.store_name,
			scope = family.scope,
			key = key_template,
			locator_mode = family.locator_mode,
		}
		if family.locator_mode == "external_inventory" then
			template.inventory_source_ref = family.inventory_source_ref
		end
		local templates = table.freeze({ table.freeze(template) })
		local normalized_adapter = table.freeze({
			name = family.id,
			templates = templates,
			templates_verified = true,
			inventory = adapter.inventory,
			fence_user = adapter.fence_user,
			dependencies_clear = adapter.dependencies_clear,
			redact_or_delete_if_generation = adapter.redact_or_delete_if_generation,
		})
		adapters_by_id[family.id] = normalized_adapter
		normalized_adapters[#normalized_adapters + 1] = table.freeze({
			family_id = adapter.family_id,
			action = adapter.action,
			inventory = adapter.inventory,
			fence_user = adapter.fence_user,
			dependencies_clear = adapter.dependencies_clear,
			redact_or_delete_if_generation = adapter.redact_or_delete_if_generation,
		})
	end

	for _, family in ipairs(manifest.families) do
		if family.id ~= profile_family_id and adapters_by_id[family.id] == nil then
			return nil, nil, "manifest key family has no application erasure adapter"
		end
	end

	local frozen_adapters = table.freeze(normalized_adapters)
	local activated, activation_error = inventory_module.verify_for_activation(raw_manifest, function(verified_manifest)
		local ok, accepted, message = pcall(verify_attestation, verified_manifest, frozen_adapters, runtime)
		if not ok then return false, "RTBF attestation verifier failed: " .. tostring(accepted) end
		if accepted ~= true then return false, tostring(message or "RTBF attestation was not independently accepted") end
		return true, ""
	end)
	if activated == nil then
		return nil, nil, activation_error or "RTBF activation verifier rejected the inventory manifest"
	end
	if activated.manifest_id ~= manifest.manifest_id or activated.revision ~= manifest.revision then
		return nil, nil, "activated RTBF manifest changed between validation and binding"
	end

	local additional_families: { any } = {}
	for _, family in ipairs(manifest.families) do
		if family.id ~= profile_family_id then
			additional_families[#additional_families + 1] = adapters_by_id[family.id]
		end
	end
	table.freeze(additional_families)
	local configuration: { [string]: any } = {
		profile_store_name = profile_family.store_name,
		profile_scope = profile_family.scope,
		key_prefix = key_prefix,
		profile_family_verified = true,
		application_inventory_manifest_id = activated.manifest_id,
		writer_inventory_verified = true,
		verify_templates = runtime.verify_templates,
		additional_families = additional_families,
	}
	for _, option_name in ipairs({
		"record_store", "record_store_v2", "mailbox_module",
		"operation_deadline", "dependencies_clear", "kick_player",
	}) do
		local value = (runtime :: any)[option_name]
		if value ~= nil then configuration[option_name] = value end
	end
	return table.freeze(configuration), activated, nil
end

return ErasureBinding
