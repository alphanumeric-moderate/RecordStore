# RecordStore durable messaging v2: correctness-first architecture

- Date: 2026-10-17
- Status: Revised design; supersedes the earlier design wherever they conflict
- Audit date: 2026-10-17; cross-key fencing, bounded preparation recovery, tombstone-safe deletion, RTBF routing, metadata preservation, and ordering gates are explicit release requirements
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
7. **Additional gameplay and operator capabilities**: optional receipt processing, idempotent direct profile transactions, application-schema migrations, escrow transfers, guarded diagnostics/restoration, RTBF-aware erasure, deterministic crash simulation, eventual secondary indexes, and correlated operation tracing. These are later design extensions, not part of the initial mailbox activation.

The previous proposal placed full message objects, active state, and dead letters in segmented envelopes. This revision separates the **canonical message record** from the **append-only segment index**. Claims, retries, acknowledgements, and terminal transitions update one message key rather than rewriting the segment. This reduces write amplification and makes cross-key recovery state explicit.

No feature described here is implemented by this document. It is a design contract. New layout and envelope fields stay disabled until compatibility, failure-injection, migration, rollback, and live Studio/server acceptance criteria pass.

## 1. Guarantees and non-goals

### 1.1 Delivery guarantee

The mailbox provides **at-least-once delivery**. A handler may execute more than once if the process stops after a side effect but before a durable acknowledgement, if a claim expires, or if a service returns an ambiguous result. An acknowledged message must not be offered for execution again by mailbox recovery. `expired` means no new handler start is eligible after the expiry boundary; it does **not** prove that a prior claimed handler never ran or that its side effect did not commit. If a previously claimed attempt loses its lease or outcome, report the effect as unknown unless a durable application receipt resolves it.

Do not call arbitrary handlers exactly-once. RecordStore can provide a stronger, narrowly-scoped guarantee for a mutation and its deduplication marker committed together to one RecordStore profile key. That is **effectively-once profile mutation within the retained inbox-receipt window**, not exactly-once behavior for web services, other DataStore keys, MessagingService, or arbitrary user code.

### 1.2 Atomicity boundary

Roblox DataStore `UpdateAsync` is atomic for the key being updated; it does not create a transaction across multiple keys. Any protocol that touches a manifest, segment index, canonical message record, profile envelope, dead-letter index, or saga record must persist intermediate states and recover them idempotently. Submission idempotency is stored in the canonical message record; inbox/commit receipts are stored with the profile envelope rather than in independent receipt keys.

A session-token or generation check read from the profile key cannot atomically fence a write to a separate message key. A session generation copied into a message is an observed association, not proof of current ownership. A local active-session check is required before invoking a profile handler, but can race with a takeover. Every durable profile mutation must independently validate the current owner/session fence inside the profile key's own `UpdateAsync`. Handlers with external side effects remain at-least-once and need their own idempotency/outbox contract.

For existing keys, transformations must preserve current user IDs and user-defined DataStore metadata through the documented `UpdateAsync` return contract unless the operation explicitly changes them. Migration, restore, sidecar updates and maintenance must not accidentally strip metadata. DataStore metadata does not replace RTBF's documented key/name/scope matching requirements.

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
- `capacity`: no durable space is available and no preparation reservation/intent was committed. Once a reservation is committed, do not report `capacity` as if no intent exists; query the active `preparing`/unknown outcome until it is completed or terminally resolved;
- `retryable`: the attempt is known not to have committed, so retry with the same operation key is safe;
- `unknown`: the attempt may or may not have committed and could not be reconciled. Query by the returned `message_id` or retry with the same idempotency key. `get_delivery_async` must query both the canonical message key and its deterministically derived active preparation shard, without a keyspace scan; expose an active reservation as `preparing` with its phase/capacity-block reason. Without a stable ID or idempotency key, do not blindly retry an irreversible operation;
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
| Explicit durable-message priority scheduling with anti-starvation and ordering constraints | No equivalent documented public priority scheduling contract found | Optional message priority tiers and fair per-server scheduling; no cross-server priority authority |
| Idempotent arbitrary profile-key business transaction with stored result | No equivalent documented transaction-receipt API found | One profile-key mutation and stable operation receipt with duplicate/conflict/unknown outcomes |
| First-class MarketplaceService receipt adapter | No equivalent documented ProfileStore receipt adapter found | Opt-in receipt integration backed by idempotent profile transactions and explicit lifetime/retention policy |
| Application-schema migration engine | No equivalent documented application-data migration registry found | Ordered, resumable migrations distinct from the serialization-envelope version, with validation and future-version fencing |
| Escrow-based transfer coordinator | No equivalent documented conservation-aware transfer API found | Explicit pending/reserved/settled workflow using idempotent per-profile legs; no false cross-key atomicity claim |
| Safe data diagnosis and guarded restore workflow | Historical reads are documented | Bounded path diffs, read-only diagnostics, repair preview, expected-revision checks and protocol-metadata preservation |
| RTBF-aware sidecar inventory and erasure | No equivalent documented RecordStore-wide erasure coordinator found | Inventory and bounded deletion of user-associated sidecars, contingent on every key family being RTBF-matchable or otherwise operationally discoverable |
| Deterministic crash/fault simulator | Mock profile operations are documented | Replayable concurrency/time/failure schedules and state-machine invariants across real production-path persistence code |
| Durable secondary indexes/materialized views | No equivalent documented public projection API found | Optional outbox-fed, sharded, rebuildable eventually consistent query projections |
| End-to-end operation tracing | Profile error/critical-state signals are documented | Correlated, bounded lifecycle traces spanning transactions, queue/outbox/inbox and workflow stages |

