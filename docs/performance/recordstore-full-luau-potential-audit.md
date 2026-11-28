# RecordStore.luau: full Luau optimization, redesign, and removal audit

**Audited revision:** main, 8b7acb68429040339094becd1229426a723691b8  
**Target:** src/PlayerDataInitializer/RecordStore.luau  
**Source size:** 26,193 lines, approximately 1.06 MB  
**Compiler directives:** --!strict and --!optimize 2  
**Intent:** complete opportunity inventory and evidence plan; not an unverified source rewrite.

## 1. Executive summary

RecordStore is already substantially optimized. The existing performance program and current implementation include allocation-reduced scheduler selection, indexed sparse queue removal, bounded terminal history, dependency waiter indexes, fused terminal-preflight/priority-inheritance work, detached copy/shape validation, copy-on-write Patch, bounded process-local structures, and paired large-profile mutation benchmarks.

The next gains are not likely to come from mechanically changing every loop, localizing every builtin, or adding caches everywhere. The highest-value remaining questions are:

1. Whether scheduler selection and completion still do more whole-queue work than their invariants require.
2. Whether DRR lane ordering and service-time percentile calculations can avoid repeated sorting and lookup.
3. Whether Mailbox V2 and Durable Streams perform bounded scans/sorts that are material at realistic segment and queue sizes.
4. Whether profile copying, validation, canonicalization and persistence preparation can share more private, already-proven facts without weakening alias isolation or exact validation.
5. Whether optional subsystems should remain embedded, be split behind lazy factories, or be removed only after public API and persisted-data compatibility are proven.
6. Whether selective native compilation of pure compute kernels provides a measurable benefit in Roblox, rather than only in Lune.

No source-level optimization is declared a guaranteed speedup by inspection alone. Each implementation proposal has a measurement requirement and the correctness properties it must preserve.

### Priority scale

| Priority | Meaning |
|---|---|
| P0 | High-value investigation; likely to reduce repeated hot-path work if its invariant can be maintained safely |
| P1 | Strong candidate, but dependent on workload/cardinality or proof that the extra index/cache is cheaper |
| P2 | Worth testing after P0/P1; likely smaller or highly workload-specific |
| Conditional | Redesign/removal only after API, usage, persisted data, rollout and rollback evidence |
| Keep | Existing optimization or correctness mechanism that should not be removed as superficial complexity |

## 2. Scope and method

The complete current source blob was read and divided by implementation area. Function/type declarations, loops, table operations, pcall boundaries, sort sites, service calls and repeated helper definitions were inventoried. Focused code ranges were inspected around scheduler selection/completion, copy and validation, serialization, backend UpdateAsync, record mutation/save, mailbox indexing/claiming, and durable stream publish/consume.

Repository engineering rules, README behavior and the existing performance program were treated as constraints. Existing benchmark and regression files were inspected to distinguish implemented work from unmeasured opportunities.

This is a source-and-benchmark-definition audit, not a live Roblox profile. It does not claim production CPU, GC, DataStore latency, request-budget or multi-server behavior has been measured.

## 3. Module map

| Source range (approx.) | Responsibility | Main performance characteristics |
|---|---|---|
| 1–3,300 | Embedded scheduler governor, policy/admission, FIFO/weighted/deadline/DRR selection, queues/heaps, dispatcher, metrics and retry state | Repeated selection scans, per-lane ordering, bounded histories, scratch reuse |
| 3,301–8,026 | Embedded Mailbox V2: manifest/segment allocation, route registry, reservation/order protocol, append indexes, claims, lease renewal, processing, recovery and dead letters | DataStore UpdateAsync boundaries, bounded segment/index reads, ordering scans/sorts, defensive decoding |
| 8,027–11,919 | Metadata, copy/shape validation, non-finite sidecars, canonicalization, envelope codecs, backend adapters, cache/budget admission and legacy queue compatibility | Recursive traversal, serialization, cloning, canonical ordering, protected service calls |
| 11,920–17,763 | Save/read/version/erasure/quarantine, record mutation, open/close, lease renewal, uncertain-write reconciliation | Correctness-dominated UpdateAsync transforms, snapshots, retry/reconciliation state |
| 17,764–18,437 | Scheduler activation and binding to RecordStore profile work | Scheduler integration, rollout and durability status |
| 18,438–22,467 | Patch, transactions/inbox/outbox, diagnostics, profile doctor/diff, migration preview/registry, mock support and SHA-256 | Path traversal, reducers, digesting, bounded receipts and optional APIs |
| 22,468–26,193 | Durable Streams, producer, worker and transient messaging | Payload cloning/validation, segment scans/integrity, consumer checkpoint/lease, advisory wakeups |

The scheduler and Mailbox V2 implementations are intentionally embedded in this ModuleScript according to the current repository design. This audit does not recommend moving either one out of the file against that contract.

## 4. All Luau optimizations

This section distinguishes existing optimizations from remaining candidates.

### 4.1 Scheduler selection and DRR

#### Existing work to preserve

- FIFO selection tracks best eligible indexes without materializing one candidate record per queue entry.
- Non-FIFO candidate storage uses dense numeric queue indexes and reusable scratch.
- High-burst filtering compacts candidate buffers in place.
- DRR reuses lane-row storage and keeps selected batch counts for the final cost check.
- Queue IDs map to sparse slots; removal tombstones slots and compaction is amortized and order-preserving.
- Terminal preflight has its own candidate index and bounded compaction policy.
- Completed/failed history is bounded with head-indexed storage and dependency-reference retention.
- Dependency waiter indexes update dependent readiness when prerequisites transition.
- Scheduler hot-path regressions protect against accidentally consulting diagnostic snapshots while dispatching ordinary work.

#### P0: remove repeated whole-queue work from completion-time DRR cleanup

**Location:** governor MarkCompleted, approximately lines 2,367–2,385.

When DRR deficits exist, completion rebuilds the active lane-key set by scanning the full queued array and then all known in-flight work, before deleting deficits whose lanes are no longer active.

**Candidate:** maintain private active-lane reference counts or equivalent lifecycle-owned membership as items enter/leave queued and in-flight states. Completion could then retire a deficit when its lane's live count reaches zero without rescanning the queue and all known items.

**Required proof:**

