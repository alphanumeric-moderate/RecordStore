# RecordStore durable messaging v2: correctness-first architecture

- Date: 2026-10-17
- Status: Revised design; supersedes the earlier design wherever they conflict
- Scope: durable mailbox, message processing, transactional outbox/inbox, and recoverable workflows
- Related PRs: #31 (configuration/observer design), #32 (initial durable-messaging design)

## Executive decision

Build a durable messaging subsystem that is more than a replacement for `ProfileStore:MessageAsync()`. The design combines:

1. **Correctness-first mailbox**: at-least-once delivery, producer idempotency, per-message authoritative state, append-only bounded segment indexes, persisted retry/backoff, claim fencing, acknowledgement recovery, and an independent dead-letter index.
2. **Transactional outbox/inbox**: atomically commit profile-data changes with outbound intent, and atomically apply inbound message effects to one profile key with a deduplication receipt.
3. **Recoverable sagas**: compose idempotent per-profile steps for transfers and other multi-record workflows without pretending that multiple DataStore keys form a transaction.
4. **Operator-grade delivery tooling**: delivery receipts/status, transition history, schema-aware replay, paginated dead-letter inspection, health diagnostics, and bounded repair.
5. **Optional acceleration**: MemoryStore and MessagingService may wake workers or provide hints; they never own correctness.

The previous proposal placed full message objects, active state, and dead letters in segmented envelopes. This revision separates the **canonical message record** from the **append-only segment index**. Claims, retries, acknowledgements, and terminal transitions update one message key rather than rewriting the segment. This reduces write amplification and makes cross-key recovery state explicit.

No feature described here is implemented by this document. It is a design contract. New layout and envelope fields stay disabled until compatibility, failure-injection, migration, rollback, and live Studio/server acceptance criteria pass.

## 1. Guarantees and non-goals

### 1.1 Delivery guarantee

The mailbox provides **at-least-once delivery**. A handler may execute more than once if the process stops after a side effect but before a durable acknowledgement, if a claim expires, or if a service returns an ambiguous result. An acknowledged message must not be offered for execution again by mailbox recovery.

Do not call arbitrary handlers exactly-once. RecordStore can provide a stronger, narrowly-scoped guarantee for a mutation and its deduplication marker committed together to one RecordStore profile key. That is **effectively-once profile mutation within the retained inbox-receipt window**, not exactly-once behavior for web services, other DataStore keys, MessagingService, or arbitrary user code.

### 1.2 Atomicity boundary

Roblox DataStore `UpdateAsync` is atomic for the key being updated; it does not create a transaction across multiple keys. Any protocol that touches a manifest, segment, receipt, message record, profile record, dead-letter index, or saga record must persist intermediate states and recover them idempotently.

Inside every `UpdateAsync` transform:

- do not yield;
- do not call MessagingService, MemoryStore, HTTP or another DataStore;
- do not dispatch observers, acquire a process mutex, wait on a task, or change scheduler state;
- do not generate GUIDs or read wall-clock/time-dependent values that would change on retry;
- do not perform irreversible application side effects.

Prepare stable IDs and timestamps before calling `UpdateAsync`. Transform callbacks supplied by consumers must be pure, deterministic for the same input, and non-yielding because Roblox can invoke a transform more than once.

### 1.3 Durable results and uncertain outcomes

New APIs return a typed result in addition to preserving existing result-code methods for compatibility. At minimum, distinguish:

- `accepted`: durable intent and canonical message state were verified;
- `duplicate`: the producer key matched an existing submission with the same exact canonical request;
- `conflict`: the same producer key was reused for a different request, owner, or incompatible protocol state;
- `capacity`: no durable space is available and no message was accepted;
- `retryable`: no final conclusion was reached and the same operation key may be retried;
- `unknown`: the caller must not infer commit or non-commit; verify or retry with the same idempotency key;
- `processed`, `acknowledged`, `retry_scheduled`, `dead_lettered`, and `discarded`: durable lifecycle states, not publish results.

A successful MessagingService publish means only that publish succeeded. A MemoryStore enqueue means only that an ephemeral hint was recorded. Neither proves that a durable message exists or that a handler completed.

### 1.4 Backpressure instead of silent loss

Each record family has explicit item and byte limits. When a queue, outbox, inbox-dedup ledger, or workflow reaches its configured bound, the API returns a capacity result before committing a partial user mutation. Never silently drop an accepted message, discard the oldest receipt, or mark a message processed because storage is full.

## 2. How RecordStore should differ from ProfileStore

The current public ProfileStore documentation describes session locking, autosaving, reconciliation, profile reads/version queries, and durable per-profile `MessageAsync()` with `MessageHandler()`/processed acknowledgement. Therefore, **durable messages alone are not a differentiator**, and this design must not claim ProfileStore lacks durable messaging.

The unique value is the combination of capabilities below. Statements about ProfileStore refer to the public API documented in its current repository; they do not assert that no internal implementation detail could be similar.

