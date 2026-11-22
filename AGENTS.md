# Agent Engineering Contract

This file applies to the entire repository. It is an operating contract for human and AI contributors, not a replacement for the design documentation.

## Engineering priority

Use the strongest, most deterministic layer that can prevent a defect:

1. **Codebase and API design:** make invalid states and unsafe operations difficult or impossible to express.
2. **Static analysis:** encode enforceable constraints in Luau types, linting, build checks, and CI.
3. **Verification:** prove behavior with focused tests, fault injection, and runtime acceptance.
4. **Prose:** document context and decisions that cannot reasonably be enforced by the first three layers.

Do not compensate for a recurring architectural defect by merely adding another paragraph to an agent prompt. Prefer removing the defect class at its source. Keep this file short; put detailed contracts beside the relevant implementation or in the existing docs.

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
