# PR #39 Production Implementation Plan

> **Execution:** Inline, one testable slice per commit/PR. Every persistence feature remains disabled until its own correctness gates pass.

**Goal:** Implement the accepted PR #39 durable-save recovery, mailbox, transactional workflow, adaptive scheduling, operations, and migration design without weakening RecordStore's durable source-of-truth or session-fencing invariants.

**Architecture:** Keep the profile-key DataStore envelope authoritative. Every write decision is revalidated inside that key's non-yielding `UpdateAsync` transform. Unknown outcomes preserve immutable operation identity/snapshot and remain visibly degraded until reconciled or fenced. Mailbox/index, MemoryStore, MessagingService, telemetry, caches, scheduling and other accelerators are advisory unless a feature has an explicit durable record protocol. Split the work into reviewable PRs; no one PR enables all phases.

**Tech Stack:** Roblox Luau strict mode, DataStoreService, bounded local scheduler, Lune regression harness, Roblox Studio/server tests, CodSpeed.

**Spec:** `docs/superpowers/specs/2026-10-17-recordstore-durable-messaging-v2-design.md` (PR #39).

## Global Constraints

- DataStore profile records are the durable source of truth; caches, MemoryStore and MessagingService cannot grant ownership or prove a write committed.
- Every UpdateAsync transform is pure, non-yielding and free of externally visible side effects.
- Never retry an ambiguous commit as if it were a confirmed non-commit. Reuse the same operation ID, immutable snapshot, base/target revisions and fencing evidence until reconciled.
- Never overwrite a newer revision, replace a competing owner, or revive an expired lease without an explicitly enabled and separately tested profile-key CAS recovery protocol.
- Distinguish ownership certainty, durability certainty and lifecycle state. `unknown` is eligible for bounded reconciliation only, not ordinary mutation.
- Keep critical renewal/save/reconciliation/release capacity reserved from mailbox, maintenance, tracing and optional transaction work.
- Preserve DataStore user IDs and custom metadata unless the operation explicitly changes them.
- Do not claim exactly-once execution for arbitrary callbacks or cross-key workflows. Use same-profile idempotency receipts/outbox and describe external effects as at-least-once.
- New persisted formats and routes require an off-by-default gate, mixed-version rejection, disposable-namespace migration rehearsal and rollback safety.
- Performance changes require equivalent CodSpeed measurements and cannot bypass correctness gates.
- No destructive deletion, restore, repair, receipt pruning or erasure runs until a durable fence and a verified inventory prove it safe.

## Review Focus

- A write commits but the caller sees an error; recovery must detect that exact write without adding a revision or replaying a reward.
- The verification read fails until lease safety margin expires; bounded backoff must not spin or falsely mark data clean.
- A newer owner/revision wins while an old write is uncertain; the old writer must never restore itself.
- Mutations arrive while ownership is unknown or dirty age exceeds policy; no silent loss or unbounded volatile buffering.
- A crash lands between durable intent, index publication, handler invocation, acknowledgement, receipt cleanup, or cross-profile saga steps; every accepted intent must remain discoverable or explicitly unresolved.

---

## Task 0: Establish protocol and executable evidence

**Files:** existing PR #39 spec, `tests/RecordStore_UnknownSaveRecoveryRegression.server.luau`, `bench/run_regression_tests.luau`, CI workflows.

- [ ] Inventory existing behavior against sections 26.13, 27.2, 27.4, 31 and phase 0.
- [x] Maintain a production-path fake DataStore boundary that deterministically injects fail-before-commit, commit-then-error, held verification reads, budget exhaustion, transform replay, and ownership races.
- [x] Add targeted transition tests; the new pending-UserIds/metadata release retry regression was observed failing before the fix and passing after it.
- [ ] Establish existing CodSpeed entries as a baseline; separate simulation, walltime, service-cost assumptions and unmeasured live Roblox behavior.
- [x] Luau type check and every Lune regression stage pass on the current head; benchmark-result interpretation and live Roblox release gates are tracked separately.

**Acceptance:** tests control clock/fault order; each failure assertion identifies a violated persistence invariant; no test labels volatile state durable.

## Task 1: P0 durability SLO, typed outcomes and mutation admission

**Files:** `src/PlayerDataInitializer/RecordStore.luau`, `src/PlayerDataInitializer/PlayerDataCore.luau`, focused regressions and README.

- [x] Validate `max_dirty_age_seconds` and `durability_mode`; preserve compatibility defaults.
- [x] Expose confirmed revision/generation, dirty/durable watermark, oldest dirty age, last confirmed write, pending operation ID, lease margin, current classification and observation quality.
- [x] Make risk signals edge-triggered/coalesced and bounded; declare health snapshot scope.
- [x] Implement deadline-aware saves and critical-operation reserve without starvation by optional work.
- [x] Make PlayerDataCore choose explicit bounded buffering or visible backpressure; the default implementation must never silently accept unbounded unsaved progress.
- [x] Test direct table mutation tracking, dirty-age boundary, unknown-write status, read-only admission, restoration of tracked Value objects, and recovery clearing risk only after confirmation.

**Acceptance:** no-op save cannot infer clean state from incomplete tracking; unhealthy persistence is observable; no claim that in-memory dirty changes survive process death.

## Task 2: P0 unknown save, renewal and release recovery

**Files:** RecordStore save/renew/release state machine, scheduler admission and fault-injection tests.

- [x] Retain immutable logical operation ID/snapshot, dirty watermark, base/target revisions, exact session token/generation and reason across ambiguous outcomes.
- [x] Confirm commit only when the authoritative uncached envelope matches the operation ID, target revision, ownership fence and lease requirements.
- [x] Retry only a known non-commit using the same operation ID/snapshot and exact base revision/fence inside UpdateAsync.
- [x] On competing revision/owner, schema mismatch, corruption, tombstone or expiry, fence instead of writing stale state.
- [x] Implement same-process lease CAS reacquisition only behind an off-by-default option, with exact base-write/revision/generation/session checks and a new fencing generation.
- [x] Cover deterministic fail-before-commit and commit-then-error recovery for save, renewal and release, including stable operation identity, revision counts, release semantics, and pending UserIds/application metadata preservation.
- [x] Test opt-in lease reacquisition after expired save and renewal, response loss during reacquisition, insufficient post-CAS lease margin, disabled-by-default behavior, and replacement-owner races.
- [ ] Run live Roblox acceptance for actual process interruption, platform throttling/cache behavior, and multi-server lease-margin transitions.

**Acceptance:** commit-then-error is recognized without duplicate revision; retries reuse exact identity and do not cross changed revision/fence; new owner always wins; continued outages remain bounded and degraded.

## Task 3: Mailbox V2 canonical durable protocol

**Files:** embedded Mailbox V2 and storage adapter, serializers/keys, queue fault tests and dedicated benchmarks.

- [ ] Define canonical bounded message records, idempotent producer receipts, append-only bounded segment/index layout and stable IDs.
- [ ] Preserve v3 readers and implement freeze/bridge/migration without a destructive in-place rewrite.
- [ ] Add bounded discoverability for partially prepared messages using deterministic fixed shards; never scan a full keyspace.
- [ ] Fence claims, renewals, acknowledgements, DLQ moves and replay with durable tokens and operation IDs.
- [ ] Reconcile acknowledgement uncertainty without rerunning a message already durably acknowledging.
- [ ] Keep DLQ capacity and growth separate from active-message write/capacity budgets.
- [ ] Keep yielding handlers unavailable until claim renewal, cancellation, shutdown fencing and at-least-once side-effect documentation are tested.
- [ ] Reject ordering keys unless the strict per-key order protocol is implemented and explicitly enabled.
- [ ] Test duplicate producer keys, payload mismatch, every crash window, stale/duplicate indexes, expiry, competing claims, ack-then-error, DLQ/replay order, capacity full, and compatibility with old queue records.

**Acceptance:** accepted durable messages remain discoverable after every crash point; no stale index yields duplicate concurrent claims; no global exactly-once callback claim; format migration retains a usable rollback source.

## Task 4: Profile inbox/outbox transactional primitives

**Files:** envelope/schema versioning, profile UpdateAsync transform, transaction tests.

- [ ] Implement `ApplyInboxAsync` with mutation and idempotency receipt in the same profile-key UpdateAsync.
- [ ] Add optional `ApplyInboxBatchAsync` only with bounded item/byte limits and tested all-or-nothing atomicity.
- [ ] Implement `CommitWithOutboxAsync` so source mutation and intent share one profile-key transaction.
- [ ] Implement bounded outbox fan-out, per-destination receipts and grouped cleanup only after confirmed destinations.
- [ ] Preserve concurrent sidecars during normal snapshots; add backpressure and migration gating while legacy writers exist.
- [ ] Test commit-then-error for receipt and source update, duplicate request payload mismatch, same-key concurrency, sidecar preservation, capacity exhaustion, dispatch/cleanup crash and old-writer rejection.

**Acceptance:** mutation+receipt and source+intent commit atomically within one key; accepted destination effects are not duplicated on cleanup retry; cross-key atomicity is never claimed.

## Task 5: Durable saga coordinator

- [ ] Persist saga identity, bounded steps, per-step idempotency, retries, compensation state and operator-visible unresolved outcomes.
- [ ] Resume interrupted sagas from authoritative records; never infer that a timed-out external effect did not occur.
- [ ] Add a transfer example only after crash-injection coverage demonstrates conservation and duplicate prevention for every step.
- [ ] Test crash before/after each step, compensation retry, unknown external effect, duplicate command, and manual-resolution requirement.

**Acceptance:** workflows converge through idempotent steps or an explicit compensation/manual-resolution state; no atomic cross-profile helper is exposed.

## Task 6: Server-local adaptive governor

- [ ] Share one governor across Record instances and integrate with existing scheduling.
- [ ] Add bounded runtime profiles, validation/revisioning, `get_runtime_snapshot()` and `apply_runtime_policy()`.
- [ ] Reserve critical save/renew/reconcile/release share; never auto-call `SetRateLimitForRequestType()`.
- [ ] Use deterministic budget/throttle traces and hysteresis; keep adaptive mode off by default.
- [ ] Test min/max bounds, stale policy revision, oscillation, budget exhaustion, throttling, lease-near-expiry, high optional load and critical reserve fairness.

**Acceptance:** adaptive controls use local measured signals only, avoid oscillation, do not exceed configured limits, and cannot starve critical profile work.

## Task 7: Measured acceleration and operations

- [ ] Add inbox batch and outbox group-cleanup benchmarks paired with correctness suites.
- [ ] Add optional shared sharded MessagingService/MemoryStore hint adapter, wake-up coalescing and bounded candidate cache behind a disabled-by-default flag.
- [ ] Keep periodic durable polling as the recovery source of truth; a missing hint never loses accepted work.
- [ ] Add bounded health/status, paginated DLQ management, repair dry-run, consistency diagnostics and redacted correlated trace IDs.
- [ ] Benchmark hint-enabled vs polling-only behavior; default to off unless target and adjacent critical-save cases meet the gate.

**Acceptance:** accelerators can be disabled without changing persistence/delivery semantics; metrics declare scope/completeness; no tracing write is mandatory per mutation.

## Task 8: Idempotent transactions, purchase receipts

- [ ] Implement and verify general single-profile `TransactAsync` mutation/receipt before MarketplaceService integration.
- [ ] Define receipt uniqueness, retention, data growth, unknown result and restore/reconcile behavior.
- [ ] Model durable pending entitlements explicitly where a grant spans profiles or external systems.
- [ ] Test repeat PurchaseId, payload mismatch, callback failure, commit-then-error, process loss after durable receipt, and pending entitlement recovery.

**Acceptance:** a receipt is never marked processed merely because an in-memory grant ran; live MarketplaceService handlers stay disabled until all tests pass.

## Task 9: Schema migrations and Profile Doctor

- [ ] Add deterministic schema migrations, version metadata, preview/validation and future-version fencing.
- [ ] Build crash simulator before enabling guarded restore or automatic repair.
- [ ] Provide read-only diagnosis first; repair plans must be dry-run, revision/session fenced, auditable and quarantined on ambiguity.
- [ ] Test partial migration, unknown migration commit, future schema, corrupted history, rollback and mixed-version writers.

**Acceptance:** no template/default data substitutes for unreadable existing data; destructive repair requires verified source history and explicit generation fence.

## Task 10: Escrow transfer and materialized views

- [ ] Build on tested saga, inbox/outbox and receipt primitives.
- [ ] Implement escrow conservation invariants, source/destination idempotency and unknown-outcome reconciliation.
- [ ] Treat projections and indexes as eventually consistent, rebuildable downstream consumers with source-version checkpoints.
- [ ] Test concurrent transfers, crash at every step, compensation, duplicate effects, stale projection and reconciliation.

**Acceptance:** no transfer helper or unique index activates before concurrent and crash-injected state-machine acceptance passes.

## Task 11: Erasure inventory and correlated tracing

- [ ] Inventory every user-linked key using explicit static DataStore/name/scope/key templates; cover multi-user/shared records and the template cap.
- [ ] Fence profile generations and sidecars before deletion; don't rely on `RemoveAsync` as a conditional delete.
- [ ] Resolve uncertain writes and references before purge; retain idempotency evidence for the advertised guarantee.
- [ ] Add bounded redacted traces with operation IDs and no mandatory extra hot-path writes.
- [ ] Test partial erasure, legacy sidecars, trace-sink failure, unresolved workflow references, mixed versions, dry-run and retry.

**Acceptance:** only claim erasure coverage after an end-to-end disposable-experience test; unresolved durable work blocks purge.

## Task 12: Staged rollout and final review

- [ ] Run every Lune regression, production-path fake DataStore/fault-injection test, Rojo build, Studio server test and relevant CodSpeed comparison.
- [ ] Exercise disposable DataStore migration and rollback; verify mixed-version rejection and old-writer drain.
- [ ] Keep independent feature kill switches that stop new writes without discarding accepted messages.
- [ ] Perform a fresh review of the final diff against PR #39; fix critical/important findings test-first.
- [ ] Merge only when every enabled phase has a mapped acceptance result and no critical/important defects remain.

**Acceptance:** each PR is green and reviewable on its own; unavailable Roblox live-service checks are labelled unverified, never passed by inference.