- Every enqueue, cancellation, expiry, admission rejection, selection, retry/reschedule, completion and shutdown transition updates membership exactly once.
- A queued-to-in-flight transition cannot double-count or temporarily disappear.
- Effective lane keys account for inherited priority and time-based expiry of inherited priority. A cached key is unsafe if scheduled_lane(item, now) changes without a queue mutation.
- DRR deficit lifetime, fairness, cursor movement and cleanup semantics remain identical.
- Add state-machine/property tests comparing the indexed version against a simple reference implementation over randomized transitions.

**Measurement:** completion cost at 0, 1, 16, 256, 2,048 and 8,192 queued/in-flight items, with both one and many distinct lanes. Include allocation and GC measurements. Keep the index only if completion improves enough to justify lifecycle bookkeeping.

#### P0: reduce DRR lane-key sorting and cursor lookup

**Location:** `choose_index`, approximately lines 1,379–1,449; especially lane grouping, sorting and cursor lookup.

**Implemented narrowly:** the effective lane is computed once while the selector checks current eligibility and is passed into `lane_key` for that same selection. The key builder no longer calls `scheduled_lane` a second time for each admitted candidate. This is selection-local only: no lane identity is cached across calls, so inherited-priority expiry is still re-evaluated against the current `now`.

**Kept:** lane keys are still sorted lexicographically and the cursor still uses binary search over that same sorted list. This preserves deterministic ordering, cursor rotation, stale-cursor fallback and time-dependent inheritance semantics.

**Measured next:** `bench/drr_lane_cardinality.bench.luau` varies queue depth (128–8,192) and distinct lane cardinality (1–2,048) independently. Queue construction is outside the timed selection. A persistent ordered-lane structure remains deferred until these measurements and a mutation/expiry reference model justify its additional lifecycle state.

#### P1: cache service-time P95 rather than sorting samples during candidate scoring

**Location:** estimated_service_time_ms, approximately lines 1,157–1,170; sample-window update helpers near the beginning of the module.

The scoring path obtains sample-window values, sorts them, and selects the P95 element. A selection may score multiple candidates from the same operation class; a per-selection cache avoids duplicate work within that call, but a later selection recomputes the percentile.

**Candidate:** update an exact or bounded-approximation percentile summary when observations enter the fixed-size sample window, or cache a versioned percentile per operation class and refresh it when the sample window changes.

**Required proof:** match the existing sample-window eviction and percentile definition, preserve empty/single-sample behavior, and invalidate cached percentiles on every window mutation/reset. Do not silently replace exact P95 with an approximation.

**Measurement:** weighted/deadline selection with 1, 8, 32 and maximum supported operation classes; small and full sample windows.

#### P1: reduce repeated candidate state evaluation only where it can be made current

**Location:** `choose_index` around lines 1,263–1,371 and `TakeNext` around lines 1,980–2,128.

**Implemented narrowly:** DRR grouping reuses the effective lane already computed for eligibility in the same pass. It does not cache due time, expiry, dependencies, admission, owner caps, renewal constraints, request budgets, or batch sizes. The final admission decision remains authoritative.

**Do not:** replace readiness with a stale heap key, trust preflight after policy or batch changes, or skip the final authoritative admission check.

**Measurement:** first-selection scaling and the new independent queue-depth × lane-cardinality matrix; dynamic budget/policy/dependency/expiry/owner cases remain in the scheduler regressions.

#### P2: bound DRR rounds using an explicit mathematical invariant

**Location:** DRR selection around lines 1,415–1,450.

**Implemented:** the loop now uses `ceil(max_item_cost / drr_quantum)` rounds instead of adding two unexplained extra rounds. The minimum effective lane weight is 1 and the minimum service weight is 1, so every complete round adds at least one quantum. Admission rejects any selectable item whose cost exceeds `max_item_cost`; the deficit cap is twice that maximum and therefore cannot saturate below the required cost. Existing deficits are nonnegative, so a carried deficit can only reduce the rounds required.

**Regression:** `bench/run_advanced_scheduler_regression.luau` covers a minimum-weight background/best-effort lane at quantum 1 and configured maximum cost 32. The work class and tracing operation are chosen so the item reaches DRR rather than being rejected by an unrelated class-admission cap. Fairness and cursor advancement are unchanged.

#### Keep: reverse terminal preflight scan until a replacement proves exact ordering

The existing performance program correctly calls out the reverse terminal-preflight scan as remaining. A heap or alternative index is not a drop-in replacement because newest-queued terminal outcomes, expiry, dependency failures and policy/batch admission rejections have observable ordering and removal semantics. Optimize only with a reference-model proof and mixed-terminal regression matrix.

### 4.2 Mailbox V2

#### Existing behavior to preserve

Mailbox V2 uses sharded routing, generation-bearing locators, bounded manifests/segments, reservations, explicit ordering state, claims with leases, idempotent acknowledgements, dead-letter transitions and maintenance/recovery paths. DataStore-backed state remains authoritative; Messaging/MemoryStore wakeups are hints only.

#### P1: audit index scans and order reconstruction against actual configured bounds

Relevant functions include:

- _open_segment (around line 4,186)
- _set_registry_entry / _get_registry_entry (around lines 4,305–4,357)
- _reserve (around line 4,376)
- _ensure_ordering_slot, replay ordering and _ordering_blocked (around lines 4,629–4,951)
- _append_index / _contains_index_row (around lines 5,042–5,065)
- _resume_reservation (around line 5,078)
- process_next_internal (around line 6,274)
- RecoverAsync, dead-letter listing/replay, stats and maintenance (around lines 6,443–6,905)

Some paths rebuild or sort route/message candidates. First establish the maximum number of manifest slots, index rows, messages per segment, pending routes and dead-letter rows for the relevant method. A sort over a deliberately small bounded segment may be preferable to a more complex index.

**Candidate:** retain a stable ordering/index field at append time and update it atomically with the authoritative row; use it to reduce repeated reconstruction only when the bound is large enough to matter.

**Required proof:** reservation replay, ordering-key sequencing, cross-route ordering, duplicate detection, claim lease fencing, dead-letter replay and crash recovery remain deterministic. No reader may delete shared MemoryStore hints or treat advisory wakeups as durable work.

#### P1: avoid redundant per-route or per-segment validation work

**Candidate:** fuse validation with the copy already required at the read/write boundary, and carry only private validated representations between local helper calls. Cache route/slot facts only within a single operation or behind a manifest-generation key.

**Required proof:** never reuse a cached manifest/registry when a fresh read is required for ownership, generation, reclamation or recovery. UpdateAsync transforms remain pure, deterministic and replay-safe.

#### P2: review queue ordering sort in ProcessNext and dead-letter pagination

