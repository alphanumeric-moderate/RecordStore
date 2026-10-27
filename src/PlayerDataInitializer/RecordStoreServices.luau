--!strict
local Services = {}

local function load_module(name: string): any
	return require(script.Parent:WaitForChild(name))
end

function Services.new(record_store: any?, raw_options: any?): any
	if raw_options ~= nil and type(raw_options) ~= "table" then
		error("RecordStore service options must be a table", 2)
	end

	local core = record_store
	if core == nil then
		core = load_module("RecordStore")
	end
	if type(core) ~= "table" or type(core.new) ~= "function" or type(core.MailboxV2) ~= "table" then
		error("RecordStore service bundle requires the core RecordStore and embedded Mailbox V2", 2)
	end

	local options = raw_options or {}
	local raw_v2_options = options.v2
	if raw_v2_options ~= nil and type(raw_v2_options) ~= "table" then
		error("RecordStore service option 'v2' must be a table", 2)
	end

	local v2_factory = load_module("RecordStoreV2")
	local acceleration = load_module("RecordStoreV2Acceleration")
	local v2_options = table.clone(raw_v2_options or {})
	if v2_options.acceleration_module == nil then
		v2_options.acceleration_module = acceleration
	end
	local v2 = v2_factory.new(core, core.MailboxV2, v2_options)

	local mailbox_migration = load_module("RecordStoreMailboxV2Migration")
	local mailbox_migration_adapter = load_module("RecordStoreMailboxV2MigrationAdapter")
	local purchase_authority = load_module("PurchaseDataStoreAuthority")
	local purchase_migration_runner = load_module("PurchaseAuthorityMigrationRunner")
	local purchase_inventory_manifest = load_module("PurchaseInventoryManifest")
	local purchase_receipt_processor = load_module("PurchaseReceiptProcessor")
	local entitlement_authority = load_module("PurchaseEntitlementDataStoreAuthority")
	local entitlement_coordinator = load_module("PurchaseEntitlementReceiptCoordinator")
	local entitlement_handler = load_module("PurchaseEntitlementReceiptHandler")
	local maintenance_runner = load_module("RecordStoreMaintenanceRunner")
	local maintenance_roblox_adapter = load_module("RecordStoreMaintenanceRobloxAdapter")
	local maintenance_datastore_adapter = load_module("RecordStoreMaintenanceDataStoreAdapter")
	local maintenance_tombstone = load_module("RecordStoreMaintenanceAtomicTombstone")
	local maintenance_binding = load_module("RecordStoreMaintenanceManifestBinding")
	local application_inventory = load_module("RecordStoreApplicationInventory")
	local player_erasure = load_module("PlayerDataErasure")
	local erasure_binding = load_module("PlayerDataErasureManifestBinding")
	local outbox_consumer = load_module("RecordStoreOutboxConsumerAdapter")
	local outbox_mailbox = load_module("RecordStoreOutboxMailboxAdapter")
	local sha256 = load_module("RecordStoreSHA256")

	local modules = table.freeze({
		RecordStoreV2 = v2_factory,
		RecordStoreV2Acceleration = acceleration,
		RecordStoreMailboxV2Migration = mailbox_migration,
		RecordStoreMailboxV2MigrationAdapter = mailbox_migration_adapter,
		PurchaseDataStoreAuthority = purchase_authority,
		PurchaseAuthorityMigrationRunner = purchase_migration_runner,
		PurchaseInventoryManifest = purchase_inventory_manifest,
		PurchaseReceiptProcessor = purchase_receipt_processor,
		PurchaseEntitlementDataStoreAuthority = entitlement_authority,
		PurchaseEntitlementReceiptCoordinator = entitlement_coordinator,
		PurchaseEntitlementReceiptHandler = entitlement_handler,
		RecordStoreMaintenanceRunner = maintenance_runner,
		RecordStoreMaintenanceRobloxAdapter = maintenance_roblox_adapter,
		RecordStoreMaintenanceDataStoreAdapter = maintenance_datastore_adapter,
		RecordStoreMaintenanceAtomicTombstone = maintenance_tombstone,
		RecordStoreMaintenanceManifestBinding = maintenance_binding,
		RecordStoreApplicationInventory = application_inventory,
		PlayerDataErasure = player_erasure,
		PlayerDataErasureManifestBinding = erasure_binding,
		RecordStoreOutboxConsumerAdapter = outbox_consumer,
		RecordStoreOutboxMailboxAdapter = outbox_mailbox,
		RecordStoreSHA256 = sha256,
	})

	return table.freeze({
		Core = core,
		V2 = v2,
		Acceleration = acceleration,
		Modules = modules,
		MailboxMigration = table.freeze({
			Runner = mailbox_migration,
			Adapter = mailbox_migration_adapter,
		}),
		Purchases = table.freeze({
			Authority = purchase_authority,
			MigrationRunner = purchase_migration_runner,
			InventoryManifest = purchase_inventory_manifest,
			ReceiptProcessor = purchase_receipt_processor,
			EntitlementAuthority = entitlement_authority,
			EntitlementCoordinator = entitlement_coordinator,
			EntitlementHandler = entitlement_handler,
		}),
		Maintenance = table.freeze({
			Runner = maintenance_runner,
			RobloxAdapter = maintenance_roblox_adapter,
			DataStoreAdapter = maintenance_datastore_adapter,
			AtomicTombstone = maintenance_tombstone,
			ManifestBinding = maintenance_binding,
		}),
		Erasure = table.freeze({
			PlayerDataAdapter = player_erasure,
			ApplicationInventory = application_inventory,
			ManifestBinding = erasure_binding,
		}),
		Outbox = table.freeze({
			ConsumerAdapter = outbox_consumer,
			MailboxAdapter = outbox_mailbox,
		}),
	})
end

return table.freeze(Services)
