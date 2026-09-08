# Reliable storage and safe SQLite migration plan

Status: **design and source review only; no migration implemented or enabled**.
Implementation branch: `v3.0`, created from `v2.5` for this work.
Reviewed 2026-09-07 on `v2.5`, clean starting checkout at
`d64660ba85dc04e6bc2f1fa88263427cb76b37aa` (the pushed `origin/v2.5`).
No production user database or live CloudKit account was inspected. Source review
is not evidence that a particular user's store is healthy, nor a speed benchmark.

## 1. Recommendation and decision

Core Data is already using SQLite through `NSPersistentContainer` in
`Persistence.swift`. This proposal replaces its object-management layer with an
app-owned SQLite schema, preferably accessed through **GRDB**, while retaining the
existing CloudKit protocol initially. SQLite does not itself provide device sync,
portable media backups, or protection from application-level deletion mistakes.
Apple explicitly says not to manipulate Core Data's private SQLite schema with
native SQLite APIs ([Apple store guidance](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreData/PersistentStoreFeatures.html)).

Proceed in independently useful steps: strengthen persistence failure handling;
create complete, verifiable backups; introduce a repository boundary over Core
Data; benchmark; implement a separate SQLite backend and importer; validate it in
shadow mode; cut over only after all safety gates pass. Keep Core Data if the
measured benefit does not justify the migration. Do not make a rewrite a
prerequisite for fixing reliability problems.

| Option | Benefit | Cost / recommendation |
| --- | --- | --- |
| Harden existing Core Data | Lowest migration risk; existing SQLite transactions and cloud outbox remain | Required first step; benchmark batching, projections and indexing here too |
| App-owned SQLite via GRDB | Explicit constraints, transactions, queries, backup/migration tooling, testable value types | Recommended migration candidate, conditional on evidence; adds dependency and app responsibility for observation/schema evolution |
| Raw SQLite C API | Maximum control, fewer wrapper dependencies | More binding, lifecycle and concurrency code to get wrong; not the default |
| SwiftData or a new sync provider | Potential alternative architecture | Separate evaluation; does not directly solve complete backup and conflict preservation; do not combine with this migration |

