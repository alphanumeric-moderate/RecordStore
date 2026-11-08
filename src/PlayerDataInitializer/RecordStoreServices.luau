--!strict
local Services = {}

-- The registry remains separate from RecordStore to keep the require graph acyclic.
local V1Factory = require(script.Parent.RecordStoreV1)
local Acceleration = require(script.Parent.RecordStoreAcceleration)
local LegacyMailboxMigration = require(script.Parent.RecordStoreLegacyMailboxMigration)
local LegacyMailboxMigrationAdapter = require(script.Parent.RecordStoreLegacyMailboxMigrationAdapter)
local PurchaseAuthority = require(script.Parent.PurchaseDataStoreAuthority)
local PurchaseMigrationRunner = require(script.Parent.PurchaseAuthorityMigrationRunner)
local PurchaseManifest = require(script.Parent.PurchaseInventoryManifest)
local PurchaseReceiptProcessor = require(script.Parent.PurchaseReceiptProcessor)
local EntitlementAuthority = require(script.Parent.PurchaseEntitlementDataStoreAuthority)
local EntitlementCoordinator = require(script.Parent.PurchaseEntitlementReceiptCoordinator)
local EntitlementHandler = require(script.Parent.PurchaseEntitlementReceiptHandler)
local MaintenanceRunner = require(script.Parent.RecordStoreMaintenanceRunner)
local MaintenanceRobloxAdapter = require(script.Parent.RecordStoreMaintenanceRobloxAdapter)
local MaintenanceDataStoreAdapter = require(script.Parent.RecordStoreMaintenanceDataStoreAdapter)
local MaintenanceAtomicTombstone = require(script.Parent.RecordStoreMaintenanceAtomicTombstone)
local MaintenanceManifestBinding = require(script.Parent.RecordStoreMaintenanceManifestBinding)
local ApplicationInventory = require(script.Parent.RecordStoreApplicationInventory)
local PlayerDataErasure = require(script.Parent.PlayerDataErasure)
local ErasureManifestBinding = require(script.Parent.PlayerDataErasureManifestBinding)
local OutboxConsumerAdapter = require(script.Parent.RecordStoreOutboxConsumerAdapter)
local OutboxMailboxAdapter = require(script.Parent.RecordStoreOutboxMailboxAdapter)
local SHA256 = require(script.Parent.RecordStoreSHA256)

function Services.new(record_store: any, raw_options: any?): any
	if raw_options ~= nil and type(raw_options) ~= "table" then
		error("RecordStore service options must be a table", 2)
	end

	local core = record_store
	if type(core) ~= "table" or type(core.new) ~= "function" or type(core.Mailbox) ~= "table" then
		error("RecordStore service bundle requires the core RecordStore and embedded Mailbox", 2)
	end

	local options = raw_options or {}
	local raw_v1_options = options.v1
	if raw_v1_options ~= nil and type(raw_v1_options) ~= "table" then
		error("RecordStore service option 'v1' must be a table", 2)
	end

	local v1_options = table.clone(raw_v1_options or {})
	if v1_options.acceleration_module == nil then
		v1_options.acceleration_module = Acceleration
	end
	local v1 = V1Factory.new(core, core.Mailbox, v1_options)

	local modules = table.freeze({
		RecordStoreV1 = V1Factory,
		RecordStoreAcceleration = Acceleration,
		RecordStoreLegacyMailboxMigration = LegacyMailboxMigration,
		RecordStoreLegacyMailboxMigrationAdapter = LegacyMailboxMigrationAdapter,
		PurchaseDataStoreAuthority = PurchaseAuthority,
		PurchaseAuthorityMigrationRunner = PurchaseMigrationRunner,
		PurchaseInventoryManifest = PurchaseManifest,
		PurchaseReceiptProcessor = PurchaseReceiptProcessor,
		PurchaseEntitlementDataStoreAuthority = EntitlementAuthority,
		PurchaseEntitlementReceiptCoordinator = EntitlementCoordinator,
		PurchaseEntitlementReceiptHandler = EntitlementHandler,
		RecordStoreMaintenanceRunner = MaintenanceRunner,
		RecordStoreMaintenanceRobloxAdapter = MaintenanceRobloxAdapter,
		RecordStoreMaintenanceDataStoreAdapter = MaintenanceDataStoreAdapter,
		RecordStoreMaintenanceAtomicTombstone = MaintenanceAtomicTombstone,
		RecordStoreMaintenanceManifestBinding = MaintenanceManifestBinding,
		RecordStoreApplicationInventory = ApplicationInventory,
		PlayerDataErasure = PlayerDataErasure,
		PlayerDataErasureManifestBinding = ErasureManifestBinding,
		RecordStoreOutboxConsumerAdapter = OutboxConsumerAdapter,
		RecordStoreOutboxMailboxAdapter = OutboxMailboxAdapter,
		RecordStoreSHA256 = SHA256,
	})

	return table.freeze({
		Core = core,
		V1 = v1,
		Acceleration = Acceleration,
		Modules = modules,
		LegacyMailboxMigration = table.freeze({
			Runner = LegacyMailboxMigration,
			Adapter = LegacyMailboxMigrationAdapter,
		}),
		Purchases = table.freeze({
			Authority = PurchaseAuthority,
			MigrationRunner = PurchaseMigrationRunner,
			InventoryManifest = PurchaseManifest,
			ReceiptProcessor = PurchaseReceiptProcessor,
			EntitlementAuthority = EntitlementAuthority,
			EntitlementCoordinator = EntitlementCoordinator,
			EntitlementHandler = EntitlementHandler,
		}),
		Maintenance = table.freeze({
			Runner = MaintenanceRunner,
			RobloxAdapter = MaintenanceRobloxAdapter,
			DataStoreAdapter = MaintenanceDataStoreAdapter,
			AtomicTombstone = MaintenanceAtomicTombstone,
			ManifestBinding = MaintenanceManifestBinding,
		}),
		Erasure = table.freeze({
			PlayerDataAdapter = PlayerDataErasure,
			ApplicationInventory = ApplicationInventory,
			ManifestBinding = ErasureManifestBinding,
		}),
		Outbox = table.freeze({
			ConsumerAdapter = OutboxConsumerAdapter,
			MailboxAdapter = OutboxMailboxAdapter,
		}),
	})
end

return table.freeze(Services)
