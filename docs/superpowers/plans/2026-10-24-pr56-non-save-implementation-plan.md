# PR #56 Non-Save PR #39 Implementation Plan

> Execution: implement in bounded, testable slices on `feat/pr39-non-save-operations-2026-10-24`; keep PR #56 a draft until all merge gates for the delivered scope pass.

**Goal:** Implement the remaining non-save features defined by PR #39, including missing non-save functionality around the merged PR #37 scheduler, while leaving PR #55's durable-save recovery and PlayerData durability/backpressure work separate.

**Architecture:** Keep profile-key DataStore envelopes authoritative and all local scheduler, MemoryStore, MessagingService, cache, index, maintenance and tracing state advisory unless a feature has its own explicit durable protocol. Extend the existing embedded Mailbox V2 and RecordStore abstractions rather than adding a parallel persistence protocol. Each write transform remains pure, deterministic, non-yielding and side-effect free. New durable features stay disabled until their correctness and rollout gates pass.

**Tech Stack:** Roblox Luau strict mode, DataStoreService, MemoryStoreService/MessagingService where supported, the existing embedded RecordStore scheduler and Mailbox V2, Lune regression shim, CodSpeed.

**Source of truth:** PR #39 design specification, especially sections 3-25, 27.2(D-E), 28-31 and implementation phases 3-12. PR #37 already supplies the advanced scheduler core; do not reimplement it.

## Intentional v1 omissions (per PR #39)

- No cross-server server-priority/master-server election or durable global worker ranking. Server role/runtime profile is a local policy hint only.
- No durable due-time index unless measurements prove the current bounded local wake scheduler and periodic authoritative reconciliation are insufficient.
- No automatic `SetRateLimitForRequestType()` changes to attempt manufacturing Roblox request priority.
- No general message reprioritization contract in the initial version. Any future reprioritization needs its own versioned compare-and-update operation and crash/compatibility tests.
- No priority override of canonical ordering, ownership/claim fencing, retry/expiry semantics, or the internal persistence reserve.
- No hard completion-deadline guarantee from queue scheduling; deadlines are advisory targets, distinct from `available_at`, expiry, and claim-lease expiry.

## Global Constraints

- PR #55 owns P0 save/renewal/release uncertainty recovery, durability SLO/backpressure, and PlayerData mutation admission; do not duplicate or weaken those changes.
- Cross-key workflows are not atomic, arbitrary callbacks are not exactly-once, and unknown outcomes are never treated as confirmed non-commit.
- All accepted durable work must remain discoverable through bounded recovery; no whole-keyspace scans on request paths.
- Do not physically delete records without a durable tombstone/fence, verified references, and reconciled ambiguous writes.
- Do not enable destructive restore, compaction, retention or erasure by default.
- Do not claim complete RTBF coverage unless every user-associated key family is matchable by verified Roblox templates and the platform-specific gate passes.
- PR #39 explicitly rejects global/cross-server server ranking as a core feature for the initial design; retain server-local roles and scheduling only.
- Persisted format changes require versioning, mixed-version rejection, migration/rollback tests, and explicit opt-in activation.
- Performance claims require same-environment CodSpeed comparisons; synthetic/Lune behavior is not live Roblox service evidence.

## Work slices

### Slice 1: Audit and complete PR #37 non-save scheduling correctness

- [x] Compare the merged scheduler and public API against PR #39 sections 28-29 and PR #37 follow-up behavior. The audit confirms bounded local scheduling, per-owner/resource admission, critical reserves, deadline-aware lease renewal, retry/circuit backpressure, kill-switch/pause behavior, and dependency retention have existing implementation/tests; no new global scheduler tier is warranted.
- [x] Add focused tests for reserved work-class aliases, dependency terminal history while queued/in-flight dependents hold references, and bounded reclamation after all dependents terminate.
- [x] Fix only reproduced defects; preserve queue bounds and critical-lane isolation. This slice fixed the proven V2 transaction API signature mismatch, removed the unsafe read-before-reserve balance rejection that could strand an all-balance reservation after response loss, and persists `compensation_pending` before invoking refund.
- [x] Record intentional omissions: no cross-server server/master ranking; no durable due-time index without measured need; no automatic Roblox request-rate manipulation; no reprioritization operation in the initial schema; and priority never bypasses ordering, claim fencing, or the reserved critical persistence lane. Local wakeups remain disposable hints backed by bounded polling/reconciliation.

