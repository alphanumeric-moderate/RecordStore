# RecordStore durable messaging and segmented mailbox v2

- Date: 2026-10-17
- Status: Design proposal for review; no production-code changes
- Target: RecordStore queue and messaging subsystem
- Related work: follow-up to merged PR #31; separate from production-configuration work

## Decision requested

Adopt a combined design, not an either/or choice:

1. Harden the existing queue's delivery contract and failure recovery (Option A).
2. Add a versioned, segmented DataStore mailbox with separate dead-letter and idempotency records (Option B, the durable foundation).
3. Add an optional MemoryStore/MessagingService acceleration path whose state is never authoritative (Option C).

Implement in phases and keep the new layout feature-gated. The current queue remains supported during migration. Do not change production defaults or activate the new queue format until the compatibility reader, migration, rollback protocol, fault tests, and benchmark suite have been reviewed and verified.

## 1. Current implementation and concrete problems

The current queue implementation lives in **src/PlayerDataInitializer/RecordStore.luau**. Queue implementation version 3 uses the **RecordStoreQueue** DataStore by default and stores a record's active messages and dead letters in one envelope. Defaults are a 10-second poll interval, 60-second processing lease, 100 active messages, 250,000 serialized bytes per envelope, and five attempts.

The public API includes **Record:MessageAsync()**, **EnqueueAsync()**, **ProcessQueueAsync()**, **GetQueueAsync()**, **GetDeadLettersAsync()**, **ClaimDeadLetterAsync()**, **ReplayDeadLetterAsync()**, **DiscardDeadLetterAsync()**, and **Stats()**. Existing queue handlers are deliberately rejected if they yield. Queue transforms already parse and validate the envelope, generate a claim token before UpdateAsync, and verify outcomes after writes. These are useful foundations, not exactly-once guarantees.

Material gaps:

- Every append, claim, acknowledgement, retry, and dead-letter transition rewrites and validates an envelope containing active messages and historical dead letters.
- Dead letters consume active queue capacity and can prevent enqueue or dead-letter transitions when the envelope reaches its byte limit.
- EnqueueAsync generates its ID internally. A caller retry after an ambiguous result can create a different ID for the same logical operation.
- Handler execution and acknowledgement are separate durable operations. A crash after a handler's external side effect but before acknowledgement can cause redelivery.
- Retry timing is tied to claim-lock expiry rather than an explicit persisted retry schedule.
- MessagingService is used for hints and transient inter-server messages. Successful publish is not proof of handler execution.
- Queue inspection has no scalable paginated dead-letter API or queue-specific snapshot of backlog age, expired claims, retry state, and acknowledgement recovery.

## 2. Delivery and API contract

### 2.1 Delivery guarantees

The durable queue provides **at-least-once delivery**. A message remains eligible for retry until it is durably acknowledged, durably dead-lettered, or explicitly discarded. A handler may execute more than once after a crash, timeout, lease expiry, uncertain DataStore response, or ownership change.

RecordStore will not promise exactly-once effects for arbitrary handlers, purchases, transfers, or external systems. Application effects must be idempotent or use a durable application-level ledger. The library will document and test a supported pattern.

Distinguish these states:

- **Submitted**: argument and payload validation succeeded.
- **Enqueued**: the canonical message and its queue index are durably written and verified.
- **Duplicate submission**: an existing idempotency receipt matches the producer key and exact request; return its original message ID.
- **Claimed**: a worker owns the persisted claim token and lease.
- **Retry scheduled**: failure and next eligible time are durably recorded.
- **Acknowledgement pending**: the handler returned success and a durable acknowledgement transition began, but cleanup/reconciliation may remain.
- **Acknowledged**: acknowledgement is durable; recovery must not run the handler again for that message.
- **Dead-lettered**: terminal failure and payload are durably stored outside active queue capacity.
- **Replay pending, replayed, or discarded**: explicit, recoverable dead-letter transitions.

An **unknown** result means the caller must not infer commit or non-commit. Repeating an enqueue with the same idempotency key is the supported way to resolve an ambiguous submit result. Existing result-code APIs remain compatible; new typed report APIs are additive.

### 2.2 Idempotent enqueue

Add an optional producer-supplied idempotency key to the durable enqueue API while preserving the two-argument call.

