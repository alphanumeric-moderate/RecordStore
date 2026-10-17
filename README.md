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


## RecordStore v2 feature services

The v2 feature layer is opt-in and lives at
`ServerScriptService.PlayerDataInitializer.RecordStoreV2`. It receives explicit dependencies on
`RecordStore` and `RecordStoreMailboxV2`. Runtime policy must be configured before creating the
first Record; adaptive mode remains disabled unless explicitly enabled.

```lua
local DataStoreService = game:GetService("DataStoreService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local HttpService = game:GetService("HttpService")

local RecordStore = require(script.Parent.RecordStore)
local MailboxV2 = require(script.Parent.RecordStoreMailboxV2)
local RecordStoreV2 = require(script.Parent.RecordStoreV2)
local DataStoreAdapter = require(script.Parent.RecordStoreV2DataStoreAdapter)
local Acceleration = require(script.Parent.RecordStoreV2Acceleration)

local runtime_code, runtime_error = RecordStore.configure_runtime({
    revision = 2,
    runtime_profile = "balanced",
    server_role = "standard",
    adaptive_runtime_enabled = true,
    adaptive_min_concurrent_requests = 1,
    adaptive_max_concurrent_requests = 4,
    critical_request_reserve = 1,
    adaptive_queue_budget_share = 0.2,
})
assert(runtime_code == "success", runtime_error)

local owner = {
    store_name = "PlayerRecords",
    scope = "global",
    profile_key = "player-" .. tostring(player.UserId),
    user_id = player.UserId,
}
local record = RecordStore.new(owner.store_name, owner.scope, owner.profile_key, {
    schema_version = 1,
    user_ids = { owner.user_id },
})
local open_code, open_error = record:Open({ coins = 0 })
assert(open_code == "created" or open_code == "loaded", open_error)

local store = DataStoreAdapter.new(RecordStore, "RecordStoreMailboxV2", "global")
local mailbox = MailboxV2.new(store, owner, {
    active_record = record,
    encode = function(value)
        return HttpService:JSONEncode(value)
    end,
})
-- Check and drain the legacy queue before switching this Record to V2.
local bind_code, bind_error = record:BindMailboxV2Async(mailbox)
assert(bind_code == "success", bind_error)

local V2 = RecordStoreV2.new(RecordStore, MailboxV2, {
    acceleration_module = Acceleration,
})
local wakeups = Acceleration.new({
    request_runner = RecordStore,
    operation_deadline_seconds = 5,
    memory_map = MemoryStoreService:GetHashMap("RecordStoreV2Wake"),
})
local started, start_error = wakeups:Start()
if not started then warn(start_error) end -- durable polling remains the fallback

local function handle_message(payload, message)
    if type(payload) ~= "table" or type(payload.coins) ~= "number" then
        return false, "invalid coin payload"
    end
    local command = {
        message_id = message.Id,
        message_type = message Type field,
        payload = payload,
    }
    local material = V2.Canonicalize(command)
    local fingerprint = V2.Fingerprint(command)
    if type(fingerprint) ~= "string" then return false, "command is not canonical" end

    local code, message_error = record:ApplyInboxAsync(
        message.Id,
        fingerprint,
        function(data)
            local next_data = if type(data) == "table" then table.clone(data) else {}
            next_data.coins = (tonumber(next_data.coins) or 0) + payload.coins
            return next_data
        end,
        material
    )
    return code == "success" or code == "duplicate", message_error
end

local bound, bind_error = V2.BindMailboxWakeups(wakeups, owner, mailbox, handle_message, 8)
assert(bound, bind_error)
```

The example assumes the surrounding game script has a `player` variable and a
server-authoritative policy for which messages are allowed to grant coins. The reducer must remain
deterministic, non-yielding, and free of external side effects. The per-message inbox receipt is what
makes reprocessing the same mailbox message safe after a crash. Arbitrary effects outside the profile
transaction remain at-least-once and need their own durable idempotency/reconciliation.

