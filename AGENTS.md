# Agent Engineering Contract

This file applies to the entire repository. It is an operating contract for human and AI contributors, not a replacement for the design documentation.

## Engineering priority

Use the strongest, most deterministic layer that can prevent a defect:

1. **Codebase and API design:** make invalid states and unsafe operations difficult or impossible to express.
2. **Static analysis:** encode enforceable constraints in Luau types, linting, build checks, and CI.
3. **Verification:** prove behavior with focused tests, fault injection, and runtime acceptance.
4. **Prose:** document context and decisions that cannot reasonably be enforced by the first three layers.

Do not compensate for a recurring architectural defect by merely adding another paragraph to an agent prompt. Prefer removing the defect class at its source. This file is the repository-wide operating contract and includes the required Luau and Roblox performance handbook. Keep agent-critical rules here; implementation documents may retain design history and deeper rationale, but no required engineering or performance instruction may depend on an agent discovering a separate document.

## Before changing anything

- Read this file, the relevant sections of [README.md](README.md), the affected source and tests, and any applicable design specification or implementation plan under `docs/`.
- Inspect the current branch, working diff, callers, consumers, and CI workflows before editing. Do not assume an old plan or pull request still describes `main`.
- State the observable behavior being changed, the invariants that must remain true, and the evidence needed to verify the change.
- Make the smallest coherent change. Avoid unrelated cleanup, speculative abstractions, duplicate implementations, and compatibility changes that were not requested.
- Preserve public API behavior and persisted-data compatibility unless an explicit migration or breaking change is approved.

## RecordStore correctness invariants

Treat these as design constraints, not optional coding conventions:

- **Durability authority:** DataStoreService is the durable source of truth. MemoryStoreService and MessagingService may accelerate discovery, wake-ups, or coordination, but must not become the authority for persisted state or correctness.
- **Session ownership:** preserve lease ownership, fencing generations, revision checks, and lease-safety margins. A stale owner must never overwrite or release a newer owner's session.
- **UpdateAsync transforms:** keep transforms deterministic, non-yielding, and free of external side effects. They must not mutate process-local state, acquire application locks, call services, or depend on execution occurring exactly once. Roblox may invoke a transform more than once; keep decisions based only on its supplied state and immutable inputs.
- **Ambiguous writes:** an exception or lost response does not prove that a write failed. Preserve an `unknown` outcome until it is reconciled against an authoritative uncached read and the relevant operation ID, owner, fencing generation, and revision conditions. Do not blindly replay a possibly committed side effect.
- **Stable idempotency:** use stable operation or receipt IDs for retryable business effects. Make duplicate delivery/replay safe; do not claim exactly-once behavior from a queue, callback, or mock.
- **Authoritative reads:** use an explicit fresh/uncached read where ownership, fencing, erasure, migration, or reconciliation requires current durable state. A cached read is not sufficient evidence for those decisions.
- **Fail closed on unknown data:** do not silently replace corrupt, unsupported, future-version, or unrecognized persisted data with defaults. Preserve it for diagnosis or use an explicit, reviewed recovery/migration path.
- **Lifecycle safety:** preserve safe save, lease renewal, release, player-leave, and shutdown behavior. Do not report a profile as successfully loaded when its durable state could not be established.
- **Optional capabilities:** keep optional queues, acceleration services, transactions, purchases, maintenance, and erasure integrations opt-in unless their required handlers, durable stores, fencing, authorization, and recovery paths are present and verified.

When a change touches one of these invariants, identify the exact state transition and failure modes. Add or update focused tests for both the normal path and the relevant negative, replay, concurrency, or uncertain-outcome paths.

## Prefer structural enforcement

- Put validation and invariant checks at the narrowest shared boundary that owns the rule. Avoid duplicating subtly different checks at each caller.
- Prefer explicit types, tagged results, bounded inputs, and state transitions over loosely shaped tables, implicit booleans, or comments describing hidden assumptions.
- Keep side effects outside retryable or replayable callbacks. Separate decision-making from effect execution and reconcile effects with stable identifiers.
- Do not weaken a type, test, CI gate, or validation rule merely to make a change pass. If a constraint is genuinely wrong, change it deliberately and document the reason and replacement evidence.
- Do not add an abstraction unless it reduces total complexity or gives a real, stable boundary. Reuse the existing module and adapter patterns where they fit.

## Static checks and tests

- Preserve the declared Luau type modes. The consolidated `src/PlayerDataInitializer/RecordStore.luau` module is required by CI to start with `--!strict`. Avoid introducing `any`, unchecked casts, or weakened annotations at new boundaries; where an escape is unavoidable, keep it narrow and validate the value at runtime.
- Use the repository's type-check and regression workflows as the canonical check definitions:
  - [Luau Type Check](.github/workflows/luau-typecheck.yml)
  - [Luau Regression Tests](.github/workflows/luau-regression.yml)
- For focused local verification, use the relevant commands documented in [README.md](README.md), such as `lune run bench/run_regression_tests.luau`. Run affected CodeNum, PlayerData, scheduler, mailbox, migration, or adapter regressions when touching those areas.
- For behavior changes, add a focused regression test that would fail before the fix where practical. Then run the focused test, the relevant broader suite, type checking, and the appropriate Rojo build checks.
- Treat benchmarks as performance evidence, not correctness evidence. Compare equivalent workloads and runner conditions; do not infer production DataStore latency or throttling behavior from mock-only measurements.
- Mock and Lune tests do not establish Roblox service semantics. Changes involving real DataStore caching, request budgets, multi-server ownership, MessagingService, MemoryStoreService, shutdown, or platform receipts require an appropriate Roblox Studio/live test before claiming platform-level acceptance.

## Documentation and completion

- Update README or the relevant document when changing a user-facing API, configuration default, persisted format, migration procedure, operational requirement, or supported behavior.
- Keep detailed design rationale in the relevant `docs/` specification or implementation plan. Do not copy the whole architecture into this file.
- Before finishing, inspect the complete diff and map each claimed behavior to fresh verification evidence.
- Report what changed, the exact checks run and their results, and what remains unverified. Distinguish a passing mock test from live-platform acceptance. Never claim a test, benchmark, review, or runtime check was performed unless it actually was.


