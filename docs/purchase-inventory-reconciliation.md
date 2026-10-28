# Historical PurchaseId inventory reconciliation

The global `PurchaseDataStoreAuthority` prevents two servers from claiming the same PurchaseId under different identities after that ID is known to the authority. It does not discover old transactions and cannot prove that the source of historical purchases was exhaustive. The per-profile permanent ledger is bounded (maximum 8,192 entries); it is not a substitute for the global authority or a complete import.

## Build an immutable inventory manifest

Before running `PurchaseAuthorityMigrationRunner`, export the complete historical purchase universe from authoritative application sources. Include at least PurchaseId, PlayerId and ProductId, and document the source systems, inclusive/exclusive time bounds, deleted/archived accounts, legacy receipt paths, duplicate IDs, conflicting identities, and how pagination reaches the actual end. Freeze the source or expose an immutable snapshot revision; a moving source is not a valid migration snapshot.

For the exact ordered sequence that the source adapter will return, compute `PurchaseAuthorityMigrationRunner.ComputeInventoryDigest(rows)`. Persist the returned 64-character lowercase SHA-256 chain digest in the independently reviewed inventory manifest, along with the source revision, unique manifest ID, expected row count, row-selection rules, export timestamp, and reviewer. The runner carries the digest through version-4 durable checkpoints, records the last `(PurchaseId, PlayerId, ProductId)` tuple, and rejects descending order within or across pages before importing that page. It will not import the terminal page or mark the job complete unless the expected row count, digest, declared ordering, and independent completion verifier all agree.

The built-in digest is a domain-separated SHA-256 hash chain over each ordered PurchaseId/PlayerId/ProductId row. It is a cryptographic digest, not a signature or proof of authorization, and it cannot prove that an external source export is exhaustive on its own. Treat the immutable source snapshot, independently reviewed manifest, row-order verification, and `verify_complete_inventory` implementation as separate controls.

## Run and reconcile

Use a stable `job_id`, a dedicated durable checkpoint key, the exact `source_revision` and `inventory_manifest_id`, `expected_purchase_count`, and `expected_inventory_digest`. The source page adapter must return dense bounded pages, nonempty control-character-free continuation cursors that advance, a stable source revision, rows in nondecreasing lexicographic `PurchaseId`, `PlayerId`, `ProductId` order, and no cursor on its terminal page. The runner enforces ordering across page boundaries by persisting the previous tuple in the durable checkpoint.

Checkpoint schema v4 stores the last verified purchase tuple so ordering checks survive process restarts. Legacy v3 checkpoints lack this state and deliberately fail closed; do not delete or rewrite them blindly. Reconcile the old checkpoint and target authority rows, then either build a v4 checkpoint from independently verified state or restart the same immutable snapshot with a new job/checkpoint key only after confirming historical backfill is fully idempotent. The runner does not silently reset a legacy cursor.

Do not advance the checkpoint when a batch is partial, its result is unknown, counters do not reconcile, identities conflict, the source revision changes, or the terminal manifest check fails. Resume with the same source revision and manifest. On completion, independently compare the source export count/digest to checkpoint totals and inspect authority rows for conflicts before flipping any receipt-processing migration gate.

Do not enable `permanent_purchase_ledger_migration_complete` or `external_purchase_authority_migration_complete` based on a successful call alone. These are operator attestations, not automatic proof. Keep them disabled until the entire historical PurchaseId source has been reconciled and the live fulfillment path is accepted.

## Lifetime entitlement authority

The source tree now includes `PurchaseEntitlementDataStoreAuthority`, `PurchaseEntitlementReceiptCoordinator`, and `PurchaseEntitlementReceiptHandler`. This is separate from the global PurchaseId authority: the entitlement authority supports reservation, commit, historical backfill, status reconciliation, and generation-fenced erasure/retention for configured entitlement IDs. The coordinator orders the durable PurchaseId claim, entitlement reservation, application-supplied idempotent profile grant, entitlement commit and terminal PurchaseId commit. Unknown or conflicting states defer rather than being acknowledged as completed.

This does not make historical migration automatic. The game must decide which products are genuinely lifetime-unique, provide a stable ProductId-to-entitlement mapping and idempotent profile-grant callback, provide an activation verifier, and reconcile/backfill historical purchases before enabling live grants. Entitlement IDs and their erasure locators must also be included in the reviewed application inventory. The mocks verify local protocol branches only; the real receipt callback, cross-server races and shutdown/response-loss behavior still require a Roblox test experience.

## Live acceptance still required

Validate cross-server `ClaimAsync`/commit behavior, response loss, duplicate callbacks, mismatched PlayerId/ProductId, server shutdown between claim/grant/commit, historical imports racing with live receipts, and the exact MarketplaceService fulfillment path in a real Roblox test experience. Determine which products have cross-profile or lifetime entitlement requirements that need a separate permanent entitlement model, and whether the game needs receipt adapters beyond developer products.

The regression `tests/PurchaseAuthorityMigrationRunnerRegression.server.luau` tests manifest count/digest mismatch, bounded import, partial batches, checkpoint response-loss recovery, row ordering across page boundaries, malformed continuation cursors, and fail-closed version-3 checkpoint handling. It does not enumerate or certify the application's actual purchase inventory.
