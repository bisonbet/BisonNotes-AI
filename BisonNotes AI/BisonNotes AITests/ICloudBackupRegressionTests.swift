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
    }

    override func tearDownWithError() throws {
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
        XCTAssertFalse(iCloudStorageManager.backedUpSettingsKeys.contains(KeychainSecretStore.awsCredentials))
        XCTAssertTrue(manager.isSensitiveSettingKey("openAIAPIKey"))
        XCTAssertTrue(manager.isSensitiveSettingKey("awsSecretAccessKey"))
        XCTAssertTrue(manager.isSensitiveSettingKey("awsBedrockSessionToken"))
        XCTAssertFalse(manager.isSensitiveSettingKey("openAISummarizationMaxTokens"))
    }

    func testProductionSchemaDiagnosticProducesActionableError() {
        let diagnostic = "Cannot create new type CD_BackupRecording in production schema"

        XCTAssertTrue(iCloudStorageManager.isMissingProductionSchemaDiagnostic(diagnostic))

        let error = iCloudStorageManager.cloudBackupProductionSchemaError(recordType: "CD_BackupRecording")
        XCTAssertEqual(error.domain, "iCloudStorageManager")
        XCTAssertTrue(error.localizedDescription.contains("CloudKit production schema update"))
        XCTAssertTrue(error.localizedDescription.contains("iCloud.Bison-Networking.BisonNotes-AI"))
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
