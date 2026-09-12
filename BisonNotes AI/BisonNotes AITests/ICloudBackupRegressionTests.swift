//
//  ICloudBackupRegressionTests.swift
//  BisonNotes AITests
//

import CloudKit
import CoreData
import XCTest
@testable import BisonNotes_AI

@MainActor
final class ICloudBackupRegressionTests: XCTestCase {
    private var persistenceController: PersistenceController!
    private var appCoordinator: AppDataCoordinator!
    private var tempDirectory: URL!

    private static let legacyMutationKeys = [
        "iCloudPendingDeletionMarkersV1",
        "iCloudPendingLocalOnlyRemovalsV1",
        "iCloudPendingSummaryRemovalsV1",
        "iCloudPendingTranscriptRemovalsV1",
        "iCloudPendingImportedAudioRemovalsV1"
    ]

    private struct LegacyDeletionMarkerFixture: Codable {
        let recordingId: UUID
        let transcriptIds: [UUID]
        let summaryIds: [UUID]
        let requestedAt: Date
    }

    private struct LegacyLocalOnlyRemovalFixture: Codable {
        let recordingId: UUID
        let requestedAt: Date
    }

    private struct LegacySummaryRemovalFixture: Codable {
        let summaryId: UUID
        let recordingId: UUID?
        let requestedAt: Date
    }

    private struct LegacyTranscriptRemovalFixture: Codable {
        let transcriptId: UUID
        let recordingId: UUID?
        let requestedAt: Date
    }

    private struct LegacyImportedAudioRemovalFixture: Codable {
        let recordingId: UUID
        let requestedAt: Date
    }

    private final class PersistentStoreLoadBox: @unchecked Sendable {
        var error: Error?
    }

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

