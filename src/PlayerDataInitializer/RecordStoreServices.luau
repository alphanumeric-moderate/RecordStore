--!strict
local Services = {}

-- This registry remains separate from RecordStore to keep the require graph acyclic.
local V2Factory = require(script.Parent.RecordStoreV2)
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
local SHA256 = require(script.Parent.RecordStoreSHA256)

function Services.new(record_store: any, raw_options: any?): any
	if raw_options ~= nil and type(raw_options) ~= "table" then
		error("RecordStore service options must be a table", 2)
	end

	local core = record_store
	if type(core) ~= "table" or type(core.new) ~= "function" then
		error("RecordStore service bundle requires RecordStore core", 2)
	end

	local options = raw_options or {}
	local raw_v2_options = options.v2
	if raw_v2_options ~= nil and type(raw_v2_options) ~= "table" then
		error("RecordStore service option 'v2' must be a table", 2)
	end

	local v2_options = table.clone(raw_v2_options or {})
	local v2 = V2Factory.new(core, v2_options)
	local modules = table.freeze({
		RecordStoreV2 = V2Factory,
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
		RecordStoreSHA256 = SHA256,
	})

	return table.freeze({
		Core = core,
		V2 = v2,
		Modules = modules,
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
	})
end

return table.freeze(Services)
