# SQLite migration evidence ledger

Status: **Phase 0 in progress; Core Data remains authoritative and SQLite is not
enabled.** This document records the evidence required before a backend or
cutover decision. It is intentionally separate from the migration plan so
measurements and dispositions can be updated without rewriting the design.

## Provenance

| Item | Value |
| --- | --- |
| Runtime source baseline | `v2.5` at `d64660ba85dc04e6bc2f1fa88263427cb76b37aa` |
| Planning/implementation branch | `v3.0` |
| Planning revision | `275ec590c17fd01d010a0e584e334ddc3760c5b4` before implementation changes |
| Reviewed date | 2026-09-07 |
| Production store/CloudKit inspection | Not performed |
| SQLite backend | Not selected or added |

The source baseline and planning revision must remain distinct. A new source
commit requires this ledger and the model hashes in
`sqlite-migration-inventory.md` to be regenerated or explicitly compared.

## Storage-boundary ledger

The inventory is schema-complete for the two checked-in Core Data models. The
following runtime categories are required before calling the data boundary
complete.

| Category | Current evidence / entry points | Initial migration treatment | Fixture or test still required |
| --- | --- | --- | --- |
| Core Data store | `Persistence.swift`; `NSPersistentContainer` resolves the default Application Support store; store `-wal`/`-shm` sidecars are possible | Capture through a quiesced Core Data coordinator; never copy an active `.sqlite` alone; record resolved URL and model/store metadata | Closed-store/WAL snapshot fixture; reopen and compare through public Core Data APIs |
| Recording assets and sidecars | Documents audio; `.location` in `AudioRecorderViewModel+Location.swift`; `.recordingmeta` in `AudioRecorderViewModel+Utilities.swift`; segment/merge files in `AudioRecorderViewModel+Segments.swift`; `deferred-recovery.json` in `AudioRecorderViewModel+RecoveryContinuation.swift` | Preserve exact relative paths and bytes; classify interrupted/recoverable sources separately from disposable work | Interrupted recording, segment merge, sidecar/hash and process-death fixtures |
| Legacy files and relationships | `DataMigrationManager.swift` reads top-level audio, `.transcript`, `.summary`, `.location`; `EnhancedFileManager.swift` persists `Documents/file_relationships.json` | Retain source files until independent validation; malformed metadata is recovery data, not empty content | Legacy-only and mixed-file fixtures with corrupt/unknown files |
| Recovery and archive staging | `Application Support/Recording Recovery` in `MacRecordingReliability.swift`; `ArchiveStaging` and `AudioExportStaging` in `RecordingArchiveService.swift` | Include recoverable artifacts and bookmark/export metadata in recovery inventory; do not prune during migration | Interrupted recovery, external archive/bookmark and unavailable-provider fixtures |
| Summary attachments | `Documents/SummaryAttachments/<summary UUID>/metadata.json` and `files/` in `SummaryAttachmentStore.swift` | Copy metadata and bytes, including orphan folders; preserve malformed metadata | Duplicate names, corrupt metadata, orphan-folder and round-trip restore tests |
| Watch durable source and receipts | Watch `Documents/WatchRecordings/metadata.json` and `recordings/*.m4a` in `WatchRecordingStorage.swift`; `Documents/reliable_transfers.json` in `WatchConnectivityManager.swift` | Preserve source and acknowledgement order; do not delete the only unsynced Watch copy | Lost acknowledgement, duplicate transfer, process death at each phone commit boundary |
| Phone Watch staging | `tmp/WatchTransferStaging` and phone Documents handoff in `WatchConnectivityManager.swift` and `AudioRecorderViewModel+WatchIntegration.swift` | Journal source ID, staging, asset commit, database commit and acknowledgement independently | Restart between every transition; failed transfer retention |
| Share imports | App Group `group.bisonnotesai.shared/ShareInbox` and `.share-import-token` in `ShareExtensionProcessor.swift`; fallback `Documents/Inbox` cleanup in `BisonNotesAIApp.swift` | Preserve token/file/commit order and retry state; cleanup only after durable receipt | Token replay, unauthenticated fallback, duplicate and interrupted import fixtures |
| Defaults and suites | Five pending queues plus `SavedEnhancedSummaries`; iCloud routine/backoff/signature/manifest/quarantine keys; setup/location/sync/backup flags; App Group action-button key and `processedWatchRecordingIds` | Classify authoritative, derived and device-specific values; migrate exact keys only; keep Keychain out of portable backups | Defaults-domain inventory and malformed/unknown queue fixtures |
| Temporary import/cloud roots | `tmp/iCloudAudioStaging`, `tmp/BisonNotesWebImports`, macOS scratch/export paths, and other file-operation staging | Keep until receipt/checksum proves the durable destination; unknown files enter recovery inventory | Interrupted copy, checksum mismatch, low-space and restart tests |
| Caches and models | FluidAudio models, map snapshots and Hugging Face/model caches under Application Support/Library/Caches | Exclude only with an explicit manifest disposition; preserve preferences, never delete unknown files | Backup manifest exclusion and rebuild-after-restore tests |
| Keychain and external dependencies | Credentials, security-scoped bookmarks, external archives and cloud-only assets | Preserve same-device access; portable backup reports exclusions/dependencies and does not export secrets by default | Sign-out/account switch, unavailable external provider and incomplete-backup tests |

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

## Working-tree validation on 2026-09-07

The following checks were run against the uncommitted Phase 0/1 working tree on
`v3.0`:

- `swiftc -parse` passed for every changed Swift file.
- Native macOS Debug build passed with Xcode 26.6, using the existing package
  cache and isolated DerivedData at `/private/tmp/bisonnotes-storage-mac`.
- Generic iOS `build-for-testing` passed, including the changed XCTest bundle,
  using `/private/tmp/bisonnotes-storage-ios`.
- A temporary macOS Core Data probe verified the default Application Support
  URL, synchronous coordinator loading, the `/dev/null` in-memory path and a
  missing-parent failure path against the built model.
- The focused iOS Simulator test command reached app launch but failed before
  XCTest bootstrapping because the existing app CloudKit initialization calls
  `CKContainer` in the simulator. The result bundle is
  `/private/tmp/bisonnotes-storage-ios-focused-20260907-rerun.xcresult`; no
  test assertion ran, so this is not a passing test result.
- Full SwiftLint reported 1,979 violations (271 serious) across 206 files and
  ended with a cache permission warning. A five-file diagnostic run reported
  98 violations in the five changed files (18 serious) with SourceKit-dependent
  rules disabled; no baseline-clean claim is made.
- `git diff --check` passed.

## Decisions required before backend selection

- Exact GRDB release, license review, Swift 6 support and deployment-target
  compatibility.
- System versus bundled SQLite and supported runtime/pragma settings.
- Backup encryption, retention, external-asset inclusion and restore/cloud-intent
  policy.
- Maximum acceptable migration maintenance window versus a later journal/replay
  design.
- Measured bottleneck and performance go/no-go budget.

Until these decisions and the baseline measurements are recorded, implementation
should remain in safety prerequisites, ledger coverage and backend-independent
tests. It must not add a GRDB dependency or enable a user-store migration.
