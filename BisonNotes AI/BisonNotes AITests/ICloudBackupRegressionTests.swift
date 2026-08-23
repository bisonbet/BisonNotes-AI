//
//  ICloudBackupRegressionTests.swift
//  BisonNotes AITests
//

import XCTest
@testable import BisonNotes_AI

@MainActor
final class ICloudBackupRegressionTests: XCTestCase {
    private var persistenceController: PersistenceController!
    private var appCoordinator: AppDataCoordinator!
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        UserDefaults.standard.set(false, forKey: "iCloudSyncEnabled")
        persistenceController = PersistenceController(inMemory: true)
        appCoordinator = AppDataCoordinator(persistenceController: persistenceController)
        tempDirectory = try TestHelpers.createTemporaryDirectory()
        let iCloudManager = SummaryManager.shared.getiCloudManager()
        iCloudManager.isEnabled = false
        iCloudManager.clearPendingCloudMutationsForTesting()
    }

    override func tearDownWithError() throws {
        SummaryManager.shared.getiCloudManager().clearPendingCloudMutationsForTesting()
        if let tempDirectory {
            try? TestHelpers.cleanupTemporaryDirectory(tempDirectory)
        }
        tempDirectory = nil
        appCoordinator = nil
        persistenceController = nil
    }

    func testBackupSourceSelectionExcludesKeepOnThisDeviceContent() throws {
        let syncableId = try createCompleteRecording(named: "Syncable")
        let localOnlyId = try createCompleteRecording(named: "Local Only")
        try appCoordinator.coreDataManager.updateCloudSyncDisabled(for: localOnlyId, disabled: true)

        let selection = iCloudStorageManager.backupSourceSelection(from: appCoordinator.coreDataManager)

        XCTAssertEqual(selection.excludedRecordingIds, Set([localOnlyId]))
        XCTAssertTrue(selection.recordings.contains { $0.id == syncableId })
        XCTAssertFalse(selection.recordings.contains { $0.id == localOnlyId })
        XCTAssertEqual(selection.transcripts.compactMap(\.recordingId), [syncableId])
        XCTAssertEqual(selection.summaries.compactMap(\.recordingId), [syncableId])
    }

    func testSensitiveCredentialSettingsAreNotEligibleForSettingsBackup() {
        let manager = iCloudStorageManager()

        XCTAssertFalse(iCloudStorageManager.backedUpSettingsKeys.contains(KeychainSecretStore.openAIAPIKey))
        XCTAssertTrue(manager.isSensitiveSettingKey("openAIAPIKey"))
        XCTAssertTrue(manager.isSensitiveSettingKey("secretAccessKey"))
        XCTAssertFalse(manager.isSensitiveSettingKey("compatibleAPIMaxTokens"))
    }

    func testLocalSpeakerBackupIncludesChoicesButExcludesLifecycleState() {
        let keys = Set(iCloudStorageManager.backedUpSettingsKeys)

        XCTAssertTrue(keys.contains(FluidAudioModelInfo.SettingsKeys.localSpeakerLabelsEnabled))
        XCTAssertTrue(keys.contains(FluidAudioModelInfo.SettingsKeys.selectedLocalSpeakerLabelMethod))
        XCTAssertFalse(keys.contains("localSpeakerLabelsModelReady"))
        XCTAssertFalse(keys.contains("localSpeakerLabelsDownloadProgress"))
        XCTAssertFalse(keys.contains("localSpeakerLabelsCachePath"))
    }

    func testRemovedAWSSettingsAreRecognized() {
        XCTAssertTrue(KeychainSecretStore.isLegacyAWSSettingKey("AWSCredentials"))
        XCTAssertTrue(KeychainSecretStore.isLegacyAWSSettingKey("awsBedrockModel"))
        XCTAssertTrue(KeychainSecretStore.isLegacyAWSSettingKey("enableAWSTranscribe"))
        XCTAssertFalse(KeychainSecretStore.isLegacyAWSSettingKey("openAICompatibleModel"))
    }

    func testProductionSchemaDiagnosticProducesActionableError() {
        let diagnostic = "Cannot create new type CD_BackupRecording in production schema"

        XCTAssertTrue(iCloudStorageManager.isMissingProductionSchemaDiagnostic(diagnostic))

        let error = iCloudStorageManager.cloudBackupProductionSchemaError(recordType: "CD_BackupRecording")
        XCTAssertEqual(error.domain, "iCloudStorageManager")
        XCTAssertTrue(error.localizedDescription.contains("CloudKit production schema update"))
        XCTAssertTrue(error.localizedDescription.contains("iCloud.Bison-Networking.BisonNotes-AI"))
    }

    func testDeletingRecordingQueuesPendingiCloudTombstoneWhenSyncIsUnavailable() throws {
        let recordingId = try createCompleteRecording(named: "Delete Me")
        let iCloudManager = SummaryManager.shared.getiCloudManager()

        appCoordinator.deleteRecording(id: recordingId)

        XCTAssertNil(appCoordinator.coreDataManager.getRecording(id: recordingId))
        XCTAssertNil(appCoordinator.coreDataManager.getTranscript(for: recordingId))
        XCTAssertNil(appCoordinator.coreDataManager.getSummary(for: recordingId))
        XCTAssertEqual(iCloudManager.pendingCloudDeletionCountForTesting, 1)
    }

    func testDeletingSummaryQueuesPendingiCloudRemovalWhenSyncIsUnavailable() async throws {
        let recordingId = try createCompleteRecording(named: "Delete Summary")
        let summaryId = try XCTUnwrap(appCoordinator.getSummary(for: recordingId)?.id)
        let iCloudManager = SummaryManager.shared.getiCloudManager()

        try await appCoordinator.deleteSummary(id: summaryId)

        XCTAssertNotNil(appCoordinator.coreDataManager.getRecording(id: recordingId))
        XCTAssertNil(appCoordinator.getSummary(for: recordingId))
        XCTAssertNil(appCoordinator.coreDataManager.getRecording(id: recordingId)?.summaryId)
        XCTAssertEqual(
            appCoordinator.coreDataManager.getRecording(id: recordingId)?.summaryStatus,
            ProcessingStatus.notStarted.rawValue
        )
        XCTAssertEqual(iCloudManager.pendingSummaryRemovalCountForTesting, 1)
    }

    func testDeletingTranscriptIndependentlyKeepsRecordingAndSummary() async throws {
        let recordingId = try createCompleteRecording(named: "Delete Transcript Only")
        let transcriptId = try XCTUnwrap(appCoordinator.getTranscript(for: recordingId)?.id)
        let iCloudManager = SummaryManager.shared.getiCloudManager()

        try await appCoordinator.deleteTranscript(id: transcriptId)

        let recording = try XCTUnwrap(appCoordinator.coreDataManager.getRecording(id: recordingId))
        XCTAssertNil(appCoordinator.coreDataManager.getTranscript(id: transcriptId))
        XCTAssertNil(recording.transcript)
        XCTAssertNil(recording.transcriptId)
        XCTAssertEqual(recording.transcriptionStatus, ProcessingStatus.notStarted.rawValue)

        let summary = try XCTUnwrap(appCoordinator.getSummary(for: recordingId))
        XCTAssertNil(summary.transcript)
        XCTAssertNil(summary.transcriptId)
        XCTAssertEqual(iCloudManager.pendingTranscriptRemovalCountForTesting, 1)
    }

    func testDeletionMarkerNamesRemainDistinctForEachContentKind() throws {
        let manager = iCloudStorageManager()
        let recordingId = UUID()
        let transcriptId = UUID()
        let summaryId = UUID()
        let parentRecordingId = UUID()

        let recordingName = manager.deletionMarkerRecordNameForTesting(kind: .recording, id: recordingId)
        let transcriptName = manager.deletionMarkerRecordNameForTesting(kind: .transcript, id: transcriptId)
        let summaryName = manager.deletionMarkerRecordNameForTesting(kind: .summary, id: summaryId)

        XCTAssertNotEqual(recordingName, transcriptName)
        XCTAssertNotEqual(recordingName, summaryName)
        XCTAssertEqual(manager.decodeDeletionTargetForTesting(recordName: recordingName)?.kind, .recording)
        XCTAssertEqual(manager.decodeDeletionTargetForTesting(recordName: recordingName)?.id, recordingId)
        XCTAssertEqual(manager.decodeDeletionTargetForTesting(recordName: transcriptName)?.kind, .transcript)
        XCTAssertEqual(manager.decodeDeletionTargetForTesting(recordName: transcriptName)?.id, transcriptId)
        XCTAssertEqual(
            manager.decodeDeletionTargetForTesting(recordName: summaryName, recordingId: parentRecordingId)?.kind,
            .summary
        )
        XCTAssertEqual(
            manager.decodeDeletionTargetForTesting(recordName: summaryName, recordingId: parentRecordingId)?.recordingId,
            parentRecordingId
        )
    }

    func testLocalOnlyToggleQueuesAndClearsPendingCloudRemovalWhenSyncIsUnavailable() async throws {
        let recordingId = try createCompleteRecording(named: "Local Only Pending Removal")
        let iCloudManager = SummaryManager.shared.getiCloudManager()

        try await appCoordinator.setCloudSyncDisabled(for: recordingId, disabled: true)

        XCTAssertEqual(appCoordinator.coreDataManager.getRecording(id: recordingId)?.isCloudSyncDisabled, true)
        XCTAssertEqual(iCloudManager.pendingLocalOnlyRemovalCountForTesting, 1)

        try await appCoordinator.setCloudSyncDisabled(for: recordingId, disabled: false)

        XCTAssertEqual(appCoordinator.coreDataManager.getRecording(id: recordingId)?.isCloudSyncDisabled, false)
        XCTAssertEqual(iCloudManager.pendingLocalOnlyRemovalCountForTesting, 0)
    }

    func testSummaryManagerReadsAuthoritativeSummariesFromCoreData() throws {
        let recordingId = try createCompleteRecording(named: "Core Data Summary Source")
        let expectedSummaryId = try XCTUnwrap(appCoordinator.getSummary(for: recordingId)?.id)

        let summaries = SummaryManager.shared.getAuthoritativeSummaryData()
        XCTAssertEqual(summaries.map(\.id), [expectedSummaryId])

        let statistics = SummaryManager.shared.getSummaryStatistics()
        XCTAssertEqual(statistics.totalSummaries, 1)
    }

    func testOrphanedSummaryUpsertIsIdempotent() throws {
        let summary = EnhancedSummaryData(
            recordingURL: tempDirectory.appendingPathComponent("cloud-only.m4a"),
            recordingName: "Cloud-only summary",
            recordingDate: Date(timeIntervalSince1970: 1_770_000_000),
            summary: "A cloud-only summary retained locally until its recording can be restored.",
            aiEngine: "Fixture",
            aiModel: "cloud-fixture",
            originalLength: 80
        )

        let firstID = try appCoordinator.coreDataManager.upsertOrphanedSummary(summary)
        let updatedSummary = EnhancedSummaryData(
            id: summary.id,
            recordingId: summary.recordingId,
            recordingURL: summary.recordingURL,
            recordingName: "Updated cloud-only summary",
            recordingDate: summary.recordingDate.addingTimeInterval(60),
            summary: "Updated cloud content must replace the prior orphaned summary without creating another row.",
            aiEngine: "Fixture",
            aiModel: "cloud-fixture-v2",
            originalLength: 90,
            generatedAt: summary.generatedAt.addingTimeInterval(60)
        )
        let secondID = try appCoordinator.coreDataManager.upsertOrphanedSummary(updatedSummary)

        XCTAssertEqual(firstID, summary.id)
        XCTAssertEqual(secondID, summary.id)
        XCTAssertEqual(appCoordinator.getAllSummaries().count, 1)
        XCTAssertEqual(appCoordinator.getAllSummaries().first?.id, summary.id)
        XCTAssertEqual(appCoordinator.getAllSummaries().first?.summary, updatedSummary.summary)
        let storedMethod = try XCTUnwrap(appCoordinator.getAllSummaries().first?.aiMethod)
        let decodedMethod = SummaryMetadataCodec.decode(storedMethod)
        XCTAssertEqual(decodedMethod.engine, "Fixture")
        XCTAssertEqual(decodedMethod.model, "cloud-fixture-v2")
        XCTAssertEqual(appCoordinator.getAllSummaries().first?.recording?.recordingName, "Updated cloud-only summary")
    }

    func testIncomingCloudIdentityReplacesExistingLocalSummaryIdentity() throws {
        let recordingId = try createCompleteRecording(named: "Cloud Identity")
        let existingSummaryId = try XCTUnwrap(appCoordinator.getSummary(for: recordingId)?.id)
        let recording = try XCTUnwrap(appCoordinator.getRecording(id: recordingId))
        let recordingURL = tempDirectory.appendingPathComponent("cloud-identity.m4a")
        let cloudSummaryId = UUID()
        let cloudSummary = EnhancedSummaryData(
            id: cloudSummaryId,
            recordingId: recordingId,
            transcriptId: recording.transcriptId,
            recordingURL: recordingURL,
            recordingName: recording.recordingName ?? "Cloud Identity",
            recordingDate: recording.recordingDate ?? Date(),
            summary: "The restored cloud summary should become the authoritative local identity and content.",
            aiEngine: "Cloud",
            aiModel: "cloud-authoritative",
            originalLength: 100
        )

        let restoredId = try appCoordinator.upsertSummary(
            cloudSummary,
            for: recordingId,
            transcriptId: recording.transcriptId,
            identityPolicy: .incomingSummary
        )

        XCTAssertEqual(restoredId, cloudSummaryId)
        XCTAssertNil(appCoordinator.coreDataManager.getSummary(id: existingSummaryId))
        XCTAssertEqual(appCoordinator.getAllSummaries().count, 1)
        XCTAssertEqual(appCoordinator.getSummary(for: recordingId)?.id, cloudSummaryId)
        XCTAssertEqual(appCoordinator.getSummary(for: recordingId)?.summary, cloudSummary.summary)
    }

    // MARK: - Multi-Device Arbitration

    func testStaleLocalVersionDoesNotOverwriteNewerCloudRecord() {
        let older = Date(timeIntervalSince1970: 1_770_000_000)
        let newer = older.addingTimeInterval(3_600)

        XCTAssertFalse(
            iCloudStorageManager.shouldUploadLocalVersion(localTimestamp: older, cloudTimestamp: newer)
        )
        XCTAssertTrue(
            iCloudStorageManager.shouldUploadLocalVersion(localTimestamp: newer, cloudTimestamp: older)
        )
    }

    func testEqualTimestampsStillUploadSoOtherFieldChangesPropagate() {
        let timestamp = Date(timeIntervalSince1970: 1_770_000_000)

        XCTAssertTrue(
            iCloudStorageManager.shouldUploadLocalVersion(localTimestamp: timestamp, cloudTimestamp: timestamp)
        )
    }

    func testUnknownTimestampsFallBackToTheLegacyOverwriteBehaviour() {
        let timestamp = Date(timeIntervalSince1970: 1_770_000_000)

        XCTAssertTrue(
            iCloudStorageManager.shouldUploadLocalVersion(localTimestamp: nil, cloudTimestamp: timestamp)
        )
        XCTAssertTrue(
            iCloudStorageManager.shouldUploadLocalVersion(localTimestamp: timestamp, cloudTimestamp: nil)
        )
        XCTAssertTrue(
            iCloudStorageManager.shouldApplyCloudVersion(cloudTimestamp: nil, localTimestamp: timestamp)
        )
        XCTAssertTrue(
            iCloudStorageManager.shouldApplyCloudVersion(cloudTimestamp: timestamp, localTimestamp: nil)
        )
    }

    func testStaleCloudRecordDoesNotOverwriteNewerLocalRow() {
        let older = Date(timeIntervalSince1970: 1_770_000_000)
        let newer = older.addingTimeInterval(3_600)

        XCTAssertFalse(
            iCloudStorageManager.shouldApplyCloudVersion(cloudTimestamp: older, localTimestamp: newer)
        )
        XCTAssertTrue(
            iCloudStorageManager.shouldApplyCloudVersion(cloudTimestamp: newer, localTimestamp: older)
        )
        XCTAssertTrue(
            iCloudStorageManager.shouldApplyCloudVersion(cloudTimestamp: older, localTimestamp: older)
        )
    }

    func testArbitrationConvergesRegardlessOfWhichDeviceSyncsLast() {
        let deviceAEdit = Date(timeIntervalSince1970: 1_770_000_000)
        let deviceBEdit = deviceAEdit.addingTimeInterval(600)

        // Device B edited later and syncs first, so the cloud holds B's version.
        XCTAssertTrue(
            iCloudStorageManager.shouldUploadLocalVersion(localTimestamp: deviceBEdit, cloudTimestamp: deviceAEdit)
        )
        // Device A syncs afterwards: it must neither publish nor keep its older edit.
        XCTAssertFalse(
            iCloudStorageManager.shouldUploadLocalVersion(localTimestamp: deviceAEdit, cloudTimestamp: deviceBEdit)
        )
        XCTAssertTrue(
            iCloudStorageManager.shouldApplyCloudVersion(cloudTimestamp: deviceBEdit, localTimestamp: deviceAEdit)
        )
    }

    // MARK: - Deletion Arbitration

    func testDeletionMarkerKeepsTheEarliestClaimedDeletionTime() {
        let deletedOnDeviceA = Date(timeIntervalSince1970: 1_770_000_000)
        let flushedLater = deletedOnDeviceA.addingTimeInterval(86_400)

        XCTAssertEqual(
            iCloudStorageManager.resolvedDeletionTimestamp(existing: nil, requested: deletedOnDeviceA),
            deletedOnDeviceA
        )
        XCTAssertEqual(
            iCloudStorageManager.resolvedDeletionTimestamp(existing: flushedLater, requested: deletedOnDeviceA),
            deletedOnDeviceA
        )
        XCTAssertEqual(
            iCloudStorageManager.resolvedDeletionTimestamp(existing: deletedOnDeviceA, requested: flushedLater),
            deletedOnDeviceA
        )
    }

    func testItemEditedAfterARemoteDeleteIsKeptInsteadOfDeleted() {
        let deletedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let editedAfterwards = deletedAt.addingTimeInterval(600)

        XCTAssertTrue(
            iCloudStorageManager.shouldReviveLocallyModifiedItem(
                localTimestamp: editedAfterwards,
                deletedAt: deletedAt
            )
        )
    }

    func testUntouchedItemAndCloseRacesStillHonourTheDelete() {
        let deletedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let untouched = deletedAt.addingTimeInterval(-600)
        let withinGracePeriod = deletedAt.addingTimeInterval(
            iCloudStorageManager.deletionReviveGraceInterval / 2
        )

        XCTAssertFalse(
            iCloudStorageManager.shouldReviveLocallyModifiedItem(localTimestamp: untouched, deletedAt: deletedAt)
        )
        XCTAssertFalse(
            iCloudStorageManager.shouldReviveLocallyModifiedItem(
                localTimestamp: withinGracePeriod,
                deletedAt: deletedAt
            )
        )
        XCTAssertFalse(
            iCloudStorageManager.shouldReviveLocallyModifiedItem(localTimestamp: nil, deletedAt: deletedAt)
        )
    }

    func testMarkerWithoutADeletionTimeNeverRevivesAnItem() {
        XCTAssertFalse(
            iCloudStorageManager.shouldReviveLocallyModifiedItem(
                localTimestamp: Date(timeIntervalSince1970: 1_770_000_000),
                deletedAt: .distantPast
            )
        )
    }

    func testQueuedDeletionRecordsWhenTheUserDeletedNotWhenItFlushes() throws {
        let recordingId = try createCompleteRecording(named: "Queued Deletion Time")
        let iCloudManager = SummaryManager.shared.getiCloudManager()
        let deletedAt = Date(timeIntervalSince1970: 1_770_000_000)

        iCloudManager.enqueueRecordingDeletionForiCloud(
            recordingId: recordingId,
            transcriptIds: [],
            summaryIds: [],
            requestedAt: deletedAt
        )

        XCTAssertEqual(iCloudManager.pendingCloudDeletionRequestedAtForTesting(recordingId: recordingId), deletedAt)
    }

    // MARK: - Duplicate Convergence

    private struct DuplicateFixture {
        let recordingId: UUID?
        let timestamp: Date?
        let id: UUID?
    }

    private func latestFixture(_ items: [DuplicateFixture]) -> (kept: [DuplicateFixture], superseded: [DuplicateFixture]) {
        iCloudStorageManager.latestPerRecording(
            items,
            recordingId: { $0.recordingId },
            timestamp: { $0.timestamp },
            identifier: { $0.id }
        )
    }

    func testLatestPerRecordingKeepsTheNewestRowAndReportsTheRest() {
        let recordingId = UUID()
        let older = DuplicateFixture(
            recordingId: recordingId,
            timestamp: Date(timeIntervalSince1970: 1_770_000_000),
            id: UUID()
        )
        let newer = DuplicateFixture(
            recordingId: recordingId,
            timestamp: Date(timeIntervalSince1970: 1_770_003_600),
            id: UUID()
        )

        let result = latestFixture([older, newer])

        XCTAssertEqual(result.kept.compactMap(\.id), [newer.id])
        XCTAssertEqual(result.superseded.compactMap(\.id), [older.id])
    }

    func testLatestPerRecordingBreaksTimestampTiesDeterministically() {
        let recordingId = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_770_000_000)
        let lowIdentifier = DuplicateFixture(
            recordingId: recordingId,
            timestamp: timestamp,
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")
        )
        let highIdentifier = DuplicateFixture(
            recordingId: recordingId,
            timestamp: timestamp,
            id: UUID(uuidString: "FF000000-0000-0000-0000-000000000000")
        )

        // Same winner no matter which order the rows arrive in, so two devices agree.
        XCTAssertEqual(latestFixture([lowIdentifier, highIdentifier]).kept.compactMap(\.id), [highIdentifier.id])
        XCTAssertEqual(latestFixture([highIdentifier, lowIdentifier]).kept.compactMap(\.id), [highIdentifier.id])
    }

    func testLatestPerRecordingKeepsRowsThatBelongToNoRecording() {
        let orphan = DuplicateFixture(recordingId: nil, timestamp: nil, id: UUID())

        let result = latestFixture([orphan])

        XCTAssertEqual(result.kept.compactMap(\.id), [orphan.id])
        XCTAssertTrue(result.superseded.isEmpty)
    }

    func testBackupSelectionUploadsOnlyTheCurrentRowPerRecording() throws {
        let recordingId = try createCompleteRecording(named: "Duplicate Upload")
        let currentTranscriptId = try XCTUnwrap(appCoordinator.getTranscript(for: recordingId)?.id)
        let currentSummaryId = try XCTUnwrap(appCoordinator.getSummary(for: recordingId)?.id)
        let staleTranscriptId = try insertDuplicateTranscript(
            for: recordingId,
            createdAt: Date(timeIntervalSince1970: 1_600_000_000)
        )
        let staleSummaryId = try insertDuplicateSummary(
            for: recordingId,
            generatedAt: Date(timeIntervalSince1970: 1_600_000_000)
        )

        let selection = iCloudStorageManager.backupSourceSelection(from: appCoordinator.coreDataManager)

        XCTAssertEqual(selection.transcripts.compactMap(\.id), [currentTranscriptId])
        XCTAssertEqual(selection.summaries.compactMap(\.id), [currentSummaryId])
        XCTAssertEqual(selection.supersededTranscripts.compactMap(\.id), [staleTranscriptId])
        XCTAssertEqual(selection.supersededSummaries.compactMap(\.id), [staleSummaryId])
    }

    func testPruningRemovesSupersededRowsWithoutWritingCloudTombstones() throws {
        let recordingId = try createCompleteRecording(named: "Duplicate Prune")
        let currentTranscriptId = try XCTUnwrap(appCoordinator.getTranscript(for: recordingId)?.id)
        let staleTranscriptId = try insertDuplicateTranscript(
            for: recordingId,
            createdAt: Date(timeIntervalSince1970: 1_600_000_000)
        )
        let staleSummaryId = try insertDuplicateSummary(
            for: recordingId,
            generatedAt: Date(timeIntervalSince1970: 1_600_000_000)
        )
        let iCloudManager = SummaryManager.shared.getiCloudManager()

        let pruned = iCloudManager.pruneSupersededLocalDuplicates(appCoordinator: appCoordinator)

        XCTAssertEqual(pruned.transcripts, 1)
        XCTAssertEqual(pruned.summaries, 1)
        XCTAssertNil(appCoordinator.coreDataManager.getTranscript(id: staleTranscriptId))
        XCTAssertNil(appCoordinator.coreDataManager.getSummary(id: staleSummaryId))
        XCTAssertNotNil(appCoordinator.coreDataManager.getTranscript(id: currentTranscriptId))
        // A convergent rule needs no tombstones: every device reaches the same winner.
        XCTAssertEqual(iCloudManager.pendingTranscriptRemovalCountForTesting, 0)
        XCTAssertEqual(iCloudManager.pendingSummaryRemovalCountForTesting, 0)
    }

    func testPruningNeverRemovesTheRowARecordingStillPointsAt() throws {
        let recordingId = try createCompleteRecording(named: "Referenced Duplicate")
        let referencedTranscriptId = try XCTUnwrap(appCoordinator.getTranscript(for: recordingId)?.id)
        // Newer duplicate the recording has not been repointed at yet.
        let newerTranscriptId = try insertDuplicateTranscript(
            for: recordingId,
            createdAt: Date(timeIntervalSince1970: 4_000_000_000)
        )

        let pruned = SummaryManager.shared.getiCloudManager()
            .pruneSupersededLocalDuplicates(appCoordinator: appCoordinator)

        XCTAssertEqual(pruned.transcripts, 0)
        XCTAssertNotNil(appCoordinator.coreDataManager.getTranscript(id: referencedTranscriptId))
        XCTAssertNotNil(appCoordinator.coreDataManager.getTranscript(id: newerTranscriptId))
    }

    @discardableResult
    private func insertDuplicateTranscript(for recordingId: UUID, createdAt: Date) throws -> UUID {
        let context = appCoordinator.coreDataManager.managedObjectContext
        let duplicate = TranscriptEntry(context: context)
        let duplicateId = UUID()
        duplicate.id = duplicateId
        duplicate.recordingId = recordingId
        duplicate.createdAt = createdAt
        duplicate.lastModified = createdAt
        duplicate.engine = "Fixture"
        duplicate.segments = "[]"
        try context.save()
        return duplicateId
    }

    @discardableResult
    private func insertDuplicateSummary(for recordingId: UUID, generatedAt: Date) throws -> UUID {
        let context = appCoordinator.coreDataManager.managedObjectContext
        let duplicate = SummaryEntry(context: context)
        let duplicateId = UUID()
        duplicate.id = duplicateId
        duplicate.recordingId = recordingId
        duplicate.summary = "A superseded duplicate summary row left behind by an earlier run."
        duplicate.aiMethod = "fixture"
        duplicate.generatedAt = generatedAt
        try context.save()
        return duplicateId
    }

    private func createCompleteRecording(named name: String) throws -> UUID {
        let audioURL = tempDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try TestHelpers.createMockAudioFile(at: audioURL)
        let recordingId = appCoordinator.addRecording(
            url: audioURL,
            name: name,
            date: Date(),
            fileSize: 1_024,
            duration: 30,
            quality: .whisperOptimized
        )
        let transcriptId = try XCTUnwrap(appCoordinator.addTranscript(
            for: recordingId,
            segments: [TranscriptSegment(speaker: "Speaker 1", text: "Transcript for \(name)", startTime: 0, endTime: 2)]
        ))
        _ = appCoordinator.addSummary(
            for: recordingId,
            transcriptId: transcriptId,
            summary: "Summary for \(name) with enough content to satisfy validation rules and exercise backup selection.",
            aiModel: "fixture",
            originalLength: 60
        )
        return recordingId
    }

    // MARK: - Local / Cloud Dedupe Parity

    /// `latestPerRecording` deduplicates the local rows and
    /// `isBackupRecordNewer` deduplicates the cloud records. Both must name the
    /// same winner from the same facts; if they disagree each device keeps
    /// re-uploading what the other just deleted.
    private struct DedupeRow {
        let id: UUID
        let timestamp: Date?
    }

    private func localWinner(_ rows: [DedupeRow], recordingId: UUID) -> UUID? {
        let result = iCloudStorageManager.latestPerRecording(
            rows,
            recordingId: { _ in recordingId },
            timestamp: { $0.timestamp },
            identifier: { $0.id }
        )
        return result.kept.first?.id
    }

    private func cloudWinner(_ rows: [DedupeRow], prefix: String) -> UUID? {
        // Mirrors resolveLatestRecordsPerRecording's fold over one record type,
        // whose record names all share that type's constant prefix.
        var winner: DedupeRow?
        for row in rows {
            guard let current = winner else {
                winner = row
                continue
            }
            let isNewer = iCloudStorageManager.isBackupRecordNewer(
                candidateTimestamp: row.timestamp ?? .distantPast,
                currentTimestamp: current.timestamp ?? .distantPast,
                candidateRecordName: prefix + row.id.uuidString,
                currentRecordName: prefix + current.id.uuidString
            )
            if isNewer { winner = row }
        }
        return winner?.id
    }

    func testLocalAndCloudDedupeAgreeOnTheWinner() {
        let recordingId = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        // Distinct timestamps, deliberately not in input order.
        let distinct = [
            DedupeRow(id: UUID(), timestamp: base),
            DedupeRow(id: UUID(), timestamp: base.addingTimeInterval(90)),
            DedupeRow(id: UUID(), timestamp: base.addingTimeInterval(45))
        ]
        XCTAssertEqual(
            localWinner(distinct, recordingId: recordingId),
            cloudWinner(distinct, prefix: "summary-backup-"),
            "Newest row must win on both sides"
        )

        // Equal timestamps fall through to the identifier tie-breaker, which is
        // the case where a prefix mismatch would silently split the two rules.
        let tied = (0..<6).map { _ in DedupeRow(id: UUID(), timestamp: base) }
        XCTAssertEqual(
            localWinner(tied, recordingId: recordingId),
            cloudWinner(tied, prefix: "transcript-backup-"),
            "Tie-break must resolve identically under a per-type record-name prefix"
        )

        // A row with no timestamp must not out-rank a timestamped one on either side.
        let missing = [
            DedupeRow(id: UUID(), timestamp: nil),
            DedupeRow(id: UUID(), timestamp: base)
        ]
        XCTAssertEqual(
            localWinner(missing, recordingId: recordingId),
            cloudWinner(missing, prefix: "summary-backup-")
        )
        XCTAssertEqual(localWinner(missing, recordingId: recordingId), missing[1].id)
    }

    func testTieBreakerIsIndependentOfTheRecordNamePrefix() {
        // Record names are prefix + uuidString. A shared prefix must not change
        // the relative order, which is what lets the local rule compare bare
        // identifiers while the cloud rule compares full record names.
        let a = UUID()
        let b = UUID()
        let byIdentifier = a.uuidString > b.uuidString

        for prefix in ["", "summary-backup-", "transcript-backup-", "zzz"] {
            XCTAssertEqual(
                iCloudStorageManager.isBackupRecordNewer(
                    candidateTimestamp: .distantPast,
                    currentTimestamp: .distantPast,
                    candidateRecordName: prefix + a.uuidString,
                    currentRecordName: prefix + b.uuidString
                ),
                byIdentifier,
                "Prefix '\(prefix)' changed the tie-break outcome"
            )
        }
    }


    // MARK: - Transcript Relink Arbitration

    func testRelinkKeepsTheNewerTranscriptWhenTheCloudRowHasADifferentId() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let linkedId = UUID()

        // The other device deleted and retranscribed, so its backup carries an
        // older transcript under a brand-new id. Matching is by id, so there is
        // no local counterpart and nothing to compare — the recording must keep
        // pointing at the newer row it already has.
        XCTAssertFalse(
            iCloudStorageManager.shouldRelinkRecordingTranscript(
                candidateId: UUID(),
                candidateTimestamp: base,
                linkedId: linkedId,
                linkedTimestamp: base.addingTimeInterval(600)
            )
        )

        // The mirror image: the cloud row really is newer, so it should win.
        XCTAssertTrue(
            iCloudStorageManager.shouldRelinkRecordingTranscript(
                candidateId: UUID(),
                candidateTimestamp: base.addingTimeInterval(600),
                linkedId: linkedId,
                linkedTimestamp: base
            )
        )
    }

    func testRelinkAlwaysAcceptsTheRowTheRecordingAlreadyPointsAt() {
        let sameId = UUID()
        XCTAssertTrue(
            iCloudStorageManager.shouldRelinkRecordingTranscript(
                candidateId: sameId,
                candidateTimestamp: nil,
                linkedId: sameId,
                linkedTimestamp: Date()
            )
        )
    }

    func testRelinkTakesTheCandidateWhenNothingIsLinkedYet() {
        XCTAssertTrue(
            iCloudStorageManager.shouldRelinkRecordingTranscript(
                candidateId: UUID(),
                candidateTimestamp: nil,
                linkedId: nil,
                linkedTimestamp: nil
            )
        )
    }

    func testRelinkDefersToTheExistingLinkWhenEitherTimestampIsUnknown() {
        // Unlike the upload and restore rules, an unknown age here must not
        // overwrite a working link — there is a valid transcript in place and
        // nothing to justify swapping it out.
        XCTAssertFalse(
            iCloudStorageManager.shouldRelinkRecordingTranscript(
                candidateId: UUID(),
                candidateTimestamp: nil,
                linkedId: UUID(),
                linkedTimestamp: Date()
            )
        )
        XCTAssertFalse(
            iCloudStorageManager.shouldRelinkRecordingTranscript(
                candidateId: UUID(),
                candidateTimestamp: Date(),
                linkedId: UUID(),
                linkedTimestamp: nil
            )
        )
    }

}
