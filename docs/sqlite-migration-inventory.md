# SQLite migration inventory

Source: `v2.5` at `d64660ba85dc04e6bc2f1fa88263427cb76b37aa`, inspected 2026-09-07. Implementation branch: `v3.0-sqlitemigration`; clean PR target: `v3.0` (kept at the `v2.5` baseline). Isolated schema/checkpoint/runtime foundation: `e612ebdcbbabb9522cdb4e9b15489324af1476a4`. Closed-snapshot verifier: `444542ac`; Core Data source fixtures: `5f9744d`; metadata importer: `9731e69a`; recovery reports: `40b431a0`; repository/settings checkpoint: `b71d9984`; observation checkpoint: `cdd0bf8e`; schema/contract tests: `82e687e8`; settings catalog checkpoint: `5232640`; catalog validation: `52101ae0`; CloudKit source contract: `e2ff6c0`; legacy source contract: `f8b4d6c7`; Core Data history observation: `c692c8c7`; Core Data migration source reader/catalog: `630a513e`; resumable metadata coordinator: `230e511c`; durable pause/settings phase: `5c88828b`; explicit Core Data/settings input boundary: `54e6c141`; durable media operation worker: `44515c52`; durable import receipt idempotency: `b8b80783`; media transfer/retention boundary: `c8b70087`; application media roots/source retention: `88c393e9`.
Current restartable media reconciliation checkpoint: `fe99e3ff`.
Current settings source-inventory checkpoint: `9dfed6fd`.
Current observation-subscription checkpoint: `33bdc7ed`.

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

## Handoff status — 2026-09-11

This inventory describes the source boundary and the intended first SQLite
schema; it is not evidence that user data has migrated. Core Data remains
authoritative. The isolated `SQLiteLibraryStore` foundation now runs schema v4;
its initial v1 schema mirrored all six
model entities and adds the operational tables, seeded library/generation
metadata, independent storage IDs, restrictive resolved-link foreign keys,
root-relative asset-operation paths, integrity diagnostics and typed durable
migration-run checkpoints. A read-only verifier now validates closed snapshots
against those six tables by schema, migration-run fingerprint, row identity and
declared value. An app-hosted fixture factory now loads the compiled original
and active v2 Core Data models into disposable SQLite-backed stores, populates
representative rows, projects every destination column and relationship, and
fingerprints the projection. Its XCTest coverage is compiled but has not
executed because the current simulator runner exits before XCTest bootstrapping;
it covers only the checked-in models, not every shipped historical hash. The
isolated metadata importer now writes those rows and row-map entries in
dependency order with transactional batch checkpoints and idempotent reopen/
resume behavior; it is not wired to app startup, the production repository,
CloudKit, or any user database. The read-only Core Data source reader is now
implemented and tested against disposable six-entity models; the isolated
Core Data migration input reader now composes that metadata snapshot with an
explicitly inventoried, typed blocking-settings snapshot and rejects
unclassified source keys before capture; it still depends on a future gate to
quiesce both source domains. The isolated
resumable metadata coordinator now handles exact-run lookup, committed batch
progress, a durable paused status for cancellation, definitive failure
checkpoints and closed-snapshot verification. Its blocking settings phase applies
the validated allowlist before final verification and is resumable after reopen.
Production source/settings acquisition and coordinator wiring,
remaining settings platform normalization/source-drift checks, Core Data
startup subscription wiring, migration screen, historical release fixtures,
final production media-root selection and Watch/share/background caller
integration still need implementation against disposable fixtures. The isolated
media worker, candidate application-root mapping, checksum-bound planner,
restartable background reconciler and guarded retention executor now exist as
background-safe foundations, but they are not app callers or a migration gate.
The first repository slice now
defines storage-neutral snapshots for all six migrated metadata entities and the
`LibraryRepository` contract, with Core Data and SQLite adapters over copied
values. It also defines typed allowlisted settings values, a UserDefaults
source adapter, the SQLite schema-v2 settings table/adapter, and a recording-
rename command with explicit revision and error behavior. Contract coverage
imports the synthetic snapshot into SQLite, reads the active Core Data fixture,
round-trips typed settings and checks stale rename rejection. The
display-name-only `AudioPlayerView` caller uses the Core Data adapter; the AI
file-renaming workflow remains on its existing path until file operations have
a journaled command. Neither backend is wired to startup or user-data
migration.
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
The SQLite-only `LibraryObservation` implementation persists a global
`library_changes` cursor and emits recording-rename/settings events atomically.
`CoreDataLibraryObservation` reads retained persistent-history transactions using
the same cursor contract; durable Core Data stores now enable history tracking.
The `LibraryObservationSubscription` cursor owner anchors before the initial
snapshot, validates contiguous change batches and supports cancellation. It is
not wired to lifecycle notifications or app startup, and the history-retention/
purge policy remains intentionally open.
The redacted recovery-report API is persisted in `recovery_items` but is not
yet connected to coordinator policy or user-facing recovery state. The
standalone runtime harness has passed 66 disposable macOS tests; the
app-hosted adapter fixture is compile-checked but has not executed because the
current simulator runner exits before XCTest bootstrapping. No test inspects or
modifies a live user store.

