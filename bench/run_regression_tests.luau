--!nocheck
-- Runs RecordStore regressions and syntax-checks the PlayerData modules under Lune.
-- Usage (from the repository root): lune run bench/run_regression_tests.luau; high-range adapter suites run as separate CodSpeed entries.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Shim = require("./RobloxShim")

for _, path in {
	"src/PlayerDataInitializer/RecordStore.luau",
	"src/PlayerDataInitializer/RecordStoreServices.luau",
	"src/PlayerDataInitializer/RecordStoreMaintenanceDataStoreAdapter.luau",
	"bench/run_scheduler_bugfix_regression.luau",
	"src/PlayerDataInitializer/PurchaseReceiptProcessor.luau",
	"src/PlayerDataInitializer/PurchaseDataStoreAuthority.luau",
	"src/PlayerDataInitializer/PurchaseAuthorityMigrationRunner.luau",
	"tests/PurchaseDataStoreAuthorityRegression.server.luau",
	"tests/PurchaseAuthorityMigrationRunnerRegression.server.luau",
	"tests/RecordStore_QuarantineFenceRegression.server.luau",
	"src/PlayerDataInitializer/RecordStoreOutboxMailboxAdapter.luau",
	"src/PlayerDataInitializer/RecordStoreOutboxConsumerAdapter.luau",
	"tests/RecordStore_OutboxConsumerAdapterRegression.server.luau",
	"src/PlayerDataInitializer/RecordStoreV2.luau",
	"src/PlayerDataInitializer/RecordStoreV2Acceleration.luau",
	"src/PlayerDataInitializer/RecordStoreMailboxV2Migration.luau",
	"src/PlayerDataInitializer/RecordStoreMailboxV2MigrationAdapter.luau",
	"bench/run_mailbox_v2_migration_regression.luau",
	"src/PlayerDataInitializer/PlayerDataErasure.luau",
	"src/PlayerDataInitializer/RecordStoreMaintenanceRunner.luau",
	"src/PlayerDataInitializer/RecordStoreMaintenanceRobloxAdapter.luau",
	"tests/RecordStoreMaintenanceRobloxAdapterRegression.server.luau",
	"bench/DeterministicCrashSimulator.luau",
	"bench/run_erasure_regression.luau",
	"bench/run_crash_simulator_regression.luau",
	"bench/run_acceleration_regression.luau",
	"bench/run_offline_maintenance_runner_regression.luau",
	"tests/RecordStoreV2NonSaveServicesRegression.server.luau",
	"tests/RecordStore_OutboxMailboxAdapterRegression.server.luau",
	"src/PlayerDataInitializer/PlayerDataCore.luau",
	"src/PlayerDataInitializer/IntegerInfinityValue.luau",
	"src/AlyaNum/init.luau",
	"src/PlayerDataInitializer/AlyaNumFormatter.luau",
	"src/PlayerDataInitializer/AlyaNumValue.luau",
	"bench/alyanum_shim.luau",
	"tests/AlyaNumValueRegression.server.luau",
	"tests/AlyaNumFormattingRegression.server.luau",
	"bench/run_alyanum_regression_tests.luau",
	"bench/run_alyanumvalue_regression_tests.luau",
	"bench/alyanum.bench.luau",
	"bench/alyanumvalue.bench.luau",
	"src/PlayerDataInitializer/init.server.luau",
	"src/PlayerDataInitializer/PlayerData.luau",
	"tests/PlayerDataSetRegression.server.luau",
	"tests/IntegerInfinityValueRegression.server.luau",
	"tests/RecordStore_EventQueueRegression.server.luau",
	"tests/RecordStore_TransactionMutationReconciliationRegression.server.luau",
	"tests/PurchaseReceiptProcessorRegression.server.luau",
	"bench/playerdata_set_harness.luau",
	"bench/playerdata_set_paths.bench.luau",
	"bench/playerdata_startup_common.luau",
	"bench/playerdata_startup_eager.bench.luau",
	"bench/playerdata_startup_lazy.bench.luau",
} do
	local chunk = luau.load(fs.readFile(path), {
		debugName = path,
	})
	assert(type(chunk) == "function", ("failed to compile %s"):format(path))