**Location:** around lines 6,274–6,335 and 6,600–6,649.

The processing path obtains candidates and sorts them before selecting. The dead-letter path also sorts returned messages. Determine whether input is already ordered by a validated index and whether sorting is necessary for the public order contract. Remove a sort only if source order is proved stable and equivalent under retries, replays and partial page boundaries.

### 4.3 Copying, shape validation and serialization

#### Existing work to preserve

- Strict mode and bounded recursive copy/shape validation.
- Rejection of cycles, unsupported types/keys, mixed array/dictionary keys, sparse arrays, excessive depth/nodes and overlong strings.
- Versioned non-finite-number sidecar paths, with lazy copy-on-write cloning of only branches that contain a replaced value.
- Exact JSON serialization as the final serialized-size authority.
- Custom validators receive isolated input; public data and last-saved snapshots retain ownership boundaries.
- Patch uses copy-on-write private ancestors and private subtree summaries.

#### P0: profile remaining copy/validate/encode traversals by operation

Relevant locations include copy helpers around lines 8,156–8,415; non-finite encoding/restoration around lines 8,415–8,639; canonicalization and event identity around lines 8,776–9,010; serialized-size/value validation around lines 8,914–9,450; Update around lines 14,276–14,360; Reconcile around lines 14,363–14,600.

**Candidate:** introduce an internal, short-lived prepared-value descriptor for operations that already have a detached private tree. It may carry shape facts (node count, max depth, non-finite presence, table-key kind) and exact serialized length only when that exact value has been encoded. Reuse those facts in the same operation rather than rescanning the same detached value.

**Required proof:**

- No fact derived from a caller-owned mutable table is reused after control returns to the caller.
- A custom validator still receives its own isolated input.
- A cached subtree summary applies only to private immutable subtrees; weak-key metadata must not outlive its owner or cross mutation boundaries.
- Lower bounds may only early-reject; exact JSON encoding still decides the DataStore byte limit.
- Sidecar protocol bytes, marker paths, envelope formats and old-version readability remain unchanged.

#### P1: reduce non-finite sidecar restore overhead

**Location:** restore_non_finite_numbers, around lines 8,501–8,639.

The code validates marker and path array density, validates every segment and then walks each path to place the restored value.

**Candidate:** validate the marker collection and all path structures in one pass into a private validated marker representation, then perform replacement from that representation. If several markers share a long prefix, consider a prefix walk/trie only when marker counts and shared-prefix distributions justify the extra structure.

**Required proof:** malformed markers remain rejected before partial public publication; duplicate/overlapping paths, root scalar markers, wrong placeholder values and array/dictionary segment mismatches retain exact behavior.

#### P1: remove redundant canonicalization and digest preparation

**Location:** canonicalization/stable identity functions around lines 8,776–9,010; SHA-256 implementation around lines 22,059–22,175; Durable Streams integrity functions around lines 22,587–22,690.

**Candidate:** share one canonical byte representation inside a single private operation when the same payload is both validated and hashed. Explore incremental hashing only if the canonical byte stream remains byte-for-byte stable.

**Required proof:** no unordered table traversal, locale/runtime-dependent formatting or key sorting changes canonical identity. Preserve existing digest known-answer vectors and persisted integrity compatibility. Do not cache a digest for a mutable payload without an immutable ownership/version key.

#### P2: reduce recursive allocation where output shape is already known

**Location:** copy/encoding paths around lines 8,293–8,415 and 8,421–8,499.

Investigate bounded array preallocation and temporary table reuse only in places with a known array size. Luau table.create preallocates the array part only; it is not an optimization for dictionaries. A two-pass count followed by table.create can cost more than the current single pass, so compare it under realistic shapes.

Do not rewrite all table traversals to numeric index loops: Luau optimizes generalized table iteration, pairs and ipairs; ipairs has different nil-termination semantics. Use generic iteration where supported by the repository's Roblox/Luau compatibility target and keep ipairs where its dense-array semantics are intentional.

### 4.4 Record mutation and persistence

#### Keep: safety boundaries are not expendable overhead

- Record:Update enforces non-yielding callback behavior, works on a detached candidate, validates before publishing, and isolates public mutable data.
- Save/close operations snapshot data, validate, run replay-safe UpdateAsync transforms and verify ambiguous writes before declaring success.
- Unknown outcomes retain operation identity and snapshot state for later reconciliation.
- Lease ownership, fencing generation, revision, user IDs and metadata are authoritative.
- Fresh/uncached reads are required for ownership and reconciliation decisions where the repository contract says so.

#### P0: profile the complete Save/Update path by stage

**Location:** update around lines 14,276–14,360; save_internal around lines 11,920–12,172; backend_update around lines 9,581–9,691; open/lease/recovery around lines 15,671–17,763.

Break the in-memory and platform operation into named measurements: external mutation detection, working-copy creation, callback, result-copy/shape validation, custom validator, non-finite encoding, exact JSON encode, UpdateAsync transform, returned envelope verification, uncertain-result reconciliation, public/baseline snapshot publication.

**Candidate:** only fuse stages when the same private object is already detached and the output proves all required validation facts. Keep the callback coroutine-yield check, custom-validator isolation and final exact JSON check.

**Measurement:** compare Update, Patch, Reconcile, Save, Close and Open on the same large-profile fixtures and data shapes; include no observers, observers, non-finite paths, custom validator, externally mutated Data and unknown write outcomes.

#### P1: consider an internal typed mutation-preparation pipeline

An explicit internal stage record could make ownership and validation facts clearer and prevent repeated traversals. It must not become a general mutable cache or cross operation boundaries. Compare total code complexity and allocations before keeping it.

#### P2: review timeout and cancellation plumbing only after fault-injection coverage

Coroutines, pcall boundaries and yields around service calls are part of the safety design. Simplification is acceptable only if cancellation, deadlines, request slots, lock release, task teardown and unknown outcomes remain tested.

### 4.5 Durable Streams, Publisher, Worker and Transient Messaging

Relevant implementations:

- Durable Streams factory and open path around lines 22,276–23,165.
- Head/segment/registry reads and maintenance lease around lines 23,175–23,460.
- Event preparation, producer-sequence resolution and batch publish around lines 23,460–24,000.
- Consumer-group and retention handling around lines 24,001–24,695.
- Claim/renew/checkpoint/consume/release around lines 24,696–25,183.
- Publisher around lines 25,184–25,562.
- Worker around lines 25,563–25,984.
- Transient messaging around lines 25,985–26,193.

