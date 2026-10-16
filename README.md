# RecordStore

[![CodSpeed](https://img.shields.io/endpoint?url=https://codspeed.io/badge.json)](https://app.codspeed.io/alphanumeric-moderate/RecordStore?utm_source=badge)

RecordStore is a server-side Roblox Luau persistence module.

## Install in Roblox Studio

1. Copy `src/RecordStore.luau` into `ServerScriptService` as a **ModuleScript** named `RecordStore`.
2. Require it from server scripts:

   ```lua
   local RecordStore = require(game:GetService("ServerScriptService"):WaitForChild("RecordStore"))
   ```

3. Use a separate test place or Studio session for compatibility testing. Do not place the regression Script in a production server by accident.

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

- `src/PlayerDataCore.luau`: a configurable player session, leaderstats, persistence, retry, and shutdown controller.
- `src/IntegerInfinityValue.luau`: a `NumberValue` factory that rounds finite values to integers while preserving positive infinity, negative infinity, and NaN. The default `kills` field uses this type so non-finite values are not silently replaced with zero.
- `src/NumberFormatter.luau`: a display formatter for native Luau numbers. Formatting never changes stored values.
- `src/CodeNumValue.luau`: an adapter for your CodeNum module. It persists CodeNum's own versioned `encode`/`decode` JSON format and provides `get`/`set` helpers for a replicated StringValue backing instance.
- `examples/PlayerData.server.luau`: a standard Script that starts the controller and shuts it down from `BindToClose`.

### PlayerData.Set API

The Rojo project maps `src/PlayerData.luau` to a shared `ServerScriptService.PlayerData` ModuleScript.
Use the included `examples/PlayerData.server.luau` Script (mapped as `PlayerDataInitializer` in
`examples.project.json`) to start the controller and shut it down safely. Gameplay Scripts require the
same ModuleScript, so they share one controller and persistence queue.

When building with default.project.json, add one Script under ServerScriptService to initialize it:

```lua
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
PlayerData:Start()

game:BindToClose(function()
	PlayerData:Shutdown()
end)
```

Use exactly one initializer. The example project already includes this Script as PlayerDataInitializer;
do not add a second initializer when using that project.

```lua
local ServerScriptService = game:GetService("ServerScriptService")
local PlayerData = require(ServerScriptService:WaitForChild("PlayerData"))

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
local NumberFormatter = require(game:GetService("ServerScriptService"):WaitForChild("NumberFormatter"))

print(NumberFormatter.format(1_250)) -- 1.25K
print(NumberFormatter.format(1_000_000_000_000)) -- 1T
```

The default `PlayerDataCore` configuration abbreviates `Kills` using `define_leaderstat("kills", "Kills", { decimals = 2 })`. Large values display as `1K`, `1.25M`, `1B`, `1T`, `1Qa`, and so on. Other numeric leaderstats can opt in by passing `{ decimals = 2 }` as the third argument to `define_leaderstat` in `src/PlayerDataCore.luau`.

A formatted leaderboard entry is a display-only `StringValue`. Its numeric backing value is placed at `player.PlayerDataValues.kills`, and that backing value remains the value persisted by PlayerDataCore. Gameplay scripts must update `player.PlayerDataValues.kills.Value` instead of `player.leaderstats.Kills.Value`, because the leaderboard entry contains text. The `PlayerDataValues` folder name is reserved by this feature.

To opt out for a particular entry, omit the third argument, for example `define_leaderstat("kills", "Kills")`.

The default Rojo project maps the server-side ModuleScripts and `ReplicatedStorage.CodeNum`, but does **not** include the example server Script. To build the project with the example Script included:

```sh
rojo build examples.project.json -o RecordStore-PlayerDataExample.rbxlx
```

The included `PlayerDataCore` example uses the store name `PlayerData_Test1`. Change `CONFIG.store_name` in `src/PlayerDataCore.luau` before using it for a live production dataset. Review the config's keys, defaults, schema version, and leaderboard values before publishing.

### CodeNum support

PlayerDataCore's optional `CodeNumValue` field stores values in your CodeNum module's canonical `encode` / `decode` JSON format (format version 2 in the supplied module). Exact decimal integers, scientific values, special values, hyperoperations, unevaluated expressions, and unary calls are serialized without coercion to native numbers.

The repository includes CodeNum 0.2.0-preview.1 at `src/CodeNum.luau`. Both `default.project.json` and `tests.project.json` map it to `ReplicatedStorage.CodeNum`, so the Rojo projects no longer require a separate CodeNum ModuleScript. The public codec API is `encode(value)`, `decode(serialized)`, and `toString(value)`.

Configure a field and optional leaderboard entry in `src/PlayerDataCore.luau`:

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
local CodeNumValue = require(ServerScriptService:WaitForChild("CodeNumValue"))
local CodeNum = require(ReplicatedStorage:WaitForChild("CodeNum"))

local cash = player.PlayerDataValues:WaitForChild("cash")
local current = CodeNumValue.get(cash)
CodeNumValue.set(cash, CodeNum.add(current, CodeNum.integer("100")))
```

RecordStore persists CodeNum's serialized JSON string, not a metatable-backed node or an EternityNum triplet. The StringValue transport uses a conservative 199,999-byte payload limit. Exact integers and scientific nodes use NumberFormatter's custom suffix sequence; hyperoperations/expressions fall back to `CodeNum.toString()` because their decimal magnitude may not be provable. Exact integer multiplication is capped at a 4,096-digit combined operand budget; larger products stay symbolic to avoid unbounded quadratic work.

### Number formatting

The 202-entry sequence is `K, M, B, T`, followed by the `first`, `second`, `third`, and `mult` suffix groups. For example, `1e12` formats as `1T`, `1e15` as `1Qa`, and `1e36` as `1Ud`. Exact CodeNum integer/scientific values use this sequence without converting the entire value to binary64. Once the suffix table runs out, values display in scientific notation.

## Rojo

Build the production modules without the example Script:

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
