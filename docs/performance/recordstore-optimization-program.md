# RecordStore performance program

## Objective

Reduce the CPU time, allocation rate, garbage-collection pressure, and avoidable work on RecordStore's profile read, mutation, save, and scheduler paths. Keep the existing durability, validation, ownership, and isolation contracts.

This PR is a performance refactor. The existing V2 service surface on `main` is preserved; this work does not add an inbox/outbox feature, mailbox migration, message-routing adapter, purchase workflow, maintenance workflow, or erasure workflow.

## Performance changes

### 1. Fused value-copy and validation pipeline

- Combine defensive copying and shape accounting in a single traversal where the caller already needs a detached tree.
- Cache the runtime type once per node/edge during recursive traversal rather than repeating type dispatch.
- Stop immediately when node, depth, key, string, or other configured limits are exceeded.
- Track the presence of non-finite values during the copy/shape pass. Proven-finite values skip a redundant non-finite marker scan.
- Build persisted non-finite path segments only when a non-finite value is found; keep the persisted marker format unchanged.
- Use the same prepared snapshot for custom validation and serialization so Save/Close do not repeat avoidable traversals.
- Preserve caller-reference isolation, custom-validator isolation, snapshot boundaries, JSON size enforcement, and external mutation detection.
- Fuse direct mutable `Record.Data` defensive copying with shape accounting, skip duplicate shape/non-finite traversals, and reuse the detached candidate for the private change-event baseline. The custom validator still receives its own isolated copy.
- Transfer ownership of newly parsed detached envelopes into public read snapshots and private LastSaved/baseline storage. Public `Record.Data` and `GetLastSaved()` results remain independently owned.
- In the durable UpdateAsync transform, fuse the detached stored-value copy with shape accounting, then run exact JSON serialization/byte-limit validation without a second shape traversal. Non-finite raw storage values remain rejected.
- During reconciliation, rely on the already-validated detached target's table-shape invariant and inspect one existing key to reject map/array key-kind mixing, instead of rescanning every target key for each inserted default.
- For plain-table templates, validate template shape in place while tracking only subtrees the merge can insert or recurse into; avoid a detached template snapshot and clone only inserted default subtrees. A no-op reconciliation still detaches the public profile tree and private mutation-observation baseline, but avoids the template snapshot and merge allocations. Templates with custom iteration metamethods retain the defensive snapshot path. Configured validation and exact serialized-size checks remain authoritative.

### 2. Copy-on-write Patch path

- Add an opt-in ordered `Record:Patch` API for small path-based mutations of large table-backed profiles.
- Clone the root and touched ancestors only on first write; do not clone untouched private subtrees.
- Reuse weak-key summaries for private immutable subtrees: node count, maximum depth, non-finite presence, and conservative serialized-size lower bounds.
- Use lower bounds only for safe early rejection. Exact JSON encoding remains the final payload-size authority.
- Continue to publish a fully detached public `Record.Data` tree and run the configured validator. Do not expose shared internal subtrees.
- Keep the existing `Record:Update` callback contract unchanged.

### 3. Scheduler allocation reductions

- Keep FIFO selection allocation-free: track the best eligible queue index and best non-high index during the admission scan.
- Represent non-FIFO eligible candidates as dense numeric queue indices instead of one temporary record table per candidate.
- Compact the high-burst fallback candidate array in place rather than allocate a second filtered array.
- Retain DRR batch-size decisions in an index-keyed side table so the final cost check uses the batch size computed during admission.
- Cache terminal-admission preflight results against both policy revision and selected batch count. Clear private cache metadata before returning terminal items; preserve it for queued or successfully dispatched work where it is still valid.
- Use ID-indexed queue positions and tombstone removals for O(1) queued cancellation and selection removal. Preserve FIFO order during sparse scans, compact in place only when holes exceed a bounded threshold, and keep shadow selectors on dense isolated copies.
- Keep terminal completed/failed history in head-indexed bounded arrays, compacting only after the head passes its bound or backing tail grows beyond twice the limit. Dependency-referenced terminal outcomes remain retained until their final dependency is released.
- Keep the bounded handoff-status cache in a fixed-capacity circular buffer instead of shifting entries from the front.
- Clear inherited-priority links by visiting the completed dependent's bounded dependency list instead of scanning every known work item.

