import Foundation
import XCTest
@testable import BisonNotesSQLiteRuntime

final class SQLiteLibraryRepositoryRuntimeTests: XCTestCase {
    func testRepositoryReturnsStorageNeutralRecordingSnapshot() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceSnapshot = makeVerifierSnapshot(migrationRunID: nil)
        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let store = try SQLiteLibraryStore(databaseURL: databaseURL)
        _ = try await SQLiteMigrationMetadataImporter.importSnapshot(
            sourceSnapshot,
            into: store,
            batchSize: sourceSnapshot.rows.count,
            at: Date(timeIntervalSinceReferenceDate: 200)
        )

        let repository = SQLiteLibraryRepository(store: store)
        let recordings = try await repository.fetchRecordingSummaries()

        XCTAssertEqual(recordings.count, 1)
        XCTAssertEqual(
            recordings[0],
            LibraryRecordingSnapshot(
                storageID: "recording-storage",
                legacyID: "recording-legacy",
                name: "Fixture recording",
                recordingDate: Date(timeIntervalSinceReferenceDate: 100),
                duration: 7.5,
                fileSize: 42,
                recordingURL: "recording.m4a",
                isArchived: false,
                lastModified: Date(timeIntervalSinceReferenceDate: 101)
            )
        )
    }

    func testRepositoryReturnsEmptyLibraryBeforeMetadataImport() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        let repository = SQLiteLibraryRepository(store: store)
        let recordings = try await repository.fetchRecordingSummaries()

        XCTAssertTrue(recordings.isEmpty)
    }

    func testRepositoryReturnsAllMetadataSnapshotsFromImportedRows() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceSnapshot = makeVerifierSnapshot(migrationRunID: nil)
        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        _ = try await SQLiteMigrationMetadataImporter.importSnapshot(
            sourceSnapshot,
            into: store,
            batchSize: sourceSnapshot.rows.count,
            at: Date(timeIntervalSinceReferenceDate: 200)
        )
        let repository = SQLiteLibraryRepository(store: store)
        let transcripts = try await repository.fetchTranscriptSnapshots()
        let summaries = try await repository.fetchSummarySnapshots()
        let processingJobs = try await repository.fetchProcessingJobSnapshots()
        let archiveLocations = try await repository.fetchArchiveLocationSnapshots()
        let pendingMutations = try await repository.fetchPendingCloudMutationSnapshots()

        XCTAssertEqual(transcripts, [expectedTranscript()])
        XCTAssertEqual(summaries, [expectedSummary()])
        XCTAssertEqual(processingJobs, [expectedProcessingJob()])
        XCTAssertEqual(archiveLocations, [expectedArchiveLocation()])
        XCTAssertEqual(pendingMutations, [expectedPendingMutation()])
    }

    private func expectedTranscript() -> LibraryTranscriptSnapshot {
        LibraryTranscriptSnapshot(
            storageID: "transcript-storage",
            legacyID: "transcript-legacy",
            confidence: 0.98,
            createdAt: Date(timeIntervalSinceReferenceDate: 102),
            engine: "fixture-engine",
            lastModified: Date(timeIntervalSinceReferenceDate: 103),
            processingTime: 1.5,
            recordingStorageID: "recording-storage",
            recordingLegacyID: "recording-legacy",
            segments: "{\"segments\":[]}",
            speakerMappings: "{}"
        )
    }

    private func expectedSummary() -> LibrarySummarySnapshot {
        LibrarySummarySnapshot(
            storageID: "summary-storage",
            aiMethod: "fixture-model",
            compressionRatio: nil,
            confidence: 0.9,
            contentType: "summary",
            generatedAt: Date(timeIntervalSinceReferenceDate: 104),
            legacyID: "summary-legacy",
            originalLength: 12,
            processingTime: 2,
            recordingStorageID: "recording-storage",
            recordingLegacyID: "recording-legacy",
            reminders: nil,
            summary: "Fixture summary",
            tasks: nil,
            titles: nil,
            transcriptStorageID: "transcript-storage",
            transcriptLegacyID: "transcript-legacy",
            version: 1,
            wordCount: 2
        )
    }

    private func expectedProcessingJob() -> LibraryProcessingJobSnapshot {
        LibraryProcessingJobSnapshot(
            storageID: "job-storage",
            completionTime: nil,
            engine: "fixture-engine",
            error: nil,
            legacyID: "job-legacy",
            jobType: "transcription",
            lastModified: Date(timeIntervalSinceReferenceDate: 105),
            modelName: "fixture-model",
            progress: 1,
            recordingName: "Fixture recording",
            recordingURL: "recording.m4a",
            recordingStorageID: "recording-storage",
            startTime: Date(timeIntervalSinceReferenceDate: 104),
            status: "complete"
        )
    }

    private func expectedArchiveLocation() -> LibraryArchiveLocationSnapshot {
        LibraryArchiveLocationSnapshot(
            storageID: "archive-storage",
            bookmarkData: Data([1, 2, 3]),
            destinationURLString: "archive://fixture",
            displayName: "Fixture archive",
            exportedAt: Date(timeIntervalSinceReferenceDate: 106),
            exportedFilename: "fixture.m4a",
            fileSize: 42,
            legacyID: "archive-legacy",
            lastVerifiedAt: Date(timeIntervalSinceReferenceDate: 107),
            providerDisplayName: "Fixture provider",
            recordingLegacyID: "recording-legacy",
            status: "verified"
        )
    }

    private func expectedPendingMutation() -> LibraryPendingCloudMutationSnapshot {
        LibraryPendingCloudMutationSnapshot(
            storageID: "mutation-storage",
            kind: "update",
            payload: Data([4, 5, 6]),
            recordingLegacyID: "recording-legacy",
            requestedAt: Date(timeIntervalSinceReferenceDate: 108),
            targetID: "recording-legacy",
            version: 1
        )
    }
}
