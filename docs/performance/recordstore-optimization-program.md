# RecordStore optimization program

## Objective

Improve RecordStore's CPU cost, allocation pressure, memory retention, and workload scalability across the core persistence module and its optional service modules without changing durable behavior or public contracts accidentally.

This is a staged engineering program, not a blanket rewrite. Every production change must correspond to an identified cost or a source-level complexity defect, and must have a regression test before it is considered complete.

## Architectural constraints

- DataStoreService remains the durable source of truth.
- MessagingService and MemoryStoreService remain advisory. They must not become prerequisites for correctness.
- Session ownership, fencing generations, lease semantics, revision ordering, and shutdown release semantics must remain unchanged.
- UpdateAsync transform callbacks remain pure, non-yielding, and free of external side effects.
- Unknown write outcomes continue to require authoritative verification or reconciliation; never turn uncertainty into a confirmed failure or success.
- Failed or corrupt loads must not silently create a fresh default profile.
- Persisted envelope, sidecar, mailbox, receipt, purchase, and erasure formats remain compatible unless a separately reviewed migration is explicitly required.
- The scheduler and embedded Mailbox implementation remain in RecordStore.luau as required by repository CI. The public mailbox API is V1. New durable queue envelopes use implementation version 3; version-2 envelopes remain readable for compatibility and migration.
- No production optimization may depend on benchmark-only Roblox service behavior or assume standalone Lune reproduces live Roblox engine/network costs.

## Workstreams and order

### 1. Bounded in-memory service structures

Targets: RecordStoreV1 tracing, read coalescing, local caches, bounded event histories, and optional advisory queues.

Current candidates:
- Replace front-removal from the process-local trace buffer with a fixed-capacity circular buffer. Preserve chronological reads, newest-event retention, dropped counts, durable flush ordering, and Drain semantics.
- Replace the read-coalescer's full-cache size count and repeated minimum-expiry scan with an indexed expiry min-heap and O(1) entry count.
- Reuse one private immutable fetch snapshot for the in-flight result and cache entry, while continuing to return defensive copies to callers.
- Inspect other bounded histories and caches for repeated full scans; use the data structure best suited to their ordering and mutation contract.

### 2. Core value pipeline

Targets: RecordStore copy, validation, serialization, change diffing, snapshot creation, and public-data isolation.

Measure and map traversals before changes. Candidate optimizations must preserve:
- cyclic-value rejection and depth/node/byte limits;
- dense-array and key-shape requirements;
- non-finite number marker behavior;
- buffer-copy isolation;
- validator invocation semantics and error categories;
- change event values, truncation, observer isolation, and public Data detachment.

Do not remove validation or make internal aliases observable simply to reduce copies. Prefer combining traversals only where a clear ownership boundary and equivalent validation behavior can be proven.

### 3. Scheduler and request admission

Targets: queue representation, candidate selection, heap operations, priority/fairness logic, budget checks, diagnostic snapshots, and retry scheduling.

The already-merged 256-entry ring-buffer metric windows are baseline behavior. Review remaining operations such as indexed array removal and sort-based selection in context. Preserve FIFO tie-breaking, weighted/deficit fairness, critical reserves, per-owner caps, deadline handling, retry ordering, and capacity guarantees. Do not replace arrays with linked structures solely because of asymptotic complexity; locality and bounded queue sizes matter.

### 4. Durable session lifecycle

Targets: open/load, save/update, lease renewal, close/release, ambiguous-write recovery, history, migrations, and version reads.

This is the highest-risk workstream. Optimization is allowed only after tracing real call paths and adding or reusing deterministic fault-injection tests for stale owners, generation changes, commit-then-error, response loss, throttling, crashes, and shutdown. No batching, coalescing, retry reordering, or cached reads may weaken per-key ordering or authoritative verification.

### 5. PlayerDataCore integration

Targets: value normalization, cached Instance lookup, pending field batches, flush/retry scheduling, lifecycle cleanup, and shutdown coordination.

Preserve leaderstats/value-object behavior, latest-value coalescing, session-state fences, backpressure, accepted-change retention, and failure visibility. Avoid extra RecordStore reads or Stats calls unless required for a correctness decision.

### 6. Optional durable service modules

Targets: purchase/receipt authority, lifetime entitlements, outbox adapters, maintenance runners/adapters, erasure inventories/fences, migration, projections, and CodeNum.

Review each service independently. Keep durable identity and idempotency checks, generation-aware erasure fences, outbox delivery semantics, migration recovery, and purchase uniqueness intact. Benchmark numeric arithmetic separately from DataStore and Roblox API overhead.

## Measurement policy

- Run the existing regression and strict Luau type-check workflows before and after each meaningful slice.
- Add targeted Lune workloads to CodSpeed for pure CPU and allocation-sensitive structures. Assert workload checksums so a faster benchmark cannot silently do less work.
- Compare only matching benchmark names, runner modes, and compatible environments.
- Treat CodSpeed Simulation as modeled CPU, not Roblox server wall time. System-call-dominated simulations cannot support end-to-end speed claims.
- Use Roblox Studio Script Profiler/MicroProfiler and multi-server tests for engine, scheduler, DataStore, MessagingService, and MemoryStore claims.
- Report measured values, methodology, environment, warnings, and limitations. If no valid before/after measurement exists, state that clearly.

## Acceptance criteria

A slice is complete only when:
1. Its target bottleneck and expected complexity/allocation change are documented.
2. Tests cover existing behavior and the changed structure's boundary cases.
3. Luau strict/typecheck passes.
4. Relevant regression suites pass on the final commit.
5. A matching benchmark exists and correctness checks prove equal work.
6. Performance claims are limited to measurements that are directly comparable.
7. An independent review finds no regression to persistence, session, schema, security, or lifecycle invariants.

## Current first slice

Implement and measure the V1 service API's process-local trace ring buffer and read-coalescer cache/expiry improvements. Keep the durable queue implementation at version 3 and preserve the existing version-2 read/migration compatibility path. Keep the changes isolated from RecordStore's durable session and mailbox protocols. The existing scheduler metric ring buffers on main are already complete and must not be duplicated.
