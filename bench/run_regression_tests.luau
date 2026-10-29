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
	"tests/RecordStore_TransactionRecoveryRegression.server.luau",
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
	"src/InfiniteMath/init.luau",
	"src/InfiniteMath/Int.luau",
	"src/InfiniteMath/Values/Suffixes.luau",
	"src/InfiniteMath/Values/FullNames.luau",
	"src/PlayerDataInitializer/InfiniteMathValue.luau",
	"bench/infinimath_shim.luau",
	"src/PlayerDataInitializer/init.server.luau",
	"src/PlayerDataInitializer/PlayerData.luau",
	"tests/PlayerDataSetRegression.server.luau",
	"tests/IntegerInfinityValueRegression.server.luau",
	"tests/InfiniteMathValueRegression.server.luau",
	"tests/InfiniteMathFormattingRegression.server.luau",
	"tests/RecordStore_EventQueueRegression.server.luau",
	"tests/PurchaseReceiptProcessorRegression.server.luau",
	"bench/playerdata_set_harness.luau",
	"bench/playerdata_set_paths.bench.luau",
	"bench/playerdata_transactions.bench.luau",
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

local InfiniteMath = require("./infinimath_shim").load_infinitemath()
assert(InfiniteMath.format(999) == "999")
assert(InfiniteMath.format(1000) == "1K")
assert(InfiniteMath.format(1250) == "1.25K")
assert(InfiniteMath.format(999_999) == "1M")
assert(InfiniteMath.format(1_000_000_000_000) == "1T")
assert(InfiniteMath.format(-1_500_000_000) == "-1.5B")
assert(InfiniteMath.format(1_000_000_000_000_000) == "1Q")
assert(InfiniteMath.format(math.huge) == "∞")
assert(InfiniteMath.format(-math.huge) == "-∞")
assert(InfiniteMath.format(0 / 0) == "NaN")
assert(InfiniteMath.format(1_200_000, { decimals = 3, trim_trailing_zeros = false }) == "1.200M")
assert(InfiniteMath.format(1_200_000, { decimals = 3 }) == "1.2M")
assert(InfiniteMath.format(1e36) == "1UD")
assert(InfiniteMath.formatInteger("123456789012345678901234567890123456789") == "123.46UD")
assert(InfiniteMath.formatScientific(1, 1.25, "12") == "1.25T")
assert(InfiniteMath.formatScientific(1, 1.259, "12", { decimals = 2 }) == "1.26T")
local huge_exponent = string.rep("9", 80)
assert(InfiniteMath.formatScientific(1, 1.25, huge_exponent, { decimals = 3, trim_trailing_zeros = false }) == "1.250e+" .. huge_exponent)
assert(not pcall(function() InfiniteMath.formatScientific(1, "1.25", "12") end))
assert(not pcall(function() InfiniteMath.formatScientific(1, 10, "12") end))
assert(not pcall(function() InfiniteMath.formatScientific(1, 1.25, 12) end))
assert(not pcall(function() InfiniteMath.format(1, { decimals = 7 }) end))

Shim.run_script("bench/run_services_regression.luau")
Shim.run_script("bench/run_outbox_adapter_unit_regression.luau")
Shim.run_script("tests/RecordStore_OpenCorrupt_CompatibilityRegression.server.luau")
Shim.run_script("tests/RecordStore_EventQueueRegression.server.luau")
Shim.run_script("tests/RecordStore_NonFiniteNumbersRegression.server.luau")
Shim.run_script("tests/RecordStore_LegacyPayloadRegression.server.luau")
Shim.run_script("tests/RecordStore_UnknownSaveRecoveryRegression.server.luau")
Shim.run_script("tests/RecordStore_TransactionRecoveryRegression.server.luau")
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
