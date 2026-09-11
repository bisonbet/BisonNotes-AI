import Foundation
import XCTest
@testable import BisonNotesSQLiteRuntime

final class SQLiteLibraryObservationRuntimeTests: XCTestCase {
    func testSubscriptionAnchorsBeforeSnapshotAndAdvancesOnce() async throws {
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
        var subscription = try await LibraryObservationSubscription.anchored(to: repository)

        _ = try await repository.renameRecording(
            LibraryRecordingRenameCommand(
                reference: LibraryRecordingReference(storageID: "recording-storage"),
                name: "Renamed [Watch]",
                expectedLastModified: Date(timeIntervalSinceReferenceDate: 101),
                modifiedAt: Date(timeIntervalSinceReferenceDate: 300)
            )
        )

        let changes = try await subscription.poll()
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].revision, 1)
        XCTAssertEqual(subscription.cursor, 1)
        let emptyPoll = try await subscription.poll()
        XCTAssertTrue(emptyPoll.isEmpty)
    }

    func testSubscriptionRejectsInvalidStartingRevisionAndSupportsCancellation() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        let repository = SQLiteLibraryRepository(store: store)

        XCTAssertThrowsError(
            try LibraryObservationSubscription(
                observation: repository,
                startingRevision: -1
            )
        ) { error in
            XCTAssertEqual(error as? LibraryObservationError, .invalidCursor(-1))
        }

        var subscription = try LibraryObservationSubscription(observation: repository)
        subscription.cancel()
        let cancelledPoll = try await subscription.poll()
        XCTAssertTrue(cancelledPoll.isEmpty)
        XCTAssertTrue(subscription.isCancelled)
    }

    func testTracksCommittedRenameAcrossReopen() async throws {
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

    func testRejectsInvalidCursors() async throws {
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
}
