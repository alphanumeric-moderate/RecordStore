--!nocheck
-- Usage (from the repository root): lune run bench/run_services_regression.luau
local Shim = require("./RobloxShim")
local initializer = Shim.environment.game:GetService("ServerScriptService"):WaitForChild("PlayerDataInitializer")
local Services = Shim.environment.require(initializer:WaitForChild("RecordStoreServices"))

local function expect(value, message)
	assert(value, message)
end

local core_calls = 0
local core = {
	new = function()
		core_calls += 1
		error("bundle construction opened a profile")
	end,
}
local raw_v2_options = table.freeze({})
local bundle = Services.new(core, table.freeze({ v2 = raw_v2_options }))
expect(bundle.Core == core and bundle.V2.Version == 2, "bundle did not bind the supplied core")
expect(core_calls == 0, "bundle activated persistence during construction")
expect(raw_v2_options.acceleration_module == nil, "bundle mutated caller-owned V2 options")
expect(bundle.Acceleration == nil and bundle.MailboxMigration == nil and bundle.Outbox == nil,
	"bundle exposed removed mailbox-only integration groups")
expect(bundle.V2.Mailbox == nil and bundle.Core.MailboxV2 == nil,
	"obsolete Mailbox V2 API remains visible")

local namespaces = {
	Purchases = {
		Authority = "PurchaseDataStoreAuthority", MigrationRunner = "PurchaseAuthorityMigrationRunner",
		InventoryManifest = "PurchaseInventoryManifest", ReceiptProcessor = "PurchaseReceiptProcessor",
		EntitlementAuthority = "PurchaseEntitlementDataStoreAuthority",
		EntitlementCoordinator = "PurchaseEntitlementReceiptCoordinator",
		EntitlementHandler = "PurchaseEntitlementReceiptHandler",
	},
	Maintenance = {
		Runner = "RecordStoreMaintenanceRunner", RobloxAdapter = "RecordStoreMaintenanceRobloxAdapter",
		DataStoreAdapter = "RecordStoreMaintenanceDataStoreAdapter",
		AtomicTombstone = "RecordStoreMaintenanceAtomicTombstone",
		ManifestBinding = "RecordStoreMaintenanceManifestBinding",
	},
	Erasure = {
		PlayerDataAdapter = "PlayerDataErasure", ApplicationInventory = "RecordStoreApplicationInventory",
		ManifestBinding = "PlayerDataErasureManifestBinding",
	},
}
for namespace, entries in pairs(namespaces) do
	expect(table.isfrozen(bundle[namespace]), namespace .. " namespace is mutable")
	for alias, module_name in pairs(entries) do
		local canonical_module = Shim.environment.require(initializer:WaitForChild(module_name))
		expect(bundle[namespace][alias] == canonical_module and bundle.Modules[module_name] == canonical_module,
			namespace .. "." .. alias .. " does not refer to the canonical module")
	end
end
for _, module_name in { "RecordStoreV2", "RecordStoreSHA256" } do
	expect(bundle.Modules[module_name] == Shim.environment.require(initializer:WaitForChild(module_name)),
		"incorrect module identity for " .. module_name)
end
expect(table.isfrozen(bundle) and table.isfrozen(bundle.Modules), "bundle/module registry is mutable")
expect(not pcall(function() bundle.Modules.RecordStoreV2 = {} end), "module registry allowed replacement")

local custom_bundle = Services.new(core, { v2 = table.freeze({}) })
expect(custom_bundle.V2.Version == 2, "custom bundle did not construct V2")
expect(custom_bundle.V2 ~= bundle.V2, "separate bundles share a V2 facade")
expect(bundle.V2.ApplyRuntimePolicy({ revision = 2, max_dirty_age_seconds = 120 }) == "success",
	"bundle could not update its V2 policy")
expect(bundle.V2.GetRuntimeSnapshot().policy.revision == 2
	and custom_bundle.V2.GetRuntimeSnapshot().policy.revision == 1,
	"updating one bundle changed another bundle's policy")

for _, invalid in { false, 1, "options" } do
	expect(not pcall(Services.new, core, invalid), "bundle accepted non-table options")
	expect(not pcall(Services.new, core, { v2 = invalid }), "bundle accepted non-table V2 options")
end
for _, invalid in { false, {}, { new = true } } do
	expect(not pcall(Services.new, invalid), "bundle accepted a core without the required factory")
end
expect(not pcall(Services.new, nil), "bundle accepted a missing core")
expect(Services.new(core).V2.Version == 2, "omitted options did not initialize the V2 facade")
expect(core_calls == 0, "a service bundle unexpectedly opened a profile")

print("[Services] retained module identity, option ownership, core binding and policy isolation passed")