Readiness, dependencies, expiry, admission/backpressure, retries, owner caps, priority inheritance, deadlines, FIFO tie-breaking, urgent streaks, DRR cursor/deficits, and critical/lease-renewal reserves remain authoritative and unchanged.
- Cache each queued item's unresolved-dependency count and failed-prerequisite ID. A reverse dependency index updates only dependents when a prerequisite completes; selection, admission, and scheduler metrics use O(1) readiness checks rather than re-walking every dependency list. Removing or terminalizing a dependent unregisters its waiter entries; dependency-history reference counts remain separately enforced.
- Remove terminal queue items by tombstoning indexed slots rather than shifting the dense array. ID-to-slot lookup makes cancellation O(1); scans preserve FIFO order across holes, and compaction is amortized and order-preserving. Shadow decisions use their own dense isolated queue.
- Keep bounded completed/failed history in head-indexed arrays with amortized compaction, preserving dependency-reference retention, and use a fixed-capacity ring for the bounded handoff-status cache.

### 4. Process-local data structures

- Replace front-removal trace storage with a fixed-capacity circular buffer. Appends and overwrites are constant-time; bounded queries/drains preserve chronological order.
- Use an indexed expiry min-heap and O(1) entry accounting in the read coalescer instead of recounting cache entries and scanning for eviction candidates.
- Keep one private result snapshot shared by cache/in-flight state, while callers still receive defensive copies.

These facilities remain process-local optimizations. They are not new durable messaging features and do not replace DataStore-backed authority.

### 5. PlayerData mutation batching

- Detach pending update batches by swapping the batch table instead of cloning it before each flush.
- Preserve mutations that arrive while an earlier write is uncertain; reconciliation must not overwrite the newest same-field update.
- Keep leave, shutdown, and unknown-write recovery behavior covered by regression tests.

## Luau implementation guidance

- Prefer stable table layouts and dense numeric arrays in hot paths.
- Use `table.create` where the final array size is known and write by index instead of repeated front insertion/removal.
- Avoid temporary candidate-row tables and repeated traversals when existing state can carry the required primitive values.
- Cache expensive structural facts only for private immutable values; never trust mutable public tables or caller references.
- Keep hot-path type dispatch simple, and only use native compilation or lower-level specialized code for pure kernels after profiling on the target Luau runtime.
- Do not assume manual builtin localization, generic loop rewrites, or added caches are faster without controlled measurement.

## Benchmarks and verification

- `scheduler_backlog_scaling.bench.luau`: first `TakeNext` at 128/512/2048/8192 queued entries across FIFO, weighted, deadline, and DRR, including ready, partially-ready, future-blocked, and owner-cap-saturated queues. Queue setup is outside the timed interval.
- `update_validation_pipeline.bench.luau` and `patch_update_pipeline.bench.luau`: matched large-profile mutation/validation workloads.
- `v2_trace_ring.bench.luau` and `v2_read_coalescer.bench.luau`: bounded process-local structure throughput and cache churn.
- PlayerData.Set regressions cover an interleaved newer same-field mutation during uncertain-write reconciliation.
- RecordStore regressions cover Patch atomicity, copy isolation, shape limits, non-finite data, external mutable-Data validation isolation, LastSaved defensive copies, and save/reopen behavior.
- Advanced scheduler regressions exercise sparse cancellation, tail growth, compaction, FIFO order, shadow selection, drain accounting, multi-prerequisite release, cancellation waiter cleanup, and cascading failure/expiry propagation.
- Update-validation regressions exercise recursive Reconcile defaults, detached template ownership, and custom-validator isolation on the reconciliation path.

Lune, Hyperfine, CodSpeed simulation, and mocked stores are diagnostic environments. They do not prove Roblox server-frame-time, garbage-collection, or live DataStoreService improvements. Use Roblox Script Profiler/MicroProfiler and multi-server tests before making those claims.

## Correctness constraints

No speed optimization may weaken persistence durability, fencing, idempotency, admission control, queue fairness, validation, caller isolation, snapshot boundaries, or exact serialization-size checks. Do not introduce background/eventual-consistency queues as a substitute for the current synchronous mutation and durable-save contract.
