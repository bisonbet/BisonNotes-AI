# Reliable storage and safe SQLite migration plan

Status: **design/source review plus Phase 0, Phase 1 and Phase 3/4 safety work
in progress; GRDB, durable checkpoints, a closed-snapshot verifier, the first
repository write/settings contracts, the SQLite observation cursor and an
isolated resumable metadata/settings coordinator plus an explicit Core Data
source-input boundary are implemented, but no SQLite migration is enabled**.
Implementation branch: `v3.0-sqlitemigration`; clean PR target: `v3.0`, which is
kept at the `v2.5` baseline.
Reviewed 2026-09-07 on `v2.5`, clean starting checkout at
`d64660ba85dc04e6bc2f1fa88263427cb76b37aa` (the pushed `origin/v2.5`).
No production user database or live CloudKit account was inspected. Source review
is not evidence that a particular user's store is healthy, nor a speed benchmark.
The current backend-independent safety slice makes durable-store failure explicit
and blocks normal startup when storage is unavailable; it does not change the
authoritative Core Data backend or authorize a user-store migration.

## Current handoff — 2026-09-09

The current observation checkpoint is `c692c8c7` (`feat: add Core Data
persistent history observation`). It adds a durable Core Data history adapter
and enables retained history for durable stores, but does not subscribe it at
startup or enable SQLite cutover.

The current source-reader/catalog checkpoint is `630a513e` (`feat: add Core
Data migration source reader`). It adds a read-only Core Data snapshot reader
for all six metadata entities, validates permanent identities and relationship
closure, fingerprints the copied projection, and closes the reviewed device-
local/Mistral settings classifications and enum/endpoint validation gaps. It
does not acquire the startup migration gate or write a user SQLite store.

The current source-input boundary checkpoint is `54e6c141` (`feat: add Core
Data migration input boundary`). `CoreDataMigrationInputReader` composes the
closed Core Data metadata snapshot with the typed blocking-settings snapshot
and requires an explicit app-owned source-key inventory so unclassified keys
fail closed. It still relies on the future startup gate to quiesce Core Data
writes and settings mutations, and does not open a live destination.

The current isolated coordinator checkpoint is `5c88828b` (`feat: persist
resumable migration pause state`), following `230e511c` (`feat: add resumable
SQLite migration coordinator`). It finds unfinished runs by exact source
fingerprint/model, emits progress only after committed metadata batches, applies
the validated blocking-metadata settings allowlist, persists cancellation as a
resumable paused state, records definitive conflicts as failed without raw error
text, and verifies the destination before reporting completion. It remains a
disposable-snapshot service: it does not open a live user store, select an active
generation, copy audio, or wire itself to app startup.

The current settings-classification checkpoint is `f8b4d6c7` (`test: cover
legacy settings classifications`), following `e2ff6c0` (`test: compare
settings catalog with CloudKit source`) and `52101ae0` (`test: validate
SQLite settings catalog values`) and `5232640` (`feat: add classified SQLite
settings catalog`).

The preceding implementation checkpoint is `82e687e8` (`test: cover SQLite
schema upgrade and observation contracts`), following `cdd0bf8e` (`feat: add
durable SQLite observation cursor`) and `b71d9984` (`feat: add repository settings and
rename contracts`), `40b431a0` (`feat: add redacted migration
recovery reports`), `9731e69a` (`feat: add resumable metadata
importer`), `5f9744d` (`test: add Core Data source snapshot fixtures`),
`444542ac` (`test: add closed-source SQLite verifier`),
`e612ebdc` (`test: add host-independent SQLite runtime harness`),
`1a03ed6d` (`feat: persist SQLite migration checkpoints`),
`c8f8d2f5` (`feat: add isolated SQLite schema foundation`), `d4e143b4`
(`build: pin GRDB for SQLite migration`) and
`76949b18` (`feat: harden storage before SQLite migration`).
The implementation branch is `v3.0-sqlitemigration`; the clean `v3.0` branch is
the PR target and remains based on `v2.5`. This checkpoint extends the isolated
foundation and is not a production cutover.

Completed in this slice:

- Durable Core Data failure is explicit; startup-critical reads no longer turn
  storage errors into an empty library or install an in-memory fallback.
- GRDB `7.11.1` is pinned to the recorded revision with the system SQLite module
  for the iOS app, native macOS app and XCTest target.
- A disposable file-backed GRDB smoke test is compiled into the XCTest bundle.
- An isolated `SQLiteLibraryStore` actor now owns a GRDB `DatabaseQueue` for a
  disposable v1 schema. The schema covers all six Core Data entities, durable
  library/generation metadata, migration row maps/checkpoints, asset and file
  operation journals, receipts, account-scoped sync state/outbox, recovery
  payloads and content revisions. It retains legacy UUID columns while using
  independent storage IDs and restrictive foreign keys for resolved links;
  file-operation paths are root-relative rather than absolute.
- The isolated store verifies `foreign_keys`, WAL, `synchronous=FULL`, the
  SQLite version/compile options and `PRAGMA integrity_check`; focused tests
  cover bootstrap, identity/reopen, relationship constraints, migration
  rollback and durable migration-run checkpoints. Typed begin/read/checkpoint
  operations validate progress and update the run atomically on the actor-owned
  queue. These tests are compiled into the existing app-hosted XCTest target but
  have not yet executed because the current simulator test runner exits before
  XCTest bootstrapping.
- The product decisions are recorded: no app export/restore or app-managed
  encryption; Apple device backups and iCloud/CloudKit remain in scope; metadata
  migration blocks first boot; audio reconciliation runs in the background.
- A root SwiftPM host-independent macOS runtime harness now runs thirty-eight
  disposable macOS runtime tests against the canonical store sources with the
  exact GRDB 7.11.1 pin. It caught and fixed two issues before any live-data
  work:
  SQLite's synchronous pragma must be set outside a transaction, and the
  processing-job status index must use the model's `lastModified` column.
- A read-only verifier now checks an explicit closed source snapshot across all
  six migrated entities. It validates the destination schema, migration-run
  fingerprint, row identity sets and every declared value, and reports missing,
  unexpected and changed rows deterministically. Disposable fixtures cover
  complete data plus malformed snapshots and all three row/value mismatch
  classes.
- An app-hosted fixture factory now loads the compiled original
  `BisonNotes_AI.mom` and active `BisonNotes_AI_v2.mom` models into disposable
  SQLite-backed Core Data stores. It populates representative rows for every
  supported entity in each model, projects all destination columns and
  relationships into the snapshot contract, and fingerprints the complete
  projection. The fixture XCTest methods are compiled into the app test bundle;
  they have not executed because the current simulator runner exits before
  XCTest bootstrapping.
- `CoreDataMigrationSnapshotReader` now turns one quiescent Core Data context
  into the importer’s six-entity `SQLiteMigrationSourceSnapshot` using public
  Core Data APIs only. It rejects temporary IDs, missing model fields, broken
  relationship closure and unsupported values; it preserves legacy IDs while
  using independent destination storage IDs, includes pending cloud mutations
  when the source model has that entity, and fingerprints the canonical rows.
  A disposable Core Data model test exercises all six entities and linked
  storage IDs; the app-hosted reader tests cover the compiled original and
  active models but remain compile-only until Xcode package resolution is
  available.
- `CoreDataMigrationInputReader` now composes that closed metadata snapshot
  with the typed blocking-settings snapshot. Its required app-owned source-key
  inventory makes unknown keys fail closed before the snapshot is handed to the
  coordinator; it does not infer or copy a global defaults domain.
- A typed metadata importer now consumes those closed snapshots in dependency
  order, writes each destination row and its source row-map entry in one
  transaction, records batch hashes/cursors, rejects destination/source
  conflicts and resumes idempotently after a committed batch. Fourteen host-side
  disposable tests cover complete import, reopen/resume, verifier parity and
  the existing storage/checkpoint behavior.
