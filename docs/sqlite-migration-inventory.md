# SQLite migration inventory

Source: `v2.5` at `d64660ba85dc04e6bc2f1fa88263427cb76b37aa`, inspected 2026-09-07. Implementation branch: `v3.0-sqlitemigration`; clean PR target: `v3.0` (kept at the `v2.5` baseline). Isolated schema/checkpoint/runtime foundation: `e612ebdcbbabb9522cdb4e9b15489324af1476a4`. Closed-snapshot verifier: `444542ac`; Core Data source fixtures: `5f9744d`; metadata importer: `9731e69a`; recovery reports: `40b431a0`; repository/settings checkpoint: `b71d9984`; observation checkpoint: `cdd0bf8e`; schema/contract tests: `82e687e8`; settings catalog checkpoint: `5232640`; catalog validation: `52101ae0`; CloudKit source contract: `e2ff6c0`; legacy source contract: `f8b4d6c7`; Core Data history observation: `c692c8c7`; Core Data migration source reader/catalog: `630a513e`; resumable metadata coordinator: `230e511c`; durable pause/settings phase: `5c88828b`; explicit Core Data/settings input boundary: `54e6c141`; durable media operation worker: `44515c52`; durable import receipt idempotency: `b8b80783`; media transfer/retention boundary: `c8b70087`; application media roots/source retention: `88c393e9`; provider archive-restore journal/planner/reconciler: `2ba09adf`; recording metadata edits: `ed898703`; security-scoped bookmark lease: `60f4d84f`; migration progress presentation: `01887385`; production recording-creation callers: `47cf88d5`; CloudKit summary restore repository boundary: `8d63a010`; CloudKit recording restore repository boundary: `91406ea2`; CloudKit transcript restore repository boundary: `961a5837`; CloudKit summary-metadata restore repository boundary: `96e49c91`.
Current restartable media reconciliation checkpoint: `fe99e3ff`.
Current settings source-inventory checkpoint: `9dfed6fd`.
Current observation-subscription checkpoint: `33bdc7ed`.
Current startup-boundary checkpoint: `1669066e`.
Current maintenance-gate checkpoint: `69074da5`.
Current provider archive-restore integration checkpoint: `be23b99f`.
Current provider archive-restore lifecycle checkpoint: `9cddca7c`.
Current media-root selection checkpoint: `a786fcd6`.
Current generic media metadata-acknowledgement checkpoint: `04e962b2`.
Current source-coordinator checkpoint: `1787855e`.
Current metadata-caller checkpoint: `e115ccbc`.
Current cloud-sync preference checkpoint: `047c4a9a`.
Current processing-job checkpoint: `0b1de446`.
Current transcript-persistence checkpoint: `caf582ec`.
Current summary-persistence checkpoint: `0af7809c`.
Current archive-state checkpoint: `37d55b77`.
Current archive-location checkpoint: `4e35a7d9`.
Current repository-gate adoption checkpoint: `431ff801`.
Current recording-creation checkpoint: `b57e871f`.
Current file-import checkpoint: `0403d053`.
Current transcript-import checkpoint: `3fe7d86d` (following `8bbbe283`).
Current full-recording-deletion checkpoint: `38ab4fbd`.
Current preserve-summary-deletion checkpoint: `3d859318`.
Current inbound-recording-tombstone checkpoint: `4d97e80e`.
Current inbound-transcript-tombstone checkpoint: `bddddd0c`.
Current inbound-summary-tombstone checkpoint: `e14d4120`.
Current inbound-imported-audio checkpoint: `13340bc9`.
Current archive-export caller checkpoint: `a47eada6`.
Current recording-file cleanup checkpoint: `fde51735`.
Current archive re-import checkpoint: `880b2c03`.
Current archive read/restore checkpoint: `f83cfbff`.
Current recording metadata-edit checkpoint: `ed898703`.
Current security-scoped bookmark-lifetime checkpoint: `60f4d84f`.
Current first-boot migration-presentation checkpoint: `01887385`.
Current production recording-creation checkpoint: `47cf88d5`.
Current generic Share/Inbox audio-import checkpoint: `f78b7496`.
Current OS-managed media retry checkpoint: `9557c09f`.
Current CloudKit summary-restore checkpoint: `8d63a010`.
Current CloudKit recording-restore checkpoint: `91406ea2`.
Current CloudKit transcript-restore checkpoint: `961a5837`.
Current CloudKit summary-metadata restore checkpoint: `96e49c91`.
Current production Watch media-intake checkpoint: `d80fa3bc`.

Generated from checked-in model XML and Swift symbol searches. This inventories schema, not production row contents. Add runtime paths, defaults domains, file formats, indirect callers and source-version fixtures in Phase 0 of [the plan](sqlite-migration-plan.md).

### CloudKit transcript restore checkpoint

Checkpoint `961a5837` routes transcript scalar metadata through
`LibraryTranscriptCloudRestoreCommand` in both repository adapters. The command
accepts legacy CloudKit records with missing segments, checks stable UUID and
expected `lastModified` identity, preserves the existing recording relationship
during the metadata commit and records a durable SQLite transcript observation.
The Core Data restore captures the recording transcript link before recording
metadata is applied, then performs timestamp-arbitrated relationship repair and
restores the prior pointer/status when the incoming child loses. This is still
a Core Data-authoritative, pre-cutover boundary; summary metadata now has a
separate checkpoint, while attachment handling, production SQLite selection and
live CloudKit/user-data validation remain open.

### CloudKit summary-metadata restore checkpoint

Checkpoint `96e49c91` routes summary scalar metadata through
`LibrarySummaryCloudRestoreCommand` in both repository adapters. The command
accepts older CloudKit rows with omitted summary fields, checks the stable UUID
and expected `generatedAt` revision, preserves existing Core Data/SQLite
relationship state during the metadata commit, and rejects conflicting
recording/transcript identities. SQLite records a durable summary observation.
The restore phase captures each recording's summary pointer/status before
recording metadata is applied, then arbitrates the incoming summary link by
timestamp and restores the prior pointer/status when the local summary wins;
transcript linking occurs only after accepted summary metadata. Audio and summary
attachments remain outside this scalar boundary. The standalone suite passes
122/122 and the macOS app build-for-testing check passes. Generic iOS
build-for-testing still stops before app/test compilation on the pre-existing
`withSecurityScope` iOS availability error. This remains Core Data-authoritative
with no live CloudKit or user-store validation.

Every attribute maps unchanged by name into its proposed table; preserve nulls and raw values. Relationships map through the source row map independently of scalar UUID references. No unlisted field may be silently ignored.

## BisonNotes_AI.xcdatamodel

XML SHA-256: `0e0abc4753abb99355be755670f80f51968cb47ca83253ef3bf691809e46c0ed`.

### RecordingEntry → `recordings`

| Source attribute / destination column | Source type | Optional | Model default |
| --- | --- | --- | --- |
| `audioQuality` | String | YES | — |
| `createdAt` | Date | YES | — |
| `duration` | Double | YES | 0.0 |
| `fileSize` | Integer 64 | YES | 0 |
| `id` | UUID | YES | — |
| `isCloudSyncDisabled` | Boolean | YES | NO |
| `lastModified` | Date | YES | — |
| `locationAccuracy` | Double | YES | — |
| `locationAddress` | String | YES | — |
| `locationLatitude` | Double | YES | — |
| `locationLongitude` | Double | YES | — |
| `locationTimestamp` | Date | YES | — |
| `recordingDate` | Date | YES | — |
| `recordingName` | String | YES | — |
| `recordingURL` | String | YES | — |
| `summaryId` | UUID | YES | — |
| `summaryStatus` | String | YES | — |
| `transcriptId` | UUID | YES | — |
| `transcriptionStatus` | String | YES | — |
| `isArchived` | Boolean | YES | NO |
| `archivedAt` | Date | YES | — |
| `archiveNote` | String | YES | — |

| Relationship | Destination | Cardinality | Deletion rule | Inverse |
| --- | --- | --- | --- | --- |
| `summary` | SummaryEntry | 0..1 | Cascade | recording |
| `transcript` | TranscriptEntry | 0..1 | Cascade | recording |
| `processingJobs` | ProcessingJobEntry | many | Cascade | recording |

### SummaryEntry → `summaries`

| Source attribute / destination column | Source type | Optional | Model default |
| --- | --- | --- | --- |
| `aiMethod` | String | YES | — |
| `compressionRatio` | Double | YES | 0.0 |
| `confidence` | Double | YES | 0.0 |
| `contentType` | String | YES | — |
| `generatedAt` | Date | YES | — |
| `id` | UUID | YES | — |
| `originalLength` | Integer 32 | YES | 0 |
| `processingTime` | Double | YES | 0.0 |
| `recordingId` | UUID | YES | — |
| `reminders` | String | YES | — |
| `summary` | String | YES | — |
| `tasks` | String | YES | — |
| `titles` | String | YES | — |
| `transcriptId` | UUID | YES | — |
| `version` | Integer 32 | YES | 1 |
| `wordCount` | Integer 32 | YES | 0 |

| Relationship | Destination | Cardinality | Deletion rule | Inverse |
| --- | --- | --- | --- | --- |
| `recording` | RecordingEntry | 0..1 | Nullify | summary |
| `transcript` | TranscriptEntry | 0..1 | Nullify | summaries |

### TranscriptEntry → `transcripts`

| Source attribute / destination column | Source type | Optional | Model default |
| --- | --- | --- | --- |
| `confidence` | Double | YES | 0.0 |
| `createdAt` | Date | YES | — |
| `engine` | String | YES | — |
| `id` | UUID | YES | — |
| `lastModified` | Date | YES | — |
| `processingTime` | Double | YES | 0.0 |
| `recordingId` | UUID | YES | — |
| `segments` | String | YES | — |
| `speakerMappings` | String | YES | — |

| Relationship | Destination | Cardinality | Deletion rule | Inverse |
| --- | --- | --- | --- | --- |
| `recording` | RecordingEntry | 0..1 | Nullify | transcript |
| `summaries` | SummaryEntry | many | Nullify | transcript |

### ProcessingJobEntry → `processing_jobs`

| Source attribute / destination column | Source type | Optional | Model default |
| --- | --- | --- | --- |
| `completionTime` | Date | YES | — |
| `engine` | String | YES | — |
| `error` | String | YES | — |
| `id` | UUID | YES | — |
| `jobType` | String | YES | — |
| `lastModified` | Date | YES | — |
| `modelName` | String | YES | — |
| `progress` | Double | YES | 0.0 |
| `recordingName` | String | YES | — |
| `recordingURL` | String | YES | — |
| `startTime` | Date | YES | — |
| `status` | String | YES | — |