#### P1: benchmark producer/idempotency lookup by segment occupancy

Publish paths search event IDs and producer IDs/sequences in retained segment messages. Cost is bounded by storage protocol limits, but may grow with segment size and batch size.

**Candidate:** retain a bounded per-segment event/producer lookup structure or compact producer-sequence checkpoint only if it reduces repeated scans without adding per-event writes or unbounded durable state. The existing producer sequence checkpoint and single-UpdateAsync batch append contract must not be weakened.

**Required proof:** duplicate retries after pruning, changed-content conflicts, sequence gaps, historical retries, rollover, checkpoint recovery and batch atomicity all remain correct.

#### P1: reduce integrity recomputation only with a stable private representation

Segment/head integrity and producer-state digests protect persisted correctness. Consider reusing canonical material only inside one operation or a versioned immutable segment. Never trust a stale digest for mutable state.

#### P1: benchmark consumer checkpoint and retention operations at maximum supported fanout

Measure consumer groups per stream, partitions, retained segments, batch size and concurrent claimants. Check group registry scans, cursor update fanout, retention floor calculations and tombstone/lease maintenance. Keep fencing generation and retention lease checks authoritative.

#### P2: unify repeated payload helpers when contracts truly match

The file contains repeated local functions for finite numbers, text validation, integer bounds, payload cloning/normalization and result notification across Durable Streams, publisher, worker and transient messaging. Some signatures differ deliberately (copy/no-copy modes, node/depth limits and notification shapes).

A shared helper is a candidate only after a side-by-side semantic comparison, common test vectors and a benchmark. Do not merge helpers simply because their names match.

#### Keep: transient messages remain advisory

Transient Messaging wakeups must not become a durable source of truth or required for consumer progress. Keep polling/recovery independent of notification success.

### 4.6 Native compilation and compiler-aware Luau style

The file already requests compiler optimization level 2. It contains no @native attributes or --!native directive at the audited revision.

**P1 investigation:** profile isolated pure compute kernels in actual Roblox: SHA-256 word/round operations, canonical string/hash preparation, numeric deadline scoring and bounded primitive validation loops. Add @native only to a function where Script Profiler/MicroProfiler shows meaningful CPU cost and Roblox measurements show a stable win.

**Do not** mark the whole 26k-line module native by default. Most code is service orchestration, table traversal, allocation, callbacks and yielding; native compilation is not a substitute for reducing those costs.

Compiler-aware rules:

- Keep --!optimize 2; let the compiler decide inlining/unrolling.
- Prefer stable table layouts and table literals for object-like records.
- Use table.create for known array capacity, not dictionaries.
- Do not replace generalized iteration with pairs/ipairs or numeric loops on intuition alone; compare equivalent semantics under Luau.
- Manual localization of builtins should require measured proof.
- Avoid extracting tiny local helpers from hot loops unless profiling and generated/native code inspection show call overhead is material.
- Do not assume closure-caching heuristics for functions with mutable or changing upvalues.

## 5. All redesign candidates

These are architectural alternatives, not permission to break the current API or storage format.

### R1. Scheduler index topology

Consider a coherent internal index model for live queued lanes/DRR deficit ownership, cursor position in ordered lane keys, operation-class rolling P95, terminal-preflight candidates, operation metric preflight, and ready/wake/retry/expiry queues.

Keep existing bounded arrays/heaps where their workload is small. Avoid multiple overlapping indexes for the same fact. Document each index's authoritative source, update sites, invalidation keys, maximum size and recovery/rebuild strategy. Benchmark maintenance cost as well as selection savings.

### R2. Prepared record-value pipeline

Consider one ephemeral internal prepared-value abstraction with explicit ownership state: detached candidate, shape validated/measured, non-finite presence known, custom validator completed, encoded snapshot ready, exact serialized size verified.

A stage may consume only facts produced by earlier stages. Public mutable Record.Data and caller-owned values must never become trusted cached inputs. Preserve all envelope/sidecar and validator semantics.

### R3. Mailbox V2 index and storage layout

Consider a durable index/manifest representation that lowers bounded route/placement scans. It must keep append reservation, ordering sequence, idempotency, segment generations, claim fencing, dead-letter state and compaction atomic across retryable UpdateAsync transforms. Any additional persistent index has write-amplification and migration cost; benchmark and model it explicitly.

### R4. Durable Streams boundaries

The module exports separate DurableStreams, DurableStreamPublisher, DurableStreamWorker and TransientMessaging surfaces. Evaluate whether these optional subsystems should become lazily required child modules while the public RecordStore facade remains compatible.

Required evidence: cold require time, module compile/bytecode memory, first-use latency, server memory and steady-state CPU; exact API/ref compatibility and require graph; no accidental shared mutable state between factory instances; Studio/Rojo hierarchy compatibility.

Keep scheduler and Mailbox V2 embedded per existing architecture contract.

### R5. Optional diagnostics, migration and application services

The core contains profile history/doctor/diff/migration facilities, transaction receipts, inbox/outbox sidecars, queue compatibility and mock adapters. Evaluate module boundaries or lazy initialization for optional features whose code is not used by normal profile open/update/save.

Do not remove a supported API simply because it is not called by the default PlayerDataCore. It may be used by downstream games, Studio tools, offline maintenance and applications.

### R6. Type-safe internal state model

Replace broad dynamic scheduler records and loosely typed result tables at narrow internal boundaries with named records/tagged result unions. Prioritize scheduler policy/item, mailbox locator/reservation/claim, backend result, prepared envelope and durable stream head/cursor/segment.

Do not attempt a 364-occurrence mechanical any removal. Some dynamic API/Roblox/adapter boundaries legitimately start as unknown and require runtime validation. Keep casts narrow and validate at the boundary.

### R7. Canonical codec and digest ownership

Consider an explicit internal codec boundary shared by profile envelope sidecars, stable event IDs and Durable Streams integrity. Keep versioned formats stable and ensure public serialized output remains byte-for-byte compatible. Proceed only if it reduces duplicate traversal/code and does not create a generic abstraction with more complexity than the duplicated implementations.

### R8. Operation orchestration and result modeling

Review duplicated operation lifecycle logic across save, lease release, mailbox claim, durable consumer claim, publisher flush and worker stop. A common state-machine utility may improve observability and correctness, but only if cancellation, owner, lease, timeout, idempotency and unknown-outcome rules actually align. Otherwise keep distinct, explicit state machines.