Use GRDB's documented database access and migration facilities; pin a tested
release and commit `Package.resolved`, check its license, Swift 6 support and both
app deployment targets. Do not guess a version or update unrelated dependencies.
The upstream project is the reference ([GRDB](https://github.com/groue/GRDB.swift)).

**Non-negotiable safety contract:** no successful migration may silently omit,
truncate, regenerate, deduplicate, or delete user content. Preserve source bytes
and identities. Unsupported/corrupt data blocks activation and remains available
for recovery. A backup verified only by counts is insufficient. No system can
promise zero loss from all hardware failures; this design makes loss prevention,
recovery, and evidence explicit.

## 2. Source findings that shape the work

Paths below are relative to `BisonNotes AI/BisonNotes AI/` unless noted. Symbol
anchors are authoritative if line numbers change. See
[the generated inventory](sqlite-migration-inventory.md) for every current model
attribute, relationship, model hash, and direct Core Data consumer found by search.

| Evidence | Implication and required treatment |
| --- | --- |
| `Persistence.swift`: `handlePersistentStoreLoadFailure` installs a temporary in-memory store | Durable-storage failure can leave a usable-looking data layer whose new data disappears at exit. Add an explicit unavailable/recovery state before migration; never run import/sync/cleanup against this fallback. Preserve any rescue recording through a separate durable spool with visible status. |
| `CoreDataManager.getAllRecordings` returns `[]` on fetch failure; `ContentView.initializeApp` uses empty collections to initiate migration, and otherwise runs cleanup | Empty is not a trustworthy absence signal. Migration and cleanup must use throwing reads and a successfully opened, validated store. Replace collection-size migration triggers with durable version/state records. |
| `CoreDataManager.cleanupRecordingsWithMissingFiles` deletes some metadata or clears URLs; startup invokes it | Missing or inaccessible audio is not proof of user deletion. During migration/recovery suspend all destructive cleanup. Retain path and metadata with explicit unavailable state rather than guessing. |
| `Persistence.swift`: `PendingCloudMutationStore`; `CoreDataManager.save(committing:)` | Local deletes and five kinds of cloud intent already commit together. Preserve this invariant, original `requestedAt`, child IDs, payload versions, coalescing and snapshot-conditional acknowledgement. Do not move this queue back into UserDefaults. |
| `CoreDataManager`, `AppDataCoordinator`, `RecordingWorkflowManager`, `TranscriptManager`, views and sync expose managed objects and/or contexts | A database-file swap cannot replace Core Data. Migrate APIs and callers to immutable values and explicit commands before cutover. |
| Active model `BisonNotes_AI_v2` has six entities, including archive locations and pending mutations | A three-table recording/transcript/summary migration would lose data. Preserve all six, both model versions, every relationship and redundant ID. |
| Most model fields, including content IDs, are optional; scalar IDs coexist with object relationships | Existing stores may contain nil IDs, duplicate UUIDs or inconsistent links. Do not force uniqueness with `INSERT OR REPLACE`, silently drop orphans, or invent identity during import. |
| `SummaryAttachmentStore` stores notes and files under `Documents/SummaryAttachments/<summary UUID>/` | Database and current cloud content backup alone are not a complete library backup. Preserve supplemental metadata and bytes, including folders not currently linked to a row. |
| `RecordingArchiveService` stores security-scoped bookmarks and exported paths | Preserve bookmark bytes, archive flags, verification state and destinations. A bookmark's existence does not prove a usable external copy or portable authorization. |
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
7. Keychain credentials stay in Keychain. Ordinary portable backups exclude
   secrets; preserve them on same-device migration. Any credential export is an
   explicit separate opt-in with reviewed encryption. Device-specific bookmarks,
   local model paths and permission grants do not become portable by copying.
8. Downloaded models and reproducible map/render caches can be excluded from
   portable backups with a manifest explanation; retain model preferences.
   Unknown files are preserved in a recovery inventory until classified, never
   automatically removed because they do not match a known pattern.
9. Cloud-only records/assets, quarantine, tombstones, and remote archive files
   must be listed as external dependencies. An offline migration need not fetch
   them; a backup claiming to be self-contained must actually include their
   bytes, or clearly report that it is incomplete.

Do not assume local-only content is unwanted in a user-selected offline backup.
Do honor `isCloudSyncDisabled` for network uploads and automatic cloud backups.

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
- `BackupService`, `MigrationCoordinator`, `StorageHealthReport`: use the same
  exclusive maintenance gate; diagnostics are non-destructive and redact content.

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
| `migration_runs`, `migration_row_map` | Source fingerprint, exporter version, per-batch cursor/count/hash, source row identity to destination row mapping |
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
known compatibility limit explicitly. Do not derive an export solely from
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
migration. Preserve them in both the source and recovery export and report the
specific issue. A later repair can create a documented mapping with user-visible
recovery; the importer itself must not choose a winner. Valid multiple child
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
   reference/backup/migration lease check. Retry failure; do not report cleanup
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

### A. Preflight and quiescence

Run before normal startup migrations, cleanup, cloud triggers and background job
resumption. Wait for or safely finish an active recording before starting; do not
interrupt captured audio to migrate. Close editing transactions and drain current
writes. Suspend new imports/jobs or spool incoming files durably without an ACK.
Pause inbound/outbound sync and asset pruning. All foreground/background/extension
entry points must observe the gate; Apple background expiration checkpoints and
retries, never forces a partially completed cutover.

Resolve actual store URLs, model version hashes, app group paths and available
space. Estimate source snapshot + new database/index/WAL + media copy budget +
operational headroom using measured sizes, not a fixed multiplier. On insufficient
space, cancellation, locked protection or inaccessible files, keep normal legacy
operation available after safely leaving the gate. Never reclaim user data to
make migration space.

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
snapshot/import/activation, while providing responsive progress and safe cancel.
If this is too slow for large libraries, add a separately tested change journal;
do not quietly allow writes that the snapshot misses. On leaving the gate and
allowing legacy writes, invalidate the candidate; a subsequent attempt takes a
fresh snapshot unless journal replay is proven complete.

Copy assets independently (APFS clones acceptable with verified copy semantics),
not hard links vulnerable to later modification. Flush and verify source manifest,
all required files and hashes, then reopen the snapshot using an isolated reader.
External media that cannot be copied remains an explicitly missing dependency;
retained references cannot justify a "complete backup" claim.

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

A validator independent of importer mapping code compares source export to a
freshly reopened destination. Check entity multisets, field values and nulls,
exact raw JSON/binary content, relationship graph, ID map, timestamps, pending
mutations including unknown payloads, file inventory/checksums, notes, bookmarks,
archive state, jobs and receipts. Record duplicate/missing link anomalies
individually. Require `integrity_check` success and zero `foreign_key_check`
violations on the new database. Row counts and checksums alone do not prove
usable media: open representative audio, render transcripts/summaries and test
notes/attachments, archive resolution and recovery UI.

The validator must not call the importer to decide its expected results. Fixtures
need explicit expected graphs and independent canonical exports. Unknown fields
in a source model fail the coverage check rather than disappearing.

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

Retain the recovery generation through at least two stable releases and until a
verified user-exported backup exists; choose the final retention/storage policy
before rollout. Never prune a retained database independently of its media or
when it is the only recoverable copy. Keep historical model readers for supported
skipped-version upgrades even after runtime Core Data use ends.

## 7. Backup and restore product contract

Ship a **local portable library backup before cutover**, usable without iCloud or
an external AI service. The format should be a versioned package/archive containing
`manifest.json`, a neutral lossless logical export, a consistent database snapshot
(optional implementation-specific recovery payload), content-addressed asset
copies, supplemental/legacy data and an explicit exclusions/dependencies report.
Use deterministic records with documented types/encoding, not an opaque Swift
object archive. A library backup is different from exporting rendered summaries
or audio alone. Include format/minimum-reader version, source app/model version,
library/generation ID, entity counts and per-file hashes/lengths.

Capture a consistent database snapshot and lease its referenced immutable files
until copy/verification finishes. With current mutable sidecars, use the exclusive
maintenance gate. Write a temporary package, verify all members and a trial import,
then publish atomically; incomplete files never replace the last good backup.
Hashing is corruption detection, not authentication. Backups contain sensitive
content: protect local staging like source data, make export destination explicit,
and do not claim encryption unless an authenticated encrypted format and key/
password recovery have been implemented and tested. Avoid plaintext export of
Keychain secrets. Finalize encryption policy before enabling automatic exports to
external locations; do not invent custom cryptography.

Restore flow: validate versions, bounds, manifest and hashes → reject archive
path traversal/symlinks, duplicate paths and decompression bombs → estimate space →
import into a new generation offline → validate → show content/dependency counts
and conflicts → back up current library → explicitly activate. A restore never
partially overwrites the live database. Reopening the resulting library, with
usable files and relationships, is the acceptance test. Unknown newer formats are
rejected without modifying either library.

Offer replacement and recovery-import as **distinct operations**. Initial release
may implement only validated replacement plus a separate recovery viewer.
Recovery-import/merge requires deterministic IDs, conflict preservation and tests;
do not emulate it with SQL REPLACE. Do not immediately replay old pending deletes
from a portable backup against today's cloud account. Same-device crash recovery
preserves its queued intent; portable/time-travel restore binds to the chosen
account and reviews/reconciles stale intent before cloud writes. Keep original
intent in the package even when held from replay. Restoring old content must not
silently defeat newer cloud deletions or erase newer edits.

Keep multiple known-good generations with an explicit retention policy; test
restore from an older backup, not just the latest. Distinguish "metadata complete",
"local assets included", "external assets unavailable", and "fully self-contained"
in status. A cloud success timestamp is not proof that every local attachment,
archived file or recording is backed up.

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

- Order: flush outbound deletions, apply inbound markers, backup, restore, prune
  only genuinely superseded candidates under the existing policy.
- Content timestamps, not `syncUpdatedAt`, arbitrate; retain equal/missing-time
  behavior for compatibility. Preserve earliest `requestedAt`, revival grace,
  retention policy and the special imported-audio unlink marker semantics.
- Distinguish whole deletion, local-only removal, summary removal, transcript
  removal and imported-audio removal. Metadata-only restore must not unlink good
  audio. Failed file cleanup stays retryable.
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
CloudKit backup include them. In the first release preserve them locally and in
portable backup. Adding network upload changes the user's privacy expectations
and needs a reviewed product policy plus production schema rollout tests.

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
| 0: Baseline / contract | Revalidate HEAD and instructions; complete data ledger from appendix, runtime store paths and defaults suites; inspect release history for every supported model. Add benchmark/evidence spec in `docs/sqlite-migration-evidence.md`. Select/pin candidate GRDB in an isolated spike only. | Schema coverage includes every model field/relationship and non-database category; baseline tests and timings recorded with limitations. Storage/backup decisions below settled before dependent phases. |
| 1: Safety prerequisites | `Persistence.swift`, `BisonNotesAIApp.swift`, `ContentView.swift`, `AppDataCoordinator`, cleanup/troubleshooting and Watch receipt/retention paths: explicit storage health, startup gate, throwing critical reads, durable failure behavior. | Open/read/save failure never looks like empty success, triggers cleanup, acknowledges a lost import or accepts ephemeral "saved" data; existing behavior suites pass. |
| 2: Backup / recovery | New storage snapshot and portable backup services, restore staging, recovery UI; adapt attachments/archive/file services. Keep Core Data authoritative. | Full offline round trip of all ledger categories, WAL fixture, interruption, malformed package and low-space tests; current library preserved on every failure. |
| 3: Repository boundary | Add domain values, protocols, observation and Core Data adapter. Convert `AppDataCoordinator` and `RecordingWorkflowManager`, then jobs/imports/transcript/summary/archive services, UI, cloud store access, test fixtures and previews. | Core Data backend passes unchanged behavior plus shared repository contract tests. Managed objects/contexts confined to adapter and legacy importer; all callers/targets audited. |
| 4: SQLite backend | New schema/migrations, repository implementation, file journal, receipts, backup support and metrics. Add dependency/project configuration for iOS/native macOS only unless another target truly needs it. | Shared contract suite passes on both disk-backed backends; transactions/constraints/observation/fault tests pass; measured performance gate met. No user cutover. |
| 5: Import / verifier | New migration state machine, model-aware source reader, lossless row map, validation and recovery reports. | Both source models plus skipped-version legacy fixtures migrate; every transition survives process kill; anomalies block safely; no cloud side effects. |
| 6: Shadow qualification | Read-only SQLite comparisons from a frozen source snapshot; retain Core Data as sole authority. Store per-field mismatch reports without content leakage. | Zero unexplained mismatches across representative fixtures/libraries. If legacy writes resume, candidate invalidated/rebuilt; do not pretend it remains current. |
| 7: Guarded activation | Bootstrap generation selection, UI/error/progress recovery, stale-worker rejection, fresh-install SQLite path, mixed-version cloud testing. | Full automated matrix plus signed hardware/backup/upgrade/CloudKit gates pass; forward-fix and restore drill performed. Opt-in internal cohort first. |
| 8: Rollout / retention | Internal → opt-in beta → small release cohort → wider release, with evidence at each expansion. Retain legacy recovery copies/models and backends as required. | Any unexplained loss, corruption, privacy regression, resurrection or divergence stops expansion. A rollout flag only prevents new migrations; it never flips active users to stale Core Data. |
| 9: Later simplification | Remove runtime Core Data only after imports from supported historical releases still work; separately consider sync protocol enhancements and notes/attachment sync. | No unresolved ledger/test gaps. Keep model-reader compatibility and backups for supported users; removal is not a prerequisite for migration success. |

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
`LibraryBackupRoundTripTests`, `CoreDataToSQLiteMigrationTests`,
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
| Race ordering | Rename/delete/import/ASR completion during snapshot, restore or upload; stale generation callback; app background expiration; Watch duplicate after lost ACK; successful revision stream matches committed state |
| Backup/restore | Complete offline restore to fresh container, old backup, partial/missing asset, truncated/tampered package, invalid path, low space, cancel, incompatible format, notes and archive state; original library unchanged until explicit activation |
| Cloud fakes | Existing arbitration/manifest/partial failure/coalescing/erase/backoff/exclusion suites on both adapters, lost local ACK after remote save, account switch, quota and network loss, metadata-only audio semantics |
| Real CloudKit | Signed old/new, new/new and upgrade-during-offline combinations; concurrent edit/delete, clock skew, beyond-retention offline return, quarantine and legacy records, local-only toggles, interrupted assets, account changes; inspect content on both devices after repeated sync/relaunch |
| UI / platform | iOS/iPadOS and native macOS list/player/transcript/summary editing/export/archive, background recording/job recovery, Watch transfer, share extensions, Shortcuts/Action Button, migration progress/cancel/error accessibility |

Use independent golden exports and randomized operation-sequence tests against a
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
page, detail load, edit/delete commits, import throughput, backup/restore,
migration duration/peak RSS/disk amplification, and steady-state sync requests/
bytes. Compare original Core Data, optimized Core Data adapter and SQLite.

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
focused migration/backup/fault tests and existing sync policies. Nightly: expanded
crash seeds, all source-version fixtures and large-library benchmarks. Before
release: full UI/platform tests, signed physical upgrade/restore drills and real
two-device CloudKit matrix. Check in evidence summaries and artifact locations;
make these required release checks through the repository's existing workflow.
Do not add third-party scanning actions as part of this work.

## 11. Decisions and release blockers

Recommended defaults are specified above; finalize these in Phase 0 with measured
or product evidence before their dependent work:

- Supported historical release/model set and how authentic synthetic fixtures
  will be produced; both checked-in models alone do not establish all shipped
  upgrade paths.
- Exact GRDB version, system versus bundled SQLite, supported SQLite runtime
  fixes/settings and actual deployment-target compatibility.
- Final backup encryption, retention, external-asset inclusion, portable restore
  cloud-intent handling and recovery UX policies.
- Large-library maintenance window versus a later transactional replay design.
- Measured bottleneck and go/no-go performance budget; keeping Core Data remains
  a valid outcome if reliability and backup improvements satisfy the need.
- Separate conflict-history/tombstone protocol design if the product requires
  lossless simultaneous edits and arbitrarily long offline-device recovery.

Stop release for any unexplained parity mismatch, unresolved user-content
identity conflict, unreplayable deletion intent, post-commit loss, unsafe account
crossing, inaccessible-only-copy deletion, unverifiable backup, schema coverage
gap, failed required test, or unsupported rollback claim. Do not downgrade such
failures to logging or silently mark migration complete. Existing unrelated test
failures require explicit recorded disposition, not a blanket "baseline" waiver.

## 12. Review limitations and current evidence

This task created planning documents and retired superseded documentation on
`v3.0`; see `docs/README.md` for the cleanup rationale. Source/model/call-site and existing-test
inspection was performed; no app code, dependency, user store or CloudKit record
was changed. No build, XCTest run, performance measurement, production upgrade,
backup restore or physical two-device validation was performed for this plan.
Tavily search was unavailable due to DNS resolution in the shell; official Apple,
SQLite and GRDB references were checked through the web tool instead. The
inventory is pinned to the reviewed HEAD and must be regenerated/compared before
implementation. This is a gated implementation specification, not certification
that migration is safe to enable today.