    func testMissingQueryableIndexProducesAnActionableError() {
        // What CloudKit actually says, which names neither the index nor the fix.
        XCTAssertTrue(
            iCloudStorageManager.isMissingQueryableIndexDiagnostic(
                "Field 'recordName' is not marked queryable"
            )
        )
        XCTAssertTrue(iCloudStorageManager.isMissingQueryableIndexDiagnostic("'recordName' is not queryable"))
        XCTAssertFalse(iCloudStorageManager.isMissingQueryableIndexDiagnostic("Network unavailable"))

        let error = iCloudStorageManager.cloudBackupQueryableIndexError(recordType: "CD_BackupDeletion")
        XCTAssertTrue(error.localizedDescription.contains("CD_BackupDeletion"))
        let suggestion = (error.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String) ?? ""
        XCTAssertTrue(suggestion.contains("QUERYABLE"), "the message has to name the fix, not just the symptom")
        XCTAssertTrue(suggestion.lowercased().contains("recordname"))
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

    func testDeletingImportedRecordingWithoutTranscriptQueuesRecordingTombstone() throws {
        let audioURL = tempDirectory.appendingPathComponent("orphan-import.m4a")
        try TestHelpers.createMockAudioFile(at: audioURL)
        let recordingId = appCoordinator.addRecording(
            url: audioURL,
            name: "Orphan Imported Transcript",
            date: Date(),
            fileSize: 1_024,
            duration: 0.1,
            quality: .whisperOptimized
        )
        let recording = try XCTUnwrap(appCoordinator.getRecording(id: recordingId))
        recording.audioQuality = "imported"
        try appCoordinator.coreDataManager.saveContext()

        XCTAssertNil(appCoordinator.getTranscript(for: recordingId))

        appCoordinator.deleteRecording(id: recordingId)

        XCTAssertNil(appCoordinator.getRecording(id: recordingId))
        XCTAssertEqual(
            SummaryManager.shared.getiCloudManager().pendingCloudDeletionCountForTesting,
            1
        )
    }

    func testTranscriptLookupFallsBackToRecordingRelationship() throws {
        let recordingId = try createRecordingOnly(named: "Relationship Transcript")
        let context = appCoordinator.coreDataManager.managedObjectContext
        let transcript = TranscriptEntry(context: context)
        let transcriptId = UUID()
        transcript.id = transcriptId
        transcript.recording = appCoordinator.getRecording(id: recordingId)
        transcript.segments = "[]"
        transcript.createdAt = Date()
        transcript.lastModified = Date()
        try context.save()

        XCTAssertEqual(appCoordinator.getTranscript(for: recordingId)?.id, transcriptId)
    }

    func testFixingIncompletelyDeletedRecordingsDoesNotEnqueueACloudTombstone() throws {
        // A recording-only restore with audio excluded has no URL, transcript,
        // or summary. Launch housekeeping used to publish a user-deletion
        // marker for that shape and then wipe the CloudKit copy everywhere.
        let context = appCoordinator.coreDataManager.managedObjectContext
        let recording = RecordingEntry(context: context)
        let recordingId = UUID()
        recording.id = recordingId
        recording.recordingName = "Metadata-only leftover"
        recording.recordingDate = Date()
        recording.recordingURL = nil
        recording.duration = 0
        recording.fileSize = 0
        recording.lastModified = Date()
        try context.save()

        let iCloudManager = SummaryManager.shared.getiCloudManager()
        XCTAssertEqual(iCloudManager.pendingCloudDeletionCountForTesting, 0)

        let fixed = appCoordinator.fixIncompletelyDeletedRecordings()

        XCTAssertEqual(fixed, 1)
        XCTAssertNil(appCoordinator.coreDataManager.getRecording(id: recordingId))
        XCTAssertEqual(iCloudManager.pendingCloudDeletionCountForTesting, 0)
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

    func testDeletingUnavailableImportedTranscriptClearsStaleLinksAndQueuesCloudCleanup() async throws {
        let recordingId = try createRecordingOnly(named: "Unavailable Imported Transcript")
        let context = appCoordinator.coreDataManager.managedObjectContext
        let recording = try XCTUnwrap(appCoordinator.getRecording(id: recordingId))
        let orphanedTranscriptId = UUID()
        let summaryId = UUID()

        recording.audioQuality = "imported"
        recording.transcriptId = orphanedTranscriptId
        recording.transcriptionStatus = ProcessingStatus.completed.rawValue

        let summary = SummaryEntry(context: context)
        summary.id = summaryId
        summary.recording = recording
        summary.recordingId = recordingId
        summary.transcriptId = orphanedTranscriptId
        summary.summary = "A retained summary for an imported item whose transcript row is gone."
        summary.aiMethod = "fixture"
        summary.generatedAt = Date()
        recording.summary = summary
        recording.summaryId = summaryId
        try context.save()

        let iCloudManager = SummaryManager.shared.getiCloudManager()
        try await appCoordinator.deleteImportedTranscriptPreservingSummary(recordingId: recordingId)

        let remainingRecording = try XCTUnwrap(appCoordinator.getRecording(id: recordingId))
        let remainingSummary = try XCTUnwrap(appCoordinator.getSummary(for: recordingId))
        XCTAssertNil(remainingRecording.recordingURL)
        XCTAssertNil(remainingRecording.transcript)
        XCTAssertNil(remainingRecording.transcriptId)
        XCTAssertEqual(remainingRecording.transcriptionStatus, ProcessingStatus.notStarted.rawValue)
        XCTAssertNil(remainingSummary.transcript)
        XCTAssertNil(remainingSummary.transcriptId)
        XCTAssertEqual(remainingSummary.id, summaryId)
        XCTAssertEqual(iCloudManager.pendingTranscriptRemovalCountForTesting, 1)
        XCTAssertEqual(iCloudManager.pendingImportedAudioRemovalCountForTesting, 1)
    }

    func testDeletingImportedTranscriptRemovesEveryLinkedLocalTranscriptRow() async throws {
        let recordingId = try createRecordingOnly(named: "Duplicate imported transcript")
        let context = appCoordinator.coreDataManager.managedObjectContext
        let recording = try XCTUnwrap(appCoordinator.getRecording(id: recordingId))
        let currentTranscriptId = UUID()
        let staleTranscriptId = UUID()

        recording.audioQuality = "imported"
        recording.transcriptId = currentTranscriptId
        recording.transcriptionStatus = ProcessingStatus.completed.rawValue

        let currentTranscript = TranscriptEntry(context: context)
        currentTranscript.id = currentTranscriptId
        currentTranscript.recording = recording
        currentTranscript.recordingId = recordingId
        currentTranscript.segments = "[]"
        currentTranscript.createdAt = Date()
        currentTranscript.lastModified = Date()

        let staleTranscript = TranscriptEntry(context: context)
        staleTranscript.id = staleTranscriptId
        staleTranscript.recordingId = recordingId
        staleTranscript.segments = "[]"
        staleTranscript.createdAt = Date().addingTimeInterval(-60)
        staleTranscript.lastModified = Date().addingTimeInterval(-60)

        let summary = SummaryEntry(context: context)
        summary.id = UUID()
        summary.recording = recording
        summary.recordingId = recordingId
        summary.transcriptId = staleTranscriptId
        summary.summary = "Retained summary"
        summary.aiMethod = "fixture"
        summary.generatedAt = Date()
        recording.summary = summary
        recording.summaryId = summary.id
        try context.save()

        try await appCoordinator.deleteImportedTranscriptPreservingSummary(
            recordingId: recordingId,
            transcriptId: currentTranscriptId
        )

        XCTAssertNil(appCoordinator.coreDataManager.getTranscript(id: currentTranscriptId))
        XCTAssertNil(appCoordinator.coreDataManager.getTranscript(id: staleTranscriptId))
        XCTAssertNotNil(appCoordinator.getSummary(for: recordingId))
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

        // An imported-audio marker carries `recordingId`, so a decoder that fell
        // through to the recording branch would read it as a whole-recording
        // tombstone and delete the recording and its summary on every other device.
        // It has to be recognised by its own prefix, before that fallback.
        let importedAudioName = manager.deletionMarkerRecordNameForTesting(
            kind: .importedAudio,
            id: recordingId
        )
        XCTAssertNotEqual(importedAudioName, recordingName)
        let importedAudioTarget = manager.decodeDeletionTargetForTesting(
            recordName: importedAudioName,
            recordingId: recordingId
        )
        XCTAssertEqual(importedAudioTarget?.kind, .importedAudio)
        XCTAssertEqual(importedAudioTarget?.id, recordingId)
        XCTAssertEqual(importedAudioTarget?.recordingId, recordingId)
    }

    func testImportedAudioDeletionMarkerOmitsRecordingIdForLegacyClients() async throws {
        let harness = makeSyncEngineHarness()
        let recordingId = UUID()

        harness.manager.enqueueImportedAudioRemovalFromiCloud(recordingId: recordingId)
        _ = try await harness.manager.flushPendingiCloudMutations(appCoordinator: appCoordinator)

        let marker = try XCTUnwrap(
            harness.transport.record(
                named: "backup_deletion_importedaudio_\(recordingId.uuidString)"
            )
        )
        XCTAssertNil(
            marker["recordingId"],
            "Legacy clients interpret this field as a whole-recording tombstone"
        )

        let decoded = harness.manager.decodeDeletionTargetForTesting(
            recordName: marker.recordID.recordName,
            recordingId: nil
        )
        XCTAssertEqual(decoded?.kind, .importedAudio)
        XCTAssertEqual(decoded?.id, recordingId)
        XCTAssertEqual(decoded?.recordingId, recordingId)
    }

    /// Applying another device's imported-audio tombstone unlinks the placeholder
    /// and removes the file, but leaves the recording row and its summary standing.
    func testApplyingImportedAudioRemovalKeepsTheRecordingAndSummary() async throws {
        let recordingId = try createRecordingOnly(named: "Imported audio removal")
        let context = appCoordinator.coreDataManager.managedObjectContext
        let recording = try XCTUnwrap(appCoordinator.getRecording(id: recordingId))
        let audioURL = tempDirectory.appendingPathComponent("\(recordingId.uuidString).m4a")
        try Data("placeholder".utf8).write(to: audioURL)

        recording.audioQuality = "imported"
        recording.recordingURL = audioURL.path
        recording.lastModified = Date().addingTimeInterval(-3_600)

        let summary = SummaryEntry(context: context)
        summary.id = UUID()
        summary.recording = recording
        summary.recordingId = recordingId
        summary.summary = "Retained summary"
        summary.aiMethod = "fixture"
        summary.generatedAt = Date()
        recording.summary = summary
        recording.summaryId = summary.id
        try context.save()

        let deletedAt = Date()
        let cleared = try await appCoordinator.applyRemoteImportedAudioRemovalUsingRepository(
            id: recordingId,
            requestedAt: deletedAt
        )

        XCTAssertTrue(cleared)
        let remaining = try XCTUnwrap(appCoordinator.getRecording(id: recordingId))
        XCTAssertNil(remaining.recordingURL)
        XCTAssertEqual(remaining.lastModified, deletedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertNotNil(appCoordinator.getSummary(for: recordingId))

        // Idempotent: nothing left to unlink on a second application.
        let repeatedClear = try await appCoordinator.applyRemoteImportedAudioRemovalUsingRepository(
            id: recordingId,
            requestedAt: deletedAt
        )
        XCTAssertFalse(repeatedClear)
    }

    func testApplyingImportedAudioRemovalKeepsTheURLWhenMainFileRemovalFails() async throws {
        let recordingId = try createRecordingOnly(named: "Imported audio removal retry")
        let recording = try XCTUnwrap(appCoordinator.getRecording(id: recordingId))
        let blockingDirectory = tempDirectory.appendingPathComponent("protected-audio-directory")
        let blockingFile = blockingDirectory.appendingPathComponent("audio.m4a")
        try FileManager.default.createDirectory(at: blockingDirectory, withIntermediateDirectories: false)
        try Data("do not remove".utf8).write(to: blockingFile)
        // Removing a directory is recursive on the simulator, so a non-empty
        // directory does not reliably exercise the failure path. Remove write
        // permission from its parent instead; the main file remains present and
        // the cleanup can restore permissions in the defer below.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o500)],
            ofItemAtPath: blockingDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: blockingDirectory.path
            )
            try? FileManager.default.removeItem(at: blockingFile)
            try? FileManager.default.removeItem(at: blockingDirectory)
        }

        recording.recordingURL = blockingDirectory.path
        try appCoordinator.coreDataManager.saveContext()

        do {
            _ = try await appCoordinator.applyRemoteImportedAudioRemovalUsingRepository(
                id: recordingId,
                requestedAt: Date()
            )
            XCTFail("Expected the imported audio removal to remain retryable")
        } catch {
            // The repository transaction must not run while the file is still
            // present, so the URL remains available for the next marker replay.
        }
        XCTAssertEqual(
            appCoordinator.getRecording(id: recordingId)?.recordingURL,
            blockingDirectory.path,
            "A failed main-file removal must leave the URL for a later marker retry"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: blockingFile.path))
    }

