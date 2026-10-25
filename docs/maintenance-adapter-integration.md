# Production maintenance and compaction adapter integration

`RecordStoreMaintenanceRobloxAdapter` connects Roblox DataStore key enumeration, uncached record inspection, and durable job checkpoints to the bounded `RecordStoreMaintenanceRunner`. It is an adapter framework, not a configured production cleanup job: this repository does not know the application's real store inventory, dependency graph, deletion policy, or fencing protocol.

## Instantiate the platform adapter

Load `RecordStoreMaintenanceRobloxAdapter` and call `Adapter.new` with explicit `store_name`, `scope`, a narrow `key_prefix`, a separate `checkpoint_store_name`/`checkpoint_scope`, a bounded `checkpoint_key`, and a stable unique `job_id`. Configure `page_size` in the range 1-100. Checkpoints must not share a DataStore name and scope with the store being enumerated.

The adapter exposes `next_page`, `inspect`, `delete_if_generation`, `load_checkpoint`, `persist_checkpoint`, `authorize`, and `assert_fence` callbacks. Pass those callbacks to `RecordStoreMaintenanceRunner.new(RecordStoreV2.Maintenance, config)` alongside `job_id` and `mode`. Use `mode = "dry_run"` first. The lower-level runner defaults to dry-run too; production cleanup must remain separately authorized.

`next_page` uses `DataStore:ListKeysAsync` with a bounded prefix and a validated advancing cursor. `inspect` uses `GetAsync` with `DataStoreGetOptions.UseCache = false` and reports the observed generation. Supply `is_eligible` and `dependencies_clear` from the application rather than inferring safety from a key name alone. A custom `get_generation` callback is required for formats whose generation is not stored as `fencing_generation` at the top level.

## Required atomic delete contract

`atomic_delete_if_generation(store, item, expected_generation, job_id)` is deliberately mandatory. It must return exactly one of `deleted`, `already_absent`, `skipped`, or `unknown`. It must also perform the actual generation and job-fence check as part of the mutation that changes the same protected record or a correctly serialized application deletion protocol.

Do **not** implement this callback as: read a separate job fence, check it, then issue an unconditional delete. The fence could be revoked between those operations. `assert_fence` in the runner is a useful preflight but cannot close a cross-key time-of-check/time-of-use race. Roblox DataStoreService does not provide a transaction spanning arbitrary keys; if the application's fence and the target record are in different keys, the adapter must use a protocol that makes revocation and deletion mutually exclusive, or it must refuse execute mode. No generic implementation can safely guess that protocol.

Unresolved inspect, delete, or checkpoint outcomes stop progress and retain the last confirmed cursor/counters. Checkpoints use uncached reads and revision-checked `UpdateAsync` transforms; the runner accepts a lost checkpoint response only after read-back matches the exact proposed checkpoint. A stale generation is skipped, never deleted.

## Application integration checklist

Before enabling `mode = "execute"`, the application owner must provide and review:

- The authoritative store name, scope, prefix and stable enumeration snapshot semantics.
- A complete, paginated inventory with an explicit bound and a documented response when that bound is reached.
- Eligibility rules for every record version, plus all references/sidecars that make deletion unsafe.
- A generation source and a real atomic deletion/fence protocol that is safe under concurrent writers and job cancellation.
- A durable checkpoint store, unique job IDs, authorization evidence, and a durable exclusive job fence.
- A rollback/recovery exercise against disposable real DataStore records, including deletion response loss, checkpoint response loss, a competing writer changing generation, fence revocation, throttling, and server termination.

The regression fixture in `tests/RecordStoreMaintenanceRobloxAdapterRegression.server.luau` validates the callback and adapter contract with a fake DataStore service. It is not evidence that the application's production deletion protocol is atomic or safe. Real Roblox acceptance remains required.