| Capability | ProfileStore documented surface | RecordStore proposal |
| --- | --- | --- |
| Profile session lock and autosave | Yes | Preserve session ownership/fencing and current persistence guarantees |
| Message sent to a profile and processed by its active session | `MessageAsync()` and `MessageHandler()` | Keep an easy profile-targeted send path, plus explicit durable lifecycle state and receipt inspection |
| Producer idempotency key that deduplicates a retried submission | No equivalent documented parameter/contract found | Stable logical ID; exact-request comparison; same-key retry returns original outcome; mismatched request conflicts |
| Independent segmented mailbox and independent dead-letter storage | No equivalent documented public queue/DLQ API found | Bounded append-only ID indexes and per-message authoritative records, separate DLQ index, paginated inspection and replay |
| Persisted retry schedule, leases, claim fencing, ack recovery | No equivalent documented public queue state-machine API found | Explicit `available_at`, claim lease/token, bounded backoff, ack/dead-letter recovery states |
| Delivery status query and transition trace | No equivalent documented message receipt/history API found | `GetDeliveryAsync` with status, attempts, next retry, terminal reason and bounded transition history |
| Transactional outbox with profile mutation | No equivalent documented public API found | One profile-key update commits data and outbound intent together; dispatcher publishes idempotently later |
| Atomic inbox deduplication with a profile mutation | No equivalent documented public API found | One profile-key update commits the reducer result and the message receipt together |
| Multi-profile workflow/saga recovery | No equivalent documented public workflow API found | Optional saga coordinator that resumes idempotent steps and compensations |
| Schema-aware message validation and safe dead-letter replay | No equivalent documented queue/replay API found | Versioned payload codecs, validation-before-replay, replay audit and operator-controlled retention |
| Queue/outbox/inbox health snapshots | ProfileStore exposes critical-state/error signals for its profile operations | RecordStore adds bounded, explicitly approximate queue and workflow diagnostics without using metrics for correctness |

Primary comparison references:
- ProfileStore README: https://github.com/MadStudioRoblox/ProfileStore/blob/main/README.md
- ProfileStore API: https://github.com/MadStudioRoblox/ProfileStore/blob/main/docs/api.md

The differentiators should be released as individually useful APIs. The mailbox remains useful without sagas; outbox/inbox remains useful without MemoryStore; the optional accelerator can be removed without changing durable semantics.

## 3. Public API proposal

Names are provisional. Preserve existing two-argument `Record:EnqueueAsync(type, data)`, `Record:MessageAsync(type, data)`, `ProcessQueueAsync()`, `GetQueueAsync()`, `GetDeadLettersAsync()`, and `Stats()` behavior unless a separately reviewed compatibility change is approved.

### 3.1 Enqueue without requiring the target profile to be open

Add a store-level operation analogous to:

```lua
local result = RecordStore.EnqueueToAsync(
    store_name,
    scope,
    profile_key,
    message_type,
    payload,
    {
        idempotency_key = "purchase:receipt-id",
        payload_version = 1,
        available_at = nil,
        expires_at = nil,
        correlation_id = nil,
        ordering_key = nil,
    }
)
```

This lets a server durably submit work for an offline profile without holding or fabricating an active Record session. Only the legitimate active Record session may execute that profile's handlers. The store-level submitter cannot claim a message or bypass session fencing.

Existing `Record:EnqueueAsync(type, data)` remains a convenience method; it delegates to the same submission protocol. A third options argument is additive. For valuable/irreversible work, require a caller-stable idempotency key. Canonicalization must be a deterministic, versioned serializer: dense arrays preserve order; string-keyed object keys are sorted; sparse arrays, mixed array/object shapes, cycles, unsupported values, and non-finite message numbers are rejected unless an explicit versioned codec supports them. Do not assume raw HttpService JSONEncode output is a canonical fingerprint unless stable key ordering is guaranteed. Retain exact canonical request material throughout the advertised deduplication window; a short hash alone does not prove equality. Calls without one get a unique submission, and an ambiguous outcome cannot be safely deduplicated by repeating the whole call.

### 3.2 Query delivery outcome

Add `RecordStore.GetDeliveryAsync(store_name, scope, profile_key, message_id)` and/or `Record:GetDeliveryAsync(message_id)`. Return a single canonical message snapshot:

- message ID, owner identity, type, payload schema version;
- lifecycle state, created/updated time, current attempt and total attempts;
- next eligibility time, current claim expiry when relevant;
- terminal result, bounded last error and replay count;
- correlation/causation IDs and bounded transition history;
- whether the response came from the canonical durable message record or is incomplete.

Do not expose a `processed` result based on MessagingService or MemoryStore. A status read is not a transactional snapshot across the entire mailbox; one message record is authoritative for that message.

### 3.3 Atomic inbox operation

Add a profile method analogous to:

```lua
local result, message = record:ApplyInboxAsync(
    message_id,
    message_type,
    payload,
    function(current_data, message_payload)
        -- Pure, deterministic data reducer only.
        return copy_and_apply(current_data, message_payload)
    end
)
```

The API compares exact canonical `message_type + payload + target owner` request material against the retained receipt. The same ID and same request returns `duplicate`; the same ID with a different payload, type, or owner returns `conflict`.

In one UpdateAsync on the same profile key, apply the reducer result and persist the deduplication receipt. The reducer runs inside an UpdateAsync transform and may be invoked multiple times. It must not yield or perform external side effects. The per-Record write gate serializes it with local mutations, flushes pending dirty state first, and rebases the in-memory snapshot after commit. For irreversible game actions, keep the domain idempotency key in the application's own durable state for as long as the business rule requires. The inbox receipt window is not a substitute for a permanent purchase-receipt ledger.

Serialize this operation through the Record's write gate: stop concurrent local mutators, flush pending local dirty data, then apply the reducer to the current durable envelope. If flushing fails or its outcome is unknown, do not proceed from a stale cache. After commit, rebase the in-memory Record to the committed data/revision before releasing the gate. This API must never discard unsaved local mutations or overwrite a newer snapshot.

### 3.4 Transactional outbox operation

Add a method analogous to:

```lua
local result, snapshot = record:CommitWithOutboxAsync(
    "shop-purchase:operation-123",
    "ShopPurchase",
    { item_id = "sword_01", recipient_key = "player_456" },
    {
        {
            target_store = "PlayerData",
            target_scope = "global",
            target_key = "player_456",
            type = "ItemGift",
            payload_version = 1,
            data = { item_id = "sword_01" },
        },
    },
    function(current_data, command)
        -- Pure, deterministic reducer. Outbox events are explicit inputs.
        return copy_and_apply_purchase(current_data, command)
    end
)
```

The API accepts an explicit command type, canonical command payload, and explicit bounded outbound event list; it does not try to fingerprint a Lua callback or infer event intent from arbitrary side effects. One UpdateAsync on the source profile key commits the data mutation, exact-request commit receipt, and bounded outbox entries together. Stable event IDs derive deterministically from the stable commit key and event ordinal before the transform. The same commit key with a different command type, payload, or event list returns conflict.

Serialize the operation through the Record write gate: flush pending local dirty data, block local mutators while the durable transform runs, and rebase the live cache/revision after commit. If the dirty flush has an unknown outcome, stop and reconcile instead of applying the command to stale data.

### 3.5 Recoverable workflow/saga API

Add an optional companion module, for example `RecordStore.Workflow`, after inbox/outbox correctness is established. Its durable API should provide:

- stable workflow ID and exact-request idempotency;
- named, versioned steps with checkpoints and status;
- step input/output summaries that avoid storing secrets;
- bounded retry policy and next retry time;
- idempotent per-record actions through `ApplyInboxAsync`;
- explicit forward recovery or compensating steps;
- status query, cancellation request, and operator-visible stuck-step reason.

A saga is eventually consistent, not a cross-key ACID transaction. Never name it `AtomicTransfer` or claim that source and destination balances change simultaneously.

## 4. Corrected durable storage architecture

### 4.1 Record families

Use the configured queue DataStore name and scope with a versioned mailbox namespace. The full record owner is `(store_name, scope, profile_key)`. Every route, receipt, segment, message, dead-letter and manifest value must store and validate the full owner; a hashed key prefix is only a routing aid.

The layout consists of:

1. **Constant-bounded manifest** per owner and partition: protocol version, full owner identity, immutable partition count, activation/migration state, a fixed-size segment-slot table, per-slot generation/state/current segment key, and a scan hint. The table is capped at the configured maximum (initially 64); it never grows with message count.
2. **Append-only segment index**: bounded entries containing message ID plus placement generation, not payload, retry state, or dead-letter history. Appending is idempotent; message processing never rewrites this index entry. Segment keys include both slot and generation so a reused slot cannot alias an older segment.
3. **Canonical message record**: one DataStore key per message ID. It owns payload, schema version, current lifecycle state, retry scheduling, attempt counters, claim token/expiry, current segment locator and generation, idempotency-receipt reference, correlation IDs, terminal reason and bounded transition history.
4. **Submission receipt**: maps an owner-scoped producer idempotency key to one stable message ID and canonical request identity. It stores reservation/acceptance state, placement generation and timestamps. The exact request representation remains available for the configured deduplication window, so a hash collision cannot silently equate two payloads.
5. **Independent dead-letter index**: separately segmented IDs for messages in dead-letter state. The canonical message record retains the payload/error needed for inspection and replay. A growing DLQ cannot consume active-segment capacity.
6. **Profile-local inbox and outbox fields**: bounded sidecars in the profile envelope, so the data mutation and its corresponding inbox receipt/outbox intent can be committed in a single UpdateAsync. These fields require a versioned profile-envelope migration and explicit rollout gating.

A per-message canonical record costs more keys and service calls than one large queue envelope, but eliminates rewrites of unrelated message payloads on claim/ack and isolates hot-key traffic. CodSpeed and constrained-budget workload evidence must determine usable defaults rather than assuming this is always cheaper.

### 4.2 Roblox key names and collision rules

Roblox DataStore key names are limited to 50 characters. Define and test a stable key codec for every route, message, segment, idempotency, and DLQ key. Include store/scope/owner identity in the stored value, not only in the key name.

- Use fixed-length routing digests to fit names. Document the exact deterministic hash implementation; do not assume Roblox provides a cryptographic hash function.
- On every read/update, compare the complete stored owner and logical ID to the requested values.
- If two inputs map to the same routing key but differ in full identity, fail closed with an explicit route-collision error. Never read, mutate, or overwrite the other owner's record.
- Hash collisions must not silently alias idempotency keys. If collision slots are not implemented and verified, the accepted behavior is a safe conflict, not automatic merging.
- Test maximum-size store, scope and profile keys as well as generated IDs. Verify encoded serialized bytes, not character estimates.

### 4.3 Boundaries and initial defaults

Initial values are benchmark candidates, not production claims:

- one partition by default; partition count is immutable after activation;
- at most 32 message IDs per active segment;
- at most 250,000 encoded bytes per segment index, even though it contains only IDs;
- at most 64 live segment slots per partition initially; slots can be reclaimed out of order after all entries are terminal or stale, so a delayed old item does not pin all later completed slots;
- each reused slot gets a strictly increasing generation encoded into its segment key; generations never wrap or reuse an old key;
- at most 64 KiB encoded payload per message by default, configurable only within validated service/key limits;
- retain the current 60-second claim lease and 10-second polling defaults until queue-specific measurements justify changes;
- deduplication and dead-letter retention must be explicit. Never expire a dedup receipt before the advertised idempotency window.

The number of message IDs per segment is not the same as maximum pending backlog. Segments may be reclaimed only after every referenced message is terminal or safely re-routed and the segment is sealed. Deleting a segment key is not the acknowledgement of any message in it.

### 4.4 Segment rollover and append protocol

