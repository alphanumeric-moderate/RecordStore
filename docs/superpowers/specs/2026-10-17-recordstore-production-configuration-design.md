# RecordStore production configuration and observer optimization

- Date: 2026-10-17
- Status: Proposed design, awaiting user review
- Scope: follow-up to merged PR #30; no data-schema or store-identity migration

## Goal

Improve production configurability and reduce avoidable runtime work without weakening session ownership, persistence diagnostics, mutation detection, or backwards compatibility. Select the request concurrency default from measured evidence rather than intuition.

## Current baseline

- The last PlayerDataCore configuration change is merged in commit `fc906f5c34b7a5a42930aada95e88f452b4f17c8`.
- `RecordStore.luau` has a module-global `DEFAULT_MAX_CONCURRENT_REQUESTS = 4`.
- The shared request scheduler checks this cap before issuing production DataStore requests.
- Existing CodSpeed benchmarks use `RecordStore.Mock`. The mock backend bypasses request admission, so those runs cannot compare values such as 4, 6, or 8 for the production semaphore.
- Latest CodSpeed runs also report syscall-dominated simulation measurements and noisy hosted-runner WallTime measurements. These remain useful for coarse CPU-regression tracking, not for proving live Roblox DataStore latency or throttling behavior.

## Design

### 1. A validated, module-wide request-concurrency setting

Expose a module-wide `RecordStore.configure({ max_concurrent_requests = n })` setting, defaulting to 4 to preserve existing behavior until the experiment has evidence. This is not a per-record setting: the request cap applies to all RecordStore instances sharing the module and must be configured before the first record starts the scheduler. Reject invalid values and late configuration attempts with an explicit error. Freeze configuration once runtime work has started so the limit cannot silently change while requests are in flight.

Candidate values for the benchmark: 4 (baseline), 6, 8, and 12. Keep a conservative upper bound of 16. Do not change the selected production default just because a larger cap improves an unlimited-budget simulation.

#### Benchmark model

Extend the Lune shim with a deterministic fake DataStore service so benchmarks exercise the real production path (`RecordStore.new`, not `RecordStore.Mock`) and the real request admission/release code. The fake service must provide atomic-enough `GetAsync`/`UpdateAsync` behavior for the scenario, controllable operation delay, observable maximum outstanding requests, and a configurable request-budget model. It must make no external Roblox calls.

Benchmark separately:
- cold join/open bursts with 10, 30, and 50 records;
- simultaneous saves / closes at the same loads;
- ample-budget and constrained-budget profiles;
- short and long synthetic DataStore service times.

For each candidate, record completed operations, batch completion duration, peak in-flight requests, deadline/budget failures, and retries. Run through CodSpeed. Because hosted WallTime is noisy, use paired candidate scenarios in the same run and use simulation measurements for CPU overhead. Do not call mock-model timing a live Roblox benchmark.

#### Selection rule

Raise the shipped default only to the smallest candidate above 4 that:
1. improves burst completion duration by at least 10% over 4 in the ample-budget profiles;
2. produces no additional deadline failures in the tested profiles;
3. does not increase budget failures/retries in constrained-budget profiles; and
4. shows no material CPU or memory regression in the existing CodSpeed suite.

If no candidate satisfies the criteria, retain 4 and document that the available benchmark evidence does not justify raising it. The fake service approximates request scheduling, not Roblox's real service-wide quota or throttling behavior, so the result is a conservative candidate, not a universal optimum. A production telemetry/playtest phase is still required before claiming the real-world optimum is proven.

### 2. Separate minimal and CodeNum-enabled Rojo projects

Make `default.project.json` the minimal default-schema project without `ReplicatedStorage.CodeNum`, and add `codenum.project.json` for games that need the CodeNum module at that location. Keep the compatibility test project and CodeNum-enabled example mapped to CodeNum.

Update the README with exact build commands and a migration note:
- the default schema does not use CodeNumValue;
- client or gameplay scripts that directly require `ReplicatedStorage.CodeNum` must build with `codenum.project.json`;
- no source module is moved, deleted, or renamed;
- this is an intentional project-build distinction, not a live-data change.

Verify both Rojo builds and inspect their model trees so the minimal project omits only CodeNum and the CodeNum-enabled project retains the documented path.

### 3. Reduce success-event callback overhead without removing diagnostics

Preserve the existing `on_event` contract by default. Add an opt-in `on_event_errors_only` option that suppresses only success-result callback dispatch while continuing to update RecordStore's internal last-error metadata. Use this option for the PlayerDataCore observer, whose callback is used to warn on exceptional persistence outcomes rather than to consume success events.

Do not remove `on_event`, weaken validation, or disable external-mutation detection as a shortcut. Keep `track_external_data_mutation` behavior unchanged in this change. Test both compatibility modes: default callbacks still receive successful events; error-only mode suppresses successful events and still reports validation, budget, fenced, corrupt/future-schema, unknown, and retry-exhaustion outcomes.

Benchmark observer-enabled versus error-only operation with small and large nested records, while retaining the existing regression scenarios.

### 4. Durable queue settings

Do not change queue timing, lease duration, capacity, or retry defaults in this change. The PlayerDataCore setup does not register `on_queue_message`, and RecordStore's automatic polling requires that handler. Changing `queue_poll_interval` would not speed up ordinary player-data saves in this configuration.

Add/keep documentation that queue settings are workload-dependent and should be tuned only for consumers that configure a queue handler. Ensure the scheduler does not poll when the handler is absent.

## Compatibility and safety invariants

- Preserve `PlayerData_Test1`, scope `global`, key prefix `Player_`, schema version, and stored record format.
- No changes to lease semantics, fencing tokens, UpdateAsync transform purity, retry classification, recovery behavior, or shutdown semantics beyond the concurrency admission cap.
- Configuration must fail fast for invalid values and after the scheduler has started.
- The minimal project must not remove CodeNum from any CodeNum-enabled project or the test project.
- The default `on_event` behavior remains backwards-compatible.

## Verification plan

1. Add focused regression tests first and confirm each fails for the intended missing behavior.
2. Test module-wide concurrency configuration: default 4, valid pre-start configuration, invalid values, and rejection after scheduler startup.
3. Test the production-path fake DataStore harness and assert the observed peak in-flight request count never exceeds the selected cap; test both abundant and constrained budget models.
4. Test event callback compatibility and error-only behavior, including error results.
5. Run the complete existing Lune regression suite via the repository's CodSpeed workflow; compare candidate results with the main baseline.
6. Build both Rojo project files and inspect their output trees.
7. Review the final diff and document what remains unverified in a live Roblox server. Do not claim the concurrency value is live-optimal without live DataStore telemetry.

## Acceptance criteria

- One clearly documented, validated module-wide concurrency setting controls actual production request admission.
- A CodSpeed benchmark exercises the real RecordStore production path and reports candidate results plus the limits of its fake service model.
- The chosen default follows the selection rule above.
- Both project variants build, with CodeNum placement correct in the enabled variant.
- Error-only observer mode preserves error diagnostics and leaves the default observer contract intact.
- Durable queue production defaults remain unchanged and unneeded automatic polling stays inactive.
- Existing persistence compatibility and regression tests remain green.