### Slice 2: Mailbox V2 protocol and operations
- [x] Add an opt-in outbox destination adapter that validates destination identity/UserId, requires an explicit activation guard, binds the embedded Mailbox V2 to an active destination Record, and acknowledges only accepted/duplicate enqueue results carrying a durable message ID.

- [ ] Finish the Mailbox V2 version/compatibility audit: canonical v2 envelope, producer receipt discoverability, claims/renewal/ack/DLQ/replay and existing crash regressions are covered individually, but the complete mixed-version/v3 rollout and remaining partial-write windows still need a unified compatibility/fault matrix.
- [x] Reject message-level envelope versions other than V2 in public delivery/queue/dead-letter reads and all canonical message updates; regression covers ready claims, acknowledgement recovery and dead-letter transitions, confirming future-version records remain untouched and claim results use `unsupported_schema` rather than `unknown`. Full mixed-version and v3 rollout compatibility remains open.
- [ ] Implement missing idempotent producer receipts and recovery for partial preparation/acknowledgement, without duplicating already implemented strict per-key ordering.
- [x] Audit and cover the existing bounded Mailbox V2 operational APIs: `RecoverAsync`, `GetStatsAsync`, `ReclaimAsync`, and `MaintenanceAsync`. Maintenance regression verifies the bounded/non-linearizable status contract, recovery/reclamation results, capacity/readiness reporting, and fail-closed activation denial. Separate indexes and wake-up hints remain advisory.
- [x] Add crash-window, competing-claim, capacity-full, duplicate-producer, stale-index and response-loss tests for producer preparation, acknowledgement, expired claims, and DLQ transition recovery. Capacity-full recovery accepts an explicit `capacity` result or an ambiguous `unknown` paired with durable blocked-preparation metadata; it does not misclassify partial writes as definite rejection.

### Slice 3: Same-profile inbox/outbox and idempotent transactions

- [x] Cover outbox batches over the 16-event limit and persistent sidecar encoded-size saturation, asserting failures do not advance the revision or mutate profile data.

- [x] Implement same-profile inbox mutation + receipt and source mutation + outbox intent within one authoritative profile-key UpdateAsync. Regression covers inbox batch commit/replay and the public outbox transaction adapter; the V2 facade forwards arguments according to the current public RecordStore method contracts.
- [x] Add general idempotent transactions with canonical request identity, bounded results/receipts, duplicate/conflict/capacity/unknown outcomes and explicit retention guarantees; regression now exercises the public `TransactAsync` adapter contract, result tuple, duplicate receipts, and canonical request binding.
- [x] Add bounded outbox reads and callback-based at-least-once dispatch with per-event destination receipt IDs, unknown-outcome reconciliation, and bounded retention cleanup.
- [x] Add inbox/transaction receipt-capacity and expiry-recovery tests; surface encoded-sidecar-size exhaustion as capacity while preserving profile data and valid duplicate receipts.
- [x] Add an opt-in legacy developer-product receipt handler factory with receipt/product validation, active-session checks, same-profile durable idempotency, and no implicit MarketplaceService registration.
- [x] Add identity-bound, read-only durable transaction receipt status lookup with committed/not-found/expired/conflict/unknown outcomes; the purchase adapter consults it before deferring an uncertain transaction.
- [ ] Add additional receipt-type adapters and live-platform acceptance for purchase processing.

### Slice 4: Recoverable saga coordinator
- [x] Add an opt-in durable cross-profile transfer saga with stable operation IDs, reservation/credit/settlement phases, compensation, durable status, and explicit unresolved outcomes.