# Luau and Roblox performance engineering handbook

This section is mandatory for every agent changing runtime code, tests, benchmarks, or performance-sensitive architecture. It consolidates the research-grounded Luau guidance, current official Luau and Roblox documentation, and this repository's existing performance program. It is part of the root engineering contract.

## 1. Evidence hierarchy and optimization order

Optimize in this order:

1. **Remove work.** Avoid unnecessary traversals, allocations, service calls, serialization, retries, polling, wake-ups, per-frame work, and repeated state derivation.
2. **Improve the algorithm.** Reduce asymptotic work only when the new algorithm preserves ordering, fairness, ownership, invalidation, and failure semantics.
3. **Improve representation and locality.** Use dense arrays, stable table layouts, indexes, bounded rings, and reusable scratch storage only when the workload and invariants justify them.
4. **Reduce allocation and retention.** Remove temporary objects, repeated clones, redundant snapshots, closure churn, and unbounded references.
5. **Use compiler and runtime optimizations.** Prefer documented Luau behavior and selectively test native code generation.
6. **Tune local expressions.** Change syntax, aliases, loop forms, or arithmetic only after controlled measurement shows a meaningful gain.

Aesthetic simplicity, fewer source lines, fewer apparent calls, or fewer visible loop iterations are not performance evidence. Prefer less total work and a simpler proof of correctness.

Classify every nontrivial performance claim:

- **Official Luau/Roblox behavior:** directly documented by the language or engine.
- **Runtime implementation observation:** visible in a particular Luau source revision; not necessarily a stable script-level contract.
- **Peer-reviewed cross-runtime finding:** measured in another language, VM, collector, compiler, or hardware environment; it motivates a hypothesis but is not a Luau result.
- **RecordStore-specific inference:** plausible from this codebase's workload and invariants; it still requires repository benchmarks and, where relevant, Roblox acceptance.
- **Measured result:** repeatable evidence for a named benchmark, commit, runtime, device, and workload.

Never present a Java, JavaScript, JVM, Go, Lua 5.1, LuaJIT, WebAssembly, or synthetic VM speedup as a Luau or Roblox speedup. A paper about VM internals does not prove that a particular application-level Luau rewrite is faster.

## 2. Required optimization workflow

Every substantive performance change must establish this evidence chain:

1. **Workload:** name the production path, input shape, scale, operation mix, frequency, and target environment. Include cold-start and sustained behavior when both matter.
2. **Bottleneck:** capture a Roblox MicroProfiler or Script Profiler trace for engine workloads, or a repeatable CPU/allocation benchmark for pure Luau. Identify the expensive operation, not just the file containing it.
3. **Baseline:** preserve the pre-change implementation or benchmark. Record revision, runtime, machine/device, inputs, configuration, warmup policy, and exact commands.
4. **Hypothesis:** state which work or resource will decrease and why. Predict possible costs such as extra writes, cache invalidation, branch overhead, retained capacity, code size, synchronization, or a slower cold path.
5. **Invariants:** list public behavior, persisted format, isolation, ordering, failure, and lifecycle properties that cannot change.
6. **Candidate measurement:** change one main variable at a time. Keep data shape, random seeds, operation mix, and runner conditions equivalent.
7. **Regression evidence:** run focused behavior and failure-path tests, type checks, and the relevant broader suite. A speed benchmark does not prove correctness.
8. **Target acceptance:** use Roblox Studio or the actual target device/server for claims involving native code generation, engine behavior, GC behavior, frame time, Instances, networking, or Roblox services.
9. **Decision:** keep the change only when its improvement is repeatable and worth its complexity and memory cost. Revert or redesign a neutral, unstable, or workload-regressive change.

Do not combine several speculative changes into one benchmark comparison. Keep a clear baseline and a causal explanation. Do not claim a performance result from source inspection alone.

## 3. Luau iteration, tables, and compiler behavior

### 3.1 Table iteration

Current Luau specializes these common table iteration patterns:

- Generalized iteration: for key, value in t do
- pairs iteration: for key, value in pairs(t) do
- ipairs iteration: for index, value in ipairs(t) do
- next iteration: for key, value in next, t do

The compiler recognizes them and emits optimized bytecode using internal iterators. Normal table iteration does not ordinarily invoke a Lua iterator function once per element. Generalized iteration, pairs, and ipairs have comparable performance.

Rules:

- Prefer generalized iteration for ordinary Luau code unless vanilla Lua compatibility or ipairs nil-termination semantics are required.
- Use ipairs only when stopping at the first nil is intended. Do not replace it blindly on potentially sparse data.
- Use pairs when its semantics or compatibility are wanted; do not call it inherently slow in Luau.
- Numeric loops such as for i = 1, #t do can be slightly slower for array-like tables because of indexed reads. Use them when the numeric index is needed or measurement supports them, not because numeric loops are presumed faster.
- Do not write a custom iterator merely to avoid a per-element function call that Luau already specializes.
- Do not change iteration order when it is observable or required for deterministic behavior.

Official source: https://luau.org/performance/

### 3.2 Table layout and field access

Luau tables use hybrid array/hash storage. Dense positive integer keys suit array-like access; named keys suit dictionary-like access. A Luau table is not a separate fixed-layout record or a native C array.

For hot object-like tables:

- Prefer table literals with stable fields declared together rather than creating an empty table and assigning the same fields later. Luau has table-creation optimizations inspired by table templates.
- Keep frequently accessed record shapes uniform. Reuse a stable set of fields instead of constructing many shapes for the same logical record.
- Prefer statically known field access, such as record.revision or a constant string key. Luau optimizes field access using inline-cache and HREF-like mechanisms.
- Keep hot data fields directly on the table. In object patterns, place methods on the metatable; metatable-mediated data lookup can inhibit the fastest direct-field path.
- Access class-level fields through the class table instead of looking them up through each instance.
- Avoid proxy layers, dynamic field resolvers, or metatables on hot lookup paths unless their semantics are required and profiling justifies their cost.
- Do not change a public API or persisted schema merely to force a table shape.

