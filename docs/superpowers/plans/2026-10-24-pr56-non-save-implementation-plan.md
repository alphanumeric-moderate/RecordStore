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

### Slice 0: Deterministic protocol simulation infrastructure

- [x] Add a bounded, replayable bench-only simulator with independent server clocks, per-key atomic UpdateAsync semantics, transform replay, fail-before-commit and commit-then-error faults, virtual scheduling, process-crash local-state loss, MemoryStore TTL behavior, best-effort MessagingService hint faults, stable seed handling, and redacted trace/invariant reporting.
- [ ] Add simulator-specific regression coverage to the final verification phase only, after the remaining feature work is complete; do not treat simulator implementation or mock behavior as Roblox service acceptance.


### Slice 0.5: Optional server-to-server wake-up acceleration

- [x] Ship the concrete opt-in MessagingService adapter consumed by `RecordStoreV2.BindMailboxWakeups`; use a fixed shard set, bounded local registrations/coalescing, event deduplication, and an explicit start/stop lifecycle.
- [x] Add an optional fixed-slot MemoryStore hint path, disabled by default. Hint loss or collisions must never affect durable mailbox correctness.
- [x] Evict every observed sorted-map hint after a poll attempt and expose removal errors; fixed-slot overwrite races remain acceptable because durable polling/reconciliation is authoritative.
- [x] Align the simulator's MessagingService mock to Roblox's `SubscribeAsync(topic, callback)` and `PublishAsync(topic, message)` call shape; model cache staleness across servers instead of globally invalidating every reader's cache.
- [ ] Add accelerator regression coverage in the final verification phase, including dropped, duplicated, delayed, stale and capacity-limited hints; durable polling must remain the recovery path.

### Slice 1: Audit and complete PR #37 non-save scheduling correctness

- [x] Compare the merged scheduler and public API against PR #39 sections 28-29 and PR #37 follow-up behavior. The audit confirms bounded local scheduling, per-owner/resource admission, critical reserves, deadline-aware lease renewal, retry/circuit backpressure, kill-switch/pause behavior, and dependency retention have existing implementation/tests; no new global scheduler tier is warranted.
- [x] Add focused tests for reserved work-class aliases, dependency terminal history while queued/in-flight dependents hold references, and bounded reclamation after all dependents terminate.
- [x] Fix only reproduced defects; preserve queue bounds and critical-lane isolation. This slice fixed the proven V2 transaction API signature mismatch, removed the unsafe read-before-reserve balance rejection that could strand an all-balance reservation after response loss, and persists `compensation_pending` before invoking refund.
- [x] Record intentional omissions: no cross-server server/master ranking; no durable due-time index without measured need; no automatic Roblox request-rate manipulation; no reprioritization operation in the initial schema; and priority never bypasses ordering, claim fencing, or the reserved critical persistence lane. Local wakeups remain disposable hints backed by bounded polling/reconciliation.

### Slice 2: Mailbox V2 protocol and operations
- [x] Add an opt-in outbox destination adapter that validates destination identity/UserId, requires an explicit activation guard, binds the embedded Mailbox V2 to an active destination Record, and acknowledges only accepted/duplicate enqueue results whose canonical destination record has been read back uncached and matched against the exact event ID/type/payload.

