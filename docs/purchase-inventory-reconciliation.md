# Historical PurchaseId inventory reconciliation

The global `PurchaseDataStoreAuthority` prevents two servers from claiming the same PurchaseId under different identities after that ID is known to the authority. It does not discover old transactions and cannot prove that the source of historical purchases was exhaustive. The per-profile permanent ledger is bounded (maximum 8,192 entries); it is not a substitute for the global authority or a complete import.

## Build an immutable inventory manifest

Before running `PurchaseAuthorityMigrationRunner`, export the complete historical purchase universe from authoritative application sources. Include at least PurchaseId, PlayerId and ProductId, and document the source systems, inclusive/exclusive time bounds, deleted/archived accounts, legacy receipt paths, duplicate IDs, conflicting identities, and how pagination reaches the actual end. Freeze the source or expose an immutable snapshot revision; a moving source is not a valid migration snapshot.

For the exact ordered sequence that the source adapter will return, compute `PurchaseAuthorityMigrationRunner.ComputeInventoryDigest(rows)`. Persist the returned 64-character lowercase hexadecimal digest in the independently reviewed inventory manifest, with `digest_algorithm = "sha256-chain-v1"`, the immutable source revision, unique manifest ID, expected row count, row-selection rules, export timestamp, and reviewer. The runner chains each length-prefixed PurchaseId/PlayerId/ProductId tuple through SHA-256. Its version-3 durable checkpoint stores both the algorithm identifier and current digest; older version-2 checkpoints are rejected rather than reinterpreted. The runner will not import the terminal page or mark the job complete unless the expected row count, digest, and independent `verify_complete_inventory` callback all agree.

The built-in digest is a deterministic SHA-256 hash chain over a fixed domain separator and unambiguous row encoding. It is intended to make changes to the ordered rows computationally hard to conceal, subject to the security of SHA-256. It is **not** a signature or MAC, does not prove the exporter was authorized, and cannot prove that the source included every historical purchase. Exhaustive source coverage, immutable snapshot provenance, conflict reconciliation, and independent review remain separate required controls. The implementation is checked against standard SHA-256 known-answer vectors in `bench/run_pr56_blocker_staging_regression.luau`.

## Run and reconcile

Use a stable `job_id`, a dedicated durable checkpoint key, the exact `source_revision` and `inventory_manifest_id`, `expected_purchase_count`, and `expected_inventory_digest`. The source page adapter must return dense bounded pages, monotonically advancing cursors, a stable source revision, and no cursor on its terminal page.

Do not advance the checkpoint when a batch is partial, its result is unknown, counters do not reconcile, identities conflict, the source revision changes, or the terminal manifest check fails. Resume with the same source revision and manifest. On completion, independently compare the source export count/digest to checkpoint totals and inspect authority rows for conflicts before flipping any receipt-processing migration gate.

Do not enable `permanent_purchase_ledger_migration_complete` or `external_purchase_authority_migration_complete` based on a successful call alone. These are operator attestations, not automatic proof. Keep them disabled until the entire historical PurchaseId source has been reconciled and the live fulfillment path is accepted.

## Live acceptance still required

Validate cross-server `ClaimAsync`/commit behavior, response loss, duplicate callbacks, mismatched PlayerId/ProductId, server shutdown between claim/grant/commit, historical imports racing with live receipts, and the exact MarketplaceService fulfillment path in a real Roblox test experience. Determine which products have cross-profile or lifetime entitlement requirements that need a separate permanent entitlement model, and whether the game needs receipt adapters beyond developer products.

The deferred regression `tests/PurchaseAuthorityMigrationRunnerRegression.server.luau` tests manifest count/digest mismatch, bounded import, partial batches and checkpoint response-loss recovery. It does not enumerate or certify the application's actual purchase inventory.