- Structured migration recovery reports now classify invalid snapshots, source
  and destination conflicts, run-state/configuration failures, incomplete
  imports and verifier mismatches without retaining raw values. Reports use
  hashed identifiers, persist through the existing `recovery_items` table, and
  can be read after reopening the isolated store. Fifteen host-side disposable
  tests cover the complete storage/importer/recovery slice.
- The first storage-neutral repository boundary is now defined by immutable
  snapshots for all six migrated metadata entities and the read-only
  `LibraryRepository` protocol. `CoreDataLibraryRepository` copies values
  out of the authoritative Core Data context, while
  `SQLiteLibraryRepository` reads the isolated GRDB-backed generation. Both
  use deterministic ordering and return immutable values; no managed objects,
  Core Data contexts or GRDB rows escape the adapters.
- Disposable contract coverage now exercises the SQLite adapter against the
  imported fixture across all six metadata tables and the Core Data adapter
  against a disposable active-model fixture. The root macOS harness passes
  thirty-eight tests with zero failures, including a disposable v2-to-v3 upgrade
  fixture that verifies existing settings stores receive the observation schema.
  The app-hosted Core Data fixture test is compile-checked with
  `build-for-testing`; the simulator runner still has not executed XCTest.
- The first settings boundary is now explicit and typed. An allowlisted
  `UserDefaultsLibrarySettingsStore` accepts only reviewed primitive values;
  it never copies an entire defaults domain, credentials or device-specific
  state. SQLite schema v2 adds a constrained `library_settings` table and a
  matching allowlisted adapter. SQLite schema v3 now records each settings
  insert/update in the durable observation log. The catalog now classifies the
  macOS vendor identifier as device-local and Mistral’s backed-up transcription
  model as blocking metadata; it validates reviewed engine/model/format/
  speaker-label enums and permits intentionally empty optional endpoints.
  Exhaustive app-key inventory, platform normalization and startup wiring are
  intentionally still open.
  An initial `LibrarySettingsCatalog` now classifies the reviewed CloudKit
  settings candidates plus source-observed omissions, lifecycle/CloudKit
  protocol state, legacy migration keys, device/cache state and credentials.
  Only the blocking-metadata subset can be read for a future SQLite import;
  unknown keys, derived/runtime values and non-migratable classifications fail
  closed. It also rejects non-finite values, out-of-range integers/reals,
  unknown enum strings and endpoint credentials. Platform normalization and
  startup wiring remain open. An app-hosted contract test now compares the
  production CloudKit settings source list, legacy on-device LLM settings and
  the seven reviewed UI omissions against the independent catalog; it has not
  executed because the current Xcode build cannot resolve external packages in
  this environment.
- The first write command is now explicit: recording rename references support
  Core Data legacy IDs and SQLite storage IDs, normalize the existing `[Watch]`
  suffix rule, and optionally enforce an expected `lastModified` revision.
  Core Data and SQLite adapters return the committed snapshot and distinguish
  invalid, missing, ambiguous, stale and failed writes. The display-name-only
  `AudioPlayerView` path uses the Core Data adapter; the AI workflow remains on
  its existing file-renaming path until file operations have a journaled
  repository command. Host and app-hosted contract coverage exercises both
  adapters.
- The durable observation boundary is now defined by `LibraryObservation`, with
  a global revision cursor and ordered `LibraryChange` values. SQLite schema v3
  adds `library_changes`; the SQLite adapter emits one change in the same
  transaction as recording rename and allowlisted settings writes, and tests
  verify invalid cursors, reopen behavior and exact committed timestamps.
- `CoreDataLibraryObservation` now reads retained `NSPersistentHistory`
  transactions and exposes the relevant changes through the same cursor
  contract. Durable Core Data stores enable history tracking and remote-change
  notifications, and application/isolated contexts use a transaction author.
  The adapter uses hashed object-URI identities so delete events remain stable
  even when a history tombstone omits legacy UUID data. Startup subscription,
  history-retention/purge policy and the remaining SQLite write commands are
  intentionally not implemented yet.
- The isolated migration coordinator now composes source validation, durable
  batch import, exact-source restart lookup, a blocking settings phase, durable
  cancellation pause, redacted failure checkpointing and closed-destination
  verification. Six host tests cover committed progress, metadata and settings
  reopen/resume, durable cancellation pause, allowlisted settings application
  and definitive conflict handling. Production source/settings acquisition,
  media work, activation and app-startup wiring remain intentionally open.
- The settings audit now identifies `iCloudStorageManager.backedUpSettingsKeys`
  as an existing source list for user-facing preferences, not as the SQLite
  migration allowlist. It omits some current FluidAudio/MLX preferences and is
  coupled to CloudKit restore rules that normalize platform-specific values.
  Migration must therefore keep a separate typed catalog: user choices can be
  copied during the blocking metadata phase; sync timestamps, migration flags,
  download/in-flight markers, device-specific audio/watch state and pending
  cloud markers remain in their owning stores; credentials remain in Keychain.

Not yet implemented or closed:

- Production coordinator/source/settings acquisition wiring, remaining
  settings-catalog source coverage/platform normalization and startup subscription
  wiring, plus broader read/write repository
  contracts and app-wired importer
  migration screen. The current read-only metadata repository adapters, schema, snapshot
  importer, verifier and resumable coordinator are isolated foundations only
  and are not a user-data destination.
- Coordinator policy for when to persist recovery reports and how to present
  them to a user; the current report API is explicit and intentionally not
  wired to app startup or a live migration.
- Fixtures for every supported shipped historical model hash, legacy-file-only
  users and skipped-release paths. The current source fixture covers only the
  checked-in original and active v2 compiled models with synthetic rows.
- Watch/share/background caller gates and the full file-operation/media journal.
- Historical source fixtures, performance measurements, shadow qualification,
  activation, signed device-backup testing and two-device CloudKit validation.

The next safe work package is to finish the remaining exhaustive source-key
catalog and platform normalization rules, connect the observation adapter to the
startup contract and expand commands while converting additional non-startup callers
behind the Core Data adapter with shared behavior tests. In parallel, close the
remaining Phase 0/1 evidence and caller-gate gaps.
Only after those contracts are stable should the isolated coordinator be wired
to the app's source/settings snapshot, recovery-report policy and first-boot
progress screen. Do not enable a migration screen or SQLite user-store cutover
until it is driven by that real source-backed coordinator.

### Live-data testing gate

No live user database is part of the current work. The first real-data test is
appropriate only after the importer and verifier operate from a frozen source
snapshot, all supported model versions have fixtures, crash/kill/background-
expiration/low-space recovery passes, anomalies block activation, the progress
screen and durable checkpoints are wired, media receipts retain the source, and
the signed app has completed Apple device-backup/restore and CloudKit validation.
The sequence is: disposable fixtures, synthetic or consented real-shaped data,
then a dedicated physical test device/account with a preserved source copy. A
production user's active library is the final rollout gate, not a development
test.

## 1. Recommendation and decision

Core Data is already using SQLite through `NSPersistentContainer` in
`Persistence.swift`. This proposal replaces its object-management layer with an
app-owned SQLite schema accessed through **GRDB 7.11.1** and the system SQLite
library, while retaining the existing CloudKit protocol initially. SQLite does
not itself provide device sync or protection from application-level deletion
mistakes. This release does not add an app-managed export/restore format: Apple
device backups and the existing iCloud/CloudKit behavior are the backup paths in
scope, while migration recovery is handled locally with durable checkpoints.
Apple explicitly says not to manipulate Core Data's private SQLite schema with
native SQLite APIs ([Apple store guidance](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreData/PersistentStoreFeatures.html)).

