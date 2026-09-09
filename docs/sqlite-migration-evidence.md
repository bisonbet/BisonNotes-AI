# SQLite migration evidence ledger

Status: **Phase 0 in progress; Core Data remains authoritative and SQLite is not
enabled.** GRDB is pinned for an isolated file-backed spike only. This document
records the evidence required before a backend or cutover decision. It is
intentionally separate from the migration plan so measurements and dispositions
can be updated without rewriting the design.

## Provenance

| Item | Value |
| --- | --- |
| Runtime source baseline | `v2.5` at `d64660ba85dc04e6bc2f1fa88263427cb76b37aa` |
| Planning/implementation branch | `v3.0` |
| Planning revision | `275ec590c17fd01d010a0e584e334ddc3760c5b4` before implementation changes |
| Last implementation commit | `1a03ed6dde5e5f10e3dfd05f8db53046bacd276c` |
| GRDB dependency commit | `d4e143b47ec3fcbe737e36a228150c32b0b33a96` |
| Safety commit | `76949b18f88c8084ed62f21bfeafd6bad6be2469` |
| Reviewed date | 2026-09-07 |
| Production store/CloudKit inspection | Not performed |
| SQLite backend | GRDB 7.11.1 pinned for an isolated spike; no user-store cutover |

The source baseline and planning revision must remain distinct. A new source
commit requires this ledger and the model hashes in
`sqlite-migration-inventory.md` to be regenerated or explicitly compared.

## Handoff state

Core Data remains the only authoritative user store. An isolated
`SQLiteLibraryStore` actor and v1 schema now exist, with typed durable
migration-run begin/read/checkpoint operations, but no SQLite importer,
repository, production checkpoint coordinator, migration screen or media-copy
worker is enabled. The store is not connected to startup or user data. Its
focused tests are compiled into the existing app-hosted XCTest target; a runtime
attempt on the iPhone 17 Pro simulator exited before XCTest bootstrapping, so no
assertion has been counted as passing.

The next evidence-producing steps are to add a host-independent disk-backed
SQLite test target, finish the runtime/defaults ledger and Watch/share/background
gates, measure metadata first-boot cost and background media reconciliation, then
build the typed repository, Core Data importer and production coordinator around
the checkpoint contract. No live user database, CloudKit record, app
export/restore package or app-managed encryption key is in scope.

## Confirmed product and backend decisions

| Decision | Recorded choice | Evidence/status |
| --- | --- | --- |
| SQLite access | GRDB **v7.11.1**, exact revision `b83108d10f42680d78f23fe4d4d80fc88dab3212`, using the system SQLite module on Apple platforms | Xcode project and `Package.resolved` are pinned; file-backed smoke test is the Phase 0 gate |
| App-managed encryption | None; no SQLCipher, custom encryption, key management or credential export | Product decision confirmed 2026-09-07 |
| Backup/restore product | No app export, portable backup package, restore importer or recovery merge UI | Rely on Apple device backups and existing iCloud/CloudKit behavior; migration recovery is local and checkpointed |
| First boot | Blocking migration screen on the first post-update launch for metadata only: recordings, transcripts, summaries, jobs, archive references, pending mutations and required settings | Progress/error state must be durable and resumable after crash, force-quit, background expiration or power loss |
| Temporary storage | Up to 2x measured metadata footprint for source plus candidate database/index/WAL/checkpoints | No second full audio copy is permitted by this budget |
| Media | Background, bounded, resumable reconciliation with source retention until per-asset receipt and validation | Audio is not part of the blocking metadata copy |

## Storage-boundary ledger

The inventory is schema-complete for the two checked-in Core Data models. The
following runtime categories are required before calling the data boundary
complete.

