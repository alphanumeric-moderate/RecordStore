--!strict
--!optimize 2
-- PlayerDataCore-specific adapter for RecordStoreV2's durable erasure coordinator.
-- This covers the deterministic PlayerDataCore profile key only. Applications must add
-- every other user-associated key family before claiming exhaustive RTBF coverage.

local Players = game:GetService("Players")
local RecordStore = require(script.Parent.RecordStore)
local RecordStoreV2Factory = require(script.Parent.RecordStoreV2)

type ErasureItem = {
	name: string,
	scope: string,
	key: string,
	generation: number,
}

type Family = {
	name: string,
	templates: { { name: string, scope: string, key: string } },
	templates_verified: boolean,
	inventory: (number, number) -> ({ ErasureItem }?, boolean | string),
	fence_user: (number, string, { ErasureItem }?) -> (boolean, string?),
	dependencies_clear: (ErasureItem, number) -> (boolean, string?),
	redact_or_delete_if_generation: (ErasureItem, number, string) -> (string, string?),
}

type Options = {
	record_store: any?,
	record_store_v2: any?,
	profile_store_name: string?,
	mailbox_module: any?,
	profile_scope: string?,
	key_prefix: string?,
	operation_deadline: number?,
	profile_family_verified: boolean?,
	application_inventory_manifest_id: string?,
	writer_inventory_verified: boolean?,
	verify_templates: ((number, { any }) -> boolean)?,
	additional_families: { any }?,
	dependencies_clear: ((ErasureItem, number) -> (boolean, string?))?,
	kick_player: ((number, string) -> (boolean, string?))?,
}

local DEFAULT_PROFILE_STORE = "PlayerData_Test1"
local DEFAULT_PROFILE_SCOPE = "global"
local DEFAULT_KEY_PREFIX = "Player_"
local MAX_SAFE_INTEGER = 9007199254740991

local function valid_user_id(value: unknown): boolean
	return type(value) == "number" and math.isfinite(value)
		and math.floor(value) == value and value >= 1 and value <= MAX_SAFE_INTEGER
end

local function valid_text(value: unknown, maximum: number): boolean
	return type(value) == "string" and value ~= "" and #value <= maximum
end

local function make_profile_key(prefix: string, user_id: number): string
	return prefix .. tostring(user_id)
end