The field-access optimization can correct a predicted hash slot dynamically. It is not a reason to mutate table layouts unpredictably or assume all dynamic-key accesses are equally fast.

### 3.3 Array length and dense storage

Luau documents that the element at #t is stored in the array part of the table. Worst-case length computation is O(log N), and the runtime can cache and adjust length after operations such as table.insert and table.remove. In ordinary workloads, length is often already cached.

Rules:

- Do not maintain a separate length variable solely because you assume #t is linear or expensive.
- A separate count is justified when it represents a different invariant, such as live entries in a tombstoned queue, and every insertion, cancellation, terminalization, and compaction path updates it correctly.
- Keep arrays dense when using length-based iteration. Do not rely on #t to represent a sparse or hole-filled sequence.
- Use table.create(n) when the expected capacity of a dense numeric array is known. It preallocates the array part; using it to preallocate a dictionary is counterproductive.
- Avoid repeated front insertion/removal from large arrays when a head index, ring buffer, or tombstone representation preserves order with less shifting.
- Do not replace an order-preserving queue with an unordered representation unless the contract permits it.

### 3.4 Clearing and capacity retention

table.clear(t) removes entries while retaining capacity. This can help when a scratch table is about to be reused with similar size, but retained capacity consumes memory and large empty tables still cost memory/GC work.

- Reuse bounded scratch arrays and recurring buffers only when their next use is predictable.
- Do not retain a very large table indefinitely to avoid a rare allocation.
- Consider whether a cleared table remains large across idle periods and long-running servers.
- Never pool public data, caller-owned values, persisted values, or data that can escape its intended lifetime.
- Pools must be bounded, ownership must be explicit, and references to user data, Instances, closures, and payloads must be cleared before reuse.

### 3.5 Global imports and local aliases

Luau optimizes common global access chains such as math.max using imports resolved when the script loads. Manual localization of every builtin or service method is not a universal optimization.

- Use locals for clarity, ownership, repeated access, or a measured hot path; do not add aliases mechanically.
- Do not assume local max = math.max materially outperforms math.max.
- Avoid getfenv, setfenv, and loadstring unless required. They can make environments impure and deoptimize global imports; even getfenv used only to read an environment can invalidate the optimization.
- Never weaken sandbox or security behavior to retain an import optimization.

### 3.6 Closures, calls, inlining, and unrolling

Creating a closure can allocate a function object. Luau can cache certain semantically equivalent closures, including eligible closures with no upvalues or immutable module-scope upvalues. These compiler heuristics can change, and caching changes function identity.

- Avoid per-item closure creation in high-volume paths when a shared callback and explicit context express the same behavior.
- Watch closure allocation in loops involving table.sort, pcall, event subscriptions, or repeated scheduling.
- Do not rely on closure caching for correctness or stable function identity, especially when closures are table keys or identity tokens.
- Do not manually inline every helper. Function boundaries improve correctness, testability, and maintainability; Luau can optimize eligible local functions.
- Keep recursion, error boundaries, and debug-observable call stacks intact unless a measured and reviewed transformation is justified.
- Do not turn readable helpers into monolithic loops solely to remove an apparent call.

The Luau CLI documents additional optimization-level features such as inlining eligible local functions and unrolling simple compile-time-bounded loops. Compiler heuristics select profitable candidates; recursion and environment-mutating functions have restrictions. Do not assume a CLI optimization flag is an application-controlled setting for Roblox production scripts.

### 3.7 Strings, buffers, and serialization

String concatenation, formatting, JSON encoding, and decoding allocate and traverse data. Measure the exact construction path.

- Avoid repeated serialization or rebuilding the same stable string within one operation.
- For many fragments, compare a bounded fragment array plus table.concat with repeated concatenation under actual string sizes and counts.
- Do not allocate a fragment array for a tiny fixed string without evidence.
- Use buffers for binary-oriented fixed-width or packed data only when the API contract and representation require binary values.
- Do not replace readable JSON persistence envelopes with an incompatible binary format as an isolated speed trick.
- Preserve exact encoding, escaping, size enforcement, and format compatibility.

## 4. Allocation, garbage collection, and object lifetime

Allocation rate and retained memory are separate costs. Reducing temporary allocation can lower GC work; retaining oversized buffers or caches can increase memory use and future GC cost.

- Measure allocation and retained references in hot paths, not elapsed CPU time alone.
- Avoid temporary per-node/per-candidate tables when a primitive value, numeric index, reused scratch record, or side table suffices.
- Fuse recursive copy, validation, shape accounting, and marker detection when they naturally traverse the same tree and can share one detached snapshot.
- Keep early rejection checks conservative. Exact validation and serialization remain authoritative.
- Reuse short-lived scratch structures only with explicit ownership and lifetime. Clear captured user data and Instances before reuse.
- Keep caches bounded and define invalidation, expiration, and cleanup.
- Do not add weak-key caches on mutable public tables. Cache only private values whose immutability is enforced by ownership.
- Keep long-lived event connections and per-player maps bounded. Disconnect connections and remove per-player entries during leave/destruction. Do not assume Player or character connections are automatically cleaned merely because a player leaves.
- Watch Developer Console LuaHeap, InstanceCount, and PlaceScriptMemory during repeated joins/leaves and realistic long-running server sessions.
- Use table.clear only when future reuse makes retained capacity worthwhile.
- Do not assume Roblox GC behavior matches the JVM, Go, JavaScript, or a standalone Luau allocator.

Roblox's official profiling guidance treats GC work and temporary table creation as performance targets. Luau runtime source can explain implementation details such as mark traversal and object types, but details such as object headers, barriers, allocator size classes, or mark lists are not script-level guarantees.

Official source: https://create.roblox.com/docs/performance-optimization/improve

## 5. Types, compute kernels, and native code generation

### 5.1 Type information