- [x] Add `ImportLegacyAsync` and `ImportLegacyDeadLetterAsync` with owner-bound stable physical routes, preserved public IDs, attempts/replay counters and Unix-second to millisecond timestamp conversion. Active legacy FIFO order is preserved only when strict ordering is explicitly enabled; old lock tokens are not reused as live claim tokens. Active imports also fail closed while the V3 processing lease is unexpired.
- [x] Add an atomic q2 queue freeze marker, uncached bounded source page APIs, and a concrete migration adapter; old V2/V3 queue parsers fail closed on the future-version marker. Reserved IDs are rejected before freeze and the source record is retained.
- [x] Close the separate retired `q:` key race: an absent or empty V1 queue is atomically sealed with a bound future-version marker instead of relying on a single cached-per-session emptiness check. Non-empty legacy data remains untouched for manual recovery.
- [x] Add a resumable mailbox migration coordinator with application-supplied source freeze, old-writer drain, bounded page readers, durable revision-CAS checkpoints, import read-back verification, explicit V2 activation, and no automatic legacy deletion.
- [ ] Finish the Mailbox V2 version/compatibility audit. The Lune matrix covers producer/ack write failures and future-schema read/write rejection; segment reclamation now reads canonical records uncached, compares entries after the safety scan and prevents stale writers from reviving retired segments. Mixed-version/V3 rolling deployment and rollback acceptance remains open.
- [x] Reject message-level envelope versions other than V2 in public delivery/queue/dead-letter reads and all canonical message updates; regression covers ready claims, acknowledgement recovery and dead-letter transitions, confirming future-version records remain untouched and claim results use `unsupported_schema` rather than `unknown`. Full mixed-version and v3 rollout compatibility remains open.
- [x] Reject future-version canonical producer receipts before an older V2 enqueue path can report a duplicate; a focused regression asserts the future record remains untouched.
- [x] Verify the existing idempotent producer receipt and recovery across before/after failures at every observed producer-enqueue `UpdateAsync` boundary; verify acknowledgement-transition response loss, both terminal-acknowledgement failure timings, and dead-letter response-loss recovery without duplicate delivery. This mock-backed protocol coverage does not close the mixed-version/V3 rollout gate.
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
- [x] Add an opt-in bounded permanent per-profile purchase-ID ledger for developer products. The ledger and grant mutation commit in the same profile transaction, survive finite transaction-receipt expiry, reject ID rebinding and fail closed at capacity or corruption. Enabling it requires `permanent_purchase_ledger_migration_complete = true`, an operator declaration that historical PurchaseIds were backfilled or no earlier purchase history needs importing; the declaration is not independent proof. The ledger is per-profile, so global lifetime uniqueness needs a separate durable entitlement authority.
- [x] Keep receipt processing scoped to the PR #39 legacy developer-product `ProcessReceipt` contract; unrelated purchase types are not required by the current design.
- [x] Add bounded `BackfillPermanentLedgerAsync` for application-supplied historical PurchaseId batches. It validates active profile/UserId ownership, commits ledger entries without a grant, reconciles unknown transaction outcomes, and defers live receipt grants while the migration gate is false.
- [ ] Complete live-platform purchase acceptance and enumerate/reconcile all required historical PurchaseIds, or configure an external entitlement authority when historical/global uniqueness is required.

### Slice 4: Recoverable saga coordinator
- [x] Add an opt-in durable cross-profile transfer saga with stable operation IDs, reservation/credit/settlement phases, compensation, durable status, and explicit unresolved outcomes.
- [x] Reuse committed per-leg outcomes beyond finite transaction-receipt retention, validate durable saga records before mutation/status return, and keep transient fenced/capacity/budget failures pending instead of compensating a valid transfer.

- [x] Persist bounded workflow identity and a four-slot per-leg outcome ledger (reserve/credit/refund/settle) with stable operation IDs, exact request fingerprints, attempts, last code, outcome state, and bounded errors. The reservation transaction itself performs the atomic balance check, so a lost reserve response cannot strand an all-balance reservation behind a stale pre-check. The `compensation_pending` phase is committed before invoking the refund leg, then reconciles the same refund operation before any credit retry. The existing 32-entry transition history remains bounded and validated. Full automatic reconciliation of non-RecordStore external side effects remains out of scope.
- [x] Resume from authoritative coordinator records, preserve idempotency across retries, and expose explicit manual-resolution states. `RequireManualResolutionAsync` uses the expected phase/status and a stable request ID; `ResolveManualAsync` uses a revision-like attempts/timestamp compare, persists exact canonical request material for both idempotency keys, rejects changed operator/reason input under reused IDs, requires operator/reason audit fields, and requires application-supplied durable evidence verification before terminal `settled`/`rejected` decisions.
- [x] Add crash/failure injection for saga manifest creation and response loss; compare full intended coordinator state before reconciling an ambiguous write, and return `settled` only when that exact terminal state is durable. A pre-commit terminal-state failure stays `unknown` at the last durable phase and resumes idempotently with the same operation ID; additional failure injection across every transfer leg remains needed. Never claim cross-profile atomic transactions.

### Slice 5: Server-local operations and adaptive governor
- [x] Add versioned bounded runtime policy updates routed to the existing core scheduler, plus a read-only runtime snapshot and diagnostic dirty-age policy.
- [x] Add resumable bounded maintenance compaction with persisted cursors and generation-aware delete callbacks; checkpoint status now matches terminal/paused/unknown outcomes, unresolved inspection/delete results keep the cursor, and oversized pages are rejected before processing.