end

-- Exercise the same normalizer used by PlayerDataCore, without relying on
-- Roblox Instance behavior. The separate Studio Script covers NumberValue.
local integer_infinity_chunk = luau.load(fs.readFile("src/PlayerDataInitializer/IntegerInfinityValue.luau"), {
	debugName = "IntegerInfinityValue",
})
local IntegerInfinityValue = integer_infinity_chunk()
assert(IntegerInfinityValue.normalize(math.huge, "nearest") == math.huge, "positive infinity normalization failed")
assert(IntegerInfinityValue.normalize(-math.huge, "nearest") == -math.huge, "negative infinity normalization failed")
assert(math.isnan(IntegerInfinityValue.normalize(0 / 0, "nearest")), "NaN was normalized to a finite number")
assert(IntegerInfinityValue.normalize(17.4, "nearest") == 17, "finite rounding changed")
assert(IntegerInfinityValue.normalize(-17.6, "nearest") == -18, "negative finite rounding changed")

local AlyaNum, AlyaNumFormatter = require("./alyanum_shim").load_alyanum()
assert(AlyaNumFormatter.format(999) == "999")
assert(AlyaNumFormatter.format(1000) == "1K")
assert(AlyaNumFormatter.format(1250) == "1.25K")
assert(AlyaNumFormatter.format(999_999) == "1M")
assert(AlyaNumFormatter.format(1_000_000_000_000) == "1T")
assert(AlyaNumFormatter.format(-1_500_000_000) == "-1.5B")
assert(AlyaNumFormatter.format(math.huge) == "Infinity")
assert(AlyaNumFormatter.format(-math.huge) == "-Infinity")
assert(AlyaNumFormatter.format(0 / 0) == "NaN")
assert(AlyaNumFormatter.format(1_200_000, { decimals = 3, trim_trailing_zeros = false }) == "1.200M")
assert(AlyaNumFormatter.format(1_200_000, { decimals = 3 }) == "1.2M")
local high_range = AlyaNum.new(10):pow(1000)
assert(AlyaNum.toNumber(high_range) == math.huge)
assert(AlyaNumFormatter.format(high_range) ~= "")


Shim.run_script("bench/run_services_regression.luau")
Shim.run_script("bench/run_outbox_adapter_unit_regression.luau")
Shim.run_script("tests/RecordStore_OpenCorrupt_CompatibilityRegression.server.luau")
Shim.run_script("tests/RecordStore_EventQueueRegression.server.luau")
Shim.run_script("tests/RecordStore_TransactionMutationReconciliationRegression.server.luau")
Shim.run_script("tests/RecordStore_NonFiniteNumbersRegression.server.luau")
Shim.run_script("tests/RecordStore_LegacyPayloadRegression.server.luau")
Shim.run_script("tests/RecordStore_UnknownSaveRecoveryRegression.server.luau")
Shim.run_script("tests/PurchaseReceiptProcessorRegression.server.luau")
Shim.run_script("tests/PurchaseDataStoreAuthorityRegression.server.luau")
Shim.run_script("tests/PurchaseAuthorityMigrationRunnerRegression.server.luau")
Shim.run_script("tests/RecordStore_QuarantineFenceRegression.server.luau")
Shim.run_script("tests/RecordStore_OutboxMailboxAdapterRegression.server.luau")
Shim.run_script("tests/RecordStore_OutboxConsumerAdapterRegression.server.luau")
Shim.run_script("tests/RecordStoreV2NonSaveServicesRegression.server.luau")
Shim.run_script("bench/run_mailbox_v2_migration_regression.luau")
Shim.run_script("bench/run_scheduler_bugfix_regression.luau")
Shim.run_script("tests/RecordStore_NonSaveRoadmapRegression.server.luau")
Shim.run_script("bench/run_erasure_regression.luau")
Shim.run_script("bench/run_crash_simulator_regression.luau")
Shim.run_script("bench/run_acceleration_regression.luau")
Shim.run_script("tests/RecordStoreMaintenanceRobloxAdapterRegression.server.luau")
Shim.close()