    /// A local edit made after the delete is still the newer edit. Stamping the
    /// marker's `deletedAt` over it would hand the row to the cloud copy.
    func testApplyingImportedAudioRemovalNeverMovesLastModifiedBackward() async throws {
        let recordingId = try createRecordingOnly(named: "Renamed after the delete")
        let recording = try XCTUnwrap(appCoordinator.getRecording(id: recordingId))
        let audioURL = tempDirectory.appendingPathComponent("\(recordingId.uuidString).m4a")
        try Data("placeholder".utf8).write(to: audioURL)

        let laterEdit = Date()
        recording.audioQuality = "imported"
        recording.recordingURL = audioURL.path
        recording.lastModified = laterEdit
        try appCoordinator.coreDataManager.managedObjectContext.save()

        _ = try await appCoordinator.applyRemoteImportedAudioRemovalUsingRepository(
            id: recordingId,
            requestedAt: laterEdit.addingTimeInterval(-3_600)
        )

        XCTAssertEqual(appCoordinator.getRecording(id: recordingId)?.lastModified, laterEdit)
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
        let recordingId = try createRecordingOnly(named: name)
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

    private func createRecordingOnly(named name: String) throws -> UUID {
        let audioURL = tempDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try TestHelpers.createMockAudioFile(at: audioURL)
        return appCoordinator.addRecording(
            url: audioURL,
            name: name,
            date: Date(),
            fileSize: 1_024,
            duration: 30,
            quality: .whisperOptimized
        )
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


    // MARK: - Transcript / Summary Relink Arbitration

    /// Summaries share `shouldRelinkRestoredRow`. A cloud summary with a
    /// different id — the other device deleted and regenerated — must not steal
    /// the recording's pointer unless it is actually newer.
    func testRelinkKeepsTheNewerSummaryWhenTheCloudRowHasADifferentId() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let linkedId = UUID()

        XCTAssertFalse(
            iCloudStorageManager.shouldRelinkRestoredRow(
                candidateId: UUID(),
                candidateTimestamp: base,
                linkedId: linkedId,
                linkedTimestamp: base.addingTimeInterval(600)
            )
        )
        XCTAssertTrue(
            iCloudStorageManager.shouldRelinkRestoredRow(
                candidateId: UUID(),
                candidateTimestamp: base.addingTimeInterval(600),
                linkedId: linkedId,
                linkedTimestamp: base
            )
        )
    }

    func testRelinkKeepsTheNewerTranscriptWhenTheCloudRowHasADifferentId() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let linkedId = UUID()

        // The other device deleted and retranscribed, so its backup carries an
        // older transcript under a brand-new id. Matching is by id, so there is
        // no local counterpart and nothing to compare — the recording must keep
        // pointing at the newer row it already has.
        XCTAssertFalse(
            iCloudStorageManager.shouldRelinkRestoredRow(
                candidateId: UUID(),
                candidateTimestamp: base,
                linkedId: linkedId,
                linkedTimestamp: base.addingTimeInterval(600)
            )
        )

        // The mirror image: the cloud row really is newer, so it should win.
        XCTAssertTrue(
            iCloudStorageManager.shouldRelinkRestoredRow(
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
            iCloudStorageManager.shouldRelinkRestoredRow(
                candidateId: sameId,
                candidateTimestamp: nil,
                linkedId: sameId,
                linkedTimestamp: Date()
            )
        )
    }

    func testRelinkTakesTheCandidateWhenNothingIsLinkedYet() {
        XCTAssertTrue(
            iCloudStorageManager.shouldRelinkRestoredRow(
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
            iCloudStorageManager.shouldRelinkRestoredRow(
                candidateId: UUID(),
                candidateTimestamp: nil,
                linkedId: UUID(),
                linkedTimestamp: Date()
            )
        )
        XCTAssertFalse(
            iCloudStorageManager.shouldRelinkRestoredRow(
                candidateId: UUID(),
                candidateTimestamp: Date(),
                linkedId: UUID(),
                linkedTimestamp: nil
            )
        )
    }


    // MARK: - Restored Engine Selection

    func testCrossPlatformRestoreKeepsEnginesValidOnBothPlatforms() {
        // These were dropped wholesale whenever a backup crossed between macOS
        // and iOS, even though every one of them works on both.
        for engine in [AIEngineType.mistralAI, .googleAIStudio, .openAICompatible, .appleNative] {
            XCTAssertEqual(
                iCloudStorageManager.resolveRestoredEngineSelection(engine.rawValue),
                .accept,
                "\(engine.rawValue) should survive a cross-platform restore"
            )
        }
    }

    func testRestoreMapsOpenAIOntoItsSuccessor() {
        // Startup migrates the OpenAI key and configuration to Compatible API,
        // so discarding the selection would strand credentials that still work.
        XCTAssertEqual(
            iCloudStorageManager.resolveRestoredEngineSelection("OpenAI"),
            .replace(AIEngineType.openAICompatible.rawValue)
        )
    }

    func testRestoreRejectsProvidersThisBuildNoLongerHas() {
        XCTAssertEqual(iCloudStorageManager.resolveRestoredEngineSelection("AWS Bedrock"), .reject)
        XCTAssertEqual(iCloudStorageManager.resolveRestoredEngineSelection("AWS Transcribe"), .reject)
    }

    func testRestoreRejectsAnEngineTheCurrentPlatformCannotRun() {
        let ollama = AIEngineType.localLLM
        XCTAssertEqual(
            iCloudStorageManager.resolveRestoredEngineSelection(ollama.rawValue),
            ollama.isSupportedOnCurrentPlatform ? .accept : .reject
        )
    }


    // MARK: - Read-Time Winner Matches Sync

    /// `getSummary(for:)` and `latestPerRecording` must name the same row. When
    /// they disagreed, a read showed one summary while sync converged on another
    /// — and the read path then deleted the row the other device was using.
    func testReadTimeSummaryWinnerMatchesTheSyncWinner() {
        struct Row { let id: UUID; let timestamp: Date? }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let recordingId = UUID()

        let cases: [[Row]] = [
            [Row(id: UUID(), timestamp: base),
             Row(id: UUID(), timestamp: base.addingTimeInterval(120)),
             Row(id: UUID(), timestamp: base.addingTimeInterval(60))],
            // Equal timestamps: the identifier tie-break has to agree too.
            (0..<5).map { _ in Row(id: UUID(), timestamp: base) },
            // A row with no timestamp must lose to one that has it, on both sides.
            [Row(id: UUID(), timestamp: nil), Row(id: UUID(), timestamp: base)]
        ]

        for rows in cases {
            let syncWinner = iCloudStorageManager.latestPerRecording(
                rows,
                recordingId: { _ in recordingId },
                timestamp: { $0.timestamp },
                identifier: { $0.id }
            ).kept.first?.id

            let readWinner = rows.max { lhs, rhs in
                CoreDataManager.summaryIsConvergentlyEarlier(
                    lhsTimestamp: lhs.timestamp,
                    lhsId: lhs.id,
                    rhsTimestamp: rhs.timestamp,
                    rhsId: rhs.id
                )
            }?.id

            XCTAssertEqual(readWinner, syncWinner)
        }
    }


    // MARK: - Recording Content Timestamp

    /// CLAUDE.md makes lastModified the value iCloud arbitration compares for a
    /// recording. Writing an older summary's generatedAt straight into it made the
    /// local row look older than the cloud copy, inviting a stale copy to
    /// overwrite newer local metadata.
    func testRecordingTimestampNeverMovesBackward() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let older = now.addingTimeInterval(-3_600)
        let newer = now.addingTimeInterval(3_600)

        XCTAssertEqual(max(now, older), now, "an older summary must not rewind the recording")
        XCTAssertEqual(max(now, newer), newer, "a newer summary still advances it")

        // And the arbitration rule this protects: a local row that looks older
        // loses to the cloud copy.
        XCTAssertFalse(
            iCloudStorageManager.shouldUploadLocalVersion(localTimestamp: older, cloudTimestamp: now)
        )
        XCTAssertTrue(
            iCloudStorageManager.shouldUploadLocalVersion(localTimestamp: now, cloudTimestamp: now)
        )
    }


    // MARK: - Batched Execution Parity
    //
    // The arbitration rules above are pure functions, and the tests for them stay
    // that way. These run the same rules through the real sync legs and a scripted
    // CloudKit transport, because batching changed *how* records are read and
    // written — and a rule that only holds one record at a time is no rule at all.

    private struct SyncEngineHarness {
        let manager: iCloudStorageManager
        let transport: FakeCloudKitTransport
        let clock: ManualCloudSyncClock
    }

    private static let syncEngineDefaultsKeys = [
        "iCloudBackupStateSignatureV1",
        "iCloudActiveManifestMigrationCompletedV2",
        "iCloudLastSuccessfulRoutineSyncV1"
    ]

    private func makeSyncEngineHarness() -> SyncEngineHarness {
        for key in Self.syncEngineDefaultsKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.set(true, forKey: "iCloudActiveManifestMigrationCompletedV2")
        // Read by `init`, so it has to be set before the manager is built; assigning
        // `isEnabled` afterwards would start the real CloudKit enable path.
        UserDefaults.standard.set(true, forKey: "iCloudSyncEnabled")
        defer { UserDefaults.standard.set(false, forKey: "iCloudSyncEnabled") }

        let transport = FakeCloudKitTransport()
        let clock = ManualCloudSyncClock()
        let manager = iCloudStorageManager(
            transport: transport,
            clock: clock,
            sleeper: RecordingCloudSyncSleeper(clock: clock),
            preferences: InMemoryCloudSyncPreferencesStore(),
            metricsSink: nil
        )
        manager.networkStatus = .available
        manager.clearPendingCloudMutationsForTesting()
        return SyncEngineHarness(manager: manager, transport: transport, clock: clock)
    }

    private func recordName(_ prefix: String, _ id: UUID) -> String {
        "\(prefix)\(id.uuidString)"
    }

    // MARK: Durable deletion intent

    func testPendingTombstoneSurvivesAPartialBatchFailure() async throws {
        let harness = makeSyncEngineHarness()
        let recordingId = try createCompleteRecording(named: "To delete")
        let recordingRecordName = recordName("backup_recording_", recordingId)
        harness.transport.seed([
            CloudKitTestRecords.record(type: "CD_BackupRecording", name: recordingRecordName)
        ])
        harness.transport.perRecordDeleteFailures[CKRecord.ID(recordName: recordingRecordName)] = [
            CloudKitTestError.ckError(.permissionFailure)
        ]

        harness.manager.enqueueRecordingDeletionForiCloud(
            recordingId: recordingId,
            transcriptIds: [],
            summaryIds: []
        )
        XCTAssertEqual(harness.manager.pendingCloudDeletionCountForTesting, 1)

        do {
            _ = try await harness.manager.flushPendingiCloudMutations(appCoordinator: appCoordinator)
            XCTFail("A failed cloud deletion must surface")
        } catch {
            // Expected.
        }

        XCTAssertEqual(
            harness.manager.pendingCloudDeletionCountForTesting,
            1,
            "Durable deletion intent is the only authority for removing cloud content; it survives until every step succeeds"
        )
        harness.manager.clearPendingCloudMutationsForTesting()
    }

    func testPendingTombstoneIsClearedOnlyAfterTheWholeSequenceSucceeds() async throws {
        let harness = makeSyncEngineHarness()
        let recordingId = try createCompleteRecording(named: "Deleted cleanly")
        let recordingRecordName = recordName("backup_recording_", recordingId)
        harness.transport.seed([
            CloudKitTestRecords.record(type: "CD_BackupRecording", name: recordingRecordName),
            CloudKitTestRecords.record(
                type: "CD_BackupContentIndex",
                name: "content_index",
                fields: [
                    "recordingRecordNames": [recordingRecordName] as NSArray,
                    "transcriptRecordNames": [] as NSArray,
                    "summaryRecordNames": [] as NSArray,
                    "manifestSchemaVersion": 2
                ]
            )
        ])

        harness.manager.enqueueRecordingDeletionForiCloud(
            recordingId: recordingId,
            transcriptIds: [],
            summaryIds: []
        )
        _ = try await harness.manager.flushPendingiCloudMutations(appCoordinator: appCoordinator)

        XCTAssertEqual(harness.manager.pendingCloudDeletionCountForTesting, 0)
        XCTAssertNil(harness.transport.record(named: recordingRecordName), "The content record is gone")
        XCTAssertNotNil(
            harness.transport.record(named: "backup_deletion_\(recordingId.uuidString)"),
            "…and the tombstone that says so is in place"
        )
        let manifest = harness.transport.record(named: "content_index")?["recordingRecordNames"] as? [String]
        XCTAssertEqual(manifest, [], "The manifest must not keep claiming a record that was deleted")
    }

    // MARK: Durable outbox persistence and migration

    func testSQLiteMigrationFromShippingModelPreservesContentAndAddsDurableOutbox() throws {
        let storeURL = tempDirectory.appendingPathComponent("shipping-migration.sqlite")
        let shippingContainer = try makeShippingModelContainer(at: storeURL)
        let recordingId = UUID()
        let shippingContext = shippingContainer.viewContext
        let shippingRecording = NSEntityDescription.insertNewObject(
            forEntityName: "RecordingEntry",
            into: shippingContext
        )
        shippingRecording.setValue(recordingId, forKey: "id")
        shippingRecording.setValue("Before durable outbox", forKey: "recordingName")
        shippingRecording.setValue(Date(), forKey: "recordingDate")
        shippingRecording.setValue(42.0, forKey: "duration")
        shippingRecording.setValue(Int64(1024), forKey: "fileSize")
        shippingRecording.setValue(Date(), forKey: "lastModified")
        try shippingContext.save()
        try closePersistentStores(of: shippingContainer)

        let migrated = PersistenceController(storeURL: storeURL)
        defer { try? closePersistentStores(of: migrated) }
        let context = migrated.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "RecordingEntry")
        request.predicate = NSPredicate(format: "id == %@", recordingId as CVarArg)
        let restored = try XCTUnwrap(try context.fetch(request).first)

        XCTAssertEqual(restored.value(forKey: "recordingName") as? String, "Before durable outbox")
        XCTAssertNotNil(
            NSEntityDescription.entity(forEntityName: PendingCloudMutationStore.entityName, in: context),
            "The current model must add the outbox entity while migrating the shipping store"
        )

        let requestedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try PendingCloudMutationStore.enqueue(
            PendingCloudMutation(
                kind: .recordingDeletion,
                targetId: recordingId,
                requestedAt: requestedAt
            ),
            in: context
        )
        try context.save()

        XCTAssertEqual(
            try PendingCloudMutationStore.fetchAll(in: context),
            [PendingCloudMutation(kind: .recordingDeletion, targetId: recordingId, requestedAt: requestedAt)]
        )
    }