- EnqueueAsync(message_type, data) keeps its current non-idempotent behavior.
- EnqueueAsync(message_type, data, idempotency_key) is idempotent for that record owner and producer key.
- The same key with the same canonical request returns the original logical message ID and a duplicate outcome if already accepted.
- The same key with a different message type or payload returns **conflict**; it must never silently reuse the earlier ID for different content.
- Validate key type and length before issuing DataStore requests. The key is scoped to the full (name, scope, key) record identity.
- Canonical request comparison must be deterministic for nested Luau tables. Do not use table iteration order as an idempotency oracle.
- By default, keep receipts until explicitly pruned. An optional configured retention may prune terminal receipts, and the API documentation must state that reuse after expiry may create a new logical message.

A receipt is a separate bounded DataStore key, not an ever-growing index in a queue envelope. Store the full producer key and full canonical request representation, or an equivalently collision-safe representation. Hashes may shorten key names, but every loaded receipt must validate the original owner and key. A hash collision must fail closed or use a collision slot; it must never merge two producer keys.

### 2.3 Transient messages

MessageAsync remains a transient MessagingService API. A successful return means only that the publish call succeeded. It does not imply persistence, subscriber delivery, handler execution, or acknowledgement. Document it separately from durable enqueue.

## 3. Option A: harden queue correctness

Implement these correctness improvements as the first production slice and carry the invariants into the segmented layout:

- Persist an explicit **available_at** retry time and bounded exponential backoff. Apply deterministic or injected jitter so mass failures do not synchronize into a retry storm. Cap the delay and honor maximum attempts.
- Distinguish attempts for the current delivery cycle, total attempts across replay, and replay count. Preserve existing fields during migration.
- A claim is expired only when its persisted lease deadline has passed. A claim token fences renewals, acknowledgements, retries, and dead-letter transitions from stale workers.
- Add lease renewal for claimed messages. Preserve the non-yielding **on_queue_message** callback for compatibility. Add a separate opt-in async callback for operations that await Roblox APIs; it requires a renewable claim and must stop progressing when either the claim or owning record session is fenced. It remains at-least-once.
- Persist acknowledgement-in-progress before updating the idempotency receipt and removing the active item. Recovery must finish this transition without invoking the successful handler a second time.
- Persist dead-letter-in-progress before copying to the independent dead-letter key. Recovery repeats the copy idempotently and then removes the active item.
- Keep UpdateAsync transforms pure and non-yielding. Do not generate IDs, mutate InternalState, publish messages, invoke observers, call other services, or acquire locks inside transforms. Generate tokens before the update and emit observations only after classifying its outcome.
- Publish MessagingService hints only after durable enqueue is verified. Failed or missed hints must not change enqueue success or prevent polling recovery.
- Validate queue settings before queue writes: timeouts, retry counts, segment sizes, retention, and partition counts.

Option A is the correctness contract, not a reason to retain the v3 envelope indefinitely.

## 4. Option B: versioned segmented durable mailbox

### 4.1 Key layout

Use the configured queue DataStore name and scope, with a new mailbox layout version referred to as **mailbox v2**. Keep every key name within Roblox's 50-character limit. Persist full record-owner identity in manifests, segments, receipts, and dead-letter records. A compact deterministic owner fingerprint is a routing prefix only, never proof of ownership.

Use four record families:

1. **Partition manifest**: one small record per owner and partition. Contains layout version, full owner identity, immutable partition count, head segment number, tail/current segment number, and migration/reconciliation state. Its size is independent of message count. It is updated for rollover, head advancement, and recovery, not for every claim or acknowledgement.
2. **Bounded active segment**: one key per owner, partition, and segment number. Contains at most the configured item count and serialized-byte ceiling. Every update validates version, owner, partition, segment number, message identity, shape, and encoded size. Claim, lease renewal, retry, acknowledgement-in-progress, and removal normally touch only this bounded key.
3. **Independent dead-letter record**: one durable key per message ID, including payload, terminal error, attempt history, timestamps, replay fencing state, and owner identity. Dead letters no longer consume active-segment bytes or slots. Retention defaults to disabled (keep records) unless explicitly configured; cleanup must be bounded and observable.
4. **Idempotency receipt**: one durable key per producer key, containing original producer key, canonical request representation, original message ID, enqueue reservation/fencing token, lifecycle status, and timestamps. The active item references the receipt identity. Receipt operations are idempotent and use a compare-and-set state machine.

