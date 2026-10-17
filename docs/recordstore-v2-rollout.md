# RecordStore V2 rollout and rollback gate

This gate is a durable protocol boundary, not proof by itself that a deployment is safe. Keep the V2 API opt-in until the application-supplied verifiers are backed by real deployment observations and the required Studio/service tests have passed.

## Required deployment evidence

Construct `V2.Rollout` with a durable DataStore-shaped adapter whose `GetAsync` and `UpdateAsync` methods use the same rollout store, name and scope on every server.

Each required verifier must return exactly `true, evidence_id`, where `evidence_id` is a stable reference to durable review/deployment evidence:

- `verify_compatibility`: confirms the compatibility release and read/write matrix are deployed.
- `verify_writers_drained`: confirms old writers are no longer running; a freeze marker is insufficient when old binaries do not check it.
- `verify_activation_frozen`: confirms activation is still frozen while preflight checks execute.
- `verify_rollback_rehearsed`: points to a completed rollback rehearsal for the exact matrix digest.
- `verify_profile_key_fencing`: confirms writes are fenced on the profile key, independently of mailbox claim tokens.
- `verify_rollback_completed`: required when completing a rollback; proves the old writer population is restored and V2 writes/processing are fenced.

Do not return success because a timer elapsed or a local flag was set. The verifiers are application integration points and must inspect the actual deployment state. Missing verifiers, missing evidence references, storage failures and unsupported manifest states fail closed.

## Example

Construct the durable rollout coordinator before constructing the guarded V2 facade. This lets the same gate be injected into every V2 service and mailbox:

```luau
local V2Module = require(path.to.RecordStoreV2)

local rollout_id = "recordstore-v2-release-2026-10"
local matrix_digest = "release-matrix-v2-sha-or-review-id"

local rollout = V2Module.Rollout.new(rolloutStoreAdapter, {
    verify_compatibility = verify_compatibility,
    verify_writers_drained = verify_old_writers_drained,
    verify_activation_frozen = verify_activation_freeze,
    verify_rollback_rehearsed = verify_rollback_rehearsal,
    verify_profile_key_fencing = verify_profile_key_fencing,
    verify_rollback_completed = verify_rollback_completion,
})

local function activation_guard(operation)
    return rollout:ActivationGuard(rollout_id, operation)
end

local V2 = V2Module.new(RecordStore, MailboxV2, {
    activation_guard = activation_guard,
})

local prepared = rollout:PrepareAsync(rollout_id, matrix_digest)
assert(prepared.code == "prepared" or prepared.code == "duplicate")

local ready = rollout:AttestAsync(rollout_id)
assert(ready.code == "committed" or ready.code == "committed_reconciled")

-- The facade inherits its guard when V2.Mailbox.new is used.
local mailbox = V2.Mailbox.new(dataStoreAdapter, owner, {
    encode = exact_store_encoder,
})

-- Activate only after a fresh preflight attestation succeeds.
local active = rollout:ActivateAsync(rollout_id, "activate-recordstore-v2-1")
assert(active.code == "committed" or active.code == "committed_reconciled")
```

Do not use `allow_unattested_activation = true` in production. That flag is for isolated tests or explicitly unsafe staging only.
## Freeze and rollback

1. `FreezeAsync(rollout_id, freeze_id)` moves an active rollout to `frozen`. New mailbox enqueue, DLQ replay/discard and maintenance operations are denied. Existing work can still process/recover/acknowledge so the deployment can drain safely.
2. `BeginRollbackAsync(rollout_id, rollback_id)` is allowed only after freeze and records that rollback has begun.
3. Restore the previous compatible application release and verify old writers and V2 fencing.
4. `CompleteRollbackAsync(rollout_id, rollback_id)` requires the application-supplied rollback-completion verifier and persists `rolled_back`. Further V2 processing is denied.

If the rollout state cannot be read, the guard denies activation-sensitive mailbox operations. Existing claim renewal remains bounded by its claim token and configured renewal horizon; this is not an exactly-once fence for an external side effect.

