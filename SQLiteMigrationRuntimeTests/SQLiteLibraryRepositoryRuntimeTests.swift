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
                isCloudSyncDisabled: false,
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

    func testRepositoryRenamesRecordingWithExpectedRevision() async throws {
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
        let updated = try await repository.renameRecording(
            LibraryRecordingRenameCommand(
                reference: LibraryRecordingReference(storageID: "recording-storage"),
                name: "Renamed [Watch]",
                expectedLastModified: Date(timeIntervalSinceReferenceDate: 101),
                modifiedAt: Date(timeIntervalSinceReferenceDate: 300)
            )
        )

        XCTAssertEqual(updated.name, "Renamed")
        XCTAssertEqual(updated.lastModified, Date(timeIntervalSinceReferenceDate: 300))
        let persistedRecordings = try await repository.fetchRecordingSummaries()
        XCTAssertEqual(persistedRecordings.first?.name, "Renamed")
    }

    func testRepositoryCloudSyncToggleCommitsRecordingAndPendingMutationTogether() async throws {
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

        let disabled = try await repository.setCloudSyncDisabled(
            LibraryRecordingCloudSyncCommand(
                reference: LibraryRecordingReference(storageID: "recording-storage"),
                disabled: true,
                expectedLastModified: Date(timeIntervalSinceReferenceDate: 101),
                modifiedAt: Date(timeIntervalSinceReferenceDate: 300),
                requestedAt: Date(timeIntervalSinceReferenceDate: 250)
            )
        )

        XCTAssertEqual(disabled.isCloudSyncDisabled, true)
        XCTAssertEqual(disabled.lastModified, Date(timeIntervalSinceReferenceDate: 300))
        let pendingAfterDisable = try await repository.fetchPendingCloudMutationSnapshots()
            .filter { $0.kind == "localOnlyRemoval" }
        XCTAssertEqual(pendingAfterDisable.count, 1)
        XCTAssertEqual(pendingAfterDisable[0].storageID, "local-only-removal-recording-storage")
        XCTAssertEqual(pendingAfterDisable[0].targetID, "recording-legacy")
        XCTAssertNil(pendingAfterDisable[0].recordingLegacyID)
        XCTAssertEqual(
            pendingAfterDisable[0].requestedAt,
            Date(timeIntervalSinceReferenceDate: 250)
        )

        let changesAfterDisable = try await repository.changes(since: 0)
        XCTAssertEqual(changesAfterDisable.map(\.revision), [1, 2])
        XCTAssertEqual(changesAfterDisable.map(\.entity), [.recording, .pendingCloudMutation])
        XCTAssertEqual(changesAfterDisable.map(\.operation), [.updated, .inserted])

        let enabled = try await repository.setCloudSyncDisabled(
            LibraryRecordingCloudSyncCommand(
                reference: LibraryRecordingReference(storageID: "recording-storage"),
                disabled: false,
                expectedLastModified: Date(timeIntervalSinceReferenceDate: 300),
                modifiedAt: Date(timeIntervalSinceReferenceDate: 301)
            )
        )

        XCTAssertEqual(enabled.isCloudSyncDisabled, false)
        XCTAssertEqual(enabled.lastModified, Date(timeIntervalSinceReferenceDate: 301))
        let pendingAfterEnable = try await repository.fetchPendingCloudMutationSnapshots()
            .filter { $0.kind == "localOnlyRemoval" }
        XCTAssertTrue(pendingAfterEnable.isEmpty)

        let changesAfterEnable = try await repository.changes(since: 2)
        XCTAssertEqual(changesAfterEnable.map(\.revision), [3, 4])
        XCTAssertEqual(changesAfterEnable.map(\.entity), [.recording, .pendingCloudMutation])
        XCTAssertEqual(changesAfterEnable.map(\.operation), [.updated, .deleted])
    }

    func testRepositoryUpdatesProcessingJobWithExplicitPreserveAndClearSemantics() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        let sourceSnapshot = makeVerifierSnapshot(migrationRunID: nil)
        _ = try await SQLiteMigrationMetadataImporter.importSnapshot(
            sourceSnapshot,
            into: store,
            batchSize: sourceSnapshot.rows.count,
            at: Date(timeIntervalSinceReferenceDate: 200)
        )
        let repository = SQLiteLibraryRepository(store: store)
        let jobReference = LibraryProcessingJobReference(storageID: "job-storage")

        let failed = try await repository.updateProcessingJob(
            LibraryProcessingJobUpdateCommand(
                reference: jobReference,
                status: "failed",
                progress: 0.75,
                error: .set("Processing failed"),
                completionTime: .set(Date(timeIntervalSinceReferenceDate: 300)),
                expectedLastModified: Date(timeIntervalSinceReferenceDate: 105),
                modifiedAt: Date(timeIntervalSinceReferenceDate: 301)
            )
        )

        XCTAssertEqual(failed.status, "failed")
        XCTAssertEqual(failed.progress, 0.75)
        XCTAssertEqual(failed.error, "Processing failed")
        XCTAssertEqual(
            failed.completionTime,
            Date(timeIntervalSinceReferenceDate: 300)
        )
        XCTAssertEqual(failed.lastModified, Date(timeIntervalSinceReferenceDate: 301))

        let preserved = try await repository.updateProcessingJob(
            LibraryProcessingJobUpdateCommand(
                reference: jobReference,
                status: "processing",
                progress: 0.8,
                expectedLastModified: Date(timeIntervalSinceReferenceDate: 301),
                modifiedAt: Date(timeIntervalSinceReferenceDate: 302)
            )
        )

        XCTAssertEqual(preserved.error, "Processing failed")
        XCTAssertEqual(
            preserved.completionTime,
            Date(timeIntervalSinceReferenceDate: 300)
        )

        let cleared = try await repository.updateProcessingJob(
            LibraryProcessingJobUpdateCommand(
                reference: jobReference,
                status: "queued",
                progress: 0,
                error: .set(nil),
                completionTime: .set(nil),
                expectedLastModified: Date(timeIntervalSinceReferenceDate: 302),
                modifiedAt: Date(timeIntervalSinceReferenceDate: 303)
            )
        )

        XCTAssertNil(cleared.error)
        XCTAssertNil(cleared.completionTime)
        let changes = try await repository.changes(since: 0)
        let revision = try await repository.currentRevision()
        XCTAssertEqual(revision, 3)
        XCTAssertEqual(
            changes.map(\.entity),
            [.processingJob, .processingJob, .processingJob]
        )
        XCTAssertEqual(
            changes.map(\.operation),
            [.updated, .updated, .updated]
        )

        do {
            _ = try await repository.updateProcessingJob(
                LibraryProcessingJobUpdateCommand(
                    reference: jobReference,
                    status: "processing",
                    progress: 0.1,
                    expectedLastModified: Date(timeIntervalSinceReferenceDate: 105),
                    modifiedAt: Date(timeIntervalSinceReferenceDate: 304)
                )
            )
            XCTFail("Expected stale processing-job revision to be rejected")
        } catch let error as LibraryRepositoryError {
            XCTAssertEqual(
                error,
                .staleProcessingJob(
                    reference: "job-storage",
                    expected: Date(timeIntervalSinceReferenceDate: 105),
                    actual: Date(timeIntervalSinceReferenceDate: 303)
                )
            )
        }
        let revisionAfterRejectedUpdate = try await repository.currentRevision()
        XCTAssertEqual(revisionAfterRejectedUpdate, 3)
    }

    func testRepositoryRenameRejectsStaleRevisionWithoutChangingTheRow() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceSnapshot = makeVerifierSnapshot(migrationRunID: nil)
        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        _ = try await SQLiteMigrationMetadataImporter.importSnapshot(
            sourceSnapshot,
            into: store,
            batchSize: sourceSnapshot.rows.count
        )
        let repository = SQLiteLibraryRepository(store: store)

        do {
            _ = try await repository.renameRecording(
                LibraryRecordingRenameCommand(
                    reference: LibraryRecordingReference(storageID: "recording-storage"),
                    name: "Should not persist",
                    expectedLastModified: Date(timeIntervalSinceReferenceDate: 999),
                    modifiedAt: Date(timeIntervalSinceReferenceDate: 300)
                )
            )
            XCTFail("Expected the stale revision to be rejected")
        } catch let error as LibraryRepositoryError {
            XCTAssertEqual(
                error,
                .staleRecording(
                    reference: "recording-storage",
                    expected: Date(timeIntervalSinceReferenceDate: 999),
                    actual: Date(timeIntervalSinceReferenceDate: 101)
                )
            )
        }

        let persistedRecordings = try await repository.fetchRecordingSummaries()
        XCTAssertEqual(persistedRecordings.first?.name, "Fixture recording")
        let revisionAfterRejectedRename = try await repository.currentRevision()
        XCTAssertEqual(revisionAfterRejectedRename, 0)
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
