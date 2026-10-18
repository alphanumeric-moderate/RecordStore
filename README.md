# RecordStore

[![CodSpeed](https://img.shields.io/endpoint?url=https://codspeed.io/badge.json)](https://app.codspeed.io/alphanumeric-moderate/RecordStore?utm_source=badge)

RecordStore is a server-side Roblox Luau persistence module.

## Install in Roblox Studio

The Rojo projects map `src/PlayerDataInitializer` to a Script named `ServerScriptService.PlayerDataInitializer`. Its child ModuleScripts are `PlayerData`, `PlayerDataCore`, `RecordStore`, `IntegerInfinityValue`, `NumberFormatter`, and `CodeNumValue`. The separate `ReplicatedStorage.CodeNum` module is included for CodeNum-backed fields.

**`CodeNum` must be a ModuleScript at `ReplicatedStorage.CodeNum`.** It is intentionally outside `PlayerDataInitializer` because `CodeNumValue` resolves it from `ReplicatedStorage`. Do not move `CodeNum` into `PlayerDataInitializer`.

Use `default.project.json` for the standard setup. The initializer starts the shared controller and registers `BindToClose` shutdown handling. Use exactly one initializer.

For manual Studio installation, create a normal server `Script` named `PlayerDataInitializer` in `ServerScriptService`; place `init.server.luau` there as the Script source and make the six data modules its direct children. Put `CodeNum` in `ReplicatedStorage` as `ReplicatedStorage.CodeNum`, not under the initializer. Use a separate test place or Studio session for compatibility testing.

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
- `src/PlayerDataInitializer/RecordStore.luau`: the underlying persistence, session ownership, versioning, and recovery API.
- `src/PlayerDataInitializer/IntegerInfinityValue.luau`: a `NumberValue` factory that rounds finite values to integers while preserving positive infinity, negative infinity, and NaN. The default `kills` field uses this type so non-finite values are not silently replaced with zero.
- `src/PlayerDataInitializer/NumberFormatter.luau`: a display formatter for native Luau numbers. Formatting never changes stored values.
- `src/PlayerDataInitializer/CodeNumValue.luau`: an adapter for your CodeNum module. It persists CodeNum's own versioned `encode`/`decode` JSON format and provides `get`/`set` helpers for a replicated StringValue backing instance. With the default schema, this adapter is not required during startup; `PlayerDataCore` loads it only when a `CodeNumValue` field is configured or used.
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
CodeNum fields accept a CodeNum value (or a supported input accepted by `CodeNumValue.normalize`)
and serialize it without coercing it to a native `number`. To use CodeNum, enable a field in
`CONFIG.data`, for example `cash = define_data_field("CodeNumValue", 0)`. CodeNum values retain
their exact serialized representation in `PlayerDataValues`; the leaderboard remains a formatted,
display-only `StringValue`.

`Set` is server-side. Do not use it as a client-authoritative economy or permission boundary; validate
gameplay actions and authorization on the server before changing protected fields.

### Number formatting

Use the formatter directly when you only need display text:

```lua
local NumberFormatter = require(game:GetService("ServerScriptService"):WaitForChild("PlayerDataInitializer"):WaitForChild("NumberFormatter"))

print(NumberFormatter.format(1_250)) -- 1.25K
print(NumberFormatter.format(1_000_000_000_000)) -- 1T
```

The default `PlayerDataCore` configuration abbreviates `Kills` using `define_leaderstat("kills", "Kills", { decimals = 2 })`. Large values display as `1K`, `1.25M`, `1B`, `1T`, `1Qa`, and so on. Other numeric leaderstats can opt in by passing `{ decimals = 2 }` as the third argument to `define_leaderstat` in `src/PlayerDataInitializer/PlayerDataCore.luau`.

A formatted leaderboard entry is a display-only `StringValue`. Its numeric backing value is placed at `player.PlayerDataValues.kills`, and that backing value remains the value persisted by PlayerDataCore. Gameplay scripts must update `player.PlayerDataValues.kills.Value` instead of `player.leaderstats.Kills.Value`, because the leaderboard entry contains text. The `PlayerDataValues` folder name is reserved by this feature.

To opt out for a particular entry, omit the third argument, for example `define_leaderstat("kills", "Kills")`.

Both the default and example Rojo projects include `PlayerDataInitializer` and map its child modules. The regression-test project deliberately does not include the active initializer, preventing test-place startup from opening real player sessions. To build the separate example place:

```sh
rojo build examples.project.json -o RecordStore-PlayerDataExample.rbxlx
```

The included `PlayerDataCore` example uses the store name `PlayerData_Test1`. Change `CONFIG.store_name` in `src/PlayerDataInitializer/PlayerDataCore.luau` before using it for a live production dataset. Review the config's keys, defaults, schema version, and leaderboard values before publishing.

### CodeNum support

`ReplicatedStorage.CodeNum` is a required location contract for CodeNum-backed data; the module is not part of the `PlayerDataInitializer` child-module bundle. `CodeNumValue` looks it up from `ReplicatedStorage` on first use and caches its API.

PlayerDataCore's optional `CodeNumValue` field stores values in your CodeNum module's canonical `encode` / `decode` JSON format (format version 2 in the supplied module). Exact decimal integers, scientific values, special values, hyperoperations, unevaluated expressions, and unary calls are serialized without coercion to native numbers.

The repository includes CodeNum 0.2.0-preview.1 at `src/CodeNum.luau`. Both `default.project.json` and `tests.project.json` map it to `ReplicatedStorage.CodeNum`, so the Rojo projects no longer require a separate CodeNum ModuleScript. The public codec API is `encode(value)`, `decode(serialized)`, and `toString(value)`.

Configure a field and optional leaderboard entry in `src/PlayerDataInitializer/PlayerDataCore.luau`:

```lua
-- In CONFIG.data:
cash = define_data_field("CodeNumValue", 0),

-- In CONFIG.leaderstats.values:
define_leaderstat("cash", "Cash", { decimals = 2 }),
```

The leaderboard uses a display-only `StringValue`; its serialized backing value is `player.PlayerDataValues.cash`. Update it on the server:

```lua
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CodeNumValue = require(ServerScriptService:WaitForChild("PlayerDataInitializer"):WaitForChild("CodeNumValue"))
local CodeNum = require(ReplicatedStorage:WaitForChild("CodeNum"))

local cash = player.PlayerDataValues:WaitForChild("cash")
local current = CodeNumValue.get(cash)
CodeNumValue.set(cash, CodeNum.add(current, CodeNum.integer("100")))
```

RecordStore persists CodeNum's serialized JSON string, not a metatable-backed node or an EternityNum triplet. The StringValue transport uses a conservative 199,999-byte payload limit. Exact integers and scientific nodes use NumberFormatter's custom suffix sequence; hyperoperations/expressions fall back to `CodeNum.toString()` because their decimal magnitude may not be provable. Exact integer multiplication is capped at a 4,096-digit combined operand budget; larger products stay symbolic to avoid unbounded quadratic work.

### Number formatting

The 202-entry sequence is `K, M, B, T`, followed by the `first`, `second`, `third`, and `mult` suffix groups. For example, `1e12` formats as `1T`, `1e15` as `1Qa`, and `1e36` as `1Ud`. Exact CodeNum integer/scientific values use this sequence without converting the entire value to binary64. Once the suffix table runs out, values display in scientific notation.

## Rojo

Build the standard production place, including `PlayerDataInitializer`:

```sh
rojo build default.project.json -o RecordStore.rbxlx
```

Build the isolated regression-test place:

```sh
rojo build tests.project.json -o RecordStore-CompatibilityTests.rbxlx
```

Open the test place in Roblox Studio and run a server playtest. Regression scripts use `RecordStore.Mock`; they do not read or write live DataStore records.

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
fairness, deadline and age-aware selection, a strictly reserved lease-renewal
concurrency slot, delayed-work heaps, expiry/dependency outcomes, retry tokens with
backoff/jitter, bounded callback concurrency, opt-in batch windows for callbacks that
already represent an application-defined batch, shadow comparisons, deterministic trace
replay, and queue/latency metrics. It never combines separate callbacks into a new
business transaction. Owner IDs are bounded to 512 bytes, work IDs to 96 bytes, and
work classes to 64 bytes.

`available_at`, an advisory scheduling deadline, `expires_at`, and the durable
session/claim lease are distinct concepts. A deadline is not a completion guarantee.
An expired item is returned with a typed terminal outcome rather than silently dropped.
The dispatcher retries only an explicit `{ code = "retryable" }` result and only
within configured limits and retry-token admission. A thrown callback is converted to
`unknown` and is not automatically replayed because its side effect may have committed.
Applications must reconcile ambiguous effects using stable business operation IDs.

The scheduler and its due-time heap are **server-local and non-durable**. A process
restart discards queued callbacks. Do not use generic scheduled callbacks as the durable
mailbox or as an exactly-once transaction mechanism. Scheduled entry points may coexist
with existing direct APIs; callers must deliberately route work through the selector when
they require scheduler ordering. Strict `ordering_key` semantics and global/server-instance
priority are not provided.

This implementation follows the scheduler requirements in [design #33, section 29](docs/superpowers/specs/2026-10-17-recordstore-durable-messaging-v2-design.md#29-advanced-scheduling-designs-with-correctness-and-performance-gates). The focused scheduler regression suite runs under Lune and the CodSpeed configuration
includes a fixed synthetic owner/work-class selection workload. These establish local
algorithm behavior and cost only; they do not prove Roblox DataStore latency, quota,
cross-server behavior or production rollout safety.

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