The v2 service exposes bounded inbox batches, grouped outbox dispatch, transaction receipts, a
server-local governor wired through RecordStore's actual request gate, revisioned runtime profiles,
critical save/release reserve, backpressure and telemetry, purchase-receipt handling, schema
migrations, transfer sagas, Profile Doctor and guarded restore, RTBF erasure planning, eventual
projections and unique reservations, tracing, payload/codec utilities, and resumable compaction.
After `Record:BindMailboxV2Async(mailbox)` succeeds, `Record:EnqueueAsync`, `Record:ProcessQueueAsync`,
and `Record:GetQueueAsync` use the bound V2 mailbox; an unbound Record retains the legacy queue behavior.
Binding first checks the existing legacy queue and returns `busy` if pending legacy messages remain,
so drain those messages before switching. The legacy `GetDeadLettersAsync` view is bounded to 1,000
entries; legacy claim/replay/discard methods fail closed on a V2-bound Record because V2 uses operation
IDs and replay generations. Use `MailboxV2.GetDeadLettersAsync`, `MailboxV2.ReplayDeadLetterAsync`, and
`MailboxV2.DiscardDeadLetterAsync` directly for V2 dead-letter operations. Important operations should
supply a caller-stable `idempotency_key` in the optional enqueue options.

The DataStore adapter preserves key UserIds/metadata on updates and uses the shared RecordStore
request gate. It intentionally exposes no unconditional physical-delete method. The wake-up
accelerator uses fixed shard topics, a bounded local candidate set, optional expiring MemoryStore
hints, and periodic per-owner polling. Pass `request_runner = RecordStore` to route MessagingService
and MemoryStore operations through the shared work-class/concurrency gate. A hint is never an
acceptance receipt or permission to execute work. Each dispatch requires a bound active Record whose store, scope, profile key, UserIds and session
state match the mailbox owner.

The library reserves the `__recordstore_v2_` prefix for its optional profile-data ledgers. Do not
store application fields under this prefix. Cross-key workflows remain sagas, projections are
eventually consistent, and strict `ordering_key` semantics and exactly-once arbitrary external
effects are not promised. Erasure still needs complete application inventories, verified Roblox key
templates, writer fences, dependency clearance, and generation-aware deletion/redaction. The full
mixed-version rollout protocol and these integration guarantees are release gates, not results of
adding helper APIs.

The V2 advanced governor is shared by V2 facades that wrap the same core RecordStore module. It applies class admission, request observation, and circuit decisions to V2 DataStore-adapter calls before the core request gate makes the final admission decision. Its `options.runtime` values seed the governor only when it is first created for a core module; use `V2.ApplySchedulerPolicy({ revision = currentRevision + 1, ... })` for later updates. Unknown fields and out-of-range values are rejected. It remains a local scheduling model, not the production selector for every mailbox, outbox, and maintenance operation; the core RecordStore request gate remains authoritative for shared request admission.

The authoritative section-by-section design map is
[`docs/superpowers/specs/2026-10-17-recordstore-v2-implementation-matrix.md`](docs/superpowers/specs/2026-10-17-recordstore-v2-implementation-matrix.md).
It separates code presence from compilation, failure-test, benchmark and Roblox acceptance status.

PR #35 currently uses a `[benchmark-only]` phase marker. During that phase the CodSpeed workflow
skips regression/failure suites and benchmarks successful paths, including the shared request gate,
grouped outbox dispatch and wake-up acceleration workloads. These are configured workloads, not
results: a fresh run on the current head is not yet verified. Remove the marker only in the separate
verification pass. Lune/Mock measurements are not real Roblox service latency or production acceptance
evidence.

## Durability status and session waiting

Call `record:GetDurabilityStatus()` to inspect dirty and durable generations, the tracked age of unsaved changes, the last confirmed save, and whether the local write outcome remains uncertain. `record:SubscribeDurabilityRisk(callback)` sends edge-triggered transitions when the configured dirty-age threshold is exceeded, a write outcome is uncertain, or the condition recovers. The default `max_dirty_age_seconds` is 300 seconds. Set initial policy through `RecordStore.configure_runtime({ ... })` before the first Record is created; after startup, validated revisioned patches can be applied through `RecordStore.apply_runtime_policy({ revision = nextRevision, max_dirty_age_seconds = ... })`. Stale or repeated policy revisions are rejected. If a runtime policy provider is configured, it must also publish monotonically increasing revisions. Observer capacity is bounded per Record.

`RecordStore.get_health_snapshot(max_records)` provides a bounded server-local summary; it does not prove that every profile or every server is healthy. `record:WaitForSessionAsync(default_data, options)` wraps the existing durable `Open` path and reports competing-session observations, retry scheduling, cancellation, acquisition, and fencing/loss. It never treats an observed expired lease as an ownership token and does not bypass the existing cooperative takeover protocol. A `session_status_unavailable` result, especially after an unknown write outcome, requires reconciliation instead of blindly retrying an external effect.