Primary comparison references:
- ProfileStore README: https://github.com/MadStudioRoblox/ProfileStore/blob/main/README.md
- ProfileStore API: https://github.com/MadStudioRoblox/ProfileStore/blob/main/docs/api.md
- MarketplaceService receipt processing: https://create.roblox.com/docs/reference/engine/classes/MarketplaceService
- Roblox Right to Be Forgotten for data stores: https://create.roblox.com/docs/cloud-services/data-stores/right-to-be-forgotten

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
        ordering_key = nil, -- reserved; non-nil is rejected until strict per-key ordering is implemented and enabled
    }
)
```

This lets a server durably submit work for an offline profile without holding or fabricating an active Record session. Handler dispatch is attempted only by a locally active Record session, checked immediately before invocation. Because queue claim state and the profile session lock live on different keys, this check cannot atomically eliminate a session-takeover race or fence an external side effect. The store-level submitter cannot claim a message or bypass session fencing; profile mutations must independently validate the current session fence on the profile key. The initial v2 release rejects a non-nil `ordering_key`; merely storing a key does not provide a strict-order guarantee.

Existing `Record:EnqueueAsync(type, data)` remains a convenience method; it delegates to the same submission protocol. A third options argument is additive. For valuable/irreversible work, require a caller-stable idempotency key. Validate it as a non-empty string with at most 256 UTF-8 bytes before any DataStore request; reject unsupported/control characters according to the versioned key codec. Producer keys must never be reused for another logical operation, even after retention expires; a late retry after expiry is outside the deduplication guarantee, and irreversible applications must keep a permanent domain ledger. Canonicalization must be a deterministic, versioned serializer: dense arrays preserve order; string-keyed object keys are sorted; sparse arrays, mixed array/object shapes, cycles, unsupported values, and non-finite message numbers are rejected unless an explicit versioned codec supports them. Do not assume raw HttpService JSONEncode output is a canonical fingerprint unless stable key ordering is guaranteed. Retain exact canonical request material throughout the advertised deduplication window; a short hash alone does not prove equality. Calls without one get a unique submission, and an ambiguous outcome cannot be safely deduplicated by repeating the whole call.

### 3.2 Query delivery outcome

Add module-level `RecordStore.get_delivery_async(store_name, scope, profile_key, message_id)` and/or the `Record:GetDeliveryAsync(message_id)` convenience method. Module-level functions use RecordStore's existing snake_case naming convention; Record instance methods retain PascalCase. Return a single canonical message snapshot:

- message ID, owner identity, type, payload schema version;
- lifecycle state, created/updated time, current attempt and total attempts;
- next eligibility time, current claim expiry when relevant;
- terminal result, bounded last error, replay count and last execution/effect-outcome category (`not_started`, `handler_succeeded`, `handler_failed_or_unknown`, or an application-receipt-confirmed outcome);
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

The batch has strict item and encoded-byte ceilings. Only messages for the same profile and compatible schema/reducer may share a transaction. Preserve delivery order explicitly; do not reorder messages with the same ordering key. The scheduler may batch only messages whose claims were successfully acquired for the same owner; it must not wait for a missing claim while holding already-claimed messages indefinitely. If any claim expires before the inbox transaction begins, abort/release or allow those claims to expire and retry the batch. Queue acknowledgements begin only after the profile mutation and all receipts are verified durable. Each queue message is still acknowledged on its own canonical message key; the batch reduces profile-envelope writes, not the per-message claim/ack writes. A crash after profile commit and before any individual ack is harmless because each committed inbox receipt suppresses that message's repeated profile mutation. A crash after profile commit but before queue acknowledgements is safe: redelivery finds the per-message inbox receipts and does not reapply the data mutations.

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

Use a dedicated queue DataStore name/scope reserved for RecordStore's mailbox; do not share that namespace with unrelated application keys or other libraries. Normalize the effective scope exactly as the underlying DataStore API does before computing any route, so omitted and explicit default scopes cannot produce two identities for the same logical owner. The full record owner is `(store_name, effective_scope, profile_key)`. Every route, segment, message, dead-letter, workflow and manifest value must store and validate its full identity; a hashed key is only a routing aid. Producer idempotency uses the canonical message record itself rather than a separate receipt key. The segment index stores the canonical record key; this lets migrated legacy messages keep their original public ID while using a v2-safe route.

The layout consists of:

1. **Constant-bounded manifest** per owner and partition: protocol version, full owner identity, immutable partition count, activation/migration state, a fixed-size segment-slot table, per-slot generation/state/current segment key, and a scan hint. The table is capped at the configured maximum (initially 64); it never grows with message count.
2. **Append-only segment index**: bounded entries containing the canonical message record key plus placement generation, not payload, retry state, or dead-letter history. For new v2 messages the record key is the public message ID; for migrated v3 messages the index key is a stable `m2l-` route while the canonical value preserves the old public ID. Appending is idempotent; message processing never rewrites this index entry. Segment keys include both slot and generation so a reused slot cannot alias an older segment.
3. **Canonical message record and producer receipt**: one DataStore key per logical message. With an idempotency key, the canonical route and public message ID are the deterministic `m2i-` key derived from the full owner tuple plus producer key; the record stores the full owner, original key, exact canonical request, payload, schema version, lifecycle state, retry schedule, attempts, claim token/expiry, current segment locator/generation, correlation IDs, terminal reason, last handler/effect-outcome category, and bounded transition history. This record is both the message and the producer's durable receipt; there is no separate permanent producer-receipt key to keep synchronized. Without a producer key, use a generated `m2g-` message ID; an ambiguous whole-call retry can create a second logical message.
4. **Bounded in-flight preparation registry**: a fixed, configured number of registry shards per owner; the canonical route deterministically selects one shard. A registry entry is a short-lived write-ahead reservation for an incomplete submission, not the durable producer receipt. It stores full owner identity, original producer key, exact canonical submission identity (including payload/semantic options), reservation token/generation, current segment locator/placement generation, and phase. It is cleared only after a matching canonical message is `ready` and its index row is verified, or after a fenced terminal state is durably recorded. Each shard has hard entry and encoded-size caps; saturation returns visible capacity before creating a reservation. These extra UpdateAsync operations and shard contention are a correctness cost and must be measured. The registry is not discoverable by keyspace scan: shard keys are deterministically derivable and their family is bounded.
5. **Independent dead-letter index**: separately segmented canonical record keys for messages in dead-letter state. The canonical message record retains the payload/error needed for inspection and replay. A growing DLQ cannot consume active-segment capacity.
6. **Profile-local inbox and outbox fields**: bounded sidecars in the profile envelope, so the data mutation and its corresponding inbox receipt/outbox intent can be committed in a single UpdateAsync. These fields require a versioned profile-envelope migration and explicit rollout gating.

A per-message canonical record costs more keys and service calls than one large queue envelope, but eliminates rewrites of unrelated message payloads on claim/ack and isolates hot-key traffic. CodSpeed and constrained-budget workload evidence must determine usable defaults rather than assuming this is always cheaper.

### 4.2 Roblox key names and collision rules

Roblox DataStore key names are limited to 50 characters. Define and test a stable key codec for every route, message, segment, idempotency, and DLQ key. Include store/scope/owner identity in the stored value, not only in the key name.

- Use a versioned deterministic route codec with fixed-length keys no longer than 50 characters. Example families are `m2i-<32-hex-digest>` for idempotent message keys/public IDs, `m2g-<32-hex-guid>` for new non-idempotent message keys/public IDs, and `m2l-<32-hex-digest>` for migrated-message storage routes. To make `m2g-` keys 36 characters, normalize a generated GUID to 32 lowercase hex characters by removing its hyphens before adding the prefix. `m2l-` is a storage route, not the preserved legacy public ID. Also use separate fixed-length prefixes such as `mf2-<32-hex-digest>` for manifests, `si2-<32-hex-digest>` for segment indexes, `pr2-<32-hex-digest>` for fixed preparation-registry shards, `di2-<32-hex-digest>` for DLQ indexes and `wf2-<32-hex-digest>` for workflow records. Preparation-shard digests cover the full owner plus a fixed configured shard number, not the producer key itself; producer-route hashing selects the stable shard. Every shard key is subject to the same owner validation and RTBF key-routing requirements as other sidecars. Each digest covers a versioned, length-prefixed tuple containing the full owner plus that record's partition/slot/generation or workflow identity. The idempotency digest covers store, scope, profile key and producer key. Document the exact pure-Luau digest algorithm and fixed test vectors; do not assume Roblox provides a built-in cryptographic hash. Every encoded key in every record family must have a test asserting its actual length is at most 50 characters. For status reads, `get_delivery_async(store_name, scope, profile_key, message_id)` uses direct lookup for reserved v2 IDs (`m2i-`/`m2g-`) and derives the `m2l-` route from `(store_name, scope, profile_key, message_id)` for migrated legacy IDs. If the canonical record is not present yet, directly read the deterministic `pr2-` preparation shard for that route and return its active reservation phase instead of false absence; this lookup is bounded and does not scan the keyspace. During migration, if a legacy public ID collides with a reserved v2 ID format or a distinct canonical record, fail closed and flag manual reconciliation rather than guessing which logical message was intended.
- On every read/update, compare the complete stored owner, producer key (when present), public message ID, record-family identity and exact canonical request to the requested values. Segment and manifest records additionally validate the complete partition/slot/generation tuple. Hash matches only route to a candidate; they never prove identity.
- An idempotent message's record key is derived from a versioned digest of the full length-prefixed owner tuple plus producer key, so the same logical submission maps directly to its canonical message record without a second receipt lookup. A submission without an idempotency key uses a generated ID and cannot deduplicate an ambiguous retry.
- If two inputs map to the same routing key but differ in full identity or request, fail closed with an explicit route-collision/conflict result. Never read, mutate, or overwrite the other owner's record.
- Digests are routing aids, not proof of equality or authentication. A collision must be detected against the stored full identity and exact canonical request; it must never silently alias idempotency keys. Keep an implementation with fixed test vectors and fit every encoded key within 50 characters.
- Test maximum-size store, scope and profile keys as well as generated IDs. Verify encoded serialized bytes, not character estimates.

### 4.3 Boundaries and initial defaults

Initial values are benchmark candidates, not production claims:

- one partition by default; partition count is immutable after activation;
- at most 32 canonical message record keys per active segment;
- at most 64 KiB encoded bytes per segment index, even though it contains only canonical record keys;
- at most 64 live active-mailbox segment slots per partition initially; slots can be reclaimed out of order after all entries are terminal or stale, so a delayed old item does not pin all later completed slots; with 32 IDs per slot, this configuration has a hard ceiling of 2,048 index rows retained in non-reclaimed active-mailbox segments before backpressure. This is bounded capacity, not an unlimited backlog promise;
- independently cap DLQ storage with `queue_dlq_max_segments`, `queue_dlq_segment_max_messages` and `queue_dlq_segment_max_bytes`; initial candidates are 64 slots × 32 IDs (2,048 DLQ index rows) and 64 KiB per segment. With DLQ auto-purge disabled, reaching that limit can block terminalization until verified operator cleanup/capacity reconfiguration. Do not assume this candidate limit is sufficient for a production experience;
- bound concurrent/incomplete submission reservations with fixed `queue_preparation_shard_count = 16` and `queue_preparation_max_entries_per_shard = 16` candidates (256 concurrent active reservations per owner in aggregate). Each active entry's encoded canonical submission identity is capped by `queue_preparation_max_entry_bytes = 131072`; the original producer key is capped by `queue_max_idempotency_key_bytes = 256`. Shard count is frozen after activation. The configuration bounds one shard value to roughly 2 MiB of entry content before structural overhead; the encoded-size validator must reject an oversized aggregate before writing. These limits are candidates, and shard skew can cause local capacity while other shards have room; measure and expose this rather than silently dropping a reservation;
- each reused slot gets a strictly increasing generation encoded into its segment key; generations never wrap or reuse an old key;
- at most 64 KiB encoded payload per message by default, configurable only within validated service/key limits;
- use the current 60-second claim lease and 10-second polling interval as initial candidates; `queue_clock_skew_grace_ms = 5000` is a starting value that must be validated under simulated skew. Lease length and skew grace are correctness-sensitive settings, not adaptive knobs; the controller may change scan/poll/concurrency only within validated bounds;
- deduplication and dead-letter retention must be explicit. Never expire a dedup receipt before the advertised idempotency window.

The proposed snake_case v2 layout options are `queue_layout`, `queue_partition_count`, `queue_segment_max_messages`, `queue_segment_max_bytes`, `queue_max_segments`, `queue_max_payload_bytes`, `queue_clock_skew_grace_ms`, `queue_dlq_max_segments`, `queue_dlq_segment_max_messages`, `queue_dlq_segment_max_bytes`, `queue_preparation_shard_count`, `queue_preparation_max_entries_per_shard`, `queue_preparation_max_entry_bytes` and `queue_max_idempotency_key_bytes`; reuse the existing validated `queue_poll_interval`, `queue_processing_lease`, and `queue_max_attempts` names where compatible. For a new layout, defaults are candidates only: `queue_layout = "v2"` stays gated off; `queue_partition_count = 1`, `queue_segment_max_messages = 32`, `queue_segment_max_bytes = 65536`, `queue_max_segments = 64`, `queue_max_payload_bytes = 65536`, `queue_processing_lease = 60`, `queue_poll_interval = 10`, `queue_dlq_max_segments = 64`, `queue_dlq_segment_max_messages = 32`, `queue_dlq_segment_max_bytes = 65536`, `queue_preparation_shard_count = 16`, `queue_preparation_max_entries_per_shard = 16`, `queue_preparation_max_entry_bytes = 131072`, `queue_max_idempotency_key_bytes = 256`, and the skew-grace candidate is 5000 ms. Slot count/partition count are frozen after activation; choose greater capacity before activation instead of resizing a live layout. Deduplication and DLQ retention are separate options and must be explicitly configured; DLQ auto-purge is disabled by default.

The number of record keys per segment is not the same as maximum pending backlog. Segments may be reclaimed only after every indexed entry is terminal or safely stale and the segment is sealed. Deleting a segment key is not the acknowledgement of any message in it.

### 4.4 Segment rollover and append protocol

The segment index is a discovery aid; the canonical message record is both the message and the producer idempotency receipt. The manifest uses a fixed-size slot table rather than a monotonically contiguous head/tail range. This allows out-of-order slot reclamation when an old delayed item remains pending.

The preparation registry is a bounded, sharded write-ahead reservation table. It prevents concurrent submissions with the same idempotency route from independently selecting different segment locators, and makes interrupted submissions discoverable without scanning the DataStore keyspace. It is transient coordination state, not the durable producer receipt; the canonical message record remains the authoritative receipt after completion.

1. Canonicalize and size-check the complete submission before any write. Prepare the stable message ID/route, exact canonical request identity, producer key, timestamps and a candidate reservation token outside all UpdateAsync transforms. Derive the preparation shard deterministically from the canonical message route.
2. Read the owner/partition manifest and choose a candidate already-published `open` segment generation. Reserve an entry with UpdateAsync on the deterministic preparation shard key, storing full owner identity, original producer key, exact canonical submission identity (including payload and every semantic option), reservation token/generation, phase and the candidate locator/placement generation. Same route plus exactly matching identity adopts the existing reservation and locator; same producer key with different owner/request conflicts. The shard transform is pure/non-yielding. If shard capacity or the encoded-value cap would be exceeded, reject before creating the reservation. A committed reservation with an ambiguous response is `unknown` and is looked up by the stable route.
3. If another writer fills/seals the chosen segment before append, retarget the registry entry with a CAS only after the append is known not to have committed; if append outcome is unknown, keep the locator pinned and reconcile the same row. Increment placement/reservation generation on a confirmed retarget. An uncertain index write must never be followed by a new locator.
4. Create or reconcile the canonical message record at its deterministic/generated route in `preparing` state with the verified reservation locator, full owner, exact canonical request and payload. The UpdateAsync transform rejects a retired/aborted tombstone, conflicts on a different owner/request, and preserves an existing matching record's locator. If the canonical record already exists in a terminal/ready state, verify its identity and reconcile the reservation instead of overwriting it.
5. Append the canonical route and placement generation to the selected active segment with UpdateAsync. The segment must already be published for the reserved generation. Append is idempotent. If the write is ambiguous, retry/verify the same segment row; never use cached absence. Workers skip the row unless its canonical record exists, has matching owner/locator/generation and is `ready`. The registry is the recovery inventory during the interval between canonical creation and index append.
6. Verify the matching index row, then promote the canonical record from `preparing` to `ready` with a CAS checking the expected locator and placement/reservation generation. Return `accepted` only after the canonical `ready` state and matching index row are verified. A result that cannot be reconciled is `unknown`, never presumed non-commit.
7. Clear the active registry entry only after verifying that the canonical record is `ready` and the index row matches. Clear it with CAS on the reservation token/generation so a stale cleanup cannot remove a newer reservation for the same shard slot. If the clear result is unknown, reconcile the shard and repeat idempotently. A crash after readiness but before clear is recovered by observing the ready canonical record and clearing the leftover entry.
8. On restart, scan the fixed preparation shard keys for active entries only. If a canonical record exists, resume the specific missing phase from its recorded state and locator. If the canonical record is absent, the registry still contains the exact submission identity/payload needed to resume the same route. If the message has expired or an explicit cancellation has been accepted, write and verify the canonical terminal/retired tombstone before clearing the reservation. Do not invent payload from a segment row or delete the reservation merely because the caller's response was lost.
9. A registry slot cannot be reused while its prior reservation outcome is unknown. Expired/dead entries are cleared only after the canonical state or retirement tombstone is verified. A stale submitter racing cleanup must encounter the same canonical-key tombstone through UpdateAsync and must not recreate the retired submission. Active reservations are hard-bounded; when all entries in a chosen shard are occupied before reservation commit, return `capacity` with no durable intent. If the registry reservation has already committed but the active-message segment is full, retain the reservation, expose a capacity-blocked `preparing` status and return `unknown` if the caller cannot wait for reconciliation; do not clear the entry or claim that no intent was accepted. Recovery resumes when terminal rows release capacity.

The fixed shard keys are derived from the full owner plus shard number and use no dynamic key enumeration. The registry adds durable UpdateAsync work and can become a hot path, so Section 13 requires dedicated request-amplification, shard-skew, contention and recovery benchmarks. This cost is explicit; the design does not assume the safer protocol is faster.

Slot lifecycle:

- Slots transition through `empty -> allocating -> open -> sealed -> draining -> empty`. Manifest transitions are compare-and-set operations.
- A slot can be reclaimed only after it is sealed and a bounded scan proves every indexed entry terminal or stale. A canonical `preparing` record can be recovered through its active preparation-registry entry; it must not be treated as accepted unless the matching index row and `ready` state are verified. A preparation registry entry cannot be cleared as complete until those checks pass, or until a canonical terminal/retired tombstone is verified. Keep each old generation permanently non-writable through the manifest generation/tombstone rule. Keep canonical terminal/retired tombstones until their idempotency, uncertainty and diagnostic-retention rules permit deletion.
- A slot generation is part of the segment key and strictly increases. A segment key is never reinitialized for another generation. Only the allocator may initialize a new segment, and append to a missing generation is rejected; this prevents an old delayed writer from recreating a purged index.
- Reclaim slots out of order to avoid head-of-line capacity loss. Polling scans the fixed slot table fairly; it does not assume a contiguous range.
- Accepted messages are not relocated simply because another slot becomes available. Relocation is allowed only while preparing and after the previous segment is sealed and the index pair verified absent.
- The manifest is rewritten only on slot allocation/reclamation, not each enqueue or lifecycle transition. Segment ID arrays are rewritten only on append/seal, never on claim, retry or acknowledgement.

### 4.5 Lifecycle state machine

Canonical message states:

- `preparing`: submission is not yet claimable; index/message reconciliation is permitted.
- `ready`: accepted and eligible after `available_at`.
- `claimed`: current claim token and lease fence the worker. A persisted claim whose lease expires remains in `claimed` until a fenced takeover or terminal recovery; an expired lease never proves the previous handler stopped.
- `acknowledging`: handler success is recorded; recovery finishes acknowledgement without invoking the handler again.
- `dead_lettering`: terminal failure is recorded; recovery finishes DLQ indexing without invoking the handler again.
- `acknowledged`, `dead_lettered`, `discarded`, `expired`: terminal states.

Allowed transitions are validated in the canonical message's UpdateAsync transform. Handler-owned message-state transitions require the current claim token, live lease and the claim/session-generation value stored on that same canonical message record. This only fences message-state changes; it does not prove that a separate profile session key is still owned by the worker. Recovery after lease expiry uses a separate CAS that checks the stored expired token/deadline plus the clock-skew grace, then atomically invalidates the old token before installing a new claim or a terminal recovery state. Profile mutations still validate the durable session fence on the profile key itself. A stale claim cannot acknowledge, renew, retry, discard or dead-letter a message. Terminal states are monotonic except an explicit replay operation, which increments the replay generation and creates a new active placement. Old index entries have older placement generations and are ignored.

### 4.6 Claim, retry and acknowledgement

**Claim:** inside the canonical message UpdateAsync, branch on the current state. For `ready`, if `expires_at <= now_ms`, transition to `expired`; otherwise claim only when `available_at <= now_ms`. For `claimed`, do nothing while the lease is live; only after the persisted lease deadline plus clock-skew grace may a worker CAS a takeover. On takeover, if the message has passed `expires_at`, make it terminal `expired` rather than starting another attempt; if a prior claim existed and no durable application receipt resolves it, preserve the effect outcome as unknown and expose that distinction in delivery status. `expired` does not assert that no prior side effect occurred. If attempt/age limits are reached before expiry, transition to `dead_lettering`; otherwise assign a new token, increment attempts/recovery counters, and record the processing server plus its observed session generation. Any old worker is fenced from changing the canonical message state after a winning takeover, but a lease cannot stop an already-running arbitrary callback or external side effect. A concurrent claimant can win only one CAS. Capture `now_ms` and token before UpdateAsync so transforms remain deterministic. If the claim call returns an unknown outcome, do not invoke the handler merely because the call errored: reconcile the canonical record against that precomputed token and invoke only if the same token is currently stored and there is a configured safe lease margin remaining. If that cannot be confirmed, stop and allow normal lease recovery. The service-call duration is not a hard real-time bound, so lease settings do not prove exclusive external execution. `expires_at` is the latest time a message may *start* processing, not a deadline that interrupts a valid in-flight handler. A takeover is at-least-once recovery, not proof the prior handler stopped.

**Renewal:** renew only when the persisted token and current message state match. Also check the local Record session manager and expected profile generation before renewing, but do not treat that separate-key check as atomic ownership proof. A profile write remains responsible for checking its own durable fence. If a renewal result is unknown, reconcile the stored token/deadline; do not assume the lease was extended. A valid in-flight claim may finish and renew after `expires_at`, because that timestamp prevents late starts rather than interrupting work already claimed. Renewals have a maximum extension/deadline to prevent permanently stuck handlers. An expired token cannot renew itself. Cross-server lease deadlines use UTC wall-clock timestamps and therefore have clock-skew uncertainty; add a validated `queue_clock_skew_grace_ms` (initial candidate: 5,000 ms) before takeover. The grace reduces early takeover but is not a proof of exclusive execution. Inject clock jumps/skew in tests and keep user effects idempotent.

**Retry:** under the live token, persist `ready`, cleared lock fields, normalized last error, attempt counters and an explicit next `available_at`. Use capped exponential backoff with deterministic/injected jitter. Limit total attempts and delivery age. The next handler must not run before the stored time. If the message's `expires_at` has passed, transition to `expired`; at attempt/age limits, transition to `dead_lettering`.

**Acknowledgement:**
1. Persist `acknowledging` on the canonical message only when the stored claim token matches and the lease is live at this message-key transition. This key cannot atomically prove that the profile session key is still owned by the worker; any profile mutation must independently validate its current session fence inside the profile-key UpdateAsync.
2. Persist the canonical message as `acknowledged` with the same operation/claim identity.
3. Recovery repeats step 2 idempotently and never invokes the handler for an `acknowledging` message. Because the canonical message record also serves as the producer receipt, there is no cross-key producer-receipt update.

If the handler effect committed but the state never reached `acknowledging`, redelivery is possible. This is why the atomic inbox pattern is a first-class API.

**Dead-lettering:**
1. After a live handler fails/exhausts policy, persist `dead_lettering` under its current token; after an expired-claim recovery exhausts attempts/age, use the separate expiry-fenced CAS described above to enter `dead_lettering` without invoking the handler.
2. Append the canonical message record key and terminal generation to the independent DLQ index idempotently.
3. Persist `dead_lettered` on the canonical message only after the matching DLQ entry is verified.
4. Recovery repeats the same transitions idempotently. `dead_lettering` is never eligible for user handler execution, and the canonical record remains queryable as the producer's outcome receipt. If the DLQ index is full or unavailable, the record remains durably `dead_lettering`, is exposed as a blocked terminalization/capacity condition, and is retried after capacity is restored. Do not reclaim its active segment row or claim terminal DLQ visibility until the DLQ index is verified. Backpressure new admission and expose an operator action; never silently purge history to make room. Full-DLQ operation is a bounded-stall mode, not a liveness guarantee.

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

For the first release, promise FIFO append placement per partition only, not FIFO execution across concurrent workers. With partition count greater than one, placement order is per partition. The initial v2 API rejects a non-nil `ordering_key`; strict per-key execution ordering is a future, separately specified/opt-in protocol requiring durable sequence/front-of-key arbitration, restart and gap recovery, fairness, lease-expiry and head-of-line tests. Do not silently accept an ordering key with no guarantee, and do not infer order from timestamps alone.

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

Built-in runtime profiles define scheduling preferences, not correctness behavior:

| Profile | Intended behavior | Trade-off |
| --- | --- | --- |
| `latency` | Prefer shorter idle-poll intervals and faster processing of eligible work while budget headroom is healthy | Higher request consumption; governor backs off immediately on pressure |
| `balanced` | Moderate poll and concurrency targets with normal maintenance | General default when no application-specific role exists |
| `budget_safe` | Longer idle-poll intervals, lower noncritical concurrency, and earlier suspension of maintenance | Higher queue wake-up latency during constrained budgets |
| `background` | Favor throughput and bounded batches for explicitly low-priority jobs | Must still preserve the critical persistence reserve and cannot override per-message ordering/transaction boundaries |

`auto` starts from `balanced` (or an explicitly configured role-to-profile mapping) and tunes from measured service and workload feedback. It must not infer game semantics from player count alone.

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
- Use weighted fair scheduling and bounded per-owner slices so a noisy profile or poison message cannot starve other profiles. Preserve ordering for the same configured ordering key. The priority-aware scheduler is specified in section 28 as a future opt-in feature. The initial mailbox release uses the normal/default priority and does not claim priority-aware queue ordering.
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

Useful fields include preparing-reservation count, oldest reservation age, per-shard reservation usage/headroom, capacity-block reason, active/claimed/delayed/acknowledging/dead-lettering counts, oldest eligible age, oldest pending outbox age, expired claim recoveries, retry distribution, terminal error distribution, idempotent duplicate submissions, conflict/capacity/unknown outcomes, migration phase, segment count, scan cursor progress, hint failures, DLQ retention eligibility and stuck workflow step.

**Accuracy contract:** a scan across many keys is not a linearizable snapshot. Every multi-key stats result includes `observed_at`, scanned range, completeness, and whether counters are exact, approximate, or process-local. Approximate metrics must never control claim correctness, purging, admission, or migration. Exact message status comes from its canonical message key. A background reconciler repairs projections using idempotent operation IDs, and reports discrepancies rather than silently rewriting ambiguous state.

Do not log payloads, purchase tokens, player secrets or arbitrary user data by default. Provide correlation IDs and stable error categories while bounding the stored error text.

## 11. Migration, rollout and rollback

The existing queue v3 value stores active messages and dead letters together. Earlier legacy queue values may have no verifiable owner metadata; a non-empty ownerless legacy queue remains a manual-recovery stop.

### 11.1 Mailbox migration

1. Verify full owner identity, supported source version and queue shape. Corrupt or mismatched data is preserved untouched. Preflight all legacy public IDs against the reserved `m2i-`/`m2g-` public-ID namespace; if a collision exists, stop migration before writes and require an explicit operator resolution.
2. Only after the compatibility bridge is deployed and all unbridged old writers have been drained/fenced, atomically replace the v3 queue envelope with a future-version freeze marker that preserves the exact source payload and migration ID. The bridge/new writer must reject the marker. Do not assume an already-deployed v3 binary recognizes it; the deployment fence, not the marker itself, prevents stale writes.
3. Copy old messages to canonical message records, segment indexes and DLQ indexes idempotently by migration ID and legacy message ID. Preserve each public legacy message ID, timestamps, attempts, replay counts, last error and payload; use a stable `m2l-` storage route derived from the full owner plus legacy ID. Segment entries carry that storage route, while the canonical value retains the original public ID. `get_delivery_async(store_name, scope, profile_key, legacy_message_id)` derives the v2 route from the full owner and legacy ID. Do not carry stale claim tokens as valid.
4. Verify every message record and index entry. Keep all imported messages non-claimable while migration is incomplete.
5. Activate the new manifest only after all copied data reconciles. Keep the frozen v3 source read-only as a recovery copy.
6. Resume interrupted migration on a compatible server. Do not reset a partially imported mailbox to empty or discard unknown entries.
7. Rollback may use only a binary that understands the current envelope and mailbox version. Reverse migration to v3 is allowed only after the queue is quiesced, all data is verified to fit the old envelope limits, and no unsupported state exists. Never silently downgrade, empty-fallback or remove the source copy as part of normal migration.

A freeze marker is not a fence against an old binary that does not validate envelope versions. Before migration, deploy a compatibility bridge that rejects unsupported/frozen versions, then stop/drain old binaries and wait out their session/write lease window before enabling the new writer. If the already-deployed v3 transform ignores future-version fields, the marker is advisory only; migration is unsafe until operational quiescence is verified. Add a compatibility test against the actual v3 parser and transform; prose or a marker alone is insufficient.

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
6. **Claim concurrency**: many workers claim one message; one live token wins; expired `claimed` messages can be taken over only through CAS after clock-skew grace; lease renewal, expiry, server shutdown and session generation changes fence stale message-state transitions and profile writes at their respective keys. The simulator must also demonstrate that an old callback may continue running but cannot commit a fenced profile mutation, and must not claim external side effects are fenced. Simulated fast/slow clocks never permit an old token to ack after takeover.
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
24. **Lease expiry recovery**: expired claim under attempt limit transfers to a new claim token; expired claim at attempt/age limit enters DLQ without handler replay; an expired `expires_at` message becomes terminal without a late start; acknowledgement racing takeover has exactly one CAS winner.
25. **Developer product receipt races**: duplicate receipt on two servers, missing player/profile, ambiguous profile transaction, same PurchaseId with mismatched identity/product, retry after commit-before-error, and receipt decision before versus after durable grant state.
26. **General transaction API**: repeated operation ID/same request, ID/request conflicts, reducer retry determinism, receipt capacity, expired dedup window, dirty-memory flush failure and concurrent session fencing.
27. **Application schema migration**: idempotent resume after every write window, target-version commit ambiguity, unsupported future schema, validation quarantine, canary gate, old-writer rejection and restore from a verified version.
28. **Escrow transfer conservation**: crash after reservation/credit/settlement, destination unknown outcome, duplicate transfer ID, concurrent spending, item mutation while reserved and operator reconciliation; the sum of spendable assets plus escrow remains conserved.
29. **Profile Doctor safety**: preview/apply revision race, truncated large diff, malformed and future versions, protocol sidecar preservation, verified recovery point and restore during old-session attempts.
30. **Erasure coverage**: render each RTBF key template, identify every user-associated sidecar, shared/multi-user payload separation, retries after partial removal, active session fencing, cache invalidation and explicit unknown/uncovered legacy keys.
31. **Secondary indexes and tracing**: duplicate/out-of-order projection events, rebuild from checkpoint, deleted source, stale query confirmation, trace truncation/privacy, trace-sink failure and proof that tracing adds no separate hot-path write.
32. **Performance optimizations preserve contracts**: no-op save only when clean is proven; coalescing obeys maximum dirty age; read singleflight never merges session acquisition; compression round-trips all supported codecs; queue cursors recover dropped hints; budget reserves prevent starvation; benchmark toggles do not alter durable state semantics.
33. **Durability SLO and dirty-state visibility**: nested mutation, direct-mutable-table tracking gap, successful commit versus unknown write, age threshold crossing, repeated alert coalescing, no DataStore write per alert and accurate unavailable/estimated status.
34. **Unified outcome/retry policy**: inject definitive failure, commit-then-error, fenced session, schema conflict and capacity result for each API family; verify that unknown outcomes are reconciled by the same stable operation ID and never converted to presumed failure.
35. **Degraded mode and backpressure**: write outage, prolonged dirty age, bounded-buffer item/byte/age limit, queue saturation, mode recovery, shutdown and critical reserve pressure; confirm optional work is rejected visibly and critical intents are not falsely acknowledged.
36. **Session contention diagnostics**: many simultaneous open attempts, stale status read, cancellation during wait, timeout around ambiguous ownership write, takeover race and old owner resume; diagnostic reads never change lease authority and retries remain bounded/fair.
37. **Retention compactor/maintenance runner**: crash before/after checkpoint, unknown deletion outcome, stale cursor, live index reference, pending saga/outbox dependency, active lease, budget starvation and resume; no evidence needed for idempotency/recovery is deleted.
38. **Priority correctness and idempotency**: the same stable enqueue idempotency key with a different priority conflicts because priority is part of the exact canonical request; accepted priority is immutable unless the explicit reprioritize protocol is enabled; repeated/stale reprioritize IDs are idempotent.
39. **Priority versus ordering**: high priority does not bypass an earlier message sharing an ordering key; unkeyed eligible messages can be selected by lane; delayed/preparing/claimed/expired items cannot be claimed merely due to priority.
40. **Anti-starvation under load**: sustain a high-priority flood while normal/background messages are pending; assert bounded lane service under healthy service conditions, configured aging behavior, per-owner fairness and no unlimited high-lane monopolization.
41. **Index hints and lane migration**: stale priority bucket, duplicated index row, stale placement generation, new lane creation and disabled-priority fallback never permit duplicate delivery or permanent message invisibility.
42. **Local work-class priority**: critical saves/releases during queue/outbox/maintenance pressure retain reserved internal capacity; maintenance yields; disabled priority scheduler falls back to fair FIFO/weighted scheduling without changing durable semantics.
43. **No global server-priority assumption**: competing servers with different roles/budgets, lost and delayed hints, server death and replacement, stale role policy and background-only worker failure; any eligible healthy server can still recover/claim according to durable CAS/fencing.
44. **Priority performance trade-offs**: compare enabled/disabled and multiple priority mixes with equal input volume; record queue wait by lane, scan amplification, request counts, critical-save p95 and background starvation under high load; no benefit is claimed from synthetic scheduling tests alone.
45. **Cost-aware deficit round robin**: one high-cost owner versus many low-cost owners, missing/corrupt cost hints, conservative fallback, oversized legal work, cost-model revision and budget changes; large work eventually gets service without starving small work or critical persistence.
46. **Deadline slack and service-age behavior**: urgent bursts, negative slack, no deadline estimate, expiry at claim boundary, overdue policy, starvation promotion and throttled service; SLO metadata never changes expires_at or lease authority.
47. **Lease renewal under scheduler pressure**: expiry-margin ordering, slow UpdateAsync, throttle burst, old token renewal after takeover, maximum renewal horizon and critical-save contention; expired/replaced claims cannot revive.
48. **Due-time wheel recovery**: server restart, dropped wakeup, stale heap entry, same bucket burst, clock skew, delayed retry and queue empty for long intervals; polling always rediscovers due accepted messages within the documented reconciliation bounds.
49. **Adaptive batch window semantics**: sparse traffic max-wait, high backlog hard item/byte caps, batch-size changes, caller-defined atomic batch boundaries, partial outbox fan-out and uncertain destination result; unrelated business transactions never merge.
50. **Retry-token/congestion control**: many simultaneous throttles, synchronized retries, token exhaustion, service recovery burst, hot permanently failing key, unknown result and poison message; retry controls delay work but never discard or falsely complete it.
51. **Workflow priority inheritance**: ready predecessor boost, cycle rejection, boost expiry, terminal/unknown predecessor, unrelated workflow fairness and per-workflow cap; inheritance never skips dependencies or triggers premature compensation.
52. **Shadow scheduler non-interference**: shadow enabled/disabled, trace overflow, scheduler error, missing candidates and policy rollback; the shadow path performs no claim/write/publish and never changes production selection.
53. **Scheduling policy comparisons**: same deterministic inputs across FIFO, weighted fairness, DRR, deadline-aware, and batched policies; report queueing p95/p99, request amplification, starvation, memory, and critical save/release regressions.
54. **Combined overload stress**: high-priority flood plus due-time burst, lease renewals, retries, outbox fan-out and maintenance at low budgets; verify per-class bounds, critical reserve, no accepted-work loss and recovery after budget restoration.
55. **Profile-session authority boundary**: claim metadata is committed on the message key while session ownership changes on the profile key; a stale local check may not authorize a profile write, and every mutation is fenced at the profile-key UpdateAsync.
56. **Preparation-index and orphan cleanup**: crash before/after reservation, canonical record creation and ready promotion; a never-retried orphan remains bounded and is recovered/retired through the existing segment index and canonical-key tombstone without whole-keyspace scans.
57. **DLQ saturation and blocked terminalization**: fill the DLQ index, crash in dead_lettering, and restore capacity; no handler reruns, no message is falsely dead_lettered, active rows are retained, and admission/diagnostics expose the stall.
58. **Tombstone-safe physical deletion**: RemoveAsync races with stale writes, unknown deletion outcomes, index reuse and cursor restart; retired generations cannot be recreated and idempotency evidence is not purged while outcomes remain unknown.
59. **DataStore metadata preservation**: profile updates, inbox/outbox operations, migration and restore preserve user IDs/metadata unless explicitly changed; validate callback return values and all key-family paths.
60. **RTBF, history and restoration interaction**: render all templates against name/scope/key constraints and the 100-template limit; erased data cannot reappear through version restore, rollback, replay, projection rebuild, stale writes or cache repopulation.
61. **Ordering feature gate**: non-nil ordering_key is rejected while strict ordering is off; when enabled, per-key sequence/gap recovery and priority fairness work across crashes; differing priority under the same producer ID conflicts.
62. **Late/unknown claim and renewal outcomes**: delayed UpdateAsync response, commit-then-error, scheduler pause and clock skew; handlers start only after the current token and safe lease margin are confirmed; unknown renewal never assumes extra lease time.
63. **Migration implementation revision**: same migration_id with a different declared revision/digest conflicts; runtime never relies on introspecting/fingerprinting arbitrary Luau closures.
64. **Value/key/throughput ceilings**: near-50-character names/keys/scopes, near-4-MiB serialized envelopes, inbox/outbox/receipt sidecar growth and per-key throttling; the serializer rejects over-limit writes before a partial transition.
65. **Finite retention with unresolved operations**: unknown or in-flight operations are not physically purged when doing so could erase the only reconciliation evidence; permanent business IDs stay in a domain ledger for the required lifetime.
66. **Expiry after claim / uncertain side effect**: claim expires while the old handler is delayed or still running, the deadline passes and takeover occurs; terminal expiry prevents a new start but reports the previous effect as unknown unless an application receipt resolves it.
67. **Independent DLQ bounds and retention**: active mailbox full, DLQ full with auto-purge disabled, manual verified purge, capacity increase and crash during terminalization; no accepted item is lost, no DLQ terminal result is reported before its row is verified, and backpressure/stuck age remain observable.
68. **Preparation registry idempotency and contention**: concurrent same-route/same-request submission, same-route/different-request conflict, same registry shard contention, stale reads, retries across servers, duplicate reservation protection and canonical-receipt adoption.
69. **Preparation registry saturation and crash recovery**: full shard, over-limit encoded identity, crash after reserve/locator/canonical/index/ready/clear, unknown registry UpdateAsync and delayed caller after tombstone; no keyspace scan, duplicate logical delivery or silent loss of the durable pending intent.
70. **Unknown preparation lookup and capacity semantics**: reservation committed but caller gets an ambiguous response, canonical message not yet written/indexed, shard or active queue is full, and recovery restarts; status resolves through the route preparation shard, `capacity` is returned only when no reservation committed, and active durable intent is never reported as absent.



The regression test must fail against the old implementation for the reason it claims to cover. A passing unit fake does not replace a Studio server playtest for real DataStore and service throttling behavior.









## 13. CodSpeed and service-budget validation

The existing main CodSpeed run has no dedicated durable-mailbox, outbox, inbox or saga benchmark. At the 2026-10-17 audit, the PR-head CI run contains only the existing 20 harness benchmarks (CodeNum, PlayerData, profile lifecycle and compatibility cases), not the proposed queue/scheduler workloads. Its hosted WallTime report flags an unknown runner environment, syscall-dominated cases and runtime-environment differences; a reported aggregate regression therefore cannot be attributed to this documentation-only diff, but it also does not count as a performance pass. Existing hosted WallTime results have environment-noise warnings and some simulation cases are syscall dominated; do not reuse those numbers as queue latency evidence.

Add repeatable benchmarks for:

- ID-index append in empty/partial/full segments;
- accepted enqueue with preparation registry reserve/clear, repeated idempotent submission, same-key/different-request conflict, active-shard saturation and skew; report UpdateAsync calls per accepted message, hot-shard contention, bounded recovery scans and p95/p99 enqueue latency;
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

### Phase 7 — idempotent transactions and receipts

- Land and verify the general single-profile `TransactAsync` mutation/receipt primitive before building the purchase adapter.
- Define receipt retention, long-lived PurchaseId uniqueness, storage growth and unresolved/unknown outcome handling before registering any live MarketplaceService handler.
- Test both same-profile immediate grants and explicitly modeled durable pending entitlements; never mark a receipt processed merely because an in-memory grant ran.

### Phase 8 — application schema migration and Profile Doctor

- Add schema-version metadata, deterministic migrations, read-only preview, validation and future-version fencing.
- Build the crash simulator before enabling automatic migrations or guarded restore in production.
- Require verified historical recovery, revision/session-fenced application and operator-visible quarantine before any destructive repair is exposed.

### Phase 9 — escrow transfer and materialized views

- Implement the generic workflow/inbox receipts first, then the escrow coordinator with conservation invariants and unknown-result reconciliation.
- Treat projection/index updates as downstream rebuildable consumers with explicit eventual consistency and source-version checkpoints.
- Do not enable asset transfer helpers or unique indexes until concurrent and crash-injected state-machine tests pass.

### Phase 10 — erasure inventory and correlated tracing

- Resolve RTBF-compatible key routing and inventory every persisted sidecar before claiming complete deletion coverage.
- Ship tracing with bounded storage, redaction and no mandatory extra write per hot-path event.
- Verify partial erasure, legacy sidecars and trace-sink failures without weakening core persistence.

Performance improvements from section 26 are evaluated as isolated changes at every phase. They may not be used to bypass correctness gates, and their default activation is based on comparable measurements rather than assumed speedups.

## 15. Acceptance criteria

The design is implementable only when tests and runtime evidence demonstrate all of the following:

- Repeating the same producer key and exact request returns one logical message ID using the canonical message record itself as the idempotency receipt, without a separate receipt key.
- Reusing a producer key for a different request fails closed.
- An accepted message survives every crash window and is eventually discoverable without relying on notifications.
- One canonical message record prevents a duplicated/stale index row from creating two concurrent deliveries.
- Claim tokens fence message-state transitions; each profile mutation must check current session ownership inside that profile key's UpdateAsync. This does not stop an already-running arbitrary callback or external side effect; those remain at-least-once and require idempotency/outbox. Expiry after a prior claim can leave an unknown effect outcome; it is not proof of non-execution. Expired claims are recoverable.
- Durable acknowledgement recovery never reruns a message already in the acknowledging state.
- Expiry prevents new handler starts after the defined boundary; it does not assert that an earlier claim had no side effect. Unknown prior effects are surfaced and require application-ledger reconciliation.
- Dead-letter growth does not enlarge active segment writes or consume active message capacity.
- Inbox mutations and their receipts are atomically committed to the same profile key.
- Outbox intent and source data mutations are atomically committed to the same profile key.
- Outbox dispatch is idempotent; a destination-accepted event is not duplicated when source cleanup crashes.
- Multi-profile workflows converge through idempotent steps or a documented compensation/manual resolution.
- Stats identify their completeness and are never treated as source of truth.
- Migration preserves the v3 source; a compatibility bridge rejects unsupported/frozen formats, operational checks verify unbridged writers are drained/fenced, and rollback never silently drops unsupported sidecars.
- Performance claims come from dedicated queue/outbox/inbox/saga/adaptive-controller benchmarks and are separated from live Roblox behavior that remains unverified.
- A single server-local governor adapts only bounded scheduling settings from observed DataStore budgets and failures; it never weakens correctness policy or starves critical profile saves/releases.
- A stale or invalid shared policy cannot overwrite last-known-good configuration, and missed policy hints recover through bounded periodic refresh.
- Explicit inbox batches commit all new data mutations and receipts or none; queue acknowledgements occur only after that profile update is verified.
- Optional wake-up topics and local candidate caches are bounded, coalesced and non-authoritative; polling recovers dropped notifications.
- No default code path modifies engine-level DataStore rate limits or assumes a server-local budget proves game-wide headroom.


- Purchase receipt handling uses stable transaction IDs, commits a verified durable grant before acknowledging completion, and has an explicit retention/lifetime-idempotency policy.
- `TransactAsync` commits profile mutation and operation receipt to one profile key; duplicate and conflict outcomes are distinguishable and unknown writes are reconcilable.
- Application schema migration is separately versioned from the serialization envelope, resumable, validated and fail-closed on future schemas.
- Escrow transfer tests demonstrate asset conservation through every crash/unknown-result window and never compensate before a destination outcome is reconciled.
- Profile Doctor defaults to read-only, guards restoration by revision/session fencing, and preserves protocol metadata and a verifiable recovery path.
- Every persistent user-associated sidecar has a declared RTBF/deletion strategy; no coverage claim relies only on opaque hashed keys or whole-keyspace scans.
- The deterministic crash simulator can replay injected failures and validates production-path invariants; Studio/platform contract tests remain separate.
- Secondary indexes are eventually consistent, rebuildable and never substitute for authoritative validation; operation tracing is bounded and adds no mandatory separate write per hot-path event.
- Each performance optimization has a baseline, target metric, representative CodSpeed workload, correctness tests, rollback/disable path where practical, and no claim of real service improvement from mocks alone.



- Advanced scheduling remains feature-gated until shadow/replay reports and workload-specific benchmarks demonstrate service fairness, correct ordering and no unacceptable critical persistence regression.
- Lease renewal, retry pressure, delayed wakeups and batch-formation policies preserve the canonical message state machine; local timers/cost estimates/shadow decisions are never authoritative.

- The priority matrix is reflected in implementation ordering: simulator/outcome contracts and bounded durability/backpressure controls precede purchase, transfer, migration automation, erasure and projections.
- Durability snapshots expose age/revision/uncertain-write limitations and cannot claim clean state when mutation tracking is incomplete.
- Degraded-mode policies have hard bounds and never treat an in-memory buffer as durable acknowledgement.
- Session diagnostics are read-only with respect to ownership; maintenance/compaction is resumable, cursor-bounded and protects live idempotency/workflow dependencies.

- The planned failure-injection matrix contains 70 groups, including key/session authority boundaries, fixed-shard preparation idempotency/saturation, unknown status/capacity semantics, orphan recovery, DLQ saturation, tombstone-safe deletion, metadata preservation, RTBF/restore interaction, uncertain-effect expiry, and late lease outcomes.

## 16. Roblox and comparison references

- Roblox DataStore limits: https://create.roblox.com/docs/cloud-services/data-stores/error-codes-and-limits
- Roblox data stores / UpdateAsync: https://create.roblox.com/docs/cloud-services/data-stores
- Roblox versioning, listing and caching: https://create.roblox.com/docs/cloud-services/data-stores/versioning-listing-and-caching
- DataStore request budgets and request categories: https://create.roblox.com/docs/reference/engine/enums/DataStoreRequestType
- MessagingService delivery/limits: https://create.roblox.com/docs/reference/engine/classes/MessagingService/SubscribeAsync
- MemoryStore limits and TTL: https://create.roblox.com/docs/cloud-services/memory-stores
- ProfileStore README: https://github.com/MadStudioRoblox/ProfileStore/blob/main/README.md
- ProfileStore API: https://github.com/MadStudioRoblox/ProfileStore/blob/main/docs/api.md



## 17. First-class purchase receipt processor

**Status: design proposal only.** This adapter builds on the idempotent transaction and inbox/outbox primitives; it is not a second persistence protocol.

### 17.1 API shape and receipt integration

Propose an opt-in adapter such as:

- `ReceiptProcessor.new(config)`;
- `ReceiptProcessor:CreateHandler(grant_reducer)` to create a callback without changing global MarketplaceService behavior;
- explicit integration helpers for `MarketplaceService:BindReceiptHandler()` when supported by the runtime and for the legacy `MarketplaceService.ProcessReceipt` callback;
- `ReceiptProcessor:GetStatusAsync(receipt_id)` for the durable state and last known outcome.

The adapter must never silently replace a game's global `ProcessReceipt` callback or register an implicit catch-all handler at module require time. The game remains responsible for registering one compatible integration and for mapping the product catalog to server-authoritative grant definitions. If a runtime supports multiple receipt handlers, registration conflicts must fail visibly. A callback must not rely on a Player instance remaining present after any yield.

Use `PurchaseId` as the stable idempotency identity for developer-product receipts. Support other MarketplaceService receipt types only through explicit receipt-type adapters with their own stable identifier contracts; do not assume that every receipt has `PurchaseId`. For Robux transfer receipts, for example, correlate using the documented transfer request identity and separate sender/receiver decisions.

### 17.2 Correctness contract

- Validate receipt type, transaction ID, player/user identity, product ID and configured grant definition. Never accept a grant amount or product definition from an untrusted client.
- If the profile session is not open, has been fenced, or cannot safely accept the grant, return the platform's unresolved/retry decision instead of pretending to succeed.
- Use `Record:TransactAsync()` for a same-profile grant when the complete grant mutation and its deduplication receipt can be committed together to that profile key.
- Repeated delivery of the same transaction with the same canonical request returns the prior durable outcome. The same transaction identity with a different user, receipt type, product or payload is a conflict that fails closed and raises an operator-visible diagnostic.
- If a durable write outcome is unknown, reconcile the same transaction ID before deciding. Never blindly add the reward a second time.
- Mark a receipt processed only after the reward is durably represented according to the application's declared grant semantics. For a conventional immediate currency/item grant, this means the profile mutation and receipt result are committed. A durable pending-entitlement ledger may count as the grant only when the game explicitly treats that ledger as the entitlement source of truth and the entitlement is safely redeemable.
- A grant reducer returns data only. No yielding, network calls, event firing, inventory Instance mutation or other external side effects may occur inside the UpdateAsync transform. Apply in-memory presentation changes only after the durable transaction result is confirmed.
- Cross-profile rewards use a durable, idempotent workflow. Do not claim a two-profile atomic transaction. The receipt can be acknowledged before a recipient-side projection only if the application's persistent entitlement/order record is already the authoritative grant and reconciliation is guaranteed; otherwise leave it unresolved until the defined grant-completion condition holds.

### 17.3 Receipt retention is a design decision

A bounded operation-receipt window cannot guarantee duplicate suppression forever. Receipt processing must expose its retention contract and must not silently purge tombstones while a transaction may still be delivered again. Long-lived purchase uniqueness requires either a compact permanent purchase ledger or a durable entitlement model keyed by transaction ID. The design must explicitly account for storage growth and provide bounded archival/compaction only when the application can prove older IDs cannot grant again or their permanent effect is represented in another authoritative ledger. A separate receipt key and profile reward mutation are not atomic by themselves; any split-key design must use a recoverable purchase-intent state machine and must not imply cross-key atomicity.

Official API references are listed in section 16. No automatic MarketplaceService callback registration or live purchase processing is implemented by this spec.

## 18. General idempotent profile transaction API

**Status: design proposal only.** This is the common gameplay primitive intended to support purchases, rewards, crafting, quest completion and safe retries independently of queue delivery.

### 18.1 Proposed API

```lua
local result, status = record:TransactAsync(
    "reward:daily:2026-10-17",
    function(current_data)
        -- Pure, deterministic, non-yielding transformation.
        local next_data = copy_data(current_data)
        next_data.coins += 100
        next_data.last_daily_reward = "2026-10-17"

        return next_data, { coins_granted = 100 }
    end,
    {
        request = { reward = "daily", day = "2026-10-17" },
        receipt_retention_seconds = 30 * 24 * 60 * 60,
    }
)
```

The name and exact parameter shape are provisional. A caller-supplied operation ID must remain stable across retries. The API canonicalizes and validates the request, compares the exact request identity stored with the receipt, and returns the prior stored result when the operation was already committed. Reusing the ID for a different request returns `conflict`, not a duplicate success.

### 18.2 Atomicity and in-memory coherence

The profile mutation, operation receipt and bounded serializable result must be written within the same profile-key UpdateAsync. Serialize the operation through the existing per-Record write gate; flush or reconcile pending local dirty state before starting; validate owner/session token and fencing generation in the transform; and rebase the in-memory snapshot after a confirmed commit. A failed or ambiguous prerequisite flush must stop the transaction instead of using stale memory.

The reducer may be invoked more than once by UpdateAsync. It must be deterministic for equal inputs, non-yielding and free from irreversible external effects. Prepare stable IDs and timestamps before entering the transform. Consumer callbacks cannot be made safe merely by wrapping them in pcall; the contract and adversarial tests must make this limitation explicit.

### 18.3 Receipt capacity and result semantics

Define typed outcomes for `committed`, `duplicate`, `conflict`, `capacity`, `fenced`, `retryable` and `unknown`. On `unknown`, the same operation ID resolves uncertainty; a new ID does not. If the operation receipt cannot fit, abort before committing the mutation. Do not evict the oldest receipt silently.

The operation receipt includes a versioned canonical request identity, operation result (within a strict encoded-size cap), committed profile revision and timestamp. Large results must be represented by a stable reference or compact summary. Receipt retention is part of the public guarantee: after expiration, old retries may execute again unless a domain ledger continues to enforce uniqueness. Applications that require lifetime idempotency must keep the required domain key for life or use a bounded business model that proves safe compaction.

### 18.4 Relationship to inbox/outbox

Share the internal mutation/receipt engine with `ApplyInboxAsync` where the contracts truly match, but preserve distinct API semantics and error codes. Inbox IDs identify delivered messages; transaction IDs identify caller-defined business operations. Do not fake queue envelopes for direct transactions or create separate receipt keys that introduce a dual-write gap.

## 19. Crash-safe application schema migration engine

**Status: design proposal only.** The application data schema is distinct from the RecordStore serialization-envelope version and from the mailbox protocol version.

### 19.1 Version model and migration registration

Add an explicit application `data_schema_version` in the profile envelope and a registry of ordered migration steps, each with a stable migration ID, source version, target version, declared compatibility range and validation function. Migrations must not be inferred from missing fields alone.

Proposed API concepts:

- `RecordStore.register_migration(store_name, from_version, to_version, migration_id, migrate, validate)`;
- `Record:MigrateAsync(target_schema_version, options)`;
- `RecordStore.preview_migration_async(store_name, scope, profile_key, target_schema_version)`;
- `RecordStore.get_migration_status_async(operation_id)`.

The exact API is not fixed. Migration registration must reject duplicate IDs with different declared implementation revisions/digests, gaps, cycles, unsupported backwards edges, and ambiguous paths to the requested target. Do not attempt to fingerprint arbitrary Luau closures at runtime; bind a stable revision or source/build digest in a checked-in manifest or immutable registration metadata, and treat changed migration code as a new declared revision.

### 19.2 Execution and recovery

- Run a bounded, deterministic, non-yielding transformation against the latest durable profile envelope while holding the Record write gate and validating current session ownership.
- Commit the migrated data and new schema version in the same profile-key UpdateAsync. An interrupted/unknown result must be reconciled by rereading the stored schema version and migration ID; do not run a second incompatible migration from stale memory.
- Each migration is idempotent or atomic at one profile key. A migration that cannot fit normal transform time/size limits must use an explicit staged protocol and remain unavailable to gameplay until the target version is validated and activated.
- Preserve the original data version through Roblox version history where available and/or a separately verified backup process. A backup written to another key is not atomic with the profile update and needs its own recovery protocol.
- Failed validation moves the profile into a visible read-only/quarantined state. Preserve the original source; do not replace malformed or future-version data with a template or guessed structure.
- Dry-run previews operate on a read-only copy and report path-level changes, estimated encoded size, validation failures and unsupported fields without opening a write transaction.
- Large migrations are scheduled with bounded concurrency and low priority, but cannot be starved indefinitely or bypass the profile's session fence.
- Old binaries encountering an unsupported future `data_schema_version` fail closed. Compatibility checks must cover overlapping deployments and rollback, not just current-version tests.

### 19.3 Operational controls

Support canary migrations in a disposable namespace, per-store activation gates, progress summaries, retryable failure categories, explicit operator pause/resume and migration audit IDs. Reversing a migration requires a separately declared inverse or verified restore; the library must not synthesize inverse code for arbitrary transformations.

The data envelope version remains independent. Upgrading a serializer must not automatically migrate game inventory/economy semantics, and changing a game's schema must not require an unrelated mailbox-format rewrite.

## 20. Escrow-based transfer and trade engine

**Status: design proposal only.** This is an optional domain-level helper built on transactions, outbox/inbox and saga recovery. It does not create a multi-key database transaction.

### 20.1 Transfer state machine

Propose an opt-in `RecordStoreTransfer` coordinator with a caller-stable transfer ID and explicit durable states:

`requested -> reserved -> credit_pending -> credited -> settled`

Terminal/exception states include `rejected`, `expired_before_reservation`, `compensation_pending` and `reconciliation_required`. The transfer record tracks source/target identity, amount or item manifest, schema version, source and target operation receipts, deadlines, retry count and the last verified step. Sensitive account fields should be minimal and owner-scoped.

### 20.2 Conservation invariant

1. In one transaction on the sender's profile key, validate available assets, move the amount from spendable balance into a reserved escrow field, and record the stable transfer ID.
2. Apply the destination credit on the destination profile key through an idempotent inbox/transaction operation keyed by the transfer ID. Duplicate attempts cannot credit twice.
3. After a verified destination receipt, settle the source reservation. A stale or repeated coordinator step is idempotent.
4. If a destination result is unknown, reconcile/retry the same operation before any compensation. Never release the source escrow while the destination credit may still commit.
5. When the operation cannot safely converge, keep assets reserved and expose `reconciliation_required`; provide an operator workflow with auditable, fenced decisions.

The invariant is conservation across spendable balances plus escrow and committed destination assets. For items, reserve a versioned item identity/count and reject mutation of the reserved item until settlement. Currency precision, negative values, overflow, duplicate item identifiers and schema changes must be validated.

The sender reservation and recipient credit live on separate DataStore keys, so temporary pending states are expected. The design must not promise instantaneous all-or-nothing visibility, exactly-once arbitrary effects, or atomic cross-profile commit. A user-facing UI should expose pending status where relevant. Compensation is a separate business operation, not a blind reversal of an uncertain write.

## 21. Profile Doctor and guarded restoration

**Status: design proposal only.** This is an operator-facing diagnostic workflow. Its default mode is strictly read-only.

### 21.1 Inspection

Propose read-only tools such as:

- `RecordStore.inspect_profile_async(...)` for envelope/data-schema classification and validated size/count summaries;
- `RecordStore.diff_profile_versions_async(...)` for bounded path-level differences between the current record and supported historical versions;
- `RecordStore.preview_repair_async(...)` for a proposed repair without committing it;
- `RecordStore.restore_profile_version_async(...)` for an explicit, guarded restore.

Inspection reports distinguish confirmed parse failures from unsupported future formats, missing data, owner/session mismatches, failed migrations, missing sidecars, size-limit risk and inconclusive reads. Diffs are bounded by node count and encoded bytes; truncation is explicit. Redact personal/sensitive values by default, with path names and hashes preferred to raw content.

### 21.2 Repair and restoration protocol

- Never auto-reconcile malformed, future-version or owner-mismatched data into the current template.
- Require a named repair rule with a stable ID, input schema range, preview, validation and expected current revision. Generic arbitrary table edits are not a safe repair language.
- Before a write, recheck owner, session/fencing token and expected revision in UpdateAsync. If the source changed after preview, return a conflict and require a new preview.
- Preserve a verifiable recovery point before destructive repair. Document whether protection relies on DataStore version history or a separately verified backup; never describe a non-atomic second-key backup as atomic with the restore.
- Store repair audit identity, operator reason, before/after revision and outcome. Avoid storing raw full snapshots in an unbounded audit log.
- A restore is a new guarded write based on an historical snapshot; it must not erase current session locks, fencing generations, inbox/outbox receipts or unknown sidecars. Merge/restore data fields separately from protocol metadata. It must also honor any applicable erasure tombstone; historical restore, rollback or projection rebuild must not resurrect data already erased under the active retention policy.
- Require explicit confirmation in the operator layer for destructive operations. The library can provide the guardrails/API, but it cannot provide a secure admin UI or authorization model automatically.

ProfileStore already provides historical reads/version queries. The differentiator here is safe diagnosis, bounded comparison, preview and guarded restoration rather than version history alone.

## 22. User-data erasure and retention coordinator

**Status: design proposal only.** This feature must complement Roblox's automated Right to Be Forgotten (RTBF) mechanisms, not claim to replace them.

### 22.1 Data inventory and ownership

Every persistent RecordStore data family must declare whether it can contain data associated with a Roblox user, the owner/subject identity, retention class and deletion strategy. Profile data, queue messages, inbox/outbox receipts, saga records, purchase intents, indexes and diagnostic traces must not be omitted simply because they live in sidecar stores.

The existing hashed route-key proposal creates a material compatibility risk: a UserId stored only inside an opaque hashed value is not discoverable by a key-pattern RTBF template. Roblox's current automated RTBF contract requires the UserId to appear in the DataStore name, scope or key through a static pattern, and supports at most 100 templates. A UserId stored only in the value or metadata is not sufficient. **Before the v2 layout can claim RTBF coverage, every user-associated key family must be directly matchable by tested templates or the feature must remain blocked from any complete-coverage claim.** An application-side deletion manifest can supplement manual erasure/reconciliation, but it does not make a hidden key match Roblox's automated templates. Do not ship a compliance guarantee based only on scanning a DataStore keyspace or relying on a manifest that automated RTBF may itself delete before the application consumes it.

Where appropriate, require an explicit `subject_user_id` for data associated with a player. Ensure key length remains within Roblox limits, use full stored owner identity checks, and keep collision fail-closed validation when route hashes are shortened to make room for a user route component. For shared/multi-user operations, minimize personal data, split user-specific payloads/receipts into individually erasable records, and keep shared coordinator state free of unnecessary identifying data. Do not promise that one owner-prefixed key handles automatic erasure for every participant.

### 22.2 Resumable erasure protocol

Propose `RecordStore.plan_erasure_async(user_id)`, `RecordStore.execute_erasure_async(erasure_id)` and `RecordStore.get_erasure_status_async(erasure_id)`. The plan is read-only and returns the discovered key families, counts/uncertainties and retention exceptions before execution. The actual operation is resumable, idempotent and bounded.

- Use a documented user-to-record inventory or matchable key layouts. Never enumerate an entire DataStore keyspace on a request path.
- Stop or fence new application writes that would recreate data covered by the request; coordinate with active sessions and old writers.
- Delete or redact eligible sidecar records and verify every operation. Unknown outcomes are reconciled before reporting completion.
- Preserve non-personal shared workflow state only when its schema can be safely redacted and policy permits. A mixed payload must not retain personal information merely because another participant still needs the transaction.
- Respect legal/platform retention exceptions and minimum required audit data; explain what was deleted versus retained and why.
- Include DataStore historical versions, backups, repair snapshots and projection/replay sources in the erasure inventory. Confirm the platform's version-history behavior rather than assuming current-key deletion erases every recoverable historical copy. An erasure tombstone must fence later profile restore, migration, projection rebuild and replay from resurrecting erased personal data.
- Apply the same policy to local traces, cached copies, memory hints and indexes. Ephemeral caches are invalidated; metrics must not retain identifiers after deletion.
- Use Roblox RTBF templates for automatic platform deletion and test every configured data-store/key pattern against representative UserIds. RecordStore's own coordinator remains useful for application-initiated cleanup, audit and sidecar reconciliation but cannot assume it will receive a callback when Roblox runs automated RTBF.

### 22.3 Acceptance gate

No RTBF-completeness claim until there is a machine-verifiable inventory for each persistent family, a test that renders all configured templates, tests for both one-user and shared/multi-user workflows, and a recovery procedure for partial deletion. Unidentified legacy sidecars must be reported as an explicit unresolved scope, not silently treated as erased.

## 23. Deterministic crash simulator and state-machine verifier

**Status: proposed test infrastructure; production RecordStore semantics remain unchanged.**

Extend the fake DataStore used by section 12 to include a deterministic scheduler and replayable fault script. A test case is defined by initial state, operations, event ordering, injected failures and expected invariants. It must execute the real production-path persistence code through an adapter, not only test a separate model that reimplements the algorithm.

### 23.1 Required simulator controls

- Explicit virtual time and clock sources for server A/server B, including bounded and extreme clock skew.
- Per-key atomic UpdateAsync behavior with configurable transform retries, commit-before-error, fail-before-commit, request throttling and budget recovery.
- Deterministic scheduling of concurrent tasks, interrupted/yielding handlers, shutdown and reconnect.
- Crash cutpoints after every durable protocol transition. Restarting a simulated server discards its local memory and reconstructs state from durable storage.
- MessagingService and MemoryStore stubs that can drop, duplicate, reorder, delay, expire or throttle all hints.
- Stable random seeds and serialized fault scripts so any failure can be reproduced exactly.
- Trace capture that identifies the operation, key family, expected state, actual state and first invariant violation without dumping raw user data.
- Model-based assertions for message at-least-once delivery, no duplicate inbox mutation, stale-claim fencing, transaction idempotency, migration safety, escrow conservation and index rebuild correctness.

### 23.2 Verification layers

Keep the abstract state-machine model independent enough to catch implementation mistakes rather than copying its logic. Run property-based sequences at small scale and curated deterministic scenarios for important failure windows. Minimize a failing sequence to the shortest reproducible trace.

The simulator is necessary but not sufficient. Add real Studio/server contract tests for APIs whose behavior depends on Roblox DataStore throttling, platform receipt callbacks, version history or cross-server timing. Performance results from a fake service must not be presented as real Roblox service latency.

## 24. Durable secondary indexes and materialized views

**Status: design proposal only.** This is an opt-in projection system for query patterns that do not fit direct profile-key access.

### 24.1 API and architecture

Propose named, versioned projections with an input event schema, deterministic projector, partition/shard layout, unique entry identity, source revision or event cursor, and rebuild strategy. Example application queries include guild membership, ownership lookup, marketplace listings and player-to-group membership.

Updates are driven from a transactional outbox or another durable change stream. Each projection update is idempotent by source operation/event ID and records progress so a restart can safely replay. Use bounded shards; never funnel every player through one global hot index key. If a projection requires pagination, expose bounded page size and cursor semantics rather than materializing every result.

### 24.2 Consistency and recovery contract

- Materialized views are explicitly eventually consistent and may be stale or incomplete. A sensitive trade/permission/economy operation must validate the authoritative profile/transaction state before committing.
- Projection updates never run inside a profile UpdateAsync transform. They are a downstream consumer with retry/DLQ handling and idempotent offsets.
- Deleting a projection row is not proof that its authoritative source data was deleted; rebuild/replay must also respect erasure and retention state.
- Rebuild from a bounded source of durable events or a declared snapshot-and-cursor protocol. If the source history has expired, return an explicit incomplete rebuild result rather than claim correctness.
- Unique constraints need durable arbitration, not merely checking the local in-memory index before inserting.
- Index schema migration uses versioned projections and dual-read/dual-write only where the cutover protocol, deduplication and rollback have been tested. Never silently read an index built from an incompatible projection version.

Use a view only when query value outweighs additional writes, storage, eventual consistency and rebuild complexity. RecordStore should not become a general-purpose search database by default.

## 25. End-to-end operation tracing

**Status: design proposal only.** Extend section 10's bounded stats and message transition history to correlate a business operation across profile persistence, queues, outbox/inbox and workflow steps.

### 25.1 Trace model

A trace event may include stable `operation_id`, correlation/causation IDs, component and protocol version, operation type, bounded state transition, attempt number, duration bucket, result category, record revision and timestamp. Provide `RecordStore.get_operation_trace_async(operation_id)` with a paginated/truncated result and a completeness label.

Trace data should answer where an operation is waiting, what durable step was last confirmed, which retry class occurred, and what can safely be retried. Distinguish verified durable transitions from process-local events and unknown outcomes.

### 25.2 Overhead and privacy

- Do not issue a separate DataStore write for every trace event on a hot path. Append protocol state/transition evidence to an already-required durable envelope update where size and semantics permit, and keep optional high-volume spans in a bounded server-local ring buffer or external sink.
- Sample successful high-frequency operations when needed, but always retain high-value failure/unknown/corruption diagnostics within configured bounds.
- Trace storage has independent size and retention limits; truncation is explicit. Never allow tracing to make a profile or accepted message unsavable.
- Redact payloads, credentials, purchase identifiers and personal data by default. Access control for a remote diagnostics UI is the game's responsibility.
- Correlation IDs are not authority tokens and do not replace claim tokens, session fencing or receipt identity.
- A trace assembled from several keys is not a linearizable snapshot; include observed time and missing-step warnings.

## 26. Additional performance engineering roadmap

**Status: hypotheses to measure, not promised optimizations.** Every item requires a baseline, an isolated implementation, correctness regression tests, and a fresh CodSpeed comparison. Roblox DataStore UpdateAsync consumes both read and write budget and is slower than SetAsync because it reads before writing; this makes unnecessary request reduction important, but not every local CPU optimization reduces service latency.

### 26.1 No-op save elimination and dirty-generation tracking

Maintain an explicit mutation/dirty generation from RecordStore-owned mutation APIs. A save can be skipped when the generation has not changed since the last verified durable revision and no session/lease/protocol refresh is due. Do not deep-compare an entire large profile on every autosave just to prove equality. If compatibility permits direct mutable table access, no-op elision must be disabled or guarded for that access path; silently skipping an untracked mutation is a data-loss bug.

Test direct and nested updates, repeated assignment of equal values, reverted mutations, uncertain saves and ownership refresh. Measure UpdateAsync calls saved per session-hour and the additional CPU/memory cost of tracking dirty state.

### 26.2 Deadline-aware autosave scheduling and startup jitter

Replace synchronized per-Record timers with one bounded per-server scheduler that tracks dirty age, last durable save, configured maximum dirty interval, session/lease deadlines and shutdown urgency. Add bounded random/deterministic jitter to routine autosaves and startup maintenance so a cohort of players does not trigger writes at the same instant. Jitter must never exceed the durability target or overlap an unsafe lease deadline.

Routine saves, explicit high-priority transactions, session release and critical recovery use priority classes with weighted fairness. A low-priority queue cannot occupy every slot. Make delay and starvation visible; urgent work preempts by scheduling, not by cancelling an UpdateAsync that may still commit.

### 26.3 Separate read/write budget gates with a critical reserve

Use the shared governor to track Read, Write and, where needed, List/Remove request classes separately because an UpdateAsync consumes both read and write budget. Reserve a configurable fraction of RecordStore's internal concurrency for critical profile save/release and durable transaction work, while bounding queue, index rebuild, erasure and maintenance traffic. Do not assume engine request budgets are reserved exclusively for RecordStore; unrelated scripts and Open Cloud activity can consume shared experience budget.

Never automatically alter DataStoreService's engine-level rate limits as a library optimization. The governor controls RecordStore's own admission/concurrency and backs off on actual throttling even when the local budget snapshot looks healthy.

### 26.4 Safe in-flight read coalescing

For explicitly read-only operations whose cache/freshness contract allows sharing, coalesce identical in-flight requests on the same server by full datastore name, effective scope, key and requested version. When the request completes, independent callers receive independent safe snapshots. Clean up the in-flight entry on success, error, timeout and shutdown; never retain a failed promise forever.

Do not coalesce session acquisition, owner fencing, claim acquisition, mutation transactions or any call whose semantics require a fresh UpdateAsync. Read coalescing is an optimization only: cache and stale reads never prove session ownership or authorization.

### 26.5 One-pass codec and serialization work

Profile encode/decode and cloning before changing them. Where evidence supports it, combine validation, canonical size accounting and deterministic encoding into one traversal rather than cloning/encoding/measuring the same structure multiple times. Cache encoded or hashed fragments only for provably immutable/unchanged subtrees, with explicit invalidation and schema-version keys. Keep special-value sidecars and envelope migrations compatible.

A canonical codec change requires versioned test vectors for nested maps/arrays, exact numbers, special values, key-order permutations and near-limit payloads. Do not trade deterministic request fingerprints or strict validation for speed. Reusable tables/buffers must not leak mutable references across Records.

### 26.6 Threshold-based compact encoding or compression

Benchmark optional compact encoding/compression for large profiles and outbox payloads. Activate only above a measured size threshold where saved serialization/throughput cost outweighs CPU time, allocations and historical-read complexity. Include codec/version markers, integrity checks, decompression bounds and a supported raw fallback. Never compress twice, and never treat compressed opaque bytes as a reason to skip schema validation.

Compression remains off by default until representative workloads show a durable size benefit and acceptable CPU/p95 latency. Verify compatibility with historical versions, backups, inspection tools and migrations; future/unknown codecs must fail closed while preserving the source.

### 26.7 Per-profile mutation coalescing without semantic merging

Continue coalescing ordinary local mutations into one pending snapshot write where the public API already defines them as changes to the same in-memory Record. Add a bounded flush window and maximum dirty-age guard so rapid updates can share a save without allowing unbounded loss exposure. An explicit `TransactAsync` or `ApplyInboxBatchAsync` remains its own atomic transaction boundary: the optimizer must not merge distinct caller transactions, reorder same-key operations or change all-or-none semantics.

Measure writes per logical mutation, p50/p95 save wait and maximum dirty duration. Under capacity pressure, report backpressure/unknown explicitly rather than silently dropping a mutation from the coalescing buffer.

### 26.8 Payload sizing and large-record decision support

Record encoded bytes, clone/encode CPU and high-water profile sizes using bounded, low-overhead diagnostics. Warn before a profile approaches a configured serialization or API limit; do not wait for a production save to fail. Use size thresholds for expensive diagnostics and sample successes while retaining failure summaries.

Do not automatically split one profile into several authoritative keys just because it grows. Splitting changes atomicity, migration and recovery semantics. If a large high-churn subdomain needs its own record, make it an explicit application data-model choice with a documented consistency boundary and transfer/recovery plan.

### 26.9 Queue scan cost controls

In addition to the section 8 candidate cache and sharded wakeups, benchmark bounded scan cursors, stale-index filtering cost, polling backoff by oldest eligible age, and request-budget-aware page sizes. Cache entries may reduce duplicate discovery reads but cannot authorize claim or suppress reconciliation indefinitely. Keep index repair and compaction in low-priority bounded slices. A queue with no eligible messages should not scan at the same frequency as one with an old due message, subject to a strict maximum idle-poll interval.

Compare polling-only, hint-assisted and cache-assisted modes under dropped notifications, high backlog, DLQ growth and hot-owner workloads. Include request count and scan amplification, not latency alone.

### 26.10 Memory and allocation budget

Measure peak memory and allocation pressure for large profiles, queued payloads, traces, migration diffs and batch buffers. Put explicit caps on local candidate caches, trace rings, diff output, pending batches and workflow inspection pages. Release references on completion, cancellation and shutdown. Never evict active authoritative session data or an accepted durable intent to satisfy an optimization budget.

Avoid pooling mutable user-data tables unless ownership and lifetime can be proven. A small reduction in allocations does not justify aliasing bugs or cross-record data contamination.

### 26.11 Benchmark matrix and acceptance policy

Add dedicated CodSpeed scenarios for:

- clean save/no-op save versus dirty save;
- 1/10/100 concurrent Record sessions with jittered autosaves and mixed critical work;
- same-key repeated read coalescing versus independent reads;
- small/medium/near-limit payload encode, decode, clone and validation;
- codec/compression thresholds across payload size and table shape;
- bursty mutation coalescing at several rates, with maximum dirty-age assertions;
- queue scan at empty/low/high backlog, stale-index ratio, DLQ size and dropped hint rates;
- preparation-registry shard skew, active reservation caps, duplicate retry contention and recovery/cleanup request amplification;
- inbox batch sizes 1/4/8/16 only for callers that explicitly opted into atomic batching;
- outbox fan-out, grouped cleanup, migration, erasure and index rebuild under bounded concurrency;
- peak memory/allocation and worst-case trace/diff truncation.

Track CPU simulation separately from wall-time. Simulation is useful for Luau compute but does not model real Roblox DataStore throttling or network latency. Use wall-time through CodSpeed for applicable measurements and consistent runners; then validate request budgets, payload sizes, throttling and cross-server behavior in Studio/live test namespaces. Report request count per logical operation, encoded bytes, CPU/allocation metrics, throughput, p50/p95 latency, oldest work age, budget headroom and failure recovery. Never translate mock service speed into a claim about real DataStore latency.

Adopt an optimization only when a comparable baseline and head run show a repeatable material improvement in its target workload (initial decision threshold: greater than 5%) without correctness failures or unacceptable regressions in adjacent workloads. If the signal is below measurement noise or only helps simulation while harming wall-time, leave the simpler implementation. Every optimization is independently switchable where practical, and disabling it must not alter persisted semantics.

### 26.12 Explicitly rejected performance shortcuts

Do not: reduce lease/fencing safety to save requests; skip canonical request comparison after a hash match; move a receipt to a second key without recovery protocol; batch distinct business transactions implicitly; let MemoryStore/MessagingService become truth; remove old-version support to speed up decode without a migration plan; run unbounded concurrent UpdateAsync calls; use an unlimited in-memory pending queue; scan the entire keyspace to recover one missing entry; or change correctness defaults based on a benchmark-only profile.


## 27. Priority design roadmap with paired performance work

**Purpose:** turn the broad proposal into an orderable implementation plan. These are priority recommendations, not claims that the features are already implemented. Performance work is paired with the relevant correctness feature, but correctness acceptance is a prerequisite to performance optimization.

### 27.1 Priority tiers

| Tier | Design focus | Why this tier comes first | Paired performance work | Exit gate |
| --- | --- | --- | --- | --- |
| **P0 — correctness floor** | Deterministic crash simulator; unified operation outcome/error model; `TransactAsync`; dirty-generation tracking; maximum dirty-age and durability-risk reporting; explicit degraded-mode/backpressure policy | All advanced capabilities depend on reliable retries, observable uncertainty and bounded unsaved state. | Baseline dirty/clean saves, serialization CPU, request count, save latency and scheduler fairness before tuning. | Crash-window tests pass; no false durable-success results; buffered memory is bounded; stale workers are fenced. |
| **P0 — session/data safety** | Write-gate invariants, migration/future-version fencing, Profile Doctor read-only diagnosis and revision-checked restore | A corrupted record or a stale writer can defeat every later feature. | One-pass validation/codec work only after recovery behavior is characterized; bounded diagnostics avoid large allocations on hot paths. | Mixed-version tests, old-writer rejection, recovery preservation and revision-race tests pass. |
| **P1 — high-value gameplay** | Purchase receipt processor, escrow transfer/trade engine, transaction result query, stable operation IDs | Solves common high-impact economy problems while reusing the P0 transaction and simulator foundations. | Receipt lookup coalescing only for read-only status; batch independent downstream fan-out only when the caller opts into transaction boundaries. | Duplicate receipt, uncertain write, concurrent sender and destination-late-commit tests pass; conservation holds. |
| **P1 — operating safety** | Session contention observer, operation trace, bounded retention/maintenance runner, explicit queue/profile health contracts | Reduces time to diagnose stuck sessions and growing backlogs, while preventing maintenance from competing with critical saves. | Fair scheduler, separate read/write gates, background work cursors, bounded trace buffers and retention batch sizes. | Critical save/release cannot starve; diagnostics declare completeness and do not authorize writes/purges. |
| **P1/P2 — data lifecycle** | Schema migration automation, user-data erasure, safe restoration; every data family gets an owner/retention/deletion strategy | These are necessary for long-lived production deployments, but they must wait for migration compatibility and data inventory. | Low-priority bounded migration/erasure slices, size-aware batches, coalesced progress summaries and resumable cursors. | RTBF templates/inventory cover every applicable sidecar; partial runs resume safely; old versions fail closed. |
| **P2 — read/query scale** | Durable secondary indexes and materialized views | High value when the game actually needs cross-profile queries, but they add write amplification and eventual-consistency complexity. | Outbox-fed projections, sharded indexes, bounded replay/compaction and read coalescing only where freshness semantics permit. | Rebuild from declared authoritative history, handle duplicate/out-of-order events, and revalidate sensitive actions against source state. |
| **P2 — codec and throughput tuning** | Compact encoding/compression, more aggressive coalescing, cache tuning and advanced queue scan optimization | These can create compatibility costs and are not automatically beneficial for DataStore-bound workloads. | CodSpeed simulation for Luau CPU, wall-time for I/O where comparable, and actual Studio/service-budget tests. | Measurable workload-specific benefit, preserved historical decoding and no correctness/default-semantic change. |

P0 means a prerequisite for safe implementation of downstream features, not that every proposed API must launch publicly in the first release. P1/P2 are gated by observed application value; do not ship a generic projection or compression subsystem solely because it appears sophisticated.

### 27.2 Additional P0/P1 designs

The following are additional designs beyond sections 17–26. They close practical gaps between safe algorithms and an operationally usable persistence library.

#### A. Durability SLO and unsaved-data risk API — P0

Expose a bounded, explicit answer to: "How much local state is currently dirty, how old is the oldest mutation, and when was this Record last durably confirmed?"

Proposed fields for `Record:GetDurabilityStatus()` and server-level `RecordStore.get_health_snapshot()`:

- Record state and last confirmed durable revision;
- dirty generation and durable generation, when the API can track them reliably;
- oldest dirty age, last successful persistence time and next due save deadline;
- in-flight operation count, retry category and whether a write outcome is uncertain;
- maximum configured dirty age and whether it has been exceeded;
- whether values are exact, estimated or unavailable, with observation time.

Provide a signal such as `OnDurabilityRisk` when thresholds are crossed or an uncertain write remains unresolved. Signals must be edge-triggered/coalesced and bounded; they must not fire once per heartbeat or require a DataStore write each time. Do not label an in-memory mutation as durable until the matching stored result/revision is verified.

Pair with deadline-aware autosave, bounded jitter, dirty-generation tracking and an internal critical-work reserve from section 26. The scheduler must keep attempting necessary persistence and expose failure; an SLO alert is not a substitute for saving. If direct mutable tables can bypass tracking, report dirty status as unknown or disable no-op-save elision for that access path rather than invent a clean state.

#### B. Unified typed persistence outcomes and retry classifier — P0

Define one documented outcome vocabulary across open/load/save/transaction/queue/migration/maintenance APIs. Preserve existing compatibility result codes where required, but let new APIs return a structured result with:

- `committed` / `loaded` / `created` / `duplicate` for confirmed durable outcomes;
- `fenced`, `conflict`, `invalid`, `unsupported_schema`, `capacity` and `cancelled` for known non-commit/business outcomes;
- `retryable` only when the previous attempt is known not to have committed;
- `unknown` when an attempt may have committed and must be reconciled by its stable operation ID;
- a stable error category, safe-to-retry hint, attempt count and optional retry-after/backoff suggestion.

The library must not map every exception to `retryable`, because a commit-then-error response can otherwise duplicate rewards or transfers. A classifier's guidance is advisory: the operation's idempotency contract and canonical durable record remain authoritative. Do not include raw player data, receipt tokens or full payloads in default error messages.

Pair with typed circuit breakers, bounded retry budgets, in-flight read coalescing only for read-only calls, and error-category metrics. These reduce retry amplification under an outage but must never turn an unknown commit into a presumed failure or swallow a required save/release error.

#### C. Explicit degraded-mode, admission and backpressure contract — P0

Define server/Record states such as `healthy`, `degraded`, `read_only` and `closing`, with explicit reasons and recovery transitions. The state machine reflects what the library knows; it must not infer that all experience storage is healthy from one local budget value.

When DataStore requests fail or dirty state exceeds configured limits, expose a policy chosen by the caller:

- `reject_noncritical`: reject new optional queue/maintenance/low-value operations before accepting a partial durable intent;
- `bounded_buffer`: permit a limited amount of local dirty work, with hard item/byte/age limits and a result that clearly says it is not yet durable;
- `read_only`: disallow mutations until an operator/application policy permits recovery.

Never silently fall back to an unbounded memory queue. Critical purchase receipts, accepted durable messages, and profile releases must follow their documented durable/unknown contract; a process-local buffer cannot justify acknowledging them as committed. On overflow, return backpressure rather than evicting accepted intent or acknowledging work that has not been durably recorded.

Pair with read/write budget admission, reserved critical concurrency, deadline-aware flush scheduling and per-owner fairness. Performance acceptance measures how gracefully the system sheds optional work while preserving critical persistence, not how many requests it can suppress by dropping data.

#### D. Session contention and takeover diagnostics — P1

Provide a bounded `RecordStore.get_session_status_async(...)` or session-wait result that distinguishes: no known competing session, competing session observed, wait/retry scheduled, cancellation requested, ownership acquired, and ownership fenced/lost. Include observed time and known source data only; do not reveal secrets or claim a globally current owner from a stale read.

For a waiting caller, report elapsed contention time and the next retry window/rationale when known. Provide cancellation and timeout without abandoning an ambiguous ownership write. Any takeover remains governed by the existing CAS/session-fencing rules, never by the diagnostic endpoint. Diagnostics cannot grant permission to force-steal a session.

Pair with jittered load retries, a fair bounded waiter scheduler, read-only coalescing of compatible status reads and per-key retry suppression. Measure acquisition latency and DataStore request amplification under many concurrent servers. Do not add periodic high-rate polling for every waiting player; use bounded intervals and a maximum retry cadence.

#### E. Resumable retention compactor and offline maintenance runner — P1

Create a shared maintenance runner for safe retention, index cleanup, migration backfills, erasure, projection rebuild and other bounded jobs. Each task declares a version, stable operation ID, key-family scope, page cursor, expected revision/generation, request budget, concurrency class, retention/deletion rule and resumable checkpoint.

The runner must:
- use bounded pages/item/byte/time limits and persist progress only at a well-defined safe checkpoint;
- revalidate canonical state, index references, live workflow/outbox dependencies and lease/fencing tokens before deletion;
- treat `RemoveAsync` as unconditional, not as a compare-and-set: first persist a tombstone/retired generation and ensure every writer rejects that generation, then physically remove only after references, leases and dependencies are retired. A read followed by `RemoveAsync` is not atomic;
- reconcile unknown delete/update results with an authoritative follow-up before advancing its cursor; never trust cached absence after an ambiguous delete;
- stop or yield when critical profile save/release work needs the scheduler;
- support dry-run counts, pause/resume, cancellation, per-family progress and an explicit incomplete result;
- never make a whole-keyspace scan part of a request path;
- never compact the only evidence that protects idempotency or future recovery;
- preserve a recovery source until a migration/compaction's result has been verified.

Pair with cursor-based incremental scans, sharded maintenance lanes, bounded cleanup batches, backpressure and a budget-aware scheduler. Track bytes/keys processed, request count per item, oldest maintenance age and impact on critical-save latency. Faster cleanup is unacceptable if it can delete an item still referenced by an active index or pending transfer.

### 27.3 Non-negotiable implementation order

1. Lock down the state/outcome contracts and build the production-path deterministic fault simulator.
2. Implement transaction receipts, dirty-generation durability tracking, and the degraded/backpressure policy with bounded scheduling.
3. Prove migration, session fencing, Profile Doctor preview/restore and legacy compatibility.
4. Build receipt handling and escrow transfers using the tested transaction/workflow primitives.
5. Add session diagnostics, traces and the maintenance runner; then do RTBF coverage before claiming complete erasure support.
6. Add projections and advanced codec/caching optimizations only for measured use cases.

This is a dependency order, not a promise to release everything as one monolithic subsystem. Keep each public feature independently gated wherever compatibility allows.

### 27.4 Priority-specific acceptance gates

- Dirty age, last durable revision and uncertain writes are distinguishable; no-op-save elision never infers a clean Record from incomplete mutation tracking.
- Every API's retry classification distinguishes confirmed non-commit from unknown commit. Tests inject commit-then-error at each supported write boundary.
- A full local dirty buffer or maintenance queue returns visible capacity/backpressure; no accepted durable intent is silently evicted.
- The critical scheduler reserve prevents queue/maintenance saturation from indefinitely blocking final profile saves/releases under the tested workload.
- Session wait diagnostics cannot grant ownership, force takeover or override the fenced state machine.
- Compaction/maintenance resumes after crashes, never skips a page whose previous result is unknown, and never removes evidence required by a live workflow or advertised idempotency guarantee.
- Each new P0/P1 feature has a focused benchmark paired with the correctness suite; the performance optimization remains off unless its target workload and adjacent critical-save workloads meet the measurement gate.


## 28. Priority-aware scheduling design: messages, work lanes and server priority

**Decision:** add opt-in, bounded **message priority** and formalize **server-local work-class priority**. Do not add a global or per-instance **server-priority** ranking to the core protocol.

Priority changes scheduling preference only. It never changes whether a message is durable, whether its claim is valid, whether a reducer is allowed to run, whether an acknowledgement committed, or how session fencing works. Priorities cannot turn at-least-once delivery into exactly-once execution.

### 28.1 Three distinct priority concepts

Keep these mechanisms separate:

1. **Message priority** selects which eligible messages should be attempted first within the same owner mailbox, subject to ordering constraints. This is an opt-in queue feature.
2. **Server-local work-class priority** decides how one server's shared governor schedules critical profile saves/releases, transactions, queue work, outbox dispatch, and maintenance. The existing shared governor owns this policy.
3. **Server-instance priority** would rank one Roblox game server above other server instances in a global scheduler. **This is not needed for the initial or default RecordStore design.** A server's configured role/profile may influence its own local work mix, but must not create a global lease-owner ranking or allow one server to steal another server's jobs.

The local request budget is reported by `DataStoreService:GetRequestBudgetForRequestType()`; Roblox also applies shared service limits, and the server-local governor cannot infer total experience-wide demand from its own budget snapshot. MessagingService delivery is best-effort. A globally coordinated server-priority system would therefore need its own cross-server authority, contention control, stale-member handling and failure recovery, adding request cost and new failure modes without strengthening durable delivery. Do not build that coordinator unless a measured application requirement demonstrates the need.

### 28.2 Message priority contract

Propose a bounded, opt-in `priority` option for the existing enqueue options. Names and exact tiers remain provisional; an initial implementation should use a small fixed enum such as:

- `high`: time-sensitive gameplay work with a justified server-side use case;
- `normal`: default business/gameplay work;
- `background`: maintenance or deferrable work.

Do not use arbitrary integers, untrusted client-supplied priority, or unlimited priority names in the durable protocol. Map caller-visible values to a small versioned enum. Default old calls and migrated messages to `normal`. A caller may set priority only through server-authoritative code; it cannot bypass payload validation, owner checking, idempotency, capacity or authorization.

Store the selected priority on the canonical message record. A segment/index row may copy a priority bucket as an acceleration hint, but the canonical record remains authoritative. The worker revalidates canonical state and placement generation before claiming. A stale priority hint may waste a read but cannot authorize or suppress a valid message indefinitely.

Priority is immutable after acceptance in the first iteration. If later requirements justify reprioritization, provide an explicit `ReprioritizeAsync(message_id, new_priority, operation_id)` with a CAS check on current state and placement generation, an idempotent operation ID, a new index placement generation, and stale-row filtering. Do not edit a message's priority in place while an index row is assumed to remain current.

A delivery receipt exposes priority, enqueue time, eligible time, claim state and an optional bounded wait/age estimate. The estimate is observational only; it is not a deadline guarantee. `expires_at`, retries, attempts and retention remain separate from priority. Do not raise priority automatically just because a message retries repeatedly; repeated failures may represent poison work and should trigger retry classification/circuit-breaker/DLQ policy, not monopolize execution.

### 28.3 Ordering and fairness are mandatory

Priority must never silently reorder work that the application declared ordered.

- If messages share an `ordering_key`, preserve the documented order within that key. A later high-priority message cannot jump ahead of an earlier eligible message on the same key unless the caller explicitly opted into a different ordering contract.
- Without an ordering key, use priority to select among eligible messages only, not among preparing, claimed, delayed, expired or otherwise non-claimable records.
- Use weighted fair scheduling across priority lanes, with a maximum consecutive high-priority service budget and periodic service to normal/background lanes.
- Add bounded age-based promotion to prevent starvation: a background item waiting beyond a configured threshold can become eligible for the next lower-lane service opportunity. Aging only affects scheduler preference; it does not modify the canonical priority, expiry, retry schedule, lease or protocol state.
- Enforce per-owner/per-lane concurrency and admission caps so one profile cannot consume the entire server-local queue budget.
- A high-priority arrival may take the next available worker slot, but it must not pretend to cancel an in-flight DataStore request or interrupt a handler that has already started. Existing claim tokens, cooperative cancellation and profile-key session fencing continue to govern running work. The ordering contract applies only when the separately specified strict per-key feature is active; the initial v2 release rejects non-nil `ordering_key`.
- Under saturation, return explicit capacity/backpressure where appropriate. Do not silently discard background work or accepted messages to keep the high lane short.

The design must name the starvation bound as a configurable policy target and demonstrate it under sustained high-priority load. A weighted scheduler cannot promise a hard elapsed-time deadline when DataStore requests are throttled or unavailable.

### 28.4 Per-server work-class priorities

The shared governor should reserve internal concurrency for critical profile writes, session release/fencing and already-accepted transactions before servicing optional queue scans, outbox fan-out, projection rebuild, erasure, diagnostics and compaction. Within the non-critical reserve, use bounded weighted fairness rather than one global FIFO that lets maintenance block gameplay work.

Proposed work classes:

| Local work class | Scheduling treatment | Constraint |
| --- | --- | --- |
| Critical profile/session persistence | Reserved bounded capacity; highest local scheduling urgency | Never report success solely because the task received priority; durable result still must be verified |
| Explicit profile transactions and receipt settlement | High local preference, bounded concurrency | Idempotency and capacity gates remain mandatory |
| Eligible high-priority messages | Preferential queue lane, subject to ordering/fairness | Cannot starve normal work or override owner/claim checks |
| Normal messages and outbox delivery | Weighted normal service | Ordering and retries remain unchanged |
| Migration, erasure, index rebuild, trace export and compaction | Background slices; yield when critical work needs capacity | Progress must be resumable; maintenance may not purge unverified/live state |

These are scheduler preferences, not separate request budgets granted by Roblox. The governor must account for DataStore read/write costs of UpdateAsync, observe throttling and latency, and retain a fallback scheduler if priority tuning is disabled. Do not call `SetRateLimitForRequestType()` automatically to manufacture priority.

### 28.5 Is server-priority needed?

**No, not as a core cross-server feature.** Do not define `server_priority`, "master server", "leader server" or a permanent privileged JobId for mailbox work in the first release.

Reasons:

- Each server has its own request budget snapshot and contention conditions. A static global rank will not reveal whether that server currently has useful headroom.
- Durable message claiming is already arbitrated by canonical message state, CAS and fencing. A global priority lease owner would duplicate coordination without improving correctness.
- Server instances churn, can become unreachable, and can have stale membership/health views; rankings add discovery, expiry, election and takeover cases.
- Cross-server control messages are not a durable source of truth. A lost or delayed priority update must not block messages.
- A privileged worker can starve ordinary workers or make a single server a hot spot. Requiring a global coordinator can add a write to each dispatch decision, defeating the performance goal.

Use `server_role` / `runtime_profile` for **local policy intent only**. For example, a gameplay server may reserve more internal capacity for profile/session work; a background server may choose a lower queue concurrency. All servers may discover messages and assist with index/terminal-state recovery, but only the server holding the currently active target Record session may invoke that profile's handlers. A claim CAS on a separate message key is not proof of profile ownership. Do not make a background-role server the exclusive owner of queue recovery, because job termination would then delay discovery and maintenance.

A future cross-server worker-tier experiment is only justified if measurements show local fairness cannot meet the use case. It must be advisory, lease-fenced, TTL-bounded, shard-aware, independently disableable and backed by ordinary workers as fallback. It cannot affect whether a message is accepted or durable. Treat it as a separately reviewed design, not a priority flag on the core message schema.

### 28.6 Performance and benchmarks

Priority can reduce queueing delay for selected work but may increase scan/index cost and worsen tail latency for lower lanes. Benchmark it as a trade-off, not a global speedup.

Add CodSpeed/fault-simulator scenarios for:

- priority disabled versus enabled under identical input and runner settings;
- balanced low/normal/high mixes and a sustained high-priority flood;
- starvation age and p50/p95/p99 eligible-to-claim latency for every lane;
- one hot owner versus many owners, including per-owner caps and ordering keys;
- separate priority lanes versus a shared index with weighted selection;
- stale/misleading index priority hints, reprioritization CAS races and duplicate index rows;
- simultaneous critical saves/releases, inbox/outbox traffic and background maintenance;
- disabled/missing MessagingService hints and polling-only recovery;
- low request budgets, commit-then-error, lease expiry and handler failures with priority enabled.

Report both gains and regressions: request count per completed message, index scan amplification, queue wait by lane, oldest pending age, critical-save p95, service-budget headroom, throughput and starvation bound. Compare simulation CPU separately from wall-time and real Roblox service behavior. A priority scheduler is accepted only if target-lane latency improves under the stated workload, background work has a demonstrated anti-starvation bound, and critical persistence shows no unacceptable regression.

### 28.7 Rollout and compatibility

- First release: keep priority selection feature-gated/off by default, with all old/migrated messages mapped to `normal`.
- Validate encoded payload/index limits and migration compatibility before adding a duplicated index hint or a new priority lane.
- The first working priority implementation should prefer a small enum and bounded local scheduling state over a complicated cross-server priority registry.
- The normal poller remains able to discover and claim valid messages if priority caches or hints fail.
- Reprioritization, if approved later, requires a separate versioned operation and crash tests; it is not implied by the initial `priority` field.
- Disabling priority must preserve message identity, queue state, ordering contracts, retry/expiry semantics and accepted work.


## 29. Advanced scheduling designs with correctness and performance gates

This section extends the priority lanes in section 28. These are distinct scheduler algorithms and operating modes, not promises of lower latency. Add them incrementally; begin with mechanisms that protect durable work and budget fairness, then consider higher-complexity optimizations only when traces establish a bottleneck.

### 29.1 Cost-aware deficit round robin across owners and work classes

**Problem:** round-robin by item count is unfair when one scheduled item costs one read while another entails an UpdateAsync, a larger payload, several outbox destinations or a costly bounded handler. A hot profile can dominate request budgets despite receiving only the same number of turns as other profiles.

**Design:** use deficit round robin (DRR) over owner/work-class lanes. Each visit earns a bounded quantum of estimated work units; an item is selected only when its estimated cost fits the available deficit, with deficit carried forward to avoid permanently starving a larger but legal item. Use a multi-dimensional estimate where helpful, for example estimated StandardRead units, StandardWrite units, bytes/serialization work and handler concurrency slots. UpdateAsync commonly consumes both read and write budget, so do not price it as write-only.

Cost models come from instrumented operation classes and representative measurements, not payload claims supplied by callers. When estimates are absent or uncertain, use a conservative configured estimate. Keep hard caps for bytes, handler duration and concurrent operations so a single large item cannot monopolize memory or a worker. The estimate guides selection; the canonical protocol decides correctness and actual service budgets remain external constraints.

Pair with the shared governor's separate read/write admission, per-owner caps, critical persistence reserve and typed backpressure. Measure request units per completed operation, per-owner service share, large-item wait, head-of-line blocking and p95 critical-save latency. Reject this complexity if ordinary weighted fair scheduling gives equivalent results.

### 29.2 Deadline slack and age-aware service

**Problem:** strict FIFO can leave time-sensitive work waiting behind a large backlog, while pure priority can starve ordinary messages. A message expiry timestamp alone is not a scheduling policy and must not be turned into a hard completion promise.

**Design:** support optional server-authoritative `service_class`/SLO metadata separate from `expires_at`. Compute an observational slack estimate from deadline/SLO, current queue age and a conservative service-time estimate. Prefer eligible work with lower slack only within its allowed priority/ordering lane and under a bounded urgent-work budget. Promote old work using bounded aging so age eventually matters even when new urgent tasks keep arriving.

The scheduler must distinguish:
- `available_at`: earliest time at which work may be attempted;
- `expires_at`: deadline after which a handler must not newly start;
- service objective/deadline: an advisory scheduling target, not proof the DataStore or handler will finish by that time;
- claim lease expiry: ownership/fencing state, not message expiry or a service objective.

Never change one timestamp to impersonate another. If the work is already in-flight, do not cancel an UpdateAsync or claim completion has been prevented. When estimated slack is negative, return/emit an overdue status and apply the documented expire-or-process policy; do not silently discard it.

Pair with per-lane latency histograms, oldest eligible age, conservative tail-latency estimates and starvation monitoring. Benchmark eligible-to-claim p50/p95/p99, overdue count and background service share under stable and overloaded request budgets. Do not market a hard deadline guarantee from a best-effort scheduler.

### 29.3 Lease-renewal deadline lane

**Problem:** yielding handlers and long-running internal workflows can lose a claim when renewal waits behind ordinary scans, fan-out and maintenance. An expired claim must be recoverable, but avoidable expiry wastes work and increases duplicates.

**Design:** schedule renewal attempts by **remaining safe lease margin**, not merely the handler's static priority. Estimate the time needed for a renewal attempt using a conservative tail-latency value and local queue delay. Put renewals with low safety margin in a bounded urgent lane, with a reserved concurrency slot but a strict per-claim renewal cap. Renew only if the canonical message still has the same claim token and session generation. Stop renewing on cancellation, session loss or terminal state.

No scheduler can guarantee renewal while the service is unavailable. If the claim is already expired/replaced, renewal must fail the fencing check rather than resurrecting it. Do not renew forever for a stuck handler: use the declared handler deadline, cooperative cancellation and bounded renewal horizon. Renewal has no permission to extend message `expires_at`.

Pair with measurement of renewal lateness, expired-claim takeover rate, duplicate executions after lease loss, write amplification from renewals and critical profile save latency. Test under low budget and slow service responses as well as simulated fast CPU. The reserved slot is an internal scheduler reserve, not a Roblox-guaranteed DataStore quota.

### 29.4 Due-time wheel and delayed-work wake scheduler

**Problem:** polling and scanning records that are not yet eligible wastes requests and increases pressure as retry backlogs grow. Repeatedly scanning the same future `available_at` set does not move work closer to execution.

**Design:** use a bounded server-local min-heap/timing wheel to schedule next wake-ups for already-discovered messages and delayed retries. Bucket wakeups by time window, coalesce repeated owner wakeups and cap heap entries. Rebuild candidates from bounded durable index pages after restart. Persisted `available_at` and the canonical message record remain authoritative; the local wheel is disposable derived state.

A missing, dropped, expired or stale timer entry must never make accepted work permanently invisible. Keep a periodic reconciliation poll with a strict maximum idle-poll interval and a progress cursor. Under overload, coalesce timer events and scan only bounded pages, but never scan the entire DataStore keyspace to reconstruct one missed entry.

An optional durable due-time index may be considered later only if measurements show the local wheel and current segments are insufficient; it requires its own append/cleanup lifecycle and can increase request amplification. Do not add a second persistent write per message simply to avoid a bounded in-memory wakeup.

Pair with tests/benchmarks for empty queues, many delayed retries, bursty due-time cohorts, restart/rebuild, clock skew, dropped hints and stale timer entries. Track reads per eligible message, scans per idle hour, lateness after `available_at`, memory use and oldest eligible age. Keep wall-clock correctness based on the existing timestamp and skew-grace contract.

### 29.5 Adaptive batch-formation window with a latency ceiling

**Problem:** a fixed batch threshold may be efficient under a large backlog but impose needless latency at low traffic. Conversely, sending every item separately can amplify profile-envelope writes and destination calls.

**Design:** for APIs that already explicitly promise batch semantics, form a batch until the first of these limits is reached: item count, encoded bytes, service-budget headroom, or a configured maximum wait. Adjust within strict hard bounds based on backlog and oldest-item age. Low backlog uses a short window; high backlog may wait for more items only while every included operation remains within its own eligibility/deadline constraints.

Do not automatically merge separate business transactions into one all-or-none transaction. For `ApplyInboxBatchAsync`, the caller's explicit batch is the atomic unit; scheduler tuning can control when a caller-submitted batch runs but cannot silently expand it with unrelated messages. For outbox dispatch, batching may group independent destination submissions only where each event retains its own idempotent identity and outcome. A partial fan-out must be resumable per event.

Pair with CodSpeed batch sizes 1/4/8/16 and multiple wait windows, under sparse and bursty traffic. Measure request count per event, p50/p95 queue wait, average batch utilization, bytes/request, budget throttles and partial-failure recovery. Select a policy from the latency-throughput curve; do not assume larger batches are always faster.

### 29.6 Congestion-aware retry lanes and retry tokens

**Problem:** a service outage can convert every waiting task into a retry storm. Independent exponential backoff per item may still synchronize retries, while an uncertain commit cannot safely be treated like a known failure.

**Design:** classify attempts into at least: definitive transient non-commit, throttling, permanent validation/authorization failure, conflict/fencing, and unknown commit outcome. Use bounded retry tokens per server/work class and optional per-owner/key cooldowns to restrict how much retry traffic competes with fresh critical work. Apply jittered delays and coalesce wakeups so many retry deadlines do not align. Persist the canonical next eligibility time before considering a failed item rescheduled; unknown outcomes must be reconciled by the same stable operation ID rather than blindly rerun as a new operation.

Retry budgets control admission and timing, not terminal correctness. They must not erase or lower attempts, change the user's expiry policy, auto-promote poison work or mark an accepted message complete. Once the retry budget is exhausted, defer visibly or move to the existing bounded DLQ policy according to configured limits; never silently drop.

Pair with per-error-class retry counts, request amplification during incidents, recovery time after budget restoration and fresh-work versus retry-work share. Test throttle bursts, commit-then-error, many simultaneous due times, a permanently failing hot key and a service that recovers suddenly. Use jitter and bounded concurrency to avoid a recovery thundering herd.

### 29.7 Dependency-aware workflow scheduling with bounded priority inheritance

**Problem:** a high-priority workflow can be blocked by a required earlier step scheduled as low priority, while blindly promoting an entire saga can let one workflow dominate the system.

**Design:** let the workflow coordinator expose the currently ready steps and explicit predecessor relationships. A ready predecessor that blocks a time-sensitive, higher-priority workflow step may receive a temporary **scheduling-only inherited urgency**. The inheritance is derived from durable workflow state, bounded by a maximum boost and duration, and never changes the step's persisted business identity, idempotency key or terminal semantics.

Only a ready, valid predecessor can be boosted; a missing, failed, unknown-outcome or fenced dependency must be reconciled through the workflow state machine before downstream work proceeds. Validate the dependency graph against cycles when a workflow is created. Inheritance expires automatically when the dependent step finishes, is cancelled or becomes terminal. It cannot be used to override profile ownership, reorder steps within a declared serial sequence, compensate an unknown result or skip a required step.

Pair with workflow critical-path wait, blocked-step age, boost rate and per-workflow resource caps. Benchmark with many small workflows and one deep/large workflow, measuring completion p95, unrelated-work starvation and extra read/write requests. Keep this opt-in for workflow users and omit it from ordinary mailbox messages.

### 29.8 Shadow scheduler, replay and gradual activation

**Problem:** scheduling algorithms are difficult to validate from throughput alone. A new rule may appear faster while starving a lane, changing ordering or overloading critical persistence.

**Design:** add a test/diagnostic mode where the current scheduler makes the real decision and an alternate scheduler computes a **shadow recommendation** from the same observed eligible candidates. The shadow path must not claim messages, write DataStore state, publish hints or mutate ordering. Record only bounded redacted decision summaries: selected lane, estimated cost, age/slack, candidate count, predicted decision and reason category.

Replay captured synthetic traces through deterministic virtual time and injected budgets to compare FIFO/weighted/DRR/deadline policies. Production shadow sampling must be opt-in, bounded and low-overhead; no arbitrary user payload is required in the trace. Gradual activation is a local runtime-policy revision and canary cohort, never a separate global server leader. Roll back scheduling policy without rewriting message records.

Pair with a deterministic metric report comparing queue delay by class, starvation bounds, critical-save p95, request amplification, and predicted versus actual completion. Shadow agreement is not correctness proof; the fault simulator and public-behavior tests remain the authority. Promotion from shadow to active scheduling requires explicit review and a kill switch.

### 29.9 Scheduling feature order

1. **First:** lease-renewal deadline lane, retry-token/backoff control and bounded fair work classes. These protect accepted work and critical profile persistence under congestion.
2. **Next:** cost-aware DRR and due-time wake scheduling, after request-cost and scan-amplification baselines exist.
3. **Then:** bounded adaptive batch windows for already-opted-in batch APIs.
4. **Later/opt-in:** deadline-slack selection and workflow priority inheritance, only where an application has explicit SLO/workflow requirements.
5. **Before default activation of any complex policy:** run the shadow scheduler, replayed traces and priority/fairness fault tests.

Do not implement every algorithm at once. Start with weighted fairness and a critical reserve; use measured queue wait and request-cost evidence to decide which extension solves a real bottleneck.

### 29.10 Scheduling performance acceptance

For each candidate algorithm, compare against the simplest viable scheduler on an identical input trace and runner. The initial owner-scoped configuration allows at most 2,048 index rows retained in non-reclaimed active-mailbox slots per partition before capacity/backpressure at the stated default limits, plus an independent bounded DLQ index. Include tests for the full configured capacity and the operational recovery path when it is exhausted. Capture:

- completed operations per second and DataStore request cost per completed operation;
- p50/p95/p99 queueing delay per owner, priority lane and work class;
- oldest eligible item age, late/expired item count and starvation interval;
- claim-renewal lateness, expired claims and duplicate-handler recovery;
- critical profile save/release p95 and maximum dirty-data age;
- read/write budget observations, throttle/error classes and retry amplification;
- batch utilization, encoded bytes, scan amplification and peak local scheduler memory.

Simulation measures scheduling/codec CPU; wall-time and Roblox service behavior are separate. Do not use mocked request latency as evidence for live DataStore latency. An optimization is accepted only when it improves its target objective without violating ordering, durability, per-owner fairness, lease fencing or critical persistence bounds. A lower average latency does not compensate for an unbounded starvation tail.


## 30. Final adversarial audit: remaining risks and required controls

This section is the final review checklist, not evidence that the future implementation has passed it.

| Risk / weakness | Why it matters | Required correction or release gate |
| --- | --- | --- |
| **More small writes can still exhaust budgets** | A canonical message key reduces rewrite amplification but enqueue still spans message state and segment index; profile sidecars add additional request work. | Measure actual request counts and byte throughput. Use inbox batching, outbox grouped cleanup, adaptive admission and fairness. Never claim the new layout is faster just because each key is smaller. |
| **Digest collision or unstable canonicalization** | A hash can route two requests to one key; ordinary JSON output is not automatically a canonical identity encoding. | Use a versioned length-prefixed identity codec, fixed test vectors, full stored identity/request comparison and fail-closed collision handling. Keep exact canonical request identity through the dedup window. |
| **A preparing message may not be indexed yet** | A crash before/after active reservation, canonical creation, index append, ready promotion or registry clear can leave an incomplete durable intent. | Use the fixed-shard bounded registry to deduplicate in-flight submissions and resume each durable phase; clear it only after verified readiness or a verified terminal tombstone. Keep the canonical message record as the permanent idempotency receipt. |
| **Per-owner hot keys and bounded slot capacity** | One profile's manifest and append segment can become hot, and a full slot table can return capacity even while some individual messages are small. | Make saturation explicit; measure worst-case same-owner concurrency. Do not add partitions or relocate ready messages without an ordering and stale-writer protocol. A future index-sharding design must be a separately reviewed migration. |
| **Session cache versus durable atomic operations** | A direct inbox/outbox UpdateAsync racing local dirty data or old session ownership can lose updates; a separate queue-key claim cannot atomically prove profile-key ownership. | Require a write gate, flush/reconcile dirty state, owner/token/generation fencing inside the profile transform, and in-memory rebase after confirmed commit. Treat message claim/session metadata as non-authoritative for profile ownership. Test takeover between local checks and writes. |
| **User reducers can cause external effects** | A reducer can be called more than once by UpdateAsync; the library cannot sandbox arbitrary Luau code or detect all side effects. | Document strict purity. Use only reducers that return data; put non-idempotent effects behind inbox/domain ledgers outside the transform. Tests can cover library code but cannot prove arbitrary consumer callbacks pure. |
| **Adaptive tuning can oscillate or starve saves** | Every Record might otherwise create its own feedback loop, and queue processing could consume budget needed for session save/release. | One server-local governor; fast throttle backoff, slow recovery, hysteresis, reserved critical budget, shared semaphore and deterministic load tests. |
| **Local budgets do not reveal all universe-wide contention** | The per-server budget is not a complete view of shared experience traffic; several servers may collectively trigger throttling. | Incorporate throttle and latency feedback. State that the controller is locally adaptive, not a globally optimal allocator. Any cross-server budget coordinator remains optional and non-authoritative. |
| **Remote policy is untrusted/stale input** | Bad or out-of-order updates could push a server into unsafe settings or cause policy flapping. | Validate whole snapshots, monotonic revisions, strict hard bounds, last-known-good fallback, jittered polling and no per-operation policy reads. Keep runtime settings out of persistence protocol state. |
| **Notification-only acceleration can lose wake-ups** | MessagingService and MemoryStore are transient/best-effort or expiring; per-profile subscriptions can scale poorly. | Fixed bounded topic shards, coalesced wakeups, TTL-limited hints, periodic polling, and tests that intentionally drop every hint. |
| **Metrics can be inconsistent** | A multi-key stats scan is not a linearizable global snapshot. | Label scope/completeness/observation time. Metrics never authorize claims, acknowledgements, purge or migration. |
| **Rollback across envelope versions can lose sidecars** | Old binaries may strip inbox/outbox fields or mutate a format they do not understand. | Old-writer freeze sentinel, version compatibility matrix, retained source copy and explicit reverse migration only when quiesced and verified. |
| **Purchase receipt identity can outlive a bounded receipt window** | A platform may redeliver an unresolved purchase after an earlier grant was committed but its acknowledgement was not recorded. | Declare the exact guarantee and retention. Use a permanent/compact purchase ledger or authoritative entitlement keyed by receipt identity for lifetime uniqueness; never purge a receipt without proving the domain state still prevents re-granting. |
| **Direct transaction receipts can be pruned too early** | An expired operation ID may be retried and apply again. | Publish receipt-window semantics and retain permanent domain-ledger IDs where the business operation requires lifetime idempotency. |
| **Application schema migration can strand or rewrite data** | Envelope compatibility does not guarantee that game-level data remains readable; rollback binaries may not understand future fields. | Separate schema/envelope versions, preserve verifiable history, fence old writers, validate each migration and fail closed on future versions. |
| **Escrow compensation can destroy conservation** | A destination credit may commit after the source decides an earlier request failed. | Reconcile/retry the same destination operation before compensation; retain escrow and expose manual reconciliation when the outcome remains unknown. |
| **Diagnostic restore can overwrite newer or erased data** | A repair preview can go stale or historical data can reintroduce data covered by erasure. | Recheck expected revision and session fence at commit, preserve protocol metadata, consult erasure tombstones, and require a verified recovery point plus an operator audit. |
| **Hashed sidecar keys may be invisible to RTBF templates** | User IDs embedded only inside stored values cannot be matched by key-template deletion. | Block an RTBF completeness claim until each family has matchable key routing or a verified operational deletion inventory; test shared/multi-user payload redaction and legacy coverage. |
| **Materialized views can become stale or unrebuildable** | Out-of-order events or expired source history may produce incorrect search results. | Mark projections eventually consistent, version events, checkpoint progress, rebuild from an authoritative source and revalidate sensitive decisions against source records. |
| **Tracing can amplify writes or leak data** | Persisting every span as its own key increases hot-path request cost; raw identifiers/payloads may expose private data. | Use existing protocol writes or bounded local/external sinks, redact by default, limit retention and make trace completeness explicit. |
| **No-op elision can miss untracked mutations** | Skipping a save based on a stale dirty flag can silently lose direct table mutations. | Track mutations at supported API seams; disable the optimization where mutation tracking cannot be proven complete and test nested/reverted edits. |
| **Autosave jitter can exceed durability bounds** | Random delays may extend dirty data lifetime or overlap lease/release deadlines. | Bound jitter by configured maximum dirty age and deadlines; prioritize release/critical writes and test at worst-case scheduler load. |
| **Read coalescing can accidentally share authority decisions** | Sharing a stale read/session attempt may bypass required ownership or freshness checks. | Limit singleflight to explicitly read-only, freshness-compatible calls; never coalesce leases, claims, mutations or session acquisition. |
| **Compression/codec changes can break recoverability** | A faster or smaller encoding may make old versions unreadable or bypass validation. | Version codecs, bound decompression, preserve raw fallback and historical-read compatibility; keep the optimization disabled unless measured. |
| **Local budget headroom can be misleading** | Other scripts/servers and Open Cloud requests share experience-level consumption. | Use local concurrency as a control, react to actual throttling, preserve critical internal capacity and make no universe-wide budget guarantee. |

| **Expiry after a prior claim is not proof of no side effect** | A handler may still be running or may have committed an external effect when a claim expires; the mailbox cannot cancel or reverse arbitrary effects. | Treat expiry as a no-new-start boundary, preserve an unknown effect-outcome category when needed, and require application idempotency/receipt reconciliation before claiming the operation had no effect. |
| **The design is not yet a performance result** | Canonical per-message writes plus preparation reservation/cleanup and bounded index/DLQ operations add request cost; existing CodSpeed baselines do not exercise this architecture. | Measure request amplification and shard contention with dedicated workloads, then run isolated Studio/server tests for real request budgets, throttling and cross-server delivery. The current PR's diff is documentation-only; its existing hosted WallTime report has environment/syscall warnings and does not measure the proposed scheduler. Do not count that report as either a design benchmark pass or an attributable source regression. |

The preparation gap has an explicit outcome: a `preparing` message is not accepted and cannot execute. A fixed-shard bounded preparation reservation must be persisted before canonical creation, making every incomplete submission discoverable without whole-keyspace scans and preventing same-key concurrent retries from independently selecting locators. The registry retains exact submission identity while active; a caller retry with the same idempotency key adopts that reservation. Background recovery resumes the missing phase and clears the registry only after verified readiness, or after a verified terminal/retired tombstone. If the registry is unavailable or cannot bound active entries and request size, the v2 layout remains disabled rather than accruing undiscoverable records. A transactional outbox retries a destination submission using the same stable event ID until destination acceptance is verified. A message without an idempotency key cannot resolve an ambiguous whole-call retry and is unsuitable for irreversible work.

Known implementation limitation: the API can enforce validation, yielding rules where supported, version fences and bounded calls; it cannot prove arbitrary consumer callback purity, guarantee external API side effects exactly once, or infer all experience-wide request consumption from one server. Those limitations must remain explicit in API docs.

## 31. Adversarial audit disposition and release blockers

This section supersedes any less precise statement elsewhere in the document. It is a design review, not evidence that implementation tests have passed.

### P0 — close before enabling v2 writes

1. **Cross-key ownership is not a fence.** A canonical queue-key claim and a profile-key session lock are independent atomicity domains. The library can fence the queue state transition on the claim token and fence profile writes on the profile's current session token, but cannot atomically prove both in one UpdateAsync. The API must not promise global single execution of arbitrary handlers. Handler effects must be idempotent or committed through the same profile key's inbox transaction/outbox, and external APIs remain at-least-once.
2. **Preparing records need bounded discoverability and cleanup.** A canonical message can exist before its index row, and concurrent retries can race. Use a deterministic fixed-shard bounded preparation registry to deduplicate in-flight routes and resume each durable phase; clear it only after verified readiness or a terminal tombstone. Do not use whole-keyspace scans.
3. **Physical deletion must be generation-safe.** `RemoveAsync` is not a conditional delete. A read followed by deletion is racy. Fence writers with a durable tombstone/retired generation first, prove references/dependencies are retired, resolve uncertain outcomes, and retain idempotency evidence for the full declared guarantee. Any unresolved write that could recreate irreversible work blocks purge.
4. **RTBF is a key-layout requirement, not just an erasure worker.** Every user-associated key must be matched by tested static DataStore/name/scope/key templates under Roblox's actual constraints. An ID present only in a value, metadata, hash preimage or operational manifest does not satisfy automated RTBF matching. The 100-template cap and shared/multi-user records must be included in the route design. Do not claim complete RTBF coverage before an end-to-end disposable-experience test passes.
5. **No silent ordering promise.** The initial v2 release guarantees append-placement order only, not execution order. Reject non-nil `ordering_key` until a separately reviewed sequence/arbitration protocol exists and is enabled. Priority is optional and cannot manufacture ordering.
6. **Preserve key metadata.** All profile-key mutations and recovery paths must preserve DataStore user IDs and user-defined metadata unless intentionally and explicitly changed. RTBF key templates remain separately required.
7. **Claim leases are recovery hints, not exactly-once execution locks.** A slow or ambiguous UpdateAsync response can consume a material part of the lease. A worker must reconcile the exact precomputed claim token and sufficient lease margin before invoking a handler. Expired/old handlers may still be running; durable effect fencing/idempotency is the correctness boundary.
8. **Mixed-version rollout must be real, not assumed.** A freeze marker only blocks binaries whose transform checks the marker/version. Deploy a bridge that rejects future formats, drain old binaries and verify the old writer population is gone before enabling sidecars or v2 queue writes. If this cannot be established, do not migrate in place.

### P1 — operational safety and liveness

- **Capacity is finite.** The defaults imply at most 2,048 index rows retained in non-reclaimed active-mailbox slots per partition, a candidate 2,048 DLQ index rows, and 256 in-flight preparation reservations per owner across 16 fixed shards. Surface capacity, shard skew/headroom and blocked-work age for each. Full DLQ capacity intentionally stalls finalization and keeps the source row live; a full preparation shard backpressures new preparations before acceptance. Do not purge history automatically to free capacity.
- **Migration registries need declared revisions.** Runtime introspection cannot reliably fingerprint arbitrary Luau callbacks. Require stable migration IDs plus declared immutable implementation revisions/build digests.
- **Restore and erasure must share a fence.** A restore, projection rebuild or replay must not resurrect data covered by an erasure tombstone. Historical version behavior and backup retention require platform-specific verification.
- **Performance status stays inconclusive for the proposed design.** The latest available CodSpeed PR-head run uses existing unrelated harnesses and flags runner/syscall/runtime-environment problems. It contains no dedicated durable-mailbox or scheduler workload; it cannot demonstrate either the proposed improvement or an attributable regression from this docs-only PR.

### Release decision

The design is improved, but v2 is **not implementation-ready for production activation** until the P0 items above have concrete protocols and executable tests. Close each blocker with an implementation PR, failure-injection coverage and relevant Studio tests. Then rerun the full 70-group matrix against the real production-path code plus the fake-service harness. CodSpeed measurements establish local CPU/wall-time behavior only for their instrumented workload; they do not prove Roblox DataStore latency, delivery or quota behavior.


## 32. PR #35 implementation coverage and verification status

PR #35 now contains opt-in implementation surfaces for most of the feature categories in this design. This still does **not** mean every section's complete protocol or release acceptance requirement is fulfilled. The auditable section-by-section inventory is
[`docs/superpowers/specs/2026-10-17-recordstore-v2-implementation-matrix.md`](./2026-10-17-recordstore-v2-implementation-matrix.md).

### Core persistence and messaging integration added

- The existing core RecordStore request gate exposes a server-global, revisioned runtime configuration with named `balanced`, `latency`, `throughput` and `conservative` presets, periodic read/write budget sampling, corresponding read/write budget floors, work-class admission caps, a protected critical save/release reserve, queue backpressure, adaptive concurrency and telemetry. Adaptive behavior remains opt-in.
- Core records expose stable store/scope/profile-key/UserId identity. Mailbox processing requires an active Record bound to the same identity, checks the session both before claim work and immediately before invoking a handler, and fails closed on a mismatch, takeover or conflicting operation.
- The new `RecordStoreV2DataStoreAdapter` routes mailbox DataStore reads and updates through the shared core request gate, validates key length and preserves key UserIds/metadata. It deliberately does not expose unconditional physical deletion.
- The optional `RecordStoreV2Acceleration` uses a fixed set of shard topics, bounded local candidates, advisory MessagingService wake-ups, optional TTL-bounded MemoryStore hints and a polling fallback. Hints are not durable receipts or authorization to execute.
- Transactional outbox dispatch now has a bounded batch API: destination calls reuse stable event IDs and selected outcomes are committed with one source-profile sidecar update.
- The public `RecordStore.read_async` path now coalesces same-key concurrent reads without retaining a post-completion cache, bounds the in-flight key/waiter set, gives waiters a deadline and clones each returned snapshot. Calls with custom legacy decoders bypass coalescing.
- Dirty-generation tracking is visible in Record stats and durability-age reporting; a clean autosave can skip a redundant durable write. No-op/dirty-state correctness is not assumed without the later regression pass.

### Feature surfaces present but not fully accepted

The branch includes the segmented mailbox/DLQ and preparation protocol; transactional inbox/receipts/outbox; purchase-receipt handling; declared-revision schema migrations; transfer/escrow saga; Profile Doctor and guarded restore; adapter-driven erasure; projections and unique reservations; bounded tracing; payload/codec helpers; and resumable compaction callbacks. A standalone governor/scheduler model also exposes due scheduling, fairness, retry tokens, priority/dependency handling and replay/shadow hooks. These features have not all been wired into every core production path, and the model scheduler is not evidence that every policy controls every live operation.

Important limitations remain explicit:

- The existing core `Record:EnqueueAsync` retains the legacy behavior unless the active Record is explicitly bound with `Record:BindMailboxV2(mailbox)`. That opt-in bridge checks mailbox store/scope/profile key and persisted UserIds; unbound Records and pre-existing legacy queue rows are not migrated automatically.
- Strict non-nil `ordering_key` continues to be rejected, as required by the initial design contract. Priority is advisory selection among eligible work.
- Cross-profile changes remain sagas; arbitrary external effects remain at-least-once. RTBF completeness requires application-verified templates and inventory, writer fencing, dependency clearance and generation-aware deletion/redaction.
- The compatibility bridge, old-writer drain, fully exercised rollback protocol, end-to-end tracing coverage, and integration of every advanced scheduling/performance policy remain incomplete or unverified.
- `RecordStoreV2.ApplyRuntimePolicy()` and `GetRuntimeSnapshot()` delegate to the shared core request governor. A monotonic-revision runtime policy API applies validated patches after Records are active; boot-only provider configuration remains a separate operation. The V2 diagnostic governor is reused within one facade. The advanced candidate scheduler remains opt-in/model-level until its selection is wired and verified across production work classes.
- A deterministic DataStore-shaped fake now drives a 13-scenario harness through `RecordStore.new` (the live-backend code path) for acquisition, metadata, ambiguous open/save writes, transform replay, version reads, contention and stale-owner fencing. A separate runtime-governor regression checks policy application/snapshots against the shared core gate. These harnesses are registered in the regression workflow but have **not** run. The full 70-group matrix, crash/state-machine acceptance, real Roblox Studio/service tests, and mixed-version rollout rehearsal have **not** been run.

### Benchmark-first scope

The CodSpeed configuration adds successful-path workloads for V2 services, the actual core request gate/read coalescer, grouped outbox dispatch and fixed-shard wake-up acceleration. The current PR head has not yet received a verified fresh CodSpeed run in this pass; therefore benchmark outcomes and regressions remain unknown. Lune/Mock results do not establish live Roblox service latency or quota behavior.

V2 remains opt-in and **not production-ready** until the P0 blockers in Section 31 are closed by concrete protocol implementation, executable failure-injection tests and relevant Roblox Studio/service acceptance evidence.