## Unsafe override

`allow_unattested_activation = true` exists for isolated regression harnesses and explicitly unsafe staging only. It bypasses the durable gate. Never use it for a production mailbox.

## RTBF inventory, tombstone, and historical data

The V2 erasure coordinator does not discover game-specific stores or user IDs by guessing. Every declared template and every inventory row must match exactly on (store_name, scope, key). Inventory callbacks must be authoritative, bounded, and complete. Rows use:

- `exists = true` (or omitted) and a positive integer `generation` for a key whose current RecordStore generation exists;
- `exists = false` and `generation = 0` only when the integration has verified that the current key is absent; this still does not prove its older version history is empty.

Each family must set `templates_verified = true`, `inventory_verified = true`, and `history_inventory_verified = true` only after independently reviewing its complete current-key and historical-version inventory. `verify_templates(user_id, rendered_templates)` must return `true`. The coordinator rejects unmatched identities, missing template rows, duplicate rows, sparse/oversized inventories, invalid generation values and unbounded keys.

For RecordStore-backed single-user profiles, use `V2.ProfileDoctor.DeleteIfGenerationAsync(record, item, user_id, erasure_id)` from the family's `redact_or_delete_if_generation` callback. It checks the exact DataStore identity and observed generation/revision before delegating to `record:EraseAsync(...)`. `EraseAsync` installs a generation-advanced core tombstone through the normal fenced `UpdateAsync` path and clears the key's `UserIds`, custom metadata, transaction/inbox receipt sidecars, and outbox sidecar. It does not call `RemoveAsync`; normal opens and stale-generation writers must not recreate a tombstoned profile. Whole-record deletion is intentionally rejected for Records associated with multiple UserIds; those require a subject-specific redaction path that preserves other users' data.

Every family must provide both:
- `fence_user(user_id, erasure_id)`, which closes or fences all application writers for that user/key family, not just the one Record instance being erased;
- `clear_history_if_generation(item, user_id, erasure_id)`, which clears historical payloads/backups for the exact inventoried key while ensuring the current deletion fence remains in place. A return value of `true` means the integration has verified completion; false/retryable or unknown results leave the manifest cursor unchanged. This callback runs after the current key has been generation-safely tombstoned and before erasure progress advances.

Configure the platform's [Data Stores Manager RTBF templates](https://create.roblox.com/docs/cloud-services/data-stores/right-to-be-forgotten) or its [Configs API](https://create.roblox.com/docs/cloud/reference/features/configs) for all applicable current-key families and validate the templates in a disposable experience. Roblox's [version-listing documentation](https://create.roblox.com/docs/cloud-services/data-stores/versioning-listing-and-caching) notes that historical versions can remain retrievable after a key is removed. Do not treat a current-key tombstone or a successful `RemoveAsync` alone as proof that historical payloads are gone. The engine reference marks `RemoveVersionAsync` as deprecated; integrations must use a currently supported, reviewed history-removal mechanism and verify that no old version can restore the erased payload.

A complete RTBF acceptance test must demonstrate: (1) the templates cover every applicable key and scope; (2) the inventory detects extra, missing, and shared-user keys; (3) the writer fence prevents new writes; (4) an old-generation delete cannot remove a newer generation; (5) UserIds, metadata and embedded sidecars are cleared; (6) version history and external backups are unavailable after completion; and (7) restore, replay, projection rebuild, and delayed writers cannot resurrect the data.

## Acceptance boundary

This state machine cannot terminate old server processes, prove old code reads the freeze marker, discover every profile key, or prove real service quotas. Before production activation, require:
- the complete failure-injection suite on the same PR head;
- CodSpeed results on the same head and a comparable baseline;
- a disposable Roblox experience testing DataStore, MessagingService and MemoryStore response loss/throttling;
- mixed-version old-writer drain and rollback rehearsal using actual server deployments;
- verified application-specific RTBF templates/inventory and per-profile tombstone fencing.
