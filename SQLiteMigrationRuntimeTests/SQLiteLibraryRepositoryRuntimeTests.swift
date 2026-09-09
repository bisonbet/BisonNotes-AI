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

    func testSQLiteObservationTracksCommittedRenameAcrossReopen() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let sourceSnapshot = makeVerifierSnapshot(migrationRunID: nil)
        let store = try SQLiteLibraryStore(databaseURL: databaseURL)
        _ = try await SQLiteMigrationMetadataImporter.importSnapshot(
            sourceSnapshot,
            into: store,
            batchSize: sourceSnapshot.rows.count,
            at: Date(timeIntervalSinceReferenceDate: 200)
        )
        let repository = SQLiteLibraryRepository(store: store)

        let initialRevision = try await repository.currentRevision()
        let initialChanges = try await repository.changes(since: 0)
        XCTAssertEqual(initialRevision, 0)
        XCTAssertTrue(initialChanges.isEmpty)

        _ = try await repository.renameRecording(
            LibraryRecordingRenameCommand(
                reference: LibraryRecordingReference(storageID: "recording-storage"),
                name: "Renamed [Watch]",
                expectedLastModified: Date(timeIntervalSinceReferenceDate: 101),
                modifiedAt: Date(timeIntervalSinceReferenceDate: 300)
            )
        )

        let expectedChange = LibraryChange(
            revision: 1,
            entity: .recording,
            storageID: "recording-storage",
            operation: .updated,
            committedAt: Date(timeIntervalSinceReferenceDate: 300)
        )
        let revisionAfterRename = try await repository.currentRevision()
        let changesAfterRename = try await repository.changes(since: 0)
        let changesAfterCursor = try await repository.changes(since: 1)
        XCTAssertEqual(revisionAfterRename, 1)
        XCTAssertEqual(changesAfterRename, [expectedChange])
        XCTAssertTrue(changesAfterCursor.isEmpty)

        let reopenedStore = try SQLiteLibraryStore(databaseURL: databaseURL)
        let reopenedRepository = SQLiteLibraryRepository(store: reopenedStore)
        let reopenedRevision = try await reopenedRepository.currentRevision()
        let reopenedChanges = try await reopenedRepository.changes(since: 0)
        XCTAssertEqual(reopenedRevision, 1)
        XCTAssertEqual(reopenedChanges, [expectedChange])
    }

    func testSQLiteObservationRejectsInvalidCursors() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        let repository = SQLiteLibraryRepository(store: store)

        do {
            _ = try await repository.changes(since: -1)
            XCTFail("Expected a negative observation cursor to be rejected")
        } catch let error as LibraryObservationError {
            XCTAssertEqual(error, .invalidCursor(-1))
        }

        do {
            _ = try await repository.changes(since: 1)
            XCTFail("Expected an observation cursor ahead of the library to be rejected")
        } catch let error as LibraryObservationError {
            XCTAssertEqual(error, .cursorAhead(current: 0, requested: 1))
        }
    }

    func testSQLiteSettingsStoreRoundTripsTypedAllowlistedValues() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        let settings = try SQLiteLibrarySettingsStore(
            store: store,
            allowedKeys: ["timeFormat", "enabled", "count", "timeout", "payload", "date"]
        )
        let snapshot = LibrarySettingsSnapshot(values: [
            "timeFormat": .string("24h"),
            "enabled": .bool(true),
            "count": .integer(42),
            "timeout": .real(180.5),
            "payload": .data(Data([1, 2, 3])),
            "date": .date(Date(timeIntervalSinceReferenceDate: 123))
        ])

        try await settings.apply(snapshot)
        let persistedSnapshot = try await settings.read()
        XCTAssertEqual(persistedSnapshot, snapshot)
        let repository = SQLiteLibraryRepository(store: store)
        let settingsRevision = try await repository.currentRevision()
        let settingChanges = try await repository.changes(since: 0)
        XCTAssertEqual(settingsRevision, 6)
        XCTAssertEqual(
            settingChanges.map(\.entity),
            Array(repeating: .setting, count: 6)
        )

        do {
            try await settings.apply(
                LibrarySettingsSnapshot(values: ["notAllowed": .string("secret")])
            )
            XCTFail("Expected the settings allowlist to reject the key")
        } catch let error as LibrarySettingsStoreError {
            XCTAssertEqual(error, .disallowedKey("notAllowed"))
        }
    }

    func testUserDefaultsSettingsStoreUsesOnlyItsAllowlist() async throws {
        let suiteName = "BisonNotesSQLiteRuntimeTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create an isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("untouched", forKey: "outsideAllowlist")
        let settings = try UserDefaultsLibrarySettingsStore(
            defaults: defaults,
            allowedKeys: ["timeFormat", "enabled"]
        )
        let snapshot = LibrarySettingsSnapshot(values: [
            "timeFormat": .string("12h"),
            "enabled": .bool(false)
        ])

        try await settings.apply(snapshot)
        let persistedSnapshot = try await settings.read()
        XCTAssertEqual(persistedSnapshot, snapshot)
        XCTAssertEqual(defaults.string(forKey: "outsideAllowlist"), "untouched")

        do {
            try await settings.apply(
                LibrarySettingsSnapshot(values: ["outsideAllowlist": .string("changed")])
            )
            XCTFail("Expected the defaults allowlist to reject the key")
        } catch let error as LibrarySettingsStoreError {
            XCTAssertEqual(error, .disallowedKey("outsideAllowlist"))
        }
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
