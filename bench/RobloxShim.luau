--!nocheck
-- Minimal Roblox engine shim so RecordStore can run under Lune (https://lune-org.github.io/docs)
-- for CodSpeed benchmarks. Only the services used by the RecordStore.Mock backend are
-- implemented; live DataStore/MessagingService calls are not available here.

local datetime = require("@lune/datetime")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")

local Shim = {}

local REPO_ROOT = "."
local SOURCE_PATH = REPO_ROOT .. "/src/PlayerDataInitializer/RecordStore.luau"

-- Deterministic GUIDs keep benchmark runs reproducible.
local guid_counter = 0
local function generate_guid(_self, wrap_in_braces: boolean?): string
	guid_counter += 1
	local id = string.format("00000000-0000-4000-8000-%012x", guid_counter)
	if wrap_in_braces then
		return "{" .. id .. "}"
	end
	return id
end

local HttpService = {
	GenerateGUID = generate_guid,
	JSONEncode = function(_self, value: any): string
		return serde.encode("json", value)
	end,
	JSONDecode = function(_self, value: string): any
		return serde.decode("json", value)
	end,
}

local DataStoreService = {
	GetDataStore = function()
		error("DataStoreService is not available outside Roblox; use RecordStore.Mock", 2)
	end,
	GetRequestBudgetForRequestType = function()
		return math.huge
	end,
}

local MessagingService = {
	PublishAsync = function()
		error("MessagingService is not available outside Roblox", 2)
	end,
	SubscribeAsync = function()
		error("MessagingService is not available outside Roblox", 2)
	end,
}

local bind_to_close: { () -> () } = {}

local function make_enum(enum_name: string, items: { string })
	local enum = {}
	for _, item in items do
		enum[item] = table.freeze({ Name = item, EnumType = enum_name })
	end
	return table.freeze(enum)
end

local Enum = table.freeze({
	DataStoreRequestType = make_enum("DataStoreRequestType", {
		"GetAsync",
		"SetIncrementAsync",
		"UpdateAsync",
		"GetSortedAsync",
		"SetIncrementSortedAsync",
		"OnUpdate",
		"ListAsync",
		"GetVersionAsync",
		"RemoveVersionAsync",
		"StandardRead",
		"StandardWrite",
		"StandardList",
		"StandardRemove",
	}),
	SortDirection = make_enum("SortDirection", { "Ascending", "Descending" }),
	ProductPurchaseDecision = make_enum("ProductPurchaseDecision", { "PurchaseGranted", "NotProcessedYet" }),
})

local DateTime = table.freeze({
	now = function()
		return { UnixTimestampMillis = datetime.now().unixTimestampMillis }
	end,
})

local Instance = table.freeze({
	new = function(class_name: string)
		return { ClassName = class_name }
	end,
})

local loaded_module: any = nil
local loaded_scheduler_module: any = nil
local loaded_mailbox_module: any = nil
local loaded_receipt_processor: any = nil
local loaded_outbox_mailbox_adapter: any = nil
local loaded_outbox_consumer_adapter: any = nil
local loaded_recordstore_v2: any = nil
local loaded_player_data_erasure: any = nil
local loaded_purchase_datastore_authority: any = nil
local loaded_purchase_authority_migration_runner: any = nil
local loaded_purchase_inventory_manifest: any = nil
local loaded_purchase_entitlement_authority: any = nil
local loaded_purchase_entitlement_coordinator: any = nil
local loaded_purchase_entitlement_handler: any = nil
local loaded_recordstore_sha256: any = nil
local loaded_maintenance_roblox_adapter: any = nil
local loaded_maintenance_atomic_tombstone: any = nil

local RecordStoreInstance = table.freeze({ Name = "RecordStore", ClassName = "ModuleScript" })
local PurchaseReceiptProcessorInstance = table.freeze({ Name = "PurchaseReceiptProcessor", ClassName = "ModuleScript" })
local RecordStoreV2Instance = table.freeze({ Name = "RecordStoreV2", ClassName = "ModuleScript" })
local OutboxMailboxAdapterInstance = table.freeze({ Name = "RecordStoreOutboxMailboxAdapter", ClassName = "ModuleScript" })
local OutboxConsumerAdapterInstance = table.freeze({ Name = "RecordStoreOutboxConsumerAdapter", ClassName = "ModuleScript" })
local PlayerDataErasureInstance = table.freeze({ Name = "PlayerDataErasure", ClassName = "ModuleScript" })
local PurchaseDataStoreAuthorityInstance = table.freeze({ Name = "PurchaseDataStoreAuthority", ClassName = "ModuleScript" })
local PurchaseAuthorityMigrationRunnerInstance = table.freeze({ Name = "PurchaseAuthorityMigrationRunner", ClassName = "ModuleScript" })
local PurchaseInventoryManifestInstance = table.freeze({ Name = "PurchaseInventoryManifest", ClassName = "ModuleScript" })
local PurchaseEntitlementAuthorityInstance = table.freeze({ Name = "PurchaseEntitlementDataStoreAuthority", ClassName = "ModuleScript" })
local PurchaseEntitlementCoordinatorInstance = table.freeze({ Name = "PurchaseEntitlementReceiptCoordinator", ClassName = "ModuleScript" })
local PurchaseEntitlementHandlerInstance = table.freeze({ Name = "PurchaseEntitlementReceiptHandler", ClassName = "ModuleScript" })
local RecordStoreSHA256Instance = table.freeze({ Name = "RecordStoreSHA256", ClassName = "ModuleScript" })
local RecordStoreMaintenanceRobloxAdapterInstance = table.freeze({ Name = "RecordStoreMaintenanceRobloxAdapter", ClassName = "ModuleScript" })
local RecordStoreMaintenanceAtomicTombstoneInstance = table.freeze({ Name = "RecordStoreMaintenanceAtomicTombstone", ClassName = "ModuleScript" })
local PlayerDataInitializer = {
	RecordStore = RecordStoreInstance,
	PurchaseReceiptProcessor = PurchaseReceiptProcessorInstance,
	RecordStoreOutboxMailboxAdapter = OutboxMailboxAdapterInstance,
	RecordStoreOutboxConsumerAdapter = OutboxConsumerAdapterInstance,
	RecordStoreV2 = RecordStoreV2Instance,
	PlayerDataErasure = PlayerDataErasureInstance,
	PurchaseDataStoreAuthority = PurchaseDataStoreAuthorityInstance,
	PurchaseAuthorityMigrationRunner = PurchaseAuthorityMigrationRunnerInstance,
	PurchaseInventoryManifest = PurchaseInventoryManifestInstance,
	PurchaseEntitlementDataStoreAuthority = PurchaseEntitlementAuthorityInstance,
	PurchaseEntitlementReceiptCoordinator = PurchaseEntitlementCoordinatorInstance,
	PurchaseEntitlementReceiptHandler = PurchaseEntitlementHandlerInstance,
	RecordStoreSHA256 = RecordStoreSHA256Instance,
	RecordStoreMaintenanceRobloxAdapter = RecordStoreMaintenanceRobloxAdapterInstance,
	RecordStoreMaintenanceAtomicTombstone = RecordStoreMaintenanceAtomicTombstoneInstance,
}
function PlayerDataInitializer:WaitForChild(name: string): any
	local child = self[name]
	assert(child ~= nil, "module is not available: " .. name)
	return child
end
function PlayerDataInitializer:FindFirstChild(name: string): any
	return self[name]
end
local script = {
	Parent = PlayerDataInitializer,
}

local function load_scheduler(): any
	if loaded_scheduler_module ~= nil then return loaded_scheduler_module end
	local source = fs.readFile(SOURCE_PATH)
	local begin_marker = "-- BEGIN EMBEDDED SCHEDULER MODULE"
	local end_marker = "-- END EMBEDDED SCHEDULER MODULE"
	local begin_position = string.find(source, begin_marker, 1, true)
	local end_position = if begin_position ~= nil
		then string.find(source, end_marker, begin_position + #begin_marker, true)
		else nil
	assert(begin_position ~= nil and end_position ~= nil and end_position > begin_position,
		"embedded scheduler implementation markers are missing or out of order")
	local embedded_source = string.sub(source, begin_position, end_position - 1)
	local chunk = luau.load(embedded_source .. "\nreturn RecordStoreScheduler\n", {
		debugName = "RecordStoreScheduler",
		environment = Shim.environment,
	})
	loaded_scheduler_module = chunk()
	return loaded_scheduler_module
end
local function load_mailbox(): any
	if loaded_mailbox_module ~= nil then return loaded_mailbox_module end
	loaded_mailbox_module = Shim.load().MailboxV2
	return loaded_mailbox_module
end
local function load_record_store(source_path: string?): any
	if loaded_module ~= nil then
		return loaded_module
	end
	local chunk = luau.load(fs.readFile(source_path or SOURCE_PATH), {
		debugName = "RecordStore",
		environment = Shim.environment,
	})
	loaded_module = chunk()
	return loaded_module
end

local function load_recordstore_v2(): any
	if loaded_recordstore_v2 ~= nil then return loaded_recordstore_v2 end
	local chunk = luau.load(fs.readFile("src/PlayerDataInitializer/RecordStoreV2.luau"), {
		debugName = "RecordStoreV2",
		environment = Shim.environment,
	})
	loaded_recordstore_v2 = chunk()
	return loaded_recordstore_v2
end

local function load_outbox_mailbox_adapter(): any
	if loaded_outbox_mailbox_adapter ~= nil then return loaded_outbox_mailbox_adapter end
	local module_environment = table.clone(Shim.environment)
	module_environment.script = { Parent = PlayerDataInitializer }
	local chunk = luau.load(fs.readFile("src/PlayerDataInitializer/RecordStoreOutboxMailboxAdapter.luau"), {
		debugName = "RecordStoreOutboxMailboxAdapter", environment = module_environment,
	})
	loaded_outbox_mailbox_adapter = chunk()
	return loaded_outbox_mailbox_adapter
end

local function load_outbox_consumer_adapter(): any
	if loaded_outbox_consumer_adapter ~= nil then return loaded_outbox_consumer_adapter end
	local module_environment = table.clone(Shim.environment)
	module_environment.script = { Parent = PlayerDataInitializer }
	local chunk = luau.load(fs.readFile("src/PlayerDataInitializer/RecordStoreOutboxConsumerAdapter.luau"), {
		debugName = "RecordStoreOutboxConsumerAdapter", environment = module_environment,
	})
	loaded_outbox_consumer_adapter = chunk()
	return loaded_outbox_consumer_adapter
end

local function load_receipt_processor(): any
	if loaded_receipt_processor ~= nil then return loaded_receipt_processor end
	local module_environment = table.clone(Shim.environment)
	module_environment.script = { Parent = PlayerDataInitializer }
	local chunk = luau.load(fs.readFile("src/PlayerDataInitializer/PurchaseReceiptProcessor.luau"), {
		debugName = "PurchaseReceiptProcessor",
		environment = module_environment,
	})
	loaded_receipt_processor = chunk()
	return loaded_receipt_processor
end

local function load_recordstore_sha256(): any
	if loaded_recordstore_sha256 ~= nil then return loaded_recordstore_sha256 end
	local chunk = luau.load(fs.readFile("src/PlayerDataInitializer/RecordStoreSHA256.luau"), {
		debugName = "RecordStoreSHA256", environment = Shim.environment,
	})
	loaded_recordstore_sha256 = chunk()
	return loaded_recordstore_sha256
end

local function load_purchase_authority_migration_runner(): any
	if loaded_purchase_authority_migration_runner ~= nil then return loaded_purchase_authority_migration_runner end
	local module_environment = table.clone(Shim.environment)
	module_environment.script = { Parent = PlayerDataInitializer }
	local chunk = luau.load(fs.readFile("src/PlayerDataInitializer/PurchaseAuthorityMigrationRunner.luau"), {
		debugName = "PurchaseAuthorityMigrationRunner", environment = module_environment,
	})
	loaded_purchase_authority_migration_runner = chunk()
	return loaded_purchase_authority_migration_runner
end

local function load_purchase_inventory_manifest(): any
	if loaded_purchase_inventory_manifest ~= nil then return loaded_purchase_inventory_manifest end
	local module_environment = table.clone(Shim.environment)
	module_environment.script = { Parent = PlayerDataInitializer }
	local chunk = luau.load(fs.readFile("src/PlayerDataInitializer/PurchaseInventoryManifest.luau"), {
		debugName = "PurchaseInventoryManifest", environment = module_environment,
	})
	loaded_purchase_inventory_manifest = chunk()
	return loaded_purchase_inventory_manifest
end

local function load_purchase_entitlement_authority(): any
	if loaded_purchase_entitlement_authority ~= nil then return loaded_purchase_entitlement_authority end
	local module_environment = table.clone(Shim.environment)
	module_environment.script = { Parent = PlayerDataInitializer }
	local chunk = luau.load(fs.readFile("src/PlayerDataInitializer/PurchaseEntitlementDataStoreAuthority.luau"), {
		debugName = "PurchaseEntitlementDataStoreAuthority", environment = module_environment,
	})
	loaded_purchase_entitlement_authority = chunk()
	return loaded_purchase_entitlement_authority
end

local function load_purchase_entitlement_coordinator(): any
	if loaded_purchase_entitlement_coordinator ~= nil then return loaded_purchase_entitlement_coordinator end
	local module_environment = table.clone(Shim.environment)
	module_environment.script = { Parent = PlayerDataInitializer }
	local chunk = luau.load(fs.readFile("src/PlayerDataInitializer/PurchaseEntitlementReceiptCoordinator.luau"), {
		debugName = "PurchaseEntitlementReceiptCoordinator", environment = module_environment,
	})
	loaded_purchase_entitlement_coordinator = chunk()
	return loaded_purchase_entitlement_coordinator
end

local function load_purchase_entitlement_handler(): any
	if loaded_purchase_entitlement_handler ~= nil then return loaded_purchase_entitlement_handler end
	local module_environment = table.clone(Shim.environment)
	module_environment.script = { Parent = PlayerDataInitializer }
	local chunk = luau.load(fs.readFile("src/PlayerDataInitializer/PurchaseEntitlementReceiptHandler.luau"), {
		debugName = "PurchaseEntitlementReceiptHandler", environment = module_environment,
	})
	loaded_purchase_entitlement_handler = chunk()
	return loaded_purchase_entitlement_handler
end

local function load_maintenance_atomic_tombstone(): any
	if loaded_maintenance_atomic_tombstone ~= nil then return loaded_maintenance_atomic_tombstone end
	local module_environment = table.clone(Shim.environment)
	module_environment.script = { Parent = PlayerDataInitializer }
	local chunk = luau.load(fs.readFile("src/PlayerDataInitializer/RecordStoreMaintenanceAtomicTombstone.luau"), {
		debugName = "RecordStoreMaintenanceAtomicTombstone", environment = module_environment,
	})
	loaded_maintenance_atomic_tombstone = chunk()
	return loaded_maintenance_atomic_tombstone
end

local function load_maintenance_roblox_adapter(): any
	if loaded_maintenance_roblox_adapter ~= nil then return loaded_maintenance_roblox_adapter end
	local module_environment = table.clone(Shim.environment)
	module_environment.script = { Parent = PlayerDataInitializer }
	local chunk = luau.load(fs.readFile("src/PlayerDataInitializer/RecordStoreMaintenanceRobloxAdapter.luau"), {
		debugName = "RecordStoreMaintenanceRobloxAdapter", environment = module_environment,
	})
	loaded_maintenance_roblox_adapter = chunk()
	return loaded_maintenance_roblox_adapter
end

local function load_purchase_datastore_authority(): any
	if loaded_purchase_datastore_authority ~= nil then return loaded_purchase_datastore_authority end
	local module_environment = table.clone(Shim.environment)
	module_environment.script = { Parent = PlayerDataInitializer }
	local chunk = luau.load(fs.readFile("src/PlayerDataInitializer/PurchaseDataStoreAuthority.luau"), {
		debugName = "PurchaseDataStoreAuthority", environment = module_environment,
	})
	loaded_purchase_datastore_authority = chunk()
	return loaded_purchase_datastore_authority
end

local function load_player_data_erasure(): any
	if loaded_player_data_erasure ~= nil then return loaded_player_data_erasure end
	local module_environment = table.clone(Shim.environment)
	module_environment.script = { Parent = PlayerDataInitializer }
	local chunk = luau.load(fs.readFile("src/PlayerDataInitializer/PlayerDataErasure.luau"), {
		debugName = "PlayerDataErasure",
		environment = module_environment,
	})
	loaded_player_data_erasure = chunk()
	return loaded_player_data_erasure
end

local ServerScriptService = {
	RecordStore = RecordStoreInstance,
	PlayerDataInitializer = PlayerDataInitializer,
	WaitForChild = function(self, name: string)
		local child = self[name]
		assert(child ~= nil, "module is not available: " .. name)
		return child
	end,
	FindFirstChild = function(self, name: string)
		return self[name]
	end,
}

local Players = {
	GetPlayerByUserId = function(_self, _user_id: number)
		return nil
	end,
}

local services = {
	Players = Players,
	DataStoreService = DataStoreService,
	HttpService = HttpService,
	MessagingService = MessagingService,
	ServerScriptService = ServerScriptService,
}

local game = {
	JobId = "",
	PlaceId = 0,
	GetService = function(_self, name: string)
		local service = services[name]
		if service == nil then
			error("service " .. tostring(name) .. " is not shimmed", 2)
		end
		return service
	end,
	BindToClose = function(_self, callback: () -> ())
		table.insert(bind_to_close, callback)
	end,
}

local function shim_require(target: any)
	if target == RecordStoreInstance then
		return load_record_store()
	end
	if target == PurchaseReceiptProcessorInstance then
		return load_receipt_processor()
	end
	if target == OutboxMailboxAdapterInstance then return load_outbox_mailbox_adapter() end
	if target == OutboxConsumerAdapterInstance then return load_outbox_consumer_adapter() end
	if target == RecordStoreV2Instance then return load_recordstore_v2() end
	if target == PlayerDataErasureInstance then return load_player_data_erasure() end
	if target == PurchaseDataStoreAuthorityInstance then return load_purchase_datastore_authority() end
	if target == PurchaseAuthorityMigrationRunnerInstance then return load_purchase_authority_migration_runner() end
	if target == RecordStoreSHA256Instance then return load_recordstore_sha256() end
	if target == PurchaseInventoryManifestInstance then return load_purchase_inventory_manifest() end
	if target == PurchaseEntitlementAuthorityInstance then return load_purchase_entitlement_authority() end
	if target == PurchaseEntitlementCoordinatorInstance then return load_purchase_entitlement_coordinator() end
	if target == PurchaseEntitlementHandlerInstance then return load_purchase_entitlement_handler() end
	if target == RecordStoreMaintenanceRobloxAdapterInstance then return load_maintenance_roblox_adapter() end
	if target == RecordStoreMaintenanceAtomicTombstoneInstance then return load_maintenance_atomic_tombstone() end
	return require(target)
end

Shim.environment = {
	game = game,
	task = task,
	Enum = Enum,
	DateTime = DateTime,
	Instance = Instance,
	script = script,
	require = shim_require,
}


function Shim.set_service(name: string, service: any)
	assert(loaded_module == nil, "services must be injected before RecordStore is loaded")
	assert(type(name) == "string" and name ~= "", "service name must be a non-empty string")
	assert(service ~= nil, "service must not be nil")
	services[name] = service
end
-- Returns the RecordStore module, loaded inside the shimmed environment.
function Shim.load(source_path: string?): any
	return load_record_store(source_path)
end

function Shim.load_scheduler(): any
	return load_scheduler()
end

-- Runs a Roblox-style script (e.g. the regression tests) inside the shimmed environment.
function Shim.run_script(path: string)
	local chunk = luau.load(fs.readFile(path), {
		debugName = path,
		environment = Shim.environment,
	})
	chunk()
end

-- Mirrors game:BindToClose, then exits right away instead of waiting for the
-- RecordStore background scheduler to wake up and notice the shutdown.
function Shim.close()
	for _, callback in bind_to_close do
		callback()
	end
	process.exit(0)
end

return Shim