- Preserve --!strict and explicit types at module and public API boundaries.
- Use types to express data shapes and invariants. Stable types can also help native compilation reason about values.
- Do not introduce any, unchecked casts, or broad type escapes to silence analysis.
- Keep runtime validation at trust boundaries even when a caller has a static type.
- Add type annotations where they clarify the contract or help a measured specialization; do not annotate every temporary mechanically.

### 5.2 Roblox native code generation

Current official Roblox documentation states that native code generation is supported for server-side scripts and client-side scripts on Android devices. Do not assume it is enabled for every client platform.

- @native requests native compilation for one function.
- --!native requests compilation for all functions and top-level scope in a Script where profitable.
- @native does not recursively annotate inner functions. Annotate each intended inner function separately.
- Roblox documents that native execution preserves script behavior and supports Roblox APIs.
- Do not include unsupported target environments in claims that depend on native compilation.
- Prefer testing a small @native candidate before using --!native on an entire script.
- Native compilation is a candidate for compute-heavy work, not an automatic gain for service-bound, allocation-heavy, scheduler-heavy, or network-bound operations.
- Annotate only after identifying a substantial pure or mostly computational hot path. Compare native-on and native-off with equivalent inputs, correctness checks, warmup, and target hardware.
- Measure cold/startup effects as well as throughput when scripts may be short-lived.
- Use concrete type information where it helps numeric/vector specialization.
- Do not confuse Luau's internal vector type or host-VM IR hooks with a public Roblox script API for custom native lowering.
- Do not blanket-enable native code generation as repository style. Limit it to proven kernels and record the target platform.

Official sources:
- https://create.roblox.com/docs/luau/native-code-gen
- https://github.com/luau-lang/site/blob/master/src/content/news/2024-07-23-luau-recap-july-2024.md

### 5.3 Numeric kernels and CodeNum

- Benchmark across the full supported domain, not just small positive integers.
- Include zero, signs, boundary magnitudes, precision limits, infinities, NaN, exponent extremes, and error/overflow behavior where supported.
- Compare algorithms across operand-size distributions and ratios. Algorithm names do not establish crossover points.
- Prefer a simpler quadratic kernel when supported operand sizes are below the crossover where recursive algorithms pay off.
- Do not raise precision/size limits without retuning thresholds and measuring memory pressure.
- Keep CodeNum direct register-writing operations when they reduce result-wrapper allocation and preserve caller-owned output semantics.
- Keep temporary limb pools bounded and LIFO. Never expose pooled arrays or reuse them while a caller-visible result can still reference them.
- Keep a fixed-width exponent buffer when it is a better fit than a table; do not replace compact bounded storage without measurement.
- Verify arithmetic against an independent oracle or invariant, not another branch of the same production algorithm.

The current CodeNum design uses table-based decimal coefficient limbs, a buffer-backed fixed-width exponent, size-dispatched multiplication, normalized Knuth Algorithm D division, and a bounded scratch pool. The current schoolbook/Karatsuba/Toom-4/blocking thresholds are workload-specific starting points, not universal constants. Retune only with Roblox Studio or supported target-hardware evidence. The CodeNum module's --!native directive does not make Lune benchmarks representative of Roblox native performance.

## 6. Data-oriented design and algorithm selection

The right representation follows the access pattern, not a universal slogan.

- Use dense arrays for sequential candidate lists, dependency waiters, histories, batches, and rings when the path scans or appends repeatedly.
- Use dictionaries/indexes for direct identity lookup and cancellation.
- Use an indexed heap for priority/expiry only when key changes and invalidation rules remain correct.
- Use a ring buffer for bounded chronological traces/status history when front removal would otherwise shift entries.
- Use tombstones and amortized compaction only when scans preserve logical ordering and live-count/slot-index invariants are explicit.
- Use side tables keyed by stable internal IDs or queue indexes when primitive facts avoid repeated record allocations or traversals.
- Use structure-of-arrays when a pass repeatedly touches a subset of fields across many items; use array-of-structures when each operation consumes most fields of one item. Benchmark the actual pass mix.
- Consider cache locality, branch behavior, table capacity, memory footprint, invalidation cost, and update frequency together.
- A single O(N) scan can outperform an index at the actual queue size because indexes require mutation, invalidation, and extra memory. Benchmark representative sizes and churn.
- Do not assume a heap is a safe replacement for a selector whose priorities depend on readiness, owner limits, budgets, lanes, age, deadlines, dependencies, and fairness.
- When introducing an index, test every producer, consumer, removal, cancellation, failure, expiry, compaction, restart, and rebuild path.

### 6.1 RecordStore scheduler invariants

Scheduler optimizations must preserve:

- Readiness and unresolved dependency state.
- Dependency failure propagation and expiry behavior.
- Admission and backpressure.
- Per-owner capacity and in-flight accounting.
- Retry limits and retry ordering.
- Priority inheritance and lane semantics.
- Deadline ordering and deterministic tie-breaking.
- FIFO order and urgent-lane burst limits.
- DRR cursor, deficits, quantum, and batch-size decisions.
- Critical and lease-renewal reserved capacity.
- Shadow-selector isolation and bounded diagnostic history.

Never use stale heap priorities or cached readiness without complete invalidation. A reverse dependency index may make readiness checks O(1), but it must update exactly the affected dependents, remove waiter entries on cancellation/terminalization, preserve terminal-history reference counts, and keep failure/expiry propagation deterministic.

Keep terminal preflight semantics intact. A replacement for the reverse terminal scan needs a proof that mixed terminal causes, newest-terminal-first ordering, dependency outcomes, admission rejection, and policy/batch changes produce identical behavior.

## 7. Roblox scheduling, Instances, and parallel execution

### 7.1 Frame and event workloads

