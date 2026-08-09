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
        XCTAssertEqual(iCloudManager.pendingCloudDeletionCountForTesting, 1)
    }

    func testDeletingSummaryQueuesPendingiCloudRemovalWhenSyncIsUnavailable() async throws {
        let recordingId = try createCompleteRecording(named: "Delete Summary")
        let summaryId = try XCTUnwrap(appCoordinator.getSummary(for: recordingId)?.id)
        let iCloudManager = SummaryManager.shared.getiCloudManager()

        try await appCoordinator.deleteSummary(id: summaryId)

        XCTAssertNotNil(appCoordinator.coreDataManager.getRecording(id: recordingId))
        XCTAssertNil(appCoordinator.getSummary(for: recordingId))
        XCTAssertEqual(iCloudManager.pendingSummaryRemovalCountForTesting, 1)
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
}
