# RecordStore v2 architecture coverage matrix

**Source design:** `docs/superpowers/specs/2026-10-17-recordstore-durable-messaging-v2-design.md` (merged PR #33)  
**Implementation branch:** `experiment/recordstore-v2-failure-hardening` (PR #35)  
**Purpose:** distinguish design/code presence from executable verification and production acceptance.

This document is a static implementation inventory. “Implemented” means a corresponding code path or API exists in this branch; it does **not** mean that the code has compiled, passed tests, survived fault injection, met its benchmark target, or is safe to activate in production. All newly added and modified behavior must still go through the separately requested verification pass.

## Status definitions

- **Implemented surface:** an identifiable API or code path is present; the later verification gate is still open.
- **Partial:** useful implementation exists, but integration, protocol coverage, or required application inputs remain incomplete.
- **Deferred:** intentionally not implemented or not run in the feature-first pass.
- **Intentional non-goal:** explicitly excluded by the initial design contract.

## Numbered section coverage

| #33 section | Status | Current implementation surface | Remaining architecture / acceptance gap |
|---|---|---|---|
| 1. Guarantees and non-goals | Partial | Mailbox outcomes distinguish accepted, duplicate, conflict, capacity, retryable/unknown-like states; stable IDs, profile-key transactions and at-least-once effects are represented. | Verify every public return path against the contract. Unknown writes need path-specific reconciliation. Do not imply arbitrary effects are exactly-once. |
| 2. Difference from ProfileStore | Design only | The spec explains the intended differentiators and explicitly avoids claiming durable messaging alone is unique. | Documentation/comparison only; it is not a runtime feature. |
| 3. Public API proposal | Partial | `MailboxV2.EnqueueAsync`, status queries, active-session-gated processing, dead-letter operations, transaction/inbox/outbox helpers, receipt processor and saga APIs exist. | The old `Record:EnqueueAsync` surface remains the existing queue path; callers must opt into the V2 mailbox explicitly. The public API compatibility/bridge is not complete. |
| 4. Durable storage architecture | Substantial, unverified | Canonical mailbox rows, segment indexes, manifests, fixed-shard preparation registry, owner/request checks, bounded capacity and metadata-preserving DataStore adapter exist. | Verify exact key limits, digest test vectors, collision handling, every ambiguous phase, user-ID templates and metadata through the real DataStore contract. |
| 5. Transactional inbox | Implemented surface | Profile-key inbox receipts, exact canonical request material, idempotent single-message application and bounded inbox batches exist. | Verify receipt bounds/retention, batch limits, reducer replay behavior, envelope compatibility and crash between profile commit and queue acknowledgement. |
| 6. Transactional outbox | Substantial, unverified | Same-profile mutation + receipt + outbox intent is supported; stable destination event IDs are used. A new bounded batch dispatcher records several dispatch outcomes with one source-profile sidecar update. | Verify destination acceptance, response loss, source commit ambiguity, partial destinations, batch size/byte caps and cleanup boundaries. Delivery remains at-least-once. |
| 7. Recoverable workflows/sagas | Partial | Cross-profile transfer stores reservation/credit/settle/compensation phases and exposes status. | It is not a cross-key transaction. Full recovery-worker lifecycle, conservation invariants, duplicate/concurrent operations and ambiguous compensations await verification. |
| 8. Scheduler and acceleration | Partial | RecordStore's central request gate has protected critical capacity, budget sampling, work-class caps, adaptive policies and backpressure. The optional accelerator uses fixed-shard MessagingService topics, bounded local candidates, optional expiring MemoryStore hints and polling fallback. | The standalone V2 scheduler model is not the sole scheduler for every core/V2 operation. Request costs and cross-server behavior are unmeasured; hints remain advisory only. |
| 9. Dead letters, replay and retention | Implemented surface | Independent bounded DLQ index, bounded paging, replay/discard entry points and explicit capacity behavior exist. | Verify all terminalization/replay races, DLQ-full backpressure and retention/replay idempotency under the failure matrix. |
| 10. Operational observability | Partial | Record and mailbox stats, runtime admission metrics, bounded/redacted tracing, contention diagnostics and durability-age reporting exist. | Correlation across every operation and low-overhead behavior are not established. Optional durable tracing requires a store adapter and recovery tests. |
| 11. Migration, rollout and rollback | Partial | Versioned profile envelopes and declared-revision application-schema migrations exist. | The mixed-version bridge, old-writer drain/fencing, activation freeze protocol, compatibility matrix and exercised rollback rehearsal remain release blockers. |
| 12. Failure-injection matrix | Deferred | Simulator and fault APIs exist; the existing mailbox regression harness contains some fault cases. | Do not count the documented 70 groups as executed. Complete and run the real production-path suite in the separate verification pass. |
| 13. CodSpeed/service-budget validation | Partial | CodSpeed includes successful-path V2 features, governor/read-coalescing, actual core request-gate, grouped outbox-dispatch and fixed-shard wake-up workloads. | A fresh CodSpeed run on the current PR head has not been verified. Mock/Lune results cannot prove live Roblox service latency or quotas. |
| 14. Implementation sequence/release gates | Partial | Feature-first commits and benchmark-only CI gating are present. | The verification sequence and staged production rollout are documented but not completed. |
| 15. Acceptance criteria | Deferred | This matrix maps code surfaces to acceptance gaps. | No end-to-end acceptance criteria have been declared passed. |
| 16. Roblox/comparison references | Documentation | References and platform constraints are in the design document. | Keep references current during the final review. |
| 17. Purchase receipt processor | Implemented surface | Stable purchase IDs, product revision checks and receipt grant through a profile transaction are represented by the opt-in adapter. | Verify repeated ProcessReceipt callbacks, unknown writes, profile/session unavailability and product-revision changes. |
| 18. Idempotent transaction API | Implemented surface | `TransactAsync`/inbox/outbox commit paths retain the fingerprint and optional bounded exact request material. | Verify conflict/fingerprint mismatch, receipt capacity/retention and interaction with external dirty data and UpdateAsync transform replay. |
| 19. Application schema migration | Implemented surface | Stable migration IDs/revisions, sequential registrations, validation, preview and committed per-step migration exist. | Migration graph ambiguity, restart after each step, future-schema rejection and mixed-version rollback are not verified. |
| 20. Escrow transfer/trade | Partial | Explicit saga phases and compensation/reconciliation are implemented as a separate-key workflow. | Full balance conservation and cross-profile recovery cases remain unverified; exactly-once cross-key commit is not promised. |
| 21. Profile Doctor/restore | Implemented surface | Inspection, redacted bounded path diff, repair preview, expected-revision restore and erasure-tombstone check exist. | Audit policy, permissions, historical-version behavior, metadata preservation and restore-vs-erasure races require acceptance tests. |
| 22. User-data erasure/retention | Partial | Bounded erasure planning/execution accepts templates, authoritative inventory, writer-fence, dependency and generation-aware deletion callbacks. | The module cannot discover every game-specific key family by itself. No complete RTBF claim until all templates/inventory are verified, including shared records, history/backups and restore/replay resurrection. |
| 23. Deterministic crash simulator | Infrastructure present; acceptance deferred | Virtual clock, per-key mock storage, pre-commit/commit-then-error, transform replay, budgets, lossy/duplicate/delayed/reordered hints and server restart controls exist. | The simulator does not yet stand as evidence of correctness. Run the real persistence path against deterministic scripts and compare invariants/traces in the later pass. |
| 24. Secondary indexes/materialized views | Implemented surface | Eventually consistent projections, incremental events, rebuild callback and unique reservations exist. | Verify idempotent event application, stale revision suppression, rebuild after interruption, uniqueness conflicts and erasure/restore fencing. |
| 25. End-to-end tracing | Partial | Redacted bounded in-memory tracing, operation lookup and optional durable flush exist. | End-to-end propagation is not proven across every core/mailbox/receipt/saga/erasure operation; verify PII redaction and flush recovery. |
| 26. Performance engineering | Partial | The current scope below maps individual optimizations. | Some helpers remain optional and some runtime paths are only partially wired. Benchmarks and service-budget evidence are pending. |
| 27. Priority-specific durability/runtime controls | Partial | Dirty-generation timestamps, durability SLO lower-bound reporting, contention diagnostics, typed result normalization, admission/backpressure, class caps and bounded compaction APIs exist. | The lower-bound/unknown states and policy revisions need measurement and failure checks. Compaction, tracing and background adapters must obey the real shared budgets. |
| 28. Message/work/server priority | Partial by design | High/normal/background message priority and local work-class admission/scheduling exist. Core renewals are considered before autosaves and queue polling. | Strict `ordering_key` is intentionally rejected. Server-instance priority is intentionally not a core feature. Priority fairness and starvation bounds are unverified. |
| 29. Advanced scheduling | Partial | Due-time scheduling, owner fairness, age/deadline scoring, lease-renewal lane in the governor model, retry tokens, dependency handling, shadow choice and replay hooks exist; the core scheduler prioritizes renewal before autosave/queue polling. | Not every advanced policy is driving all production operations. Validate fairness, starvation, lease margins, throttling and the latency ceiling before activation. |
| 30. Final adversarial audit | Partial | Claim margin checks, explicit unknown effects, bounded preparation registry, generation-aware compactor callback, metadata-preserving adapters and session guard are present. | Protocol proofs remain incomplete without the real fault suite. In particular, no queue claim can fence an already-running arbitrary external effect across a second key. |
| 31. Release blockers/disposition | Deferred / not production-ready | The implementation documents the outstanding P0 and P1 constraints. | Do not enable by default or claim production readiness until every P0 protocol is closed by code, failure-injection tests and Roblox Studio/service acceptance. |

## Section 26 detailed coverage

| #33 optimization | Status | Implementation notes |
|---|---|---|
| 26.1 No-op save and dirty generations | Implemented surface | Core dirty/saved sequence tracking is wired; clean autosave can skip a redundant durable write. |
| 26.2 Deadline-aware autosave and startup jitter | Partial | Existing autosave jitter and renewal-before-autosave order remain; core exposes the dirty-generation timestamp/SLO. A complete policy guaranteeing a max dirty age under every overload is not established. |
| 26.3 Separate read/write budgets and critical reserve | Implemented surface | Shared core gate samples both budget types, applies the corresponding floors, and protects save/release request capacity. External mailbox/DataStore adapter traffic uses the same gate. |
| 26.4 Safe in-flight read coalescing | Implemented surface | Public `RecordStore.read_async` coalesces same-key concurrent reads only, uses bounded flight/waiter counts, waiter deadlines and cloned snapshots, performs no post-completion cache, and bypasses custom legacy decoders. |
| 26.5 One-pass codec/serialization | Partial | Canonicalization and codec validation are available in the V2 feature layer; it is not yet a universal replacement for every core serialization path. |
| 26.6 Threshold compression/compact encoding | Partial | Versioned codec-selection helpers exist; no default compression policy has been enabled in the core durable envelope. |
| 26.7 Per-profile mutation coalescing | Partial | Save requests can be coalesced using existing busy/follow-up state; arbitrary user mutations are not semantically merged. |
| 26.8 Payload sizing/large-record decision support | Partial | Canonical-byte estimates and payload assessment exist; these are not exact encoded-envelope sizes or Roblox request guarantees. |
| 26.9 Queue scan cost controls | Substantial surface | Segmented bounded indexes, capped batches, local due candidates and fixed-shard hints exist; scan amplification must be measured. |
| 26.10 Memory/allocation budget | Partial | Data structures and copies have item/depth limits in key paths; there is no complete measured per-profile/process allocation budget yet. |
| 26.11 Benchmark matrix/acceptance | Partial | Dedicated successful-path workloads are registered in `codspeed.yml`. They have not yet been run on the current head in this pass. |
| 26.12 Rejected performance shortcuts | Contract maintained | No claim of exactly-once effects, no unconditional generation-blind physical delete in the new adapter, no advisory-hint authority and no silent ordering promise. |

## Release gates that remain explicit

1. **Code/compilation gate:** run formatter/static analysis and the normal non-fault compile checks on the current PR head; these have not been run in this phase.
2. **Benchmark-first gate:** run the configured CodSpeed workloads on the current PR head. Current-head performance is unknown until that run returns.
3. **Failure verification gate:** run the full 70-group matrix plus inbox/outbox, purchase-receipt, saga, migration, erasure, projection, read-coalescing, scheduler and server-crash scenarios. This was intentionally deferred.
4. **Roblox acceptance gate:** disposable-experience DataStore/MessagingService/MemoryStore quota and response-loss tests, user-ID templates, metadata preservation, cross-server behavior and mixed-version rollback rehearsal.
5. **Release gate:** keep V2 opt-in and not production-enabled until P0s close. Performance results from Lune/Mock are local algorithm measurements, not live service guarantees.

The implementation matrix should be updated whenever a design gap closes. Do not convert a row from partial/deferred to passed merely because an API or benchmark workload exists.