| Relationship | Destination | Cardinality | Deletion rule | Inverse |
| --- | --- | --- | --- | --- |
| `recording` | RecordingEntry | 0..1 | Nullify | processingJobs |

### RecordingArchiveLocationEntry → `archive_locations`

| Source attribute / destination column | Source type | Optional | Model default |
| --- | --- | --- | --- |
| `bookmarkData` | Binary | YES | — |
| `destinationURLString` | String | YES | — |
| `displayName` | String | YES | — |
| `exportedAt` | Date | YES | — |
| `exportedFilename` | String | YES | — |
| `fileSize` | Integer 64 | YES | 0 |
| `id` | UUID | YES | — |
| `lastVerifiedAt` | Date | YES | — |
| `providerDisplayName` | String | YES | — |
| `recordingId` | UUID | YES | — |
| `status` | String | YES | — |

## BisonNotes_AI_v2.xcdatamodel

XML SHA-256: `3dd84b9b7f833f47868de4f2b77a174620e85b0cf6f9703d1b9cddf8e2f726fa`.

### RecordingEntry → `recordings`

| Source attribute / destination column | Source type | Optional | Model default |
| --- | --- | --- | --- |
| `audioQuality` | String | YES | — |
| `createdAt` | Date | YES | — |
| `duration` | Double | YES | 0.0 |
| `fileSize` | Integer 64 | YES | 0 |
| `id` | UUID | YES | — |
| `isCloudSyncDisabled` | Boolean | YES | NO |
| `lastModified` | Date | YES | — |
| `locationAccuracy` | Double | YES | — |
| `locationAddress` | String | YES | — |
| `locationLatitude` | Double | YES | — |
| `locationLongitude` | Double | YES | — |
| `locationTimestamp` | Date | YES | — |
| `recordingDate` | Date | YES | — |
| `recordingName` | String | YES | — |
| `recordingURL` | String | YES | — |
| `summaryId` | UUID | YES | — |
| `summaryStatus` | String | YES | — |
| `transcriptId` | UUID | YES | — |
| `transcriptionStatus` | String | YES | — |
| `isArchived` | Boolean | YES | NO |
| `archivedAt` | Date | YES | — |
| `archiveNote` | String | YES | — |

| Relationship | Destination | Cardinality | Deletion rule | Inverse |
| --- | --- | --- | --- | --- |
| `summary` | SummaryEntry | 0..1 | Cascade | recording |
| `transcript` | TranscriptEntry | 0..1 | Cascade | recording |
| `processingJobs` | ProcessingJobEntry | many | Cascade | recording |

### SummaryEntry → `summaries`

| Source attribute / destination column | Source type | Optional | Model default |
| --- | --- | --- | --- |
| `aiMethod` | String | YES | — |
| `compressionRatio` | Double | YES | 0.0 |
| `confidence` | Double | YES | 0.0 |
| `contentType` | String | YES | — |
| `generatedAt` | Date | YES | — |
| `id` | UUID | YES | — |
| `originalLength` | Integer 32 | YES | 0 |
| `processingTime` | Double | YES | 0.0 |
| `recordingId` | UUID | YES | — |
| `reminders` | String | YES | — |
| `summary` | String | YES | — |
| `tasks` | String | YES | — |
| `titles` | String | YES | — |
| `transcriptId` | UUID | YES | — |
| `version` | Integer 32 | YES | 1 |
| `wordCount` | Integer 32 | YES | 0 |

| Relationship | Destination | Cardinality | Deletion rule | Inverse |
| --- | --- | --- | --- | --- |
| `recording` | RecordingEntry | 0..1 | Nullify | summary |
| `transcript` | TranscriptEntry | 0..1 | Nullify | summaries |

### TranscriptEntry → `transcripts`

| Source attribute / destination column | Source type | Optional | Model default |
| --- | --- | --- | --- |
| `confidence` | Double | YES | 0.0 |
| `createdAt` | Date | YES | — |
| `engine` | String | YES | — |
| `id` | UUID | YES | — |
| `lastModified` | Date | YES | — |
| `processingTime` | Double | YES | 0.0 |
| `recordingId` | UUID | YES | — |
| `segments` | String | YES | — |
| `speakerMappings` | String | YES | — |

| Relationship | Destination | Cardinality | Deletion rule | Inverse |
| --- | --- | --- | --- | --- |
| `recording` | RecordingEntry | 0..1 | Nullify | transcript |
| `summaries` | SummaryEntry | many | Nullify | transcript |

### ProcessingJobEntry → `processing_jobs`

| Source attribute / destination column | Source type | Optional | Model default |
| --- | --- | --- | --- |
| `completionTime` | Date | YES | — |
| `engine` | String | YES | — |
| `error` | String | YES | — |
| `id` | UUID | YES | — |
| `jobType` | String | YES | — |
| `lastModified` | Date | YES | — |
| `modelName` | String | YES | — |
| `progress` | Double | YES | 0.0 |
| `recordingName` | String | YES | — |
| `recordingURL` | String | YES | — |
| `startTime` | Date | YES | — |
| `status` | String | YES | — |

| Relationship | Destination | Cardinality | Deletion rule | Inverse |
| --- | --- | --- | --- | --- |
| `recording` | RecordingEntry | 0..1 | Nullify | processingJobs |

### RecordingArchiveLocationEntry → `archive_locations`

| Source attribute / destination column | Source type | Optional | Model default |
| --- | --- | --- | --- |
| `bookmarkData` | Binary | YES | — |
| `destinationURLString` | String | YES | — |
| `displayName` | String | YES | — |
| `exportedAt` | Date | YES | — |
| `exportedFilename` | String | YES | — |
| `fileSize` | Integer 64 | YES | 0 |
| `id` | UUID | YES | — |
| `lastVerifiedAt` | Date | YES | — |
| `providerDisplayName` | String | YES | — |
| `recordingId` | UUID | YES | — |
| `status` | String | YES | — |

### PendingCloudMutation → `pending_cloud_mutations`

| Source attribute / destination column | Source type | Optional | Model default |
| --- | --- | --- | --- |
| `kind` | String | NO | recordingDeletion |
| `payload` | Binary | YES | — |
| `recordingId` | UUID | YES | — |
| `requestedAt` | Date | YES | — |
| `targetId` | UUID | NO | 00000000-0000-0000-0000-000000000000 |
| `version` | Integer 32 | NO | 1 |

## Direct Swift persistence touchpoints

Search matches below require adapter migration or an explicit retained legacy/test-only justification. They are not all equally coupled; callers using coordinator methods without these symbols require a second pass.

- `BisonNotes AI/BisonNotes AI/BackgroundProcessingManager.swift`
- `BisonNotes AI/BisonNotes AI/BisonNotesAIApp.swift`
- `BisonNotes AI/BisonNotes AI/ContentView.swift`
- `BisonNotes AI/BisonNotes AI/FileImportManager.swift`
- `BisonNotes AI/BisonNotes AI/Models/AdvancedTroubleshootingService.swift`
- `BisonNotes AI/BisonNotes AI/Models/AppDataCoordinator.swift`
- `BisonNotes AI/BisonNotes AI/Models/CoreDataManager.swift`
- `BisonNotes AI/BisonNotes AI/Models/DataMigrationManager.swift`
- `BisonNotes AI/BisonNotes AI/Models/RecordingArchiveService.swift`
- `BisonNotes AI/BisonNotes AI/Models/RecordingWorkflowManager.swift`
- `BisonNotes AI/BisonNotes AI/Models/SummaryAttachmentStore.swift`
- `BisonNotes AI/BisonNotes AI/Models/SummaryPresencePolicy.swift`
- `BisonNotes AI/BisonNotes AI/Models/TranscriptManager.swift`
- `BisonNotes AI/BisonNotes AI/Models/TranscriptionStarter.swift`
- `BisonNotes AI/BisonNotes AI/Persistence.swift`
- `BisonNotes AI/BisonNotes AI/SummariesView.swift`
- `BisonNotes AI/BisonNotes AI/SummaryManager.swift`
- `BisonNotes AI/BisonNotes AI/TranscriptImportManager.swift`
- `BisonNotes AI/BisonNotes AI/UITestSupport.swift`
- `BisonNotes AI/BisonNotes AI/Views/AudioPlayerView.swift`
- `BisonNotes AI/BisonNotes AI/Views/RecordingsListView.swift`
- `BisonNotes AI/BisonNotes AI/Views/TranscriptViews.swift`
- `BisonNotes AI/BisonNotes AI/iCloudStorageManager.swift`
- `BisonNotes AI/BisonNotes AITests/AdvancedTroubleshootingServiceTests.swift`
- `BisonNotes AI/BisonNotes AITests/AudioTranscriptionRegressionTests.swift`
- `BisonNotes AI/BisonNotes AITests/BisonNotesAIIntegrationTests.swift`
- `BisonNotes AI/BisonNotes AITests/ICloudBackupRegressionTests.swift`
- `BisonNotes AI/BisonNotes AITests/ICloudSyncOrchestrationTests.swift`
- `BisonNotes AI/BisonNotes AITests/LocalDiarizationPersistenceTests.swift`
- `BisonNotes AI/BisonNotes AITests/Swift6PersistenceIsolationTests.swift`
- `BisonNotes AI/BisonNotes AITests/WebImportManagerTests.swift`

## Payloads stored inside attributes

The XML inventory cannot enumerate Codable keys nested in `segments`, `speakerMappings`, `tasks`, `reminders`, `titles`, or mutation `payload`. Preserve their original text/bytes and unknown keys. In particular, v2.5 transcript cleanup adds optional derived text within segment payloads: retain original AND cleaned forms, provenance and mappings. Include old-client rewrite behavior in mixed-version tests. Read `TranscriptSegment`, cleanup payload types, `SummarySupplementalData`, Watch messages and archive models before implementing conversion.

## Known non-database roots and state

