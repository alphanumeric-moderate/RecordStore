# RecordStore

[![CodSpeed](https://img.shields.io/endpoint?url=https://codspeed.io/badge.json)](https://app.codspeed.io/alphanumeric-moderate/RecordStore?utm_source=badge)

RecordStore is a server-side Roblox Luau persistence module.

## Install in Roblox Studio

The Rojo projects map `src/PlayerDataInitializer` to a Script named `ServerScriptService.PlayerDataInitializer`. Its child ModuleScripts include `PlayerData`, `PlayerDataCore`, `RecordStore`, `IntegerInfinityValue`, `AlyaNumFormatter` and `AlyaNumValue`. The scheduler and Mailbox V2 implementations are embedded in `RecordStore.luau`. AlyaNum is vendored at `src/AlyaNum` and mapped to `ReplicatedStorage.AlyaNum`.

**`AlyaNum` must be a ModuleScript at `ReplicatedStorage.AlyaNum`.** The vendored AlyaNum module is outside `PlayerDataInitializer`; `AlyaNumFormatter` resolves it from `ReplicatedStorage`, while `AlyaNumValue` is a child of `PlayerDataInitializer`.

Use `default.project.json` for the standard setup. The initializer starts the shared controller and registers `BindToClose` shutdown handling. Use exactly one initializer.

For manual Studio installation, preserve the hierarchy below. Create each `.luau` source as a `ModuleScript`, except `init.server.luau`, which is the source of the normal server `Script` named `PlayerDataInitializer`.

```text
ServerScriptService
└── PlayerDataInitializer (Script; source: init.server.luau)
    ├── PlayerData (ModuleScript; PlayerData.luau)
    ├── PlayerDataCore (ModuleScript; PlayerDataCore.luau)
    ├── RecordStore (ModuleScript; RecordStore.luau)
    ├── IntegerInfinityValue (ModuleScript; IntegerInfinityValue.luau)
    ├── AlyaNumFormatter (ModuleScript; AlyaNumFormatter.luau)
    └── AlyaNumValue (ModuleScript; AlyaNumValue.luau)

ReplicatedStorage
└── AlyaNum (ModuleScript; source: src/AlyaNum/init.luau)
```

Do not put `AlyaNum` inside `PlayerDataInitializer`. Its module must be named exactly `ReplicatedStorage.AlyaNum`. Keep `AlyaNumFormatter` and `AlyaNumValue` as children of the single `PlayerDataInitializer` Script. Use a separate test place or Studio session for compatibility testing.

**Recommended setup with Rojo:** from the repository root, run `rojo serve default.project.json`, open the place in Studio, connect using the Rojo Studio plugin, and sync. The existing project file maps `src/PlayerDataInitializer` and `src/AlyaNum` into the hierarchy shown above. To produce a place/model file instead, run `rojo build default.project.json -o RecordStore.rbxlx`.

## Non-finite numeric values

RecordStore supports `math.huge`, `-math.huge`, and NaN in record data, including nested tables and root scalar records. Values are preserved when reading a record, using `Record:Get()`, mutating it through `Record:Update()`, saving, closing, reopening, or reading supported historical versions.

JSON-backed DataStore records cannot store these numbers as ordinary JSON numbers. RecordStore therefore stores a versioned sidecar of typed table paths and replaces non-finite numbers with finite placeholders in the encoded envelope. The paths distinguish the original values without reserving magic user strings or colliding with application data. The values are restored to actual numbers after the envelope is parsed.

The durable envelope implementation version is now `2`. Version-`1` envelopes remain readable and are upgraded when rewritten. Older RecordStore code sees version-`2` envelopes as a future implementation and refuses to write them, rather than accidentally replacing the placeholders with ordinary zeros. Keep all live servers on a compatible RecordStore version during a rollout.

Non-finite values are supported in **record data**, not as table keys or in unrelated JSON payloads such as metadata or durable-queue messages. RecordStore continues to validate those protocol and metadata fields separately.

Example:

```lua
local record = RecordStore.new("ExampleStore", "global", "player_123", {
    schema_version = 1,
})

local result, message = record:Open({
    positive = math.huge,
    negative = -math.huge,
    not_a_number = 0 / 0,
})

assert(result == "created" or result == "loaded", message)
assert(record:Get().positive == math.huge)
assert(record:Get().negative == -math.huge)
assert(math.isnan(record:Get().not_a_number))
```

## PlayerData modules

The repository also includes:

- `src/PlayerDataInitializer/PlayerData.luau`: the shared controller ModuleScript required by the initializer and gameplay scripts.
- `src/PlayerDataInitializer/PlayerDataCore.luau`: a configurable player session, leaderstats, persistence, retry, and shutdown controller.
- `src/PlayerDataInitializer/RecordStore.luau`: the persistence, session ownership, versioning and recovery API, including its bounded request governor, scheduling policy, dispatcher, and durable Mailbox V2 implementation.
- `src/PlayerDataInitializer/RecordStoreOutboxMailboxAdapter.luau`: source outbox dispatch to a destination Mailbox V2, with exact durable enqueue receipt verification.
- `src/PlayerDataInitializer/RecordStoreOutboxConsumerAdapter.luau`: destination message worker that applies registered versioned reducers through a durable Inbox receipt before acknowledging delivery.
- `src/PlayerDataInitializer/PurchaseReceiptProcessor.luau` and `PurchaseDataStoreAuthority.luau`: opt-in developer-product receipt processing with bounded per-profile idempotency and an optional global PurchaseId authority.
- `src/PlayerDataInitializer/PurchaseAuthorityMigrationRunner.luau`: resumable, bounded import of an application-enumerated historical PurchaseId snapshot with uncached durable checkpoints, source count and rolling digest reconciliation; unresolved batches never advance the cursor.
- `src/PlayerDataInitializer/RecordStoreMaintenanceRobloxAdapter.luau`: paged real DataStore key enumeration, uncached inspection, and revision-checked checkpoint adapters for the bounded maintenance runner. Generation-aware deletion remains explicitly application supplied.
- `src/PlayerDataInitializer/IntegerInfinityValue.luau`: a `NumberValue` factory that rounds finite values to integers while preserving positive infinity, negative infinity, and NaN. The default `kills` field uses this type so non-finite values are not silently replaced with zero.
- `src/PlayerDataInitializer/AlyaNumFormatter.luau`: shared abbreviation formatting for native numbers and AlyaNum values. It renders positive infinity as `Infinity`, negative infinity as `-Infinity`, and NaN as `NaN`.
- `src/PlayerDataInitializer/AlyaNumValue.luau`: an adapter for the vendored AlyaNum library. It persists AlyaNum's normalized base representation in a versioned JSON envelope and provides `get`/`set` helpers for a replicated StringValue backing instance. IEEE special values use explicit tagged sentinels because AlyaNum itself accepts finite numeric inputs. With the default schema, this adapter is not loaded during startup; `PlayerDataCore` requires it only when an `AlyaNumValue` field is configured or used.
- `src/AlyaNum/init.luau`: vendored AlyaNum source from `evilbocchi/alyanum`, pinned to commit `331b5e56d3857b04a4899fa9e46d6d39670c368a`. Its MIT license is included in `THIRD_PARTY_NOTICES/AlyaNum-MIT.txt`.
- `src/PlayerDataInitializer/init.server.luau`: a standard Script that starts the controller and shuts it down from `BindToClose`.

### PlayerData.Set API

The Rojo project maps `src/PlayerDataInitializer/PlayerData.luau` to a shared `ServerScriptService.PlayerDataInitializer.PlayerData` ModuleScript.
Use the included `src/PlayerDataInitializer/init.server.luau` Script (mapped as `PlayerDataInitializer` in
`examples.project.json`) to start the controller and shut it down safely. Gameplay Scripts require the
same ModuleScript, so they share one controller and persistence queue.

The `PlayerDataInitializer` Script initializes the shared controller from its child `PlayerData` ModuleScript:

```lua
local player_data = require(script:WaitForChild("PlayerData"))
assert(player_data:Start(), "PlayerData controller already started or is shutting down")

game:BindToClose(function()
	player_data:Shutdown()
end)
```

Use exactly one initializer. The example project already includes this Script as PlayerDataInitializer;
do not add a second initializer when using that project.

```lua
local ServerScriptService = game:GetService("ServerScriptService")
local PlayerData = require(ServerScriptService:WaitForChild("PlayerDataInitializer"):WaitForChild("PlayerData"))

-- All keys are the lowercase keys in CONFIG.data, not the displayed leaderboard labels.
local ok, message = PlayerData.Set(player, "kills", 12500124)
assert(ok, message)

PlayerData.Set(player, "equipped", "Hi")
PlayerData.Set(player, "admin", true)
```

`Set` uses **dot-call syntax** (`PlayerData.Set(player, key, value)`), not colon syntax.
It returns `true, nil` when the value was accepted by the runtime API, or `false, reason` for an
unknown key, invalid value, missing active session, or missing required runtime value instance. For
fields represented by a Value object, the existing `Changed` listener updates formatted display text
and queues the value for persistence. Data fields without a leaderboard entry, such as `admin`, are
queued directly. Persistence is asynchronous and coalesced; a successful return does not mean a
DataStore write has completed synchronously.

Numeric fields are normalized according to their configured Value type. For example, `kills` uses
`IntegerInfinityValue`, so fractional input is rounded using the field's configured rounding rule.
AlyaNum fields accept an AlyaNum value or a supported finite numeric input and serialize it without coercing high-range values to a native `number`. To use AlyaNum, configure a field in `CONFIG.data`, for example `cash = define_data_field("AlyaNumValue", 0)`. The adapter stores the AlyaNum base representation in a versioned JSON payload backed by a replicated `StringValue`; the leaderboard remains formatted, display-only text.

`Set` is server-side. Do not use it as a client-authoritative economy or permission boundary; validate
gameplay actions and authorization on the server before changing protected fields.

### Reset-on-join data fields

Pass `"ResetOnJoin"` as the third argument to `define_data_field` to restore that field to its configured default whenever its record is successfully loaded:

```luau
equipped = define_data_field("StringValue", "Default", "ResetOnJoin")
```

The reset is applied during post-load normalization and written through the active RecordStore session before the player is marked loaded. Only fields explicitly configured this way are reset; other saved fields remain unchanged. A field that already equals its default does not trigger a redundant normalization write. Changes made during the active session remain persistent normally, but the selected field is reset again on the next join. The third argument accepts either one rounding mode (`"nearest"`, `"floor"`, `"ceil"`, or `"trunc"`) or `"ResetOnJoin"`.

### Number formatting

AlyaNumFormatter supplies the shared number-abbreviation path for native Luau numbers and AlyaNum objects:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local initializer = ServerScriptService:WaitForChild("PlayerDataInitializer")
local AlyaNum = require(ReplicatedStorage:WaitForChild("AlyaNum"))
local AlyaNumFormatter = require(initializer:WaitForChild("AlyaNumFormatter"))

print(AlyaNumFormatter.format(1_250)) -- 1.25K
print(AlyaNumFormatter.format(1_000_000_000_000)) -- 1T
print(AlyaNumFormatter.format(AlyaNum.new(10):pow(1000))) -- beyond native number range
print(AlyaNumFormatter.format(math.huge)) -- Infinity
print(AlyaNumFormatter.format(-math.huge)) -- -Infinity
print(AlyaNumFormatter.format(0 / 0)) -- NaN
```

The default `PlayerDataCore` configuration abbreviates `Kills` using `define_leaderstat("kills", "Kills", { decimals = 2 })`. Native numeric and `AlyaNumValue` leaderstats use `AlyaNumFormatter.format`. Explicit precision accepts integers from 0 through 6; `trim_trailing_zeros` controls whether fractional trailing zeros are kept. Formatting changes display text only, never persisted values.

### AlyaNum support and persistence compatibility

`ReplicatedStorage.AlyaNum` exposes the vendored AlyaNum library. Configure extended-range fields with `define_data_field("AlyaNumValue", 0)`. The `AlyaNumValue` adapter stores a versioned AlyaNum base representation in the profile and a replicated `StringValue`, then reconstructs an AlyaNum value when read.

```luau
local ServerScriptService = game:GetService("ServerScriptService")
local AlyaNumValue = require(ServerScriptService:WaitForChild("PlayerDataInitializer"):WaitForChild("AlyaNumValue"))
local AlyaNum = require(game:GetService("ReplicatedStorage"):WaitForChild("AlyaNum"))

local cash = player.PlayerDataValues.cash
local current = AlyaNumValue.get(cash)
AlyaNumValue.set(cash, current + AlyaNum.new(100))
```

AlyaNum uses an extended-range floating representation rather than arbitrary-precision integer arithmetic. It retains finite precision and has its own representational limits; applications requiring exact unbounded integer arithmetic need a separate integer representation. IEEE positive infinity, negative infinity, and NaN are not passed to AlyaNum as ordinary values. `AlyaNumValue` stores those states as explicit tagged sentinels, and `AlyaNumFormatter` displays them as `Infinity`, `-Infinity`, and `NaN`.

New values use the `AlyaNumValue` JSON format version 1. The adapter includes a compatibility decoder for saved `InfiniteMathValue` version-1 envelopes and version-2 CodeNum payloads. Values that AlyaNum can represent are normalized to the AlyaNumValue format; legacy symbolic CodeNum values outside AlyaNum's supported range are preserved verbatim and retain a safe legacy display instead of being replaced with defaults. The old `InfiniteMathValue` name is recognized only as a persisted legacy-format identifier; RecordStore no longer loads or depends on InfiniteMath at runtime.

The StringValue transport retains a conservative 199,999-byte payload limit. AlyaNum's MIT license and pinned upstream commit are recorded in `THIRD_PARTY_NOTICES/AlyaNum-MIT.txt`.
### PlayerDataCore V2 mailbox wake-ups

`PlayerDataCore` can optionally bind each active player Record to the embedded Mailbox V2 and use `RecordStoreV2Acceleration` for cross-server wake-ups. Enable it through the dependencies passed to `PlayerDataCore.new` (for the standard Rojo setup, configure the call in `PlayerData.luau`):

```luau
local PlayerDataCore = require(script.Parent.PlayerDataCore)
local QueueMessageHandler = require(script.Parent.YourQueueMessageHandler)

return PlayerDataCore.new({
    MailboxWakeupsEnabled = true,
    MemoryStoreAccelerationHintsEnabled = true,
    QueueMessageHandler = QueueMessageHandler.handle,
})
```

`QueueMessageHandler` is required when mailbox wake-ups are enabled. Its signature is `(player, message_type, payload, attempts, message_id, sender_job_id, created_at, context) -> (accepted, message?)`. Return `true` only after the application-owned operation has completed. Return `false` with a reason to leave the message retryable. The handler must be idempotent because Mailbox V2 provides at-least-once delivery; do not acknowledge a message before its durable effect is confirmed.

`MailboxWakeupsEnabled` automatically enables the RecordStore durable queue for PlayerData sessions. `MemoryStoreAccelerationHintsEnabled` requires mailbox wake-ups and adds bounded MemoryStore sorted-map hints alongside MessagingService notifications. Both switches default to `false`, and no external services are initialized by the default PlayerDataCore setup. If the optional acceleration service cannot start, PlayerDataCore keeps the mailbox's durable polling/reconciliation path available and continues player loading.

The wake-up adapter is not a profile-save accelerator: it only signals Mailbox V2 work. MessagingService and MemoryStore hints are advisory and may be lost, duplicated, delayed, or throttled. RecordStore's durable mailbox polling remains the recovery path. A Record whose legacy queue has not drained may reject V2 binding; PlayerDataCore leaves the existing queue handler available rather than discarding queued work.

## Rojo

Build the standard production place, including `PlayerDataInitializer`:

```sh
rojo build default.project.json -o RecordStore.rbxlx
```

Build the full isolated regression-test place:

```sh
rojo build tests.project.json -o RecordStore-CompatibilityTests.rbxlx
```

To test default numeric leaderstats without the persistence adapter installed, build the dedicated integration place:

```sh
rojo build tests-native-formatting.project.json -o RecordStore-NativeFormattingRegression.rbxlx
```

This project intentionally omits `ServerScriptService.AlyaNumValue` while keeping the real `ReplicatedStorage.AlyaNum` module and `AlyaNumFormatter`. Open the resulting place in Roblox Studio and run a server playtest. The mapped `PlayerDataSetRegression` must initialize the player, update the formatted `Kills` display (including `Infinity`, `-Infinity`, and `NaN`), and complete its persistence assertions without requiring the optional AlyaNumValue persistence adapter.

Regression scripts use `RecordStore.Mock`; they do not read or write live DataStore records.

## Advanced server-local scheduler

RecordStore includes an advanced **opt-in** server-local scheduler. It is disabled by
default so an existing experience can explicitly review policy and enable the new
selection path. When enabled, background session renewal, autosave and legacy queue
polling enter the same bounded selector. Durable record writes still use RecordStore's
existing session-token/generation fencing and DataStore request-budget checks.

The scheduler exposes policy, metrics and a generic work entry point:

```lua
local RecordStore = require(
    game:GetService("ServerScriptService")
        .PlayerDataInitializer
        .RecordStore
)

local snapshot = RecordStore.get_scheduler_snapshot()
local configured, message = RecordStore.configure_scheduler_policy({
    revision = snapshot.policy.revision + 1,
    shadow_enabled = true,
    shadow_sample_rate = 1,
})
assert(configured == "success", message)

-- Enabling the selector is an explicit rollout decision and can be reversed.
assert(RecordStore.set_scheduler_enabled(true))

local job = RecordStore.schedule_work(
    "maintenance:daily-rebuild",
    "rebuild-page-1",
    function()
        -- Return a typed result. Use "retryable" only when the callback
        -- can prove that no side effect committed.
        return { code = "success" }
    end,
    {
        lane = "background",
        work_class = "maintenance",
        operation_class = "maintenance",
    }
)
assert(job.code == "accepted", job.message)

local current = RecordStore.get_scheduler_snapshot()
```

The API supports revisioned policy updates, cost-aware DRR, bounded owner/work-class
fairness, deadline and age-aware selection, a protected internal concurrency share for
lease renewals and critical profile persistence, delayed-work heaps, expiry/dependency outcomes, retry tokens with
backoff/jitter, bounded callback concurrency, cost-weighted governor admission with
separate StandardRead and StandardWrite estimates, per-work-class caps, estimated-byte
and handler-slot limits, critical read/write reserves, circuit cooldowns, live request
budget observations, opt-in batch windows for callbacks that already represent an
application-defined batch, shadow comparisons, deterministic trace replay, and
queue/latency metrics. Snapshot diagnostics report the active-owner count without returning
raw owner identifiers or DataStore record keys. Governor reservations are released on completion
and before a retry is queued. It never combines separate callbacks into a new business transaction.
The public `schedule_work` API cannot claim `service_class = "critical"`; that service
class grants access to protected admission capacity and is reserved for library-managed
persistence callbacks. The `critical`/`profile_save` work and operation classes, the
`lease_renewal` lane, and the `lease_renewal`/`profile_release` work and operation
classes are likewise internal-only.

The dispatcher also reserves bounded queue headroom for internal critical work, not just
in-flight execution slots. Generic and other noncritical work receives a `capacity`
result before it can consume that reserve. The reserve scales with `queue_capacity`, is
capped at 64 items, and never exceeds `queue_capacity - 1`; a queue capacity of one has
no separate reserve. The total queue remains bounded, so critical admission can still
return `capacity` if critical work itself fills the queue.

`RecordStore.replay_scheduler_trace(trace, policy_override?)` replays synthetic events
against an isolated governor and virtual clock. The trace must be a dense array of at most
8,192 events. Supported event kinds are `enqueue`, `take`, `complete`, `advance`, `budget`,
and `observe`. Time advances must be non-negative and no greater than one year per event;
budget values and observed latencies must be finite and non-negative. Invalid traces return
`{ code = "invalid", message = ... }` before any event is executed.

The result's numeric array portion contains selected work IDs (using `"<empty>"` when nothing
is selected), with a parallel `.statuses` array for each `take`. A `take` event may set
`mode = "critical"` to select protected internal persistence/renewal work or
`mode = "regular"` to select ordinary work; the legacy boolean `renewal_mode` selector remains
supported for compatibility. A `complete` record's optional `outcome` is preserved, so
dependency failures and other terminal outcomes can be reproduced.
A `budget` event uses `{ kind = "budget", read = 16, write = 8 }` to inject a
read/write budget snapshot. An `observe` event accepts `operation_kind`, boolean `succeeded`,
non-negative `latency_ms`, and optional `error_class` and non-negative `budget`; it injects an
operation latency/outcome observation so replay can exercise admission, circuit and batching
decisions.

The optional `policy_override` is merged onto the current policy for that isolated run, e.g.
`{ algorithm = "deadline" }`. The replay assigns its own policy revision. Overrides cannot
change the live policy, request-budget observations, scheduler queue, or callback state. Replay
does not run callbacks or mutate the live scheduler queue.

Priority inheritance is deliberately narrow: a `high`-lane dependent must declare a finite
`deadline_ms` or an `interactive` service class before a ready background prerequisite can
inherit temporary `normal`-lane urgency. The public API cannot request `critical` service
class. Inheritance affects scheduling only; it never changes the prerequisite's stored lane,
identity, dependency outcome, or persistence/session fencing.

Rollout is also per-server and revisioned. Before enabling the selector, read
`get_scheduler_snapshot().rollout` and increase the percentage in controlled steps:

```lua
local rollout = RecordStore.get_scheduler_snapshot().rollout
local code, message = RecordStore.configure_scheduler_rollout({
    revision = rollout.revision + 1,
    percent = 5, -- 0 excludes every server; 100 includes every server.
    salt = "scheduler-canary-wave-1",
})
assert(code == "success", message)
assert(RecordStore.set_scheduler_enabled(true))
```

The cohort bucket is deterministic for the server identity and salt, in the range
`[0, 100)`. Changing the salt starts a new cohort assignment. Rollout percentage only
gates activation; the selector is still explicitly opt-in, and
`set_scheduler_enabled(false)` remains the immediate kill switch. Reducing a rollout
cancels queued, not-yet-started scheduler work; in-flight operations are not preempted
and remain protected by the normal session-token/generation fencing.
Owner IDs are bounded to 512 bytes, work IDs to 96 bytes, and work classes to 64 bytes.

An explicitly batchable callback can accept one optional `batch_size` argument:
```lua
RecordStore.schedule_work("outbox:dispatch", "dispatch-window", function(batch_size)
    return dispatch_outbox_batch(batch_size)
end, {
    batchable = true,
    batch_size = 8,
    batch_backlog = 8,
    batch_window_ms = 5,
    work_class = "outbox_dispatch",
    operation_class = "outbox_dispatch",
})
```

The selected count is bounded by the configured maximum, declared eligible backlog,
recent service latency, request-budget headroom, and in-flight reservations. Admission
reserves the estimated read/write units and bytes for that count before invoking the
callback. The count is a limit for the callback's already-defined batch, not permission
to merge separate callbacks or business transactions. Callbacks that are not marked
`batchable = true` continue to run without a batch-size argument.

Admission uses operation_class as the request-kind key and a conservative estimate for
each operation class. Explicit read_units, write_units, estimated_bytes and handler_slots
can raise the estimate; they cannot lower the class's configured minimum. An UpdateAsync
defaults to consuming both read and write admission dimensions. RecordStore refreshes
the server's StandardRead and StandardWrite budgets at each scheduler dispatch pump using
GetRequestBudgetForRequestType. Fresh low-budget observations defer noncritical work;
critical admission reserves remain local controls, not guarantees against other scripts,
servers or Open Cloud traffic. See the [official DataStore request budget and limits
documentation](https://create.roblox.com/docs/cloud-services/data-stores/error-codes-and-limits).

Scheduler telemetry cardinality is bounded. Built-in operation classes retain independent
latency, budget and circuit-breaker observations; after the bounded custom operation-label
allowance is consumed, additional custom labels are aggregated under `__other__`.
Work-class governor counters represent active reservations only and are removed when their
last reservation is released. Snapshot percentiles cover retained samples, not lifetime totals.

Generic callbacks can return a numeric budget field to publish an additional
operation-class-specific budget observation. Work remains queued during temporary
capacity, circuit, or budget backpressure. Under read_only, mutations are terminally
rejected unless they are classified as critical; mutating = false opts a callback into
read-only execution only when it truly performs no persistence mutation. The
reject_noncritical mode gives queued noncritical work a typed backpressure completion.

`available_at`, an advisory scheduling deadline, `expires_at`, and the durable
session/claim lease are distinct concepts. A deadline is not a completion guarantee.
The weighted/deadline selectors estimate remaining slack as deadline minus current time
and the conservative operation-class service-time estimate (the greater of retained P95
and EWMA when measurements exist). Deadline influence is bounded so it cannot erase static
lane/service preference; age promotion is separate.

When an advisory deadline has already passed at selection, the `on_complete` result keeps
the callback's `code` and includes the reserved scheduler fields `scheduler_overdue = true`,
`scheduler_deadline_ms`, and `scheduler_selected_at_ms`. This reports lateness without
suppressing or automatically expiring the callback. An item whose separate `expires_at`
boundary has passed is returned with a typed terminal outcome rather than silently dropped.
The dispatcher retries only an explicit `{ code = "retryable" }` result and only
within configured limits and retry-token admission. A thrown callback is converted to
`unknown` and is not automatically replayed because its side effect may have committed.
Applications must reconcile ambiguous effects using stable business operation IDs.

The scheduler and its due-time heap are **server-local and non-durable**. A process
restart discards queued callbacks. Do not use generic scheduled callbacks as the durable
mailbox or as an exactly-once transaction mechanism. Scheduled entry points may coexist
with existing direct APIs; callers must deliberately route work through the selector when
they require scheduler ordering. The generic `schedule_work` API does not provide durable
`ordering_key` semantics. Global or per-server-instance priority is intentionally not part of
the protocol; priority may affect message selection and server-local work-class scheduling only.

RecordStore's profile path includes bounded unknown-outcome reconciliation for save, lease-renewal,
and release operations. It retains the logical operation ID and immutable save snapshot, performs an
authoritative uncached read, and retries only through a conditional profile-key `UpdateAsync` while
the exact owner token, fencing generation, expected revision, and lease safety margin still match.
If ownership or revision has changed, the old writer is fenced. `lease_recovery_enabled` defaults to
`false`. When explicitly enabled, same-process recovery may reacquire only if an uncached authoritative
read and the key-level `UpdateAsync` transform both confirm the exact base write ID, revision, fencing
generation, session token, and job/place identity are unchanged and the lease is expired. Reacquisition
uses a distinct stable operation ID and new session token, increments the fencing generation, preserves
the durable payload/revision, and does not replay the ambiguous operation's snapshot. Any uncommitted
local changes remain dirty for a later save. A competing owner or changed fence always wins.

The separate `RecordStore.MailboxV2` API supports an opt-in strict per-key message order. Pass
`strict_ordering_enabled = true` when constructing the mailbox before using a non-nil
`ordering_key`; the default remains disabled and rejects those enqueues. When enabled, every
earlier message on that key must reach a terminal state before a successor can be claimed, even
when the successor has higher priority or the predecessor is delayed, claimed, or retrying.
Dead-letter replay obtains a new durable sequence, so replay cannot jump ahead of older live
messages. The mailbox adapter must provide `GetAsyncFresh(key)` for uncached authoritative reads;
RecordStore's `CreateMailboxStoreAdapter()` does this with `DataStoreGetOptions.UseCache = false`.
Strict mode fails closed rather than falling back to a potentially stale cached read. Per-key
ordering can cause head-of-line blocking and should be enabled only for workflows that require it.
Priority tiers are bounded to `high`, `normal`, and `background`; `high_priority_burst`
sets the maximum consecutive high-priority claims before non-high work gets a selection turn
(default `4`, maximum `32`). These are local scheduling preferences, not ownership or durability
guarantees.

Scheduler design and durable-save recovery are governed by [PR #39](https://github.com/alphanumeric-moderate/RecordStore/pull/39), especially sections 26.13, 27.4, 29 and P0 release blockers 9-10 in section 31. PR #56 contains bounded save/renewal/release reconciliation, freshness budgets, mutation admission and opt-in same-process expired-lease reacquisition. The historical [Luau Regression Tests run](https://github.com/alphanumeric-moderate/RecordStore/actions/runs/40529718478) passed on code-bearing revision `9ee4b56bc24ff9901c98605c9123242f6928287b`. That regression run is separate from the earlier passing Luau Type Check, Bencher Continuous Benchmarks and RecordStore Update Latency runs; those historical results do not validate later reviewed heads. Each later revision requires its own affected checks. Those runs use Lune, Roblox shims and fake stores; they do not establish the full durability contract or real DataStoreService behavior. Previous CodSpeed comparisons flagged unreliable wall-time outside Macro Runners, runner-type mismatch and syscall-dominated workloads, so performance remains inconclusive until comparable measurements are collected. Real Roblox multi-server, throttling/cache, crash/shutdown and rollout acceptance remain open.

## Durability risk and mutation admission

Each Record accepts a validated durability policy:

```luau
local record = RecordStore.new("PlayerData", "global", "Player_123", {
    schema_version = 1,
    autosave_interval = 60,
    max_dirty_age_seconds = 120,
    durability_mode = "balanced",
    lease_recovery_enabled = false,
    on_event = function(event, key, result, message)
        if event == "durability_risk" then
            warn("Persistence risk", key, result, message or "")
        elseif event == "durability_recovered" then
            print("Persistence risk cleared", key)
        end
    end,
})

local status = record:GetDurabilityStatus()
local server_status = RecordStore.get_health_snapshot()
```

- `balanced` preserves the normal mutation policy and emits an edge-triggered risk event when a
  write outcome is unknown or dirty data exceeds the configured age.
- `durability_first` advances the next eligible autosave deadline once dirty data reaches half of
  `max_dirty_age_seconds`. Lease renewal still takes precedence when due. These thresholds do not
  guarantee that Roblox DataStoreService will accept or complete a write by a particular time.
- **read_only_on_risk** rejects RecordStore mutation APIs once the observed dirty generation reaches
  the configured age. In PlayerDataCore, the same policy also rejects new PlayerData.Set calls and
  restores tracked Value-object changes if either the coalesced pending-value buffer or the Record's
  dirty generation exceeds that age. Pending values are coalesced to at most one latest value per
  configured field. Earlier accepted pending values remain eligible for flush; read-only admission
  must not discard them. An in-process policy cannot make uncommitted memory durable.

The game-facing policy can be selected per controller instead of editing the module default:

    local player_data = PlayerDataCore.new({
        DurabilityMode = "read_only_on_risk",
        MaxDirtyAgeSeconds = 120,
        LeaseRecoveryEnabled = false,
    })

DurabilityMode accepts balanced, durability_first, or read_only_on_risk. MaxDirtyAgeSeconds must be
finite, positive, and at most 86,400 seconds. These controller overrides are passed to each Record
and also govern the PlayerDataCore pending buffer.

max_dirty_age_seconds defaults to twice autosave_interval and must be positive and at most
86,400 seconds. GetDurabilityStatus() observes supported direct mutation of the public Record.Data
table before returning status, reports ownership certainty separately from durability, and includes
confirmed revision/generation, dirty and durable watermarks, oldest dirty age and its evidence basis,
lease margin, pending operation identity, policy, and mutation-admission state. Direct mutable-table
changes are timestamped when first observed, so that age is explicitly marked as a lower bound. The
existing on_event option receives edge-triggered durability_risk and durability_recovered events.
The server-level get_health_snapshot() summarizes only Records known to the current server instance;
a healthy result is not a global DataStore service health guarantee.

The Lune regression suite exercises direct-data status, risk reporting, unknown-write reconciliation,
and pending-buffer backpressure. Mock tests do not establish live-service latency, throttling, or
cross-server guarantees. Full PR #39 acceptance still requires the complete failure-injection matrix,
Roblox Studio/server validation, and the separately gated Mailbox, transaction, saga, migration,
operations, and erasure phases.

## Non-save operational diagnostics

Use `RecordStore.get_session_status_async(name, scope, key)` to inspect a profile's last-read durable session lease without opening or mutating that profile. The result distinguishes a missing record, tombstone, absent session, observed unexpired lease, and observed expired lease. This is a fresh point-in-time observation, not an ownership decision: an expired lease does not authorize a takeover or write, and callers must still use the normal fenced session-open protocol. The API does not expose the session token.

```lua
local status, result, message =
    RecordStore.get_session_status_async("PlayerData", "global", "Player_123")

if result == "success" then
    print(status.Observation, status.LeaseRemainingSeconds)
end
```

For an opt-in Mailbox V2 operational pass, `mailbox:MaintenanceAsync()` runs bounded recovery, safe empty-slot reclamation, and a status snapshot in that order. It returns the outcome of the first unsuccessful stage instead of reporting the entire pass as complete. Its report is explicitly bounded and non-linearizable across the separate reads; it is diagnostic and must not authorize delivery, ownership, deletion, or rollout decisions.

```lua
local report, result = mailbox:MaintenanceAsync()
if result.code == "success" then
    print(report.stats.ready, report.stats.preparing_reservations)
end
```


## Profile Doctor and schema migration preview

The read-only Profile Doctor APIs report profile protocol state, a bounded data-size summary, and historical version differences without returning raw profile values.

```lua
local inspection, result, message =
    RecordStore.inspect_profile_async("PlayerData", "global", "Player_123")

if result == "success" then
    print(inspection.Classification, inspection.Revision, inspection.DataNodeCount)
end

local diff, diff_result, diff_message = RecordStore.diff_profile_versions_async(
    "PlayerData",
    "global",
    "Player_123",
    before_version,
    after_version,
    { max_nodes = 4096, max_depth = 32, max_changes = 256 }
)
```

Inspection is a point-in-time, non-authoritative observation. Historical diffs are bounded and include changed paths and value types, not the stored values. Truncation is reported explicitly.

A process-local migration registry supports stable IDs, explicit implementation revisions, declared compatible schema ranges, and forward-only version edges. The registry rejects conflicting ID reuse and ambiguous paths. Load identical migration registrations in every server process that should preview the same schema changes.

```lua
local register_result, register_message = RecordStore.register_migration("PlayerData", {
    id = "playerdata-v1-v2",
    from_version = 1,
    to_version = 2,
    implementation_revision = "playerdata-v1-v2@1",
    compatible_schema_min = 1,
    compatible_schema_max = 2,
    transform = function(_from_version, data)
        local migrated = table.clone(data :: { [string]: RecordStore.JsonValue })
        migrated.migration_marker = true
        return migrated
    end,
    validator = function(value)
        return type(value) == "table", "expected a table"
    end,
})

local preview, preview_result, preview_message =
    RecordStore.preview_migration_async("PlayerData", "global", "Player_123", 2)
if preview_result == "success" then
    print(preview.SourceSchemaVersion, preview.TargetSchemaVersion, #preview.Steps)
end
```

The preview is a dry run only. It runs non-yielding migration callbacks against a read-only snapshot, validates each step, and returns bounded path/type changes without writing migrated data. The registration registry and preview remain process-local; the separate RecordStoreV2 migration-manifest workflow provides explicit durable, guarded execution and quarantine records. Profiles are not automatically migrated by `Open`, and each application's migration definition, backfill inventory, compatibility window and rollback acceptance must still be configured and verified.

## Transactional inbox, idempotent transactions, and outbox delivery

`Record:TransactAsync` and `Record:ApplyInboxAsync` are opt-in through `transactional_operations_enabled = true`. `Record:CommitWithOutboxAsync` commits the source-profile mutation, the operation receipt, and bounded outbox intents in one profile-key `UpdateAsync`; it does not itself deliver to destination profiles. 

`Record:GetOutboxAsync(max_events?)` returns pending and unresolved events in creation-time/event-ID order. The page size defaults to 8 and is bounded at 16. `Record:DispatchOutboxAsync(dispatcher, max_events?)` invokes an application-supplied dispatcher for that bounded page and returns the number of deliveries whose receipt was confirmed.

Use a stable event ID as the destination's idempotency key. The callback should return `true, durable_receipt_id` only after it can verify durable acceptance for that same event ID. A plain, non-durable acknowledgement is not sufficient.

```lua
local delivered_count, status, message = source:DispatchOutboxAsync(function(event)
    -- Application-defined: enqueue with event.EventId as the stable idempotency key,
    -- then verify the destination's durable receipt before returning true.
    local accepted, durable_receipt_id = destination_enqueue_and_confirm(event.EventId, event)
    return accepted, durable_receipt_id
end, 8)
```

`false, reason` leaves the event pending. A callback exception or an acknowledgement without a valid receipt ID leaves the event unresolved (`unknown`) so the next attempt reuses the same event ID. Delivery is at-least-once; arbitrary external side effects are not exactly-once. The callback is application code and must make destination handling idempotent.

These operations can read and update the source outbox while the source `Record` is closed. Outbox status updates are sidecar-only compare-and-update writes: they preserve profile data, revision, timestamps, session fields, write ID, and unknown-compatible top-level fields.

`Record:PruneOutboxAsync(delivered_before_unix, max_events?)` explicitly removes only events with confirmed `delivered` state and `delivered_at` strictly earlier than the cutoff. The cutoff is a Unix timestamp in **seconds**, not milliseconds. Cleanup is bounded (at most 16 events per call); pending, unknown, and blocked events are never pruned by this API. Cleanup is not automatic.

## Opt-in RecordStore V2 non-save services

### Unified service entry point

The optional service modules are exposed through `RecordStoreServices.new(record_store, options?)`. Keep the core and registry as separate ModuleScripts: this avoids require cycles because several adapters depend on core RecordStore types. Constructing the bundle explicitly loads the optional modules and creates a V2 facade bound to the supplied core and its embedded Mailbox V2.

```lua
local initializer = game:GetService("ServerScriptService"):WaitForChild("PlayerDataInitializer")
local RecordStore = require(initializer:WaitForChild("RecordStore"))
local RecordStoreServices = require(initializer:WaitForChild("RecordStoreServices"))
local services = RecordStoreServices.new(RecordStore)
local v2 = services.V2

local PurchaseAuthority = services.Purchases.Authority
local MaintenanceAdapter = services.Maintenance.DataStoreAdapter
local ErasureBinding = services.Erasure.ManifestBinding
local OutboxConsumer = services.Outbox.ConsumerAdapter
```

The returned bundle contains `Core`, `V2`, `Acceleration`, `Modules`, `MailboxMigration`, `Purchases`, `Maintenance`, `Erasure`, and `Outbox`. `Modules` exposes every optional service ModuleScript by its source-module name; the grouped fields point to those same module instances. `options.v2` is passed to the V2 constructor, and the acceleration module is registered there by default. The registry does not require the core, so it can safely expose adapters whose type contracts refer back to RecordStore.

Creating the bundle does **not** start wake-up acceleration, assign `MarketplaceService.ProcessReceipt`, import historical purchases, run maintenance, or execute erasure. Those operations remain explicit and require application-owned configuration, authorization, inventory evidence, and live-platform acceptance. Construct the bundle once per application service graph; create separately configured bundles only when their distinct V2 policy state is intentional.

`RecordStoreV2` is a side-effect-free-on-require, opt-in facade for durable cross-profile sagas, versioned migration manifests, profile diagnosis/repair and quarantine records, erasure plans, eventual projections/unique reservations, bounded redacted traces with per-event durability provenance, and resumable maintenance. All storage-facing workflows accept explicit DataStore-like adapters and use bounded records rather than scanning an entire keyspace.

The saga coordinator is a **recoverable multi-key workflow**, not a cross-key atomic transaction. Its durable manifest retains the latest 32 validated phase/status transitions with timestamps and attempt numbers, so an operator can inspect the progression without storing raw transfer payloads in the history. Use stable transfer IDs, retain the source/recipient operation IDs, and reconcile `unknown` before deciding whether to retry or compensate. Each saga records bounded per-leg outcomes for its stable reserve/credit/refund/settle transaction IDs, including request fingerprints, observed attempts, outcome status, and sanitized errors. When a definitive credit failure triggers a refund whose result is uncertain, the saga enters `compensation_pending`; retries reconcile the same refund operation before considering credit again. If automated reconciliation is insufficient, `Sagas:RequireManualResolutionAsync(id, request, expected_phase, expected_status, manual_request_id, operator_id, reason)` durably pauses a nonterminal saga against its expected state. `Sagas:ResolveManualAsync(id, request, manual_request_id, resolution_id, decision, operator_id, reason, verify_outcome?)` supports `resume`, `confirm_settled`, and `confirm_rejected`; terminal decisions require a caller-supplied verifier that proves the durable cross-profile outcome and returns a stable evidence ID. Replays with the same resolution ID and exact operator/reason input are idempotent; reusing either manual ID with different input conflicts, stale snapshots conflict, and a saga in `manual_resolution_required` cannot proceed through normal automatic retry. Trace events use unique `trace_event_id` values rather than process-local sequence numbers for deduplication. `Tracing:GetOperationTrace` labels events `process_local`; `Tracing:GetOperationTraceAsync` marks records as `durable_store`, `process_local`, or `durable_store_and_local`, and returns an `evidence_summary`: `process_local_events` and `durable_events` count unique returned events observed in those respective sources (including overlaps), while `process_local_only_events`, `durable_only_events`, and `durable_and_local_events` partition those sources. These fields describe evidence provenance, not a linearizable global history. Payloads and player identity fields are deliberately omitted. Projection rows are eventual and require durable source revision/event IDs. Event receipts retain a bounded fingerprint of the canonical event payload, so reusing a recent event ID for different content returns a conflict instead of silently treating it as a duplicate; older IDs outside the 64-receipt window are still protected from reapplication by source-revision checks. `Projections:RebuildDurableAsync(name, rebuild_id, source_snapshot_id, fetch_page, max_pages?)` persists bounded rebuild progress and can resume with the same stable rebuild ID after restart. The `fetch_page(cursor, page_size, source_snapshot_id)` adapter must return `items, next_cursor, complete, observed_snapshot_id` and enforce the immutable source snapshot. Completed pages must return no next cursor; incomplete pages must return an advancing cursor; `GetRebuildStatusAsync(name, rebuild_id)` reads the durable cursor/status. A rebuild ID cannot be reused with a different snapshot, and pages are limited to 64 events. Erasure coverage is only as complete as the application-provided family inventories, writer fences, dependency checks, and key templates. Each family inventory callback must return a dense list of `{ name, scope, key, generation }` locators plus a second return value of `true` only when the list is exhaustive; missing completeness flags, oversized lists, and template-unmatched locators prevent `rtbf_coverage_verified` from being true. `coverage[family].unmatched_count` and a bounded `unmatched_samples` list surface mismatches for operator follow-up.

Versioned runtime policy updates are routed to the current RecordStore scheduler policy API when scheduler fields are present. `max_dirty_age_seconds` is diagnostic/SLO policy; it does not create an unconditional save guarantee. The V2 facade does not register hidden request hooks or enable Mailbox V2 globally. Provide an explicit activation guard.

Durable migration manifests and quarantine records help coordinate operators. `ProfileDoctor.Restore` fails closed unless the application supplies an authorization callback and an erasure-status callback, uses active session ownership and expected revision, binds the transaction to the preflight profile digest, preserves reserved RecordStore keys, and records operator identity/reason. `ProfileDoctor.QuarantineAsync` now installs an atomic same-key durable fence before committing its audit manifest. The fence is represented as a fail-closed future implementation marker, so normal RecordStore reads/writes by stale or new RecordStore versions cannot recreate or mutate the profile. Resolution stages the marker as `release_pending`, confirms the durable audit manifest as `resolved`, and only then removes the marker with a generation-advancing write; unknown outcomes remain fenced and are retried using a stable resolution ID. `ProfileDoctor.CheckWritableAsync` remains a useful pre-write gate, but is not itself atomic and cannot protect application code that bypasses RecordStore or writes other user-associated keys directly. Those external write paths still need exhaustive inventory/integration and live acceptance before production enablement. For crash recovery after the original server exits, `GetQuarantineStatusAsync`, `QuarantineAsync`, `ResolveQuarantineAsync`, and `CheckWritableAsync` also accept an identity table `{store_name = ..., scope = ..., profile_key = ...}` in place of the live Record. This identity-only path reconciles a missing audit manifest from the authoritative same-key fence; it does not allow changing the original operator decision, and unresolved fence/audit disagreement remains write-blocking.

## Lifetime entitlement authority and receipt coordination

`ReserveAsync(entitlement_id, player_id, product_id, purchase_id, expected_revision?)` supports explicit recovery of a pending reservation. After reconciling the previous purchase and its profile grant, pass the observed revision to transfer the reservation to another purchase. The atomic update advances the revision; stale revisions cannot transfer it, and the previous purchase cannot commit over the replacement. Ordinary calls without a revision retain the existing owner, and committed entitlements cannot be taken over.

The optional lifetime-unique purchase path is implemented as separate modules: `PurchaseEntitlementDataStoreAuthority` stores durable entitlement reservation/ownership state; `PurchaseEntitlementReceiptCoordinator` coordinates the global PurchaseId claim, entitlement reservation, a stable idempotent profile-grant callback, entitlement commit and terminal PurchaseId commit; and `PurchaseEntitlementReceiptHandler` adapts the result to Roblox receipt decisions while preserving a caller-supplied fallback for products the coordinator does not own.

This path is not automatically registered with `MarketplaceService.ProcessReceipt`. The game must supply the true lifetime-unique ProductId-to-entitlement mapping, the active-profile grant callback, an activation verifier, request-governor configuration and a reconciled historical source before enabling it. Unknown outcomes defer rather than being treated as successful grants. The authority exposes erasure locator and generation-fenced retention/redaction operations, but it cannot discover all historical entitlement IDs or certify that application inventory is exhaustive.

## Manifest-bound maintenance and erasure helpers

`RecordStoreApplicationInventory` validates the structure of a bounded application inventory manifest, and `PlayerDataErasureManifestBinding` binds a reviewed manifest to explicit family adapters and the existing erasure coordinator. `RecordStoreMaintenanceManifestBinding` binds a reviewed multi-family catalog to application policy callbacks; `RecordStoreMaintenanceAtomicTombstone` provides same-key generation/job-fence mutation helpers with ambiguous-write reconciliation.

These are production code-level integration primitives, not automatic application discovery. The application must still provide exact deployed store/scope/key inventories, writer and recreation-path coverage, dependency/eligibility policies, authorization, compatible durable fencing, and live acceptance. In particular, no RTBF-completeness claim is valid merely because a manifest passes structural validation or a callback returns an attestation.

## Legacy V3 mailbox migration

The retired pre-V2 `q:` queue key is now atomically sealed when absent or valid and empty. Its marker binds the exact store/scope/profile identity and uses a future implementation version so older parser-based `UpdateAsync` writers fail closed. Non-empty or malformed legacy values remain untouched and require manual recovery; a failed/ambiguous marker write is reconciled through an uncached read before queue operations continue.

The embedded mailbox exposes `ImportLegacyAsync` and `ImportLegacyDeadLetterAsync` for bounded, idempotent V3 imports. They derive an owner-bound V2 storage route while retaining the original legacy message ID in public snapshots and results. They preserve the old attempt/replay counters, sender job ID and creation/dead-letter timestamps; legacy timestamps are converted from Unix seconds to V2 milliseconds. Old lock tokens are retained only as migration audit fields and never become active V2 claim tokens. Importing active messages requires `strict_ordering_enabled = true` to preserve FIFO order through a dedicated per-migration ordering key. Active messages with an unexpired V3 processing lease are rejected until that lease expires; the application source-fence adapter must also prove old workers/handlers are drained before import and activation.

The freeze marker leaves the original queue content in place and preserves the V2/V3 fields for source verification. Queue updates use `UpdateAsync` and are accepted only when a fresh uncached read proves the marker; an ambiguous response without a matching durable marker is `unknown`. If the added marker would exceed the configured queue limit, or if a malformed/future-version queue or reserved V2 ID is detected, the freeze is rejected without overwriting source data. Existing queue operations fail closed after the marker is installed.

`RecordStoreMailboxV2MigrationAdapter.bind(...)` supplies a concrete source adapter using `RecordStore.begin_mailbox_v2_migration_async`, `get_mailbox_v2_migration_status_async`, and `get_mailbox_v2_migration_source_page_async`. The latter performs fresh reads against the existing q2 queue key. The coordinator then coordinates the cutover in bounded steps. Its application adapters must freeze the exact legacy source, prove all old writers are drained, provide bounded active/dead-letter page readers, persist a revision-checked durable checkpoint, and supply a mandatory `verify_complete` callback that checks destination inventory/contents as well as the frozen source counts. The adapter rejects configuration without this callback; count agreement and per-item read-back alone are not treated as proof that the destination contains no extras or duplicates. V2 can be enabled atomically only after that verification succeeds. The coordinator stops at `ready_to_activate`; activation is a separate explicit call. It never deletes the frozen source. The application must configure its activation guard to permit the migration operation while blocking normal V2 enqueue/processing until cutover is approved.

## Mailbox V2 operations and maintenance

The embedded Mailbox V2 exposes bounded `RecoverAsync`, `GetStatsAsync`, `ReclaimAsync`, and `MaintenanceAsync` operations. Maintenance sequences recovery, slot reclamation, and a capacity/status read; its report uses `consistency = "bounded_non_linearizable"` and `complete = true` means that bounded sequence finished, not that it captured a linearizable cross-server snapshot. Activation denial is returned before backing-store reads or writes.

## Opt-in outbox-to-Mailbox V2 delivery
The adapter does not acknowledge the source event from the enqueue result alone. It resolves the returned message ID with an uncached, authoritative Mailbox V2 read, then verifies the public ID, message type, and full canonical payload (including the source event ID) before returning the destination receipt ID. An unresolved read-back or identity mismatch leaves the source event unacknowledged for reconciliation.


`RecordStoreOutboxMailboxAdapter` adapts `Record:DispatchOutboxAsync()` to the embedded Mailbox V2. It verifies the resolved destination's store, scope, profile key, and optional UserId, requires an explicit activation guard, binds Mailbox V2 only when the destination Record is active and its legacy queue is empty, and uses the durable outbox event ID as the mailbox idempotency key.

The destination receipt is the stable Mailbox V2 message ID. The source outbox is marked delivered only after Mailbox V2 returns `accepted` or `duplicate` with that non-empty ID. Unknown enqueue/bind outcomes throw so the source outbox records an uncertain outcome and retries the same event ID. Known rejections do not receive a success receipt.

This is **durable mailbox acceptance**, not proof that the destination's eventual handler ran or that an arbitrary external side effect completed. Keep destination handlers idempotent, check `payload_version`, and treat external effects as at-least-once. The adapter never enables Mailbox V2 globally; the application supplies the rollout/activation guard.

### Destination outbox consumer

`src/PlayerDataInitializer/RecordStoreOutboxConsumerAdapter.luau` closes the destination-profile mutation path. Register a reducer for each supported event type and payload version, then call `ProcessBatchAsync(record, limit)` from a dedicated worker/maintenance loop. The reducer is a pure, non-yielding transformation passed into `RecordStoreV2.Inbox.ApplyAsync`; the source event ID is the Inbox receipt's idempotency key **while that receipt is retained**. Inbox receipts are bounded (128 by default); a full receipt set fails closed and leaves delivery retryable rather than evicting a prior receipt. `PruneInboxReceiptsAsync(record, older_than_unix, operation_id, max_items)` provides explicit bounded pruning, with a stable operation ID for reconciliation. Receipt pruning can permit a delayed duplicate to run the reducer again, so events that require lifetime exactly-once domain effects must also update a permanent domain event/entitlement ledger or use a naturally idempotent domain transition in the same profile transaction. The worker acknowledges a Mailbox V2 message only after the destination Inbox transaction returns `committed` or `duplicate`. If a profile write is uncertain, the message claim is lost, the destination locator does not match, or the payload version is unsupported, the worker leaves the message retryable.

Do **not** call the consumer from `Record:ProcessQueueAsync()`. That method holds the Record queue mutex, which rejects a nested Inbox transaction. The consumer creates a separate Mailbox V2 instance for durable claim processing while still checking the active Record identity and explicit `activation_guard`. This does not make arbitrary external effects atomic: have the destination reducer record state and any next-step outbox intent together, then perform external effects through another idempotent adapter.

```lua
local Consumer = require(
    game:GetService("ServerScriptService").PlayerDataInitializer.RecordStoreOutboxConsumerAdapter
)
local consumer = Consumer.new({
    activation_guard = function(record, operation)
        return record:GetState() == "active" and record:IsOpen()
    end,
    handlers = {
        CreditBalance = {
            payload_version = 1,
            reduce = function(data, payload, event)
                local updated = table.clone(data)
                updated.coins += payload.amount
                updated.last_event_id = event.EventId
                return updated
            end,
        },
    },
})

-- Call from a dedicated worker, not from record:ProcessQueueAsync().
local progress = consumer:ProcessBatchAsync(active_records[destination_key], 8)
```

The adapter and its regression cases are wired into the final Lune runner but are still awaiting the deferred final verification phase and live multi-server acceptance.

```lua
local adapter = RecordStoreOutboxMailboxAdapter.new({
    get_record = function(event)
        return active_records[event.DestinationProfileKey]
    end,
    activation_guard = function(record, operation)
        return rollout_is_enabled(record, operation)
    end,
})
source_record:DispatchOutboxAsync(adapter.Dispatch, 8)
```

## Opt-in developer product receipts

For products that require lifetime uniqueness, the per-profile permanent PurchaseId ledger can be backfilled in bounded batches. Construct the processor with `permanent_purchase_ledger_key` set and `permanent_purchase_ledger_migration_complete = false`. While the gate is false, the live receipt handler returns `NotProcessedYet` and never invokes a grant reducer. Use `BackfillPermanentLedgerAsync(record, batch, max_items)` to record known historical PurchaseIds without granting anything; the active profile must own each batch item's PlayerId. Each batch is bounded to 16 entries and is idempotent by PurchaseId. Persist your source enumeration cursor outside this helper, retry unknown results with the same batch, and enable the migration-complete flag only after every required historical source has been enumerated and reconciled. This is a per-profile backfill API, not proof of globally unique purchase history; live Roblox fulfillment and platform-specific historical reconciliation remain release gates.


`PurchaseReceiptProcessor` creates a legacy `MarketplaceService.ProcessReceipt` callback for developer products. It does not access `MarketplaceService`, assign the global callback, or register anything when the module is required. The game must explicitly compose the returned handler with its existing server-side receipt integration.

The processor requires an active RecordStore profile lookup and an explicit finite receipt-retention window between 1 second and 365 days. It commits the profile mutation and a durable idempotency receipt together through `Record:TransactAsync()`. Only `committed` and matching `duplicate` outcomes return `Enum.ProductPurchaseDecision.PurchaseGranted`; conflicts, unknown writes, capacity limits, missing profiles, invalid receipts, and unconfigured products return `NotProcessedYet`.

```lua
local MarketplaceService = game:GetService("MarketplaceService")
local PurchaseReceiptProcessor = require(
    game:GetService("ServerScriptService").PlayerDataInitializer.PurchaseReceiptProcessor
)

local processor = PurchaseReceiptProcessor.new({
    get_record = function(user_id)
        return active_records[user_id]
    end,
    receipt_retention_seconds = 30 * 24 * 60 * 60,
    on_diagnostic = function(diagnostic)
        warn(diagnostic.category, diagnostic.status, diagnostic.message)
    end,
})

local process_receipt = processor:CreateHandler({
    [123456] = function(data, receipt)
        local updated = table.clone(data)
        updated.coins += 100
        updated.last_purchase_id = receipt.PurchaseId
        return updated, { coins_granted = 100 }
    end,
})

-- Only set this if this script owns the experience's single receipt callback.
MarketplaceService.ProcessReceipt = process_receipt
```

`get_record` should be a fast, non-yielding lookup of an already-loaded, actively owned profile. Product reducers must be deterministic, non-yielding data transformations with no external side effects. Apply inventory Instances, effects, or notifications only after the durable transaction result is confirmed.

The idempotency receipt is retained only for the configured window; this does not guarantee lifetime suppression after expiry. Products that require lifetime uniqueness can opt into the permanent per-profile purchase-ID ledger described below. This initial adapter covers legacy developer-product receipts only; additional receipt-type adapters and live Roblox acceptance remain separate work.

After the bounded historical backfill and reconciliation completes, live receipt processing can enable longer-lived uniqueness by setting `permanent_purchase_ledger_key` to an application-owned top-level data field and `permanent_purchase_ledger_migration_complete = true` when constructing the processor. Optionally set `permanent_purchase_ledger_capacity` (default 8192, maximum 8192). The boolean is an operator declaration that all historical PurchaseIds were backfilled into the ledger or that no earlier purchases need importing; it is not automatic verification. A ledger only suppresses IDs already stored in it. If a finite transaction receipt has already expired before its PurchaseId was backfilled, the processor cannot know it was previously granted and could grant it again. Do not enable this feature until historical purchase/entitlement data has been reconciled and imported. Still-retained pre-ledger transaction receipts lack the ledger proof marker and deliberately return `NotProcessedYet` with a `permanent_purchase_ledger_marker_missing` diagnostic instead of being acknowledged without lifetime-ledger proof. The grant and ledger entry commit in the same profile transaction; an ID rebound to another player/product, a malformed ledger, or a full ledger fails closed with `NotProcessedYet` and a diagnostic. The ledger is **per profile**, grows the profile payload, and is not a global cross-profile receipt database. Monitor capacity and plan an audited remediation path. Products requiring global user/product lifetime uniqueness need a dedicated durable global entitlement/receipt authority, not this per-profile ledger alone.


### External durable PurchaseId authority

An optional **external_purchase_authority** enforces PurchaseId identity across different player profiles. The repository includes `src/PlayerDataInitializer/PurchaseDataStoreAuthority.luau`, a concrete DataStore-backed implementation for all servers in one Roblox experience. Use a dedicated DataStore name/scope for this ledger. It maps each PurchaseId to a bounded key, stores the full ID in the durable row to detect hash collisions, uses atomic `UpdateAsync` for claims/commits, and confirms status through `GetAsync` with `DataStoreGetOptions.UseCache = false`. A hash collision, malformed row, conflicting player/product tuple, exhausted request budget, or unresolved write fails closed.

The adapter implements **ClaimAsync(purchase_id, player_id, product_id)**, **CommitAsync(purchase_id, player_id, product_id, outcome)**, **GetStatusAsync(purchase_id, player_id, product_id)**, and **BackfillAsync(purchase_id, player_id, product_id)**. Every returned record contains the requested PurchaseId, PlayerId, ProductId, Status, and optional Outcome. For conflicting tuples, return a Status of **conflict** record echoing the requested tuple; do not disguise a conflict as a timeout or return an unvalidated record shape.

**ClaimAsync** must atomically reserve an ID to one tuple. Repeating the same tuple returns **claimed**, while an already completed matching ID returns **committed**; a different tuple returns **conflict**. Claims remain durable until completion or explicit audited recovery, so a process crash cannot free an ID for another player. **CommitAsync** idempotently transitions a matching claim to **committed** with Outcome **granted** or **duplicate**. **GetStatusAsync** bypasses caches and reconciles uncertain responses. **BackfillAsync** imports already-completed historical purchases as Status **imported** on first insertion and Status **committed**, Outcome **historical** on later reads, without running a grant reducer. It must not convert an in-flight **claimed** entry into historical completion.

Configure both the existing per-profile ledger and the external authority:

~~~lua
local PurchaseDataStoreAuthority = require(
    game:GetService("ServerScriptService").PlayerDataInitializer.PurchaseDataStoreAuthority
)
local PurchaseReceiptProcessor = require(
    game:GetService("ServerScriptService").PlayerDataInitializer.PurchaseReceiptProcessor
)

local authority = PurchaseDataStoreAuthority.new({
    store_name = "ExperiencePurchaseAuthority",
    scope = "global",
    -- Optional: route direct DataStore calls through the application's shared request governor.
    -- request_runner = request_runner,
})

local processor = PurchaseReceiptProcessor.new({
    get_record = get_active_record,
    receipt_retention_seconds = 30 * 24 * 60 * 60,
    permanent_purchase_ledger_key = "purchase_ledger",
    permanent_purchase_ledger_capacity = 8192,
    permanent_purchase_ledger_migration_complete = true,
    external_purchase_authority = authority,
    external_purchase_authority_migration_complete = true,
})
~~~

The two migration flags are operator assertions, not proof. Before enabling live grants, enumerate and reconcile the relevant historical PurchaseIds, use BackfillPermanentLedgerAsync against each owning active profile, and use BackfillExternalAuthorityAsync to import global history in bounded batches of at most 16. Persist source cursors externally and retry ambiguous batches using the same IDs. Set both flags only after both histories have been exhaustively reconciled. The local transaction records the profile grant and its per-profile receipt; the external authority is committed afterward. If the external commit is uncertain, the handler returns NotProcessedYet unless an uncached status read confirms completion, and the next delivery reconciles without running the reducer again.

The native DataStore adapter checks per-server read/write request budgets and fails fast instead of waiting when exhausted. `request_runner` is an optional hook for integration with the application's shared governor; it receives `read` or `update` plus a callback returning `(value, error)` and must preserve bounded admission and error semantics. An injected `store_adapter` is useful for deterministic regression scenarios but must itself provide atomic updates and truly uncached reads. The adapter does not itself enumerate historical PurchaseIds or set either migration flag. Those flags are operator assertions, and historical import plus cross-server response-loss behavior still require acceptance in a real Roblox experience.

### Resumable historical PurchaseId import

The external authority's single-call backfill and the processor's bounded `BackfillExternalAuthorityAsync(batch, max_items)` cover the durable identity transition, but an application still has to enumerate its real source of historical purchases. `PurchaseAuthorityMigrationRunner` composes that batch API with an application-supplied paged reader and a durable compare-and-update checkpoint store. The reader must represent a stable source snapshot and return the same declared `source_revision` on every page. The checkpoint key must be shared by all workers using the same `job_id`.

Before constructing the runner, independently export the entire historical source and review a manifest containing the snapshot revision, manifest ID, exact row count, ordered digest, source-selection rules, and reconciliation evidence. Use `PurchaseAuthorityMigrationRunner.ComputeInventoryDigest(rows)` to compute the deterministic SHA-256 digest over the exact ordered (PurchaseId, PlayerId, ProductId) rows that the source will return. This digest is not signed or authenticated; the application-supplied verifier must compare the immutable reviewed manifest against the expected and observed digests and counts.

~~~lua
local PurchaseAuthorityMigrationRunner = require(
    game:GetService("ServerScriptService").PlayerDataInitializer.PurchaseAuthorityMigrationRunner
)

local migration = PurchaseAuthorityMigrationRunner.new({
    job_id = "purchase-authority-backfill-2026-10",
    source_revision = reviewed_manifest.source_revision,
    inventory_manifest_id = reviewed_manifest.id,
    expected_purchase_count = reviewed_manifest.row_count,
    expected_inventory_digest = reviewed_manifest.ordered_digest,
    verify_complete_inventory = function(manifest_id, source_revision, expected_count,
        observed_count, expected_digest, observed_digest)
        return manifest_id == reviewed_manifest.id
            and source_revision == reviewed_manifest.source_revision
            and expected_count == reviewed_manifest.row_count
            and observed_count == reviewed_manifest.row_count
            and expected_digest == reviewed_manifest.ordered_digest
            and observed_digest == reviewed_manifest.ordered_digest
    end,
    source = historical_purchase_source,
    processor = processor,
    checkpoint_store = durable_checkpoint_store,
    checkpoint_key = "purchase-authority-backfill:2026-10",
    page_size = 16,
})

local progress = migration:RunBatchAsync(2)
-- Repeat RunBatchAsync on later worker turns while progress.code == "incomplete".
-- Enable the production migration flags only after the full source is reconciled,
-- progress.code == "completed", and real fulfillment behavior is accepted.
~~~

The source implements `read_page(cursor, maximum)` and returns `{items, next_cursor, done, source_revision}`. The checkpoint adapter implements `GetAsyncFresh(key)` and atomic `UpdateAsync(key, transform)`. Each invocation processes at most 8 pages and each source page at most 16 PurchaseIds. A partially imported or ambiguous batch leaves the cursor unchanged; replay is safe because the authority import is idempotent. The runner rejects a non-advancing cursor, malformed/dense-page violations, a changed source revision, corrupt or conflicting checkpoints, terminal row-count mismatch, and terminal digest mismatch. The independent historical source and manifest still require operator reconciliation and live-platform acceptance. See [historical PurchaseId inventory reconciliation](docs/purchase-inventory-reconciliation.md).


## Optional cross-server mailbox wake-ups

`src/PlayerDataInitializer/RecordStoreV2Acceleration.luau` implements the opt-in adapter required by `RecordStoreV2.BindMailboxWakeups`. It uses a bounded set of MessagingService topic shards, opaque owner fingerprints, bounded local registrations and coalesced wake-ups. An optional MemoryStore sorted-map hint cache is enabled explicitly and is also bounded; each range poll requests at most Roblox's 20-entry API limit and observed entries are evicted after each poll attempt so stale hints cannot permanently occupy the first page. Entries are advisory and may be overwritten, duplicated, delayed, dropped or expire. The adapter is disabled unless configured with `enabled = true` and started with `Start()`. Wake-ups are never proof that a durable message exists, was claimed or completed. Periodic durable polling and reconciliation must remain active.

Example wiring (supply the same canonical owner identity used to construct the mailbox):

```lua
local Acceleration = require(
    game:GetService("ServerScriptService").PlayerDataInitializer.RecordStoreV2Acceleration
)
local wakeups = Acceleration.new({
    messaging_service = game:GetService("MessagingService"),
    memory_store_service = game:GetService("MemoryStoreService"),
    http_service = game:GetService("HttpService"),
    server_id = game.JobId,
    enabled = true,
    enable_memory_store = false,
})
assert(wakeups:Start())

-- v2_services is the value returned by RecordStoreV2.new(...).
local bound, bind_error = v2_services.BindMailboxWakeups(
    wakeups,
    owner_identity,
    mailbox,
    handler,
    4
)
assert(bound, bind_error)
game:BindToClose(function() wakeups:Stop() end)
```

## Deterministic protocol fault simulation

`bench/DeterministicCrashSimulator.luau` provides an isolated virtual-time harness for replayable persistence failure schedules. It models per-key atomic updates, transform replay, pre-commit failure, commit-then-error response loss, per-server clock skew, process restart, request budgets, local read-cache staleness, MemoryStore TTL, and lossy/duplicated/delayed/reordered MessagingService hints. Trace records omit raw keys and payloads, and invariant callbacks stop at the first violation. The simulator is test infrastructure, not a Roblox service emulator; passing its scenarios cannot establish live DataStore, MemoryStore, MessagingService, platform receipt, or Studio behavior.

## Benchmarks

Performance is tracked with [CodSpeed](https://codspeed.io). The benchmarks run `RecordStore.Mock` scenarios outside Roblox with [Lune](https://github.com/lune-org/lune), a standalone Luau runtime. `bench/RobloxShim.luau` provides the small set of Roblox APIs the mock backend needs (`HttpService`, `DateTime`, `Enum`, `task`, ...).

```sh
# run a single scenario
lune run bench/session_lifecycle.bench.luau

# run the regression tests outside Studio
lune run bench/run_regression_tests.luau

# run every benchmark from codspeed.yml with the CodSpeed CLI
codspeed run --mode simulation
```

### Bencher.dev

Bencher runs alongside CodSpeed and tracks the same Lune workload benchmarks through Hyperfine. It reports median process wall time from the `ubuntu-24.04` GitHub-hosted runner; these timings include Lune startup and are not directly comparable to CodSpeed's simulated measurements.

To enable it:

1. Create a Bencher Cloud project and create a project API key (`bencher_run_*`).
2. Add the project slug as the repository Actions variable `BENCHER_PROJECT`.
3. Add the project API key as the repository Actions secret `BENCHER_API_KEY`.

The workflow publishes a baseline on pushes to `main` and compares pull requests against their base branch. Pull-request runs fail on a Bencher alert once the configured statistical threshold has enough baseline samples. If `BENCHER_PROJECT` is not configured, the Bencher job is skipped. If `BENCHER_API_KEY` is missing, its benchmark and reporting steps are skipped without affecting CodSpeed or the regression checks.

References: [Bencher GitHub Actions](https://bencher.dev/docs/how-to/github-actions/) · [Hyperfine adapter](https://bencher.dev/docs/explanation/adapters/#-shell-hyperfine).


## User-data erasure and RTBF

The generic erasure coordinator is an orchestration primitive, not a discovery mechanism. Its store adapter must implement `GetAsyncFresh` that bypasses Roblox's cached read view; construction fails without it, and planning reconciliation, execution, and status/write-gate reads use that fresh adapter. Cached `GetAsync` is not sufficient evidence for an erasure fence. Each family must supply a complete inventory callback, explicit exact templates for DataStore name/scope/key, an exhaustive-inventory acknowledgement, a durable writer-fence callback, a dependency check, and a generation-aware delete/redaction callback. Templates cannot omit name or scope as wildcards. Empty scope is allowed when it is the actual platform default.

Planning is non-destructive. Execution returns `coverage_unverified` and performs no deletions unless every declared family inventory and template is verified. Writer fences and dependency checks are required before execution and rechecked immediately before every generation-aware deletion. A manifest labeled `resolved` is not proof of erasure or safe recreation on its own; `ShouldBlockWrites(user_id)` keeps writes blocked until the application's audited resolution process explicitly clears its durable writer fence. To recover after a delete succeeds but its response or cursor checkpoint is lost, callbacks may return `already_absent` or `already_redacted` only when the exact planned generation is confirmed absent/already redacted. A generation mismatch or uncertain identity must return a non-success outcome, not be treated as erased. This preflight does not remove the check/delete race by itself: each application's `redact_or_delete_if_generation` callback must atomically verify the same durable erasure fence and the observed generation within the actual mutation. `IsErased(user_id)` reports actual completion only: it returns false for a merely planned/in-progress erase, true only for a completed manifest with `rtbf_coverage_verified = true`, and an unresolved result for a completed manifest without proof. Use `ShouldBlockWrites(user_id)` separately to keep writes/recreation blocked while an erase is planned/in progress or a legacy completed manifest lacks coverage proof. Unknown/corrupt gate state must fail closed in the application.

These checks do **not** establish complete RTBF for an application until its real user-associated store/key inventory and all writer/recreation paths have been wired to the family adapters and accepted against live Roblox DataStore behavior. Keep the RTBF-completeness claim blocked until that application-specific acceptance has passed.


### PlayerDataCore integration

#### Runtime feature configuration

`PlayerDataCore` explicitly configures the features that fit its player-session lifecycle:

| Feature | Configuration | Status |
| --- | --- | --- |
| Cross-server session messaging | `messaging_enabled = true` | Enabled |
| Session takeover requests | `takeover_enabled = true` | Enabled |
| Durable legacy queue | `durable_queue_enabled = false` | Disabled until an application message handler is supplied |
| Transactional operations | `transactional_operations_enabled = false` | Opt-in only; keep disabled until transaction/reconciliation acceptance passes |
| Expired-lease recovery | `lease_recovery_enabled = false` | Opt-in only; requires live-service recovery acceptance |
| Durability | `durability_mode = "balanced"`, `max_dirty_age_seconds = 180` | Enabled with bounded dirty-age tracking |
| Advanced scheduler | DRR selector with weighted shadow comparison, 100% cohort rollout | Enabled on controller start |

The advanced scheduler is configured through RecordStore's revisioned policy and rollout APIs. PlayerDataCore keeps DRR as the active selection algorithm and samples the weighted alternative at a 10% shadow rate. Shadow comparison does not change the active algorithm. The scheduler continues to use RecordStore's shared request-budget governor and protected internal capacity for lease renewal, profile saves, and releases. If scheduler configuration cannot be applied or verified, PlayerDataCore warns and leaves the current scheduler state unchanged rather than preventing player loading.

Mailbox V2 and `RecordStoreV2Acceleration` are not started automatically by PlayerDataCore. Acceleration requires a real mailbox, its authoritative activation guard, an application-owned message handler, and an explicit `Start()` / `BindMailboxWakeups(...)` lifecycle. MessagingService notifications and optional MemoryStore hints are advisory only; durable mailbox polling and reconciliation remain authoritative. Do not enable MemoryStore hints solely because the module is available.

Purchases, receipt authorities, inbox/outbox consumers, maintenance, projections, and user-data erasure remain separate application services. They require application-specific handlers, stores, migration inventories, writer fences, or destructive-operation authorization and should not be enabled as generic per-player session defaults.

`src/PlayerDataInitializer/PlayerDataErasure.luau` is an opt-in family adapter for the current `PlayerDataCore` layout (`PlayerData_Test1`, scope `global`, key `Player_{user_id}`). It supplies a bounded exact-key inventory, an active-player kick hook, a same-key generation-aware erasure fence, and resumable historical-version retention verification. The fence replaces the profile envelope with an intentionally unsupported future implementation marker, so older RecordStore versions fail closed rather than recreating the profile. The same marker remains authoritative for new RecordStore code. Erasure status is read through `RecordStore.get_erasure_status_async`; `RecordStore.erase_user_data_async` installs/reconciles the fence; `RecordStore.purge_erased_versions_async` checks the exact fence version and verifies historical-version expiry in bounded scans. It no longer calls deprecated `DataStore:RemoveVersionAsync` and no longer has an opt-in to call it. Roblox documents that superseded versioned backups expire after 30 days; while historical versions remain, purge reports `Complete = false`, exposes `RetentionUntil`, and keeps the writer fence installed. After the retention deadline, the call re-enumerates versions and only reports completion if the fence is the sole remaining version. If history remains after the documented expiry, the operation fails closed and requires live-platform investigation. Mock-backed regression does not validate live Roblox retention behavior. The default 1,024-version scan is bounded, so callers must resume until `Complete == true`.

The manifest store is injected rather than silently constructed by this adapter. It must provide `GetAsyncFresh` that bypasses Roblox's cached read view and an atomic `UpdateAsync` adapter suitable for the coordinator's compare-and-update manifests. Do not substitute cached reads or a non-atomic read/write pair.

```luau
local PlayerDataErasure = require(script.Parent.PlayerDataErasure)

local coordinator = PlayerDataErasure.new(manifest_store_adapter, {
    -- Set true only after auditing every user-key layout owned by PlayerDataCore.
    profile_family_verified = false,

    -- Bind the durable plan to a reviewed complete application key-family manifest.
    application_inventory_manifest_id = nil,

    -- Keep false until every direct writer/recreation path is independently audited and fenced.
    writer_inventory_verified = false,

    -- Verify the rendered templates against independent, deployment-specific evidence.
    verify_templates = function(user_id, rendered_templates)
        return false -- keep the destructive gate closed until verified
    end,

    -- Add every other user-associated store/key family in the application here.
    additional_families = {},
})

local plan = coordinator:PlanAsync(user_id, erasure_id)
if plan.code == "success" and plan.rtbf_coverage_verified == true then
    local progress = coordinator:ExecuteAsync(user_id, erasure_id, 1)
end
```

The default configuration deliberately does not certify RTBF coverage. Replace the example verification callback only after the full application's key families and templates have been independently audited. Every `additional_families` entry must provide complete inventory, exact templates, a durable writer fence, dependency checks, and a generation-aware action that validates the same erasure fence atomically with its mutation. Keep `ShouldBlockWrites(user_id)` fail-closed when manifest state is missing, corrupt, or uncertain.

This adapter covers one known profile family; it cannot discover arbitrary DataStores or verify application-owned secondary keys. The new inventory-manifest ID and writer-audit attestation are required by the adapter but do not create evidence by themselves. It does not make the overall application RTBF-complete. Historical-version retention, cross-server kick timing, stale-server behavior, and the full erasure flow still require acceptance in a real Roblox test experience before any completeness claim. Maintain the external inventory and direct-writer audit in [the RTBF application inventory guide](docs/rtbf-application-inventory.md).


## Independent maintenance runner

`RecordStoreMaintenanceRunner` is an opt-in runner around `RecordStoreV2.Maintenance.NewCompactor`. It defaults to `dry_run`; `execute` mode refuses construction without both application authorization and a durable writer-fence callback. The runner rechecks authorization/fencing before a step and immediately before each generation-aware delete. Its checkpoint adapter must atomically compare the expected revision, persist the next revision, cursor, processed/removed counts and status, and return whether that write was confirmed.

The reusable `src/PlayerDataInitializer/RecordStoreMaintenanceRobloxAdapter.luau` implements bounded `ListKeysAsync` pagination, uncached `GetAsync` inspection, and revision-CAS checkpoints in a separate store. The application must still supply `is_eligible`, `dependencies_clear`, and `atomic_delete_if_generation(store, item, expected_generation, job_id)`. The delete callback must atomically compare the current generation and enforce the durable job fence within the protected mutation; a separate `assert_fence` call alone has a time-of-check/time-of-use race. The adapter deliberately has no unsafe default delete. Execute-mode delete outcomes are `deleted`, `already_absent`, `skipped`, and `unknown`; unresolved or unsupported outcomes stop progress and preserve the prior page cursor. The `removed` counter counts eligible items confirmed absent (`deleted` or idempotent `already_absent`), not only physical deletions performed during the current attempt. See [maintenance adapter integration](docs/maintenance-adapter-integration.md).

`runner:Run(max_steps, batch_size, budget_ms)` defaults to at most eight steps, one key per checkpoint, and a 25 ms cooperative target. Single-key checkpoints are recommended for destructive operations. Multi-key pages are completed before advancing the page-level cursor. `budget_ms` is enforced between fully checkpointed steps; a slow page read or deletion can exceed the target, after which the runner yields without rereading or replaying work whose checkpoint was confirmed. Reuse the same stable `job_id` to resume the same inventory, and never reuse it for another job. The runner does not enumerate arbitrary DataStores, supply the application's key-family inventory, or implement a production delete adapter. Live Roblox storage validation remains a separate release gate.