- Keep RenderStepped, PreRender, BindToRenderStep, PreSimulation, Heartbeat, and other high-frequency callbacks short.
- Reduce frequency or eliminate redundant work before trying to make each iteration marginally faster.
- Prefer event-driven work over polling only when it preserves required periodic reconciliation.
- Split or defer large non-urgent batches only when partial progress is permitted and no observer can see an invalid intermediate state.
- Do not spread a correctness-critical atomic transition across frames.
- Treat task.spawn, task.defer, task.delay, signals, and coroutines as scheduling mechanisms, not free parallel CPU execution.
- Too many waiting scripts or long pre-yield work can pressure Roblox's waiting-script budget and be throttled.
- Avoid unbounded per-frame task creation. Coalesce redundant work, bound concurrency, and make cleanup explicit.

### 7.2 Parallel Luau and Actors

Creating an Actor does not automatically parallelize a script. Code runs serially by default until it enters a parallel phase.

- Use task.desynchronize(), a parallel signal connection, or Actor messaging deliberately.
- Switch back with task.synchronize() before serial-only engine mutations.
- Respect API thread-safety tags: Unsafe is not usable in parallel; Read Parallel permits reads only; Local Safe is restricted to the same Actor; Safe is usable as documented. Unspecified tags default to Unsafe.
- require() is not allowed during a desynchronized parallel phase.
- Partition independent, coarse-grained CPU work. Parallelize only when per-task work outweighs Actor messaging, scheduling, synchronization, and merge overhead.
- Use immutable snapshots or explicitly synchronized state. Do not allow multiple Actors to mutate a shared profile, scheduler, queue, or RecordStore session without a separately proven concurrency protocol.
- Shared tables provide specific atomic/shared semantics; they do not make arbitrary multi-step invariants atomic.
- Formal determinism in one concurrency model does not establish safety for arbitrary Roblox Actor schedules.
- Do not move DataStore, MemoryStore, MessagingService, or other engine calls into parallel code based on assumptions. Check current API thread-safety metadata and exercise the exact boundary in Studio.
- Keep per-key mutation, lease, and scheduler authority serialized unless an explicit design proves ordering, fencing, and reconciliation.

Official source: https://create.roblox.com/docs/scripting/multithreading

### 7.3 Instances, connections, physics, and memory

- Reduce unnecessary Instance creation/destruction and repeated property changes in hot workloads.
- Profile physics, raycast, animation, replication, and rendering work instead of assuming which engine subsystem dominates.
- Reduce the number and frequency of engine calls before optimizing arithmetic around them.
- Keep event connections bounded and disconnect them when their owner leaves its lifecycle.
- Remove per-player maps, callbacks, references, and transient Instances during player/character teardown.
- Use MicroProfiler labels around suspected regions; do not infer a script bottleneck from overall FPS alone.
- Check LuaHeap, InstanceCount, and PlaceScriptMemory over realistic long-running server sessions.
- Average FPS can hide frame spikes; inspect frame-time distributions and identify the thread/task that owns the work.

## 8. Profiling and benchmark methodology

### 8.1 Roblox profiling

Use the official tools for the right layer:

- **MicroProfiler:** frame-time breakdown, thread/task hierarchy, script and engine work, spikes, scheduling, GC, and custom scopes.
- **Script Profiler:** script/function CPU attribution where available in the current Studio/runtime version.
- **Developer Console:** memory categories, LuaHeap, InstanceCount, PlaceScriptMemory, and runtime diagnostics.
- **Performance Stats:** FPS, memory, and ping context; not a substitute for a trace.
- **Custom scopes:** use debug.profilebegin("RecordStore.CopyAndValidate") and debug.profileend() around meaningful regions. Keep labels stable and specific; pair every begin with an end, including controlled error paths.
- **Device testing:** profile target client devices and server workloads directly. Studio desktop results do not establish low-end mobile or production server behavior.

Profile first, change one bottleneck, then re-profile to establish that the expensive region shrank rather than merely changing source layout.

Official sources:
- https://create.roblox.com/docs/performance-optimization/microprofiler
- https://create.roblox.com/docs/performance-optimization/microprofiler/use-microprofiler
- https://create.roblox.com/docs/performance-optimization/test-on-hardware

### 8.2 Lune, CodSpeed, and mocked tests

This repository uses Lune and a Roblox shim for repeatable CPU and behavior checks. These are useful for pure Luau kernels, copy/shape validation, mock serialization, scheduler selection, process-local queues/rings/coalescers, CodeNum arithmetic, regression tests, and deterministic protocol-fault simulation.

They do not prove:

- Roblox server frame time or scheduler behavior.
- Native code-generation performance on the Roblox host.
- Roblox production garbage collector or allocator behavior.
- DataStoreService latency, caching, request budgets, throttling, or multi-server conflicts.
- MessagingService or MemoryStoreService delivery, ordering, quotas, expiry, or contention.
- BindToClose timing or production shutdown acceptance.

Use the repository's current commands and benchmark definitions. Relevant examples include:

~~~sh
lune run bench/run_regression_tests.luau
lune run bench/run_codenum_regression_tests.luau
lune run bench/run_advanced_scheduler_regression.luau
lune run bench/run_crash_simulator_regression.luau
lune run bench/session_lifecycle.bench.luau
lune run bench/large_profile.bench.luau
lune run bench/scheduler_backlog_scaling.bench.luau
codspeed run --mode simulation
~~~

Run the relevant checks for the changed path and the broader required regression/type/build checks. Do not claim a command was run unless its fresh exit status is available.

### 8.3 Experimental design