- `SummaryAttachments/<summary UUID>/metadata.json` and `files/` under Documents: notes, attachment records and bytes.
- Documents audio, imported placeholders, legacy `.transcript`/summary files and `.location` sidecars; resolve actual roots from source/runtime.
- Recording Recovery under Application Support; share App Group inbox/tokens; phone Watch staging/receipts; Watch JSON/audio storage.
- `SavedEnhancedSummaries` and `SavedEnhancedSummariesMigrationVersion`: legacy summary payload and migration status.
- Five legacy queues: `iCloudPendingDeletionMarkersV1`, `iCloudPendingLocalOnlyRemovalsV1`, `iCloudPendingSummaryRemovalsV1`, `iCloudPendingTranscriptRemovalsV1`, `iCloudPendingImportedAudioRemovalsV1`.
- Active/quarantine state: `iCloudActiveManifestMigrationCompletedV2`, `iCloudQuarantinedBackupRecordNamesV2`, `iCloudQuarantinedLegacySummaryRecordNamesV2`; preserve account context.
- `iCloudBackupStateSignatureV1`, sync throttles/backoff and settings: classify authoritative versus derived state before migration.
- Keychain, security-scoped bookmarks, external archives and cloud-only assets require the separate policies in the plan.

Add a fixture/assertion column to this inventory during implementation; schema coverage tests must fail when a new source field has no declared disposition.

## Phase 0 runtime-boundary additions

The schema inventory above is not a complete file/defaults inventory. Phase 0
source review identified these additional roots and entry points that require an
explicit owner, format, platform-backup disposition and fixture before migration.
The app will not create a portable export/restore package or manage encryption
keys; Apple device backups and existing iCloud/CloudKit behavior remain the
platform/product mechanisms in scope:

| Category | Evidence to ledger |
| --- | --- |
| Recording sidecars and recovery | `.location`, `.recordingmeta`, segment/merge files, and `deferred-recovery.json` in the `AudioRecorderViewModel` persistence extensions |
| Legacy relationship state | `Documents/file_relationships.json` in `EnhancedFileManager`; top-level `.transcript`, `.summary`, `.location` and audio files in `DataMigrationManager` |
| Recovery/archive staging | `Application Support/Recording Recovery`, `ArchiveStaging` and `AudioExportStaging` |
| Watch source and receipts | Watch `Documents/WatchRecordings/metadata.json`, `recordings/*.m4a`, and `Documents/reliable_transfers.json`; phone `Application Support/WatchTransferStaging` is the persistent pre-cutover source root, with journaled cleanup after metadata acknowledgement |
| Share imports | App Group `group.bisonnotesai.shared/ShareInbox`, `.share-import-token`, and the `Documents/Inbox` fallback |
| Additional defaults | App Group action-button key `actionButtonShouldStartRecording`; `.standard` dedupe key `processedWatchRecordingIds`; sync timestamps, absence markers, throttles and backup flags |
| Temporary roots and caches | `tmp/iCloudAudioStaging`, `tmp/BisonNotesWebImports`, macOS scratch/export paths, FluidAudio models, map snapshots and model caches |
| Omitted direct I/O callers | `EnhancedFileManager`, `ActionButtonLaunchManager`, `ShareExtensionProcessor`, Watch storage/connectivity, `CloudAudioAssetStaging`, `TemporaryFileCleanupService`, `WebImportDownloader`, `RestoredAudioFileInstaller`, and `AudioRecorderViewModel` persistence extensions |

See [the evidence ledger](sqlite-migration-evidence.md) for initial treatment
and test dispositions. These additions are not permission to delete, rename or
exclude any root; unknown files remain in recovery until classified. Metadata
references migrate in the blocking first-boot phase, while audio and other large
media are reconciled by a bounded background worker with durable receipts and no
full-library duplicate.

## Handoff status — 2026-09-12

This inventory describes the source boundary and the intended first SQLite
schema; it is not evidence that user data has migrated. Core Data remains
authoritative. The isolated `SQLiteLibraryStore` foundation now runs schema v8;
its initial v1 schema mirrored all six
model entities and adds the operational tables, seeded library/generation
metadata, independent storage IDs, restrictive resolved-link foreign keys,
root-relative asset-operation paths, integrity diagnostics and typed durable
migration-run checkpoints. A read-only verifier now validates closed snapshots
against those six tables by schema, migration-run fingerprint, row identity and
declared value. An app-hosted fixture factory now loads the compiled original
and active v2 Core Data models into disposable SQLite-backed stores, populates
representative rows, projects every destination column and relationship, and
fingerprints the projection. Its XCTest coverage is compile-checked by the
app-hosted build-for-testing gate but has not executed because the current
simulator runner exits before XCTest bootstrapping; it covers only the checked-in
models, not every shipped historical hash. The
isolated metadata importer now writes those rows and row-map entries in
dependency order with transactional batch checkpoints and idempotent reopen/
resume behavior; it is not wired to app startup, the production repository,
CloudKit, or any user database. The read-only Core Data source reader is now
implemented and tested against disposable six-entity models; the isolated
Core Data migration input reader now composes that metadata snapshot with an
explicitly inventoried, typed blocking-settings snapshot and rejects
unclassified source keys before capture. `LibraryMaintenanceGate` now provides
cancellation-safe normal/exclusive access, and the disposable
`SQLiteMigrationSourceCoordinator` holds exclusive access across observation
anchoring, source capture, revision validation and the resumable coordinator.
The isolated
resumable metadata coordinator now handles exact-run lookup, committed batch
progress, a durable paused status for cancellation, definitive failure
checkpoints and closed-snapshot verification. Its blocking settings phase applies
the validated allowlist before final verification and is resumable after reopen.
Production source/settings acquisition and coordinator wiring beyond the
disposable source-backed harness, adoption of the gate by every Core Data,
settings, Watch, share and background caller, the migration screen, historical
release fixtures,
final production media-root selection and signed-device scheduling validation
still need implementation against disposable fixtures. The Watch
caller and the Share/Inbox audio-import caller now exercise the generic
transfer boundary in the pre-cutover Core Data-authoritative path. Share/Inbox
audio uses stable source-derived journal identities, a bounded metadata
descriptor, Documents publication, idempotent Core Data metadata commit,
receipt-gated source removal and activation retry; failed or unsupported inbox
sources remain available. URLs outside the two managed inbox roots, video and
text imports, archive-token restores and other direct file-owning paths remain
on their existing paths. The isolated
media worker, candidate application-root mapping, checksum-bound planner,
restartable background reconciler and guarded retention executor now exist as
background-safe foundations, but they are not app callers or a migration gate.
The first repository slice now
defines storage-neutral snapshots for all six migrated metadata entities and the
`LibraryRepository` contract, with Core Data and SQLite adapters over copied
values. It also defines typed allowlisted settings values, a UserDefaults
source adapter, the SQLite schema-v2 settings table/adapter, a recording-rename
command with explicit revision and error behavior, an atomic cloud-sync
  preference command that carries the local-only outbox marker, and a
  transcript-upsert command that preserves transcript identity and updates its
  recording link/status atomically. Contract
coverage imports the synthetic snapshot into SQLite, reads the active Core Data
fixture, round-trips typed settings, checks stale rename rejection and verifies
that disabling/re-enabling cloud sync commits/removes the marker with the
recording update. The
display-name-only `AudioPlayerView`, `SummaryDetailView`,
`EditableTranscriptView` and summary-regeneration callers use the Core Data
adapter. `BackgroundProcessingManager` routes synchronous job creation plus asynchronous
status transitions, stale-job reconciliation, rerun/duplicate cleanup, manual
terminal cleanup and clear-all enumeration/deletion through processing-job
repository commands. Creation carries a stable optional recording reference,
rejects duplicate UUIDs and preserves the initial job state; SQLite
canonicalizes UUID legacy references so Core Data-style `UUID.uuidString` callers
resolve migrated rows. The batch terminal cleanup helper now uses the same
repository boundary with case-insensitive status matching and durable per-row
delete changes. The obsolete direct Core Data cleanup helper was removed in
`17abdac3` after its call sites were eliminated. Startup crash reconciliation
now marks pre-crash jobs failed in memory before automatic work can start, then
persists the known nonterminal set through a retry-safe repository command that
skips missing or already-terminal rows. The AI file-renaming workflow remains
separate until its surrounding file operations have a journaled repository
command. Production transcription persistence now uses the async transcript
  repository command across background, direct, live, editor, cleanup and rerun
  paths; the synchronous helper remains only for UI-test seeding and legacy
  compatibility. Neither backend is wired to startup or user-data migration.
Production background summarization and both summary-regeneration paths now use
the async summary repository command. The summary upsert preserves the existing
summary identity on replacement, creates a stable identity for a new row and
commits the summary/recording link and status together; supplemental notes and
attachments remain outside that transaction and are not deleted or migrated by
this command. The app-hosted macOS/iOS builds and the 87-test host suite pass at
that summary checkpoint.
The archive-state checkpoint `37d55b77` adds
`LibraryRecordingArchiveCommand` and a coordinator helper for committing
`isArchived`, `archivedAt`, `archiveNote` and `lastModified` through Core Data
or SQLite with an optional expected-revision guard. SQLite records the
recording change in the same transaction. This command commits metadata only:
`RecordingArchiveService`'s iCloud Drive copy, security-scoped bookmarks,
destination verification and local-source removal remain outside the
transaction until their receipt/order boundary is implemented. The app-hosted
macOS/iOS builds and the full 88-test host suite pass; neither adapter is wired
to startup or a user-data migration.
The archive-location checkpoint `4e35a7d9` adds
`LibraryArchiveLocationUpsertCommand` for already-verified external archive
metadata. Core Data and SQLite preserve a stable row ID on retry, reuse a
same-recording/same-destination legacy row and reject ambiguous or
cross-recording collisions; SQLite records the archive-location change in the
same transaction. The command does not copy files, acquire bookmarks, restore
audio or remove sources, and `RecordingArchiveService` has no production
caller through this boundary yet. The app-hosted macOS/iOS builds and the full
89-test host suite pass.
The repository-gate checkpoint `431ff801` makes `PersistenceController` the
owner of one shared `LibraryMaintenanceGate` for each persistence generation.
The production Core Data repository construction paths and the SQLite
`LibraryRepository` adapter now wait behind an exclusive source-capture lease
for repository-backed reads and commands. SQLite observation polling remains
ungated so the source coordinator can validate a revision while holding that
lease. The standalone runtime suite passes 91/91 and the app-hosted macOS/iOS
build-for-testing checks pass. Direct managed-object saves in legacy recording,
import, archive, settings, Watch/share and sync services remain open for
separate conversion or an explicit exclusion; no backend is wired to startup.

