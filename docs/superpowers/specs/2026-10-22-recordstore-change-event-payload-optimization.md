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

## Formatter candidate

Refactor the numeric body of `NumberFormatter.format` behind a private helper that accepts already-validated decimal options. `formatScientific` can then call that helper directly instead of resolving the same options again. Public input validation and formatting output must remain identical. Keep the refactor only if equivalent CodSpeed workloads show an improvement outside measurement noise; otherwise revert it.

## Validation

1. Add regressions for truncated full-record payload isolation and queue-processing durability interleaving.
2. Run focused RecordStore regressions and the existing full Lune CI suite.
3. Run existing CodSpeed scenarios, with specific comparison of `large profile update and save` and `CodeNumValue format and normalization` against this baseline.
4. Review the full diff for API/data-format changes, unbounded allocations, observer isolation, queue semantics, and untested Roblox-only assumptions.

## Non-goals

- No public API or serialized envelope changes.
- No change to ordering semantics or event capacity limits.
- No blanket change to `queue_busy` guards without evidence.
- No release claim for live Roblox DataStore/MemoryStore/MessagingService behavior from mock-only CI.