## 6. All removal candidates

**No feature is approved for unconditional removal by this source-only audit.** Each candidate must first have usage, compatibility and durable-data evidence.

| Candidate | Why removal or isolation may be worthwhile | Evidence required before deletion |
|---|---|---|
| Legacy queue envelope/key/handoff compatibility | Reduces migration/compatibility branching and code paths | Inventory live stores, migration completion, rollback horizon, old-version servers, repair plan, regression fixture for unsupported legacy state |
| Legacy Mailbox V2 import/replay compatibility paths | May be obsolete after every installation migrates | Per-installation migration status, no active old producers/consumers, preserved dead letters/operation IDs, rollback/restore proof |
| Duplicate payload validation/clone helper copies | Reduces maintenance and duplicate code | Prove identical depth/node/byte/error/ownership semantics; consolidate before considering deletion |
| Unused scheduler algorithms or policy options | Reduces algorithm branches, configuration matrix and testing burden | Search all callers/examples/stored config; observe rollout/production configuration; maintain API compatibility or version explicit removal |
| Shadow scheduler / trace replay / diagnostic surfaces | Could lower memory and branches in production | Confirm observability/support requirements; compare disabled overhead; move to optional diagnostics module rather than deleting if operationally valuable |
| Profile doctor, version diff, migration preview | Likely cold-path tooling | Check downstream callers, support workflows, operators, examples and Studio usage; consider lazy module boundary first |
| Transactions/inbox/outbox features and sidecar receipt state | Reduces core complexity and durable envelope overhead if unused | Prove no callers, no retained receipt/sidecar data requiring replay, no API consumers, no migration dependency, no purchase/event integration |
| Durable Streams, publisher, worker | Optional event-stream surface is distinct from profile persistence | Usage telemetry, product commitment, downstream API search, persistent stream inventory, consumer release/retention plan; split/lazy-load before deletion |
| Transient Messaging | Wakeup feature may be unnecessary where polling suffices | Verify no production users rely on wake-up latency, confirm polling bounds/cost, keep advisory-failure tests |
| Mock backends/test-only hooks in runtime source | Could reduce runtime module size and production code | Audit public Mock APIs and test harnesses; move behind a supported test-only build boundary only if Studio/library consumers keep a test interface |
| Compatibility aliases/wrappers/public exports | Fewer branches and smaller API surface | Full package/downstream search, version/deprecation policy, persisted data implications, docs/migration guidance |

A removal must include exact symbol/caller inventory, evidence that no supported consumer requires it, persisted-data and rollback assessment, migration/deprecation plan, tests for the new unsupported/removed state, and docs/API version decision.

## 7. Type-check and static-analysis opportunities

1. Preserve --!strict and --!optimize 2; do not disable solver-sensitive types to force a pass.
2. Audit 364 textual any occurrences by trust boundary and call frequency. Replace internal state shapes first; keep unknown at untrusted API/Roblox boundaries and validate before narrowing.
3. Introduce tagged result unions for high-risk state transitions (backend result, save reconciliation, lease operation, mailbox claim/reservation, durable stream consume) where it eliminates ambiguous combinations of booleans and optional fields.
4. Type the internal scheduler item, policy and metrics structures rather than routing the governor through a string-keyed dynamic table.
5. Type Durable Streams head/segment/cursor/registry and publisher/worker contracts without exposing new mutable internals publicly.
6. Keep tests and Lune fixtures explicitly separate from production strict typing. A test's --!nocheck is not evidence that the source is type-safe.
7. Add static checks for UpdateAsync-transform purity/forbidden yields and accidental use of MemoryStore/Messaging as durable authority if a reliable lint/AST rule can enforce them.

## 8. Bug, correctness and security review matrix

These invariants are acceptance requirements for every implementation change; verify them through focused state-transition tests and the repository's required runtime checks, not style-only changes.

| Area | Required checks |
|---|---|
| UpdateAsync | Deterministic, non-yielding transform; no service calls, locks, task scheduling, mutable closure state or external side effects; safe when Roblox replays the transform |
| Unknown writes | Lost acknowledgement remains unknown; authoritative fresh read and stable operation/write ID reconcile it; no blind duplicate mutation |
| Sessions | Lease margin, fencing generation, stale owner rejection, stale release rejection, renew/reacquire races, BindToClose and PlayerRemoving |
| Corruption/versioning | Corrupt, unsupported, future-schema and legacy data fail closed; no silent default reset; quarantine and explicit recovery remain fenced |
| Mutable data | Detached Record.Data, Update candidate, validator input, LastSaved and event snapshots; direct mutation tracking; no leaked shared subtree |
| Serialization | Exact JSON bytes, dense arrays, depth/node/string limits, cycles, unsupported key kinds, root scalar and nested non-finite paths, marker corruption |
| Scheduler | FIFO order, DRR fairness/cursor, batch admission, high-burst, urgent/deadline starvation bounds, dependency propagation, retry/expiry, owner caps and reserve slots |
| Mailbox V2 | Ordering slot fencing, reservation replay, sequence allocation, segment reclamation, deduplication, claims/renewal, ack/retry/dead-letter/replay, multi-server recovery |
| Durable Streams | Producer identity/sequence, changed-payload conflict, batch atomicity, segment rollover, retention fence/floor, consumer claim/checkpoint and duplicate delivery |
| Transient messaging | Notification loss/duplication is harmless; durable poll/reconcile still makes progress |
| Privacy/erasure | User-id coverage, erasure generation/fencing, quarantine release, version purge and manifest binding |

Any suspected bug found during implementation must get a focused red/green regression before its fix is accepted. Do not infer correctness from type-check or benchmark success.

## 9. Benchmark and verification plan

### Existing assets to reuse

- scheduler_backlog_scaling.bench.luau: first TakeNext at queue sizes 128/512/2,048/8,192 across FIFO/weighted/deadline/DRR, with readiness and dependency scenarios; setup is outside the timed interval.
- run_scheduler_hot_path_regression.luau: dispatch path stays off diagnostic snapshot work for regular and batchable work.
- update_validation_pipeline.bench.luau and patch_update_pipeline.bench.luau: matched nested-profile shape, mutation count and touched paths.
- copy_traversal_baseline.bench.luau: direct mutable Data capture and save/reopen.
- run_advanced_scheduler_regression.luau: fairness, admission, retry, dependency, expiry, shadow, trace, batching and queue-index regressions.
- run_production_adapter_safety_regression.luau: cache behavior, UpdateAsync replay, ambiguous writes and release reconciliation.
- Mailbox V2 ordering/migration, acceleration and Durable Streams regression runners.
- Canonical CI: .github/workflows/luau-regression.yml and .github/workflows/luau-typecheck.yml.

