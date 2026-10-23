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

Scheduler design is governed by [PR #39](https://github.com/alphanumeric-moderate/RecordStore/pull/39), the latest durable-messaging and durable-save-recovery specification. In particular, its sections 26.13, 27.4, 29 and P0 release blockers 9-10 in section 31 govern dirty-age-aware saves, bounded unknown-outcome reconciliation, mutation backpressure, and the critical persistence reserve. The production code contains bounded save/renewal/release reconciliation, observable durability
risk/admission states, and opt-in same-process expired-lease CAS reacquisition. Automated tests cover
successful reacquisition, response loss after the CAS commit, and a competing-owner race. The full
PR #39 fault-injection acceptance gates and live Roblox Studio/server validation remain outstanding;
do not treat the entire durability contract as release-verified. The focused regression suite runs under Lune. CodSpeed measures FIFO, weighted, deadline and DRR against the same synthetic multi-owner/work-class input in separate benchmark entries. These establish local algorithm behavior and relative cost only; they do not prove Roblox DataStore latency, quota, cross-server behavior or production rollout safety.

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