No worker may enumerate the entire DataStore keyspace to find ready messages on every poll. Normal processing uses bounded manifests and segment ranges. ListKeysAsync is reserved for paginated operator-facing dead-letter inspection or infrequent reconciliation, with its request-budget cost handled explicitly.

### 4.2 Segments and rollover

Initial conservative mailbox v2 defaults:

- **queue_segment_max_messages = 32**
- **queue_segment_max_bytes = 250000**
- **queue_max_segments = 64** per partition
- **queue_partition_count = 1**
- Start with the existing 60-second claim lease; validate all lease values.
- Preserve the existing 10-second poll default until benchmarks and live telemetry justify changing it.

These defaults allow up to 2,048 small active messages per single-partition mailbox while preserving a byte ceiling per segment. Larger messages naturally reduce the item count per segment. Dead letters do not count toward active capacity. Capacity exhaustion returns an explicit capacity/validation result; it never silently drops an existing message.

A writer reads the current manifest and attempts an append to the selected segment. The segment UpdateAsync rejects appends if sealed or full. Rollover is recoverable:

1. Seal the old segment using UpdateAsync guarded by its current identity.
2. Create and verify the next empty segment.
3. Advance the manifest tail only if it still points to the old segment and the old segment is sealed.
4. Retry the append against the current manifest.
5. Recovery repairs a sealed current segment or an orphan empty segment without deleting a referenced active segment.

The order is mandatory. A stale producer may not append after a segment is sealed. Only sealed, empty, non-current segments may be skipped and retired. Head/tail segment numbers avoid a manifest array that grows with every rollover.

The default partition count remains one to preserve the old queue's effective order as closely as possible. Partitioning is opt-in and immutable after activation. With more than one partition, ordering is only per partition; no total FIFO order is promised. Resizing partitions requires a future migration rather than an in-place setting change.

### 4.3 Cross-key crash recovery

DataStore provides no transaction spanning the manifest, segment, receipt, and dead-letter keys. Every cross-key transition therefore has a persisted intermediate state and an idempotent recovery path.

**Enqueue with an idempotency key**

1. Create or read the receipt using UpdateAsync. A matching key and canonical request reuse the same message ID; a mismatched request returns conflict.
2. Persist a reservation token in the receipt.
3. Append the message with that ID and reservation token to a segment.
4. Mark the receipt accepted only if the reservation token still matches.
5. Verify the stored result, then return enqueued or duplicate.
6. If the process stops between steps, a repeated submit with the same key resumes the same logical enqueue. A worker must not execute an item whose receipt is still reserved. Recovery may commit the receipt only after verifying the corresponding segment item. A stale reservation is fenced; a late item with that token is removed or reconciled without invoking its handler.

Do not report enqueue success until the item exists and the receipt is committed. A write response with an uncertain outcome is verified using an uncached read or a subsequent idempotent retry, not guessed from a nil return value.

**Claim and execution**

Claim is a compare-and-set transition on the segment item. It increments attempt counters, stores a new GUID claim token, sets locked_until, and records the processing server and session generation. Only the matching unexpired token may renew or finish the item. A handler starts only after the worker verifies queue state and current record-session ownership. Session ownership and queue claim are different keys, so they are not one atomic lock.

**Acknowledgement**

1. After handler success, persist **acknowledging** on the active item using the current claim token.
2. Mark the matching idempotency receipt acknowledged.
3. Remove the active item from its segment.
4. Recovery of an acknowledging item completes steps 2-3 and never re-runs the handler. If the process dies before step 1 commits, delivery may repeat; application-side idempotency remains necessary.

**Retry**

Persist ready plus available_at, last_error, attempt counts, and cleared claim fields. A retry becomes claimable only at available_at. Reconcile an uncertain write before starting another transition. After maximum attempts, use the dead-letter protocol rather than retrying indefinitely.

**Dead-lettering**

1. Persist **dead_lettering** in the active item under its claim token.
2. Upsert the separate dead-letter record idempotently by message ID and terminal lock token.
3. Update the idempotency receipt to dead-lettered if present.
4. Remove the active item.
5. Recovery repeats these transitions idempotently. A dead-lettering item must never be passed to the handler again.

