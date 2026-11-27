# RecordStore full-module audit instructions

These instructions are selected only for pull request #82, whose purpose is a complete audit of `src/PlayerDataInitializer/RecordStore.luau`.

## Mandatory source coverage

Read the complete current PR-head version of `src/PlayerDataInitializer/RecordStore.luau` using Robin's repository `read_file` tool. The file is over 26,000 lines. Each call returns at most 2,000 lines and provides a continuation location.

- Read successive chunks until EOF; do not skip, overlap ambiguously, or infer coverage from grep results, the diff, a previous report, or a summary.
- Maintain an exact line-range coverage ledger across context compaction.
- The final review must state all inspected ranges and explicitly confirm whether EOF was reached.
- If any range was not read, label the review incomplete and state the missing ranges. Never present a partial scan as a clean full-module review.

## Repository context

After reading the complete module, inspect `AGENTS.md`, `README.md`, `docs/performance/recordstore-optimization-program.md`, relevant callers, tests, regression runners, and benchmarks. Trace symbols and callers where needed.

## Review coverage

Classify findings under:
- Luau hot-path optimizations and allocation reduction;
- architecture and ownership-aware redesign candidates;
- conditional feature removals, including API and persisted-data compatibility;
- Luau typing and static-analysis opportunities;
- correctness, durability, concurrency, security and privacy;
- regression and benchmark coverage.

For every finding, provide exact path and line references, severity, confidence, concrete cost or failure reasoning, and a test or benchmark that would verify it.

## Required invariants

Preserve DataStore as the durable source of truth; UpdateAsync transformers must remain pure, replay-safe, non-yielding and free of external side effects. Preserve lease fencing, uncertain-write reconciliation, idempotency, copy isolation, schema validation, fail-closed corruption handling, scheduler fairness, mailbox ordering, retention fences, and privacy/erasure guarantees.

Do not recommend blanket `@native`, mechanical loop rewrites, stale caches, persistent indexes, or feature deletion without workload evidence and compatibility/rollback analysis. Do not claim a test, type check, benchmark, Roblox runtime profile, or multi-server acceptance ran unless its actual result is available.

The PR may contain the first implementation tranche of the audit roadmap. Review the actual current diff and code, not only the original audit document.
