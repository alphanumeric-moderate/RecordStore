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
- `examples/PlayerData.server.luau`: a standard Script that starts the controller and shuts it down from `BindToClose`.

The default Rojo project maps the three ModuleScripts, but does **not** include the example server Script. To build the project with the example Script included:

```sh
rojo build examples.project.json -o RecordStore-PlayerDataExample.rbxlx
```

The included `PlayerDataCore` example uses the store name `PlayerData_Test1`. Change `CONFIG.store_name` in `src/PlayerDataCore.luau` before using it for a live production dataset. Review the config's keys, defaults, schema version, and leaderboard values before publishing.

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