## Settings classification checkpoint

The existing `iCloudStorageManager.backedUpSettingsKeys` list is the starting
source inventory for user-facing preferences, but it is not reused as the
SQLite migration allowlist. CloudKit restore applies platform-specific rules
and model normalization, and the list does not include every current
FluidAudio/MLX preference. An initial independently typed catalog now records
those candidates and the source-observed omissions. An app-hosted contract test
compares the actual CloudKit and legacy on-device LLM source lists to the
catalog, but it has not executed because the current Xcode build cannot resolve
external packages. The catalog now explicitly keeps the macOS vendor identifier
device-local, treats the backed-up Mistral transcription model as blocking
metadata, validates the reviewed enum values, and accepts empty optional
endpoints. Exhaustive app-key inventory, platform normalization and startup
wiring remain open; the catalog is not yet the final production allowlist.

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
| Immutable recording values | `LibraryRecordingSnapshot` preserves nullable legacy IDs, names, dates, durations, sizes, URLs, archive state and modification dates without exposing managed objects or SQL rows. | Root SwiftPM contract test asserts the imported recording projection exactly; app-hosted test asserts the Core Data projection against the active compiled model. |
| Remaining metadata values | `LibraryTranscriptSnapshot`, `LibrarySummarySnapshot`, `LibraryProcessingJobSnapshot`, `LibraryArchiveLocationSnapshot` and `LibraryPendingCloudMutationSnapshot` preserve nullable scalar, payload and resolved-link values. | Root SwiftPM contract test asserts all five imported projections; app-hosted test asserts the active-model fixture, including relationship-derived storage IDs. |
| Core Data read adapter | `CoreDataLibraryRepository` fetches all six entities through a supplied context, copies values inside the context operation, and applies deterministic ordering. | Uses only a disposable `BisonNotes_AI_v2` fixture; no production `PersistenceController` or `CoreDataManager` is constructed. |
| Core Data migration source/input reader | `CoreDataMigrationSnapshotReader` captures all supported metadata entities from one quiescent context, preserves public attribute/relationship values, rejects temporary/incomplete graphs, and fingerprints the canonical snapshot without copying audio bytes. `CoreDataMigrationInputReader` composes that result with an explicitly inventoried typed blocking-settings snapshot and rejects unclassified source keys. | Runtime fixtures cover all six entities, relationship storage IDs, settings filtering and the combined input boundary; app-hosted tests cover original and active compiled models but remain compile-only until the app target can resolve external packages. |
| Resumable metadata/settings coordinator | `SQLiteMigrationCoordinator` validates a closed snapshot and blocking settings snapshot, finds the newest matching pending/running/paused run after reopen, emits progress after committed batches and settings commit, persists cancellation as paused, records definitive conflicts as failed with a generic durable message, applies/read-backs the allowlisted settings, and verifies the destination before completion. | Six host tests cover progress, metadata/settings reopen-resume, durable cancellation pause, allowlisted settings application and conflict failure. It is not wired to production source acquisition, settings acquisition, media, startup or an active user generation. |
| Durable media operation journal/worker | `SQLiteMediaCopyPlan`, `SQLiteLibraryStore` media-operation transactions and `SQLiteMediaFileOperationWorker` persist root-relative audio copy intent, claim/recovery state, streaming SHA-256/length verification and atomic partial-file publication. Exact destinations are idempotently accepted; conflicting destinations fail without overwrite and durable errors are generic. | Five host tests cover successful copy, idempotent enqueue, destination-before-checkpoint recovery, conflict protection and traversal rejection. Final production root selection, scheduling, progress UI and startup wiring remain open. |
| Durable import receipts | `SQLiteImportReceipt` and `SQLiteLibraryStore.recordImportReceipt` persist a unique source transfer ID, optional destination storage ID and typed committed/rejected/failed outcome. Duplicate source retries return the original result; changed retries and receipt-ID collisions fail closed. | Three host tests cover reopen/duplicate acknowledgement, conflicting duplicate outcome/destination and receipt-ID collision. Not connected to Watch/share callers or source-retention cleanup yet. |
| Media transfer and retention boundary | `SQLiteMediaRootRegistry`, `SQLiteMediaTransferCoordinator` and `SQLiteMediaSourceRetentionPolicy` validate logical source/destination roots, run the existing verified worker, record a committed receipt only after completion, and report source-removal eligibility only for a matching committed receipt. `SQLiteApplicationMediaRootMapping` classifies observed app roots without creating directories; `SQLiteMediaSourceRetentionExecutor` re-verifies the destination before idempotent source removal and refuses aliases or drift. | Nine host tests cover successful retry and receipt persistence, checksum failure, receipt conflict, broad/unregistered root rejection, application-root classification, committed cleanup, pending-operation refusal, alias refusal and destination drift. Final production root selection, Watch/share caller integration and retention scheduling remain open. |
| Application media transfer planning | `SQLiteApplicationMediaTransferPlanner` resolves an existing file to the most-specific registered application root, validates the destination root-relative path and computes a streaming SHA-256/byte-length fingerprint without creating directories, copying bytes or deleting the source. | Four host tests cover Documents/Inbox specificity, Watch staging, unmanaged sources and directory refusal. No production caller is wired. |
| Restartable background media reconciliation | Schema v4 persists `sourceTransferID` with each transfer asset. `SQLiteMediaBackgroundReconciler` serializes a bounded pass over pending/failed operations and completed operations without receipts, verifies already-published destinations before recording committed receipts and emits progress. Source retention remains an explicit follow-up. | Four host tests cover source identity across reopen, queued background copying with progress, receipt completion after reopen and changed-destination refusal. Production scheduling and caller wiring remain open. |
| SQLite read adapter | `SQLiteLibraryRepository` reads all six isolated tables through `SQLiteLibraryStore` and maps database dates, booleans, blobs and links into the same value types. | Imports the closed synthetic snapshot into a temporary file, verifies all six projections, and separately verifies an empty pre-import database. |
| Typed settings boundary | `LibrarySettingValue` and `LibrarySettingsSnapshot` allow only string, integer, finite real, bool, data and date values. `UserDefaultsLibrarySettingsStore` reads/writes an explicit allowlist; `LibrarySettingsCatalog.readMigratableSettings` now requires the app-owned source-key inventory and fails closed on unclassified keys; `SQLiteLibrarySettingsStore` applies the same allowlist over schema-v2 `library_settings` and records its committed insert/update in the v3 change log. `LibrarySettingsSourceInventory` explicitly records the reviewed main-defaults keys, the separate Action Button app-group key, and dynamic legacy-key prefixes. The catalog exposes only the blocking-metadata subset to a future reader and validates finite values, reviewed ranges/enums and endpoint credentials. | Host tests round-trip all six value kinds, verify six durable inserts and six durable updates, reject out-of-catalog/non-migratable/type-mismatched/invalid values, reject an unclassified source key, require the exact source inventory/catalog match and prove unrelated defaults are untouched. Startup wiring, source-drift checks and platform normalization are still open. |
| Recording rename command | `LibraryRecordingRenameCommand` addresses a row by legacy ID or storage ID, applies the existing `[Watch]` normalization, and can require an expected `lastModified`. Core Data and SQLite adapters return the committed snapshot or explicit not-found, ambiguous, stale or write errors. | Host tests cover SQLite commit and stale rejection; app-hosted contract coverage checks the Core Data commit. The display-name-only `AudioPlayerView` caller uses the Core Data adapter; file-owning AI rename remains outside this command pending a journaled file boundary. |
| Durable observation cursor | `LibraryObservation` exposes a global revision and ordered `LibraryChange` values. `SQLiteLibraryStore` persists `library_changes` in schema v3 and the SQLite repository emits recording/settings events in the same transaction as those writes. `CoreDataLibraryObservation` reads retained `NSPersistentHistory` transactions with hashed object-URI identities, and durable `PersistenceController` stores enable history tracking. `LibraryObservationSubscription` anchors before the initial snapshot, validates contiguous change batches and owns explicit cancellation. | Host tests reject negative/ahead cursors, verify exact rename events survive database reopen, upgrade a disposable v2 store to v3, exercise Core Data insert/update/delete history while filtering an unrelated entity, and exercise subscription across a commit and cancellation. Lifecycle/startup wiring, history retention/purge policy and the remaining write commands are still open. |

This is still a pre-cutover boundary, not production migration evidence. The
next inventory update must finish platform normalization and source-drift checks,
connect the observation contract and the isolated coordinator to
the startup contract, expand command/error coverage, and add production
final production-root selection/source-retention scheduling and Watch/share
caller integration before production services can depend on the repository.