The recording-creation checkpoint `b57e871f` adds
`LibraryRecordingCreateCommand` with finite-value, range and identity
validation. Core Data and SQLite commit the complete metadata row atomically,
reject duplicate identities and preserve the legacy UUID; SQLite also assigns
the stable `sqlite-recording-<lowercase-UUID>` storage ID and records one
durable `recording`/`inserted` observation change. The async
`AppDataCoordinator` bridge is used by
`BackgroundProcessingManager.ensureRecordingExists` after that workflow has
already taken ownership of the audio file. Audio copying, naming and source
retention remain outside this metadata transaction. One focused SQLite runtime
test passes; the Core Data contract test is compile-checked by the app-hosted
build-for-testing target, while direct simulator execution remains unavailable
in the current runner.

The transcript-import checkpoint `8bbbe283` routes the normal
`TranscriptImportManager` path through the repository: duplicate-name checks
use repository snapshots, dummy-audio metadata uses the recording-create
command, and encoded imported segments use the transcript-upsert command.
Dummy-audio creation, ownership and failure cleanup remain with the importer.
The later `3fe7d86d` checkpoint replaces the rollback delete with the
import-only `LibraryRecordingDiscardCommand`: both adapters refuse dependent
metadata/outbox rows, and SQLite records a clean discard in its durable change
log without creating a CloudKit tombstone. The full-recording-deletion
checkpoint `38ab4fbd` adds `LibraryRecordingDeleteCommand` to both adapters,
deletes the recording-owned metadata graph in one transaction, coalesces
recording/summary CloudKit removal intents, withdraws stale imported-audio
markers and performs Core Data summary-attachment cleanup after commit.
Whole-recording callers now use the async coordinator bridge; preserve-summary
deletion remains a separate lifecycle boundary from whole-recording deletion.
The inbound-recording-tombstone checkpoint `4d97e80e` routes whole-recording
markers through the same storage-neutral deletion transaction with cloud enqueue
disabled and idempotent missing-row handling. The inbound-transcript-tombstone
checkpoint `bddddd0c` adds `LibraryTranscriptDeleteCommand` to both adapters:
it deletes only the transcript row, clears recording and summary transcript
links, resets the recording transcription status, retains the recording and
summary rows, and queues an outbound transcript-removal intent only for local
deletes. Inbound application disables cloud enqueueing and treats a missing row
as an idempotent replay; audio bytes and sidecars are outside the command. The
preserve-summary checkpoint `3d859318`
adds `LibraryRecordingPreserveSummaryDeleteCommand` to both adapters: it keeps
the recording/summary anchor, clears audio/transcript links, removes local
transcript rows, carries stale transcript identities and coalesces durable
transcript/audio removal intents in one transaction. `EnhancedFileManager` and
imported-transcript cleanup use the async coordinator bridge; file bytes and
sidecars remain owned by the file manager. SQLite also resolves summary
storage-linked transcripts when a recording back-reference is absent. The
macOS/iOS app-hosted build-for-testing checks and the 97-test standalone suite
pass; no backend is wired to startup. Remaining imported-audio marker/file
removal and archive/file ownership remain separate lifecycle work.

The inbound-summary-tombstone checkpoint `e14d4120` adds
`LibrarySummaryDeleteCommand` to both adapters. Local deletion clears only the
summary metadata, parent recording link/status and matching local outbox intent
in one transaction; inbound application disables cloud enqueueing and treats a
missing row as an idempotent replay. The recording and transcript remain
available, while summary notes and attachment files are removed only after the
coordinator observes a successful repository commit. The app-hosted
orchestration regression and Core Data contract are compile-checked by
`build-for-testing`; the standalone suite passes 99/99 and both macOS/iOS
app-hosted build-for-testing checks pass. No repository backend is wired to
startup. Inbound imported-audio marker/file ownership is covered by the
following checkpoint; archive/file ownership and startup cutover remain open.

The inbound-imported-audio checkpoint `13340bc9` adds
`LibraryImportedAudioRemovalCommand` to both adapters. The command clears only
the recording's audio link, preserves the recording/transcript/summary
metadata, coalesces the optional local CloudKit-removal intent and records the
SQLite recording update in the same transaction. Inbound CloudKit application
uses the coordinator with cloud enqueueing disabled. `LibraryImportedAudioFileStore`
owns storage-neutral path resolution and idempotent removal of the main file
and known sidecars; the coordinator removes the file before unlinking its
metadata URL so a process kill leaves the URL and inbound marker available for
retry, while a missing file is safe to replay. The focused Core Data/SQLite
contracts, CloudKit regression path and standalone file-cleanup test are
included in the 101/101 standalone suite; macOS/iOS app-hosted
build-for-testing checks pass, while direct simulator XCTest execution remains
unavailable because the current runner exits before XCTest bootstrapping. The
recording-file cleanup checkpoint `fde51735` now uses the same idempotent file
store before the metadata unlink, so a process kill leaves the URL retryable;
the final production media/file journal remains separate. No repository backend
is wired to startup.

The archive-export caller checkpoint `a47eada6` routes production archive
completion through the repository. `RecordingArchiveService` creates
storage-neutral archive-location commands after destination/bookmark
validation, upserts them through `AppDataCoordinator`, then commits archive
state. Local audio and known sidecars are removed only after those metadata
commits, and cleanup failure leaves the committed archive state and source URL
retryable. `RecordingsListView` awaits the operation and keeps selection on
failure. The recording-file cleanup checkpoint `fde51735` makes
`EnhancedFileManager` use the same idempotent file store for full and
preserve-summary deletion, keeping the metadata URL as a retry handle until
the repository transaction commits. The archive re-import checkpoint
`880b2c03` adds `LibraryRecordingAudioRestoreCommand`, which atomically commits
the restored URL, optional file size, archive-flag clearing and revision update
through both adapters. Imported archive restores and clear-flag reimports now
await the repository path.

The archive read/restore checkpoint `f83cfbff` moves the recordings-list
archive-location cache and file-provider location selection to repository
snapshots. File-provider restore now verifies or reuses the local copy, commits
the recording relink and archive-flag clearing through the repository before
attempting external-source deletion, and records stale/missing location status
through the same metadata boundary. A process kill after the metadata commit
therefore cannot lose the restored local audio; the external source remains
available for a later cleanup pass. The provider copy/source-delete operations
are still direct file work without a durable archive-operation journal. The
standalone suite passes 102/102 and the macOS app-hosted build-for-testing check
passes; the current full iOS scheme build is blocked by the pre-existing
watch-widget `accessoryCorner` availability error, and direct simulator XCTest
execution remains unavailable. No repository backend is wired to startup.

The durable media-operation checkpoint `44515c52` adds transactional asset and
file-operation enqueueing, root-relative path validation, streaming checksum/
length verification, atomic partial-file publication, non-overwriting conflict
handling and recovery of interrupted `running` rows. Five disposable host tests
cover those paths, including a destination published before its database
checkpoint and source removal after publication. Final production root selection,
scheduling, progress UI and startup wiring remain open.
The durable import-receipt checkpoint `b8b80783` adds typed, durable outcomes
for source transfer IDs, optional destination storage IDs and idempotent
retries. Reopened stores return the original receipt; conflicting retries and
receipt-ID collisions fail closed. Three disposable host tests cover those
cases. The API is not yet connected to Watch/share callers or
source-retention cleanup.
The media-transfer checkpoint `c8b70087` adds a validated logical-root
registry, joins verified destination publication to a committed import receipt,
and reports source-removal eligibility without deleting files. Four disposable
host tests cover successful retry, checksum failure, receipt conflict and root
validation. The follow-on application-root/retention checkpoint below adds
candidate path classification and guarded cleanup without production caller
wiring.

The application-root/retention checkpoint `88c393e9` adds
`SQLiteApplicationMediaRootMapping` for Documents, Documents/Inbox, Watch
transfer staging, iCloud audio staging, optional ShareInbox and an isolated
Application Support/SQLiteMedia destination candidate. It does not create
directories or scan user data. `SQLiteMediaSourceRetentionExecutor` requires a
completed operation with a matching committed receipt, re-verifies the
destination length and SHA-256 immediately before removal, rejects aliases and
invalid or changed destinations, and treats an absent source as idempotent.
Five disposable host tests cover that mapping and retention behavior. Final
production root selection, Watch/share/background caller integration and
retention scheduling remain open.
The restartable-media checkpoint `fe99e3ff` adds the schema-v4 source transfer
identity to the asset journal, a most-specific-root transfer planner and a
serialized bounded background reconciler. It can recover queued operations and
finish a committed receipt after verified publication interrupted before the
acknowledgement; it verifies an already-completed destination before recording
that receipt. It never removes source files automatically, and it is not wired
to production callers. Four additional host tests cover source identity across
reopen, queued background copying with progress, receipt completion after
reopen and changed-destination refusal.
The provider archive-restore checkpoint `2ba09adf` adds schema v5
`archive_restore_operations` with separate copy, metadata acknowledgement and
source-deletion phases, generic retry errors and recovery of each in-flight
phase after reopen. `SQLiteArchiveRestoreReconciler` bounds work, performs large
file operations in detached utility tasks, verifies a previously published
destination before retrying metadata, and never attempts source deletion before
the metadata callback succeeds. `SQLiteApplicationArchiveRestorePlanner`
converts a currently resolved bookmark URL plus its logical root into a
checksum-bound plan without persisting an absolute provider path;
`SQLiteApplicationMediaRootMapping` creates the matching process-local registry
only while that security-scoped access is held. The existing Core Data archive
restore caller now performs provider copy/validation and source deletion off
the main actor but is not yet journal-backed. Four archive-reconciler host tests
and three archive-planner tests cover the new behavior. No production SQLite
store, root selection, bookmark retry scheduler or cutover is enabled.

The generic media metadata-acknowledgement checkpoints `ef52505d` and
`04e962b2` upgrade the
file-operation journal to schema v7 with `metadataState` and
`metadataAcknowledgedAt`. A new generic transfer remains copy-complete but
metadata-pending until an idempotent caller callback commits the recording
metadata; only then is its unique source-transfer receipt recorded and source
retention eligible. Failed or interrupted callbacks are retryable after reopen,
and a durable metadata acknowledgement lets a later pass record the missing
receipt without invoking the callback again. Existing v6 completed operations
are labeled `legacy` without a fabricated acknowledgement timestamp. The
focused media suite covers callback ordering, failure/retry, metadata-claim
recovery, lost receipt recovery and retention refusal before acknowledgement;
the full standalone suite passes 129/129 and the macOS app-hosted
build-for-testing check passes. This is the generic v7 acknowledgement layer;
the v8 descriptor extension and the production Watch caller are recorded
below. No live user store or CloudKit account was used.