The segment index is a discovery aid; the canonical message record and its receipt decide whether an indexed ID is deliverable. The manifest uses a fixed-size slot table rather than a monotonically contiguous head/tail range. This allows out-of-order slot reclamation when an old delayed item remains pending.

1. Reserve a stable message ID and target (slot, generation) in the submission receipt. Generate candidate GUIDs before UpdateAsync; retries reuse the winning ID.
2. Create the canonical message record in `preparing` state. Repeated creation with the same owner/request is idempotent; a conflict fails closed.
3. Append (message ID, placement generation) to the selected segment with UpdateAsync. Append requires that the target segment key already exists for the generation published in the manifest. A missing/retired key is rejected rather than implicitly initialized. Repeating the same append returns the existing entry.
4. If append returns an ambiguous error, do not move the receipt to a different segment. Repeat the idempotent append/verification on the same key until the ID is known present or the deadline returns `unknown`. Never infer absence from a cached GetAsync or timeout.
5. If the segment is full, seal it with a compare-and-set UpdateAsync. Once sealed, no append is accepted. The allocator increments a free slot's generation, creates and verifies its empty segment key, then publishes the slot as open with a CAS. Multiple allocators may race, but only the manifest-published generation is valid.
6. Retarget a preparing receipt/message only after the previous segment is confirmed sealed and the index pair is confirmed absent. Increment the placement generation. Stale writers to an old generation see a sealed or missing key and cannot append. Workers require the index generation to match the canonical message locator.
7. Once the index entry is present, mark the receipt accepted only if its reservation and placement generation still match. Then promote the canonical message to `ready`. Only `ready` messages can be claimed.
8. If the server stops mid-protocol, a repeated submission with the same idempotency key or a worker inspecting the indexed preparing entry can resume it. Recovery may finalize a reservation only after verifying the exact owner/request and matching index pair. If there is no index entry and the receipt is not accepted, the request was not reported as accepted; use the same key to resolve an ambiguous submit.
9. An index row is deliverable only when owner, slot, segment generation, message ID and placement generation match the canonical message. Duplicate or stale rows are skipped. Claim is still a CAS on the canonical message record.

Slot lifecycle:

- Slots transition through `empty -> allocating -> open -> sealed -> draining -> empty`. Manifest transitions are compare-and-set operations.
- A slot can be reclaimed only after a bounded scan proves every index entry terminal or stale. Keep canonical message/receipt tombstones until their idempotency and diagnostic-retention rules permit deletion.
- A slot generation is part of the segment key and strictly increases. A segment key is never reinitialized for another generation. Only the allocator may initialize a new segment, and append to a missing generation is rejected; this prevents an old delayed writer from recreating a purged index.
- Reclaim slots out of order to avoid head-of-line capacity loss. Polling scans the fixed slot table fairly; it does not assume a contiguous range.
- Accepted messages are not relocated simply because another slot becomes available. Relocation is allowed only while preparing and after the previous segment is sealed and the index pair verified absent.
- The manifest is rewritten only on slot allocation/reclamation, not each enqueue or lifecycle transition. Segment ID arrays are rewritten only on append/seal, never on claim, retry or acknowledgement.

### 4.5 Lifecycle state machine

Canonical message states:

