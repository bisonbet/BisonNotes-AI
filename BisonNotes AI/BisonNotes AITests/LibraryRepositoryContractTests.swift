import CoreData
import Foundation
import XCTest
@testable import BisonNotes_AI

final class LibraryRepositoryContractTests: XCTestCase {
    func testCoreDataRepositoryReturnsStorageNeutralRecordingSnapshot() async throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        let fixture = try SQLiteMigrationCoreDataSourceFixtureFactory.make(
            at: directory.appendingPathComponent("repository.sqlite"),
            version: .active
        )
        defer {
            try? SQLiteMigrationCoreDataSourceFixtureFactory.close(
                container: fixture.container
            )
            try? FileManager.default.removeItem(at: directory)
        }

        let repository = CoreDataLibraryRepository(
            context: fixture.container.viewContext
        )
        let recordings = try await repository.fetchRecordingSummaries()

        XCTAssertEqual(recordings.count, 1)
        XCTAssertEqual(recordings[0].legacyID, "10000000-0000-0000-0000-000000000001")
        XCTAssertEqual(recordings[0].name, "Fixture recording")
        XCTAssertEqual(recordings[0].recordingDate, Date(timeIntervalSinceReferenceDate: 100))
        XCTAssertEqual(recordings[0].duration, 7.5)
        XCTAssertEqual(recordings[0].fileSize, 42)
        XCTAssertEqual(recordings[0].recordingURL, "recording.m4a")
        XCTAssertEqual(recordings[0].isArchived, false)
        XCTAssertEqual(recordings[0].isCloudSyncDisabled, false)
        XCTAssertEqual(recordings[0].lastModified, Date(timeIntervalSinceReferenceDate: 101))
    }

    func testCoreDataRepositoryReturnsAllMetadataSnapshots() async throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        let fixture = try SQLiteMigrationCoreDataSourceFixtureFactory.make(
            at: directory.appendingPathComponent("repository-all.sqlite"),
            version: .active
        )
        defer {
            try? SQLiteMigrationCoreDataSourceFixtureFactory.close(
                container: fixture.container
            )
            try? FileManager.default.removeItem(at: directory)
        }

        let repository = CoreDataLibraryRepository(
            context: fixture.container.viewContext
        )
        let transcripts = try await repository.fetchTranscriptSnapshots()
        let summaries = try await repository.fetchSummarySnapshots()
        let processingJobs = try await repository.fetchProcessingJobSnapshots()
        let archiveLocations = try await repository.fetchArchiveLocationSnapshots()
        let pendingMutations = try await repository.fetchPendingCloudMutationSnapshots()

        let recordingStorageID = "core-data-recording-10000000-0000-0000-0000-000000000001"
        let transcriptStorageID = "core-data-transcript-10000000-0000-0000-0000-000000000002"

        try assertTranscript(
            try XCTUnwrap(transcripts.first),
            recordingStorageID: recordingStorageID
        )
        try assertSummary(
            try XCTUnwrap(summaries.first),
            recordingStorageID: recordingStorageID,
            transcriptStorageID: transcriptStorageID
        )
        try assertProcessingJob(
            try XCTUnwrap(processingJobs.first),
            recordingStorageID: recordingStorageID
        )
        try assertArchiveLocation(try XCTUnwrap(archiveLocations.first))
        try assertPendingMutation(try XCTUnwrap(pendingMutations.first))
    }

    func testCoreDataRepositoryRenamesRecordingThroughStorageNeutralCommand() async throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        let fixture = try SQLiteMigrationCoreDataSourceFixtureFactory.make(
            at: directory.appendingPathComponent("repository-rename.sqlite"),
            version: .active
        )
        defer {
            try? SQLiteMigrationCoreDataSourceFixtureFactory.close(
                container: fixture.container
            )
            try? FileManager.default.removeItem(at: directory)
        }

        let repository = CoreDataLibraryRepository(
            context: fixture.container.viewContext
        )
        let recordingID = "10000000-0000-0000-0000-000000000001"
        let updated = try await repository.renameRecording(
            LibraryRecordingRenameCommand(
                reference: LibraryRecordingReference(legacyID: recordingID),
                name: "Renamed [Watch]",
                expectedLastModified: Date(timeIntervalSinceReferenceDate: 101),
                modifiedAt: Date(timeIntervalSinceReferenceDate: 300)
            )
        )

        XCTAssertEqual(updated.legacyID, recordingID)
        XCTAssertEqual(updated.name, "Renamed")
        XCTAssertEqual(updated.lastModified, Date(timeIntervalSinceReferenceDate: 300))
        let persistedRecordings = try await repository.fetchRecordingSummaries()
        XCTAssertEqual(persistedRecordings.first?.name, "Renamed")
    }

    func testCoreDataRepositoryCloudSyncToggleCommitsRecordingAndPendingMutationTogether() async throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        let fixture = try SQLiteMigrationCoreDataSourceFixtureFactory.make(
            at: directory.appendingPathComponent("repository-cloud-sync.sqlite"),
            version: .active
        )
        defer {
            try? SQLiteMigrationCoreDataSourceFixtureFactory.close(
                container: fixture.container
            )
            try? FileManager.default.removeItem(at: directory)
        }

        let repository = CoreDataLibraryRepository(
            context: fixture.container.viewContext
        )
        let recordingID = "10000000-0000-0000-0000-000000000001"
        let disabled = try await repository.setCloudSyncDisabled(
            LibraryRecordingCloudSyncCommand(
                reference: LibraryRecordingReference(legacyID: recordingID),
                disabled: true,
                expectedLastModified: Date(timeIntervalSinceReferenceDate: 101),
                modifiedAt: Date(timeIntervalSinceReferenceDate: 300),
                requestedAt: Date(timeIntervalSinceReferenceDate: 250)
            )
        )

        XCTAssertEqual(disabled.isCloudSyncDisabled, true)
        XCTAssertEqual(disabled.lastModified, Date(timeIntervalSinceReferenceDate: 300))
        let pendingAfterDisable = try await repository.fetchPendingCloudMutationSnapshots()
            .filter { $0.kind == PendingCloudMutationKind.localOnlyRemoval.rawValue }
        XCTAssertEqual(pendingAfterDisable.count, 1)
        XCTAssertEqual(pendingAfterDisable[0].targetID, recordingID)
        XCTAssertEqual(
            pendingAfterDisable[0].requestedAt,
            Date(timeIntervalSinceReferenceDate: 250)
        )

        let enabled = try await repository.setCloudSyncDisabled(
            LibraryRecordingCloudSyncCommand(
                reference: LibraryRecordingReference(legacyID: recordingID),
                disabled: false,
                expectedLastModified: Date(timeIntervalSinceReferenceDate: 300),
                modifiedAt: Date(timeIntervalSinceReferenceDate: 301)
            )
        )

        XCTAssertEqual(enabled.isCloudSyncDisabled, false)
        XCTAssertEqual(enabled.lastModified, Date(timeIntervalSinceReferenceDate: 301))
        let pendingAfterEnable = try await repository.fetchPendingCloudMutationSnapshots()
            .filter { $0.kind == PendingCloudMutationKind.localOnlyRemoval.rawValue }
        XCTAssertTrue(pendingAfterEnable.isEmpty)
    }

    private func assertTranscript(
        _ transcript: LibraryTranscriptSnapshot,
        recordingStorageID: String
    ) throws {
        XCTAssertEqual(transcript.legacyID, "10000000-0000-0000-0000-000000000002")
        XCTAssertEqual(transcript.confidence, 0.98)
        XCTAssertEqual(transcript.createdAt, Date(timeIntervalSinceReferenceDate: 102))
        XCTAssertEqual(transcript.engine, "fixture-engine")
        XCTAssertEqual(transcript.lastModified, Date(timeIntervalSinceReferenceDate: 103))
        XCTAssertEqual(transcript.processingTime, 1.5)
        XCTAssertEqual(transcript.recordingStorageID, recordingStorageID)
        XCTAssertEqual(transcript.recordingLegacyID, "10000000-0000-0000-0000-000000000001")
        XCTAssertEqual(transcript.segments, "{\"segments\":[]}")
        XCTAssertEqual(transcript.speakerMappings, "{}")
    }

    private func assertSummary(
        _ summary: LibrarySummarySnapshot,
        recordingStorageID: String,
        transcriptStorageID: String
    ) throws {
        XCTAssertEqual(summary.legacyID, "10000000-0000-0000-0000-000000000003")
        XCTAssertEqual(summary.aiMethod, "fixture-model")
        XCTAssertEqual(summary.compressionRatio, 0.25)
        XCTAssertEqual(summary.confidence, 0.9)
        XCTAssertEqual(summary.contentType, "summary")
        XCTAssertEqual(summary.generatedAt, Date(timeIntervalSinceReferenceDate: 104))
        XCTAssertEqual(summary.originalLength, 12)
        XCTAssertEqual(summary.processingTime, 2)
        XCTAssertEqual(summary.recordingStorageID, recordingStorageID)
        XCTAssertEqual(summary.recordingLegacyID, "10000000-0000-0000-0000-000000000001")
        XCTAssertEqual(summary.reminders, "[{\"text\":\"follow up\"}]")
        XCTAssertEqual(summary.summary, "Fixture summary")
        XCTAssertEqual(summary.tasks, "[{\"text\":\"task\"}]")
        XCTAssertEqual(summary.titles, "[{\"text\":\"Fixture\"}]")
        XCTAssertEqual(summary.transcriptStorageID, transcriptStorageID)
        XCTAssertEqual(summary.transcriptLegacyID, "10000000-0000-0000-0000-000000000002")
        XCTAssertEqual(summary.version, 1)
        XCTAssertEqual(summary.wordCount, 2)
    }

    private func assertProcessingJob(
        _ processingJob: LibraryProcessingJobSnapshot,
        recordingStorageID: String
    ) throws {
        XCTAssertEqual(processingJob.legacyID, "10000000-0000-0000-0000-000000000004")
        XCTAssertEqual(processingJob.completionTime, Date(timeIntervalSinceReferenceDate: 106))
        XCTAssertEqual(processingJob.engine, "fixture-engine")
        XCTAssertNil(processingJob.error)
        XCTAssertEqual(processingJob.jobType, "transcription")
        XCTAssertEqual(processingJob.lastModified, Date(timeIntervalSinceReferenceDate: 105))
        XCTAssertEqual(processingJob.modelName, "fixture-model")
        XCTAssertEqual(processingJob.progress, 1)
        XCTAssertEqual(processingJob.recordingName, "Fixture recording")
        XCTAssertEqual(processingJob.recordingURL, "recording.m4a")
        XCTAssertEqual(processingJob.recordingStorageID, recordingStorageID)
        XCTAssertEqual(processingJob.startTime, Date(timeIntervalSinceReferenceDate: 104))
        XCTAssertEqual(processingJob.status, "complete")
    }

    private func assertArchiveLocation(
        _ archiveLocation: LibraryArchiveLocationSnapshot
    ) throws {
        XCTAssertEqual(archiveLocation.legacyID, "10000000-0000-0000-0000-000000000005")
        XCTAssertEqual(archiveLocation.bookmarkData, Data([1, 2, 3]))
        XCTAssertEqual(archiveLocation.destinationURLString, "archive://fixture")
        XCTAssertEqual(archiveLocation.displayName, "Fixture archive")
        XCTAssertEqual(archiveLocation.exportedAt, Date(timeIntervalSinceReferenceDate: 106))
        XCTAssertEqual(archiveLocation.exportedFilename, "fixture.m4a")
        XCTAssertEqual(archiveLocation.fileSize, 42)
        XCTAssertEqual(archiveLocation.lastVerifiedAt, Date(timeIntervalSinceReferenceDate: 107))
        XCTAssertEqual(archiveLocation.providerDisplayName, "Fixture provider")
        XCTAssertEqual(archiveLocation.recordingLegacyID, "10000000-0000-0000-0000-000000000001")
        XCTAssertEqual(archiveLocation.status, "verified")
    }

    private func assertPendingMutation(
        _ pendingMutation: LibraryPendingCloudMutationSnapshot
    ) throws {
        XCTAssertEqual(pendingMutation.kind, "update")
        XCTAssertEqual(pendingMutation.payload, Data([4, 5, 6]))
        XCTAssertEqual(pendingMutation.recordingLegacyID, "10000000-0000-0000-0000-000000000001")
        XCTAssertEqual(pendingMutation.requestedAt, Date(timeIntervalSinceReferenceDate: 108))
        XCTAssertEqual(pendingMutation.targetID, "10000000-0000-0000-0000-000000000001")
        XCTAssertEqual(pendingMutation.version, 1)
    }
}