The production Watch media-intake checkpoint `d80fa3bc` adds a capped,
caller-owned metadata descriptor to the generic file-operation journal and
connects `AudioRecorderViewModel` to a persistent
`Application Support/WatchTransferStaging` source root. A Watch delivery is
given stable recording-derived transfer/operation/asset identities, copied
and verified into the pre-cutover Documents root, acknowledged through an
idempotent Core Data recording-create bridge, and retained at the source until
the committed receipt and verified cleanup are both complete. Startup/handler
setup and app activation run bounded retry passes; failed steps leave the
staged source available. Share/Inbox cleanup now removes only importer-reported
successful sources and retains failed or unsupported inputs, but generic Share
media has not yet adopted the journal. The v8 migration, metadata-payload
conflict/size tests, restart cleanup test and Watch integration compile in the
macOS target; the full standalone suite passes 132/132. The iOS scheme still
stops before app/test compilation at the pre-existing Watch Widget
`accessoryCorner` availability error; no signed-device or live-data validation
was performed.

The production Share/Inbox audio-import checkpoint `f78b7496` connects
`FileImportManager` and the app's App Group/`Documents/Inbox` scans to the same
schema-v8 generic media boundary. Only audio inside those two managed roots is
journaled; it uses stable source-derived transfer identities, a bounded
metadata descriptor, the existing Documents destination, idempotent Core Data
metadata creation, receipt-gated source removal and bounded activation retry.
Failed or unsupported sources remain available. Direct document-picker/web
imports outside those roots, video extraction, archive-token restores and text
imports remain on their existing paths. The macOS app-hosted build-for-testing
check passes for the caller change; the standalone suite remains 132/132, and
the iOS scheme remains blocked before app/test compilation by the pre-existing
Watch Widget `accessoryCorner` availability error. No signed-device or live-data
validation was performed.

The OS-managed media retry checkpoint `9557c09f` connects the Watch and
Share/Inbox journal enqueue/retry events to the permitted iOS
`BGProcessingTask` identifier `com.bisonai.media-reconciliation`. Each pass is
bounded to eight operations and receipt-gated source removals, cancels its
work on task expiration and schedules a follow-up when work remains; native
macOS retains activation retry because it has no `BGTaskScheduler`. This is a
production scheduling foundation, not signed-device evidence: delivery,
expiration timing, power behavior, retry metrics and final media-root selection
remain to be qualified. The full standalone suite passes 132/132 and the macOS
app-hosted build-for-testing check passes; the iOS scheme remains blocked by
the pre-existing Watch Widget `accessoryCorner` availability error. No
signed-device or live-data validation was performed.

The CloudKit summary-restore checkpoint `8d63a010` routes linked summary
application through `AppDataCoordinator` and `LibrarySummaryUpsertCommand`,
using an explicit incoming-identity policy for cloud-authoritative UUIDs. If
the incoming UUID replaces a local summary UUID, the coordinator preserves
notes and attachments with a post-commit supplemental-directory move. When no
local recording exists, `LibrarySummaryAnchorUpsertCommand` creates or retries
the summary and a zero-audio recording anchor atomically through Core Data or
SQLite. Missing transcripts remain represented by their raw UUID until a later
transcript restore can resolve the link. The legacy synchronous
`CoreDataManager` orphan helper remains only for compatibility/test callers;
production CloudKit restore no longer calls it. The standalone suite passes
118/118 and the macOS app-hosted build-for-testing check passes; no SQLite
backend is wired to startup and no live user store or account was used.

The CloudKit recording-restore checkpoint `91406ea2` routes the recording leg
of `iCloudStorageManager.performRestore` through
`LibraryRecordingCloudRestoreCommand` and
`LibraryRecordingAudioLinkCommand`. The metadata command applies cloud scalar
fields with an optimistic `lastModified` guard, creates cloud-only rows without
audio, and preserves an existing local audio URL, archive state and cloud-sync
flag. The audio command runs only after a staged asset copy succeeds and
changes only the local URL (and optional size), leaving the cloud-content
timestamp and archive state unchanged; the imported-audio clear path uses the
same boundary. SQLite records durable recording observations for both commands.
Transcript and summary scalar writes now have separate guarded repository
boundaries; child relationship repair remains explicit in the restore method.
The standalone suite passes 120/120 and the macOS app build-for-testing check
passes; generic iOS build-for-testing is still blocked before app/test
compilation by the pre-existing `withSecurityScope` iOS availability error. No
SQLite backend is wired to startup and no live user store or account was used.

The SQLite-only `LibraryObservation` implementation persists a global
`library_changes` cursor and emits recording-rename/archive-state/cloud-sync/
settings events atomically, including the pending-marker changes associated
with a cloud-sync toggle.
`CoreDataLibraryObservation` reads retained persistent-history transactions using
the same cursor contract; durable Core Data stores now enable history tracking.
The `LibraryObservationSubscription` cursor owner anchors before the initial
snapshot, validates contiguous change batches and supports cancellation. It is
used by the pre-cutover startup boundary for durable stores and is polled from
activation and persistent-store remote-change notifications. The history-
retention/purge policy remains intentionally open.
The redacted recovery-report API is persisted in `recovery_items` but is not
yet connected to coordinator policy or user-facing recovery state. The
standalone runtime harness passes 118 disposable macOS tests; the app-hosted
adapter fixture and repository contracts are compile-checked by iOS
build-for-testing but have not executed because the current simulator runner
exits before XCTest bootstrapping. No test inspects or modifies a live user
store.

## Settings classification checkpoint

The existing `iCloudStorageManager.backedUpSettingsKeys` list is the starting
source inventory for user-facing preferences, but it is not reused as the
SQLite migration allowlist. CloudKit restore applies platform-specific rules
and model normalization, and the list does not include every current
FluidAudio/MLX preference. The independently typed catalog now records those
candidates and the source-observed omissions, while
`LibrarySettingsSourceInventory` enumerates the exact app-owned catalog keys.
`LibrarySettingsNormalizer` is a pure, context-driven boundary for canonicalizing
reviewed legacy identifiers/endpoints, omitting Mac-only Ollama state on iOS, and
clamping MLX model IDs to the target capability set. The shared
`LibrarySettingsSourceInventory.validateCloudKitSourceKeys` contract fails
closed if the production CloudKit projection drifts from the blocking catalog
plus the seven reviewed omissions. The app-hosted source-drift and no-write
startup-boundary tests require that projection and keep legacy settings inside
the inventory. The catalog now explicitly keeps the macOS vendor identifier
device-local, treats the backed-up Mistral transcription model as blocking
metadata, validates the reviewed enum values, and accepts empty optional
endpoints. `SQLiteMigrationStartupBoundary` consumes the normalized snapshot
and durable source cursor during startup without activating SQLite or writing
UserDefaults; it is not yet the production migration allowlist.

| Disposition | Current source-observed examples | Migration treatment |
| --- | --- | --- |
| Candidate blocking metadata settings | Selected AI/transcription engines, summary detail/thinking, transcription-progress display, time format, Watch preferences, location preference, provider endpoints/models/limits, Mistral transcription model, FluidAudio speaker-label choices, MLX inference choices, and the seven clear UI omissions | Copy only through the typed allowlist after key-by-key value and platform normalization rules are approved; record changes in the SQLite settings table. The catalog currently holds back derived/runtime and owner-controlled legacy values. |
| Retain in owning defaults/sync stores for now | `lastSyncDate`, routine-sync/backup timestamps, first-launch/setup markers, migration-completed flags, CloudKit manifest/quarantine state, pending cloud deletion markers, clean-shutdown state, and retry/backoff state | Do not duplicate derived lifecycle or cloud protocol state into the SQLite metadata table until its owner is migrated; preserve it durably during first boot. |
| Device/download/watch state | Preferred audio input UID, Mac capture flags, downloaded/in-flight model markers, processed Watch transfer IDs and similar local capability/cache state | Keep device-local or in its existing journal/cache; never copy it as portable library metadata. |
| Excluded secrets and credentials | API keys, legacy AWS credential/session values, Keychain-backed provider secrets and token-like values | Never copy to SQLite; continue using Keychain and existing one-time legacy-secret cleanup. |

This is a source classification checkpoint, not a production allowlist: any
unclassified key must block activation until its owner, value type, device scope,
and normalization rule are recorded. Legacy OpenAI settings, `SelectedAIModel`,
MLX context/chunk tuning and similar derived/runtime values are deliberately
classified outside the blocking-metadata subset until their owning behavior is
resolved.

## First repository-boundary slice