    func testSQLiteDeletionAndOutboxSurviveReopenTogether() throws {
        let storeURL = tempDirectory.appendingPathComponent("delete-outbox.sqlite")
        let recordingId = UUID()
        let firstController = PersistenceController(storeURL: storeURL)
        let firstManager = CoreDataManager(persistenceController: firstController)
        let recording = RecordingEntry(context: firstManager.managedObjectContext)
        recording.id = recordingId
        recording.recordingName = "Durably deleted"
        recording.recordingDate = Date()
        recording.duration = 30
        recording.fileSize = 1024
        recording.lastModified = Date()
        try firstManager.saveContext()

        try firstManager.deleteRecording(id: recordingId)
        XCTAssertNil(firstManager.getRecording(id: recordingId))
        XCTAssertEqual(PendingCloudMutationStore.count(in: firstManager.managedObjectContext), 1)
        try closePersistentStores(of: firstController)

        let reopened = PersistenceController(storeURL: storeURL)
        defer { try? closePersistentStores(of: reopened) }
        let context = reopened.container.viewContext
        let recordings = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "RecordingEntry"))
        let mutations = try PendingCloudMutationStore.fetchAll(in: context)

        XCTAssertTrue(recordings.isEmpty)
        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(mutations.first?.kind, .recordingDeletion)
        XCTAssertEqual(mutations.first?.targetId, recordingId)
    }

    func testSQLiteSaveFailureRollsBackTheDeletionAndItsOutboxTogether() throws {
        let storeURL = tempDirectory.appendingPathComponent("delete-outbox-rollback.sqlite")
        let controller = PersistenceController(storeURL: storeURL)
        defer { try? closePersistentStores(of: controller) }
        let manager = CoreDataManager(persistenceController: controller)
        let context = manager.managedObjectContext
        let recordingId = UUID()
        let recording = RecordingEntry(context: context)
        recording.id = recordingId
        recording.recordingName = "Must survive failed save"
        recording.recordingDate = Date()
        recording.duration = 30
        recording.fileSize = 1024
        recording.lastModified = Date()
        try manager.saveContext()

        // Force the same save to contain an invalid required outbox value. The
        // deletion and the valid outbox row must both roll back as one transaction.
        let invalidOutbox = NSEntityDescription.insertNewObject(
            forEntityName: PendingCloudMutationStore.entityName,
            into: context
        )
        invalidOutbox.setValue(nil, forKey: "kind")
        invalidOutbox.setValue(nil, forKey: "targetId")

        XCTAssertThrowsError(try manager.deleteRecording(id: recordingId))
        XCTAssertNotNil(manager.getRecording(id: recordingId))
        XCTAssertEqual(PendingCloudMutationStore.count(in: context), 0)
    }

    func testClearAllCoreDataCommitsItsCloudRemovalsWithTheLocalRows() async throws {
        _ = try createCompleteRecording(named: "Clear all transaction")
        let migrationManager = DataMigrationManager(persistenceController: persistenceController)

        await migrationManager.clearAllCoreData()

        XCTAssertTrue(appCoordinator.coreDataManager.getAllRecordings().isEmpty)
        XCTAssertTrue(appCoordinator.coreDataManager.getAllTranscripts().isEmpty)
        XCTAssertTrue(appCoordinator.coreDataManager.getAllSummaries().isEmpty)

        let mutations = try PendingCloudMutationStore.fetchAll(
            in: persistenceController.container.viewContext
        )
        XCTAssertEqual(mutations.count, 3)
        XCTAssertEqual(
            Set(mutations.map(\.kind)),
            Set([
                .recordingDeletion,
                .transcriptRemoval,
                .summaryRemoval
            ])
        )
    }

    func testLegacyMutationQueuesMigrateLosslesslyAndRerunWithoutDuplicates() throws {
        let defaults = UserDefaults.standard
        let keys = Self.legacyMutationKeys
        let oldValues = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in oldValues {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        keys.forEach { defaults.removeObject(forKey: $0) }

        let recordingId = UUID()
        let transcriptId = UUID()
        let summaryId = UUID()
        let requestedAt = Date(timeIntervalSince1970: 1_700_000_001)
        let encoder = JSONEncoder()
        defaults.set(
            try encoder.encode([
                LegacyDeletionMarkerFixture(
                    recordingId: recordingId,
                    transcriptIds: [transcriptId],
                    summaryIds: [summaryId],
                    requestedAt: requestedAt
                )
            ]),
            forKey: "iCloudPendingDeletionMarkersV1"
        )
        defaults.set(
            try encoder.encode([
                LegacyLocalOnlyRemovalFixture(recordingId: recordingId, requestedAt: requestedAt)
            ]),
            forKey: "iCloudPendingLocalOnlyRemovalsV1"
        )
        defaults.set(
            try encoder.encode([
                LegacySummaryRemovalFixture(
                    summaryId: summaryId,
                    recordingId: recordingId,
                    requestedAt: requestedAt
                )
            ]),
            forKey: "iCloudPendingSummaryRemovalsV1"
        )
        defaults.set(
            try encoder.encode([
                LegacyTranscriptRemovalFixture(
                    transcriptId: transcriptId,
                    recordingId: recordingId,
                    requestedAt: requestedAt
                )
            ]),
            forKey: "iCloudPendingTranscriptRemovalsV1"
        )
        defaults.set(
            try encoder.encode([
                LegacyImportedAudioRemovalFixture(recordingId: recordingId, requestedAt: requestedAt)
            ]),
            forKey: "iCloudPendingImportedAudioRemovalsV1"
        )

        let controller = PersistenceController(inMemory: true)
        defer { try? closePersistentStores(of: controller) }
        let context = controller.container.viewContext

        XCTAssertTrue(PendingCloudMutationStore.migrateLegacyQueuesIfNeeded(in: context))
        let firstPass = try PendingCloudMutationStore.fetchAll(in: context)
        XCTAssertEqual(firstPass.count, 5)
        XCTAssertTrue(keys.allSatisfy { defaults.object(forKey: $0) == nil })
        XCTAssertFalse(PendingCloudMutationStore.migrateLegacyQueuesIfNeeded(in: context))
        XCTAssertEqual(try PendingCloudMutationStore.fetchAll(in: context).count, firstPass.count)
        XCTAssertEqual(
            Set(firstPass.map(\.kind)),
            Set(PendingCloudMutationKind.allCases)
        )
        XCTAssertEqual(
            firstPass.first(where: { $0.kind == .recordingDeletion })?.transcriptIds,
            [transcriptId]
        )
        XCTAssertEqual(
            firstPass.first(where: { $0.kind == .recordingDeletion })?.summaryIds,
            [summaryId]
        )
    }

    func testFailedLegacyMigrationRetainsRecoverableUserDefaultsData() throws {
        let defaults = UserDefaults.standard
        let key = "iCloudPendingDeletionMarkersV1"
        let oldValue = defaults.object(forKey: key)
        defer {
            if let oldValue { defaults.set(oldValue, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        let malformed = Data("not-json".utf8)
        defaults.set(malformed, forKey: key)

        let controller = PersistenceController(inMemory: true)
        defer { try? closePersistentStores(of: controller) }
        XCTAssertFalse(PendingCloudMutationStore.migrateLegacyQueuesIfNeeded(in: controller.container.viewContext))
        XCTAssertEqual(defaults.data(forKey: key), malformed)
        XCTAssertTrue(try PendingCloudMutationStore.fetchAll(in: controller.container.viewContext).isEmpty)
    }

    func testPendingMutationAcknowledgementRetainsAConcurrentNewerPayload() throws {
        let controller = PersistenceController(inMemory: true)
        defer { try? closePersistentStores(of: controller) }
        let context = controller.container.viewContext
        let targetId = UUID()
        let firstTranscript = UUID()
        let newerTranscript = UUID()
        let first = PendingCloudMutation(
            kind: .recordingDeletion,
            targetId: targetId,
            transcriptIds: [firstTranscript],
            requestedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try PendingCloudMutationStore.enqueue(first, in: context)
        try context.save()
        let snapshot = try XCTUnwrap(PendingCloudMutationStore.fetchAll(in: context).first)

        try PendingCloudMutationStore.enqueue(
            PendingCloudMutation(
                kind: .recordingDeletion,
                targetId: targetId,
                transcriptIds: [newerTranscript],
                requestedAt: Date(timeIntervalSince1970: 1_700_000_100)
            ),
            in: context
        )
        try context.save()

        XCTAssertFalse(try PendingCloudMutationStore.removeIfUnchanged(snapshot, from: context))
        let retained = try XCTUnwrap(PendingCloudMutationStore.fetchAll(in: context).first)
        XCTAssertEqual(Set(retained.transcriptIds), Set([firstTranscript, newerTranscript]))
    }

    // MARK: Arbitration through the real legs

    func testNewerCloudRecordWinsThroughBatchedExecution() async throws {
        let harness = makeSyncEngineHarness()
        let recordingId = try createRecordingOnly(named: "Local name")
        let recordingRecordName = recordName("backup_recording_", recordingId)
        let cloudEdit = Date().addingTimeInterval(600)
        harness.transport.seed([
            CloudKitTestRecords.record(
                type: "CD_BackupRecording",
                name: recordingRecordName,
                fields: [
                    "recordingName": "Renamed on another device",
                    "recordingDate": Date(),
                    "createdAt": Date(),
                    "lastModified": cloudEdit,
                    "syncLifecycle": "active",
                    "syncSchemaVersion": 2
                ]
            )
        ])

        _ = try await harness.manager.reconcileAllDataWithiCloud(
            appCoordinator: appCoordinator,
            reason: .appLaunch
        )

        let recording = try XCTUnwrap(appCoordinator.coreDataManager.getRecording(id: recordingId))
        XCTAssertEqual(
            recording.recordingName,
            "Renamed on another device",
            "The newer edit wins whichever device syncs last"
        )
        XCTAssertEqual(
            harness.transport.record(named: recordingRecordName)?["recordingName"] as? String,
            "Renamed on another device",
            "…and this device must not have overwritten it on the way past"
        )
    }

    func testRevivalGraceSurvivesBatchedExecution() async throws {
        let harness = makeSyncEngineHarness()
        let recordingId = try createRecordingOnly(named: "Edited after delete")
        let recording = try XCTUnwrap(appCoordinator.coreDataManager.getRecording(id: recordingId))
        recording.lastModified = Date()
        try appCoordinator.coreDataManager.managedObjectContext.save()

        let deletionRecordName = "backup_deletion_\(recordingId.uuidString)"
        harness.transport.seed([
            CloudKitTestRecords.record(
                type: "CD_BackupDeletion",
                name: deletionRecordName,
                fields: [
                    // Deleted elsewhere well over the grace window ago; this device
                    // has edited the item since.
                    "deletedAt": Date().addingTimeInterval(-600),
                    "recordingId": recordingId.uuidString
                ]
            )
        ])

        _ = try await harness.manager.reconcileAllDataWithiCloud(
            appCoordinator: appCoordinator,
            reason: .appLaunch
        )

        XCTAssertNotNil(
            appCoordinator.coreDataManager.getRecording(id: recordingId),
            "An edit more than the grace interval after a delete beats that delete"
        )
        XCTAssertNil(
            harness.transport.record(named: deletionRecordName),
            "…and the tombstone is withdrawn so every device keeps the item"
        )
    }

    func testLocalOnlyRecordingIsWithdrawnFromTheCloudThroughTheBatchedLeg() async throws {
        let harness = makeSyncEngineHarness()
        let recordingId = try createCompleteRecording(named: "Keep on device")
        let recordingRecordName = recordName("backup_recording_", recordingId)
        harness.transport.seed([
            CloudKitTestRecords.record(type: "CD_BackupRecording", name: recordingRecordName)
        ])
        try appCoordinator.coreDataManager.updateCloudSyncDisabled(for: recordingId, disabled: true)

        _ = try await harness.manager.reconcileAllDataWithiCloud(
            appCoordinator: appCoordinator,
            reason: .appLaunch
        )

        XCTAssertNil(
            harness.transport.record(named: recordingRecordName),
            "Keep on This Device means the cloud copy goes away"
        )
    }

    func testRestoreRelinksRecordingsToTheirTranscriptAndSummary() async throws {
        let harness = makeSyncEngineHarness()
        let recordingId = UUID()
        let transcriptId = UUID()
        let summaryId = UUID()
        let now = Date()

        harness.transport.seed([
            CloudKitTestRecords.record(
                type: "CD_BackupRecording",
                name: recordName("backup_recording_", recordingId),
                fields: [
                    "recordingName": "Restored",
                    "recordingDate": now,
                    "createdAt": now,
                    "lastModified": now,
                    "recordingURL": "restored.m4a",
                    "duration": 42.0,
                    "transcriptId": transcriptId.uuidString,
                    "summaryId": summaryId.uuidString,
                    "summaryStatus": ProcessingStatus.notStarted.rawValue,
                    "syncLifecycle": "active",
                    "syncSchemaVersion": 2
                ]
            ),
            CloudKitTestRecords.record(
                type: "CD_BackupTranscript",
                name: recordName("backup_transcript_", transcriptId),
                fields: [
                    "recordingId": recordingId.uuidString,
                    "createdAt": now,
                    "lastModified": now,
                    "engine": "fixture",
                    "syncLifecycle": "active",
                    "syncSchemaVersion": 2
                ]
            ),
            CloudKitTestRecords.record(
                type: "CD_BackupSummary",
                name: recordName("backup_summary_", summaryId),
                fields: [
                    "recordingId": recordingId.uuidString,
                    "transcriptId": transcriptId.uuidString,
                    "summary": "Restored summary body long enough to look like real content.",
                    "generatedAt": now,
                    "lastModified": now,
                    "aiMethod": "fixture",
                    "syncLifecycle": "active",
                    "syncSchemaVersion": 2
                ]
            )
        ])

        _ = try await harness.manager.restoreAllDataFromiCloud(
            appCoordinator: appCoordinator,
            includeAudioFiles: false,
            restoreSettings: false
        )

        let recording = try XCTUnwrap(appCoordinator.coreDataManager.getRecording(id: recordingId))
        XCTAssertEqual(recording.transcriptId, transcriptId)
        XCTAssertEqual(recording.summaryId, summaryId)
        XCTAssertNotNil(recording.transcript, "The relationship, not just the id, has to be repaired")
        XCTAssertNotNil(recording.summary)
        XCTAssertEqual(
            recording.summaryStatus,
            ProcessingStatus.completed.rawValue,
            "An accepted summary must repair a stale recording status"
        )
    }

    /// The compiled `.momd` that ships in the bundle, which holds every model
    /// version as its own `.mom`.
    ///
    /// Deliberately not the source `.xcdatamodel`: `NSManagedObjectModel` loads
    /// compiled `.mom`/`.momd` only, so reading the source tree could never have
    /// produced a model no matter what path it was given.
    private static func compiledModelDirectoryURL() -> URL? {
        var searched: [Bundle] = [Bundle(for: ICloudBackupRegressionTests.self), Bundle.main]
        searched.append(contentsOf: Bundle.allBundles)
        for bundle in searched {
            if let url = bundle.url(forResource: "BisonNotes_AI", withExtension: "momd") {
                return url
            }
        }
        return nil
    }

    private func makeShippingModelContainer(at storeURL: URL) throws -> NSPersistentContainer {
        guard let modelDirectoryURL = Self.compiledModelDirectoryURL() else {
            throw NSError(
                domain: "ICloudBackupRegressionTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not find BisonNotes_AI.momd in any loaded bundle"]
            )
        }
        // `BisonNotes_AI.mom` is the v1 entry — the model as shipped, before
        // `PendingCloudMutation` was added. Opening the `.momd` directory instead
        // would load the current version and test nothing.
        let modelURL = modelDirectoryURL.appendingPathComponent("BisonNotes_AI.mom")
        guard let model = NSManagedObjectModel(contentsOf: modelURL) else {
            throw NSError(
                domain: "ICloudBackupRegressionTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not load the shipping Core Data model at \(modelURL.path)"]
            )
        }
        XCTAssertNil(
            model.entitiesByName[PendingCloudMutationStore.entityName],
            "The shipping model must not already contain the outbox, or this migration proves nothing"
        )

        let container = NSPersistentContainer(name: "BisonNotes_AI_Shipping", managedObjectModel: model)
        let description = container.persistentStoreDescriptions[0]
        description.url = storeURL
        description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
        description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
        let loadBox = PersistentStoreLoadBox()
        container.loadPersistentStores { _, error in
            loadBox.error = error
        }
        if let loadError = loadBox.error { throw loadError }
        return container
    }

    private func closePersistentStores(of controller: PersistenceController) throws {
        let coordinator = controller.container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try coordinator.remove(store)
        }
    }

    private func closePersistentStores(of container: NSPersistentContainer) throws {
        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try coordinator.remove(store)
        }
    }
}
