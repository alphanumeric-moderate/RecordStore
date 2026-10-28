# Production maintenance and compaction adapter integration

`RecordStoreMaintenanceRobloxAdapter` connects Roblox DataStore key enumeration, uncached record inspection, and durable job checkpoints to the bounded `RecordStoreMaintenanceRunner`. The source tree also now includes `RecordStoreMaintenanceManifestBinding` for reviewed multi-family catalogs and `RecordStoreMaintenanceAtomicTombstone` for same-key generation/job-fence mutation. These are reusable production primitives, not a configured production cleanup job: this repository does not know the application's actual store inventory, dependency graph, deletion policy, authorization, or deployment-specific fencing protocol.

## Instantiate the platform adapter

Load `RecordStoreMaintenanceRobloxAdapter` and call `Adapter.new` with explicit `store_name`, `scope`, a narrow `key_prefix`, a separate `checkpoint_store_name`/`checkpoint_scope`, a bounded `checkpoint_key`, and a stable unique `job_id`. Configure `page_size` in the range 1-100. Checkpoints must not share a DataStore name and scope with the store being enumerated.

The adapter exposes `next_page`, `inspect`, `delete_if_generation`, `load_checkpoint`, `persist_checkpoint`, `authorize`, and `assert_fence` callbacks. Pass those callbacks to `RecordStoreMaintenanceRunner.new(RecordStoreV2.Maintenance, config)` alongside `job_id` and `mode`. Use `mode = "dry_run"` first. The lower-level runner defaults to dry-run too; production cleanup must remain separately authorized.

`next_page` uses `DataStore:ListKeysAsync` with a bounded prefix and a validated advancing cursor. `inspect` uses `GetAsync` with `DataStoreGetOptions.UseCache = false` and reports the observed generation. Supply `is_eligible` and `dependencies_clear` from the application rather than inferring safety from a key name alone. A custom `get_generation` callback is required for formats whose generation is not stored as `fencing_generation` at the top level.

## Required atomic delete contract

`atomic_delete_if_generation(store, item, expected_generation, job_id)` is deliberately mandatory. It must return exactly one of `deleted`, `already_absent`, `skipped`, or `unknown`. It must also perform the actual generation and job-fence check as part of the mutation that changes the same protected record or a correctly serialized application deletion protocol.

Do **not** implement this callback as: read a separate job fence, check it, then issue an unconditional delete. The fence could be revoked between those operations. `assert_fence` in the runner is a useful preflight but cannot close a cross-key time-of-check/time-of-use race. Roblox DataStoreService does not provide a transaction spanning arbitrary keys; if the application's fence and the target record are in different keys, the adapter must use a protocol that makes revocation and deletion mutually exclusive, or it must refuse execute mode. No generic implementation can safely guess that protocol.

Unresolved inspect, delete, or checkpoint outcomes stop progress and retain the last confirmed cursor/counters. Checkpoints use uncached reads and revision-checked `UpdateAsync` transforms; the runner accepts a lost checkpoint response only after read-back matches the exact proposed checkpoint. A stale generation is skipped, never deleted.

## Available manifest-bound atomic tombstone helper

`RecordStoreMaintenanceAtomicTombstone.new(config)` exposes `FenceIfGeneration`, `FenceAndDeleteIfGeneration`, and `DeleteIfGeneration`. Its `UpdateAsync` mutation checks the configured target generation and durable job-fence fields on the protected key, applies non-yielding eligibility/dependency policy, advances the generation, and reconciles uncertain write responses with uncached read-back. A manifest-binding helper can produce the per-family runner callbacks from an approved catalog and explicit application policies.

This closes the generic helper gap; it does **not** complete a particular game's maintenance job. The application's fence must be serialized with target mutation on the same key or by another proven mutually exclusive protocol. A job-fence field that can be revoked independently in a different DataStore key is not made atomic by this helper. Keep execute mode disabled if revocation and deletion are not mutually exclusive, and do not claim actual data cleanup until the configured callbacks and disposable real-key acceptance have been reviewed.

## Application integration checklist

Before enabling `mode = "execute"`, the application owner must provide and review:

- The authoritative store name, scope, prefix and stable enumeration snapshot semantics.
- A complete, paginated inventory with an explicit bound and a documented response when that bound is reached.
- Eligibility rules for every record version, plus all references/sidecars that make deletion unsafe.
- A generation source and a real atomic deletion/fence protocol that is safe under concurrent writers and job cancellation.
- A durable checkpoint store, unique job IDs, authorization evidence, and a durable exclusive job fence.
- A rollback/recovery exercise against disposable real DataStore records, including deletion response loss, checkpoint response loss, a competing writer changing generation, fence revocation, throttling, and server termination.

The regression fixture in `tests/RecordStoreMaintenanceRobloxAdapterRegression.server.luau` validates the callback and adapter contract with a fake DataStore service. It is not evidence that the application's production deletion protocol is atomic or safe. Real Roblox acceptance remains required.


## Multi-family DataStore adapter

`RecordStoreMaintenanceDataStoreAdapter` is separate from the single-store adapter described above. Use it when the application has a reviewed, explicit catalog of multiple key families, potentially across multiple DataStores or scopes. It is still an adapter framework, not an application inventory or a ready-to-run deletion policy.

```lua
local adapter = RecordStoreMaintenanceDataStoreAdapter.new({
	job_id = "approved-maintenance-job-id",
	catalog_revision = "reviewed-inventory-revision-1",
	families = application_reviewed_family_catalog,
	checkpoint_store_name = "MaintenanceCheckpoints",
	checkpoint_scope = "global",
	checkpoint_key = "approved-maintenance-job-id",
	maintenance = RecordStoreV2.Maintenance,
	maintenance_runner = RecordStoreMaintenanceRunner,
	mode = "dry_run",
	authorize = application_authorization_callback,
	assert_fence = application_job_fence_callback,
})
local runner = adapter:NewRunner()
local result = runner:Run(4, 100, 250)
```

The names in this example are placeholders. Populate the family catalog and callbacks from a reviewed application inventory; do not copy a guessed key layout into production. Keep `mode = "dry_run"` until eligibility, dependency, authorization, and the atomic deletion protocol have been accepted on disposable real Roblox records.

Each family entry declares `name`, `store_name`, optional `scope` and `prefix`, plus `get_generation`, `inspect`, `can_delete`, `make_tombstone`, and `is_tombstone` callbacks. The catalog must be a dense array of 1–128 entries. The adapter copies and freezes each family definition during construction so later caller mutation cannot redirect a live cursor. Advance `catalog_revision` whenever family membership, ordering, store/scope/prefix identity, or the meaning of a family changes; continuation cursors are bound to that revision.

Enumeration uses bounded `ListKeysAsync` pages for each catalog family and validates that every continuation cursor advances. Records are read with `DataStoreGetOptions.UseCache = false`. `inspect` must verify the application's actual record schema, eligibility, and dependencies and return `status = "success"`, boolean `eligible` and `dependencies_clear`, and the observed generation only when those facts are verified. Unknown layouts, ambiguous policy results, and invalid generations stop safe deletion rather than being treated as eligible. Missing keys are non-eligible.

`get_generation`, `can_delete`, and `make_tombstone` participate in the `UpdateAsync` deletion transformer and must be deterministic, non-yielding, side-effect-free, and safe to run more than once. `can_delete(value, key_info, expected_generation, job_id)` must check both the generation and the application's durable job fence as part of the same-key conditional mutation. Do not perform a DataStore read, network call, or external side effect inside these callbacks. A fence stored only in another key cannot be atomically checked by a Roblox DataStore transform; if the application's protocol cannot serialize fence revocation with the target mutation, execute mode must remain disabled.

`checkpoint_store_name` and `checkpoint_scope` must not overlap any enumerated family store/scope. Checkpoint writes use revision-checked `UpdateAsync` plus uncached read-back to reconcile response loss. `adapter:NewRunner()` wires the production adapter's enumeration, inspection, deletion, checkpoint, authorization, and preflight-fence methods into `RecordStoreMaintenanceRunner`. The runner's `assert_fence` is only a preflight; it does not replace the same-mutation job-fence check in `can_delete`.

`bench/run_maintenance_datastore_adapter_regression.luau` covers immutable catalog binding, dense-family enforcement, multi-family cursor transitions, stale catalog cursors, uncached inspection, missing-key handling, same-key job/generation fencing, a concurrent generation change during `UpdateAsync`, and checkpoint response-loss/CAS-conflict behavior under a fake DataStore service. This proves the local adapter contract, not application-specific deletion safety, live throttling/cache semantics, or Roblox storage/retention behavior.