| Boundary | Implementation | Fixture/assertion disposition |
| --- | --- | --- |
| Immutable recording values | `LibraryRecordingSnapshot` preserves nullable legacy IDs, names, dates, durations, sizes, URLs, archive state, cloud-sync preference and modification dates without exposing managed objects or SQL rows. | Root SwiftPM contract test asserts the imported recording projection exactly; app-hosted test asserts the Core Data projection against the active compiled model. |
| Remaining metadata values | `LibraryTranscriptSnapshot`, `LibrarySummarySnapshot`, `LibraryProcessingJobSnapshot`, `LibraryArchiveLocationSnapshot` and `LibraryPendingCloudMutationSnapshot` preserve nullable scalar, payload and resolved-link values. | Root SwiftPM contract test asserts all five imported projections; app-hosted test asserts the active-model fixture, including relationship-derived storage IDs. |
| Core Data read adapter | `CoreDataLibraryRepository` fetches all six entities through a supplied context, copies values inside the context operation, and applies deterministic ordering. | Uses only a disposable `BisonNotes_AI_v2` fixture; no production `PersistenceController` or `CoreDataManager` is constructed. |
| Core Data migration source/input reader | `CoreDataMigrationSnapshotReader` captures all supported metadata entities from one quiescent context, preserves public attribute/relationship values, rejects temporary/incomplete graphs, and fingerprints the canonical snapshot without copying audio bytes. `CoreDataMigrationInputReader` composes that result with an explicitly inventoried typed blocking-settings snapshot and rejects unclassified source keys. | Runtime fixtures cover all six entities, relationship storage IDs, settings filtering and the combined input boundary; app-hosted tests cover original and active compiled models and are compile-checked by `build-for-testing`. Direct simulator execution remains outstanding because the current simulator runner exits before XCTest bootstrapping. |
| Maintenance gate and source-backed coordinator | `LibraryMaintenanceGate` grants fair normal access and exclusive maintenance leases, removes canceled waiters and makes release cleanup idempotent. `SQLiteMigrationSourceCoordinator` anchors the source observation after acquiring the gate, captures real Core Data/defaults input, rejects source revision drift before import and holds the gate through the isolated metadata/settings coordinator. `PersistenceController` now owns the shared gate for its generation; production Core Data repository construction paths and all SQLite `LibraryRepository` operations use it, while repository observation polling remains ungated to avoid deadlock during source validation. | Three gate tests cover fairness, waiter cancellation and cleanup; source-coordinator fixtures cover successful full-run composition under the gate and source-change blocking; new Core Data and SQLite repository tests prove a write waits behind an exclusive lease. This remains a disposable harness with no production destination selection, startup caller, activation or app-wide direct-caller gate adoption. |
| Resumable metadata/settings coordinator | `SQLiteMigrationCoordinator` validates a closed snapshot and blocking settings snapshot, finds the newest matching pending/running/paused run after reopen, emits progress after committed batches and settings commit, persists cancellation as paused, records definitive conflicts as failed with a generic durable message, applies/read-backs the allowlisted settings, and verifies the destination before completion. | Six host tests cover progress, metadata/settings reopen-resume, durable cancellation pause, allowlisted settings application and conflict failure. It is not wired to production source acquisition, settings acquisition, media, startup or an active user generation. |
| Durable media operation journal/worker | `SQLiteMediaCopyPlan`, `SQLiteLibraryStore` media-operation transactions and `SQLiteMediaFileOperationWorker` persist root-relative audio copy intent, claim/recovery state, streaming SHA-256/length verification and atomic partial-file publication. Exact destinations are idempotently accepted; conflicting destinations fail without overwrite and durable errors are generic. | Five host tests cover successful copy, idempotent enqueue, destination-before-checkpoint recovery, conflict protection and traversal rejection. Final production root selection, signed-device scheduling validation, retry metrics, progress UI and startup wiring remain open. |
| Durable import receipts | `SQLiteImportReceipt` and `SQLiteLibraryStore.recordImportReceipt` persist a unique source transfer ID, optional destination storage ID and typed committed/rejected/failed outcome. Duplicate source retries return the original result; changed retries and receipt-ID collisions fail closed. | Three host tests cover reopen/duplicate acknowledgement, conflicting duplicate outcome/destination and receipt-ID collision. The production Watch and Share/Inbox audio callers now use receipt-gated retention; signed-device scheduling validation, retry metrics and the remaining direct file-owning callers remain open. |
| Media transfer and retention boundary | `SQLiteMediaRootRegistry`, `SQLiteMediaTransferCoordinator` and `SQLiteMediaSourceRetentionPolicy` validate logical source/destination roots, run the existing verified worker, require a durable generic metadata acknowledgement before recording a committed receipt, and report source-removal eligibility only for a matching committed receipt plus acknowledged metadata. `SQLiteApplicationMediaRootMapping` classifies observed app roots without creating directories; `SQLiteMediaSourceRetentionExecutor` re-verifies the destination before idempotent source removal and refuses aliases, drift or a receipt that precedes metadata acknowledgement. `SQLiteApplicationMediaTransferCoordinator` adds application-root transfer, bounded retry cleanup and source-root filtering. | The media runtime tests cover successful retry and receipt persistence, checksum failure, receipt conflict, broad/unregistered root rejection, application-root classification, committed cleanup, pending-operation refusal, alias refusal, destination drift, the pre-acknowledgement retention guard and restart cleanup selection. Watch and Share/Inbox audio now use this boundary pre-cutover; final post-cutover root selection, signed-device scheduling validation and retry metrics remain open. |
| Application media transfer planning | `SQLiteApplicationMediaTransferPlanner` resolves an existing file to the most-specific registered application root and accepts an explicit destination root, while `SQLiteApplicationArchiveRestorePlanner` resolves a bookmark-scoped provider source under a caller-supplied logical root; both validate root-relative paths and compute streaming SHA-256/byte-length fingerprints without creating directories, copying bytes or deleting the source. `SQLiteApplicationMediaRootMapping` can add the resolved provider root to a process-local registry without persisting its URL. The generic transfer request keeps the candidate SQLite-media root as its default for compatibility, while the production Watch and Share/Inbox audio callers deliberately choose Documents before cutover. v8 persists a capped caller-owned metadata descriptor for restartable metadata acknowledgement. | Host tests cover Documents/Inbox specificity, explicit Documents destination selection, Watch staging, unmanaged sources, directory refusal, bookmark-root planning, source-outside-root refusal, alias protection, descriptor persistence/conflict and descriptor-size rejection. Watch and Share/Inbox production wiring is in place with activation retry and an iOS processing-task request; signed-device scheduling validation and final root selection remain open. |
| Restartable background media reconciliation | Schema v4 persists `sourceTransferID` with each transfer asset, schema v7 persists `metadataState` plus `metadataAcknowledgedAt`, and schema v8 persists an optional bounded `metadataPayload` descriptor with each generic file operation. `SQLiteMediaBackgroundReconciler` serializes a bounded pass over pending/failed operations and completed operations without receipts, verifies already-published destinations, invokes the idempotent metadata callback only after publication, records committed receipts only after acknowledgement and emits progress. `SQLiteApplicationMediaTransferRuntime` serializes direct transfer, retry reconciliation and source cleanup; source-root-filtered cleanup can finish a receipt-gated removal after relaunch. Pre-v7 completed rows are labeled `legacy` during upgrade. iOS now has an app-owned `BGProcessingTask` request/handler for this runtime, with expiration cancellation and bounded follow-up scheduling; native macOS remains activation-driven. | Focused media tests cover source identity across reopen, queued background copying with progress, receipt completion after reopen, changed-destination refusal, metadata failure/retry, interrupted metadata-claim recovery, lost-receipt recovery, pre-acknowledgement retention refusal, descriptor persistence/conflict, payload size rejection and restart cleanup selection. Watch and Share/Inbox activation retry plus the iOS scheduler use the runtime; signed-device delivery/expiration validation, retry metrics and final media-root selection remain open. |
| Durable provider archive-restore journal/reconciliation | Schema v6 persists `archive_restore_operations` through copy, metadata-acknowledgement and source-deletion phases with generic errors, attempt counts, reopen recovery and the owning recording's `ownerLastModified` revision. `SQLiteArchiveRestoreReconciler` bounds work, runs copy/source deletion in detached utility tasks, re-verifies changed destinations before metadata retry and deletes the provider source only after metadata acknowledgement. `SQLiteArchiveRestoreCoordinator` and its actor runtime now connect this journal to `RecordingArchiveService`; the production caller publishes into the existing Documents-relative path until SQLite cutover, retains the resolved bookmark lease for each operation, and retries only through an existing journal beside durable Core Data. | The full standalone suite passes 129/129, including focused archive/migration-version coverage at 3/3; the macOS app-hosted build-for-testing check passes. The full iOS build remains blocked before app/test compilation by the pre-existing `withSecurityScope` availability error, and direct simulator XCTest execution remains unavailable. Dedicated iOS processing-task requests and activation retry now exist for archive restore and generic media; signed-device delivery/expiration validation, final SQLite media-root selection and live-data validation remain open. |
| SQLite read adapter | `SQLiteLibraryRepository` reads all six isolated tables through `SQLiteLibraryStore` and maps database dates, booleans, blobs and links into the same value types. | Imports the closed synthetic snapshot into a temporary file, verifies all six projections, and separately verifies an empty pre-import database. |
| Typed settings boundary | `LibrarySettingValue` and `LibrarySettingsSnapshot` allow only string, integer, finite real, bool, data and date values. `UserDefaultsLibrarySettingsStore` reads/writes an explicit allowlist; `LibrarySettingsCatalog.readMigratableSettings` now requires the app-owned source-key inventory and fails closed on unclassified keys; `SQLiteLibrarySettingsStore` applies the same allowlist over schema-v2 `library_settings` and records its committed insert/update in the v3 change log. `LibrarySettingsSourceInventory` explicitly records the reviewed main-defaults keys, the separate Action Button app-group key, dynamic legacy-key prefixes and CloudKit omissions. `LibrarySettingsNormalizer` provides pure target-platform normalization before final catalog validation, while `SQLiteMigrationStartupBoundary` captures that result without source writes. The catalog exposes only the blocking-metadata subset to a future reader and validates finite values, reviewed ranges/enums and endpoint credentials. | Host tests round-trip all six value kinds, verify six durable inserts and six durable updates, reject out-of-catalog/non-migratable/type-mismatched/invalid values, reject an unclassified source key and source-list drift, require the exact source inventory/catalog match, exercise normalization and prove unrelated defaults are untouched. The app-hosted source-drift/no-write boundary tests are compile-checked. |
| Recording creation and transient discard commands | `LibraryRecordingCreateCommand` validates a caller-owned audio recording's metadata, rejects duplicate UUID identities and commits the initial recording row through Core Data or SQLite. `LibraryRecordingDiscardCommand` is intentionally narrower than user deletion: it removes only an orphaned recording, refuses transcript/summary/processing-job/archive-location/pending-outbox dependents, and does not enqueue a CloudKit tombstone. SQLite assigns `sqlite-recording-<lowercase-UUID>` for creation and records durable inserted/deleted recording changes; the async `AppDataCoordinator` bridge is used by `BackgroundProcessingManager.ensureRecordingExists`, `FileImportManager` and `TranscriptImportManager`. | Focused SQLite runtime tests cover the complete create row, stable identity, duplicate rejection, clean discard, durable delete observation and dependent-row refusal. The app-hosted Core Data contract covers the active-model create/discard behavior and dependent-row refusal but is compile-checked by `build-for-testing`; direct simulator execution remains unavailable. Audio copying, file naming and source retention remain outside these commands; full recording deletion, preserve-summary deletion, inbound imported-audio marker/file application and archive/file ownership are separate lifecycle boundaries. |
| Full recording deletion command | `LibraryRecordingDeleteCommand` addresses one recording with an optional optimistic-revision guard, deletes its recordings/transcripts/summaries/processing jobs in one adapter transaction, nullifies retained summary transcript links as Core Data does, withdraws stale imported-audio markers, and coalesces durable recording/summary CloudKit removal intents. SQLite deletes restrictive-FK children in dependency order and records each committed mutation; archive locations are intentionally retained for the separate archive lifecycle. `AppDataCoordinator` exposes the async bridge, and whole-recording paths in `EnhancedFileManager`, `RecordingsListView`, `SummaryDetailView`, `TranscriptViews` and `CombineRecordingsView` use it. | SQLite runtime coverage verifies graph deletion, archive-location retention, child identities in the recording-deletion payload, summary-removal intents, imported-marker withdrawal, local-only deletion and durable observations. The Core Data contract verifies the active-model graph/outbox behavior. The standalone suite passes 95/95 and both macOS/iOS app-hosted `build-for-testing` checks pass; direct simulator XCTest execution remains unavailable. Preserve-summary deletion is covered by the following separate command row; inbound whole-recording tombstones are covered by the dedicated row below, while archive/file ownership and startup cutover remain open. |
| Preserve-summary recording deletion command | `LibraryRecordingPreserveSummaryDeleteCommand` retains the recording and its summary content as the UI anchor, clears audio/transcript links, deletes all locally linked transcript rows, includes stale transcript identities supplied by imported cleanup, and coalesces transcript-removal plus imported-audio CloudKit intents in the same Core Data or SQLite transaction. The SQLite adapter also resolves a summary's storage-linked transcript when a recording back-reference is absent. `AppDataCoordinator` exposes the async bridge; `EnhancedFileManager` and imported-transcript cleanup use it while retaining file-byte/sidecar ownership in the file manager. Its deletion cleanup now uses the idempotent file store before the metadata transaction, leaving the recording URL retryable across a process kill. | Two focused SQLite runtime tests cover cloud-intent and local-only behavior; the app-hosted Core Data contract covers summary, transcript, job/archive retention and outbox identities. The standalone suite passes 97/97 and both macOS/iOS app-hosted `build-for-testing` checks pass; direct simulator execution remains unavailable. Inbound whole-recording tombstones are covered by the following row; the production media/file journal, archive/file ownership and startup cutover remain open. |
| Inbound whole-recording CloudKit tombstone application | `iCloudStorageManager` applies whole-recording markers through `AppDataCoordinator.applyRemoteRecordingDeletionUsingRepository`, which invokes `LibraryRecordingDeleteCommand` with cloud enqueue disabled. Missing rows are idempotent replays; existing rows use the adapter's metadata transaction, SQLite's dependency order and Core Data's post-commit summary-attachment cleanup. Imported-audio marker/file removal is covered by the dedicated boundary below because its local file ownership and retry contract differ. | The app-hosted orchestration regression covers deletion of the recording/transcript/summary graph and verifies that no outbound marker is raised. The standalone suite passes 97/97 and both macOS/iOS app-hosted `build-for-testing` checks pass; direct simulator XCTest execution remains unavailable. No repository backend is wired to startup. |
| Inbound transcript CloudKit tombstone application | `iCloudStorageManager` applies transcript markers through `AppDataCoordinator.applyRemoteTranscriptDeletionUsingRepository`, which invokes `LibraryTranscriptDeleteCommand` with cloud enqueue disabled. The command deletes only the transcript metadata, clears recording and summary links, resets transcription status, preserves the recording/summary rows and treats a missing row as an idempotent replay. Local deletes optionally enqueue the outbound transcript-removal intent; audio bytes and sidecars remain outside this boundary. | The focused SQLite runtime test verifies atomic metadata/link cleanup, the outbox intent, durable recording/summary/transcript observations and no-op replay; the app-hosted Core Data contract and inbound orchestration regression are compile-checked by `build-for-testing`. The standalone suite passes 98/98 and both macOS/iOS app-hosted `build-for-testing` checks pass; direct simulator XCTest execution remains unavailable. No repository backend is wired to startup. |
| Inbound summary CloudKit tombstone application | `iCloudStorageManager` applies summary markers through `AppDataCoordinator.applyRemoteSummaryDeletionUsingRepository`, which invokes `LibrarySummaryDeleteCommand` with cloud enqueue disabled. The command deletes only summary metadata, clears the parent recording's summary link/status and treats a missing row as an idempotent replay; the recording and transcript remain intact. Local deletes optionally enqueue the outbound summary-removal intent. Summary notes and attachment files are removed only after the coordinator observes a successful repository commit, and audio bytes remain outside this boundary. | The focused SQLite runtime test verifies atomic summary/recording updates, the outbox intent, durable summary/recording observations and no-op replay; the app-hosted Core Data contract and inbound orchestration regression are compile-checked by `build-for-testing`. The standalone suite passes 99/99 and both macOS/iOS app-hosted `build-for-testing` checks pass; direct simulator XCTest execution remains unavailable. No repository backend is wired to startup. |
| Inbound imported-audio CloudKit tombstone application | `iCloudStorageManager` applies imported-audio markers through `AppDataCoordinator.applyRemoteImportedAudioRemovalUsingRepository`, which invokes `LibraryImportedAudioRemovalCommand` with cloud enqueue disabled. The command clears only the recording audio link in Core Data or SQLite, preserves recording/transcript/summary metadata, coalesces local removal intent when requested and records the SQLite observation atomically. `LibraryImportedAudioFileStore` resolves the storage-neutral path and removes the main file plus known sidecars idempotently. The coordinator removes the file before the metadata unlink, leaving the URL and inbound marker retryable across a process kill; missing files are safe replays. | Focused Core Data/SQLite contract tests cover metadata preservation, optional outbox behavior and missing-file idempotency; CloudKit regression coverage verifies inbound application and failed file cleanup leaves the URL intact. The standalone suite passes 101/101 and both macOS/iOS app-hosted `build-for-testing` checks pass; direct simulator XCTest execution remains unavailable because the current runner exits before XCTest bootstrapping. Outbound preserve-summary file-manager ordering, the production media/file journal and startup cutover remain open. |
| Transcript import caller | `TranscriptImportManager` uses repository snapshot reads for duplicate-name generation, creates the imported dummy-audio recording through `LibraryRecordingCreateCommand` and persists encoded segments through `LibraryTranscriptUpsertCommand`. If transcript persistence fails, it invokes `LibraryRecordingDiscardCommand`; the importer retains dummy-audio creation, ownership and file cleanup, and logs any failed metadata cleanup while rethrowing the original import error. | Both app-hosted targets compile the caller and the 95-test standalone suite passes. The discard contract is import-only and does not replace preserve-summary deletion or the inbound CloudKit tombstone lifecycle; no SQLite backend is selected for this caller at startup. |
| Recording rename command | `LibraryRecordingRenameCommand` addresses a row by legacy ID or storage ID, applies the existing `[Watch]` normalization, and can require an expected `lastModified`. Core Data and SQLite adapters return the committed snapshot or explicit not-found, ambiguous, stale or write errors. | Host tests cover SQLite commit and stale rejection; app-hosted contract coverage checks the Core Data commit. The display-name-only `AudioPlayerView`, `SummaryDetailView`, `EditableTranscriptView` and summary-regeneration callers use the Core Data adapter. The file-owning AI rename stays outside this command pending a journaled file-operation boundary. |
| Recording date/location update commands | `LibraryRecordingDateUpdateCommand` and `LibraryRecordingLocationUpdateCommand` preserve the recording row, atomically set or clear the date/location projection, validate finite dates, coordinates and accuracy, and optionally require an expected `lastModified`. Both adapters return the committed snapshot and durable recording change; `AppDataCoordinator` and `SummaryDetailView` route user edits through these commands while Core Data remains authoritative. | Focused runtime coverage verifies date/location updates, complete location clearing and stale revision rejection; the app-hosted Core Data contract compiles the equivalent behavior. The standalone suite passes 116/116 and the macOS app-hosted build-for-testing check passes. The full iOS scheme remains blocked by the pre-existing watch-widget `accessoryCorner` availability error, and direct simulator XCTest execution remains unavailable. |
| Production recording-creation callers | `AudioRecorderViewModel` normal completion, interruption/unprocessed recovery, segment merge, live-transcription and native-Mac finalization paths, Watch intake, and `CombineRecordingsView` now await `AppDataCoordinator.createRecordingUsingRepository`. The helper preserves an iOS recovery snapshot when metadata commit fails; Watch removes a destination with no repository row so the source can retry; combine removes an uncommitted output while leaving its source recordings intact. The synchronous `AppDataCoordinator.addRecording` remains only for deterministic UI-test seeding and legacy compatibility. | The macOS app-hosted target compiles all changed callers and the standalone suite passes 116/116. The iOS target-only compile remains blocked before app compilation by the watch `AppIcon` asset and Textual dependency module-resolution issues; the known full scheme also has the pre-existing watch-widget `accessoryCorner` error. No simulator or live-data test ran. Production SQLite startup/journal wiring remains open. |
| CloudKit summary restore and summary-only anchors | `iCloudStorageManager` routes linked cloud summaries through `AppDataCoordinator.upsertSummaryUsingRepository` with incoming cloud identity semantics. Summary-only cloud records use `upsertOrphanedSummaryUsingRepository`, whose Core Data and SQLite adapters create or retry one zero-audio recording anchor and summary in a single metadata transaction; missing transcript IDs remain retryable raw references. Incoming UUID replacement preserves the adapter storage identity and moves supplemental notes/attachments after the metadata commit. | Core Data and SQLite contract tests cover incoming identity, collision rejection, atomic anchor creation and idempotent retry; the CloudKit orphan regression now exercises the coordinator bridge. The standalone suite passes 118/118 and the macOS app-hosted build-for-testing check passes. Direct simulator XCTest execution and live CloudKit/user-data validation remain unavailable; no repository backend is wired to startup. |
| CloudKit recording restore metadata and audio link | `iCloudStorageManager` routes recording metadata through `LibraryRecordingCloudRestoreCommand`, which applies cloud scalar fields with a guarded `lastModified` revision and creates metadata-only cloud rows without replacing existing local audio, archive or cloud-sync state. After a staged CloudKit asset copy succeeds, `LibraryRecordingAudioLinkCommand` commits only the local audio URL and optional size; the imported-audio clear path uses the same link operation. Core Data and SQLite share the command contract, while SQLite records durable recording observations for both phases. Child metadata and relationship repair remain explicit restore phases, and durable media-worker integration remains separate. | Focused SQLite runtime and app-hosted Core Data contract tests cover existing-row preservation, cloud-only creation, stable retry, stale rejection and post-copy linking. The standalone suite passes 120/120 and the macOS app build-for-testing check passes. Generic iOS build-for-testing remains blocked before app/test compilation by the pre-existing `withSecurityScope` iOS availability error; no simulator, live CloudKit account or user store was used, and no repository backend is wired to startup. |
| CloudKit summary metadata restore | `iCloudStorageManager` routes linked summary scalar fields through `LibrarySummaryCloudRestoreCommand`. Both repository adapters accept legacy records with missing summary fields, preserve existing relationship objects during the metadata commit, guard the stable UUID and expected `generatedAt` revision, reject conflicting recording/transcript identities, and leave audio/attachments outside the command. SQLite records a durable summary observation. The restore phase captures recording summary pointers/status before recording metadata is applied, arbitrates the incoming summary link by timestamp, restores the prior pointer/status when the local summary wins, and repairs the transcript relationship only after accepted summary metadata. | The focused SQLite runtime test covers metadata-only creation, raw recording/transcript ID preservation, stable retry and stale rejection; the app-hosted Core Data contract covers relationship preservation and stale rejection but could not run because the iOS build stops before app/test compilation at the pre-existing `withSecurityScope` availability error. The macOS app build-for-testing check passes and the standalone suite passes 122/122. No simulator, live CloudKit account or user store was used, and no repository backend is wired to startup. |
| Security-scoped bookmark lease | `SQLiteSecurityScopedBookmarkLease` resolves bookmarks with generic errors, reports stale resolution, starts access exactly once and pairs it with idempotent stop/deinit cleanup. `RecordingArchiveService` retains the lease across detached provider copy, metadata acknowledgement and source-deletion tasks; persisted archive state continues to use bookmark and logical-root identities rather than absolute provider paths. Journal retries resolve and lease each archive location independently. | Focused runtime tests cover valid resolution/idempotent stop and invalid-bookmark failure; the macOS app-hosted build-for-testing check passes. The lease and journal are now used by the production provider-restore caller, with bounded startup/activation retry and a dedicated iOS processing-task request. Signed-device delivery/expiration validation remains open, and SQLite is inactive. |
| First-boot migration progress presentation | `SQLiteMigrationPresentationModel` provides redacted idle/running/paused/failed/completed state with durable progress, safe pause, retry, generic failure and terminal completion semantics. The injected app view model and `SQLiteMigrationProgressView` render a blocking progress/retry screen without selecting a store or reading user data. | Four pure state-machine tests are included in the 116/116 standalone suite, and the macOS app-hosted build-for-testing check compiles the view and view model. Startup wiring, source-backed coordinator integration and recovery-report policy remain open; the full iOS scheme is still blocked by the pre-existing watch-widget availability error and direct simulator execution is unavailable. |
| Transcript upsert command | `LibraryTranscriptUpsertCommand` carries encoded transcript payloads, resolves one recording and preserves the existing transcript identity on replacement. Core Data and SQLite create or update the transcript and recording link/status atomically; SQLite records both changes in its durable observation log. | Two focused SQLite tests cover replacement identity/payload updates and stable new-row retry; the app-hosted contract covers Core Data replacement identity and persisted payloads. Production transcription persistence uses the async repository path; the synchronous helper remains for UI-test seeding and legacy compatibility. No backend is selected for startup. |
| Summary upsert command | `LibrarySummaryUpsertCommand` carries encoded structured payloads and summary metadata, resolves one recording and preserves the existing summary identity on replacement. Core Data and SQLite create or update the summary and recording link/status atomically; SQLite records both changes in its durable observation log. Missing or ambiguous recording/summary/transcript identities fail closed, and retrying a new-row command does not duplicate it. Supplemental notes and attachments remain outside this metadata transaction. | Two focused SQLite tests cover replacement identity/payload updates and stable new-row retry; the app-hosted contract covers Core Data replacement identity and persisted payloads. Background summarization and both summary-regeneration paths use the async repository path; the synchronous helper remains for UI-test seeding and legacy compatibility. No backend is selected for startup. |
| Recording archive-state command | `LibraryRecordingArchiveCommand` commits `isArchived`, `archivedAt`, `archiveNote` and `lastModified` through Core Data or SQLite, with an optional expected-revision guard. SQLite records the durable recording change in the same GRDB transaction; unarchive explicitly clears archive metadata. | One focused SQLite test and one app-hosted Core Data contract test cover archive/restore state and revision behavior. `RecordingArchiveService` now uses the command from its archive-export completion path and its repository-backed clear-flags path; archive-location reads and provider file operations remain outside this boundary. |
| Recording audio restore command | `LibraryRecordingAudioRestoreCommand` relinks a recording to an already-copied and validated local audio file, optionally updates its file size, clears archive metadata and commits `lastModified` in one Core Data or SQLite transaction with an optional expected-revision guard. | Focused SQLite and app-hosted Core Data contract tests cover the atomic URL/file-size/archive-state update and durable recording change. The archive re-import caller and the journaled file-provider restore path use this command; the provider path retains Documents-relative audio and only removes its external source after metadata acknowledgement. Final generic media transfer/retention integration remains open. |
| Archive-location upsert command | `LibraryArchiveLocationUpsertCommand` records bookmark, destination, filename, verification, provider, status and recording identity metadata for an already-verified external destination. Core Data and SQLite preserve a stable ID on retry, reuse a same-recording/same-destination legacy row and reject ambiguous or cross-recording collisions; SQLite records an `archiveLocation` change in the same GRDB transaction. | One focused SQLite test and one app-hosted Core Data contract test cover stable retry identity and no duplicate row. The production archive-export caller and stale/missing status updates supply these commands; repository snapshot reads are now used by the recordings list and restore selector. File-provider copy, bookmark acquisition, restore copy and source removal remain outside the command. |
| Production archive-export completion caller | `RecordingArchiveService` validates iCloud destinations and security-scoped bookmarks, creates archive-location commands, awaits repository location upserts, commits archive state, and only then removes local audio/known sidecars through the idempotent file store. `RecordingsListView` awaits the operation and preserves the selection when an error is reported. A failed metadata operation leaves local audio untouched; a post-commit cleanup failure leaves the archive URL retryable. | The standalone suite passes 102/102; macOS app-hosted `build-for-testing` passes. The current full iOS scheme build is blocked by the pre-existing watch-widget `accessoryCorner` availability error; direct simulator XCTest execution remains unavailable. Archive-location reads and restore metadata are repository-backed; provider copy/source deletion and the full production media/file journal remain separate boundaries. |
| Cloud-sync preference command | `LibraryRecordingCloudSyncCommand` addresses a recording through the same reference/revision boundary and commits `isCloudSyncDisabled` with the durable `localOnlyRemoval` marker. Core Data uses one context save; SQLite uses one GRDB transaction, preserves the earliest marker request time, coalesces duplicate rows and removes all matching markers when sync is re-enabled. CloudKit flushing remains post-commit. | Host coverage verifies both recording and pending-marker changes, exact observation revisions and re-enable cleanup; the app-hosted contract covers the Core Data path in the compiled active-model fixture. No live account or user store is touched. |
| Processing-job create/update/delete/recovery commands | `LibraryProcessingJobCreateCommand`, `LibraryProcessingJobUpdateCommand`, `LibraryProcessingJobDeleteCommand`, `LibraryProcessingJobTerminalCleanupCommand` and `LibraryProcessingJobCrashRecoveryCommand` address jobs by stable storage or legacy ID, validate command values and apply an optimistic `lastModified` guard where a row is being changed or removed. Creation preserves the initial status, progress, model, error, completion and start-time values, optionally resolves a stable recording reference and rejects duplicate UUIDs. Updates distinguish preserving an optional error/completion value from intentionally clearing it. Terminal cleanup matches legacy casing/whitespace and records one durable delete change per deleted row. Crash recovery marks only the known nonterminal set as Failed, preserves progress, records the generic message and completion timestamp in one adapter transaction, and safely skips missing/already-terminal rows on retry. Core Data commits each command in one context save; SQLite commits each in one GRDB transaction and emits one `processingJob` change. `BackgroundProcessingManager` routes synchronous creation, asynchronous status transitions/reconciliation, terminal cleanup and startup crash recovery through the Core Data adapter. SQLite canonicalizes UUID legacy references for migrated rows. | Five focused host tests cover create/link/duplicate rejection, terminal cleanup, crash recovery, update set/preserve/clear behavior, delete durability, stale/not-found rejection, exact revisions and no revision on rejection; the app-hosted contract covers the Core Data create/terminal-cleanup/recovery paths and both adapters' update/delete paths against the active compiled model. |
| Durable observation cursor | `LibraryObservation` exposes a global revision and ordered `LibraryChange` values. `SQLiteLibraryStore` persists `library_changes` in schema v3 and the SQLite repository emits recording/setting/archive-state/archive-location/cloud-sync, transcript, summary and pending-marker events in the same transaction as those writes. `CoreDataLibraryObservation` reads retained `NSPersistentHistory` transactions with hashed object-URI identities, and durable `PersistenceController` stores enable history tracking. `LibraryObservationSubscription` anchors before the initial snapshot, validates contiguous change batches and owns explicit cancellation. The app startup boundary anchors a Core Data subscription for durable stores and polls it from persistent-store remote-change and activation notifications; in-memory stores are explicitly not applicable. Repository observation polling intentionally stays outside the normal-access gate because the source coordinator polls during its exclusive lease. | Host tests reject negative/ahead cursors, verify exact rename and cloud-sync events survive database reopen, upgrade a disposable v2 store to v3, exercise Core Data insert/update/delete history while filtering an unrelated entity, exercise subscription across a commit and cancellation, and prove repository writes wait behind the gate. The app-hosted startup boundary is compile-checked; history retention/purge policy and remaining file-owning write commands are still open. |