| Category | Current evidence / entry points | Initial migration treatment | Fixture or test still required |
| --- | --- | --- | --- |
| Core Data store | `Persistence.swift`; `NSPersistentContainer` resolves the default Application Support store; store `-wal`/`-shm` sidecars are possible | Capture through a quiesced Core Data coordinator; never copy an active `.sqlite` alone; record resolved URL and model/store metadata | Closed-store/WAL snapshot fixture; reopen and compare through public Core Data APIs |
| Recording assets and sidecars | Documents audio; `.location` in `AudioRecorderViewModel+Location.swift`; `.recordingmeta` in `AudioRecorderViewModel+Utilities.swift`; segment/merge files in `AudioRecorderViewModel+Segments.swift`; `deferred-recovery.json` in `AudioRecorderViewModel+RecoveryContinuation.swift` | Keep exact source paths and bytes; migrate references in the blocking metadata phase, then reconcile media in the background without duplicating the full audio library | Interrupted recording, segment merge, sidecar/hash and process-death fixtures |
| Legacy files and relationships | `DataMigrationManager.swift` reads top-level audio, `.transcript`, `.summary`, `.location`; `EnhancedFileManager.swift` persists `Documents/file_relationships.json` | Retain source files until independent validation; malformed metadata is recovery data, not empty content | Legacy-only and mixed-file fixtures with corrupt/unknown files |
| Recovery and archive staging | `Application Support/Recording Recovery` in `MacRecordingReliability.swift`; `ArchiveStaging` and `AudioExportStaging` in `RecordingArchiveService.swift` | Migrate references and recovery metadata first; keep staged/recoverable bytes until a background receipt proves safe reconciliation; do not prune during migration | Interrupted recovery, external archive/bookmark and unavailable-provider fixtures |
| Summary attachments | `Documents/SummaryAttachments/<summary UUID>/metadata.json` and `files/` in `SummaryAttachmentStore.swift` | Migrate metadata in the blocking phase; reconcile bytes without deleting the source; rely on Apple device backup rather than an app export | Duplicate names, corrupt metadata, orphan-folder and crash/restart tests |
| Watch durable source and receipts | Watch `Documents/WatchRecordings/metadata.json` and `recordings/*.m4a` in `WatchRecordingStorage.swift`; `Documents/reliable_transfers.json` in `WatchConnectivityManager.swift` | Preserve source and acknowledgement order; do not delete the only unsynced Watch copy | Lost acknowledgement, duplicate transfer, process death at each phone commit boundary |
| Phone Watch staging | `tmp/WatchTransferStaging` and phone Documents handoff in `WatchConnectivityManager.swift` and `AudioRecorderViewModel+WatchIntegration.swift` | Journal source ID, staging, asset commit, database commit and acknowledgement independently | Restart between every transition; failed transfer retention |
| Share imports | App Group `group.bisonnotesai.shared/ShareInbox` and `.share-import-token` in `ShareExtensionProcessor.swift`; fallback `Documents/Inbox` cleanup in `BisonNotesAIApp.swift` | Preserve token/file/commit order and retry state; cleanup only after durable receipt | Token replay, unauthenticated fallback, duplicate and interrupted import fixtures |
| Defaults and suites | Five pending queues plus `SavedEnhancedSummaries`; iCloud routine/backoff/signature/manifest/quarantine keys; setup/location/sync/backup flags; App Group action-button key and `processedWatchRecordingIds` | Classify authoritative, derived and device-specific values; migrate exact keys only; keep Keychain out of the SQLite schema and do not export it | Defaults-domain inventory and malformed/unknown queue fixtures |
| Temporary import/cloud roots | `tmp/iCloudAudioStaging`, `tmp/BisonNotesWebImports`, macOS scratch/export paths, and other file-operation staging | Keep until receipt/checksum proves the durable destination; unknown files enter recovery inventory; bound staging so it cannot become a full audio duplicate | Interrupted copy, checksum mismatch, low-space and restart tests |
| Caches and models | FluidAudio models, map snapshots and Hugging Face/model caches under Application Support/Library/Caches | Keep outside the blocking metadata migration; preserve preferences and never delete unknown files; platform backup behavior is not app-controlled | Rebuild-after-migration and unknown-file retention tests |
| Keychain and external dependencies | Credentials, security-scoped bookmarks, external archives and cloud-only assets | Preserve same-device access; do not export secrets or manage keys; report dependencies to migration health | Sign-out/account switch, unavailable external provider and incomplete-reconciliation tests |

The direct Core Data touchpoint list in the inventory is not sufficient by
itself. Storage-boundary review must also cover `EnhancedFileManager`,
`ActionButtonLaunchManager`, `ShareExtensionProcessor`, both Watch storage and
connectivity implementations, `CloudAudioAssetStaging`,
`TemporaryFileCleanupService`, `WebImportDownloader`,
`RestoredAudioFileInstaller`, and the `AudioRecorderViewModel` persistence
extensions.