local function new(manifest_store: any, options: Options?): any
	if type(manifest_store) ~= "table"
		or type(manifest_store.GetAsyncFresh) ~= "function"
		or type(manifest_store.UpdateAsync) ~= "function"
	then
		error("PlayerDataErasure requires a durable manifest adapter with GetAsyncFresh and UpdateAsync", 2)
	end
	if options ~= nil and type(options) ~= "table" then
		error("PlayerDataErasure options must be a table", 2)
	end
	local config: Options = if options == nil then {} else table.clone(options)
	local record_store = config.record_store or RecordStore
	local record_store_v2 = config.record_store_v2 or RecordStoreV2Factory
	local profile_store_name = config.profile_store_name or DEFAULT_PROFILE_STORE
	local profile_scope = if config.profile_scope == nil then DEFAULT_PROFILE_SCOPE else config.profile_scope
	local key_prefix = config.key_prefix or DEFAULT_KEY_PREFIX
	local operation_deadline = config.operation_deadline
	if not valid_text(profile_store_name, 50) then error("profile_store_name must be 1 to 50 bytes", 2) end
	if type(profile_scope) ~= "string" or #profile_scope > 50 then error("profile_scope must be a string of at most 50 bytes", 2) end
	if not valid_text(key_prefix, 40) then error("key_prefix must be 1 to 40 bytes", 2) end
	if operation_deadline ~= nil and (
		type(operation_deadline) ~= "number" or not math.isfinite(operation_deadline)
		or operation_deadline <= 0
	) then error("operation_deadline must be finite and positive", 2) end
	if config.application_inventory_manifest_id ~= nil
		and not valid_text(config.application_inventory_manifest_id, 128)
	then
		error("application_inventory_manifest_id must be 1 to 128 bytes", 2)
	end
	if config.writer_inventory_verified ~= nil and type(config.writer_inventory_verified) ~= "boolean" then
		error("writer_inventory_verified must be a boolean", 2)
	end
	if config.writer_inventory_verified == true and config.application_inventory_manifest_id == nil then
		error("writer_inventory_verified requires an application inventory manifest ID", 2)
	end
	if config.verify_templates == nil or type(config.verify_templates) ~= "function" then
		error("PlayerDataErasure requires verify_templates; a hard-coded template is not proof of live coverage", 2)
	end
	if config.additional_families ~= nil and type(config.additional_families) ~= "table" then
		error("additional_families must be an array", 2)
	end
	if type(record_store) ~= "table"
		or type(record_store.get_erasure_status_async) ~= "function"
		or type(record_store.erase_user_data_async) ~= "function"
		or type(record_store.purge_erased_versions_async) ~= "function"
		or type(record_store.list_versions_async) ~= "function"
	then
		error("RecordStore must expose the permanent erasure fence and historical purge APIs", 2)
	end
	if type(record_store_v2) ~= "table" or type(record_store_v2.new) ~= "function" then
		error("RecordStoreV2 factory is unavailable", 2)
	end
	local mailbox = config.mailbox_module or record_store.MailboxV2 or RecordStore.MailboxV2
	if type(mailbox) ~= "table" or type(mailbox.new) ~= "function" then
		error("RecordStore must expose its MailboxV2 module", 2)
	end

	local function resolve_key(user_id: number): string
		return make_profile_key(key_prefix, user_id)
	end

	local function kick_active_player(user_id: number, erasure_id: string): (boolean, string?)
		if type(config.kick_player) == "function" then
			local ok, accepted, message = pcall(config.kick_player, user_id, erasure_id)
			if not ok then return false, tostring(accepted) end
			if accepted ~= true then return false, message or "application did not confirm the active-player fence" end
			return true, nil
		end
		local player = Players:GetPlayerByUserId(user_id)
		if player ~= nil then
			local ok, message = pcall(function()
				player:Kick("Your data is being erased. Rejoin only after the request is resolved.")
			end)
			if not ok then return false, tostring(message) end
		end
		return true, nil
	end

	local function dependencies_clear(item: ErasureItem, user_id: number): (boolean, string?)
		if item.name ~= profile_store_name or item.scope ~= profile_scope
			or item.key ~= resolve_key(user_id)
		then
			return false, "inventory locator is outside the declared PlayerDataCore family"
		end
		if type(config.dependencies_clear) == "function" then
			return config.dependencies_clear(item, user_id)
		end
		-- PlayerDataCore's configured profile fields are scalar values and contain no
		-- external object references. Additional key families need their own checks.
		return true, nil
	end

	local family: Family = {
		name = "PlayerDataCore",
		templates = {
			{
				name = profile_store_name,
				scope = profile_scope,
				key = key_prefix .. "{user_id}",
			},
		},
		-- A family flag alone cannot certify RTBF: an independently reconciled application
		-- inventory must also attest that direct writers and recreation paths are fenced.
		templates_verified = config.profile_family_verified == true
			and config.writer_inventory_verified == true
			and valid_text(config.application_inventory_manifest_id, 128),
		inventory = function(user_id: number, _maximum: number): ({ ErasureItem }?, boolean | string)
			if not valid_user_id(user_id) then return nil, "invalid UserId" end
			local key = resolve_key(user_id)
			local status, code, message = record_store.get_erasure_status_async(
				profile_store_name, profile_scope, key, user_id, operation_deadline
			)
			if code ~= "success" and code ~= "not_found" then
				return nil, message or ("profile inventory failed: " .. tostring(code))
			end
			local generation = 0
			if status ~= nil then
				generation = if status.Erased then status.SourceGeneration or 0 else status.Generation
				local history, history_code, history_message = record_store.list_versions_async(
					profile_store_name, profile_scope, key, Enum.SortDirection.Descending,
					nil, nil, 1024, operation_deadline
				)
				if history_code ~= "success" or history == nil then
					return nil, history_message or ("historical inventory failed: " .. tostring(history_code))
				end
			end
			return {
				{
					name = profile_store_name,
					scope = profile_scope,
					key = key,
					generation = generation,
				},
			}, true
		end,
		fence_user = function(
			user_id: number,
			erasure_id: string,
			planned_items: { ErasureItem }?
		): (boolean, string?)
			if not valid_user_id(user_id) or not valid_text(erasure_id, 96) then
				return false, "invalid erasure identity"
			end
			if type(planned_items) ~= "table" or #planned_items ~= 1 then
				return false, "PlayerDataCore erasure requires exactly one generation-bound profile inventory item"
			end
			local planned = planned_items[1]
			if type(planned) ~= "table" or planned.name ~= profile_store_name
				or planned.scope ~= profile_scope or planned.key ~= resolve_key(user_id)
				or not math.isfinite(planned.generation) or planned.generation < 0
				or math.floor(planned.generation) ~= planned.generation
			then
				return false, "planned profile inventory identity or generation is invalid"
			end
			local clear, dependency_error = dependencies_clear(planned, user_id)
			if clear ~= true then return false, dependency_error or "live dependency blocks deletion" end
			local kicked, kick_error = kick_active_player(user_id, erasure_id)
			if not kicked then return false, kick_error or "active player could not be fenced" end
			local _, code, message = record_store.erase_user_data_async(
				profile_store_name, profile_scope, planned.key,
				user_id, erasure_id, planned.generation, operation_deadline
			)
			if code ~= "success" then return false, message or ("generation-aware profile fence failed: " .. tostring(code)) end
			return true, nil
		end,
		dependencies_clear = dependencies_clear,
		redact_or_delete_if_generation = function(
			item: ErasureItem,
			user_id: number,
			erasure_id: string
		): (string, string?)
			if not valid_user_id(user_id) or not valid_text(erasure_id, 96)
				or item.name ~= profile_store_name or item.scope ~= profile_scope
				or item.key ~= resolve_key(user_id)
			then
				return "skipped", "inventory identity did not match the exact PlayerDataCore key"
			end
			local _, erase_code, erase_message = record_store.erase_user_data_async(
				profile_store_name, profile_scope, item.key, user_id, erasure_id,
				item.generation, operation_deadline
			)
			if erase_code ~= "success" then
				return if erase_code == "unknown" then "unknown" else "retryable",
					erase_message or ("generation-aware profile erasure returned " .. tostring(erase_code))
			end
			local progress, purge_code, purge_message = record_store.purge_erased_versions_async(
				profile_store_name, profile_scope, item.key, user_id, erasure_id, 16, operation_deadline
			)
			if purge_code ~= "success" or progress == nil then
				return if purge_code == "unknown" then "unknown" else "retryable",
					purge_message or ("historical profile purge returned " .. tostring(purge_code))
			end
			if progress.Complete ~= true then
				local retention_until = progress.RetentionUntil
				if type(retention_until) == "number" and math.isfinite(retention_until) then
					if os.time() < retention_until then
						return "retryable", "historical profile versions are retained by Roblox until approximately Unix time "
							.. tostring(retention_until) .. "; keep the writer fence and resume the same erasure ID after retention expiry"
					end
					return "retryable", "the retention deadline passed but historical versions remain visible; keep the writer fence, do not certify erasure completion, and investigate live DataStore retention before resuming"
				end
				return "retryable", "historical profile purge remains incomplete; resume the same erasure ID"
			end
			return "redacted", nil
		end,
	}

	local additional_families = config.additional_families or {}
	local additional_count = #additional_families
	local additional_keys = 0
	for index in pairs(additional_families) do
		additional_keys += 1
		if type(index) ~= "number" or not math.isfinite(index)
			or math.floor(index) ~= index or index < 1 or index > additional_count
		then
			error("additional_families must be a dense numeric array", 2)
		end
	end
	if additional_keys ~= additional_count then
		error("additional_families must be a dense numeric array", 2)
	end
	local families: { any } = { family }
	for index = 1, additional_count do
		local additional = additional_families[index]
		if type(additional) ~= "table" then error("additional erasure families must be tables", 2) end
		families[#families + 1] = additional
	end

	local v2 = record_store_v2.new(record_store, mailbox)
	return v2.Erasure.new(manifest_store, families, {
		verify_templates = config.verify_templates,
		require_inventory_attestation = true,
		application_inventory_manifest_id = config.application_inventory_manifest_id,
		writer_inventory_verified = config.writer_inventory_verified == true,
	})
end

return table.freeze({
	new = new,
})