This is still a pre-cutover boundary, not production migration evidence. The
production recording-creation callers and CloudKit
summary/recording/transcript-restore metadata callers now share repository
commit boundaries; synchronous Core Data helpers remain only for deterministic
test fixtures and legacy compatibility.
The bookmark lease,
summary anchor and migration-progress screen are reusable process-local or
presentation seams, but none selects a production store or starts a live
migration. The version-6 archive-restore journal is now connected to the
production provider-restore caller through the existing Documents path, with
per-location bookmark retry and bounded startup reconciliation; this does not
constitute SQLite activation or OS-managed background scheduling. Schema v8
now adds the bounded generic transfer metadata descriptor on top of the v7
acknowledgement state, so a copied asset can reconstruct its caller metadata
commit after reopen without storing audio bytes in the journal. Watch is now
connected to the pre-cutover Documents destination with persistent staging,
activation retry and receipt-gated source removal. Share/Inbox audio now uses
the same journal, metadata descriptor, Documents destination and bounded
activation retry; failed and unsupported inputs remain available for retry.
External document-picker/web imports and other direct file-owning paths remain
explicit follow-up boundaries. The next inventory update must expand
command/error coverage, finish final media-root selection, validate the
OS-managed background scheduling boundary and add retry metrics, and convert or explicitly exclude every remaining
direct source mutation caller from the maintenance-gate boundary before
production services can depend on the complete repository.