### New paired measurements to add as each optimization is implemented

1. Scheduler: queue depth × distinct lane count × readiness ratio × dependency count × budget churn; record selection and completion separately.
2. Mailbox: segment occupancy × route count × ordering-key fanout × claim contention × recovery/replay state.
3. Copy/validation: profile size, table shape, non-finite density, custom validator, observer count, direct mutation and Patch touched-path ratio.
4. Persistence: separate local prep, mock UpdateAsync and real Roblox DataStore timings; capture request-budget waits and uncertain-outcome path.
5. Durable Streams: messages per segment, batch count, producer cardinality, consumer groups, partitions, retention and replay.
6. Runtime footprint: cold require time, module compile/bytecode memory, first-use latency, memory before/after require and steady-state allocation/GC.
7. Roblox behavior: Script Profiler and MicroProfiler traces under representative server load, including shutdown and multi-server ownership tests.

For every change:
- compare baseline and candidate on the same commit/runner/input distribution;
- report median and tail values, not only fastest run;
- include allocations/GC or a proxy where possible;
- include worst-case correctness/fault tests in addition to performance measurements;
- define a regression threshold before accepting the optimization;
- revert ideas that do not beat the baseline or require materially more complexity.

Lune, local mocks and hosted CPU simulations do not prove Roblox VM native compilation, live DataStore caching/throttling, MemoryStore TTL semantics or MessagingService delivery. Those require Roblox runtime acceptance.

## 10. Implementation verification

Per the explicit instruction for this continuation, no independent reviewer is being invoked and no review approval is claimed. Implementation verification is based on the repository's strict Luau type-check, focused regressions, the full regression workflow, and paired benchmark runs. These checks are distinct from Roblox Studio/MicroProfiler acceptance. No live Roblox performance claim is made here.

## 11. Ordered implementation roadmap

### Phase A — establish baselines
- Preserve the current main commit as the benchmark base.
- Capture baseline timings for scheduler completion, DRR selection, P95 scoring, mailbox candidate ordering, Update/Patch/copy-validation and Durable Streams lookup.
- Add only missing focused benchmark inputs; do not rewrite runtime code in the baseline PR.

### Phase B — scheduler hot paths
- Prove active-lane reference counting and cursor/lane ordering behavior in a reference model.
- Measure P95 refresh alternatives.
- Keep existing arrays/heaps until the candidate wins under all relevant queue distributions.

### Phase C — mailbox and durable stream indexing
- Map every scan/sort to a real collection bound and storage request.
- Prototype one bounded index at a time.
- Fault-inject reservation replay, duplicate publish, claim expiry, retention and recovery.

### Phase D — copy/validation and mutation pipeline
- Use paired Update/Patch and direct-mutation benchmarks.
- Fuse only private detached-value stages with explicit ownership.
- Keep exact serialization and custom validator contracts.

### Phase E — typing and module boundaries
- Replace dynamic internal types incrementally at narrow seams.
- Test optional lazy-loading seams for Durable Streams and diagnostic/application surfaces without moving the scheduler or Mailbox V2.
- Do not change public API or persisted formats without a separately reviewed compatibility plan.

### Phase F — native and removal decisions
- Profile pure kernels in Roblox; selectively try native compilation only after baseline.
- Decide removal candidates with actual downstream usage and stored-data evidence, not code volume.

## 12. Phase A–C implementation progress

The following items have now been implemented on this audit branch. The original main revision and its benchmark inputs remain the comparison base; results are not described as a speedup until the current paired benchmark job finishes.

### Phase A — baselines

- Reused the existing `lease_renewal_advice` benchmark, which repeatedly queries the same latency sample windows, to exercise P95 cache reuse.
- Reused the existing `durable_stream_publish_batch` workload with 64-message segments and 16-message batches to exercise segment lookup at increasing occupancy.
- Added focused regression coverage for exact P95 behavior after the 256-entry sample ring wraps, DRR cursor movement, and large mixed-producer stream batches.
- CI runs the new tests on the PR branch. The Bencher report for commit `30e0244df8b112d328b9b00e7688735c08b4b949` has now published. Existing paired workloads include scheduler, lease-renewal and large-profile comparisons; the new Update/Patch validation workloads have measurements but no baseline samples yet. The precise results and limits are recorded in Section 13.

### Phase B — scheduler hot paths

- **Implemented:** exact P95 values are memoized per latency sample-window revision. Every accepted sample append/overwrite advances the revision; repeated service-time scoring and lease-renewal advice reuse the cached value until the window changes. The 256-sample capacity and percentile rank calculation are unchanged.
- **Implemented:** DRR's cursor lookup uses binary search over the same lexicographically sorted lane-key list. Cursor rotation, missing-cursor fallback and lane sort order remain unchanged.
- **Implemented:** DRR candidate collection reuses the effective lane already computed for the current eligibility pass; it does not persist a time-sensitive lane key or skip per-selection checks.
- **Implemented:** the DRR round bound is exactly `ceil(max_item_cost / drr_quantum)`, backed by a maximum-cost/minimum-weight regression.
- **Deferred:** completion-time active-lane reference counts. Effective lane assignment can change as inherited priority expires, independently of queue membership. A lifecycle-maintained counter is unsafe until time-dependent lane identity can be represented and tested correctly.
- **Deferred:** replacing the sorted lane-key structure. The new queue-depth × lane-cardinality diagnostic measures its cost before any more complex ordering structure is considered.

### Phase C — Mailbox V2 and Durable Streams

