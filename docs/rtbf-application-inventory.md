# RTBF application key-family and writer inventory

**Status: incomplete; RTBF completeness must not be claimed.** The repository's built-in `PlayerDataErasure` family describes only `PlayerData_Test1 / global / Player_{user_id}`. This static profile layout does not establish coverage of every store, legacy key, sidecar, shared record, direct writer or recreation path used by a game.

## Required inventory manifest

Create a reviewed, versioned inventory manifest before enabling any destructive erasure. Include one row for every independently user-associated key family:

| Required field | Evidence to record |
|---|---|
| Family name and manifest revision | Stable name, reviewer, review date, source commit/version |
| Store and scope | Exact DataStore name and exact scope, including default/empty scopes |
| Key templates | Exact key templates with explicit `{user_id}` binding; document multi-user/shared-key cases |
| Legacy layouts | Old prefixes, old scopes, migration aliases and obsolete schemas that may still be read or recreated |
| Sidecars and relationships | Receipt, inbox/outbox, mailbox, saga, projection, index, trace, entitlement, cache-derived and other records that can retain user-linked data or references |
| Inventory source | Bounded pagination/enumeration source, snapshot/version, end-of-inventory proof, truncation/capacity behavior |
| Generation and erasure action | Exact generation/revision observed, atomic redaction/deletion contract, ambiguous-outcome reconciliation |
| Dependency/retention policy | External references, shared ownership, historical-version retention, and when cleanup may resume |
| Writers/recreation paths | Every module, script, server, job, migration, admin path and API that can write or recreate the family |
| Durable writer fence | Evidence the write path checks and enforces the erasure generation/fence at the same mutation boundary |
| Acceptance evidence | Test place/version, execution date, scenarios and result artifacts |

The inventory must be independently reconciled against the complete source tree and deployment/application scripts. Search for `GetDataStore`, `SetAsync`, `UpdateAsync`, `IncrementAsync`, `RemoveAsync`, custom persistence wrappers, `ProcessReceipt`, job scripts, migration scripts, admin commands, and every module that creates profiles or sidecars. Include code that bypasses RecordStore. Source-code search alone is not sufficient for dynamically named stores or scripts outside this repository; reconcile against the published experience and any private application repositories.

## Required writer fence

A separate preflight read followed by an unconditional write is not sufficient. Every active writer and every recreation path must enforce the erasure fence/generation at the mutation boundary, or be disabled and drained. For each family prove that a stale server, old version, scheduled job, retry queue, restore tool or admin script cannot re-create the data after the fence is installed. Legacy/mixed-version writers must fail closed until they are retired or fenced.

Do not use `RemoveVersionAsync` as a workaround for retention. Keep the permanent same-key fence and only report completed cleanup after the retention scan and dependency requirements prove it safe. Mock results do not establish Roblox retention timing or no-recreation behavior.

## `PlayerDataErasure` activation contract

The included adapter requires all of the following before the generic erasure coordinator can certify this family's coverage:

- `profile_family_verified = true` for the exact configured PlayerDataCore family;
- `application_inventory_manifest_id` containing the reviewed, immutable application inventory manifest ID;
- `writer_inventory_verified = true` after the independent direct-writer/recreation audit;
- `verify_templates` rechecking the exact configured templates for the current UserId; and
- successful bounded inventory, generation checks, dependency checks and durable manifest reconciliation.

The first three fields are explicit application attestations. Setting them does not create evidence by itself; the reviewed manifest and live acceptance record must exist. The durable erasure manifest binds to the inventory-manifest ID and fails closed if that ID changes on resume. Any change to key layout or writers requires a new reviewed manifest and a new acceptance pass.

## Live acceptance checklist

- Verify all templates and exact key locators for representative existing, deleted, legacy and multi-profile users.
- Install the durable write/recreation fences and prove stale writer attempts fail across multiple live Roblox servers.
- Inject partial inventory, truncated pagination, unknown writes, generation changes, dependency failures, shutdown/restart and repeated execution with the same erasure ID.
- Validate documented version retention and resumable history cleanup using disposable real DataStore keys.
- Demonstrate no recreation after completion, and reconcile every manifest entry back to the independently reviewed inventory.
- Keep the RTBF-completeness claim blocked until every inventory row and every writer path has evidence and independent review.
