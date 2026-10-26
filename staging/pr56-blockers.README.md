# PR #56 blocker candidates

These modules are intentionally staged outside `src/PlayerDataInitializer`. They are not required by RecordStore or PlayerDataCore, and PR #57 is stacked on PR #56 rather than modifying its branch. Keep each candidate isolated until its regression tests, strict Luau analysis, source review and application contract review pass.

## Candidate modules

- `RecordStoreApplicationInventory.luau`: validates a bounded RTBF inventory manifest. It checks exact store/scope locators, safe key templates, external-inventory evidence references, reciprocal family/writer coverage, and generation-aware same-mutation fence declarations. `validate` proves structure only. `verify_for_activation` also requires live Roblox acceptance evidence plus an independent verifier. Field attestations cannot prove that a manifest is exhaustive by themselves.

- `RecordStoreMaintenanceAtomicTombstone.luau`: applies a same-key UpdateAsync tombstone only when the current row generation and row-local durable maintenance job fence match, policy and dependency callbacks return true without yielding, and the tombstone advances generation while identifying the same job and observed generation. Ambiguous commits are reconciled through uncached readback. Its policy callbacks must be pure and must only use dependency facts that are safe to recheck from the current record. Cross-key dependencies cannot be made atomic by this helper. Every writer and recreation path must honor the durable tombstone/fence.

- `PurchaseInventoryManifest.luau`: validates a source revision, immutable snapshot ID, stable ordered PurchaseId/PlayerId/ProductId inventory, row count, rolling digest, archived/deleted account coverage, legacy receipt paths, source end-of-inventory proof, conflict reconciliation and reviewer evidence. Import-source verification and post-migration activation verification are separate. The rolling digest is not cryptographic; an independent source export/verifier remains mandatory.

- `PurchaseEntitlementDataStoreAuthority.luau`: optional non-expiring per-player lifetime-entitlement authority for product types that really require uniqueness. It is separate from the globally keyed PurchaseId authority. It exposes reserve/commit/backfill/status operations, uncached status reads, request-budget/shared-governor hooks, identity collision checks and ambiguous-write reconciliation.

- `PurchaseEntitlementReceiptCoordinator.luau`: coordinates global PurchaseId claiming, lifetime-entitlement reservation, an idempotent profile grant, entitlement commit and terminal purchase commit. It defers on unknown outcomes and competing pending entitlements, and only acknowledges after durable terminal status is confirmed. The application must map only true lifetime-unique products and supply a stable, idempotent profile-grant adapter.

## Check order before integration

1. Run the dedicated Lune regression runner and isolated strict Luau analysis on the exact candidate head. Review every new finding and test negative paths as well as happy paths.
2. Independently review the candidate diff. Passing fake-store tests proves only the simulated contract, not Roblox DataStore production semantics.
3. Obtain the actual game's reviewed purchase inventory, source manifest and verifier. This repository does not contain the complete historical PurchaseId export.
4. Independently inventory every user-associated DataStore/scope/key family, all direct writers and recreation paths, and exact RTBF templates. This repository does not contain the complete game source tree, so it cannot generate that inventory honestly.
5. Configure application-owned maintenance eligibility/dependency rules. Verify that the atomic generation and job fence are enforced in the protected mutation, not only by a preflight check.
6. Run live Roblox multi-server, response-loss, shutdown, rollout/rollback, purchase fulfillment, retention and no-recreation acceptance tests.
7. Integrate components into RecordStore one at a time only after their relevant tests and review pass. Leave unrelated candidate modules staged until independently checked.

## Explicit non-claims

This staging branch does not certify complete purchase migration or RTBF coverage, does not claim the live Roblox acceptance gates are passed, and does not assert that a review/coverage boolean is proof of deployed completeness. No application inventory data was fabricated.