- [x] Persist bounded workflow identity and a four-slot per-leg outcome ledger (reserve/credit/refund/settle) with stable operation IDs, exact request fingerprints, attempts, last code, outcome state, and bounded errors. The reservation transaction itself performs the atomic balance check, so a lost reserve response cannot strand an all-balance reservation behind a stale pre-check. The `compensation_pending` phase is committed before invoking the refund leg, then reconciles the same refund operation before any credit retry. The existing 32-entry transition history remains bounded and validated. Full automatic reconciliation of non-RecordStore external side effects remains out of scope.
- [x] Resume from authoritative coordinator records, preserve idempotency across retries, and expose explicit manual-resolution states. `RequireManualResolutionAsync` uses the expected phase/status and a stable request ID; `ResolveManualAsync` uses a revision-like attempts/timestamp compare, persists exact canonical request material for both idempotency keys, rejects changed operator/reason input under reused IDs, requires operator/reason audit fields, and requires application-supplied durable evidence verification before terminal `settled`/`rejected` decisions.
- [x] Add crash/failure injection for saga manifest creation and response loss; compare full intended coordinator state before reconciling an ambiguous write, and return `settled` only when that exact terminal state is durable. A pre-commit terminal-state failure stays `unknown` at the last durable phase and resumes idempotently with the same operation ID; additional failure injection across every transfer leg remains needed. Never claim cross-profile atomic transactions.

### Slice 5: Server-local operations and adaptive governor
- [x] Add versioned bounded runtime policy updates routed to the existing core scheduler, plus a read-only runtime snapshot and diagnostic dirty-age policy.
- [x] Add resumable bounded maintenance compaction with persisted cursors and generation-aware delete callbacks; checkpoint status now matches terminal/paused/unknown outcomes, unresolved inspection/delete results keep the cursor, and oversized pages are rejected before processing.

- [x] Add versioned bounded runtime policies and read-only health/runtime snapshots on top of the current scheduler/governor; this duplicates the checked runtime-policy/snapshot item above and has been reconciled with its existing regression coverage.
- [x] Preserve the internal critical persistence reserve and keep adaptive changes opt-in. Existing scheduler tests confirm generic work cannot consume reserved critical capacity; runtime policy changes are versioned and explicitly applied.
- [ ] Complete the offline maintenance runner and real retention-compaction acceptance. Bounded session/lease diagnostics and resumable, generation-aware compaction orchestration exist; live retention behavior and an independently invokable offline runner remain open.
- [x] Add fairness, low-budget, throttle, lease-margin, pause/resume and bounded-progress regressions to the common Lune runner. The advanced scheduler suite covers request-budget recovery, pause/resume and kill-switch behavior; the focused scheduler slice checks high-lane flood fairness, low-budget critical preference, circuit cooldown recovery, and lease-margin renewal selection.

### Slice 6: Migration and Profile Doctor
- [x] Add durable migration manifests with stable migration IDs/revisions, guarded execution through Record transactions, explicit failed-step quarantine, and operator-audited quarantine resolution.
- [x] Add durable profile quarantine status/resolve APIs and keep repair preview read-only; restore now requires explicit authorization and erasure callbacks, binds the expected preflight data digest, and records operator ID plus reason.
- [x] Add a fail-closed quarantine writer-check helper; integrating an atomic writer fence into every application write path remains a release blocker.

- [x] Add a process-local migration registry with stable IDs, declared implementation revisions, compatibility ranges, forward-only edges and ambiguous-path rejection. A target with no path fails closed during preview.
- [x] Add bounded read-only path/type migration previews. Preview executes non-yielding transformations on a snapshot and never persists the result.
- [x] Add read-only profile inspection and historical version diffs that omit raw values and report truncation explicitly.
- [x] Add durable registry manifests, execution with source revision/session fencing checks, visible quarantine on validation failure, and operator-audited quarantine resolution; regression verifies commit-then-response-loss reconciliation.
- [x] Ensure restore never overwrites protocol metadata, receipts, fencing state or erasure tombstones; regression injects conflicting historical values for each class.

### Slice 7: Projections, erasure and operation tracing
- [x] Add opt-in durable event-driven projections with monotonic revision checks, payload-fingerprinted bounded idempotency receipts (event-ID reuse with a different payload conflicts), durable bounded rebuild cursors, and durable uniqueness reservations.
- [x] Add resumable bounded erasure manifests with explicit application family inventory, writer fence, dependency check, and generation-aware redaction/deletion callbacks; repeated planning preserves existing progress, `resolved` is terminal, cursor checkpoints use monotonic compare-and-update, inventory must explicitly certify completeness, malformed/oversized lists fail closed, and unmatched template locators remain visible and block RTBF coverage claims.
- [x] Add bounded redacted trace buffering and optional durable trace flush/read reconciliation.