- **Implemented, measured conservatively:** Durable Streams builds temporary event-ID and producer-sequence maps only when `segment.messages * prepared_batch_size >= 1536`; smaller combinations retain linear scans. The initial 64-case scan/index sweep included index construction in each indexed repetition. At the old product-256 boundary, indexing won only 1 of 12 shape/workload cases; all below-boundary cases favored scanning. At products 1536 and 2048, all eight then-measured cases favored indexing. The cutoff was raised to 1536, the smallest tested product where the original matrix consistently favored indexes. The revised 80-case sweep separates real producer retries (reusing the stored event ID and producer sequence) from producer-sequence conflicts (fresh event ID, existing producer sequence), and retains a mixed duplicate/conflict workload. This remains a provisional Lune-derived threshold, not a Roblox VM or production DataStore performance guarantee.
- **Implemented:** the transient maps preserve first-match behavior and the existing distinction between event-ID conflicts and producer-sequence conflicts. Regression coverage exercises a 48-message segment, mixed producer/non-producer batches, commit-then-error reconciliation, same-event-ID retries, changed event payload and producer-sequence identity conflicts.
- **Threshold measurement:** `bench/durable_streams_index_break_even.bench.luau` compares linear scans with index construction plus indexed lookups; build cost is included and sample order alternates. The corrected 80-case Lune run found 13 indexed wins in the 70 cases below product 1536, while all five scenarios favored indexing at product 1536 and all five favored it at product 2048. The 1536 cutoff is therefore the lowest tested product with an across-scenario win; it remains evidence for this Lune workload, not a Roblox VM or live DataStore guarantee.
- **Implemented:** Mailbox V2 uses one module-local priority-rank table instead of allocating a rank table per queue read/process call, and preallocates the bounded queue snapshot array from the observed index-row count. Age-based priority promotion, high-priority burst limiting, FIFO tie-breaks, claims and recovery order are unchanged.
- **Deferred:** persistent Mailbox route/segment/order indexes and changes to candidate sorting. Queue order is dependent on age, high-priority burst state and durable claims; no persisted index is introduced without a separate ordering and recovery proof.

### Explicitly unchanged

No DataStore key, persisted envelope/segment/sidecar format, public API, lease/fencing contract, UpdateAsync replay rule, or durable idempotency rule was intentionally changed. The embedded scheduler and Mailbox V2 remain embedded as required by the repository design. The subsequent Phase D–F findings and evidence-gated implementation decisions are recorded in Section 13.

## 13. Phase D–F continuation findings and implementation decisions (2026-11-28)

**Implementation input revision:** `6586b2083f3c57621afdcea4b05b8f007e07bad0`. The consolidated source was re-read at 26,324 lines. The follow-up implementation, tests and evidence are recorded in subsequent PR commits and CI runs. Independent review was not requested for this continuation.

### Phase B follow-up — selection-local work and DRR progress bound

- The DRR selector now passes the effective lane derived at the start of the current selection into the lane-key builder. This removes a duplicate `scheduled_lane` evaluation per admitted candidate without caching across selections; inherited priority is still recalculated against the current selection time.
- DRR's maximum-round loop is bounded by `ceil(max_item_cost / drr_quantum)`. The minimum lane/service weight is 1, admission limits every selectable cost to `max_item_cost`, and the 2× deficit cap is above that threshold.
- The strict advanced-scheduler regression exercises a background/best-effort lane, quantum 1 and configured maximum cost 32. It deliberately uses a critical work class and tracing operation so the item reaches DRR despite the separate work-class admission limit.
- `bench/drr_lane_cardinality.bench.luau` and the Bencher workflow measure first-selection cost over queue sizes 128–8,192 and distinct lane counts 1–2,048, with queue construction outside the timed operation. This supplies the evidence needed before replacing lexical lane sorting or adding a persistent lane index.

### Phase D — copy/validation and mutation pipeline

**Decision: retain the existing ownership-aware pipeline; do not add another prepared-value cache or duplicate traversal in this PR.**

- `copy_value` already performs detachment and records node count, depth, string-limit and non-finite facts when supplied a `ShapeValidation`. `Record:Update` uses that single copy/shape traversal and calls `validate_value` with `shape_already_validated = true` and the known non-finite flag. The second shape walk is therefore skipped, but the exact JSON encoding/byte-limit check and isolated custom-validator call remain authoritative.
- `Patch` already uses copy-on-write for changed ancestors and payloads. Its weak-key subtree summaries are restricted to private table subtrees, and the final output still passes through validation/serialization. No caller-owned mutable table is promoted into a persistent prepared-value cache.
- Reconciliation already has a no-op inspection path that can avoid cloning the current profile when no defaults need to be inserted. Replacing it with a generic pipeline would add complexity without a demonstrated reduction in traversal or allocation.
- The depth limit for recursive value copying is resolved once per copy invocation rather than recomputed from the shared envelope namespace for every node. Static node and string limits are module-local constants; the accepted profile depth and raw-envelope wrapper-depth behavior are unchanged.
- Non-finite sidecar restoration still validates marker shape and path semantics before a value can be published. A separate validated-marker trie/descriptor is not added: the extra representation and allocation have no paired profile evidence yet, and malformed/overlapping paths must continue to fail closed.
- Canonicalization and digest material remain byte-compatible. No persistent digest cache or shared canonical representation is introduced for mutable payloads.

**Envelope wrapper-depth correction (implemented in this continuation).** The three quarantine-fence transitions and two outbox sidecar transitions now copy raw envelopes with `_copy_value_with_depth(raw, _max_value_depth + 1)` and validate each changed envelope with the same additional wrapper depth. The profile-data limit remains 64 edges, exact JSON size validation remains authoritative, and the persisted envelope/sidecar format is unchanged. The new strict regression exercises install, release-pending, release, outbox state update, and outbox prune using exactly 64-edge profile data.