**Dead-letter replay/discard**

Dead-letter claim tokens and replay tokens are separate from active claim tokens. Replay persists an intent, creates the active item with the original message ID and replay token, verifies the item, and then marks the dead-letter record replayed. If a crash leaves both records, reconciliation must finish without creating a second logical message. Discard persists an explicit terminal state before cleanup; deletion must never be the first record of the decision.

## 5. Option C: optional acceleration only

Add **queue_acceleration_enabled**, defaulting to false until measurements justify enabling it.

- Publish a compact MessagingService wake-up hint only after durable enqueue is verified. The hint contains routing and message identity, not the authoritative payload.
- An optional MemoryStore queue/hash-map may hold short-lived message-ID hints, wake-up coalescing keys, or short-lived scheduling metadata. Use short explicit TTLs; handle throttling, eviction, quota exhaustion, and unavailable service as normal acceleration failures.
- Every hint consumer must claim the actual item through DataStore using durable segment state and the current claim token. Never acknowledge or grant an effect solely because MemoryStore or MessagingService says a message exists.
- Keep the bounded DataStore polling path enabled as recovery. Missing, duplicated, reordered, expired, or forged hints cannot drop a durable message or bypass owner/token checks.
- Do not add MemoryStore until deterministic queue tests and the baseline benchmark show a measurable benefit. If it adds requests or latency without useful gain, leave it disabled or remove the accelerator without changing the durable protocol.

Roblox documents MessagingService delivery as best-effort and not guaranteed. Messaging topics are limited to 80 characters and messages to 1 KiB. MemoryStore is ephemeral, TTL-based, and subject to game-level and per-structure/per-partition quotas. Neither service is a durable broker.

## 6. Handler safety patterns

### Purchase grants

A grant handler must carry an application idempotency key such as a stable purchase receipt identifier. In the same authoritative application record that applies the grant, atomically record the receipt key and resulting grant state in one UpdateAsync transform. If the receipt key already exists, return the recorded outcome without applying the grant again. The transform itself must remain pure and non-yielding.

Do not rely solely on queue acknowledgement. A crash can occur after the application grant commits and before queue acknowledgement. Redelivery must encounter the durable receipt ledger and become a no-op.

### Cross-profile transfers

A transfer across two profile keys cannot be made atomic by the queue. Use a transfer ID and a saga/escrow protocol: persist source-side intent/reservation, apply destination credit idempotently under a destination-side transfer ledger, and finalize the source reservation only after durable destination confirmation. Reconcile incomplete transfers after crashes and define compensation/refund behavior for a permanently unavailable destination. Two independent profile UpdateAsync calls are not one transaction.

### Yielding handlers

Preserve existing non-yielding **on_queue_message** behavior. Add a separate opt-in async callback for operations that must await Roblox APIs. Its claim must be renewed by a worker-owned heartbeat, and processing must stop after session or claim fencing is detected. This cannot cancel or roll back an external effect that already committed; async handlers still need idempotency keys and must not perform irreversible work before their durable deduplication boundary.

## 7. Observability

Add an additive typed **GetQueueStatsAsync()** snapshot exposing, where observable:

- active count and oldest active message age;
- claimed items and expired-claim recoveries;
- attempts/retries scheduled and next retry timing;
- acknowledgement-in-progress count and acknowledgement failures;
- dead-letter count, oldest dead-letter age, and retention eligibility;
- enqueue conflicts, duplicate submissions, saturated segments, and uncertain-write verification failures;
- last poll, last successful processing, and acceleration-hint failures.

Include observation time and whether the view is complete. A multi-key scan is not a transaction, so do not call it a linearizable global snapshot. Persist counters only when repeated transitions can update them idempotently; label process-local counters as resettable since-server-start metrics.

Keep **Stats()** backwards compatible. Add paginated **ListDeadLettersAsync(cursor, page_size)** for large dead-letter histories. Retain **GetDeadLettersAsync()** as a compatibility helper with an explicit bound/deadline outcome rather than silently returning an incomplete list. Observer callbacks happen outside DataStore transforms and are never required for recovery.

## 8. Migration and rollback

The current v3 queue key contains owner identity plus active and dead-letter lists. The older legacy queue key may not contain verifiable owner metadata; preserve the current behavior of refusing automatic migration for a non-empty legacy queue and report manual recovery as required.