Proceed in independently useful steps: strengthen persistence failure handling;
define a complete, verifiable migration source/checkpoint protocol; introduce a
repository boundary over Core Data; benchmark; implement a separate SQLite
backend and importer; validate it in shadow mode; cut over only after all safety
gates pass. Keep Core Data if the measured benefit does not justify the
migration. Do not make a rewrite a prerequisite for fixing reliability problems.

| Option | Benefit | Cost / recommendation |
| --- | --- | --- |
| Harden existing Core Data | Lowest migration risk; existing SQLite transactions and cloud outbox remain | Required first step; benchmark batching, projections and indexing here too |
| App-owned SQLite via GRDB | Explicit constraints, transactions, queries, backup/migration tooling, testable value types | Recommended migration candidate, conditional on evidence; adds dependency and app responsibility for observation/schema evolution |
| Raw SQLite C API | Maximum control, fewer wrapper dependencies | More binding, lifecycle and concurrency code to get wrong; not the default |
| SwiftData or a new sync provider | Potential alternative architecture | Separate evaluation; does not directly solve complete backup and conflict preservation; do not combine with this migration |

Use GRDB's documented database access and migration facilities. The selected
release is pinned exactly to **v7.11.1** (revision
`b83108d10f42680d78f23fe4d4d80fc88dab3212`) in the Xcode project and
`Package.resolved`; its `GRDB` product is wired to the system SQLite module on
Apple platforms. The upstream references are the
[GRDB v7.11.1 release](https://github.com/groue/GRDB.swift/releases/tag/v7.11.1)
and its [pinned Package.swift](https://raw.githubusercontent.com/groue/GRDB.swift/v7.11.1/Package.swift).
Do not update unrelated dependencies.

**Non-negotiable safety contract:** no successful migration may silently omit,
truncate, regenerate, deduplicate, or delete user content. Preserve source bytes
and identities. Unsupported/corrupt data blocks activation and remains available
for recovery. A migration validation verified only by counts is insufficient. No system can
promise zero loss from all hardware failures; this design makes loss prevention,
recovery, and evidence explicit.

## 2. Source findings that shape the work

Paths below are relative to `BisonNotes AI/BisonNotes AI/` unless noted. Symbol
anchors are authoritative if line numbers change. See
[the generated inventory](sqlite-migration-inventory.md) for every current model
attribute, relationship, model hash, and direct Core Data consumer found by search.

| Evidence | Implication and required treatment |
| --- | --- |
| Baseline `Persistence.swift`: `handlePersistentStoreLoadFailure` installed a temporary in-memory store | Durable-storage failure can leave a usable-looking data layer whose new data disappears at exit. The current safety slice removes that fallback, reports an explicit unavailable state and blocks normal startup; migration still needs a separate durable recovery/spool policy. |
| Baseline `CoreDataManager.getAllRecordings` returned `[]` on fetch failure; `ContentView.initializeApp` used empty collections to initiate migration, and otherwise ran cleanup | Empty is not a trustworthy absence signal. The current safety slice uses throwing startup reads and blocks normal library operation on failure; migration still needs durable version/state records and a repository-level maintenance lease before destructive cleanup. |
| `CoreDataManager.cleanupRecordingsWithMissingFiles` deletes some metadata or clears URLs; startup invokes it | Missing or inaccessible audio is not proof of user deletion. During migration/recovery suspend all destructive cleanup. Retain path and metadata with explicit unavailable state rather than guessing. |
| `Persistence.swift`: `PendingCloudMutationStore`; `CoreDataManager.save(committing:)` | Local deletes and five kinds of cloud intent already commit together. Preserve this invariant, original `requestedAt`, child IDs, payload versions, coalescing and snapshot-conditional acknowledgement. Do not move this queue back into UserDefaults. |
| `CoreDataManager`, `AppDataCoordinator`, `RecordingWorkflowManager`, `TranscriptManager`, views and sync expose managed objects and/or contexts | A database-file swap cannot replace Core Data. Migrate APIs and callers to immutable values and explicit commands before cutover. |
| Active model `BisonNotes_AI_v2` has six entities, including archive locations and pending mutations | A three-table recording/transcript/summary migration would lose data. Preserve all six, both model versions, every relationship and redundant ID. |
| Most model fields, including content IDs, are optional; scalar IDs coexist with object relationships | Existing stores may contain nil IDs, duplicate UUIDs or inconsistent links. Do not force uniqueness with `INSERT OR REPLACE`, silently drop orphans, or invent identity during import. |
| `SummaryAttachmentStore` stores notes and files under `Documents/SummaryAttachments/<summary UUID>/` | Database and current CloudKit state alone do not prove that local supplemental data is recoverable. Preserve supplemental metadata and bytes, including folders not currently linked to a row, and rely on Apple device backup for platform-managed backup. |
| `RecordingArchiveService` stores security-scoped bookmarks and exported paths | Preserve bookmark bytes, archive flags, verification state and destinations. A bookmark's existence does not prove a usable external copy or platform-backup coverage. |
| `SummaryManager.migrateLegacySummariesIfNeeded`, `DataMigrationManager`, `.location` fallback reads | Older users can still have legacy content. Existing conversion helpers can apply defaults/filter records; do not use presentation DTOs as a lossless export. |
| `iCloudStorageManager` implements custom CloudKit records, active manifest v2, quarantine and deletion arbitration; container is `NSPersistentContainer`, not `NSPersistentCloudKitContainer` | Retain existing wire protocol and account behavior. Model `usedWithCloudKit` flags are not evidence of automatic Core Data mirroring. |
| Watch has JSON/audio storage and automatic cleanup, including failed transfers after repeated attempts | Phone database migration does not protect the watch's only copy. Harden transfer acknowledgement/retention as a separate prerequisite, without converting the watch to SQLite in the same release. |

These are source-observed behaviors and migration risks, not a claim that Core
Data itself has corrupted user data. Main-actor full fetches and repeated value
conversion are performance candidates; measure before calling them bottlenecks.

## 3. Complete data boundary

Maintain a checked-in **data ledger** with owner, actual resolved path/domain,
read/write entry points, backup policy, sync policy, migration treatment, fixture
and test for each category. The appendix is the starting schema ledger, not a
claim that regex searches discover all runtime behavior.

1. All six Core Data entities, including unlinked rows, archived recordings,
   processing jobs, original optional values, raw JSON strings and outbox blobs.
   Preserve both relationship targets and scalar linkage IDs independently.
2. Audio at current/legacy document paths, imported placeholders, `.location`
   sidecars, transcript/summary legacy files, and archive export artifacts owned
   by the app. Preserve exact names/relative paths initially; do not rename media
   during database migration.
3. `SummaryAttachments` metadata, user notes, attachment bytes and orphan folders.
   Do not treat a malformed JSON document as empty supplemental data.
4. Application Support/Recording Recovery and unfinished recording sources;
   interrupted/transcribing/summarizing jobs and staging artifacts. Distinguish
   recoverable user audio from reproducible temporary conversions.
5. App Group share inbox plus authorization tokens; staged Watch transfers and
   processed-transfer deduplication IDs. Preserve receive/commit/acknowledgement
   order across process death. Audit `Shared Share Support`, `Shared`, both share
   extensions, Watch app and phone `WatchConnectivity` code.
6. Defaults: legacy `SavedEnhancedSummaries` storage, all five
   legacy pending-removal keys, setup/migration markers, sync preferences,
   eligibility/backoff state, account identity scope, manifest migration state,
   quarantined cloud record names, signatures and timestamps. Extract exact keys
   and suite names in Phase 0; do not wholesale upload all UserDefaults.
7. Keychain credentials stay in Keychain. The app does not export credentials,
   manage backup encryption or manage backup keys. Preserve same-device access
   during migration. Device-specific bookmarks, local model paths and permission
   grants are not copied into the SQLite metadata schema unless their ownership
   is explicitly modeled.
8. Downloaded models and reproducible map/render caches are not part of the
   blocking metadata migration; retain model preferences and preserve unknown
   files until classified. Do not delete anything merely because it is not a
   database row.
9. Cloud-only records/assets, quarantine, tombstones and remote archive files
   must be listed as external dependencies. Existing iCloud/CloudKit behavior
   remains in scope, but CloudKit state is not treated as proof that local audio,
   attachments or external archives are backed up.

There is no app-created portable backup, export package, restore importer or
app-managed backup encryption in this release. Apple device backup and iCloud/
CloudKit are the supported backup/sync mechanisms; the migration itself relies on
local durable checkpoints and retained source data until validation completes.
Honor `isCloudSyncDisabled` for network uploads and automatic cloud activity.

## 4. Target architecture and contracts

Suggested new directory: `Storage/`, split into domain values, repository,
Core Data adapter, SQLite adapter, migration, backup and file-operation services.
Names below are proposed, not existing APIs.

- `StorageBootstrap`: the sole composition root; chooses one authoritative
  generation, reports `ready`, `migrating`, `unavailable`, `recoveryRequired`.
  It must run before construction of singletons that read/write persistence,
  including the initial `BisonNotesAIApp` properties and cloud manager defaults.
- `LibraryRepository`: injected capability for throwing reads and atomic domain
  commands. Return `Sendable` recording/transcript/summary/job/archive snapshots;
  `nil` means not found only after a successful read. Commands return committed
  IDs/revisions or errors. Never expose `NSManagedObject`, contexts, database
  handles or SQL rows outside adapters.
- Commands include create/import recording, replace transcript, upsert summary
  with explicit identity policy, edit metadata, archive/restore, delete each
  content kind, set local-only, claim/complete job, apply inbound cloud records,
  and acknowledge exactly the outbound snapshot sent. They own every related
  row, link and outbox update in one transaction.
- `LibraryObservation`: ordered committed change stream with a revision/cursor;
  initial snapshot plus subscription must not lose an intervening commit.
  Deliver UI updates on `@MainActor`, cancel subscriptions on teardown, paginate
  libraries, and keep transcript/summary bodies out of list projections.
- `CloudLibraryStore`: repository-backed snapshots and mutations used by the
  existing sync engine. Remove process-wide `PersistenceController.shared`
  fallbacks, especially local-only checks and pending-context rebinding.
- `AssetStore` and durable `FileOperationJournal`: immutable installed assets,
  explicit staged/install/delete states, checksums, deterministic recovery.
- `MigrationCoordinator`, `FileOperationJournal`, `StorageHealthReport`: use the
  same exclusive maintenance gate; diagnostics are non-destructive and redact
  content. Do not add an app-level backup/export service for this migration.

Use one injected database writer (GRDB queue initially, pool only if measured
reads justify it). No `await`, CloudKit call, media copy, hashing, UI work, or
external side effect inside a database write transaction. Prepare immutable
inputs first, then validate expected revisions and commit. Swift actor isolation
alone does not prevent reentrancy across `await`; serialize maintenance and
revision-check long-running work explicitly. Avoid new unchecked Sendable types.

### Database shape

Create a **new database path**, e.g. Application Support/Library/generations/<id>/
library.sqlite. Never open Core Data's file through GRDB. Keep media in existing
locations at first, tracked by an asset catalog and protected from cleanup.

Initial content tables map one-for-one from all attributes in the appendix:
`recordings`, `transcripts`, `summaries`, `processing_jobs`, `archive_locations`,
`pending_cloud_mutations`. Retain original camelCase column names initially to
make mapping auditable. New operational tables:

| Table | Required purpose |
| --- | --- |
| `schema_migrations`, `library_metadata` | Ordered immutable migration IDs, schema/minimum reader version, library/generation identity and revision |
| `library_changes` | Append-only global revision log for committed metadata/settings changes; observers resume from a durable cursor rather than an in-memory notification |
| `migration_runs`, `migration_row_map` | Source fingerprint, importer/schema version, per-batch cursor/count/hash, source row identity to destination row mapping |
| `asset_catalog`, `file_operations` | Relative path, kind, byte length/hash, available/unavailable/external state; retryable install/delete with owner/revision |
| `import_receipts` | Unique source transfer ID and durable commit outcome; duplicate retries return the same result |
| `sync_state`, `sync_outbox` | Account-scoped eligibility/acknowledgements and future durable upload intents, distinct from legacy deletion semantics |
| `recovery_items` | Lossless original payload, reason and provenance for unresolved rows/files; never a silent trash can |
| `content_revisions` | Preserve replaced editable content before destructive conflict resolution; explicit retention, never purged by migration |

Use an internal primary key independent of nullable legacy UUIDs. Preserve
original UUID and relationship source keys. Link valid rows with indexed foreign
keys; keep a lossless link map for unresolved references. Initially use explicit
transactional delete commands and restrictive FKs rather than relying on cascades
that would bypass cloud intent and asset bookkeeping. Do not impose one child per
recording: older/redundant rows must survive even though sync selects one winner.

Preserve v2.5 original and optional cleaned transcript representations inside
segment payloads, their provenance and mappings. Older clients may drop the
derived representation when rewriting JSON; preserve originals and cover this
known compatibility limit explicitly. Do not derive migration input solely from
whichever representation is currently displayed.

Data conversion rules: UUID strings use one canonical representation but retain
original null/identity semantics; Int32/Int64 use range-checked SQLite INTEGER;
Date uses lossless Double seconds with an explicitly named epoch (preserve nil,
no `Date()` defaults); Double values retain precision, including a recovery path
for unsupported nonfinite legacy values; binary payloads/bookmarks are BLOBs;
strings including JSON remain exact text, nil distinct from empty. Unknown enum
raw values survive and display an unsupported state. Do not trim content or
round timestamps. JSON may get an auxiliary parsed representation, never replace
the original until a separately tested schema migration authorizes it.

Before activation, unresolved duplicate IDs or contradictory links block normal
migration. Preserve them in the source and a durable recovery record and report
the specific issue. A later repair can create a documented mapping with
user-visible recovery; the importer itself must not choose a winner. Valid multiple child
rows and legitimately missing media are not automatically corruption.

Configure and verify foreign-key enforcement per connection, a bounded busy
policy, durable writes (start with `synchronous=FULL`), and supported journal
settings. Record `sqlite_version()` and compile options on supported OS versions;
check current upstream fixes before choosing pooling/WAL. Never enable destructive
"erase database on schema change" tooling in production. Schedule checkpoints
outside latency-sensitive work and bound WAL growth. FULL sync is a durability
choice, not a guarantee against every filesystem/hardware failure
([SQLite pragmas](https://sqlite.org/pragma.html)).

Index UUID lookups, recording-linked children, recording date plus stable tie ID,
archive lookups, job status and outbox eligibility. Use EXPLAIN QUERY PLAN and
benchmarks before adding search/FTS or normalizing large JSON payloads.

## 5. File/database atomicity

SQLite transactions cannot atomically commit an audio file and CloudKit request.
Specify the following protocol before implementation:

1. Receive/copy into a uniquely named durable staging area, validate media where
   appropriate, hash/flush bytes, and retain the source. A recording being written
   is never snapshotted as a completed asset.
2. Commit an install intent with source/destination/checksum/owner and receipt.
   Publish the complete file with same-volume atomic replacement only after its
   bytes are durable; never overwrite an unrelated file on a name collision.
3. Commit the content row/reference and mark the operation complete. Readers see
   pending/unavailable state until installation is verified. On restart, replay
   by checksum and operation ID; file existence alone is not success.
4. A delete transaction hides/deletes the row, records cloud intent as applicable,
   and journals file cleanup together. Remove files only after commit, with a
   reference/migration lease check. Retry failure; do not report cleanup
   success while pending. Local cache/offload cleanup never synthesizes deletion
   intent for another device.
5. A Watch/share import is acknowledged as durable only after asset and database
   commit. Store its source ID atomically with content; never rely on an in-memory
   set or a defaults write racing a database commit. Preserve pending sources
   through migration and never auto-delete the only unsynced Watch copy.

Crash tests must cover every boundary above, including file installed but no row,
row pending but no file, local deletion committed but cloud/file cleanup pending,
and duplicate receipt after the acknowledgement was lost.

## 6. User migration state machine

Use a persisted state machine and an exclusive process-safe storage gate, not a
single `hasMigrated` preference. Store generations are immutable candidates until
selected; use a small atomic, versioned active-generation descriptor, with enough
redundant evidence inside the database to detect a torn/missing descriptor.

`legacyReady → preparing → snapshotVerified → importing → validating → readyToActivate → sqliteActive`

Any pre-activation failure → `migrationBlocked` with original authoritative store
and a report retained. Any active-store failure → `recoveryRequired`; it must not
select the older database automatically. State transitions are idempotent and
crash-tested. A newer unsupported descriptor/schema blocks writes.

### First post-update launch contract

On the first launch of the release that enables migration, `StorageBootstrap`
must acquire the gate before constructing the normal library, sync, Watch or share
write paths. The foreground app presents a blocking migration screen with a
plain-language explanation, current phase, completed/total metadata work and
indeterminate progress when the source cannot provide a safe count. The user may
quit or the OS may kill the app, but the app must not bypass the metadata gate and
open a partially migrated library on relaunch.

The blocking first-boot scope is metadata: recordings, transcripts, summaries,
processing jobs, archive references, pending cloud mutations and the required
settings/defaults disposition. Allow a temporary budget of up to **2x the measured
metadata footprint** for the source plus candidate database, indexes, WAL and
checkpoint state. This is a metadata budget only; it does not authorize a second
full copy of audio. Audio and other large media are reconciled by a background,
bounded, resumable file-operation worker after the metadata checkpoint is safe.

Every visible progress step must correspond to a durable checkpoint. A crash,
force-quit, background expiration or power loss resumes idempotently from the last
committed batch, rechecks its source fingerprint and never trusts a lone
`completed` preference. The coordinator writes the activation marker only after an
independent validation pass, and it retains the legacy source plus any unreconciled
media until their receipts and validation are durable.

### A. Preflight and quiescence

Run before normal startup migrations, cleanup, cloud triggers and background job
resumption. Wait for or safely finish an active recording before starting; do not
interrupt captured audio to migrate. Close editing transactions and drain current
writes. Suspend new imports/jobs or spool incoming files durably without an ACK.
Pause inbound/outbound sync and asset pruning. All foreground/background/extension
entry points must observe the gate; Apple background expiration checkpoints and
retries, never forces a partially completed cutover.

Resolve actual store URLs, model version hashes, app group paths and available
space. Estimate source snapshot + new database/index/WAL + metadata checkpoint
headroom using measured sizes, not a fixed multiplier; do not include a full audio
copy in that budget. On insufficient space, locked protection or inaccessible
files, leave the authoritative legacy store intact and show a recoverable blocked
state. Quitting is safe, but the user cannot cancel into a partially migrated
library. Never reclaim user data to make migration space.

### B. Capture a recoverable source

Capture the database **and** defaults/legacy files/assets under one logical
quiescent generation. Use a tested Core Data coordinator snapshot/migration-copy
procedure on a dedicated coordinator, or a fully closed-store consistent bundle;
do not copy an active `.sqlite` file alone. Opening the original must not
silently upgrade it before the recovery copy exists. If a source needs lightweight
migration to read, perform that on a disposable clone using bundled historical
models. Validate every supported source version through public Core Data APIs.

WAL contains committed changes that may not be in the database file; independently
copying database/WAL/SHM during writes is not a consistent snapshot. SQLite's
backup API is suitable for the **new app-owned database**, but does not capture
external assets ([SQLite backup API](https://sqlite.org/backup.html),
[SQLite WAL](https://sqlite.org/wal.html)).

For the first migration implementation, pause all library mutations during
snapshot/import/activation, while providing responsive progress and safe process
termination. If this is too slow for large libraries, add a separately tested
change journal; do not quietly allow writes that the snapshot misses. A process
termination resumes the same verified run; if the source is allowed to change,
invalidate the candidate and take a fresh snapshot unless journal replay is proven
complete.

Inventory assets independently (APFS clones are acceptable only with verified copy
semantics), and never use hard links vulnerable to later modification. Flush and
verify the metadata source snapshot, then reopen it using an isolated reader.
Background media reconciliation records each source/destination/checksum receipt;
external media that cannot be reconciled remains an explicitly missing dependency
and its source is retained. The migration must not claim media completeness merely
because a path is present.

### C. Lossless import

Read raw entity attributes and relationships via Core Data, using bounded batches
and a stable mapping from source store identity + permanent object ID to an
internal destination key. Temporary object IDs must be resolved on the clone.
Never read `Z*` tables, use UI conversion helpers that generate UUIDs/defaults, or
fetch only records visible in the current UI.

Import all entity rows first, then links, then file metadata and operational
state. Persist each batch and its progress/hash in the **same destination
transaction**. Resume only against the identical verified source fingerprint.
All insertions are idempotent against the row map; uniqueness conflicts abort or
are explicitly preserved for recovery, never ignored/replaced.

Import valid pending mutations and all five legacy defaults queues without
changing earliest request time or dropping children. Retain malformed/unknown
payload bytes and block activation when deletion intent cannot be interpreted.
Do not clear original legacy queues/summary files while building a candidate.
Preserve manifest quarantine and account-specific suppression state; stale
success signatures must be invalidated for a deliberate reconciliation after
cutover, not reused to skip newly migrated data.

Legacy-only users and users who skipped releases need fixtures of their own.
Run any required older file-to-Core Data conversion on a working copy and reconcile
its output against the original files. Unrecognized legacy files stay in recovery;
no “migration completed” state based merely on a successful context save.

### D. Independent validation

A validator independent of importer mapping code compares the quiescent source
snapshot to a freshly reopened destination. Check entity multisets, field values and nulls,
exact raw JSON/binary content, relationship graph, ID map, timestamps, pending
mutations including unknown payloads, file inventory/checksums, notes, bookmarks,
archive state, jobs and receipts. Record duplicate/missing link anomalies
individually. Require `integrity_check` success and zero `foreign_key_check`
violations on the new database. Row counts and checksums alone do not prove
usable media: open representative audio, render transcripts/summaries and test
notes/attachments, archive resolution and recovery UI.

The validator must not call the importer to decide its expected results. Fixtures
need explicit expected graphs and independent canonical validation projections.
Unknown fields in a source model fail the coverage check rather than disappearing.

### E. Activation and rollback boundaries

Flush/close and reopen the validated candidate, write its readiness marker,
atomically publish the active descriptor, then reconstruct **all** repositories,
UI observations and sync dependencies from that generation. Persist and verify
activation before accepting any edits. Stale workers carry a generation token
and must be rejected after cutover. Never have two writable authoritative stores.

Before activation, fallback to the unchanged Core Data source is safe after
candidate invalidation. **After the first SQLite write, pointing back to Core
Data loses new work.** Use a forward-fix build that understands SQLite; if reverse
migration is ever needed, build and validate a full export/import including new
edits, deletions, receipts and assets first. Do not advertise binary downgrade
support: old releases cannot understand the new activation guard and may open a
stale Core Data copy. Do not deliberately destroy that copy to stop them; document
unsupported downgrade/reinstall behavior and test re-upgrade detection/recovery.

Retain the legacy source and recovery generation through at least two stable
releases and until metadata validation plus per-asset reconciliation are complete;
there is no app-exported backup whose existence can replace this retention.
Choose the final retention/storage policy before rollout. Never prune a retained
database independently of its media or when it is the only recoverable copy. Keep
historical model readers for supported skipped-version upgrades even after
runtime Core Data use ends.

## 7. Apple device backup and iCloud product contract

This release does **not** ship an app-created portable library backup, export
package, restore importer or recovery merge operation. It does not add backup
encryption, key management or a second app-owned copy of the audio library. The
supported product mechanisms remain Apple device backup for platform-managed app
data and the existing iCloud/CloudKit sync behavior. The app must not describe a
CloudKit success as proof that local-only audio, attachments or external archive
bookmarks are independently backed up.

Migration safety is provided by local recovery rather than an export format:

1. Keep the unchanged Core Data source authoritative until the new metadata
   database is independently validated and activated.
2. Store the migration run, source fingerprint, batch cursor, row map, asset
   receipt and validation result durably. A crash or app kill resumes from the
   last committed checkpoint; it never treats a missing or torn completion marker
   as success.
3. Block the first post-update launch only for metadata migration: recordings,
   transcripts, summaries, processing state, archive references, pending cloud
   mutations and required settings. Permit up to **2x the measured metadata
   footprint** for the source plus candidate database, indexes and WAL. This
   allowance does not include a second full audio copy.
4. Reconcile audio and other large media in the background with bounded,
   resumable file operations. Retain each source until its destination receipt,
   byte length and hash/format checks pass. If an individual asset needs staging,
   bound that staging to the active work item; never duplicate the entire audio
   library just to make the migration convenient.
5. Continue to rely on platform backup/restore and normal iCloud account behavior
   after activation. Any unreconciled asset or external dependency remains
   visible to recovery/health reporting and is never silently deleted.

The first-boot migration screen is therefore an operational gate, not a backup
wizard. It explains the current phase, completed/total metadata work, whether
background media reconciliation is pending, and any actionable failure. It does
not offer export/restore controls or ask the app to manage encryption keys.

## 8. Cloud sync compatibility and reliability

### Preserve the protocol during local cutover

Keep the container `iCloud.Bison-Networking.BisonNotes-AI`, existing database/zone
selection, record types, IDs/prefixes and field meanings. Current types include
`CD_BackupRecording`, `CD_BackupTranscript`, `CD_BackupSummary`, `CD_BackupSettings`,
`CD_BackupContentIndex`, `CD_BackupDeletion`, and legacy `CD_EnhancedSummary`.
`content_index` uses active manifest schema 2; backup schema is separately 1.
Do not reset account data, recreate the container, renumber records, publish
migration-time timestamps as edits, clear quarantine, or back up the entire
SQLite file to implement sync. The active database stays on local storage; it is
not opened from iCloud Drive or a network filesystem.

Port the current rules into repository-independent tests before adapting callers:

- Order: flush outbound deletions, apply inbound markers, reconcile existing cloud
  records and prune only genuinely superseded candidates under the existing policy.
- Content timestamps, not `syncUpdatedAt`, arbitrate; retain equal/missing-time
  behavior for compatibility. Preserve earliest `requestedAt`, revival grace,
  retention policy and the special imported-audio unlink marker semantics.
- Distinguish whole deletion, local-only removal, summary removal, transcript
  removal and imported-audio removal. Metadata-only cloud reconciliation must not
  unlink good audio. Failed file cleanup stays retryable.
- Newest-per-recording selection must agree locally and remotely without removing
  the selected link. Migration itself never prunes historical child rows.
- Preserve exclusion of local-only content, active lifecycle/quarantine filtering,
  bootstrap on missing/untrusted manifests, delta conflict merges, full-record
  refetch before modifying partial records, immutable audio staging, bounded
  batches, backoff/defer semantics, single coordinator and erase supersession.
- Cloud outcomes containing failed/deferred IDs are not success. Acknowledge only
  the exact generation/revision/payload sent; edits made during upload remain
  pending. A cloud save acknowledged remotely but not locally must replay safely.

Preserve `CloudKitTransport`, batch executor, retry policy, manifest coordinator,
operation coordinator, metrics and audio policy abstractions. Introduce a store
adapter beneath them; do not simultaneously rewrite those components or switch
to `CKSyncEngine`. Shadow runs never write to CloudKit.

### Additional sync work after compatibility is proven

A local database rewrite does not solve timestamp conflict loss or devices offline
past tombstone retention. Explicitly test both and document the limits of the
current protocol. For a stronger guarantee, design a separate versioned sync
upgrade with durable revision-based upload intents, preserved losing content,
account-scoped state, deterministic conflict resolution and device acknowledgement/
epoch rules for tombstone reclamation. An old device that lacks the new protocol
cannot be assumed to acknowledge it. Keep this release blocked from claiming
lossless arbitrary-offline sync until that compatibility problem is resolved.

Notes and attachments need an explicit future sync mapping and asset policy;
there is no basis to assume moving their metadata into SQLite makes the current
CloudKit records include them. In the first release preserve them locally and rely
on Apple device backup for platform-managed backup. Adding network upload changes
the user's privacy expectations and needs a reviewed product policy plus
production schema rollout tests.

On account sign-out/change, stop work and partition remote acknowledgements,
outboxes, quarantine and retry state by account/library. Never apply account A's
pending deletes to account B. Local-only content remains local. Test unavailable
account, permission denial, quota failure and rate limiting without resetting
local data. Any additive CloudKit fields must tolerate older writers that do not
understand them; migration-only work should need no schema change.

## 9. Implementation work packages for Luna or another agent

Execute sequentially in small reviewable commits. A phase is complete only with
its evidence. This plan does not authorize an unattended production rollout,
cloud erase or migration of the developer's personal library. Use disposable
fixture containers; default to no live network in tests. Do not start a new agent
or task unless the owner requests it.

| Phase | Concrete deliverable and files | Exit gate |
| --- | --- | --- |
| 0: Baseline / contract | Revalidate HEAD and instructions; complete data ledger from appendix, runtime store paths and defaults suites; inspect release history for every supported model. Add benchmark/evidence spec in `docs/sqlite-migration-evidence.md`. Pin GRDB **7.11.1** with system SQLite, resolve it for the app/test targets and run an isolated file-backed smoke test. | Schema coverage includes every model field/relationship and non-database category; baseline tests and timings recorded with limitations. The GRDB pin, system-SQLite choice, Apple-device-backup/iCloud policy, metadata budget and first-boot/background-media policy are recorded. **In progress:** complete source-key/catalog coverage, production coordinator wiring and measurements remain open. |
| 1: Safety prerequisites | `Persistence.swift`, `BisonNotesAIApp.swift`, `ContentView.swift`, `AppDataCoordinator`, cleanup/troubleshooting and Watch receipt/retention paths: explicit storage health, startup gate, throwing critical reads, durable failure behavior. **In progress:** Core Data health/startup gating and throwing startup reads are implemented; Watch/extension/background caller gates remain open. | Open/read/save failure never looks like empty success, triggers cleanup, acknowledges a lost import or accepts ephemeral "saved" data; existing behavior suites pass. |
| 2: Recovery and media safety | New durable migration checkpoints, source snapshot/validation services, file-operation journal and recovery UI; adapt attachments/archive/file services. Keep Core Data authoritative. Do not add an app export/restore package. | Metadata source/candidate recovery across crash, kill, low-space and malformed input; bounded background media reconciliation; current library preserved on every failure. |
| 3: Repository boundary | **Started:** immutable snapshots for all six metadata entities, typed allowlisted settings adapters, the first rename command/error contract, Core Data and SQLite adapters, durable SQLite/Core Data observation adapters, the read-only Core Data migration source reader, and disposable contract tests are in place. `AudioPlayerView` now uses the Core Data adapter for its display-name-only write; startup subscription, file-owning commands, and the remaining `AppDataCoordinator`, `RecordingWorkflowManager`, jobs/imports/transcript/summary/archive services, UI, cloud store access, fixtures and previews remain. | Core Data backend passes unchanged behavior plus shared repository contract tests. Managed objects/contexts confined to adapters and the legacy importer; all callers/targets audited. |
| 4: SQLite backend | **Started:** the isolated SQLite adapter now has a durable v3 change log for the first rename/settings writes and cursor/reopen tests. Extend it into the complete repository implementation, file journal, receipts and metrics using the pinned GRDB product. Add dependency/project configuration for iOS/native macOS only unless another target truly needs it. | Shared contract suite passes on both disk-backed backends; all transactions/constraints/observation/fault tests pass; measured performance gate met. No user cutover. |
| 5: Import / verifier | The model-aware read-only Core Data source reader, explicit Core Data-plus-settings input boundary, lossless row map, importer, validation, recovery reports and resumable metadata/settings coordinator are now isolated foundations; production source/settings acquisition and the production state machine remain open. | Both source models plus skipped-version legacy fixtures migrate; every transition survives process kill; anomalies block safely; no cloud side effects. |
| 6: Shadow qualification | Read-only SQLite comparisons from a frozen source snapshot; retain Core Data as sole authority. Store per-field mismatch reports without content leakage. | Zero unexplained mismatches across representative fixtures/libraries. If legacy writes resume, candidate invalidated/rebuilt; do not pretend it remains current. |
| 7: Guarded activation | Bootstrap generation selection, first-boot migration screen/error/progress recovery, stale-worker rejection, fresh-install SQLite path, mixed-version cloud testing and background media reconciliation. | Full automated matrix plus signed hardware/device-backup/upgrade/CloudKit gates pass; forward-fix and platform restore drill performed. Opt-in internal cohort first. |
| 8: Rollout / retention | Internal → opt-in beta → small release cohort → wider release, with evidence at each expansion. Retain legacy recovery copies/models and backends as required. | Any unexplained loss, corruption, privacy regression, resurrection or divergence stops expansion. A rollout flag only prevents new migrations; it never flips active users to stale Core Data. |
| 9: Later simplification | Remove runtime Core Data only after imports from supported historical releases still work; separately consider sync protocol enhancements and notes/attachment sync. | No unresolved ledger/test gaps. Keep model-reader compatibility and platform-backup compatibility for supported users; removal is not a prerequisite for migration success. |

Do not dual-write independently to Core Data and SQLite: a crash between commits
creates two conflicting sources of truth. Shadow import/read comparison is safer.
If live incremental shadowing becomes necessary, first design an authoritative
transactional change log with high-water marks and idempotent replay; do not
approximate it with two saves.

### Caller migration directions

1. Replace managed-object-returning getters with immutable snapshots. UI selection
   should store stable IDs; windows, refreshes and deletion must tolerate missing
   selected records. Preserve user edits in explicit edit state and submit one
   command; replace direct property mutation followed by `saveContext()`.
2. Keep `SummaryUpsertIdentityPolicy` semantics: generation preserves existing
   summary UUID/notes linkage, cloud restore can use the incoming UUID. Preserve
   attachment migration behavior and all superseded content in recovery history.
3. Replace `DeferredDeletionEffects` with a repository transaction that records
   database, cloud and file intent; verify rollback leaves all three untouched.
4. Replace `bindPendingMutationContext` with injected account/library-scoped store
   access. Remove hidden shared-store reads; injected tests must never touch the
   user's default store.
5. Jobs persist expected recording/content revisions. On restart, interrupted work
   is reconciled, not blindly repeated; late ASR/AI callbacks cannot overwrite an
   edited/deleted record or a newly selected database generation.
6. Change `SummaryAttachmentStore.pruneOrphans(against:)` to take a successfully
   acquired repository snapshot and maintenance lease. An empty/error/partial
   snapshot never authorizes deletion. Migrate archive KVC entity access too.
7. Update `UITestSupport`, previews, environment context injection and Swift 6
   persistence tests. Preserve DEBUG-only reset safety and default no-cloud test
   launch. Keep Watch/share wire formats unless separately versioned/tested.
8. Search direct entity names plus `NSFetchRequest`, `managedObjectContext`,
   `PersistenceController`, KVC entity names, `.save()`, `FileManager` mutation,
   defaults suites and target membership. Review compile conditionals and Xcode
   synchronized groups; regex absence alone is not completion proof.

### Mandatory phase handoff

Record branch/starting and ending SHA, files changed, interfaces introduced,
ledger coverage, tests actually executed with counts and result bundles, baseline
versus new failures, benchmarks, remaining risks, retained compatibility code and
the next allowed phase. Do not claim "implemented" for a plan, "tested" for a
build-only result, or "safe to release" with physical-device gates outstanding.

Copyable starting instruction for Luna:

> Read `AGENTS.md`, `CLAUDE.md`, `docs/sqlite-migration-plan.md` and
> `docs/sqlite-migration-inventory.md`. Implement Phase 0 and report its evidence
> before proceeding to Phase 1. Recheck branch/HEAD/status; preserve unrelated
> changes. Use only disposable test stores; do not open or migrate my personal
> app data. Treat all phases' exit gates and the data-preservation contract as
> mandatory. Do not simplify the scope to three entities, directly read Core
> Data SQL tables, delete legacy data, enable production cutover or change the
> cloud protocol. Report blockers and the concrete next phase at handoff.

## 10. Testing and ongoing regression prevention

Every persisted entity field and data-ledger entry must map to an explicit fixture
assertion. Every domain mutation must map to success, rollback and reopen tests.
Use real **disk-backed SQLite** for durability tests: `/dev/null`, in-memory
contexts and mocks do not prove WAL, process death, file protection or migration.

Suggested new suites: `StorageContractTests`, `StorageBootstrapTests`,
`CoreDataToSQLiteMigrationTests`,
`MigrationCrashRecoveryTests`, `AssetJournalTests`, `StoragePerformanceTests`, and
`MixedVersionSyncCompatibilityTests`. Names are proposed; do not add empty suites
just to satisfy the plan.

| Matrix | Required cases and oracle |
| --- | --- |
| Source versions | Original model, active v2, fixtures from each supported shipped model hash, legacy-file-only user, mixed legacy/current state, user skipping intermediate releases; complete raw-value/graph parity |
| Content | Empty library, audio-only, imported summary/transcript, archived/offloaded audio, nil/duplicate IDs, conflicting redundant links, unlinked rows, multiple children, unknown statuses, Unicode/emoji, long transcript, speaker mappings/timestamps, all tasks/reminders/titles, extreme integer/date values |
| Files | Notes/attachments including duplicate names and corrupt metadata, unknown/orphan files, stale container URLs, `.location`, security bookmarks, unavailable providers, recovery audio, cloud-only audio, share inbox and pending Watch transfer |
| Outbox | All five mutation kinds, original timestamps/child sets, legacy malformed queues, duplicate/coalesced requests, save rollback, restart persistence, concurrent changed acknowledgement; no resurrection from lost intent |
| Process death | Kill a subprocess after every state transition/batch/descriptor step, then relaunch; repeated kills and double-launch; committed input is represented exactly once and original recovery source remains intact |
| Storage faults | `SQLITE_FULL`, IOERR, BUSY/LOCKED, corrupt/truncated DB, active WAL, denied permissions/protected device, interrupted copy, corrupt manifest, checksum mismatch, future schema; no empty fallback and no destructive cleanup |
| Race ordering | Rename/delete/import/ASR completion during snapshot, activation or upload; stale generation callback; app background expiration; Watch duplicate after lost ACK; successful revision stream matches committed state |
| Migration recovery / platform backup | Reopen after crash, kill, background expiration, low space, protected data and malformed source; verify Apple device-backup/reinstall/upgrade behavior where the platform permits; metadata and media receipts remain recoverable and the original library is unchanged until explicit activation |
| Cloud fakes | Existing arbitration/manifest/partial failure/coalescing/erase/backoff/exclusion suites on both adapters, lost local ACK after remote save, account switch, quota and network loss, metadata-only audio semantics |
| Real CloudKit | Signed old/new, new/new and upgrade-during-offline combinations; concurrent edit/delete, clock skew, beyond-retention offline return, quarantine and legacy records, local-only toggles, interrupted assets, account changes; inspect content on both devices after repeated sync/relaunch |
| UI / platform | iOS/iPadOS and native macOS list/player/transcript/summary editing/export/archive, first-boot migration progress/error accessibility, background media reconciliation, recording/job recovery, Watch transfer, share extensions and Shortcuts/Action Button |

Use independent golden validation projections and randomized operation-sequence tests against a
simple reference model. Random tests retain seed/operation trace on failure and
assert invariants after every reopen. Inject failures at real commit boundaries;
mocked throwing functions alone do not prove crash durability. Avoid committing
user audio/transcripts/secrets; use synthetic or consented fixture content.

Extend existing suites rather than discarding their behavior: `ICloudBackupRegressionTests`
already has `testSQLiteMigrationFromShippingModelPreservesContentAndAddsDurableOutbox`,
`testSQLiteDeletionAndOutboxSurviveReopenTogether`,
`testSQLiteSaveFailureRollsBackTheDeletionAndItsOutboxTogether`, legacy-queue and
acknowledgement tests. These test **Core Data's SQLite store**, not a completed
migration to an app-owned database. Preserve CloudKit batch/retry/manifest/
orchestration/audio/metrics tests; add repository-backed variants. Also retain
`Swift6PersistenceIsolationTests`, `LocalDiarizationPersistenceTests`,
`SummaryAttachmentOrphanTests`, `RestoredAudioFileInstallerTests`,
`AdvancedTroubleshootingServiceTests`, `CacheMaintenanceTests`,
`ShareImportAuthorizationTests`, integration and Watch tests.

### Performance acceptance

Before selecting the backend, use the same synthetic libraries (100, 1,000,
10,000 recordings; representative 1-hour and long transcript payloads; sparse and
large asset sets), same hardware/OS and release configuration. Separate metadata
cost from audio copy/hash/network. Measure cold launch to usable library, first
page, detail load, edit/delete commits, import throughput, first-boot metadata
migration duration/peak RSS/disk amplification, background media reconciliation,
and steady-state sync requests/bytes. Compare original Core Data, optimized Core
Data adapter and SQLite.

Record at least 30 samples for routine operations with warm/cold cases separated.
Proposed acceptance budget: no p95 regression over 10% on key operations and a
repeatable improvement of at least 20% on the measured target bottleneck before
using speed to justify cutover. Revise budgets with recorded baseline evidence
before implementation, never after a failing result merely to pass. Library
operations must not block audio callbacks; no more work on the main actor than
publishing bounded UI state. No fixed millisecond guarantee is established by
this review. Migration must remain bounded in memory and resumable for large
libraries, even if it takes minutes.

### Reproducible commands and release evidence

Follow `docs/testing-regimen.md`; discover current destinations before using
example names. Run builds sequentially with isolated DerivedData and an existing
verified package cache. Record Xcode/Swift/OS, package lock hash and SQLite runtime.

```sh
git status --short --branch
git rev-parse HEAD
xcodebuild -showdestinations -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI"
xcodebuild test -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI" -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /private/tmp/bisonnotes-storage-ios -resultBundlePath /private/tmp/bisonnotes-storage-ios.xcresult
xcodebuild build -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI macOS" -destination 'platform=macOS' -derivedDataPath /private/tmp/bisonnotes-storage-mac
xcodebuild test -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI Watch App" -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' -derivedDataPath /private/tmp/bisonnotes-storage-watch
```

Use a fresh result-bundle path each run. Run normal SwiftLint from the app source
directory using the committed baseline and report actual counts, then
`git diff --check`. Run the new storage suites on native macOS as well, adding a
host-independent storage test target if current scheme membership cannot execute
them. Include signed Release archives for both app platforms and the manual
hardware cases from the testing regimen. A compile success or XCTest bootstrap
failure is not a passing test suite. Linux validation cannot close Apple runtime
gates.

CI on every storage-affecting change: schema coverage, both backend contracts,
focused migration/recovery/fault tests and existing sync policies. Nightly: expanded
crash seeds, all source-version fixtures and large-library benchmarks. Before
release: full UI/platform tests, signed physical upgrade/restore drills and real
two-device CloudKit matrix. Check in evidence summaries and artifact locations;
make these required release checks through the repository's existing workflow.
Do not add third-party scanning actions as part of this work.

## 11. Decisions and release blockers

The following product decisions were confirmed on 2026-09-07:

- Use GRDB **v7.11.1**, pinned exactly in the Xcode project and
  `Package.resolved`, with the system SQLite library. Do not use SQLCipher or
  another app-managed encryption/key layer.
- Do not build app-level export/restore or portable backups. Rely on Apple device
  backups and existing iCloud/CloudKit behavior; migration recovery is local,
  checkpointed and resumable.
- On the first post-update launch, block normal library access behind a
  progress/error screen until metadata (including transcripts, summaries and
  settings) is validated. Allow up to 2x temporary metadata usage, not a second
  full audio copy.
- Reconcile audio/media in the background with durable receipts, bounded staging,
  crash/kill recovery and source retention until validation.

The following remain Phase 0/5 evidence gates before a production cutover:

- Supported historical release/model set and how authentic synthetic fixtures
  will be produced; both checked-in models alone do not establish all shipped
  upgrade paths.
- Supported SQLite runtime fixes/settings and actual deployment-target
  compatibility; the GRDB dependency pin itself is settled.
- Exact legacy source/model fixture set and the retention period for the legacy
  source and unreconciled media; the app-level backup/export decision is settled.
- Large-library metadata maintenance duration and whether a later transactional
  replay design is required. The first release uses a blocking metadata window;
  no fixed millisecond promise is made.
- Measured bottleneck and go/no-go performance budget; keeping Core Data remains
  a valid outcome if reliability and backup improvements satisfy the need.
- Separate conflict-history/tombstone protocol design if the product requires
  lossless simultaneous edits and arbitrarily long offline-device recovery.

Stop release for any unexplained parity mismatch, unresolved user-content
identity conflict, unreplayable deletion intent, post-commit loss, unsafe account
crossing, inaccessible-only-copy deletion, unverifiable migration recovery,
unproven platform-backup assumption, schema coverage gap, failed required test,
or unsupported rollback claim. Do not downgrade such
failures to logging or silently mark migration complete. Existing unrelated test
failures require explicit recorded disposition, not a blanket "baseline" waiver.

## 12. Review limitations and current evidence

This task created planning documents and retired superseded documentation on
`v3.0-sqlitemigration`; see `docs/README.md` for the cleanup rationale. Source/model/call-site and existing-test
inspection was performed. The initial Phase 1 safety slice changes app startup
and persistent-store failure handling. The current Phase 0 slice pins GRDB and
adds an isolated file-backed smoke test, and verifies closed synthetic snapshots,
but does not change a user store or write CloudKit records. The
host-independent suite passed 19 tests with 0 failures; iOS `build-for-testing`
and native macOS builds also passed. No production upgrade, Apple device-backup
restore or physical two-device validation was performed for this plan or safety
slices.
Tavily search was unavailable due to DNS resolution in the shell; official Apple,
SQLite and GRDB references were checked through the web tool instead. The
inventory is pinned to the reviewed HEAD and must be regenerated/compared before
any backend, import, or cutover implementation. This is a gated implementation specification, not certification
that migration is safe to enable today.
