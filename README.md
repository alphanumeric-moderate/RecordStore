# RecordStore

[![CodSpeed](https://img.shields.io/endpoint?url=https://codspeed.io/badge.json)](https://app.codspeed.io/alphanumeric-moderate/RecordStore?utm_source=badge)

RecordStore is a server-side Roblox Luau persistence module.

## Repository layout

```text
RecordStore/
├── src/
│   └── RecordStore.luau
├── tests/
│   └── RecordStore_OpenCorrupt_CompatibilityRegression.server.luau
├── bench/
│   ├── RobloxShim.luau
│   └── *.bench.luau
├── codspeed.yml
├── docs/
│   └── compatibility.md
├── default.project.json
├── tests.project.json
└── README.md
```

## Install in Roblox Studio

1. Copy `src/RecordStore.luau` into `ServerScriptService` as a **ModuleScript** named `RecordStore`.
2. Require it from server scripts:

   ```lua
   local RecordStore = require(game:GetService("ServerScriptService"):WaitForChild("RecordStore"))
   ```

3. Use a separate test place or Studio session for compatibility testing. Do not place the regression Script in a production server by accident.

## Rojo

The default project maps only the production ModuleScript:

```sh
rojo build default.project.json -o RecordStore.rbxlx
```

To build the isolated regression-test place instead:

```sh
rojo build tests.project.json -o RecordStore-CompatibilityTests.rbxlx
```

Open the test place in Roblox Studio and run a server playtest. The test Script uses `RecordStore.Mock`; it does not read or write live DataStore records.

## Benchmarks

Performance is tracked with [CodSpeed](https://codspeed.io). The benchmarks run
`RecordStore.Mock` scenarios outside Roblox with [Lune](https://github.com/lune-org/lune),
a standalone Luau runtime. `bench/RobloxShim.luau` provides the small set of Roblox
APIs the mock backend needs (`HttpService`, `DateTime`, `Enum`, `task`, ...).

```sh
# run a single scenario
lune run bench/session_lifecycle.bench.luau

# run the regression tests outside Studio
lune run bench/run_regression_tests.luau

# run every benchmark from codspeed.yml with the CodSpeed CLI
codspeed run --mode simulation
```
