# PR #56 blocker-candidate comparison

## Current relationship to PR #56

These files began as isolated candidate modules outside src/PlayerDataInitializer. Since this staging branch was created, PR #56 has advanced and now contains production-path counterparts for the main blocker candidates. This README is a comparison guide, **not** a statement that the candidate modules are still missing from PR #56.

Current PR #56 code-bearing snapshot checked for the documentation refresh: `63d30bde9c8ff7b5ce99b0f47fcf88e9cf502a31`. That snapshot passed the 23 explicitly named Lune regression steps plus Luau Type Check, Bencher Continuous Benchmarks, and RecordStore Update Latency. The Lune core runner also runs additional mock-backed fixtures. None of these checks is live Roblox service acceptance.

## Staging-to-production comparison observed

| Staged file | Current PR #56 production-path counterpart | Comparison |
|---|---|---|
| `RecordStoreApplicationInventory.luau` | `src/PlayerDataInitializer/RecordStoreApplicationInventory.luau` | Exact content match at the checked snapshots. |
| `RecordStoreMaintenanceAtomicTombstone.luau` | `src/PlayerDataInitializer/RecordStoreMaintenanceAtomicTombstone.luau` | Exact content match at the checked snapshots. |
| `PurchaseEntitlementReceiptCoordinator.luau` | `src/PlayerDataInitializer/PurchaseEntitlementReceiptCoordinator.luau` | Exact content match at the checked snapshots. |
| `PlayerDataErasureManifestBinding.luau` | `src/PlayerDataInitializer/PlayerDataErasureManifestBinding.luau` | Different revisions; the production-path file is longer. Compare behavior before porting anything. |
| `RecordStoreMaintenanceManifestBinding.luau` | `src/PlayerDataInitializer/RecordStoreMaintenanceManifestBinding.luau` | Different revisions; production binds the atomic tombstone helper. |
| `PurchaseInventoryManifest.luau` | `src/PlayerDataInitializer/PurchaseInventoryManifest.luau` | Different revisions; production has additional migration/checkpoint logic. |
| `PurchaseEntitlementDataStoreAuthority.luau` | `src/PlayerDataInitializer/PurchaseEntitlementDataStoreAuthority.luau` | Different revisions; production includes its SHA-256 dependency and more code. |
| `PurchaseEntitlementReceiptHandler.luau` | `src/PlayerDataInitializer/PurchaseEntitlementReceiptHandler.luau` | A production-path counterpart exists in PR #56. |

PR #56 also contains `RecordStoreSHA256`, the migration-runner changes, and dedicated Lune stages for the current production-path purchase, maintenance and RTBF modules.

## What this staging PR is still useful for

Use it to inspect test scenarios, candidate implementation history, and differences that are **actually missing** from the current PR #56 branch. For every alleged gap:

1. Compare the current PR #56 implementation and callers with the staged version.
2. Reproduce the gap with a focused regression that fails against PR #56.
3. Port only the missing behavior and its test into PR #56, then rerun strict analysis and regressions.
4. Do not copy a staged file over a more complete production-path version just because the module name matches.

The staged regression runner remains useful as a reference, but its result is not a substitute for running the current PR #56 workflow on the exact final head. No application inventory or deployed writer list should be fabricated from these generic modules.

## Explicit outstanding release gates

- Independently review the current PR #56 code and all changed callers.
- Supply and reconcile the actual game's historical PurchaseId/entitlement source and independent verifier.
- Inventory every deployed user-associated DataStore/scope/key family and direct writer/recreation path for RTBF.
- Configure real maintenance family catalogs, eligibility/dependency callbacks, authorization and durable fences.
- Accept multi-server, response-loss, crash/shutdown, receipt fulfillment, mixed-version/V3 rollout/rollback, storage retention and RTBF no-recreation against a real Roblox test experience.
- Collect comparable CodSpeed evidence. Previous reports warn about wall-time outside Macro Runners, runner-type mismatch and syscall-dominated workloads.

## Stack state

At the last metadata check, PR #57's base SHA remained `3eba6a193e156fb27c5dd64fb3b1fbc59088d245`, while PR #56's head had advanced to the documentation refresh commit `ebaa3b66cada38e7cdfb9b6d1e3259ce182e6020`. GitHub reported PR #57 as not mergeable. Refresh the stacked base and inspect the resulting diff before relying on PR #57 to represent outstanding work; do not merge the staging directory wholesale.
