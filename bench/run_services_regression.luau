--!nocheck
-- Usage (from the repository root): lune run bench/run_services_regression.luau
local Shim = require("./RobloxShim")
local initializer = Shim.environment.game:GetService("ServerScriptService"):WaitForChild("PlayerDataInitializer")
local Services = Shim.environment.require(initializer:WaitForChild("RecordStoreServices"))

local function expect(value, message)
	assert(value, message)
end

-- Construction must bind the supplied core without opening profiles or creating
-- mailboxes. Observe mailbox creation only when the caller explicitly asks.
local mailbox_calls = {}
local core_calls = 0
local core = {
	new = function() core_calls += 1; error("bundle construction opened a profile") end,
	MailboxV2 = {
		new = function(store, owner, options)
			local mailbox = { store = store, owner = owner, options = options }
			table.insert(mailbox_calls, mailbox)
			return mailbox
		end,
	},
}
local raw_v2_options = table.freeze({})
local bundle = Services.new(core, table.freeze({ v2 = raw_v2_options }))
expect(bundle.Core == core and bundle.V2.Version == 2, "bundle did not bind the supplied core")
expect(core_calls == 0 and #mailbox_calls == 0, "bundle activated persistence during construction")
expect(raw_v2_options.acceleration_module == nil, "bundle mutated the caller's V2 options")
expect(bundle.V2.Acceleration == bundle.Acceleration, "default acceleration module was not forwarded to V2")

local namespaces = {
	MailboxMigration = {
		Runner = "RecordStoreMailboxV2Migration", Adapter = "RecordStoreMailboxV2MigrationAdapter",
	},
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
	Outbox = { ConsumerAdapter = "RecordStoreOutboxConsumerAdapter", MailboxAdapter = "RecordStoreOutboxMailboxAdapter" },
}
for namespace, entries in pairs(namespaces) do
	expect(table.isfrozen(bundle[namespace]), namespace .. " namespace is mutable")
	for alias, module_name in pairs(entries) do
		local canonical_module = Shim.environment.require(initializer:WaitForChild(module_name))
		expect(bundle[namespace][alias] == canonical_module and bundle.Modules[module_name] == canonical_module,
			namespace .. "." .. alias .. " does not refer to the canonical module")
	end
end
for _, module_name in { "RecordStoreV2", "RecordStoreV2Acceleration", "RecordStoreSHA256" } do
	expect(bundle.Modules[module_name] == Shim.environment.require(initializer:WaitForChild(module_name)),
		"incorrect module identity for " .. module_name)
end
expect(table.isfrozen(bundle) and table.isfrozen(bundle.Modules), "bundle/module registry is mutable")
expect(not pcall(function() bundle.Outbox.MailboxAdapter = {} end), "namespace allowed adapter replacement")

local store, owner = {}, {}
local mailbox = bundle.V2.Mailbox.new(store, owner)
expect(mailbox == mailbox_calls[1] and mailbox.store == store and mailbox.owner == owner,
	"V2 constructed a mailbox against a different core")
local allowed = mailbox.options.activation_guard("enqueue")
expect(allowed == false, "default bundle enabled Mailbox V2 without an application guard")

local custom_acceleration = table.freeze({ new = function() error("acceleration was automatically started") end })
local active_record = {}
local guard_calls = 0
local custom_options = table.freeze({
	acceleration_module = custom_acceleration,
	mailbox_activation_guard = function(record, operation)
		expect(record == active_record and operation == "enqueue", "bundle lost activation guard arguments")
		guard_calls += 1
		return true, "explicit activation"
	end,
})
local custom_bundle = Services.new(core, { v2 = custom_options })
expect(custom_bundle.V2.Acceleration == custom_acceleration, "bundle replaced explicit acceleration configuration")
expect(custom_bundle.Acceleration == bundle.Acceleration, "custom V2 options changed the canonical module registry")
expect(guard_calls == 0, "constructing the bundle invoked the application activation guard")
local mailbox_options = table.freeze({ active_record = active_record })
local custom_mailbox = custom_bundle.V2.Mailbox.new(store, owner, mailbox_options)
local custom_allowed, reason = custom_mailbox.options.activation_guard("enqueue")
expect(custom_allowed == true and reason == "explicit activation" and guard_calls == 1,
	"V2 did not use the supplied application activation guard")
expect(mailbox_options.activation_guard == nil and mailbox_options.encode == nil,
	"creating a mailbox mutated caller-owned options")

-- Each service graph owns its V2 policy even when it uses the same core.
expect(bundle.V2 ~= custom_bundle.V2, "separate bundles share a V2 facade")
expect(bundle.V2.ApplyRuntimePolicy({ revision = 2, max_dirty_age_seconds = 120 }) == "success",
	"bundle could not update its V2 policy")
expect(bundle.V2.GetRuntimeSnapshot().policy.revision == 2
	and custom_bundle.V2.GetRuntimeSnapshot().policy.revision == 1,
	"updating one bundle changed another bundle's policy")

for _, invalid in { false, 1, "options" } do
	expect(not pcall(Services.new, core, invalid), "bundle accepted non-table options")
	expect(not pcall(Services.new, core, { v2 = invalid }), "bundle accepted non-table V2 options")
end
for _, invalid in {
	false, {}, { new = true, MailboxV2 = {} }, { new = function() end },
	{ new = function() end, MailboxV2 = false }, { new = function() end, MailboxV2 = {} },
} do
	expect(not pcall(Services.new, invalid), "bundle accepted a core without the required factory/mailbox API")
end
expect(not pcall(Services.new, nil), "bundle accepted a missing core")
expect(Services.new(core).V2.Acceleration == bundle.Acceleration, "omitted options did not use defaults")
expect(core_calls == 0, "a service bundle unexpectedly opened a profile")

print("[Services] module identity, option ownership, core binding, activation defaults and policy isolation passed")
