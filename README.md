# RecordStore

RecordStore is a server-side Roblox Luau persistence module. This repository contains the V6 compatibility-fix source and a mock-backed regression script for legacy-envelope recovery.

## Repository layout

```text
RecordStore/
├── src/
│   └── RecordStore.luau
├── tests/
│   └── RecordStore_OpenCorrupt_CompatibilityRegression.server.luau
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

## V6 compatibility fix

The source includes adapters for historical RecordStore envelope shapes, generation-zero normalization/recovery, and fail-closed handling for legacy records whose ownership lease cannot be verified. See [Compatibility notes](docs/compatibility.md).

## Verification status

The regression cases are included but require Roblox Studio to execute. A successful file copy or Rojo build is not proof that persistence behavior has passed a live Studio test. Preserve a backup before applying this module to a live experience, and test against a dedicated test DataStore name first.
