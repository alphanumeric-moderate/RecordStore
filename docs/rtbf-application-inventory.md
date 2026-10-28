# RTBF application key-family and writer inventory

**Status: incomplete; RTBF completeness must not be claimed.** The source tree now includes `RecordStoreApplicationInventory` and `PlayerDataErasureManifestBinding` to validate a bounded manifest and bind explicit family adapters. They do not discover deployed stores/writers, and manifest fields or callback attestations do not prove exhaustive coverage. The built-in `PlayerDataErasure` family still describes only `PlayerData_Test1 / global / Player_{user_id}` unless additional reviewed adapters are supplied.

## Repository-known data surfaces that must be reconciled

The current source tree identifies these additional surfaces. This is a source-level inventory of known candidates, **not** an exhaustive deployed-game inventory or a claim that their erasure actions have been implemented.

| Surface | Locator/ownership model | User-associated content or write path | RTBF disposition |
|---|---|---|---|
| PlayerDataCore profile and embedded sidecars | `PlayerData_Test1 / global / Player_{user_id}` | Profile data plus same-envelope RecordStore transaction/Inbox receipts, Outbox events, and configured permanent per-profile purchase ledger. Main writes are through RecordStore and PlayerDataCore. | The included adapter installs the generation-bound same-key fence and retention-checks history. It covers this one family only; live writer/recreation acceptance remains outstanding. |
| Global `PurchaseDataStoreAuthority` | Application-configured DataStore/scope; key derived from `key_prefix + digest(PurchaseId)`, not from PlayerId | Each authority row can retain PurchaseId, PlayerId, ProductId, status and outcome. `ClaimAsync`, `CommitAsync` and `BackfillAsync` are direct DataStore-backed writers. | The source now exposes `GetErasureLocatorAsync` and `EraseRetainFenceAsync` to replace raw purchase identity with a generation-advancing, non-reversible identity digest while retaining a permanent duplicate-grant fence. **This family is not automatically covered by PlayerDataErasure**; include it in the reviewed manifest and provide a verified adapter. Its complete inventory still depends on the historical PurchaseId source or an independently verified index. |
| Lifetime `PurchaseEntitlementDataStoreAuthority` | Application-configured DataStore/scope; key derived from configured entitlement identity | Non-expiring ownership/reservation rows link entitlement ID to PlayerId, ProductId and PurchaseId. `ReserveAsync`, `CommitAsync`, and `BackfillAsync` write durable authority state. | The source now exposes `GetErasureLocatorAsync` and `EraseRetainFenceAsync`; the retained fence blocks regrant while the raw identity fields are redacted. This family still needs an exhaustive entitlement-ID inventory, a manifest family adapter, and a documented retention decision. Do not delete the uniqueness fence to satisfy cleanup. |
| Application erasure manifest and family binding | The reviewed manifest store and explicit family locators supplied to `PlayerDataErasureManifestBinding` | Erasure plan/progress records contain UserId, exact family locators/generations, and the permanent no-recreation/retention state. | The binding supports explicitly declared family adapters, including purchase/entitlement authority records when supplied. The complete set is still application-owned; retain/minimize manifest identity fields using a reviewed retention protocol without deleting the only durable no-recreation fence. |
| RecordStore V2 Mailbox V2 | Application-configured store, owner identity and bounded message/segment/index routes | Durable message payloads, dead letters and route metadata may contain sender/recipient UserIds or other personal fields. Producers, mailbox migration/operations and the outbox mailbox adapter can write these records. | The generic library has no global UserId-to-mailbox inventory. The application must identify owners, route/index keys, historical V3 records and message payloads that reference the user, then add a bounded inventory and generation/claim-fenced redaction action. |
| V2 sagas, projections/unique reservations, migration/repair manifests, operation traces and maintenance checkpoints | Stores/scopes/keys are injected or application-configured; some keys use transfer, projection, rebuild, job or caller-supplied IDs | Durable payloads can contain source/destination UserIds, receipt identities, user-linked snapshots, diagnostics or references. Their writers are the V2 services and application-supplied adapters. | Inspect each configured workflow and payload schema; include only the user-linked families, with exact locators and dependency semantics. The generic RecordStore repo cannot enumerate arbitrary configured stores or infer data hidden in custom payloads. |
| Erasure coordinator manifest itself | Injected manifest store; current manifest key is `rv2erase-u{user_id}`, and the manifest stores `user_id` plus exact locators/generations | Planning/status/resume writes the manifest to preserve the no-recreation fence and audit trail. | This is also user-associated metadata. Decide and document retention/minimization requirements for completed erasure manifests and the permanent fence. Do not delete the only durable no-recreation fence to satisfy cleanup; if pseudonymization is needed, define a secret-backed stable subject locator and migration protocol rather than an unsalted UserId hash. |

The global purchase authority and mailbox/V2 workflow rows are why a complete source-tree search alone is not enough. Some locator values are supplied only when the game constructs the service, and mailbox/saga/projection payloads may be custom application data. The application inventory must include the deployed configuration and every private application repository in addition to these repository-known components.

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
- `application_inventory_manifest_id` containing the reviewed, immutable application inventory identity;
- `writer_inventory_verified = true` after the independent direct-writer/recreation audit;
- `verify_templates` rechecking the exact configured templates for the current UserId; and
- successful bounded inventory, generation checks, dependency checks and durable manifest reconciliation.

The first three fields are explicit application attestations. Setting them does not create evidence by itself; the reviewed manifest and live acceptance record must exist. The durable erasure manifest binds to the inventory identity and fails closed if it changes on resume. `PlayerDataErasureManifestBinding` derives this identity from both `manifest_id` and `revision` using a length-framed SHA-256 digest within the 128-byte limit. Plans persisted with only the manifest ID fail closed when resumed through this binding. The built-in profile family must declare `generation_field = "fencing_generation"` and `fence_field = "__recordstore_erasure_fence"`. Any change to key layout or writers requires a new reviewed manifest and a new acceptance pass.

## Live acceptance checklist

- Verify all templates and exact key locators for representative existing, deleted, legacy and multi-profile users.
- Install the durable write/recreation fences and prove stale writer attempts fail across multiple live Roblox servers.
- Inject partial inventory, truncated pagination, unknown writes, generation changes, dependency failures, shutdown/restart and repeated execution with the same erasure ID.
- Validate documented version retention and resumable history cleanup using disposable real DataStore keys.
- Demonstrate no recreation after completion, and reconcile every manifest entry back to the independently reviewed inventory.
- Keep the RTBF-completeness claim blocked until every inventory row and every writer path has evidence and independent review.
