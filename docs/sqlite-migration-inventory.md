# SQLite migration inventory

Source: `v2.5` at `d64660ba85dc04e6bc2f1fa88263427cb76b37aa`, inspected 2026-09-07. Implementation branch: `v3.0`. Isolated schema foundation: `c8f8d2f5a7e112b417783751c5e5ef3a0c325013`.

Generated from checked-in model XML and Swift symbol searches. This inventories schema, not production row contents. Add runtime paths, defaults domains, file formats, indirect callers and source-version fixtures in Phase 0 of [the plan](sqlite-migration-plan.md).

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
| Watch source and receipts | Watch `Documents/WatchRecordings/metadata.json`, `recordings/*.m4a`, and `Documents/reliable_transfers.json`; phone `tmp/WatchTransferStaging` |
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

## Handoff status — 2026-09-09

This inventory describes the source boundary and the intended first SQLite
schema; it is not evidence that user data has migrated. Core Data remains
authoritative. The isolated `SQLiteLibraryStore` v1 foundation mirrors all six
model entities and adds the operational tables, seeded library/generation
metadata, independent storage IDs, restrictive resolved-link foreign keys,
root-relative asset-operation paths, and integrity diagnostics. It is not wired
to app startup, the production repository, CloudKit, or any user database. The
importer, repository, migration screen, durable checkpoint coordinator,
host-independent runtime tests and background media worker still need
implementation against disposable fixtures.
