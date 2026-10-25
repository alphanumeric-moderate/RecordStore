# Historical PurchaseId inventory reconciliation

The global `PurchaseDataStoreAuthority` prevents two servers from claiming the same PurchaseId under different identities after that ID is known to the authority. It does not discover old transactions and cannot prove that the source of historical purchases was exhaustive. The per-profile permanent ledger is bounded (maximum 8,192 entries); it is not a substitute for the global authority or a complete import.

## Build an immutable inventory manifest

Before running `PurchaseAuthorityMigrationRunner`, export the complete historical purchase universe from authoritative application sources. Include at least PurchaseId, PlayerId and ProductId, and document the source systems, inclusive/exclusive time bounds, deleted/archived accounts, legacy receipt paths, duplicate IDs, conflicting identities, and how pagination reaches the actual end. Freeze the source or expose an immutable snapshot revision; a moving source is not a valid migration snapshot.

For the exact ordered sequence that the source adapter will return, compute `PurchaseAuthorityMigrationRunner.ComputeInventoryDigest(rows)`. Persist the returned 32-character lowercase hex value in the independently reviewed inventory manifest, along with the source revision, unique manifest ID, expected row count, row-selection rules, export timestamp, and reviewer. The runner carries a rolling digest through its version-2 durable checkpoints and will not import the terminal page or mark the job complete unless both the expected row count and digest match. Its `verify_complete_inventory` callback must independently revalidate the manifest ID/revision/count and that expected digest equals observed digest.

The built-in digest is a deterministic rolling, non-cryptographic reconciliation checksum. It detects ordinary row omission, duplication, reordering and identity mismatches; it is **not** a cryptographic signature, proof of authorization, or collision-resistant commitment. Treat the exported source, manifest review and `verify_complete_inventory` implementation as independent controls. If threat models require a cryptographic digest, generate and verify one with an application-approved cryptographic implementation and retain it alongside this checksum.

## Run and reconcile

Use a stable `job_id`, a dedicated durable checkpoint key, the exact `source_revision` and `inventory_manifest_id`, `expected_purchase_count`, and `expected_inventory_digest`. The source page adapter must return dense bounded pages, monotonically advancing cursors, a stable source revision, and no cursor on its terminal page.

Do not advance the checkpoint when a batch is partial, its result is unknown, counters do not reconcile, identities conflict, the source revision changes, or the terminal manifest check fails. Resume with the same source revision and manifest. On completion, independently compare the source export count/digest to checkpoint totals and inspect authority rows for conflicts before flipping any receipt-processing migration gate.

Do not enable `permanent_purchase_ledger_migration_complete` or `external_purchase_authority_migration_complete` based on a successful call alone. These are operator attestations, not automatic proof. Keep them disabled until the entire historical PurchaseId source has been reconciled and the live fulfillment path is accepted.

## Live acceptance still required

Validate cross-server `ClaimAsync`/commit behavior, response loss, duplicate callbacks, mismatched PlayerId/ProductId, server shutdown between claim/grant/commit, historical imports racing with live receipts, and the exact MarketplaceService fulfillment path in a real Roblox test experience. Determine which products have cross-profile or lifetime entitlement requirements that need a separate permanent entitlement model, and whether the game needs receipt adapters beyond developer products.

The deferred regression `tests/PurchaseAuthorityMigrationRunnerRegression.server.luau` tests manifest count/digest mismatch, bounded import, partial batches and checkpoint response-loss recovery. It does not enumerate or certify the application's actual purchase inventory.