- [x] Add versioned bounded runtime policies and read-only health/runtime snapshots on top of the current scheduler/governor; this duplicates the checked runtime-policy/snapshot item above and has been reconciled with its existing regression coverage.
- [x] Preserve the internal critical persistence reserve and keep adaptive changes opt-in. Existing scheduler tests confirm generic work cannot consume reserved critical capacity; runtime policy changes are versioned and explicitly applied.
- [x] Add an independently invokable bounded maintenance runner with dry-run default, authorization and durable writer-fence requirements for execution, revision-checked checkpoints, exact response-loss reconciliation and resumable job IDs. Application-owned page, inspection, dependency and generation-aware delete adapters remain mandatory; the runner does not infer the live keyspace.
- [ ] Complete real retention-compaction acceptance. The compactor now validates dense bounded pages and advancing cursors, rolls counters back to the durable page boundary after inspection/delete uncertainty, and counts idempotent `already_absent` replays as confirmed absence. Live storage behavior and acceptance with the real application adapters remain open.
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
- [x] Harden erasure API boundary validation: reject malformed batch limits and UserIds without throwing; validate status identity/version before returning it, and propagate corrupt/unverified status fail-closed to `IsErased` and `ShouldBlockWrites`.
- [x] Harden resumable erasure execution: each RTBF template must specify exact DataStore name, scope, and key; inventories must explicitly certify completeness; malformed/oversized lists and unmatched locators fail closed; destructive execution is blocked until the stored plan proves coverage. The coordinator requires `GetAsyncFresh` for status/execution and ambiguous-plan reconciliation so cached reads cannot miss a fence. Writer fences and dependency checks are required/rechecked at each item boundary; the application delete/redaction adapter must atomically validate both the durable erasure fence and observed generation in the mutation, because a prior callback alone leaves a check/delete race. `already_absent` and `already_redacted` are accepted to replay a confirmed prior action after response/checkpoint loss; generation mismatch or uncertain identity must not be reported as success. `resolved` is terminal but does not release the write gate unless the application's audited resolution process explicitly clears its own durable fence. `IsErased` reports completion only after a coverage-verified completed manifest; `ShouldBlockWrites` separately preserves the no-recreation fence while an erase is planned/in progress, resolved without proof, or a legacy manifest lacks proof.
- [x] Add bounded redacted trace buffering and optional durable trace flush/read reconciliation.

- [x] Add opt-in durable projection rebuild manifests with stable rebuild/snapshot identity, bounded page processing, persisted cursors and counts, exact ambiguous-write reconciliation, status inspection, restart/resume coverage, and strict complete/cursor contract validation. The source adapter must pin the same immutable snapshot for every page; source-specific platform acceptance remains a release gate.
- [ ] Connect the generic erasure coordinator to the application's actual user-associated key families; supply exhaustive inventories, verified templates, generation-aware actions, and writer/recreation fences for every active write path. The generic bounded plan/execution/status API exists, but the real user-key inventory and exhaustive application wiring are not implemented.
- [ ] Keep the RTBF-completeness claim blocked until templates cover every user-associated key layout and the real platform acceptance test passes.
- [x] Add bounded correlated operation traces with unique per-event IDs, cross-process-safe merge/deduplication, explicit `process_local` / `durable_store` / `durable_store_and_local` evidence labels, durability summaries, and payload/identity redaction.

### Slice 8: Verification and merge gates

- [ ] Run all Luau checks and Lune regression stages for every delivered slice on the final head. Latest completed typecheck and regression evidence predates the current erasure-constructor hardening; fresh current-head CI is required.
- [ ] Complete fault-injection and focused CodSpeed evidence for every durable protocol/maintenance path. Mailbox V2 producer/acknowledgement/future-schema interleavings, compaction checkpoint replay (including counters), independent maintenance-runner checkpoint recovery, purchase-ledger expiry/conflict/capacity/legacy-marker behavior, and saga reserve/credit/refund/settle failures both before commit and after response loss have focused regression coverage. Complete final-head benchmark/evidence and real-platform acceptance remain outstanding.
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

Still incomplete: real mixed-version/V3 rollout and rollback acceptance (source freeze/import primitives are implemented, but must be accepted on live Roblox services); handler-side destination effect integration and real multi-server acceptance; additional receipt adapters if the application uses other purchase types; atomic quarantine writer fencing across every application write path; real user-key-family inventory and RTBF completeness; complete fault-injection across every durable saga leg and real retention path; adaptive governor fairness/low-budget/throttle/lease-margin acceptance; independent review of all changed files; final-head regression and benchmark evidence for every durable protocol; and live Roblox Studio/DataStore throttling, cache behavior, crashes/shutdown, mixed-version rollback, purchase fulfillment and RTBF template acceptance. The permanent purchase ledger is bounded and per-profile, not global.

The outbox-to-Mailbox V2 adapter receipt proves durable mailbox acceptance only. It does not prove that a destination handler executed, or that an external effect completed. Keep handler-side processing idempotent and retain live multi-server acceptance as a separate release gate.
