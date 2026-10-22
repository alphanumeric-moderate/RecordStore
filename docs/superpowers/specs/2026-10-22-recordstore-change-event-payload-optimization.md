# RecordStore change-event payload optimization

Date: 2026-10-22
Base: `main` at `8423b690d3f65055b5ab73498a18d5e27c1e0be9`

## Problem

When a Record has change observers, `enqueue_change_observation` deep-copies both complete data trees before diffing them. Most successful updates change only a small subset of a profile, so this performs redundant allocation and traversal. The change-event API still requires snapshots to be immutable from the observer's point of view: a subscriber must not be able to mutate canonical data or another observer's payload.

## Design

- Diff the synchronously stable source trees directly.
- Clone old/new values only when a change event is actually emitted. If a changed node is a whole subtree (rather than a leaf), clone that subtree as the event's payload.
- If the per-operation event cap forces a truncated full-record event, clone the full old/new trees only for that fallback.
- If the asynchronous dispatch queue overflows, replace pending events with a truncated full-record event that owns detached snapshots. Do not pass live record state to observers.
- Keep sorting, path encoding, event sequence, observer scheduling, dropped-event counters, and queue capacity behavior unchanged.

## Queue-processing invariant under test

While processing a durable message, local Record mutations remain synchronous and may be used by a handler, but nested durability operations (Save/Close/renewal) must report busy while queue processing is active. The regression exercises this invariant without introducing an undocumented blanket ban on updates. The suspected `queue_busy` guard inconsistency is not fixed unless this targeted test or source tracing proves an actual violation.

## Formatter candidate disposition

The `NumberFormatter.formatScientific` candidate was not retained. Available measurements did not establish a meaningful improvement: the relevant Simulation result was effectively unchanged, while WallTime results were flagged as unreliable outside CodSpeed Macro Runners. The scientific-formatting boundary regressions remain, but production formatting code is unchanged.


The shared scheduler benchmark workload was reduced from 256 to 128 items after the PR CI logs showed repeated scheduler selections consumed the 16-minute CodSpeed step budget on a slower runner. It still exercises all 16 owners (8 items each), all priority lanes, service classes, operation classes, fairness assertions, and the independent regression suite. Scheduler benchmark names include the item count so CodSpeed treats them as new workload identities rather than comparing unlike workloads. The paired event benchmark applies 16 single-field updates after creating a 1,000-entry archive, making the redundant whole-profile copies visible across repeated updates rather than measuring a one-time archive insertion.

## Validation

1. Add regressions for truncated full-record payload isolation and queue-processing durability interleaving.
2. Run focused RecordStore regressions and the existing full Lune CI suite.
3. Run existing CodSpeed scenarios, plus a paired sparse-change benchmark that applies 16 single-field updates to a 1,000-entry profile against the unmodified `main` RecordStore source.
4. Review the full diff for API/data-format changes, unbounded allocations, observer isolation, queue semantics, and untested Roblox-only assumptions.

## Non-goals

- No public API or serialized envelope changes.
- No change to ordering semantics or event capacity limits.
- No blanket change to `queue_busy` guards without evidence.
- No release claim for live Roblox DataStore/MemoryStore/MessagingService behavior from mock-only CI.