- [x] Add opt-in durable projection rebuild manifests with stable rebuild/snapshot identity, bounded page processing, persisted cursors and counts, exact ambiguous-write reconciliation, status inspection, restart/resume coverage, and strict complete/cursor contract validation. The source adapter must pin the same immutable snapshot for every page; source-specific platform acceptance remains a release gate.
- [ ] Connect the generic erasure coordinator to the application's actual user-associated key families; supply exhaustive inventories, verified templates, generation-aware actions, and writer/recreation fences for every active write path. The generic bounded plan/execution/status API exists, but the real user-key inventory and exhaustive application wiring are not implemented.
- [ ] Keep the RTBF-completeness claim blocked until templates cover every user-associated key layout and the real platform acceptance test passes.
- [x] Add bounded correlated operation traces with unique per-event IDs, cross-process-safe merge/deduplication, explicit `process_local` / `durable_store` / `durable_store_and_local` evidence labels, durability summaries, and payload/identity redaction.

### Slice 8: Verification and merge gates

- [ ] Run all Luau checks and Lune regression stages for every delivered slice.
- [ ] Complete fault-injection and focused CodSpeed evidence for every durable protocol/maintenance path. The V2 transaction adapter now has direct public-contract regression coverage; saga tests inject response loss after reserve, credit, refund and settle, including the refund-before-credit retry hazard.
- [ ] Complete independent code review and inspect every changed file.
- [ ] Keep live Roblox Studio/DataStore multi-server, throttling/cache, crash/shutdown, mixed-version rollout/rollback and RTBF template acceptance explicitly blocked until executed in a real test experience.

## Current status

Implemented and covered by the current Lune regression suite:
- Read-only session lease diagnostics and bounded Mailbox V2 maintenance orchestration.
- Profile Doctor point-in-time inspection and bounded historical version diffs with path/type-only output.
- Process-local migration registration with stable IDs/implementation revisions, compatibility validation, forward-only edges, ambiguity rejection, and read-only migration previews.
- Opt-in same-profile idempotent transactions and inbox application with bounded durable receipts, duplicate/conflict handling, reducer yield rejection, and unknown-write reconciliation.
- Atomic source-profile mutation plus durable outbox-intent creation through `CommitWithOutboxAsync`.
- Bounded `GetOutboxAsync`, `DispatchOutboxAsync`, and `PruneOutboxAsync` APIs: stable event IDs, verified destination receipt IDs, sidecar-only raw-envelope writes, closed-source dispatch, bounded pages/cleanup, and explicit unknown/pending states.
- Regression coverage for inbox/transaction receipt saturation and expiry recovery: full collections reject new operation IDs without profile mutation; live receipts still deduplicate; expired receipts are reclaimed before a new commit.
- Opt-in developer-product receipt processing through `PurchaseReceiptProcessor:CreateHandler`: malformed receipt and unsupported product checks, active-profile requirements, durable same-profile grant/idempotency, duplicate acknowledgement, conflict deferral, and explicit finite receipt retention.

Still incomplete: remaining scheduler audit and independent acceptance run; Mailbox V2 mixed-version/v3 compatibility and remaining partial-preparation/acknowledgement crash windows; handler-side destination effect integration and real multi-server acceptance; additional purchase receipt types and permanent entitlement semantics where required; atomic quarantine writer fencing across every application write path; real user-key-family inventory and RTBF completeness; complete CI/fault-injection execution for reserve/credit/refund/settlement response-loss regressions on the final head; adaptive governor fairness/low-budget/throttle/lease-margin acceptance; independent review; final fault-injection execution and focused CodSpeed evidence; and live Roblox Studio/DataStore throttling, crash/shutdown and mixed-version rollback acceptance.

The outbox-to-Mailbox V2 adapter receipt proves durable mailbox acceptance only. It does not prove that a destination handler executed, or that an external effect completed. Keep handler-side processing idempotent and retain live multi-server acceptance as a separate release gate.