- Use multiple independent process/runtime runs. Iterations within one process do not capture all startup, allocator, cache, scheduling, and runtime-state variability.
- Randomize or interleave baseline and candidate order to avoid ordering effects from temperature, background load, thermal state, or machine conditions.
- Separate cold-start cost, warmup, and sustained behavior. Do not silently discard warmup when startup is part of the real workload.
- Do not assume a managed runtime reaches a stable steady state. Long-running workloads can shift between performance segments due to JIT, GC, cache, demand-loading, or resource changes.
- Record each run and time series. Report distributions and trends, not one aggregate average.
- Report median and relevant tail percentiles such as p90/p95/p99 when sample count supports them, plus spread/variance and throughput.
- Use enough independent samples for the claim. Do not stop after one favorable run.
- Keep benchmark setup outside the timed interval only if setup is not part of the user-visible workload. Otherwise include it and explain why.
- Avoid measuring random-number generation, string formatting, logging, assertions, mock setup, or unrelated allocations unless they are part of the target workload.
- Exercise realistic sizes, ratios, sparse/dense distributions, cache hit/miss patterns, failures, dependency depths, queue backlogs, and owner contention.
- Measure memory as well as time. A faster path that increases retained capacity or tail memory can regress long-lived servers.
- Treat profiling as diagnostic, not the only performance number. Sampling profilers can be biased and perturb the workload; validate material findings with controlled timing.
- Do not use profiler pause time or GC pause time as the only proxy for user-experienced latency.
- Do not compare Lune/CodSpeed simulation directly to Bencher process wall time or Roblox production timing. Keep runner metrics separate.
- Save raw output, parameters, commit IDs, environment details, and summaries for reproducibility.

### 8.4 Required performance report

For a meaningful claim, record:

- Commit and source revision.
- Runtime and version.
- Target OS, CPU architecture, and device class.
- Native code generation state and supported platform.
- Workload name, input size/distribution, and operation count.
- Warmup and repetition policy.
- Baseline/candidate execution order.
- Median, tail latency, spread/variance, throughput, and memory/GC observations available.
- Correctness suites and results.
- Whether evidence is Lune/mock, Roblox Studio, target device, or production-like server acceptance.

One fast run, fewer lines of source, a higher average FPS, or an uninstrumented before/after claim is insufficient.

## 9. RecordStore-specific performance requirements

### 9.1 Profile reads, mutations, validation, and saves

Before adding a helper or cache, inspect the current consolidated RecordStore module and its callers. Likely work surfaces include:

- Stored-envelope decoding and protocol/schema validation.
- Detached value copying and shape accounting.
- Non-finite-number detection and sidecar path construction.
- Default reconciliation and custom-validator isolation.
- Change observation and diff generation.
- JSON encoding and exact serialized-byte enforcement.
- Snapshot construction, LastSaved state, Save, Close, and reopen paths.
- Scheduler admission, candidate selection, dependency readiness, metrics, and terminal history.
- PlayerData update batching and uncertain-write reconciliation.
- CodeNum arithmetic and formatting kernels.

Do not duplicate validation or introduce a second implementation beside the existing shared boundary.

### 9.2 Copy and validation pipeline

- Fuse defensive copying and shape accounting in one traversal when both require a detached tree.
- Cache runtime type once per node/edge rather than redispatching repeatedly.
- Stop immediately when configured depth, node, key, string, or shape limits are exceeded.
- Detect non-finite values during the traversal already needed for copying; avoid another full scan when finiteness is proven.
- Build sidecar marker paths only after a non-finite value is found.
- Reuse one prepared immutable snapshot for validation and serialization where the public contract permits.
- Keep the separate isolated copy passed to custom validators. Validator mutations must not affect the candidate or public record.
- Preserve caller-reference isolation, direct Record.Data mutation detection, change-baseline boundaries, LastSaved defensive copies, and save/reopen semantics.
- Transfer ownership of parsed detached envelopes only when no external reference can mutate them. Public Record.Data, Get(), and GetLastSaved() results must remain independently owned.
- In the durable UpdateAsync transform, keep detachment/validation pure and non-yielding. Fuse traversals only while exact serialization and raw persisted-envelope rules remain intact.
- Keep exact JSON encoding/byte-limit enforcement as final size authority.
- A conservative serialized-size lower bound may reject an impossible candidate early; it may never certify that a candidate fits.
- Optimize plain-table reconciliation only where validated shape and ownership are known. Preserve defensive handling for custom/metatable templates.
- Do not weaken depth, node-count, key-kind, non-finite, schema, envelope, or payload limits to gain speed.

### 9.3 Copy-on-write Patch

- Use Patch for small path-based changes to large table-backed roots when the write set is small.
- Clone the root and each touched ancestor on first write; share untouched subtrees only internally.
- Do not expose shared subtrees through public Record.Data, Get(), validator arguments, or caller-owned values.
- Keep the public Update callback's detached-copy contract unchanged.
- Patch operations remain ordered and atomic with respect to publication. Invalid paths, values, shapes, sizes, or validator rejection leave current data unchanged.
- Cache weak-key summaries only for private immutable subtrees with enforced ownership. Summaries may include node count, maximum depth, non-finite presence, or conservative size lower bounds.
- Test aliasing, external mutation, invalid operations, deep paths, array append/remove semantics, validation, non-finite values, exact JSON size, save, reopen, and historical compatibility.
- Benchmark sparse small-path writes and broad mutations. Copy-on-write can lose when most of the tree changes.

### 9.4 Scheduler, mailbox, coalescer, and process-local structures

- Keep FIFO selection allocation-free where possible by tracking eligible queue indexes during the existing admission scan.
- Represent non-FIFO candidates as dense numeric indexes instead of one temporary record per candidate.
- Compact scratch arrays in place only when semantics permit.
- Cache decisions against every relevant policy revision and batch parameter; clear cache metadata when ownership or terminal transitions require it.
- Use stable ID-to-slot indexes and tombstones for O(1) cancellation only if sparse scans preserve FIFO order and compaction is bounded, amortized, and order-preserving.
- Keep terminal completed/failed history bounded and head-indexed or ring-backed; retain dependency-referenced outcomes until their last dependent releases them.
- Use fixed-capacity circular buffers for traces/status, preserving chronology on reads and drains.
- Use an indexed expiry min-heap in the read coalescer only when every insert, hit, refresh, expiry, cancellation, and replacement updates the index.
- Share private immutable snapshots among cache/in-flight state only while callers still receive their required defensive copies.
- Cache unresolved-dependency counts and failed-prerequisite IDs only with a reverse dependency index that updates affected dependents and cleans up waiter entries on removal/terminalization.
- Fuse the reverse terminal preflight with inheritance-candidate collection only if terminal-before-inheritance behavior and deterministic ownership remain identical.
- Do not replace a dynamic selector with a heap until readiness, owner limits, budgets, age, deadlines, inheritance, FIFO ties, urgent streaks, DRR deficits, and fairness remain correct.
- Bound metrics and shadow selectors. Ensure instrumentation does not allocate or scan the full queue on every hot operation without a measured budget.

