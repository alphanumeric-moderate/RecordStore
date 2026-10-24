# PR #56 Non-Save PR #39 Implementation Plan

> Execution: implement in bounded, testable slices on `feat/pr39-non-save-operations-2026-10-24`; keep PR #56 a draft until all merge gates for the delivered scope pass.

**Goal:** Implement the remaining non-save features defined by PR #39, including missing non-save functionality around the merged PR #37 scheduler, while leaving PR #55's durable-save recovery and PlayerData durability/backpressure work separate.

**Architecture:** Keep profile-key DataStore envelopes authoritative and all local scheduler, MemoryStore, MessagingService, cache, index, maintenance and tracing state advisory unless a feature has its own explicit durable protocol. Extend the existing embedded Mailbox V2 and RecordStore abstractions rather than adding a parallel persistence protocol. Each write transform remains pure, deterministic, non-yielding and side-effect free. New durable features stay disabled until their correctness and rollout gates pass.

**Tech Stack:** Roblox Luau strict mode, DataStoreService, MemoryStoreService/MessagingService where supported, the existing embedded RecordStore scheduler and Mailbox V2, Lune regression shim, CodSpeed.

**Source of truth:** PR #39 design specification, especially sections 3-25, 27.2(D-E), 28-31 and implementation phases 3-12. PR #37 already supplies the advanced scheduler core; do not reimplement it.

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

- [ ] Compare the merged scheduler implementation and public API against PR #39 sections 28-29 and the latest PR #37 follow-up findings.
- [ ] Add focused tests for reserved work-class aliases, dependency terminal history while queued/in-flight dependents hold references, and bounded reclamation after all dependents terminate.
- [ ] Fix only reproduced defects; preserve queue bounds and critical-lane isolation.
- [ ] Record which omissions are intentionally rejected by PR #39, rather than treating them as missing features.

### Slice 2: Mailbox V2 protocol and operations

- [ ] Audit existing Mailbox V2 coverage against the canonical envelope, producer idempotency, bounded preparation discoverability, claims/renewal/ack/DLQ/replay, and v3 compatibility contracts.
- [ ] Implement missing idempotent producer receipts and recovery for partial preparation/acknowledgement, without duplicating already implemented strict per-key ordering.
- [ ] Add bounded operational APIs for recovery, capacity/status reporting, safe reclamation and resumable maintenance; preserve advisory-only semantics for separate indexes and MessagingService hints.
- [ ] Add crash-window, competing-claim, capacity-full, duplicate-producer, stale-index and response-loss tests.

### Slice 3: Same-profile inbox/outbox and idempotent transactions

- [x] Implement same-profile inbox mutation + receipt and source mutation + outbox intent within one authoritative profile-key UpdateAsync; regression coverage verifies the source mutation and outbox intent commit together.
- [ ] Add general idempotent transactions with canonical request identity, bounded results/receipts, duplicate/conflict/capacity/unknown outcomes and explicit retention guarantees.
- [ ] Add bounded outbox fan-out with per-destination receipts and resumable cleanup.
- [ ] Add purchase receipt processing as an opt-in adapter; never auto-register or replace MarketplaceService callbacks.

### Slice 4: Recoverable saga coordinator

- [ ] Persist bounded workflow identity, step state, retry/compensation state and unresolved external outcomes.
- [ ] Resume from authoritative coordinator records, preserve idempotency across retries, and expose explicit manual-resolution states.
- [ ] Add crash/failure injection for every step boundary; never claim cross-profile atomic transactions.

### Slice 5: Server-local operations and adaptive governor

- [ ] Add versioned bounded runtime policies and read-only health/runtime snapshots on top of the current scheduler/governor.
- [ ] Preserve the internal critical persistence reserve and keep adaptive changes opt-in.
- [ ] Add bounded session contention/takeover diagnostics, a resumable retention compactor and an offline maintenance runner.
- [ ] Add fairness, low-budget, throttle, lease-margin, pause/resume and bounded-progress tests.

### Slice 6: Migration and Profile Doctor

- [x] Add a process-local migration registry with stable IDs, declared implementation revisions, compatibility ranges, forward-only edges and ambiguous-path rejection. A target with no path fails closed during preview.
- [x] Add bounded read-only path/type migration previews. Preview executes non-yielding transformations on a snapshot and never persists the result.
- [x] Add read-only profile inspection and historical version diffs that omit raw values and report truncation explicitly.
- [ ] Add durable registry manifests, execution with source revision/session fencing checks, visible quarantine on validation failure, repair preview and guarded restore with audit identity.
- [ ] Ensure restore never overwrites protocol metadata, receipts, fencing state or erasure tombstones.

### Slice 7: Projections, erasure and operation tracing

- [ ] Add opt-in durable secondary indexes/materialized views backed by durable events or a verified snapshot/cursor protocol, with idempotent projection offsets and rebuild status.
- [ ] Add a user-data family inventory and resumable erasure plan/execution/status that fences recreation and reports uncertain/unmatched families.
- [ ] Keep the RTBF-completeness claim blocked until templates cover every user-associated key layout and the real platform acceptance test passes.
- [ ] Add bounded correlated operation traces that distinguish durable evidence from process-local observations and redact payload/identity fields by default.

### Slice 8: Verification and merge gates

- [ ] Run all Luau checks and Lune regression stages for every delivered slice.
- [ ] Add fault-injection tests and focused CodSpeed benchmarks for each durable protocol/maintenance path.
- [ ] Complete independent code review and inspect every changed file.
- [ ] Keep live Roblox Studio/DataStore multi-server, throttling/cache, crash/shutdown, mixed-version rollout/rollback and RTBF template acceptance explicitly blocked until executed in a real test experience.

## Current status

Implemented and covered by the current Lune regression suite:
- Read-only session lease diagnostics and bounded Mailbox V2 maintenance orchestration.
- Profile Doctor point-in-time inspection and bounded historical version diffs with path/type-only output.
- Process-local migration registration with stable IDs/implementation revisions, compatibility validation, forward-only edges, ambiguity rejection, and read-only migration previews.
- Opt-in same-profile idempotent transactions and inbox application with bounded durable receipts, duplicate/conflict handling, reducer yield rejection, and unknown-write reconciliation.
- Atomic source-profile mutation plus durable outbox-intent creation through `CommitWithOutboxAsync`; the API persists intent only and does not yet deliver events to destination profiles.

Still incomplete: scheduler audit items and full mailbox producer/recovery acceptance matrix; receipt capacity/retention fault coverage; bounded outbox delivery with per-destination receipts and cleanup; purchase receipt adapter; recoverable saga orchestration; adaptive runtime policy APIs; resumable retention/offline maintenance; durable migration manifests and guarded execution/quarantine/restore; durable indexes/materialized views; erasure inventory/coordinator; and correlated operation tracing. Live Roblox service and rollout acceptance remains a separate release gate.