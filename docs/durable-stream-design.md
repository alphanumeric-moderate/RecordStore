# Durable stream storage design

## Commit and ordering model

A stream has a fixed partition count. A stable route key chooses one partition; ordering and stream sequence numbers are local to that partition. Each partition has one active, bounded segment. A bounded batch is validated and canonicalized before entering UpdateAsync. The segment UpdateAsync is the append linearization point: message rows, sequence allocation, producer checkpoints, byte counts, and the integrity chain become visible together. Transform callbacks are pure and replay-safe.

A full segment is sealed before the partition head advances. Head advancement is a second, idempotent UpdateAsync; it copies the segment's producer high-watermarks and increments the active segment and next sequence. The append remains committed if head advancement is uncertain. The next writer or consumer repairs the rollover. A writer that races with rollover must observe the sealed segment and refresh the head; it never appends to an older segment.

## Permanent bounded producer idempotency

Event IDs are retained in segment rows and support exact duplicate/conflict reconciliation while the segment exists. Exact historical event lookup for arbitrary IDs has no finite storage bound: after deletion, the identity no longer exists unless some durable summary remains.

The producer contract supplies (producer_id, producer_sequence) and requires a single sequencer per producer ID and partition. The active segment holds the latest sequence, event ID, payload digest, and stream sequence for each producer. This table is updated in the same segment write as the message. On rollover, the latest values are copied to the compact partition head. Historical retries at or below the high-watermark are recognized from this metadata even after all earlier segments have been removed. The latest sequence can be checked exactly against its event ID and payload digest; older compacted sequences are treated as duplicates by contract and cannot be content-verified.

This is a bounded compromise: 128 producer IDs per partition, 64-byte IDs, and a 64 KiB metadata ceiling. Entries are never automatically evicted, because eviction would silently re-enable duplicates. When the cap is reached, new producer IDs receive a typed capacity result. This is appropriate for long-lived logical producer identities, not per-server or per-session IDs. Event-ID-only callers retain segment-local exact deduplication.

## Why not a per-message key/index?

| Design | Writes for a batch | Reads | Main advantage | Main cost / failure mode |
|---|---:|---|---|---|
| One key per message plus an index/directory | At least one message write per event plus index maintenance | Requires deterministic ID lookup or directory traversal | Straightforward independent records and exact identity by key | Write amplification grows with batch size; directory/index becomes another hot key or unbounded structure; batch commit is no longer atomic across messages |
| Bounded append segments | One segment UpdateAsync per batch; one head write per rollover | Sequential segment reads and one cursor read per consumer batch | Atomic batch, contiguous partition order, bounded segment size, amortized head writes | Active-segment contention per partition; more recovery states; old event IDs need producer high-watermarks or retained rows |

The segmented log is selected for workloads that benefit from bounded batch append and sequential consumption. It is not universally superior: extremely low-volume independent events or workloads requiring arbitrary exact lookup by event ID may prefer per-message keys. For this stream API, those trade-offs do not justify a second unbounded index.

## Crash and uncertainty matrix

| Operation | Linearization point | Failure after commit but before response | Recovery |
|---|---|---|---|
| Append | Segment UpdateAsync | Outcome may be unknown | Fresh-read exact active segment; match event ID or producer sequence and digest; otherwise return unknown |
| Segment seal | Segment UpdateAsync that stores sealed=true | Head may still point at sealed segment | Next writer/consumer advances head idempotently |
| Head rollover | Head UpdateAsync | New active segment may be empty | Read head; if advanced, continue; otherwise retry advancement |
| Consumer claim | Cursor UpdateAsync | Claim response may be lost | Read cursor and confirm owner token, generation, and unexpired lease |
| Consumer checkpoint | Cursor UpdateAsync | Handler may have succeeded but cursor result be uncertain | Read cursor; only report committed when expected next position is durable; otherwise redelivery is allowed |
| Retention floor | Group registry UpdateAsync | Floor may be advanced while deletions are incomplete | Read authoritative floor and resume the independent monotonic cleanup cursor |
| Segment deletion | RemoveAsync below the committed floor | Removal may have happened before response loss | Retry idempotent RemoveAsync and advance cleanup only after confirmed observation |
| Group removal | Registry marks group removing before cursor cleanup | Some cursor records may remain | Group rejects new claims; repeated removal resumes bounded cleanup |

No cross-key transaction is assumed. Consumers provide at-least-once effects, not exactly-once external side effects. MessagingService wakeups are advisory and only reduce polling latency; the durable cursor and segment log remain authoritative.

## Operational and benchmark acceptance

The deterministic fake-store suite should cover transform replay, concurrent append attempts, before/after-commit failures, rollover repair, retention-floor interruption, stale claims, checkpoint uncertainty, historical producer retries, producer conflicts/gaps, and identity-capacity backpressure.

Benchmarks should report calls per event and payload bytes for one-event and batched append, consumer batch throughput and backlog drain, partition contention, rollover, cursor checkpoints, and cleanup. Compare p50/p95/p99 latency, throughput, CPU, allocations/GC, and memory on matched runners under steady and burst load. Lune and fake-store runs validate algorithms and local costs only. Roblox Studio multi-server tests and live DataStoreService fault/acceptance tests are required before making service-budget or production-durability claims.