### 9.5 PlayerData mutation and uncertain writes

- Detach a pending batch by ownership swap when safe instead of cloning the entire batch before every flush.
- Keep a detached batch immutable while its write is unresolved.
- Preserve new mutations that arrive while an earlier write is uncertain; reconciliation must not overwrite a newer same-field update.
- Keep application effects outside retryable persistence transforms.
- Preserve stable idempotency IDs, per-key ordering, lease ownership, fencing, revision checks, and unknown-outcome reconciliation.
- Keep player-leave and shutdown work bounded and safe with uncertain writes.

### 9.6 CodeNum

- Preserve the exact numeric model and serialization format while optimizing internals.
- Benchmark arithmetic across limb counts, exponent sizes, sign combinations, common/adversarial operand ratios, and supported special values.
- Dispatch multiplication using empirically tuned thresholds for target hardware.
- Preserve exact quotient/remainder behavior and verify division corrections/interpolation invariants.
- Keep direct register-writing APIs where they reduce wrapper allocation and preserve explicit caller-owned output semantics.
- Keep scratch pools bounded; pooled limbs must never escape into persistent/public values.
- Preserve fixed-size buffer-backed exponent representation unless an alternative wins in runtime and memory at supported sizes.
- Measure native code generation on Roblox Studio or supported target hardware. Lune does not establish native-codegen gains.
- Keep arithmetic oracle tests independent from implementation and exercise precision, range, infinities, NaN, formatting, codec depth, and malformed input.

## 10. Anti-optimization folklore

Reject these claims unless a relevant benchmark supports them:

- Numeric for loops are always faster than pairs, ipairs, or generalized iteration.
- pairs and ipairs call a Lua function for every element.
- Every builtin should be localized to a local variable.
- A separate array length variable is always faster than #t.
- Manual function inlining is always faster.
- Every metatable is expensive or all metatables should be removed.
- A heap always beats a queue scan.
- SoA is always faster than AoS.
- More Actors always means more CPU throughput.
- Pooling always reduces memory.
- table.clear is always better than allocating a new table.
- Native code generation is always faster.
- A passing Lune benchmark proves Roblox performance.
- A lower GC pause proves better frame-time latency.
- An UpdateAsync error proves that the write did not commit.
- MemoryStore or MessagingService can replace DataStore durability because they are faster.

A benchmark must model relevant data shape, mutation rate, lookup pattern, cache churn, queue size, target runtime, and object lifetime before it can justify a recommendation.

## 11. Research evidence and transfer limits

The research sweep used Lune's peer-reviewed corpus and current official Luau/Roblox documentation. No directly applicable peer-reviewed study specifically measuring ordinary Roblox Luau game scripts or RecordStore was surfaced in the searched Lune corpus. This is a search/corpus limitation, not proof that Luau-specific research does not exist.

Use the literature as follows:

- **Dynamic-language VM specialization:** Deegen demonstrates bytecode specialization/quickening, inline caches, type-based fast/slow paths, code outlining, and baseline JIT generation inside a language VM. These are VM-author techniques, not application-level Luau features RecordStore can implement. Transfer the principle: keep common fast paths simple and exceptional paths explicit.
- **Interpreter representation:** AST-versus-bytecode studies on RPython/GraalVM show representation folklore does not generalize across execution engines. Do not infer that a source layout or loop syntax is faster because it is shorter or more compact.
- **Function specialization:** Inlining and speculative dispatch can remove dynamic dispatch and expose constants, but guards, code size, compilation cost, deoptimization, and cache pressure matter. Prefer stable contracts and profile-guided native annotations over manually simulating a JIT.
- **Allocation elimination:** Escape analysis and stack-allocation research describes compiler/runtime mechanisms that ordinary Luau scripts cannot request directly. Do not assume a local table is stack allocated; reduce measured temporary allocations or rely on proven compiler behavior.
- **GC and memory pressure:** Managed-runtime studies show allocation, write barriers, concurrent collector work, memory limits, and workload shape can affect throughput and tail latency. These motivate measurement on Roblox; they do not establish that Luau has the same collector or overheads.
- **Data-oriented layout:** Discrete-event and many-world simulation studies motivate organizing data around fields each pass actually touches. AoS versus SoA is workload dependent; preserve natural records where operations consume most fields or persistence/API shape requires them.
- **Serialization and cloning:** Data-intensive systems research motivates measuring graph traversal, copying, encoding, decoding, and batching as distinct costs. It does not establish Roblox JSON or DataStore latency.
- **Parallelism:** Actor/ECS research depends on explicit models and constraints. Do not transfer formal determinism results to arbitrary Roblox Actors, shared tables, Instances, or DataStore calls.
- **Benchmark methodology:** Runtime papers document warmup effects, GC effects, run-to-run variability, non-steady performance segments, ordering bias, and profiler sampling bias. Use fresh runs, randomized/interleaved trials, latency distributions, and realistic workloads instead of one warmed-up average.

### Selected peer-reviewed sources

