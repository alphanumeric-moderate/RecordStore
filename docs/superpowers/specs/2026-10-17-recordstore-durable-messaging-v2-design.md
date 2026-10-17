# RecordStore durable messaging v2: correctness-first architecture

- Date: 2026-10-17
- Status: Revised design; supersedes the earlier design wherever they conflict
- Scope: durable mailbox, message processing, transactional outbox/inbox, recoverable workflows, server-local dynamic configuration and measured acceleration
- Related PRs: #31 (configuration/observer design), #32 (initial durable-messaging design)

## Executive decision

Build a durable messaging subsystem that is more than a replacement for `ProfileStore:MessageAsync()`. The design combines:

1. **Correctness-first mailbox**: at-least-once delivery, producer idempotency, per-message authoritative state, append-only bounded segment indexes, persisted retry/backoff, claim fencing, acknowledgement recovery, and an independent dead-letter index.
2. **Transactional outbox/inbox**: atomically commit profile-data changes with outbound intent, and atomically apply inbound message effects to one profile key with a deduplication receipt.
3. **Recoverable sagas**: compose idempotent per-profile steps for transfers and other multi-record workflows without pretending that multiple DataStore keys form a transaction.
4. **Operator-grade delivery tooling**: delivery receipts/status, transition history, schema-aware replay, paginated dead-letter inspection, health diagnostics, and bounded repair.
5. **Optional acceleration**: MemoryStore and sharded MessagingService wake-ups, local candidate caching, explicit inbox batches, grouped outbox cleanup, fair lanes and typed circuit breakers may reduce waste and latency; they never own correctness.
6. **Server-local adaptive governor**: one controller coordinates every Record in a server and adjusts only bounded scheduling/concurrency knobs from request budgets, observed latency and throttling. Versioned runtime policy snapshots and server profiles cannot weaken persistence invariants.

The previous proposal placed full message objects, active state, and dead letters in segmented envelopes. This revision separates the **canonical message record** from the **append-only segment index**. Claims, retries, acknowledgements, and terminal transitions update one message key rather than rewriting the segment. This reduces write amplification and makes cross-key recovery state explicit.

No feature described here is implemented by this document. It is a design contract. New layout and envelope fields stay disabled until compatibility, failure-injection, migration, rollback, and live Studio/server acceptance criteria pass.

## 1. Guarantees and non-goals

### 1.1 Delivery guarantee

The mailbox provides **at-least-once delivery**. A handler may execute more than once if the process stops after a side effect but before a durable acknowledgement, if a claim expires, or if a service returns an ambiguous result. An acknowledged message must not be offered for execution again by mailbox recovery.

Do not call arbitrary handlers exactly-once. RecordStore can provide a stronger, narrowly-scoped guarantee for a mutation and its deduplication marker committed together to one RecordStore profile key. That is **effectively-once profile mutation within the retained inbox-receipt window**, not exactly-once behavior for web services, other DataStore keys, MessagingService, or arbitrary user code.

### 1.2 Atomicity boundary

Roblox DataStore `UpdateAsync` is atomic for the key being updated; it does not create a transaction across multiple keys. Any protocol that touches a manifest, segment index, canonical message record, profile envelope, dead-letter index, or saga record must persist intermediate states and recover them idempotently. Submission idempotency is stored in the canonical message record; inbox/commit receipts are stored with the profile envelope rather than in independent receipt keys.

Inside every `UpdateAsync` transform:

- do not yield;
- do not call MessagingService, MemoryStore, HTTP or another DataStore;
- do not dispatch observers, acquire a process mutex, wait on a task, or change scheduler state;
- do not generate GUIDs or read wall-clock/time-dependent values that would change on retry;
- do not perform irreversible application side effects.

Prepare stable IDs and timestamps before calling `UpdateAsync`. Transform callbacks supplied by consumers must be pure, deterministic for the same input, and non-yielding because Roblox can invoke a transform more than once.

### 1.3 Durable results and uncertain outcomes

New APIs return a typed result in addition to preserving existing result-code methods for compatibility. An enqueue result includes the assigned `message_id` as soon as it is generated, even when the durable outcome is `unknown`, so the caller can query the canonical record. If the caller never received that ID because the submitting server died, only a caller-stable idempotency key can safely resolve the logical submission. At minimum, distinguish:

- `accepted`: durable intent and canonical message state were verified;
- `duplicate`: the producer key matched an existing submission with the same exact canonical request;
- `conflict`: the same producer key was reused for a different request, owner, or incompatible protocol state;
- `capacity`: no durable space is available and no message was accepted;
- `retryable`: the attempt is known not to have committed, so retry with the same operation key is safe;
- `unknown`: the attempt may or may not have committed and could not be reconciled. Query by the returned `message_id` or retry with the same idempotency key. Without either, do not blindly retry an irreversible operation;
- `acknowledged`, `dead_lettered`, `discarded` and `expired`: persisted terminal outcomes; `processed` is an API alias for acknowledged, and `retry_scheduled` is a transition result rather than a stored state. Canonical state names are defined in the mailbox state machine.

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
| Server-local adaptive configuration and policy introspection | No equivalent documented public runtime governor API found | Shared budget-aware scheduler, versioned validated policy snapshots, server roles/profiles, last-known-good fallback and explainable effective settings |

Primary comparison references:
- ProfileStore README: https://github.com/MadStudioRoblox/ProfileStore/blob/main/README.md
- ProfileStore API: https://github.com/MadStudioRoblox/ProfileStore/blob/main/docs/api.md

The differentiators should be released as individually useful APIs. The mailbox remains useful without sagas; outbox/inbox remains useful without MemoryStore; the optional accelerator can be removed without changing durable semantics.

## 3. Public API proposal

Names are provisional. Preserve existing two-argument `Record:EnqueueAsync(type, data)`, `Record:MessageAsync(type, data)`, `ProcessQueueAsync()`, `GetQueueAsync()`, `GetDeadLettersAsync()`, and `Stats()` behavior unless a separately reviewed compatibility change is approved.

### 3.1 Enqueue without requiring the target profile to be open

Add a store-level operation analogous to:

```lua
local result = RecordStore.enqueue_to_async(
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

Existing `Record:EnqueueAsync(type, data)` remains a convenience method; it delegates to the same submission protocol. A third options argument is additive. For valuable/irreversible work, require a caller-stable idempotency key. Validate it as a non-empty string with at most 256 UTF-8 bytes before any DataStore request; reject unsupported/control characters according to the versioned key codec. Producer keys must never be reused for another logical operation, even after retention expires; a late retry after expiry is outside the deduplication guarantee, and irreversible applications must keep a permanent domain ledger. Canonicalization must be a deterministic, versioned serializer: dense arrays preserve order; string-keyed object keys are sorted; sparse arrays, mixed array/object shapes, cycles, unsupported values, and non-finite message numbers are rejected unless an explicit versioned codec supports them. Do not assume raw HttpService JSONEncode output is a canonical fingerprint unless stable key ordering is guaranteed. Retain exact canonical request material throughout the advertised deduplication window; a short hash alone does not prove equality. Calls without one get a unique submission, and an ambiguous outcome cannot be safely deduplicated by repeating the whole call.

### 3.2 Query delivery outcome

Add module-level `RecordStore.get_delivery_async(store_name, scope, profile_key, message_id)` and/or the `Record:GetDeliveryAsync(message_id)` convenience method. Module-level functions use RecordStore's existing snake_case naming convention; Record instance methods retain PascalCase. Return a single canonical message snapshot:

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

In one UpdateAsync on the same profile key, apply the reducer result and persist the deduplication receipt. Before applying or returning a receipt outcome, the transform verifies the stored owner, active session token and fencing generation match the Record that invoked the operation; if they do not, return `fenced` without applying the reducer. The reducer runs inside an UpdateAsync transform and may be invoked multiple times. It must not yield or perform external side effects. The per-Record write gate serializes it with local mutations, flushes pending dirty state first, and rebases the in-memory snapshot after commit. For irreversible game actions, keep the domain idempotency key in the application's own durable state for as long as the business rule requires. The inbox receipt window is not a substitute for a permanent purchase-receipt ledger.

Serialize this operation through the Record's write gate: stop concurrent local mutators, flush pending local dirty data, then apply the reducer to the current durable envelope. If flushing fails or its outcome is unknown, do not proceed from a stale cache. After commit, rebase the in-memory Record to the committed data/revision before releasing the gate. This API must never discard unsaved local mutations or overwrite a newer snapshot.

### 3.3.1 Bounded inbox batching

Add opt-in `Record:ApplyInboxBatchAsync(messages, reducer)` for several messages targeting the same profile key:

```lua
local result = record:ApplyInboxBatchAsync(messages, function(current_data, unseen_messages)
    -- Pure, deterministic reducer over messages in input/delivery order.
    return apply_messages(current_data, unseen_messages)
end)
```

One UpdateAsync applies the combined profile mutation and records inbox receipts for all new message IDs. The input must contain unique message IDs; duplicate IDs within one call are rejected as validation errors before any write. Matching receipts from earlier calls are returned as duplicates and excluded from the reducer input. If any ID conflicts with a retained receipt, the full batch aborts without applying any new messages. An invalid reducer result, callback error/yield, owner/session fencing failure or capacity overflow also aborts the entire batch. The result gives an outcome for every input ID.

The batch has strict item and encoded-byte ceilings. Only messages for the same profile and compatible schema/reducer may share a transaction. Preserve delivery order explicitly; do not reorder messages with the same ordering key. The scheduler may batch only messages whose claims were successfully acquired for the same owner; it must not wait for a missing claim while holding already-claimed messages indefinitely. If any claim expires before the inbox transaction begins, abort/release or allow those claims to expire and retry the batch. Queue acknowledgements begin only after the profile mutation and all receipts are verified durable. A crash after profile commit but before queue acknowledgements is safe: redelivery finds the per-message inbox receipts and does not reapply the data mutations.

This API is opt-in because one batch is one atomic unit: all new items in that batch commit or none do. Automatic batch-size changes must not silently change a caller's intended transaction boundaries. Runtime acceleration may coalesce candidate discovery and scheduling, but it can merge messages into one atomic batch only where the caller explicitly opted into batch semantics.

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

The API accepts an explicit command type, canonical command payload, and explicit bounded outbound event list; it does not try to fingerprint a Lua callback or infer event intent from arbitrary side effects. One UpdateAsync on the source profile key commits the data mutation, exact-request commit receipt, and bounded outbox entries together. Stable event IDs derive deterministically from `(source store_name, source scope, source profile_key, commit_key, event ordinal)` before the transform, so the same commit key on different source profiles cannot collapse into one destination event. The same commit key with a different command type, payload, or event list returns conflict.

Serialize the operation through the Record write gate: flush pending local dirty data, block local mutators while the durable transform runs, and rebase the live cache/revision after commit. If the dirty flush has an unknown outcome, stop and reconcile instead of applying the command to stale data.

### 3.4.1 Bounded outbox dispatch

Add `Record:DispatchOutboxBatchAsync(max_events)` as an opt-in dispatcher. It selects a bounded set of independent pending entries, applies the shared governor's concurrency limit, and records a per-event result. It enqueues each event using its stable event ID as the destination idempotency key. Once several destination receipts are verified accepted, it marks only those event IDs delivered in one compare-and-set source-envelope update. An unverified or failed event remains pending; after a crash, accepted destinations are safely recognized by their original IDs.

This batches source cleanup and overlaps independent destination work, but does not claim atomic delivery across destinations. Preserve per-target ordering when requested and cap concurrency to avoid turning a fan-out into a burst of DataStore throttling.

### 3.5 Opt-in yielding queue handlers

Preserve the existing `on_queue_message` contract: it is synchronous and must not yield. Add a separate opt-in `on_queue_message_async` callback for operations that need to await Roblox APIs. Do not silently change the old callback's execution model.

The async callback runs only after the current canonical message claim and owning Record session fence are verified. A shared worker renews the persisted claim lease while the handler is active, using a higher scheduler priority than routine queue scans and maintenance. It must verify the same claim token and session generation on every renewal; an expired or replaced claim cannot renew itself.

Pass a context containing the stable `message_id`, attempt number, current deadline and a cooperative `is_cancelled()`/cancellation reason. If renewal cannot be verified, the session is fenced, the lease expires, or shutdown begins, mark the context cancelled and stop scheduling further handler work. The handler must check cancellation before starting another external effect. RecordStore cannot forcibly reverse an already-committed HTTP/service side effect and cannot prove a yielding callback is safe simply because its coroutine was cancelled.

Treat timeout, lease loss, or an uncertain external response as an unknown side-effect outcome, not evidence of failure. The message remains at-least-once and may be redelivered. Require application idempotency for irreversible effects; only enter the durable `acknowledging` state after the handler reports success and the current token is still valid. Renewal intervals and maximum handler deadlines are validated within hard bounds. Runtime adaptation must not extend the claim lease of an already-claimed message or suppress lease-renewal work.

### 3.6 Recoverable workflow/saga API

Add an optional companion module, for example `RecordStoreWorkflow`, after inbox/outbox correctness is established. Its durable API should provide:

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

Use the configured queue DataStore name and scope with a versioned mailbox namespace. The full record owner is `(store_name, scope, profile_key)`. Every route, segment, message, dead-letter and manifest value must store and validate the full owner; a hashed key is only a routing aid. Producer idempotency uses the canonical message record itself rather than a separate receipt key. The segment index stores the canonical record key; this lets migrated legacy messages keep their original public ID while using a v2-safe route.

The layout consists of:

1. **Constant-bounded manifest** per owner and partition: protocol version, full owner identity, immutable partition count, activation/migration state, a fixed-size segment-slot table, per-slot generation/state/current segment key, and a scan hint. The table is capped at the configured maximum (initially 64); it never grows with message count.
2. **Append-only segment index**: bounded entries containing the canonical message record key plus placement generation, not payload, retry state, or dead-letter history. For new v2 messages the record key is the public message ID; for migrated v3 messages the index key is a stable `m2l-` route while the canonical value preserves the old public ID. Appending is idempotent; message processing never rewrites this index entry. Segment keys include both slot and generation so a reused slot cannot alias an older segment.
3. **Canonical message record and producer receipt**: one DataStore key per logical message. With an idempotency key, the canonical route and public message ID are the deterministic `m2i-` key derived from the full owner tuple plus producer key; the record stores the full owner, original key, exact canonical request, payload, schema version, lifecycle state, retry schedule, attempts, claim token/expiry, current segment locator/generation, correlation IDs, terminal reason and bounded transition history. This record is both the message and the producer's durable receipt; there is no separate producer-receipt key to keep synchronized. Without a producer key, use a generated `m2g-` message ID; an ambiguous whole-call retry can create a second logical message.
4. **Independent dead-letter index**: separately segmented IDs for messages in dead-letter state. The canonical message record retains the payload/error needed for inspection and replay. A growing DLQ cannot consume active-segment capacity.
5. **Profile-local inbox and outbox fields**: bounded sidecars in the profile envelope, so the data mutation and its corresponding inbox receipt/outbox intent can be committed in a single UpdateAsync. These fields require a versioned profile-envelope migration and explicit rollout gating.

A per-message canonical record costs more keys and service calls than one large queue envelope, but eliminates rewrites of unrelated message payloads on claim/ack and isolates hot-key traffic. CodSpeed and constrained-budget workload evidence must determine usable defaults rather than assuming this is always cheaper.

### 4.2 Roblox key names and collision rules

Roblox DataStore key names are limited to 50 characters. Define and test a stable key codec for every route, message, segment, idempotency, and DLQ key. Include store/scope/owner identity in the stored value, not only in the key name.

- Use a versioned deterministic route codec with fixed-length keys no longer than 50 characters. Example families are `m2i-<32-hex-digest>` for idempotent message keys/public IDs, `m2g-<32-hex-guid>` for new non-idempotent message keys/public IDs, and `m2l-<32-hex-digest>` for migrated-message storage routes. To make `m2g-` keys 36 characters, normalize a generated GUID to 32 lowercase hex characters by removing its hyphens before adding the prefix. `m2l-` is a storage route, not the preserved legacy public ID. Also use separate fixed-length prefixes such as `mf2-<32-hex-digest>` for manifests, `si2-<32-hex-digest>` for segment indexes, `di2-<32-hex-digest>` for DLQ indexes and `wf2-<32-hex-digest>` for workflow records. Each digest covers a versioned, length-prefixed tuple containing the full owner plus that record's partition/slot/generation or workflow identity. The idempotency digest covers store, scope, profile key and producer key. Document the exact pure-Luau digest algorithm and fixed test vectors; do not assume Roblox provides a built-in cryptographic hash. Every encoded key in every record family must have a test asserting its actual length is at most 50 characters. For status reads, `get_delivery_async(store_name, scope, profile_key, message_id)` uses direct lookup for reserved v2 IDs (`m2i-`/`m2g-`) and derives the `m2l-` route from `(store_name, scope, profile_key, message_id)` for migrated legacy IDs. During migration, if a legacy public ID collides with a reserved v2 ID format or a distinct canonical record, fail closed and flag manual reconciliation rather than guessing which logical message was intended.
- On every read/update, compare the complete stored owner, producer key (when present), public message ID, record-family identity and exact canonical request to the requested values. Segment and manifest records additionally validate the complete partition/slot/generation tuple. Hash matches only route to a candidate; they never prove identity.
- An idempotent message's record key is derived from a versioned digest of the full length-prefixed owner tuple plus producer key, so the same logical submission maps directly to its canonical message record without a second receipt lookup. A submission without an idempotency key uses a generated ID and cannot deduplicate an ambiguous retry.
- If two inputs map to the same routing key but differ in full identity or request, fail closed with an explicit route-collision/conflict result. Never read, mutate, or overwrite the other owner's record.
- Digests are routing aids, not proof of equality or authentication. A collision must be detected against the stored full identity and exact canonical request; it must never silently alias idempotency keys. Keep an implementation with fixed test vectors and fit every encoded key within 50 characters.
- Test maximum-size store, scope and profile keys as well as generated IDs. Verify encoded serialized bytes, not character estimates.

### 4.3 Boundaries and initial defaults

Initial values are benchmark candidates, not production claims:

- one partition by default; partition count is immutable after activation;
- at most 32 canonical message record keys per active segment;
- at most 250,000 encoded bytes per segment index, even though it contains only IDs;
- at most 64 live segment slots per partition initially; slots can be reclaimed out of order after all entries are terminal or stale, so a delayed old item does not pin all later completed slots;
- each reused slot gets a strictly increasing generation encoded into its segment key; generations never wrap or reuse an old key;
- at most 64 KiB encoded payload per message by default, configurable only within validated service/key limits;
- retain the current 60-second claim lease and 10-second polling defaults until queue-specific measurements justify changes;
- deduplication and dead-letter retention must be explicit. Never expire a dedup receipt before the advertised idempotency window.

The number of record keys per segment is not the same as maximum pending backlog. Segments may be reclaimed only after every referenced message is terminal or safely re-routed and the segment is sealed. Deleting a segment key is not the acknowledgement of any message in it.

### 4.4 Segment rollover and append protocol

The segment index is a discovery aid; the canonical message record is both the message and the producer idempotency receipt. The manifest uses a fixed-size slot table rather than a monotonically contiguous head/tail range. This allows out-of-order slot reclamation when an old delayed item remains pending.

1. Select a currently published `open` segment generation from the manifest; a message record must never reference a slot still in `allocating`. If a producer key is supplied, derive the canonical message key/public ID from the full owner tuple plus producer key digest; otherwise generate a GUID and use its `m2g-` key. Store the full owner, producer key, exact canonical request, payload and `preparing` state in that canonical message record with its selected locator. Retrying the same key and exact request finds the same key/ID; a mismatched request/owner fails closed.
2. The `preparing` record includes the chosen (slot, segment generation, placement generation) locator for a segment that was already published `open`. Do not allocate a different segment because a read timed out or an append response is ambiguous.
3. Append (canonical message record key, placement generation) to the selected segment with UpdateAsync. Append requires that the target segment key already exists for the generation published in the manifest. A missing/retired key is rejected rather than implicitly initialized. Repeating the same append returns the existing entry.
4. If append returns an ambiguous error, repeat the idempotent append/verification on the same key until the ID is known present or the operation deadline returns `unknown`. Never infer absence from a cached GetAsync or timeout.
5. If the segment is full, seal it with a compare-and-set UpdateAsync. Once sealed, no append is accepted. To allocate a slot, first CAS the manifest slot from `empty` to `allocating` with a strictly new generation; only the winner owns that generation. It then creates and verifies the empty segment key and CASes that same slot/generation from `allocating` to `open`. Recovery can resume an interrupted allocation or retire the unused generation only after proving no preparing message references it. Multiple allocators may race, but only the manifest-published generation is valid.
6. Retarget a preparing message only after the previous segment is confirmed sealed and the index pair is confirmed absent. Increment the placement generation. Stale writers to an old generation see a sealed or missing key and cannot append. Workers require the index generation to match the canonical message locator.
7. After verifying the matching index entry, promote the canonical message from `preparing` to `ready` with a CAS that checks the expected locator and placement generation. The index entry references the canonical storage key, while status APIs return the stored public message ID. Only `ready` messages can be claimed. Return `accepted` only after this state is verified; an ambiguous response remains `unknown` until the canonical record is reconciled.
8. If the server stops before the canonical record and index are both verified, the caller must retry with the same idempotency key to resume. If the index exists but the message remains `preparing`, reconciliation promotes it to ready only after validating owner, exact request, index entry and placement generation. If the canonical record exists but no index entry was committed, the submission was not reported as accepted; the idempotent retry resumes the same record. If its original slot has since been retired, retarget only after proving the old pair is absent and the old generation can no longer accept writes.
9. An index row is deliverable only when owner, slot, segment generation, canonical record key, canonical record locator and placement generation match. For new v2 messages the public message ID equals the canonical key; for migrated legacy messages the stored public ID may differ from the `m2l-` route. Duplicate or stale rows are skipped. Claim is a CAS on the canonical message record.

Slot lifecycle:

- Slots transition through `empty -> allocating -> open -> sealed -> draining -> empty`. Manifest transitions are compare-and-set operations.
- A slot can be reclaimed only after it is sealed and a bounded scan proves every indexed entry terminal or stale. Do not block reclamation on a `preparing` message record that has no index entry: it was never accepted, and a caller retry must detect that its recorded generation is retired, verify the old index pair is absent, and retarget it to a newly published open generation. Keep the old generation permanently non-writable through the manifest generation/tombstone rule. Keep canonical terminal tombstones until their idempotency and diagnostic-retention rules permit deletion.
- A slot generation is part of the segment key and strictly increases. A segment key is never reinitialized for another generation. Only the allocator may initialize a new segment, and append to a missing generation is rejected; this prevents an old delayed writer from recreating a purged index.
- Reclaim slots out of order to avoid head-of-line capacity loss. Polling scans the fixed slot table fairly; it does not assume a contiguous range.
- Accepted messages are not relocated simply because another slot becomes available. Relocation is allowed only while preparing and after the previous segment is sealed and the index pair verified absent.
- The manifest is rewritten only on slot allocation/reclamation, not each enqueue or lifecycle transition. Segment ID arrays are rewritten only on append/seal, never on claim, retry or acknowledgement.

### 4.5 Lifecycle state machine

Canonical message states:

- `preparing`: submission is not yet claimable; index/message reconciliation is permitted.
- `ready`: accepted and eligible after `available_at`.
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
1. Persist `acknowledging` on the canonical message under the current token.
2. Persist the canonical message as `acknowledged` with the same operation/claim identity.
3. Recovery repeats step 2 idempotently and never invokes the handler for an `acknowledging` message. Because the canonical message record also serves as the producer receipt, there is no cross-key producer-receipt update.

If the handler effect committed but the state never reached `acknowledging`, redelivery is possible. This is why the atomic inbox pattern is a first-class API.

**Dead-lettering:**
1. Persist `dead_lettering` on the canonical message under the current token.
2. Append the canonical message record key and terminal generation to the independent DLQ index idempotently.
3. Persist `dead_lettered` on the canonical message.
4. Recovery repeats the same transitions idempotently. `dead_lettering` is never eligible for user handler execution, and the canonical record remains queryable as the producer's outcome receipt.

No DataStore callback may perform any of these transitions by directly calling another key's API inside the transform.

## 5. Transactional inbox: safer message effects

### 5.1 Atomic mutation plus receipt

`ApplyInboxAsync(message_id, message_type, payload, reducer)` updates the recipient's primary profile envelope in one UpdateAsync. Its transform checks the retained inbox receipt, applies the pure reducer to the current durable data, and records the message ID plus exact canonical request identity in the same envelope. A matching receipt returns the stored prior outcome without running the reducer again. A mismatched message type/payload/owner returns conflict.

Before entering this transform, serialize the operation through the Record's write gate: block local mutators, flush pending dirty data, then apply the reducer to the current envelope. If flushing fails or its outcome is unknown, do not proceed from a stale cache. On successful commit, rebase the in-memory Record to the committed data/revision before releasing the gate. On an ambiguous commit, reconcile by the stable message ID and receipt before allowing a second mutation.

The reducer may run multiple times and must be pure, deterministic and non-yielding. If it throws, yields, or returns an invalid value, abort both the data mutation and receipt insertion. The library can detect callback errors and yields, but cannot prove arbitrary callback code has no external side effects; purity is an API contract, not a sandbox guarantee. This provides at-most-once application of the reducer to the one profile key while the receipt remains retained. Delivery may repeat, but the same persisted profile mutation does not. It does not protect side effects outside the same UpdateAsync or make another profile key part of the transaction.

### 5.2 Receipt retention and capacity

Inbox receipts must be versioned and bounded by both entry count and encoded bytes. Define an advertised deduplication window that is at least as long as the maximum queue retry/replay window. Refuse new inbox commits with a capacity result when pruning would violate the advertised window; do not evict a live receipt to make space.

For purchase receipts that must remain deduplicated indefinitely, applications keep the purchase identifier in durable domain state or a permanent ledger. Do not claim lifetime deduplication after a finite inbox receipt has expired. Receipt pruning is allowed only after expiry and must preserve the documented replay policy.

## 6. Transactional outbox: remove the dual-write gap

### 6.1 Atomic commit

`CommitWithOutboxAsync(commit_key, command_type, command_payload, outbox_events, reducer)` performs one UpdateAsync against the source profile key. The reducer returns the next profile-data value. The same transform writes:

- next profile data;
- an exact-request commit receipt keyed by `commit_key`, including the canonical command and event list identity;
- stable outbox event IDs derived deterministically from full source profile identity, `commit_key` and event ordinal;
- each event's schema version, target identity and correlation/causation fields.

Canonicalize the command and bounded event list before entering the transform. The reducer must be deterministic, pure and non-yielding; Roblox may invoke it more than once. The transform verifies owner identity, active session token and fencing generation before writing. An already-committed key with the same exact request returns its prior outcome without applying the data mutation again. The same key with a different command, payload or event list conflicts. Commit keys and derived event idempotency keys are operation identities and must never be reused for a different logical purchase/transfer. After the configured receipt-retention window expires, deduplication is no longer promised; applications must retain permanent domain ledgers for business operations that require lifetime deduplication.

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

Every leg is replay-safe because the profile data mutation and step receipt share one key. A crash after a leg commits but before the saga checkpoint writes is harmless: replay of that leg returns its recorded outcome. An ambiguous destination result is `unknown`, not a definitive failure: reconcile or retry the same destination step ID before releasing a source reservation. Never compensate while a prior step could still commit late. If a step is definitively terminal and compensation is safe, execute the defined compensation (such as release the source reservation) with its own idempotency key. Compensation is a new business operation, not rollback of history. A workflow's maximum retry/deadline window must fit inside each participant's inbox-receipt retention window, or the domain must retain a permanent step ledger.

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



### 8.4 Server-local dynamic configuration

Dynamic configuration is a first-class subsystem, but it is a **bounded runtime overlay**, not a second source of truth for persistence. RecordStore should have one server-local governor shared by all live Record instances, because DataStore budgets, in-flight requests and server pressure are shared within the server. Per-Record controllers would compete with each other and overestimate available capacity.

#### Configuration layers and precedence

Resolve effective settings in this order:

1. **Correctness invariants** compiled into RecordStore: protocol/version checks, owner verification, session/claim fencing, idempotency rules, legal state transitions, minimum retention guarantees and key/value size ceilings. No dynamic or remote policy can weaken these.
2. **Developer hard bounds** supplied through the one-time module-level runtime configuration; per-Record options may tighten request-specific limits but must not exceed server-global hard bounds.
3. **Validated versioned policy snapshot** supplied by the experience, if configured.
4. **Server profile** selected by the developer or `auto`: `latency`, `balanced`, `budget_safe`, or `background`.
5. **Adaptive local overlay** calculated from this server's observed budgets, latency, throttling and workload.

Add a separate module-level `RuntimeOptions` configuration accepted by `RecordStore.configure_runtime(config)` before the first Record opens. Do not repeat server-global controller settings in every Record's `Options`, because that would create conflicting feedback loops. The server-global config uses snake_case fields: `runtime_profile`, `server_role`, `adaptive_runtime_enabled`, `adaptive_sample_interval`, `adaptive_min_queue_poll_interval`, `adaptive_max_queue_poll_interval`, `adaptive_min_concurrent_requests`, `adaptive_max_concurrent_requests`, `adaptive_read_budget_floor`, `adaptive_write_budget_floor`, `adaptive_queue_budget_share`, `adaptive_hysteresis_seconds`, `runtime_policy_refresh_interval`, and optional `runtime_policy_provider`. Configuration is validated atomically; incompatible repeated `configure_runtime()` calls fail explicitly. Require finite positive sampling/poll/refresh/hysteresis durations; `adaptive_min_queue_poll_interval` must not exceed its maximum; concurrency bounds are positive integers with min not greater than max; budget floors are nonnegative integers; `adaptive_queue_budget_share` is between 0 and 1; and every profile-specific value is clamped to developer hard bounds. A missing or unavailable policy at cold start falls back to the built-in safe profile and must not block profile open/save while waiting for remote configuration. Defaults keep adaptive control disabled or conservative until benchmarks and Studio acceptance tests pass.

`server_role` is developer-provided (`gameplay`, `hub`, `match`, `background`, `studio_test`, or `custom`). `auto` may observe Studio versus live server, current player count, active Record count, server age, current work and measured service behavior, but it must not guess application semantics from JobId or private/reserved status alone. The same server can host both latency-sensitive profile saves and low-priority maintenance; role is a hint, never a correctness decision.

Add module-level APIs consistent with existing naming:
- `RecordStore.configure_runtime(config)`: install the validated server-global hard bounds/profile/provider before opening Records. The governor and request budget are shared across every Record instance.
- `RecordStore.apply_runtime_policy(revision, policy)`: validate and install an immutable policy snapshot in this server. Repeating the same revision and canonical policy is a no-op; reusing a revision with different contents is a conflict; lower/stale revisions are rejected.
- `RecordStore.get_runtime_snapshot()`: return the effective settings, bounds, source of each setting, policy revision, controller state, sample time, and a short reason for each adaptive change.
- An optional `on_runtime_config_changed` observer runs outside all DataStore transforms and cannot block or roll back configuration. The optional `runtime_policy_provider(context)` is a bounded, non-yielding callback supplied via `configure_runtime`; it returns a revision plus the application's already-cached policy snapshot and is invoked only at the configured refresh interval, outside all DataStore transforms. Its read-only context may include `is_studio`, `place_id`, `player_count`, `active_record_count`, `server_role`, current request budgets and controller health, but must not include player payloads or secrets. Remote config I/O belongs in the application's own refresh task, which can call `apply_runtime_policy()` when it has validated a new snapshot. A provider that throws, yields, or returns invalid data is ignored and the last-known-good policy remains active.

The experience may keep remote policy storage in its own config service or DataStore key. RecordStore should not issue remote config reads on every operation. The last-known-good policy is server-local memory; after a restart, if the provider cannot supply a validated snapshot, use built-in safe defaults until refresh succeeds rather than assuming a previous server's in-memory policy survived. A local versioned snapshot is refreshed at a jittered, bounded interval; MessagingService is only an invalidation hint; missed hints are recovered by periodic refresh. Keep the last-known-good snapshot when the provider is unavailable. Validate the entire new snapshot before atomically replacing the old one. Unknown schema versions, invalid numbers, unsupported fields, unsafe limits or a stale revision reject the whole snapshot rather than applying a partial config.

#### Signals and adaptation policy

Sample no faster than the configured minimum interval. Inputs include:
- `DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.StandardRead)` and `StandardWrite`; `UpdateAsync` consumes both read and write budget;
- recent RecordStore-owned operation latency EWMAs, in-flight count, timeout/uncertain-write rate and classified throttling errors;
- eligible backlog count/oldest age and retry backlog;
- optional Heartbeat delay as a weak signal for avoiding extra nonessential work when the server is already overloaded;
- active record count and player count as context, not a substitute for actual budget readings.

DataStore budgets are observed per server, while some limits are shared across the experience. Therefore a high local budget does not prove the experience-wide budget is healthy; actual throttle responses and operation latency remain feedback signals. Do not infer exact universe-wide capacity from one server's budget.

The controller adapts only scheduling/acceleration knobs that preserve semantics: RecordStore-owned maximum in-flight requests, scan work per tick, idle poll interval within validated bounds, optional prefetch/cache TTL, outbox dispatch concurrency, background maintenance slice size, and batch throughput for APIs whose batch boundaries were explicitly supplied by the caller. It does not alter message IDs, deduplication windows, session or claim-fencing rules, lease expiry for work already claimed, retry attempt limits, payload validation, schema/version migration, terminal states, or dead-letter retention.

Use asymmetric control to avoid oscillation:
1. On a throttle, low budget reserve, or spike in uncertain writes, reduce noncritical concurrency quickly, stop low-priority scans/maintenance and move background work behind critical persistence operations.
2. Preserve reserved capacity within RecordStore's own request scheduler for profile open/save, session lease renewal/release and bounded shutdown work. Queue, DLQ inspection, compaction and metrics may not consume this internal reserved share. This is not an engine-enforced DataStore budget reservation: unrelated scripts in the same server can still consume the engine's request budget.
3. Keep durable accepted work pending instead of dropping it. A new send is accepted only after its canonical record and segment index are verified; for submissions with an idempotency key, return `retryable` or `unknown` and require retry with that same key. Without a key, an unknown result cannot be safely retried for irreversible work.
4. Increase concurrency slowly only after several stable samples, adequate budget headroom and no recent throttle/error. Apply hysteresis, cooldowns, per-step change limits and minimum dwell time.
5. During shutdown, stop new background work, prioritize final profile saves/releases, and finish only work covered by the shutdown deadline. Unfinished queue work stays durable; shutdown never pretends it was delivered.
6. Emit diagnostics for effective values, clamp decisions and throttle causes without logging user payloads.

Do not call `DataStoreService:SetRateLimitForRequestType()` automatically: it changes the server's request rate limits for that request category, which can affect other scripts using DataStoreService. Integrations that opt into managing those engine-level limits must explicitly delegate ownership of the whole server budget and are out of scope for the default governor.

### 8.5 Acceleration plan

Apply acceleration where it reduces actual Roblox service calls or wasted work. Do not optimize only synthetic CPU time, and do not weaken correctness for lower latency.

**A. Bounded inbox batching**
- Use the explicit `ApplyInboxBatchAsync` API to apply a bounded set of messages and receipts to one profile in one UpdateAsync. This amortizes profile mutation writes while preserving atomicity for that caller-defined batch.
- Start with batch sizes of 1, 4, 8 and 16 as benchmark candidates, bounded by encoded payload plus receipt bytes. These are candidates, not defaults.
- If the batch exceeds the profile envelope or configured size cap, reject that batch without partial effects. Splitting into smaller calls is an explicit caller decision because it changes atomicity boundaries.
- Acknowledge queue messages only after the durable profile receipt is confirmed; never mark the queue acknowledged based only on a cached in-memory Record value.

**B. Outbox fan-out and grouped cleanup**
- Dispatch independent outbox events with bounded concurrency under the shared governor, with fairness by target profile and priority class.
- Each event uses a stable destination idempotency key. A destination-accepted event is safe to retry if the source cleanup update crashes.
- After verifying destination acceptance for several events, remove/mark those entries in one CAS/update of the source outbox sidecar. Keep events without verified destination receipts pending. One failed event must not cause already-confirmed events to be resent with new IDs.
- Do not combine separate source data mutations into one implicit transaction. `CommitWithOutboxAsync` preserves one command's explicit atomic boundary.

**C. Wake-up coalescing and bounded topic sharding**
- Replace one-subscription-per-profile acceleration for the new mailbox with a fixed, configured number of shared wake-up topics per experience/shard. Topic routing is a hint; the payload carries only a compact owner/message/generation reference, never trusted state or game-economy data.
- Coalesce repeated wake-ups for the same owner in a server-local keyed work map. One notification triggers a bounded scan rather than one request chain per hint.
- Respect current MessagingService topic/message size and subscription/publish limits. If a shared topic is congested, dropped or unavailable, durable polling remains the recovery path.
- Avoid creating a topic/subscription for every record; subscription fanout itself can become a resource bottleneck.

**D. Bounded local candidate cache**
- Cache recently observed segment IDs/slot metadata with a short TTL and cap. Hints invalidate or refresh the cache, but never authorize delivery.
- Always revalidate current owner, generation, lifecycle state and claim token through the canonical message UpdateAsync before handling.
- A maximum cache age and mandatory reconciliation poll prevent missed invalidations from suppressing work indefinitely. Stale cache entries may waste a read but may never suppress recovery forever or make an invalid message claimable.

**E. Fair multi-lane scheduling**
- Separate critical profile persistence and lease work from durable-message processing, outbox fan-out, and maintenance/diagnostics.
- Use weighted fair scheduling and bounded per-owner slices so a noisy profile or poison message cannot starve other profiles. Preserve ordering for the same configured ordering key. Per-message priority values remain a later opt-in scheduling feature; do not imply that they are active in the initial mailbox release.
- Under pressure, drop only ephemeral hints/cache entries, not accepted durable messages. Delay low-priority work rather than consuming the reserved budget.
- Keep queue and maintenance concurrency in one shared request governor; do not create independent semaphores per feature that oversubscribe the same DataStore budget.

**F. Typed circuit breaker and retry suppression**
- Classify invalid payload/schema, permanent authorization/owner conflict, transient service failure, key/experience throttling and uncertain write separately.
- Open a bounded circuit for repeated transient failures to a service/key, with a half-open probe and cooldown. Do not repeatedly hammer a known-throttled key.
- Never circuit-break critical final profile save/release into silent success. Return an explicit retryable/unknown outcome and preserve the durable recovery path.

Every accelerator has an off switch and a polling-only fallback. Removing MemoryStore/MessagingService must not require data migration, change message IDs, or weaken delivery semantics.

## 9. Dead letters, replay and retention

### 9.1 Independent DLQ

Dead letters are canonical message records plus a separately segmented DLQ index. A dead-letter append is idempotent by canonical message record key and terminal generation; the API exposes the record's public message ID. No active segment size calculation may include historical DLQ records.

Expose module-level `RecordStore.list_dead_letters_async(store_name, scope, profile_key, cursor, page_size)` plus Record convenience methods:
- paginated `ListDeadLettersAsync(cursor, page_size)`;
- `ClaimDeadLetterAsync`, `ReplayDeadLetterAsync`, and `DiscardDeadLetterAsync` with fenced tokens;
- bounded last error, attempts, timestamps and replay history;
- retention eligibility and explicit purge outcomes.

A large DLQ is inspected page by page; no API silently materializes an unbounded history in one call. The legacy `GetDeadLettersAsync()` remains a bounded compatibility helper with a clear limit/incomplete result.

### 9.2 Replay safety

Replay is a new delivery generation of the same logical message. It atomically reserves a replay token on the canonical record, appends its canonical storage key to a new segment index entry with a larger placement generation, then transitions back to ready. The public message ID stays stable across replay. The old segment row becomes stale and is ignored. Repeated replay requests with the same replay operation ID return the same outcome; a different replay request while one is pending conflicts.

Before replay, validate the message type and payload schema against the currently registered decoder/migration. Allow a dry-run validation result that shows the intended upgraded payload without changing durable state. Unknown future schemas remain quarantined; never force-rewrite them to an older guessed shape.

### 9.3 Retention rules

Retention is separate for completed payloads, producer-idempotency tombstones, inbox receipts, outbox entries, dead letters and transition history. The producer idempotency tombstone lives in the canonical message key: payload bytes may be pruned only when the exact canonical request identity needed to resolve duplicate submissions is retained in the tombstone, or when the advertised idempotency window expires. Defaults are conservative: retain pending work; do not auto-delete dead letters; retain dedup identity at least through the advertised idempotency window.

Purge only terminal data that is past its declared retention and no longer referenced by a live index, pending workflow or source outbox. Purge transitions need audit IDs and must be idempotent. Never leave a producer-key tombstone pointing to a nonexistent message or return a false success after payload deletion.

## 10. Operational observability

Add module-level `RecordStore.get_queue_stats_async()`, `RecordStore.get_delivery_async()`, `RecordStore.get_outbox_stats_async()`, and `RecordStore.get_inbox_stats_async()`, plus Record convenience methods where a live Record is available. Keep `Stats()` backwards compatible. Expose workflow status through the optional `RecordStoreWorkflow` module.

Useful fields include active/claimed/delayed/acknowledging/dead-lettering counts, oldest eligible age, oldest pending outbox age, expired claim recoveries, retry distribution, terminal error distribution, idempotent duplicate submissions, conflict/capacity/unknown outcomes, migration phase, segment count, scan cursor progress, hint failures, DLQ retention eligibility and stuck workflow step.

**Accuracy contract:** a scan across many keys is not a linearizable snapshot. Every multi-key stats result includes `observed_at`, scanned range, completeness, and whether counters are exact, approximate, or process-local. Approximate metrics must never control claim correctness, purging, admission, or migration. Exact message status comes from its canonical message key. A background reconciler repairs projections using idempotent operation IDs, and reports discrepancies rather than silently rewriting ambiguous state.

Do not log payloads, purchase tokens, player secrets or arbitrary user data by default. Provide correlation IDs and stable error categories while bounding the stored error text.

## 11. Migration, rollout and rollback

The existing queue v3 value stores active messages and dead letters together. Earlier legacy queue values may have no verifiable owner metadata; a non-empty ownerless legacy queue remains a manual-recovery stop.

### 11.1 Mailbox migration

1. Verify full owner identity, supported source version and queue shape. Corrupt or mismatched data is preserved untouched. Preflight all legacy public IDs against the reserved `m2i-`/`m2g-` public-ID namespace; if a collision exists, stop migration before writes and require an explicit operator resolution.
2. Atomically replace the v3 queue envelope with a future-version freeze marker that preserves the exact source payload and migration ID. Old v3 code must fail closed rather than append to a structure it cannot understand.
3. Copy old messages to canonical message records, segment indexes and DLQ indexes idempotently by migration ID and legacy message ID. Preserve each public legacy message ID, timestamps, attempts, replay counts, last error and payload; use a stable `m2l-` storage route derived from the full owner plus legacy ID. Segment entries carry that storage route, while the canonical value retains the original public ID. `get_delivery_async(store_name, scope, profile_key, legacy_message_id)` derives the v2 route from the full owner and legacy ID. Do not carry stale claim tokens as valid.
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
2. **Submission windows**: crash after canonical message creation, index append, and ready promotion; retry and recovery never lose a reported-accepted message or execute a preparing item. Same-key retry finds the same canonical message record without a separate receipt-key round trip. An unindexed preparing record does not pin a segment forever; its same-key retry safely retargets after generation retirement.
3. **Ambiguous writes**: UpdateAsync failure before commit versus commit then error; retries hit the same message/segment; no route reassignment while index existence is unknown.
4. **Rollover races**: many producers fill the final segment concurrently; stale writers to sealed segments are rejected; only one correct manifest tail wins; segment IDs never alias.
5. **Duplicate index rows**: the same ID appears twice or in a stale old segment; canonical placement generation allows at most one delivery and stale rows are ignored.
6. **Claim concurrency**: many workers claim one message; one live token wins; lease renewal, expiry, server shutdown and session generation changes fence old workers.
7. **Acknowledgement**: crash before `acknowledging`, after it, and after terminal update; acknowledged messages never rerun, while pre-ack uncertainty is safely at-least-once.
8. **Retry/DLQ**: thrown/rejected/yielding handler, bounded exponential delay, attempt and age caps, DLQ index append crash, duplicate DLQ append and independent active capacity.
9. **Replay/purge**: repeated replay ID, stale replay token, schema migration failure, future schema quarantine, retention boundaries, active index references, and purge interruption.
10. **Inbox atomicity**: crash after profile mutation and before mailbox ack; redelivery is duplicate and does not increment balance twice; payload/recipient mismatch conflicts; receipt capacity aborts both mutation and receipt.
11. **Outbox atomicity**: profile mutation cannot commit without outbox intent; crash after outbox append before response; crash after destination enqueue before outbox cleanup; repeat uses the same event ID; normal session save races with outbox-only update without dropping either change.
12. **Reducer semantics**: transforms may run more than once; deterministic pure reducer yields the same result; exceptions/yields abort; document and test the callback contract without claiming the library can detect every external side effect.
13. **Saga**: crash after each reserve/credit/finalize and before checkpoint; each step is idempotent; source funds are not duplicated; retry leads to completion or defined compensation; stuck state remains observable.
14. **Acceleration failures**: MessagingService errors, dropped/reordered/duplicated hints, MemoryStore expiry/eviction/throttling/quotas, and disabled acceleration; durable polling recovers everything.
15. **Migration**: empty/non-empty v3, active and dead-letter records, malformed/future version, wrong owner, crash between each import, old writer races, freeze marker read by actual v3 code, feature gate and reverse migration.
16. **Scale**: 0/100/1,000/10,000 DLQ items; segment counts at low and configured max; high retry backlog; scan fairness and bounded requests; inbox/outbox capacity and retention.
17. **Transform purity**: instrumentation and review prove library-owned transforms do not yield or call MessagingService/MemoryStore, observers, GUID generation, or cross-key APIs. Consumer callbacks are separately documented as pure/non-yielding; no test can prove arbitrary callback code has no hidden external side effects.

18. **Adaptive configuration**: budget traces with sustained low/healthy/flapping budgets, throttle bursts, changing player counts and Heartbeat delays; one governor coordinates all Records, downshifts promptly, recovers slowly and never changes correctness limits or starves its internal critical lane.
19. **Policy snapshots**: stale revisions, repeated identical revision, same-revision conflicting contents, invalid bounds/schema, provider failures, missing invalidation messages and cold start; last-known-good policy or built-in safe defaults remain effective without blocking profile startup.
20. **Inbox batch and claim races**: repeated IDs inside one batch are rejected before writes; earlier matching receipts are duplicates; payload conflicts and capacity overflow abort all new mutations; claims that expire before the profile transaction are not acknowledged; crash after profile commit before queue ack replays as duplicates.
21. **Outbox event identity and cleanup**: same commit key/payload from the same source returns the same events; the same commit key on different source profiles generates distinct event IDs; different payload under the same source commit key conflicts; partial destination success, cleanup crash and repeated dispatch remove only events whose destination receipts are verified.
22. **Acceleration and fairness**: all hints dropped, duplicated or reordered; cache invalidation missed; high-profile fan-out; per-owner hot spots; MemoryStore throttling/expiry; topic count remains fixed by shard configuration; low-priority maintenance cannot consume RecordStore's critical internal concurrency reserve.
23. **Yielding handlers**: lease renewals under budget pressure, handler yield/error, uncertain service response, cooperative cancellation, session fencing, expired/replaced claims, server shutdown during yield, and redelivery after an external side effect may already have committed.

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
- `ApplyInboxBatchAsync` batches of 1, 4, 8 and 16 messages with duplicate receipts, payload sizes, reducer costs and constrained budgets;
- `DispatchOutboxBatchAsync` with mixed destination latency/errors and grouped source cleanup;
- adaptive-controller CPU cost with 1/10/100 active Records, policy updates, budget traces, throttling and recovery hysteresis;
- fixed-shard wake-up coalescing at growing profile counts versus per-profile subscriptions, including MemoryStore-assisted versus polling-only service-call counts;
- hot-segment contention, canonical message-key updates and worst-case collision verification;
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
- Implement retries, lease fencing, acknowledgement recovery, independent DLQ, replay and status queries. Preserve the existing synchronous/non-yielding handler; add the separate yielding callback only with tested claim renewal, cooperative cancellation and shutdown fencing.
- No MemoryStore dependency and no inbox/outbox format change yet.

### Phase 2 — profile transactional primitives

- Version and migrate the primary profile envelope for inbox/outbox sidecars.
- Implement `ApplyInboxAsync`, opt-in `ApplyInboxBatchAsync`, and `CommitWithOutboxAsync` with capacity/backpressure and explicit transaction boundaries.
- Implement bounded outbox fan-out with grouped cleanup using verified destination receipts.
- Prove that normal session saves preserve concurrent sidecar changes.
- Keep feature activation gated until old writers are drained.

### Phase 3 — workflows

- Add the generic saga coordinator with persisted steps, idempotent inbox legs, recovery and compensation.
- Publish a transfer example only after crash matrix coverage passes.
- Do not expose a misleading atomic cross-profile transfer helper.

### Phase 4 — server-local adaptive governor

- Build one governor shared by all Record instances and integrate it with the existing request-concurrency scheduler.
- Add bounded runtime profiles, configuration validation/revisioning, `get_runtime_snapshot()`, and `apply_runtime_policy()`.
- Preserve a reserved share for profile/session persistence. Do not call `SetRateLimitForRequestType()` automatically.
- Add deterministic budget/throttle traces and hysteresis tests before enabling adaptive mode.

### Phase 5 — measured acceleration and operations

- Add explicit inbox batching and outbox grouped cleanup; verify batch atomicity and per-message idempotency receipts.
- Add the shared sharded MessagingService/MemoryStore hint adapter behind an off-by-default setting, local wake-up coalescing and bounded candidate cache.
- Add approximate health/status endpoints, paginated DLQ tools, repair dry-run and diagnostics.
- Benchmark against polling-only behavior, keep accelerators disabled without measurable benefit, and never change persisted delivery semantics for a performance profile.

### Phase 6 — staged rollout

- Run all Lune regressions, fake DataStore integration/fault-injection suites, Rojo builds, Studio tests and CodSpeed.
- Perform a controlled migration in a disposable DataStore namespace before real data.
- Verify mixed-version rejection and rollback.
- Enable new layout and envelope features separately, each with a kill switch that stops new writes without discarding accepted messages.

## 15. Acceptance criteria

The design is implementable only when tests and runtime evidence demonstrate all of the following:

- Repeating the same producer key and exact request returns one logical message ID using the canonical message record itself as the idempotency receipt, without a separate receipt key.
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
- Performance claims come from dedicated queue/outbox/inbox/saga/adaptive-controller benchmarks and are separated from live Roblox behavior that remains unverified.
- A single server-local governor adapts only bounded scheduling settings from observed DataStore budgets and failures; it never weakens correctness policy or starves critical profile saves/releases.
- A stale or invalid shared policy cannot overwrite last-known-good configuration, and missed policy hints recover through bounded periodic refresh.
- Explicit inbox batches commit all new data mutations and receipts or none; queue acknowledgements occur only after that profile update is verified.
- Optional wake-up topics and local candidate caches are bounded, coalesced and non-authoritative; polling recovers dropped notifications.
- No default code path modifies engine-level DataStore rate limits or assumes a server-local budget proves game-wide headroom.

## 16. Roblox and comparison references

- Roblox DataStore limits: https://create.roblox.com/docs/cloud-services/data-stores/error-codes-and-limits
- Roblox data stores / UpdateAsync: https://create.roblox.com/docs/cloud-services/data-stores
- Roblox versioning, listing and caching: https://create.roblox.com/docs/cloud-services/data-stores/versioning-listing-and-caching
- DataStore request budgets and request categories: https://create.roblox.com/docs/reference/engine/enums/DataStoreRequestType
- MessagingService delivery/limits: https://create.roblox.com/docs/reference/engine/classes/MessagingService/SubscribeAsync
- MemoryStore limits and TTL: https://create.roblox.com/docs/cloud-services/memory-stores
- ProfileStore README: https://github.com/MadStudioRoblox/ProfileStore/blob/main/README.md
- ProfileStore API: https://github.com/MadStudioRoblox/ProfileStore/blob/main/docs/api.md


## 17. Final adversarial audit: remaining risks and required controls

This section is the final review checklist, not evidence that the future implementation has passed it.

| Risk / weakness | Why it matters | Required correction or release gate |
| --- | --- | --- |
| **More small writes can still exhaust budgets** | A canonical message key reduces rewrite amplification but enqueue still spans message state and segment index; profile sidecars add additional request work. | Measure actual request counts and byte throughput. Use inbox batching, outbox grouped cleanup, adaptive admission and fairness. Never claim the new layout is faster just because each key is smaller. |
| **Digest collision or unstable canonicalization** | A hash can route two requests to one key; ordinary JSON output is not automatically a canonical identity encoding. | Use a versioned length-prefixed identity codec, fixed test vectors, full stored identity/request comparison and fail-closed collision handling. Keep exact canonical request identity through the dedup window. |
| **A preparing message may not be indexed yet** | A crash between canonical record creation and segment append leaves a preparing record that routine segment scans cannot discover. | Do not report acceptance before the index and ready state are verified. Caller retries with the same key resume the record. If automatic recovery without caller retry is required, add a bounded preparation journal/index or prove a safe bounded discovery strategy; never solve this by enumerating the whole keyspace each poll. |
| **Per-owner hot keys and bounded slot capacity** | One profile's manifest and append segment can become hot, and a full slot table can return capacity even while some individual messages are small. | Make saturation explicit; measure worst-case same-owner concurrency. Do not add partitions or relocate ready messages without an ordering and stale-writer protocol. A future index-sharding design must be a separately reviewed migration. |
| **Session cache versus durable atomic operations** | A direct inbox/outbox UpdateAsync racing local dirty data or old session ownership can lose updates. | Require a write gate, flush/reconcile dirty state, owner/token/generation fencing inside the transform, and in-memory rebase after confirmed commit. Test old-server races and uncertain flushes. |
| **User reducers can cause external effects** | A reducer can be called more than once by UpdateAsync; the library cannot sandbox arbitrary Luau code or detect all side effects. | Document strict purity. Use only reducers that return data; put non-idempotent effects behind inbox/domain ledgers outside the transform. Tests can cover library code but cannot prove arbitrary consumer callbacks pure. |
| **Adaptive tuning can oscillate or starve saves** | Every Record might otherwise create its own feedback loop, and queue processing could consume budget needed for session save/release. | One server-local governor; fast throttle backoff, slow recovery, hysteresis, reserved critical budget, shared semaphore and deterministic load tests. |
| **Local budgets do not reveal all universe-wide contention** | The per-server budget is not a complete view of shared experience traffic; several servers may collectively trigger throttling. | Incorporate throttle and latency feedback. State that the controller is locally adaptive, not a globally optimal allocator. Any cross-server budget coordinator remains optional and non-authoritative. |
| **Remote policy is untrusted/stale input** | Bad or out-of-order updates could push a server into unsafe settings or cause policy flapping. | Validate whole snapshots, monotonic revisions, strict hard bounds, last-known-good fallback, jittered polling and no per-operation policy reads. Keep runtime settings out of persistence protocol state. |
| **Notification-only acceleration can lose wake-ups** | MessagingService and MemoryStore are transient/best-effort or expiring; per-profile subscriptions can scale poorly. | Fixed bounded topic shards, coalesced wakeups, TTL-limited hints, periodic polling, and tests that intentionally drop every hint. |
| **Metrics can be inconsistent** | A multi-key stats scan is not a linearizable global snapshot. | Label scope/completeness/observation time. Metrics never authorize claims, acknowledgements, purge or migration. |
| **Rollback across envelope versions can lose sidecars** | Old binaries may strip inbox/outbox fields or mutate a format they do not understand. | Old-writer freeze sentinel, version compatibility matrix, retained source copy and explicit reverse migration only when quiesced and verified. |
| **The design is not yet a performance result** | More safety states and per-message records create overhead, and existing CodSpeed baselines lack these workloads. | Add representative CodSpeed workloads, then run isolated Studio/server tests for real request budgets, throttling and cross-server delivery. Keep adaptive/acceleration defaults conservative until measured. |

The preparation gap has an explicit outcome: a `preparing` message is not accepted and cannot execute. A caller retry with the same idempotency key resumes the same canonical record; a transactional outbox keeps retrying until destination acceptance is verified. A message with no idempotency key cannot recover an ambiguous whole-call retry and must be documented as unsuitable for irreversible work. Automatic background recovery of unaccepted `preparing` records is intentionally not promised; this does not lose an accepted message because acceptance is not returned until the record is indexed and ready. If a future API promises background recovery of unaccepted submissions, it must add a bounded preparation journal rather than scan the whole DataStore keyspace.

Known implementation limitation: the API can enforce validation, yielding rules where supported, version fences and bounded calls; it cannot prove arbitrary consumer callback purity, guarantee external API side effects exactly once, or infer all experience-wide request consumption from one server. Those limitations must remain explicit in API docs.