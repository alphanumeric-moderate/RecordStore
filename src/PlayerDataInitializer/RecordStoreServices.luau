--!strict
local Services = {}

local CoreModule = require(script.Parent.RecordStore)
local V2Factory = require(script.Parent.RecordStoreV2)
local Acceleration = require(script.Parent.RecordStoreV2Acceleration)
local MailboxMigration = require(script.Parent.RecordStoreMailboxV2Migration)
local MailboxMigrationAdapter = require(script.Parent.RecordStoreMailboxV2MigrationAdapter)
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

function Services.new(record_store: any?, raw_options: any?): any
	if raw_options ~= nil and type(raw_options) ~= "table" then
		error("RecordStore service options must be a table", 2)
	end

	local core = record_store or CoreModule
	if type(core) ~= "table" or type(core.new) ~= "function" or type(core.MailboxV2) ~= "table" then
		error("RecordStore service bundle requires the core RecordStore and embedded Mailbox V2", 2)
	end

	local options = raw_options or {}
	local raw_v2_options = options.v2
	if raw_v2_options ~= nil and type(raw_v2_options) ~= "table" then
		error("RecordStore service option 'v2' must be a table", 2)
	end

	local v2_options = table.clone(raw_v2_options or {})
	if v2_options.acceleration_module == nil then
		v2_options.acceleration_module = Acceleration
	end
	local v2 = V2Factory.new(core, core.MailboxV2, v2_options)

	local modules = table.freeze({
		RecordStoreV2 = V2Factory,
		RecordStoreV2Acceleration = Acceleration,
		RecordStoreMailboxV2Migration = MailboxMigration,
		RecordStoreMailboxV2MigrationAdapter = MailboxMigrationAdapter,
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
		V2 = v2,
		Acceleration = Acceleration,
		Modules = modules,
		MailboxMigration = table.freeze({
			Runner = MailboxMigration,
			Adapter = MailboxMigrationAdapter,
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
