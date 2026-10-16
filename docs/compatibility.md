# V6 compatibility notes

The V6 module is based on the latest `RecordStore_OpenCorrupt_CompatibilityFix_v6.luau` source in the project Library. The compatibility adapter is intentionally strict: it recognizes historical layouts only when their identifying fields and field types match, then normalizes accepted records into the current envelope before future writes.

## Covered by the regression script

1. **Reconstruction v2/v3 envelope:** recognizes `__recordStore`, `format`, `revision`, string `fence`, `commitId`, `deleted`, `version`, and `data`; verifies that stored Coins and Inventory survive migration.
2. **Generation-zero baseline:** checks that an inactive baseline can be opened and advanced to generation 1.
3. **Historical recovery:** checks recovery from a valid historical generation-zero baseline when the current version is corrupt.
4. **Previous generation/payload envelope:** migrates a safe older envelope into canonical `data` and advances its fencing generation.
5. **Unverifiable legacy ownership lease:** fails closed when an old envelope retains a lease that cannot be validated, and confirms the stored fixture remains unchanged.

These cases are mock-backed regression coverage. They do not replace a Roblox Studio playtest using the intended Roblox engine version and a dedicated test DataStore.

## Data safety

- Do not hand-edit production DataStore values to force a migration.
- Keep backups and test with isolated DataStore names before deploying.
- A record with an unverified legacy ownership lease must remain unchanged; do not bypass the fail-closed result.
- Treat `corrupt`, `future_schema`, and other failure results according to the calling game's recovery policy; do not silently initialize defaults over existing data.
