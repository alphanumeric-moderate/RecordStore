# PR #56 blocker candidates

These modules are deliberately staged outside `src/PlayerDataInitializer` and are not required by RecordStore or PlayerDataCore. They must remain isolated until their own regression suite, type analysis, source review, and application contract review pass.

## Candidate modules

- `RecordStoreApplicationInventory.luau` validates a bounded RTBF family/writer manifest. It checks explicit store/scope/key locator data, exact user-ID templates, family/writer bidirectional coverage, generation and same-mutation fence declarations, and evidence references. `validate` establishes structural validity only. `verify_for_activation` also requires live Roblox acceptance evidence and an independently implemented attestation verifier. Do not implement that verifier as an unconditional `return true`.

- `PurchaseEntitlementDataStoreAuthority.luau` is a separate permanent per-player entitlement authority for products which genuinely require lifetime uniqueness. It is not a replacement for the globally keyed PurchaseId authority. The caller must map products to stable entitlement IDs, commit the entitlement only after the corresponding profile grant is confirmed, and reconcile uncertain cross-key outcomes through the same stable PurchaseId receipt protocol. Repeatable developer products must not be mapped to a lifetime-unique entitlement. The native DataStore adapter bypasses the local read cache; callers should provide the shared request-governor `request_runner` and budget callback.

## Required before integration

1. Run `bench/run_pr56_blocker_staging_regression.luau` and the dedicated staged type analysis on the exact candidate head.
2. Independently review the source and tests. Passing fake-store tests does not prove live DataStore semantics or the application-specific trust boundary.
3. Obtain the real game's reviewed purchase inventory and RTBF manifest, including every relevant DataStore/scope/key family, source snapshot, direct writer and recreation path. This repository has no historical purchase export and no complete game-script inventory, so those data cannot be generated safely here.
4. Verify each family’s deletion/redaction path enforces both the observed generation and durable writer fence at the same mutation boundary. A preflight check or a boolean attestation alone is insufficient.
5. Run the real Roblox multi-server, response-loss, shutdown, rollout/rollback, entitlement fulfillment, storage-retention, and no-recreation acceptance scenarios.
6. Only after the staged code has been reviewed and checked should the required components be integrated one at a time into the relevant RecordStore-facing modules.

This candidate work does not close RTBF completeness or purchase migration by itself. It creates reusable validation and entitlement authority pieces while preserving fail-closed gates for evidence the repository does not contain.