Mailbox v2 activation uses a future-version sentinel in the old v3 key as a migration freeze. The marker preserves the v3 messages and dead letters and identifies migration state, but its implementation version is newer than v3, causing old binaries to refuse writes rather than mutate a queue they cannot understand.

Migration protocol:

1. Validate owner identity and ensure the unsupported legacy queue is empty. Never overwrite corrupt or owner-mismatched data.
2. Atomically transform the current v3 envelope into a frozen sentinel while preserving its exact messages and dead letters. Old v3 transforms then see a future version and must not modify it.
3. Treat the frozen payload as an immutable migration source. Copy active messages into mailbox segments and dead letters into independent records, preserving IDs, timestamps, attempts, replay counters, errors, and safe lock state.
4. Make imports idempotent by owner, source version, and message ID. Verify every copied item and dead letter.
5. Write mailbox v2 activation only after all data is verified. Keep the frozen v3 source as a read-only recovery copy; do not delete it automatically.
6. If a server stops at any point, the next compatible server resumes from the frozen source. Do not run handlers from a partial import.
7. After activation, old binaries must fail closed on the future-version sentinel. Rollback must use a compatible binary that reads mailbox v2. Downgrading to v3 requires a separately verified reverse migration after quiescing the queue and proving all active and dead-letter data fits the old limits. Never silently fall back to an empty old queue.

The sentinel matters because older code does not know about a separate route marker. It prevents stale v3 writers from appending to the old envelope after migration begins. A non-empty ownerless legacy queue remains a hard stop rather than being guessed into the new format.

## 9. Tests and fault injection

Build a deterministic fake DataStore service that exercises the **production RecordStore path**, not only RecordStore.Mock. It needs per-key atomic UpdateAsync behavior, configurable delay/budget, failures before and after commit, stale-read modes where relevant, and controllable crash points. It must not call real Roblox services or mutate test state from UpdateAsync transforms.

Required correctness coverage:

1. Same idempotency key and same request, sequential and concurrent: one logical ID; duplicates return it.
2. Same key and different request: conflict; no payload substitution.
3. Simulated hash collision and owner mismatch: fail closed; never cross-read or cross-write.
4. Enqueue crash after receipt reservation, segment write, receipt commit, and hint publication; accepted messages remain discoverable and retry creates no second logical message.
5. UpdateAsync fails before commit versus commits then returns an error; outcome is verified, not guessed.
6. Concurrent enqueue across segment capacity and rollover; stale writers targeting sealed segments retry safely.
7. Concurrent claims, repeated claims, lease renewal, expired claims, stale acknowledgements, and session generation changes.
8. Handler returns true then process crashes before acknowledgement; redelivery is allowed and the sample handler's durable ledger applies the effect once.
9. Crash at every acknowledgement step; acknowledging recovery never re-runs a successful handler.
10. Handler rejects, throws, or yields; maximum attempts, exponential backoff, and delayed retry eligibility.
11. Crash during every dead-letter transition; dead-letter persistence is independent of active capacity and repeated recovery creates one DLQ record.
12. Dead-letter claim/replay/discard with stale tokens, replay idempotency, and crashes between source/destination writes.
13. Dead-letter retention, idempotency retention, saturated segments, and recovery after server shutdown.
14. MessagingService failure, dropped/duplicated/reordered hints, MemoryStore eviction/throttling/quota failure, and disabled acceleration; polling still recovers accepted messages.
15. Migration from empty and non-empty v3 queues, malformed/future versions, corrupt values, wrong owner, interrupted copy, and old v3 writes racing with the freeze sentinel.
16. Paginated DLQ inspection and metrics under large histories; no silent truncation and no unbounded single-value rewrite.
17. Shutdown during claim, handler, acknowledgement, retry, dead-lettering, and migration.

Keep UpdateAsync transforms pure and non-yielding in tests and production. Assert that observer dispatch, MemoryStore, MessagingService, task waits, GUID generation, and mutable scheduler actions never run inside transforms.

## 10. CodSpeed performance plan

