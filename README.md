# RecordStore

[![CodSpeed](https://img.shields.io/endpoint?url=https://codspeed.io/badge.json)](https://app.codspeed.io/alphanumeric-moderate/RecordStore?utm_source=badge)

RecordStore is a server-side Roblox Luau persistence module.

## Install in Roblox Studio

The Rojo projects map `src/PlayerDataInitializer` to a Script named `ServerScriptService.PlayerDataInitializer`. Its child ModuleScripts include `PlayerData`, `PlayerDataCore`, `RecordStore`, `IntegerInfinityValue` and `InfiniteMathValue`. The scheduler and Mailbox V2 implementations are embedded in `RecordStore.luau`. InfiniteMath Revised is vendored at `src/InfiniteMath` and mapped to `ReplicatedStorage.InfiniteMath`.

**`InfiniteMath` must be a ModuleScript at `ReplicatedStorage.InfiniteMath`.** The vendored InfiniteMath Revised module is outside `PlayerDataInitializer` because `InfiniteMathValue` resolves it from `ReplicatedStorage`. Do not move `InfiniteMath` into `PlayerDataInitializer`.

Use `default.project.json` for the standard setup. The initializer starts the shared controller and registers `BindToClose` shutdown handling. Use exactly one initializer.

For manual Studio installation, preserve the hierarchy below. Create each `.luau` source as a `ModuleScript`, except `init.server.luau`, which is the source of the normal server `Script` named `PlayerDataInitializer`.

```text
ServerScriptService
└── PlayerDataInitializer (Script; source: init.server.luau)
    ├── PlayerData (ModuleScript; PlayerData.luau)
    ├── PlayerDataCore (ModuleScript; PlayerDataCore.luau)
    ├── RecordStore (ModuleScript; RecordStore.luau)
    ├── IntegerInfinityValue (ModuleScript; IntegerInfinityValue.luau)
    └── InfiniteMathValue (ModuleScript; InfiniteMathValue.luau)

ReplicatedStorage
└── InfiniteMath (ModuleScript; source: src/InfiniteMath/init.luau)
    ├── Int (ModuleScript; Int.luau)
    └── Values (Folder)
        ├── FullNames (ModuleScript; FullNames.luau)
        └── Suffixes (ModuleScript; Suffixes.luau)
```

Do not put `InfiniteMath` inside `PlayerDataInitializer`. Its module must be named exactly `ReplicatedStorage.InfiniteMath`, including its `Int` and `Values` children. Use exactly one `PlayerDataInitializer` Script. Use a separate test place or Studio session for compatibility testing.

**Recommended setup with Rojo:** from the repository root, run `rojo serve default.project.json`, open the place in Studio, connect using the Rojo Studio plugin, and sync. The existing project file already maps `src/PlayerDataInitializer` and `src/InfiniteMath` into the hierarchy shown above. To produce a place/model file instead, run `rojo build default.project.json -o RecordStore.rbxlx`.

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
- `src/PlayerDataInitializer/IntegerInfinityValue.luau`: a `NumberValue` factory that rounds finite values to integers while preserving positive infinity, negative infinity, and NaN. The default `kills` field uses this type so non-finite values are not silently replaced with zero.
- `InfiniteMath.format(value, options?)`: the shared abbreviation formatter for native and InfiniteMath numbers. Formatting never changes stored values.
- `src/PlayerDataInitializer/InfiniteMathValue.luau`: an adapter for the vendored InfiniteMath Revised module. It persists the number's normalized `first`/`second` pair inside a versioned JSON envelope and provides `get`/`set` helpers for a replicated StringValue backing instance. With the default schema, this adapter is not required during startup; `PlayerDataCore` loads it only when an `InfiniteMathValue` field is configured or used.
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
InfiniteMath fields accept an InfiniteMath value (or a supported input accepted by `InfiniteMathValue.normalize`)
and serialize it without coercing it to a native `number`. To use InfiniteMath, enable a field in
`CONFIG.data`, for example `cash = define_data_field("InfiniteMathValue", 0)`. InfiniteMath values retain
their normalized `first`/`second` serialization in `PlayerDataValues`; the leaderboard remains a formatted,
display-only `StringValue`.

`Set` is server-side. Do not use it as a client-authoritative economy or permission boundary; validate
gameplay actions and authorization on the server before changing protected fields.

### Reset-on-join data fields

Pass `"ResetOnJoin"` as the third argument to `define_data_field` to restore that field to its configured default whenever its record is successfully loaded:

```luau
equipped = define_data_field("StringValue", "Default", "ResetOnJoin")
```

The reset is applied during post-load normalization and written through the active RecordStore session before the player is marked loaded. Only fields explicitly configured this way are reset; other saved fields remain unchanged. A field that already equals its default does not trigger a redundant normalization write. Changes made during the active session remain persistent normally, but the selected field is reset again on the next join. The third argument accepts either one rounding mode (`"nearest"`, `"floor"`, `"ceil"`, or `"trunc"`) or `"ResetOnJoin"`.

### Number formatting

InfiniteMath owns the shared number-abbreviation path. Use its static formatter for native Luau numbers or pass a constructed value for ranges beyond native numbers:

```lua
local InfiniteMath = require(game:GetService("ReplicatedStorage"):WaitForChild("InfiniteMath"))

print(InfiniteMath.format(1_250)) -- 1.25K
print(InfiniteMath.format(1_000_000_000_000)) -- 1T
print(InfiniteMath.format(InfiniteMath.new("1,1000"))) -- InfiniteMath's extended suffix range
```

The default `PlayerDataCore` configuration abbreviates `Kills` using `define_leaderstat("kills", "Kills", { decimals = 2 })`. Native numeric and `InfiniteMathValue` leaderstats share `InfiniteMath.format`, including InfiniteMath's suffix table and scientific-notation fallback. Explicit precision accepts integers from 0 through 6; `trim_trailing_zeros` controls whether fractional trailing zeros are kept. Formatting changes display text only, never persisted values.

### InfiniteMath support

`ReplicatedStorage.InfiniteMath` exposes the vendored InfiniteMath Revised library. Configure large-number fields with `define_data_field("InfiniteMathValue", 0)`. The `InfiniteMathValue` adapter stores a versioned JSON envelope in the profile and a replicated `StringValue`, then reconstructs an InfiniteMath number when read.

```luau
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local InfiniteMathValue = require(ServerScriptService:WaitForChild("PlayerDataInitializer"):WaitForChild("InfiniteMathValue"))
local InfiniteMath = require(ReplicatedStorage:WaitForChild("InfiniteMath"))

local cash = player.PlayerDataValues.cash
local current = InfiniteMathValue.get(cash)
InfiniteMathValue.set(cash, current + InfiniteMath.new("100"))
```

InfiniteMath Revised represents values using IEEE-754 double-precision floating-point significands and exponents. It extends representable range far beyond native `1e308`, but it is not arbitrary-precision arithmetic: values retain roughly 15–17 significant decimal digits, exponent increments can become unresolvable once the exponent magnitude exceeds `2^53`, and addition/subtraction deliberately discard terms more than 16 decimal orders below the larger operand. These precision and range limits are covered by regression tests; exact large-integer arithmetic requires a separate arbitrary-precision representation. The decimal exponent component must be an integer. `Reverse()` converts to a native Luau number and can underflow or overflow by design. `floor`, `ceil`, `round`, `modf`, and logarithms have regression coverage for tiny values and invalid domains; `log(0)` explicitly errors because negative infinity is not representable. `Number:Reverse()` converts back to a native Luau number and can therefore underflow to zero or overflow to infinity outside the native range. Formatting avoids silently displaying such tiny nonzero values as zero. Leaderboard encodings clamp very small values to the negative cap and reject malformed or non-finite decode inputs.

New values use the `InfiniteMathValue` JSON format version 1. InfiniteMath Revised is vendored from `imezx/InfiniteMath` at upstream commit `7a846efdd1f63c6f38ccf2cbd0afda382ffc5ccf`; its MIT license is included in `THIRD_PARTY_NOTICES/InfiniteMath-MIT.txt`. Existing version-2 CodeNum payloads that fit InfiniteMath are normalized into the new format. Legacy symbolic values that cannot be represented by InfiniteMath are preserved verbatim and remain displayable rather than being silently replaced with defaults. Such preserved legacy values cannot be used as ordinary InfiniteMath numbers until explicitly converted to a representable value.

The StringValue transport retains a conservative 199,999-byte payload limit. InfiniteMath's built-in suffix formatting is used for its supported suffix range, with scientific notation for larger exponents.
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

This project intentionally omits `ServerScriptService.InfiniteMathValue` while keeping the real `ReplicatedStorage.InfiniteMath` module. Open the resulting place in Roblox Studio and run a server playtest. The mapped `PlayerDataSetRegression` must initialize the player, update the formatted `Kills` display, and complete its persistence assertions without requiring `InfiniteMathValue`.

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

Scheduler design is governed by [PR #39](https://github.com/alphanumeric-moderate/RecordStore/pull/39), the latest durable-messaging and durable-save-recovery specification. In particular, its sections 26.13, 27.4, 29 and P0 release blockers 9-10 in section 31 govern dirty-age-aware saves, bounded unknown-outcome reconciliation, mutation backpressure, and the critical persistence reserve. This PR implements only the scheduler side of that contract; the production-path unknown-save/renewal reconciler and its fault-injection acceptance gates remain unimplemented and must not be treated as satisfied. The focused scheduler regression suite runs under Lune. CodSpeed measures FIFO, weighted, deadline and DRR against the same synthetic multi-owner/work-class input in separate benchmark entries. These establish local algorithm behavior and relative cost only; they do not prove Roblox DataStore latency, quota, cross-server behavior or production rollout safety.

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

The preview is a dry run only. It runs non-yielding migration callbacks against a read-only snapshot, validates each step, and returns bounded path/type changes without writing the migrated data. The registry and migration code are not persisted by RecordStore, and this API does not automatically migrate profiles during `Open`; guarded execution, durable registry manifests, quarantine, and crash-safe migration acceptance remain unfinished roadmap work.

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

`RecordStoreV2` is a side-effect-free-on-require, opt-in facade for durable cross-profile sagas, versioned migration manifests, profile diagnosis/repair and quarantine records, erasure plans, eventual projections/unique reservations, bounded redacted traces with per-event durability provenance, and resumable maintenance. All storage-facing workflows accept explicit DataStore-like adapters and use bounded records rather than scanning an entire keyspace.

The saga coordinator is a **recoverable multi-key workflow**, not a cross-key atomic transaction. Use stable transfer IDs, retain the source/recipient operation IDs, and reconcile `unknown` before deciding whether to retry or compensate. If automated reconciliation is insufficient, `Sagas:RequireManualResolutionAsync(id, request, expected_phase, expected_status, manual_request_id, operator_id, reason)` durably pauses a nonterminal saga against its expected state. `Sagas:ResolveManualAsync(id, request, manual_request_id, resolution_id, decision, operator_id, reason, verify_outcome?)` supports `resume`, `confirm_settled`, and `confirm_rejected`; terminal decisions require a caller-supplied verifier that proves the durable cross-profile outcome and returns a stable evidence ID. Replays with the same resolution ID are idempotent, stale snapshots conflict, and a saga in `manual_resolution_required` cannot proceed through normal automatic retry. Trace events use unique `trace_event_id` values rather than process-local sequence numbers for deduplication. `Tracing:GetOperationTrace` labels events `process_local`; `Tracing:GetOperationTraceAsync` marks records as `durable_store`, `process_local`, or `durable_store_and_local`, and returns an `evidence_summary`: `process_local_events` and `durable_events` count unique returned events observed in those respective sources (including overlaps), while `process_local_only_events`, `durable_only_events`, and `durable_and_local_events` partition those sources. These fields describe evidence provenance, not a linearizable global history. Payloads and player identity fields are deliberately omitted. Projection rows are eventual and require durable source revision/event IDs. Event receipts retain a bounded fingerprint of the canonical event payload, so reusing a recent event ID for different content returns a conflict instead of silently treating it as a duplicate; older IDs outside the 64-receipt window are still protected from reapplication by source-revision checks. `Projections:RebuildDurableAsync(name, rebuild_id, source_snapshot_id, fetch_page, max_pages?)` persists bounded rebuild progress and can resume with the same stable rebuild ID after restart. The `fetch_page(cursor, page_size, source_snapshot_id)` adapter must return `items, next_cursor, complete, observed_snapshot_id` and enforce the immutable source snapshot. Completed pages must return no next cursor; incomplete pages must return an advancing cursor; `GetRebuildStatusAsync(name, rebuild_id)` reads the durable cursor/status. A rebuild ID cannot be reused with a different snapshot, and pages are limited to 64 events. Erasure coverage is only as complete as the application-provided family inventories, writer fences, dependency checks, and key templates. Each family inventory callback must return a dense list of `{ name, scope, key, generation }` locators plus a second return value of `true` only when the list is exhaustive; missing completeness flags, oversized lists, and template-unmatched locators prevent `rtbf_coverage_verified` from being true. `coverage[family].unmatched_count` and a bounded `unmatched_samples` list surface mismatches for operator follow-up.

Versioned runtime policy updates are routed to the current RecordStore scheduler policy API when scheduler fields are present. `max_dirty_age_seconds` is diagnostic/SLO policy; it does not create an unconditional save guarantee. The V2 facade does not register hidden request hooks or enable Mailbox V2 globally. Provide an explicit activation guard.

Durable migration manifests and quarantine records help coordinate operators. `ProfileDoctor.Restore` now fails closed unless the application supplies an authorization callback and an erasure-status callback, uses active session ownership and expected revision, binds the transaction to the preflight profile digest, preserves reserved RecordStore keys, and records operator identity/reason. `ProfileDoctor.CheckWritableAsync` provides a fail-closed pre-write gate, but it is not an atomic fence by itself: every writer must integrate it alongside a durable writer-fencing protocol to prevent check/write races. These services remain opt-in and require real Roblox service/rollback acceptance before production enablement.

## Opt-in outbox-to-Mailbox V2 delivery

`RecordStoreOutboxMailboxAdapter` adapts `Record:DispatchOutboxAsync()` to the embedded Mailbox V2. It verifies the resolved destination's store, scope, profile key, and optional UserId, requires an explicit activation guard, binds Mailbox V2 only when the destination Record is active and its legacy queue is empty, and uses the durable outbox event ID as the mailbox idempotency key.

The destination receipt is the stable Mailbox V2 message ID. The source outbox is marked delivered only after Mailbox V2 returns `accepted` or `duplicate` with that non-empty ID. Unknown enqueue/bind outcomes throw so the source outbox records an uncertain outcome and retries the same event ID. Known rejections do not receive a success receipt.

This is **durable mailbox acceptance**, not proof that the destination's eventual handler ran or that an arbitrary external side effect completed. Keep destination handlers idempotent, check `payload_version`, and treat external effects as at-least-once. The adapter never enables Mailbox V2 globally; the application supplies the rollout/activation guard.

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

The idempotency receipt is retained only for the configured window; this does not guarantee lifetime suppression after expiry. Products that require lifetime uniqueness need a permanent domain ledger or durable entitlement model. This initial adapter covers legacy developer-product receipts only; explicit status lookup, transfer receipt types, cross-profile workflows, and live Roblox acceptance remain separate work.

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
