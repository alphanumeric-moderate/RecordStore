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

```luau
local rollout = V2.Rollout.new(rolloutStoreAdapter, {
    verify_compatibility = verify_compatibility,
    verify_writers_drained = verify_old_writers_drained,
    verify_activation_frozen = verify_activation_freeze,
    verify_rollback_rehearsed = verify_rollback_rehearsal,
    verify_profile_key_fencing = verify_profile_key_fencing,
    verify_rollback_completed = verify_rollback_completion,
})

local rollout_id = "recordstore-v2-release-2026-10"
local matrix_digest = "release-matrix-v2-sha-or-review-id"

local prepared = rollout:PrepareAsync(rollout_id, matrix_digest)
assert(prepared.code == "prepared" or prepared.code == "duplicate")

local ready = rollout:AttestAsync(rollout_id)
assert(ready.code == "committed" or ready.code == "committed_reconciled")

-- This guard must be shared by the V2 mailbox on every server.
local function activation_guard(operation)
    return rollout:ActivationGuard(rollout_id, operation)
end

local mailbox = MailboxV2.new(dataStoreAdapter, owner, {
    encode = exact_store_encoder,
    activation_guard = activation_guard,
})

-- Activate only after a fresh preflight attestation succeeds.
local active = rollout:ActivateAsync(rollout_id, "activate-recordstore-v2-1")
assert(active.code == "committed" or active.code == "committed_reconciled")
```

Use a stable rollout ID and matrix digest. Do not rewrite a prepared rollout to point at a different matrix; create a new rollout ID for a different compatibility contract. Keep activation disabled if any assertion fails or returns an unknown result.

## Freeze and rollback

1. `FreezeAsync(rollout_id, freeze_id)` moves an active rollout to `frozen`. New mailbox enqueue, DLQ replay/discard and maintenance operations are denied. Existing work can still process/recover/acknowledge so the deployment can drain safely.
2. `BeginRollbackAsync(rollout_id, rollback_id)` is allowed only after freeze and records that rollback has begun.
3. Restore the previous compatible application release and verify old writers and V2 fencing.
4. `CompleteRollbackAsync(rollout_id, rollback_id)` requires the application-supplied rollback-completion verifier and persists `rolled_back`. Further V2 processing is denied.

If the rollout state cannot be read, the guard denies activation-sensitive mailbox operations. Existing claim renewal remains bounded by its claim token and configured renewal horizon; this is not an exactly-once fence for an external side effect.

## Unsafe override

`allow_unattested_activation = true` exists for isolated regression harnesses and explicitly unsafe staging only. It bypasses the durable gate. Never use it for a production mailbox.

## Acceptance boundary

This state machine cannot terminate old server processes, prove old code reads the freeze marker, discover every profile key, or prove real service quotas. Before production activation, require:
- the complete failure-injection suite on the same PR head;
- CodSpeed results on the same head and a comparable baseline;
- a disposable Roblox experience testing DataStore, MessagingService and MemoryStore response loss/throttling;
- mixed-version old-writer drain and rollback rehearsal using actual server deployments;
- verified application-specific RTBF templates/inventory and per-profile tombstone fencing.