The latest recorded main run (6ad31bfd3b85786a778fc5bf, commit 4f6d7d3) has 20 benchmarks covering CodeNum, compatibility regression, profile updates, startup, and session lifecycle. It has no dedicated durable-queue workload. Hosted WallTime measurements are flagged as environment-variable/noisy, and ten simulation benchmarks are noted as syscall-dominated. Those runs are not queue latency measurements.

Add CodSpeed scenarios for:

- append/claim/ack with empty, partially filled, and full segments;
- depths of 1, 32, 256, 1,000, and the configured maximum;
- dead-letter histories of 0, 100, 1,000, and 10,000 records, proving they do not enlarge active-segment updates;
- idempotent enqueue for a new key versus a repeated key;
- retries/backoff, expired-claim recovery, replay, migration, and uncertain write outcomes;
- concurrent producers and partition-count candidates;
- acceleration disabled versus enabled, measuring request count, hint hits, fallback polls, CPU overhead, and latency;
- production-path fake DataStore workloads with ample and constrained request budgets.

Use the CodSpeed CLI and MCP results for tracked performance claims. Simulation helps measure deterministic CPU work, not Roblox service latency. Hosted WallTime requires comparable environments. A fake service is a model, not a live Roblox quota test. Do not change defaults or claim a performance win unless comparable CodSpeed results improve without correctness, memory, or constrained-budget regressions. Roblox Studio/server playtests must separately verify throttling and cross-server behavior.

## 11. Implementation phases and acceptance criteria

### Phase 0: design and test contract

- Review and approve this design.
- Add state-machine documentation, API compatibility tests, fault-injection seams, and the production-path fake DataStore harness.
- Record a baseline and ensure new tests expose the current failure modes.

### Phase 1: Option A correctness slice

- Add idempotent enqueue, explicit outcomes, retry scheduling, lease fencing/renewal, acknowledgement recovery, dead-letter transition recovery, and retention rules.
- Preserve old calls and callback behavior.
- Add queue observability and negative tests for uncertain outcomes.

### Phase 2: Option B mailbox v2

- Implement manifest, bounded segments, separate receipts and dead letters, rollover recovery, and migration.
- Implement the freeze sentinel and retain the old source as a recovery copy.
- Keep mailbox v2 behind an explicit layout setting until migration and playtest criteria pass.

### Phase 3: cross-server and async processing

- Add opt-in async handlers with heartbeat and session/claim fencing.
- Test lease expiry and shutdown while an async handler is suspended.
- Document idempotent purchase-grant and transfer/escrow patterns.

### Phase 4: Option C acceleration and measurement

- Add the optional MemoryStore/MessagingService hint path, disabled by default.
- Benchmark against the durable polling baseline. Leave it disabled without a measured benefit.
- Add operational metrics and large-backlog/dead-letter workloads.

### Phase 5: rollout decision

- Verify the Lune regression suite, Studio compatibility project, fake-service integration tests, fault-injection matrix, and CodSpeed runs.
- Do not enable mailbox v2 by default until tests pass and migration/rollback has been exercised.
- Do not claim exactly-once effects or live-service optimality. Publish residual limits in the README and API types.

Acceptance is evidence-based: accepted idempotent sends cannot disappear; uncertain results can be retried with the same key; duplicate notifications cannot compromise ownership; crash recovery preserves active and dead-letter work; dead-letter growth cannot fill active segments; migration never overwrites source data; measured improvements are reported separately from unverified live Roblox behavior.

## 12. Roblox references

- [Data stores](https://create.roblox.com/docs/cloud-services/data-stores): UpdateAsync transforms must not yield; writes to separate keys are not one transaction.
- [Data store error codes and limits](https://create.roblox.com/docs/cloud-services/data-stores/error-codes-and-limits): documented key names are limited to 50 characters and one data key value to 4,194,304 bytes; UpdateAsync consumes read and write budget.
- [Data store versioning, listing, and caching](https://create.roblox.com/docs/cloud-services/data-stores/versioning-listing-and-caching): ListKeysAsync has its own request budget; read-after-write verification must account for caching.
- [MessagingService](https://create.roblox.com/docs/reference/engine/classes/MessagingService/SubscribeAsync): cross-server delivery is best effort with topic and message-size limits.
- [Memory stores](https://create.roblox.com/docs/cloud-services/memory-stores): MemoryStore is ephemeral, TTL-based, and subject to quotas; it is not a durable source of truth.