**Paired same-runner measurements before the recursive-limit hoist (Bencher, Ubuntu 24.04, Hyperfine median, five runs).** The comparison used main baseline SHA `4813492555759ed4ba70c3ec03d9d32be622bc0d` and PR head `6586b2083f3c57621afdcea4b05b8f007e07bad0`; see the [Bencher report](https://bencher.dev/perf/alphanumeric-moderate-s-project/reports/01a221a3-a0a2-728c-ae39-8b626de6d358) and its [GitHub Actions run](https://github.com/alphanumeric-moderate/RecordStore/actions/runs/46133362345).

| Workload | Main baseline | PR result | Change |
|---|---:|---:|---:|
| Large profile update/save | 238.77 ms | 214.89 ms | -10.00% |
| Update copy/validation pipeline | 329.64 ms | 342.55 ms | +3.92% |
| Patch copy/validation pipeline | 239.52 ms | 245.62 ms | +2.55% |
| Reconcile pipeline | 666.73 ms | 685.98 ms | +2.89% |
| Legacy migration/history | 117.26 ms | 127.11 ms | +8.40% |

All five Hyperfine samples completed with zero command exit codes. The PR Bencher gate reported statistically detected alerts for Reconcile and Update validation. The table records paired observations, not causal attribution to a particular code change. The recursive-limit hoist is intended to remove avoidable per-node work and is being remeasured on the later head. These hosted Lune results are not Roblox DataStore latency claims. The earlier isolated CodSpeed WallTime run was marked unreliable outside Macro Runners and is not used as performance evidence.

### Phase E — narrow typing and module boundaries

**Decision: preserve strict typing and current module boundaries; do not perform a mechanical `any` sweep or split the core module without a verified seam.**

- The current consolidated file is still `--!strict` and `--!optimize 2`. Its core records include named types such as `ShapeValidation`, `Message`, `Segment`, `Head`, and `SegmentIndexes`; the latter gives the new temporary event/producer indexes explicit value shapes.
- A source scan found 364 textual `any` occurrences in the current module. They are not one homogeneous issue: several sit at deliberately dynamic Roblox/API, adapter, test/mock, and embedded scheduler boundaries. Replacing them mechanically would increase assertion and conversion surface without proving narrower runtime states. The next type work should target one internal state transition at a time with a regression and strict type-check.
- The consolidated `RecordStore.luau` contains no `require(...)` calls. A Durable Streams/diagnostics lazy split would therefore introduce a new child-module/require graph and change compile-time, cold-require and first-use behavior. This audit does not have a matched RecordStore-specific cold-load, bytecode-memory, first-use or live Studio/Rojo hierarchy comparison to justify that boundary. Keep the scheduler and Mailbox V2 embedded as required by the existing architecture contract.
- Existing eager/lazy PlayerData startup benchmarks do not prove that splitting RecordStore itself is beneficial. A future module-boundary proposal must compare the same RecordStore API and workload, test multiple factory instances for shared mutable state, and build/run in Roblox Studio with the actual Rojo hierarchy.

### Phase F — native compilation and removal decisions

**Decision: add no `@native` annotations and remove no feature in this PR.**

- The 26,324-line RecordStore module has no `@native` or `--!native` directive. There is no Roblox Script Profiler/MicroProfiler evidence identifying a pure compute kernel as a dominant cost. Hosted Lune/CPU simulation is not a substitute for Roblox VM native-code evidence. Any later native experiment must annotate the smallest measured function, test nested helper functions separately, and compare live Roblox results against the same workload.
- No downstream installation usage inventory, API-consumer evidence, persisted queue/mailbox/receipt/stream inventory, rollback horizon, or migration-completion evidence was available for the removal candidates in Section 6. No compatibility path, algorithm, diagnostic API, transaction/receipt surface, stream service, mock adapter or public wrapper is approved for deletion.
- Removal remains conditional on an exact caller/export inventory plus live data and rollback evidence. If isolation is sufficient, prefer a separately reviewed lazy boundary before deleting a supported API.

### Benchmark workflow correction and current verification limits

**Paired benchmark evidence after the recursive-limit hoist (Bencher, Ubuntu 24.04, Hyperfine median, five runs).** The comparison used main baseline SHA `4813492555759ed4ba70c3ec03d9d32be622bc0d` and PR measurement head `35cf9afa15420b7932e23a2ce8b9becca7af1ac2`; see the [Bencher report](https://bencher.dev/perf/alphanumeric-moderate-s-project/reports/01a2228c-47c2-71bb-9f14-e692c457ffaa) and [GitHub Actions run](https://github.com/alphanumeric-moderate/RecordStore/actions/runs/46153929684).

| Workload | Main baseline | PR result | Change |
|---|---:|---:|---:|
| Large profile update/save | 238.77 ms | 200.08 ms | -16.2% |
| Update validation pipeline | 329.64 ms | 321.41 ms | -2.5% |
| Patch validation pipeline | 239.52 ms | 231.24 ms | -3.5% |
| Reconcile pipeline | 666.73 ms | 655.15 ms | -1.7% |
| Legacy migration/history | 117.26 ms | 117.45 ms | +0.2% |
| Durable Streams batch publish | 4,839.92 ms | 4,794.91 ms | -0.9% |
| Durable Streams single publish | 62,250.30 ms | 61,774.75 ms | -0.8% |

The report completed without Bencher alerts. This supersedes the earlier pre-hoist alert report; these remain hosted Lune/Hyperfine observations, not Roblox DataStore or Script Profiler evidence.

The CodSpeed CPU-simulation action previously hit the explicit 16-minute step timeout (about 971 seconds) on both the base and PR revisions. The step timeout was raised to 35 minutes and the job timeout to 40 minutes, and the duplicate PlayerData.Set benchmark entry was removed. The latest verified pre-follow-up run was still in progress; report it as passing only after the current-head run completes.

The complete 4-algorithm × 6-scenario × 4-depth scheduler matrix remains an uninstrumented Bencher diagnostic. CodSpeed tracks a bounded first-selection scaling subset for FIFO and DRR at 512, 2,048 and 8,192 items alongside its other benchmarks. The DRR lane-cardinality matrix is now included in Bencher diagnostics and the Hyperfine aggregate. Roblox Studio multi-server/DataStore acceptance and Roblox Script Profiler/MicroProfiler measurements have not been performed.
### Phase D–F disposition

The remaining audit candidates now have explicit keep/defer decisions and the evidence required to revisit them. Phase D does not justify another runtime rewrite on the available data; Phase E's broad typing and module-split candidates remain scoped follow-up work; Phase F is correctly blocked on live profiling and consumer/persisted-data evidence. No public API, persisted format, lease/fencing, or UpdateAsync transform behavior is changed by these decisions.

## 14. Acceptance criteria

The source-grounded opportunity inventory and Phase D–F audit dispositions are recorded above. Runtime implementation acceptance remains phase-specific and requires:
- every major source area above has an explicit optimization, redesign, keep or conditional-removal decision;
- every high-priority candidate has a location, rationale, invariant, test plan and benchmark plan;
- no performance claim is made without paired measurements;
- no removal is unconditional without usage and persisted-data evidence;
- No independent review is requested or performed for this continuation, by explicit user direction; no review approval is claimed;
- subsequent implementation PRs keep strict type-check, relevant regressions, full CI and required Roblox acceptance evidence.

## 15. References

- Existing performance program: docs/performance/recordstore-optimization-program.md
- Repository engineering contract: AGENTS.md
- Luau performance guide: https://luau.org/performance/
- Luau function attributes: https://luau.org/syntax/
- Luau native code generation: https://luau.org/native-code-gen/
- Roblox MicroProfiler: https://create.roblox.com/docs/performance-optimization/microprofiler
- Independent review: not requested or performed for this continuation, by explicit user direction.