## Baseline evidence to record

Run these from the implementation checkout and attach the actual output or
result-bundle path to the phase handoff. No result is recorded here until it has
actually run on the current revision.

```sh
git status --short --branch
git rev-parse HEAD
xcodebuild -showdestinations -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI"
swiftlint lint --reporter summary
git diff --check
```

For each storage-affecting change also record Xcode/Swift/OS, package-resolution
state, active model hashes, SQLite runtime/version and the exact test/build
commands. Simulator/build success does not close signed-app, physical-device,
CloudKit or two-device evidence gates.

## Working-tree validation on 2026-09-09

The following checks were run against the Phase 0/1 working tree on `v3.0`:

- `swiftc -parse` passed for every changed Swift file.
- Native macOS Debug build passed with Xcode 26.6, using the existing package
  cache and isolated DerivedData at `/private/tmp/bisonnotes-storage-mac`.
- GRDB package resolution passed at exactly `7.11.1` with revision
  `b83108d10f42680d78f23fe4d4d80fc88dab3212`; the native macOS Debug build with
  the package integrated passed using `/private/tmp/bisonnotes-grdb-mac`.
- Generic iOS `build-for-testing` passed, including the changed XCTest bundle,
  including `GRDBSystemSQLiteTests`, using `/private/tmp/bisonnotes-grdb-ios`.
- Generic iOS `build-for-testing` passed after adding the isolated store and
  focused tests, using `/private/tmp/bisonnotes-sqlite-schema-ios-20260909`.
- Native macOS Debug build passed after adding the isolated store, using
  `/private/tmp/bisonnotes-sqlite-schema-mac-20260909`.
- Generic iOS `build-for-testing` passed after adding the durable checkpoint
  operations and focused tests, using
  `/private/tmp/bisonnotes-sqlite-checkpoint-ios-20260909`.
- Native macOS Debug build passed after adding the durable checkpoint operations,
  using `/private/tmp/bisonnotes-sqlite-checkpoint-mac-20260909`.
- The GRDB smoke test is compiled into the iOS XCTest bundle but has not yet run
  as an XCTest assertion; the app's existing simulator CloudKit bootstrap and
  the current CoreSimulator service state prevent treating the simulator test
  path as a passing runtime result.
- A temporary macOS Core Data probe verified the default Application Support
  URL, synchronous coordinator loading, the `/dev/null` in-memory path and a
  missing-parent failure path against the built model.
- The focused iOS Simulator test command for the checkpoint slice reached app
  launch but failed before XCTest bootstrapping: `BisonNotes AI` exited early
  and the test runner never established a connection. The result bundle is
  `/private/tmp/bisonnotes-sqlite-checkpoint-focused-20260909.xcresult`; its
  summary reports 0 passed tests, 1 runner failure and 0 assertions, so this is
  not a passing test result.
- The new tests cover schema bootstrap, seeded identity/reopen, restrictive
  relationship foreign keys, GRDB migration rollback and checkpoint
  persistence/validation, but their runtime assertions remain open until a
  host-independent test target can execute them.
- Focused SwiftLint on the SQLite store/checkpoint app files and test file
  reported 0 violations with SourceKit disabled; SwiftLint emitted only its
  expected SourceKit-rule skip notice.
- Full SwiftLint reported 1,979 violations (271 serious) across 206 files and
  ended with a cache permission warning. A five-file diagnostic run reported
  98 violations in the five changed files (18 serious) with SourceKit-dependent
  rules disabled; no baseline-clean claim is made.
- `git diff --check` passed.

## Open evidence gates before backend selection/cutover

- License review, Swift 6 and deployment-target compatibility for the pinned
  release, plus supported system-SQLite runtime/pragma settings.
- Complete historical Core Data model/source fixture set and exact defaults-suite
  classification.
- First-boot metadata duration, peak RSS and temporary disk usage against the 2x
  metadata budget; background media reconciliation duration and interruption
  behavior without full-audio duplication.
- Measured bottleneck and performance go/no-go budget.
- Crash/force-quit/background-expiration recovery evidence for every checkpoint,
  including stale activation descriptors and unreconciled media.

These gates allow implementation of the isolated backend spike, schema and
checkpoint machinery. They do not authorize a user-store migration, app-level
export/restore feature, CloudKit protocol change or production cutover.