1. Haoran Xu and Fredrik Kjolstad, “Deegen: A JIT-Capable VM Generator for Dynamic Languages,” OOPSLA 2026, DOI 10.1145/3798246.
2. Octave Larose, Sophie Kaleba, Humphrey Burchell, and Stefan Marr, “AST vs. Bytecode: Interpreters in the Age of Meta-Compilation,” OOPSLA 2023, DOI 10.1145/3622808.
3. Olivier Flückiger et al., “Contextual dispatch for function specialization,” OOPSLA 2020, DOI 10.1145/3428275.
4. Ben L. Titzer, “A Fast In-Place Interpreter for WebAssembly,” OOPSLA 2022, DOI 10.1145/3563311.
5. Aditya Anand et al., “Optimistic Stack Allocation and Dynamic Heapification for Managed Runtimes,” PLDI 2024, DOI 10.1145/3656389.
6. Aditya Anand et al., “CoSSJIT: Combining Static Analysis and Speculation in JIT Compilers,” OOPSLA 2025, DOI 10.1145/3763149.
7. David Lion et al., “Investigating Managed Language Runtime Performance: Why JavaScript and Python are 8x and 29x slower than C++, yet Java and Go can be Faster?,” USENIX ATC 2022.
8. Stephen M. Blackburn et al., “Rethinking Java Performance Analysis,” ASPLOS 2025, DOI 10.1145/3669940.3707217.
9. Jaromír Antoch et al., “Experimental Evaluation Methodology for the Era of No Steady Performance,” OOPSLA 2026, DOI 10.1145/3839448.
10. Christoph Laaber et al., “Dynamically Reconfiguring Software Microbenchmarks: Reducing Execution Time without Sacrificing Result Quality,” FSE 2020, DOI 10.1145/3368089.3409683.
11. Dmitry Duplyakin et al., “Avoiding the Ordering Trap in Systems Performance Measurement,” USENIX ATC 2023.
12. Humphrey Burchell and Stefan Marr, “Divining Profiler Accuracy: An Approach to Approximate Profiler Accuracy through Machine Code-Level Slowdown,” OOPSLA 2025.
13. Mingyu Wu et al., “Platinum: A CPU-Efficient Concurrent Garbage Collector for Tail-Reduction of Interactive Services,” USENIX ATC 2020.
14. Wenyu Zhao et al., “Advancing Performance via a Systematic Application of Research and Industrial Best Practice,” OOPSLA 2025.
15. Kaihui Gao et al., “DONS: Fast and Affordable Discrete Event Network Simulation with Automatic Parallelization,” SIGCOMM 2023, DOI 10.1145/3603269.3604844.
16. Olivier Melançon et al., “Float Self-Tagging,” OOPSLA 2025, DOI 10.1145/3763108.
17. Patrick Redmond et al., “Exploring the Theory and Practice of Concurrency in the Entity-Component-System Pattern,” OOPSLA 2025, DOI 10.1145/3763050.
18. Brennan Shacklett et al., “An Extensible, Data-Oriented Architecture for High-Performance, Many-World Simulation,” SIGGRAPH 2023, DOI 10.1145/3592427.
19. Jaeyoung Jang et al., “A Specialized Architecture for Object Serialization with Applications to Big Data Analytics,” ISCA 2020.
20. Taranov et al., “Naos: Serialization-free RDMA Networking in Java,” USENIX ATC 2021.
21. Kolokasis et al., “TeraHeap: Reducing Memory Pressure in Managed Big Data Frameworks,” ASPLOS 2023.
22. Chris Fallin and Maxwell Bernstein, “Partial Evaluation, Whole-Program Compilation,” PLDI 2025, DOI 10.1145/3729259.
23. Boyao Ding et al., “MEA2: A Lightweight Field-Sensitive Escape Analysis with Points-to Calculation for Golang,” OOPSLA 2024, DOI 10.1145/3689759.

Verify exact bibliographic metadata against the paper before using it in an external academic publication. Cross-runtime numeric speedups are intentionally not presented as Luau targets.

## 12. Official Luau and Roblox references

Use official sources first and re-check them when platform behavior may have changed:

- Luau performance guide: https://luau.org/performance/
- Luau performance guide source: https://github.com/luau-lang/site/blob/master/src/content/docs/guides/performance.md
- Luau type-informed/native optimization discussion: https://github.com/luau-lang/site/blob/master/src/content/news/2024-07-23-luau-recap-july-2024.md
- Luau function attributes: https://luau.org/syntax/
- Roblox native code generation: https://create.roblox.com/docs/luau/native-code-gen
- Roblox general performance optimization: https://create.roblox.com/docs/performance-optimization
- Roblox Improve performance: https://create.roblox.com/docs/performance-optimization/improve
- Roblox MicroProfiler: https://create.roblox.com/docs/performance-optimization/microprofiler
- Roblox MicroProfiler walkthrough: https://create.roblox.com/docs/performance-optimization/microprofiler/use-microprofiler
- Roblox profiling on hardware: https://create.roblox.com/docs/performance-optimization/test-on-hardware
- Parallel Luau and Actors: https://create.roblox.com/docs/scripting/multithreading
- DataStore documentation: https://create.roblox.com/docs/cloud-services/data-stores
- DataStore caching and versioning: https://create.roblox.com/docs/cloud-services/data-stores/versioning-listing-and-caching
- GlobalDataStore API reference: https://create.roblox.com/docs/reference/engine/classes/GlobalDataStore
- MessagingService API reference: https://create.roblox.com/docs/reference/engine/classes/MessagingService

The documentation was checked on 2026-11-28. Native code-generation platform support, API thread-safety tags, service limits, cache behavior, and profiling tools can change. Verify current official documentation before relying on a platform fact.

## 13. Final performance acceptance gate

A performance change is ready only when all applicable statements are true:

- The target bottleneck was measured, not guessed.
- The benchmark matches the actual workload, input distribution, and supported scale.
- Baseline and candidate use the same environment and measurement policy.
- Improvement repeats across independent runs and is not explained by ordering, warmup, thermal state, profiler overhead, or unrelated noise.
- CPU time, tail latency, throughput, allocation, and retained memory were considered where relevant.
- Luau compiler/runtime optimizations were understood before adding manual workarounds.
- Data ownership, isolation, type, protocol, persistence, scheduling, and lifecycle invariants remain true.
- Regression, fault, type, and build checks pass for changed behavior.
- Roblox-specific claims have Roblox Studio/device/server evidence.
- The change does not create a slower cold path, unbounded cache, hidden queue, starvation risk, or operational cleanup burden.

If a target Roblox environment is unavailable, mark platform-level performance acceptance **unverified**. Do not replace it with a Lune result or a paper's result.