- `preparing`: submission is not yet claimable; index/receipt reconciliation is permitted.
- `ready`: accepted and eligible after `available_at\).
- `claimed`: current claim token and lease fence the worker.
- `acknowledging`: handler success is recorded; recovery finishes acknowledgement without invoking the handler again.
- `dead_lettering`: terminal failure is recorded; recovery finishes DLQ indexing without invoking the handler again.
- `acknowledged`, `dead_lettered`, `discarded`, `expired`: terminal states.

Allowed transitions are validated in the canonical message's UpdateAsync transform. A stale claim cannot acknowledge, renew, retry, discard or dead-letter a message. Terminal states are monotonic except an explicit replay operation, which increments the replay generation and creates a new active placement. Old index entries have older placement generations and are ignored.

### 4.6 Claim, retry and acknowledgement

**Claim:** atomically change `ready` to `claimed`, increment attempts, assign a token and lease expiry, and record processing server/session generation. A concurrent claimant can win only one CAS. A message is not claimable before `available_at`. Claim tokens are generated before the transform.

**Renewal:** renew only when the persisted token and current state match and the owning profile session is still active with the expected fencing generation. Renewals have a maximum extension/deadline to prevent permanently stuck handlers. An expired token cannot renew itself.

**Retry:** under the live token, persist `ready`, cleared lock fields, normalized last error, attempt counters and an explicit next `available_at`. Use capped exponential backoff with deterministic/injected jitter. Limit total attempts and delivery age. The next handler must not run before the stored time. At attempt/age limits, transition to `dead_lettering`.

**Acknowledgement:**
1. Persist `acknowledging` under the current token.
2. Update the producer receipt to acknowledged if it exists.
3. Persist the canonical message as acknowledged.
4. Recovery repeats steps 2-3 idempotently and never invokes the handler for an `acknowledging` message.

If the handler effect committed but the state never reached `acknowledging`, redelivery is possible. This is why the atomic inbox pattern is a first-class API.

**Dead-lettering:**
1. Persist `dead_lettering` under the current token.
2. Append the message ID and terminal generation to the independent DLQ index idempotently.
3. Update the producer receipt, if any.
4. Persist `dead_lettered`.
5. Recovery repeats the same transitions idempotently. `dead_lettering` is never eligible for user handler execution.

No DataStore callback may perform any of these transitions by directly calling another key's API inside the transform.

## 5. Transactional inbox: safer message effects

### 5.1 Atomic mutation plus receipt

`ApplyInboxAsync(message_id, message_type, payload, reducer)` updates the recipient's primary profile envelope in one UpdateAsync. Its transform checks the retained inbox receipt, applies the pure reducer to the current durable data, and records the message ID plus exact canonical request identity in the same envelope. A matching receipt returns the stored prior outcome without running the reducer again. A mismatched message type/payload/owner returns conflict.

Before entering this transform, serialize the operation through the Record's write gate: block local mutators, flush pending dirty data, then apply the reducer to the current envelope. If flushing fails or its outcome is unknown, do not proceed from a stale cache. On successful commit, rebase the in-memory Record to the committed data/revision before releasing the gate. On an ambiguous commit, reconcile by the stable message ID and receipt before allowing a second mutation.

The reducer may run multiple times and must be pure, deterministic and non-yielding. If it throws, yields, or returns an invalid value, abort both the data mutation and receipt insertion. This provides at-most-once application of that reducer to the one profile key while the receipt remains retained. Delivery may repeat, but the same persisted profile mutation does not. It does not protect side effects outside the same UpdateAsync or make another profile key part of the transaction.

### 5.2 Receipt retention and capacity

Inbox receipts must be versioned and bounded by both entry count and encoded bytes. Define an advertised deduplication window that is at least as long as the maximum queue retry/replay window. Refuse new inbox commits with a capacity result when pruning would violate the advertised window; do not evict a live receipt to make space.

For purchase receipts that must remain deduplicated indefinitely, applications keep the purchase identifier in durable domain state or a permanent ledger. Do not claim lifetime deduplication after a finite inbox receipt has expired. Receipt pruning is allowed only after expiry and must preserve the documented replay policy.

## 6. Transactional outbox: remove the dual-write gap

### 6.1 Atomic commit

`CommitWithOutboxAsync(commit_key, command_type, command_payload, outbox_events, reducer)` performs one UpdateAsync against the source profile key. The reducer returns the next profile-data value. The same transform writes:

- next profile data;
- an exact-request commit receipt keyed by `commit_key`, including the canonical command and event list identity;
- stable outbox event IDs derived deterministically from `commit_key` and event ordinal;
- each event's schema version, target identity and correlation/causation fields.

Canonicalize the command and bounded event list before entering the transform. The reducer must be deterministic, pure and non-yielding; Roblox may invoke it more than once. An already-committed key with the same exact request returns its prior outcome without applying the data mutation again. The same key with a different command, payload or event list conflicts.

Serialize this operation through the Record write gate: block local mutators, flush pending local dirty data, then run the durable transform. If flushing fails or is ambiguous, do not apply the command to a potentially stale envelope. After a confirmed commit, rebase the in-memory data, revision and saved snapshot before releasing the gate. If the result is uncertain, reconcile through the stable `commit_key` rather than applying a new operation.

The transform rejects the entire operation when the outbox byte/item budget would be exceeded. The profile mutation and outbound intent are committed together; neither is allowed to commit alone.

### 6.2 Dispatch and cleanup

The dispatcher reads durable pending outbox events, then enqueues each to the mailbox using its stable event ID as producer idempotency key. Only after the destination receipt is verified does it mark/remove the source outbox event. A crash between destination acceptance and source cleanup replays the same event ID and returns the original mailbox message.

The dispatcher may run when the source profile is not open. It may update only the outbox sidecar in the source envelope and must preserve the current data, session, revision, inbox and all unknown-compatible fields from the UpdateAsync transform's current raw value. It must not write a stale full-envelope snapshot. Normal session saves and inbox/outbox transactions must also preserve any newer sidecar state read by their transforms.

Reading pending outbox events may use GetAsync as a discovery hint; the dispatcher must CAS the current source envelope before deleting an event and verify that the destination receipt is accepted. Cached/stale reads cannot cause the source intent to be removed.

### 6.3 Envelope compatibility gate

Inbox/outbox fields affect the primary record format and must not be added as unversioned optional fields that older code silently drops on save. Implement a new envelope version and a tested parser/writer compatibility window.

Before enabling the feature:
1. Ship a compatibility build that reads the previous format and understands the new version but keeps new fields/features disabled.
2. Drain or explicitly fence old servers so no old writer remains able to save the earlier envelope format.
3. Enable inbox/outbox writes only when the feature/version gate proves the running server is compatible.
4. Keep old source values and version history available for diagnosis; never auto-downgrade a record that contains new sidecars.
5. Rollback uses a compatible binary or a reviewed reverse migration after quiescing writers; it must not discard inbox receipts or pending outbox events.

## 7. Recoverable sagas for multi-profile operations

### 7.1 Why a saga instead of a false transaction

A trade/transfer touches at least two profile keys. Roblox does not provide a transaction across those keys. RecordStore must expose this as a recoverable workflow with temporary states, not an atomic cross-profile operation.

### 7.2 Transfer example

For transfer ID `T` from A to B:

1. Create a durable workflow record with exact request identity, source/destination, amount and step state.
2. On A, reserve funds and record inbox key `T:reserve` in the same source-profile UpdateAsync.
3. On B, credit the amount and record inbox key `T:credit` in the same destination-profile UpdateAsync.
4. On A, finalize the reservation and record inbox key `T:finalize`.
5. Mark the workflow complete only after each durable step is verified.

Every leg is replay-safe because the profile data mutation and step receipt share one key. A crash after a leg commits but before the saga checkpoint writes is harmless: replay of that leg returns its recorded outcome. If a step permanently fails, execute a defined compensation (such as release the source reservation) with its own idempotency key. Compensation is a new business operation, not rollback of history.

Workflow state is a checkpoint/projection; authoritative effects remain the per-profile inbox receipts and durable data. The reconciler compares them and resumes or compensates. Never assume the workflow record and the profile effects update atomically.

### 7.3 Failure policy

Every workflow specifies:
- a deadline and retry budget;
- retryable versus terminal errors;
- an operator-readable stuck state;
- a forward recovery path and, where safe, a compensation;
- whether compensation is automatic or requires operator approval;
- idempotency and retention requirements for each step.

A compensation cannot always reverse an irreversible external effect. Document manual resolution for non-compensable steps. Do not provide a built-in money-transfer helper until the generic inbox/outbox primitives and crash tests pass.

## 8. Scheduler, ordering and optional acceleration

### 8.1 Durable polling

Every mailbox always has a durable DataStore polling path. Workers maintain a local round-robin scan cursor over the manifest's fixed-size live slot table and scan a bounded number of IDs per tick. Slots can be reclaimed out of order, so the worker cannot assume a contiguous head/tail range. On restart, the cursor may reset; canonical message state makes repeat scans harmless. A delayed or claimed item must not block every later item unless the caller explicitly selected strict ordering.

For the first release, promise FIFO placement per partition only, not global FIFO execution across concurrent workers. With partition count greater than one, ordering is per partition. Strict per-`ordering_key` serialization is a later opt-in feature requiring tests for fairness, lease expiry and head-of-line behavior; do not imply that supplying an arbitrary key currently guarantees ordering.

Workers must:
- use GetAsync only to discover candidates; all owner/state/lease decisions are revalidated inside the canonical message's UpdateAsync transform against the current stored value;
- never infer that an ambiguous write did not commit from a cached read;
- check the canonical message state and placement generation before claim;
- cap scan work per call and per scheduler tick;
- advance cursors fairly to avoid starving segments with delayed retries or poison messages;
- apply backoff to DataStore/service errors rather than tight-loop polling;
- stop claims when owner session fencing or shutdown begins;
- never rely on a MemoryStore index for correctness.

### 8.2 MemoryStore and MessagingService

Keep acceleration disabled by default until it shows measured value.

- Publish compact wake-up hints only after a message is durably accepted.
- MemoryStore may keep expiring message-ID hints or wake-up coalescing tokens; it may lose, duplicate, reorder or evict them.
- A worker must reopen the canonical DataStore message and claim it through the durable protocol.
- Failed hint publication never changes durable enqueue result. Polling discovers work if every hint is dropped.
- Handle request budgets, TTL expiration, quotas and throttling as expected conditions. Never make correctness decisions from hint counts.

Roblox documents MessagingService delivery as best effort and not guaranteed; messages are limited to 1 KiB and topic names to 80 characters. MemoryStore is ephemeral with TTL-based eviction and quotas.

### 8.3 Future scheduling features

The canonical message schema should leave room for `available_at`, `expires_at`, `priority`, consumer/type policy, correlation/causation ID and a schema version. Initial support should implement delayed availability and optional expiry before priority scheduling.

Priority lanes and strict ordering should be enabled only after a starvation-proof scheduler is designed and benchmarked. Expired messages must reach a terminal `expired` state with a durable reason, not disappear silently.

## 9. Dead letters, replay and retention

### 9.1 Independent DLQ

Dead letters are canonical message records plus a separately segmented DLQ index. A dead-letter append is idempotent by message ID and terminal generation. No active segment size calculation may include historical DLQ records.

Expose:
- paginated `ListDeadLettersAsync(cursor, page_size)`;
- `ClaimDeadLetterAsync`, `ReplayDeadLetterAsync`, and `DiscardDeadLetterAsync` with fenced tokens;
- bounded last error, attempts, timestamps and replay history;
- retention eligibility and explicit purge outcomes.

A large DLQ is inspected page by page; no API silently materializes an unbounded history in one call. The legacy `GetDeadLettersAsync()` remains a bounded compatibility helper with a clear limit/incomplete result.

### 9.2 Replay safety

Replay is a new delivery generation of the same logical message ID. It atomically reserves a replay token on the canonical record, appends a new segment index entry with a larger placement generation, then transitions back to ready. The old segment row becomes stale and is ignored. Repeated replay requests with the same replay operation ID return the same outcome; a different replay request while one is pending conflicts.

Before replay, validate the message type and payload schema against the currently registered decoder/migration. Allow a dry-run validation result that shows the intended upgraded payload without changing durable state. Unknown future schemas remain quarantined; never force-rewrite them to an older guessed shape.

### 9.3 Retention rules

Retention is separate for completed message payloads, producer receipts, inbox receipts, outbox entries, dead letters and transition history. Defaults are conservative: retain pending work; do not auto-delete dead letters; retain dedup receipts for at least the advertised idempotency window.

Purge only terminal data that is past its declared retention and no longer referenced by a live index, pending workflow or source outbox. Purge transitions need audit IDs and must be idempotent. A retained receipt whose referenced message has been purged must either retain enough exact request identity to resolve duplicates safely or expire at the same time; never keep a misleading receipt that points to nonexistent data and returns a false success.

## 10. Operational observability

Add `GetQueueStatsAsync()`, `GetDeliveryAsync()`, `GetOutboxStatsAsync()`, `GetInboxStatsAsync()` and workflow status snapshots without breaking `Stats()`.

Useful fields include active/claimed/delayed/acknowledging/dead-lettering counts, oldest eligible age, oldest pending outbox age, expired claim recoveries, retry distribution, terminal error distribution, idempotent duplicate submissions, conflict/capacity/unknown outcomes, migration phase, segment count, scan cursor progress, hint failures, DLQ retention eligibility and stuck workflow step.

**Accuracy contract:** a scan across many keys is not a linearizable snapshot. Every multi-key stats result includes `observed_at`, scanned range, completeness, and whether counters are exact, approximate, or process-local. Approximate metrics must never control claim correctness, purging, admission, or migration. Exact message status comes from its canonical message key. A background reconciler repairs projections using idempotent operation IDs, and reports discrepancies rather than silently rewriting ambiguous state.

Do not log payloads, purchase tokens, player secrets or arbitrary user data by default. Provide correlation IDs and stable error categories while bounding the stored error text.

## 11. Migration, rollout and rollback

The existing queue v3 value stores active messages and dead letters together. Earlier legacy queue values may have no verifiable owner metadata; a non-empty ownerless legacy queue remains a manual-recovery stop.

### 11.1 Mailbox migration

1. Verify full owner identity, supported source version and queue shape. Corrupt or mismatched data is preserved untouched.
2. Atomically replace the v3 queue envelope with a future-version freeze marker that preserves the exact source payload and migration ID. Old v3 code must fail closed rather than append to a structure it cannot understand.
3. Copy old messages to canonical message records, segment indexes and DLQ indexes idempotently by migration ID and message ID. Preserve timestamps, attempts, replay counts, last error and payload; do not carry stale claim tokens as valid.
4. Verify every message record and index entry. Keep all imported messages non-claimable while migration is incomplete.
5. Activate the new manifest only after all copied data reconciles. Keep the frozen v3 source read-only as a recovery copy.
6. Resume interrupted migration on a compatible server. Do not reset a partially imported mailbox to empty or discard unknown entries.
7. Rollback may use only a binary that understands the current envelope and mailbox version. Reverse migration to v3 is allowed only after the queue is quiesced, all data is verified to fit the old envelope limits, and no unsupported state exists. Never silently downgrade, empty-fallback or remove the source copy as part of normal migration.

The freeze marker blocks old writers only when their transform validates the version and refuses to write an unsupported future version. Add a compatibility test against the actual v3 parser and transform; a prose assumption is insufficient.

### 11.2 Profile-envelope rollout for inbox/outbox

Inbox/outbox requires a versioned primary envelope. Do not enable it while old server binaries can still write the old envelope. The rollout must have a compatibility release, old-server drain/fence, activation gate, read/write compatibility matrix, and tested rollback procedure. An earlier version must never silently strip unrecognized sidecars.

Before migration/feature activation:
- backup/version-history strategy is documented;
- migration is idempotent at every step;
- partial import is non-executable;
- old-writer races are injected in tests;
- rollout and rollback are tested with mixed version attempts;
- an operator can inspect state without triggering automatic repair.

## 12. Failure-injection and contract test matrix

Build a deterministic fake DataStore that drives the actual RecordStore production path, not only `RecordStore.Mock`. It must support per-key atomic UpdateAsync, controlled concurrency/time, configurable request budgets, failures before commit, commit-then-error outcomes, and failpoints after each durable step. The fake must not mutate state or perform side effects inside UpdateAsync transforms.

Required test groups:

1. **Canonicalization/idempotency**: nested objects with different insertion order compare equal; arrays/holes/mixed keys are validated; same key/same request returns original ID; same key/different request conflicts; hash/owner collisions fail closed.
2. **Submission windows**: crash after reservation, message preparation, index append, receipt acceptance, and ready promotion; retry and recovery never lose an accepted message or execute a preparing item.
3. **Ambiguous writes**: UpdateAsync failure before commit versus commit then error; retries hit the same message/segment; no route reassignment while index existence is unknown.
4. **Rollover races**: many producers fill the final segment concurrently; stale writers to sealed segments are rejected; only one correct manifest tail wins; segment IDs never alias.
5. **Duplicate index rows**: the same ID appears twice or in a stale old segment; canonical placement generation allows at most one delivery and stale rows are ignored.
6. **Claim concurrency**: many workers claim one message; one live token wins; lease renewal, expiry, server shutdown and session generation changes fence old workers.
7. **Acknowledgement**: crash before `acknowledging`, after it, after receipt update, and after terminal update; acknowledged messages never rerun, while pre-ack uncertainty is safely at-least-once.
8. **Retry/DLQ**: thrown/rejected/yielding handler, bounded exponential delay, attempt and age caps, DLQ index append crash, duplicate DLQ append and independent active capacity.
9. **Replay/purge**: repeated replay ID, stale replay token, schema migration failure, future schema quarantine, retention boundaries, active index references, and purge interruption.
10. **Inbox atomicity**: crash after profile mutation and before mailbox ack; redelivery is duplicate and does not increment balance twice; payload/recipient mismatch conflicts; receipt capacity aborts both mutation and receipt.
11. **Outbox atomicity**: profile mutation cannot commit without outbox intent; crash after outbox append before response; crash after destination enqueue before outbox cleanup; repeat uses the same event ID; normal session save races with outbox-only update without dropping either change.
12. **Reducer semantics**: transforms may run more than once; deterministic pure reducer yields same result; exceptions/yields abort; external side-effect test fixture fails the contract test rather than simulating exactly-once.
13. **Saga**: crash after each reserve/credit/finalize and before checkpoint; each step is idempotent; source funds are not duplicated; retry leads to completion or defined compensation; stuck state remains observable.
14. **Acceleration failures**: MessagingService errors, dropped/reordered/duplicated hints, MemoryStore expiry/eviction/throttling/quotas, and disabled acceleration; durable polling recovers everything.
15. **Migration**: empty/non-empty v3, active and dead-letter records, malformed/future version, wrong owner, crash between each import, old writer races, freeze marker read by actual v3 code, feature gate and reverse migration.
16. **Scale**: 0/100/1,000/10,000 DLQ items; segment counts at low and configured max; high retry backlog; scan fairness and bounded requests; inbox/outbox capacity and retention.
17. **Transform purity**: explicit assertions prove no yielding, MessagingService/MemoryStore use, observers, GUID generation, hidden mutable state, or cross-key API calls occur in transforms.

The regression test must fail against the old implementation for the reason it claims to cover. A passing unit fake does not replace a Studio server playtest for real DataStore and service throttling behavior.

## 13. CodSpeed and service-budget validation

The existing main CodSpeed run has no dedicated durable-mailbox, outbox, inbox or saga benchmark. Existing hosted WallTime results have environment-noise warnings and some simulation cases are syscall dominated; do not reuse those numbers as queue latency evidence.

Add repeatable benchmarks for:

- ID-index append in empty/partial/full segments;
- claim, renewal, retry, acknowledgement and DLQ transitions at different active and DLQ sizes;
- idempotent new submit versus repeated submission;
- payload sizes and canonicalization cost;
- outbox commit, dispatch, and recovery after destination acceptance;
- inbox first-application versus duplicate delivery;
- saga replay/compensation and migration;
- 1, 32, 256, 1,000 and configured-maximum pending messages;
- high dead-letter history independent of active segment update size;
- 10/30/50 concurrent producers with ample and constrained fake budgets;
- polling alone versus acceleration on, measuring calls, request units, hit/miss ratios and recovery latency.

All performance measurements go through CodSpeed. Use Simulation for deterministic CPU work, not Roblox service latency. Use comparable WallTime environments for elapsed-time evidence. The fake DataStore demonstrates the tested model, not live Roblox quota behavior. Defaults change only after comparable results show a meaningful improvement without correctness, memory or constrained-budget regressions. Real Studio/server tests remain required for live service throttling and cross-server behavior.

## 14. Implementation sequence and release gates

### Phase 0 — lock the protocol

- Review this corrected design before production changes.
- Implement canonical serializer/key codec tests and state-machine transition tests.
- Define API types/outcome semantics and compatibility tests.
- Establish the production-path fake DataStore harness and queue-specific CodSpeed baseline.

### Phase 1 — mailbox core

- Build the canonical message record, bounded append-only segment index, receipt protocol and recovery.
- Keep the existing v3 queue reader and add the freeze/migration path.
- Implement retries, lease fencing, acknowledgement recovery, independent DLQ, replay and status queries.
- No MemoryStore dependency and no inbox/outbox format change yet.

### Phase 2 — profile transactional primitives

- Version and migrate the primary profile envelope for inbox/outbox sidecars.
- Implement `ApplyInboxAsync` and `CommitWithOutboxAsync` with capacity/backpressure.
- Prove that normal session saves preserve concurrent sidecar changes.
- Keep feature activation gated until old writers are drained.

### Phase 3 — workflows

- Add the generic saga coordinator with persisted steps, idempotent inbox legs, recovery and compensation.
- Publish a transfer example only after crash matrix coverage passes.
- Do not expose a misleading atomic cross-profile transfer helper.

### Phase 4 — optional acceleration and operations

- Add the MemoryStore/MessagingService hint adapter behind an off-by-default setting.
- Add approximate health/status endpoints, paginated DLQ tools, repair dry-run and diagnostics.
- Benchmark against polling-only behavior and keep acceleration disabled without measurable benefit.

### Phase 5 — staged rollout

- Run all Lune regressions, fake DataStore integration/fault-injection suites, Rojo builds, Studio tests and CodSpeed.
- Perform a controlled migration in a disposable DataStore namespace before real data.
- Verify mixed-version rejection and rollback.
- Enable new layout and envelope features separately, each with a kill switch that stops new writes without discarding accepted messages.

## 15. Acceptance criteria

The design is implementable only when tests and runtime evidence demonstrate all of the following:

- Repeating the same producer key and exact request returns one logical message ID.
- Reusing a producer key for a different request fails closed.
- An accepted message survives every crash window and is eventually discoverable without relying on notifications.
- One canonical message record prevents a duplicated/stale index row from creating two concurrent deliveries.
- Claim tokens and session generations fence stale handlers; expired claims are recoverable.
- Durable acknowledgement recovery never reruns a message already in the acknowledging state.
- Dead-letter growth does not enlarge active segment writes or consume active message capacity.
- Inbox mutations and their receipts are atomically committed to the same profile key.
- Outbox intent and source data mutations are atomically committed to the same profile key.
- Outbox dispatch is idempotent; a destination-accepted event is not duplicated when source cleanup crashes.
- Multi-profile workflows converge through idempotent steps or a documented compensation/manual resolution.
- Stats identify their completeness and are never treated as source of truth.
- Migration preserves the v3 source, old writers fail closed, and rollback never silently drops unsupported sidecars.
- Performance claims come from dedicated queue/outbox/inbox/saga benchmarks and are separated from live Roblox behavior that remains unverified.

## 16. Roblox and comparison references

- Roblox DataStore limits: https://create.roblox.com/docs/cloud-services/data-stores/error-codes-and-limits
- Roblox data stores / UpdateAsync: https://create.roblox.com/docs/cloud-services/data-stores
- Roblox versioning, listing and caching: https://create.roblox.com/docs/cloud-services/data-stores/versioning-listing-and-caching
- MessagingService delivery/limits: https://create.roblox.com/docs/reference/engine/classes/MessagingService/SubscribeAsync
- MemoryStore limits and TTL: https://create.roblox.com/docs/cloud-services/memory-stores
- ProfileStore README: https://github.com/MadStudioRoblox/ProfileStore/blob/main/README.md
- ProfileStore API: https://github.com/MadStudioRoblox/ProfileStore/blob/main/docs/api.md
