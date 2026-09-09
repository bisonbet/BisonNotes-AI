import Foundation
import XCTest
@testable import BisonNotesSQLiteRuntime

final class SQLiteMigrationCoordinatorRuntimeTests: XCTestCase {
    func testCoordinatorReportsCommittedProgressAndVerifiesDestination() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let snapshot = makeVerifierSnapshot(migrationRunID: nil)
        let store = try SQLiteLibraryStore(databaseURL: databaseURL)
        let recorder = MigrationProgressRecorder()

        let result = try await SQLiteMigrationCoordinator().migrate(
            snapshot: snapshot,
            into: store,
            batchSize: 2,
            at: Date(timeIntervalSinceReferenceDate: 500),
            progress: { progress in
                await recorder.append(progress)
            }
        )

        XCTAssertTrue(result.verification.isValid)
        XCTAssertEqual(result.run.status, "completed")
        let events = await recorder.values
        XCTAssertEqual(events.first?.phase, .preparing)
        XCTAssertEqual(events.dropFirst().first?.phase, .importingMetadata)
        XCTAssertEqual(events.last?.phase, .completed)
        XCTAssertEqual(
            events.filter { $0.phase == .importingMetadata }.map(\.metadataCompleted),
            [0, 2, 4, 6]
        )
        XCTAssertEqual(events.filter { $0.phase == .verifying }.count, 1)
        XCTAssertEqual(events.last?.fractionCompleted, 1)
    }

    func testCoordinatorResumesNewestUnfinishedRunAfterStoreReopen() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let snapshot = makeVerifierSnapshot(migrationRunID: nil)
        let store = try SQLiteLibraryStore(databaseURL: databaseURL)
        let initialRun = try await store.beginMigrationRun(
            sourceFingerprint: snapshot.sourceFingerprint,
            importerVersion: SQLiteMigrationMetadataImporter.version,
            sourceModel: snapshot.sourceModel,
            metadataTotal: snapshot.rows.count,
            at: Date(timeIntervalSinceReferenceDate: 600)
        )
        let firstBatch = Array(
            SQLiteMigrationImportSupport.orderedRows(snapshot.rows).prefix(2)
        )
        _ = try await store.importMetadataBatch(
            runID: initialRun.id,
            rows: firstBatch,
            at: Date(timeIntervalSinceReferenceDate: 601)
        )

        let reopenedStore = try SQLiteLibraryStore(databaseURL: databaseURL)
        let result = try await SQLiteMigrationCoordinator().migrate(
            snapshot: snapshot,
            into: reopenedStore,
            batchSize: 2,
            at: Date(timeIntervalSinceReferenceDate: 700)
        )

        XCTAssertEqual(result.run.id, initialRun.id)
        XCTAssertEqual(result.run.metadataCompleted, snapshot.rows.count)
        XCTAssertEqual(result.run.batchCount, 3)
        XCTAssertTrue(result.verification.isValid)
    }

    func testCoordinatorFailsDefinitiveConflictWithoutPersistingRawErrorText() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let snapshot = makeVerifierSnapshot(migrationRunID: nil)
        guard let targetRow = SQLiteMigrationImportSupport.orderedRows(snapshot.rows).first else {
            return XCTFail("Expected the fixture to contain a recording row")
        }
        let store = try SQLiteLibraryStore(databaseURL: databaseURL)

        let unrelatedRun = try await store.beginMigrationRun(
            sourceFingerprint: "unrelated-source",
            importerVersion: SQLiteMigrationMetadataImporter.version,
            sourceModel: snapshot.sourceModel,
            metadataTotal: 1,
            at: Date(timeIntervalSinceReferenceDate: 800)
        )
        _ = try await store.importMetadataBatch(
            runID: unrelatedRun.id,
            rows: [targetRow],
            at: Date(timeIntervalSinceReferenceDate: 801)
        )

        let recorder = MigrationProgressRecorder()
        do {
            _ = try await SQLiteMigrationCoordinator().migrate(
                snapshot: snapshot,
                into: store,
                batchSize: 1,
                at: Date(timeIntervalSinceReferenceDate: 900),
                progress: { progress in
                    await recorder.append(progress)
                }
            )
            XCTFail("Expected the destination conflict to block migration")
        } catch let error as SQLiteMigrationImportError {
            guard case .destinationRowConflict(_, let storageID, _) = error else {
                return XCTFail("Unexpected migration error: \(error)")
            }
            XCTAssertEqual(storageID, targetRow.destinationStorageID)
        }

        let events = await recorder.values
        guard let failedEvent = events.last(where: { $0.phase == .failed }),
              let failedRunID = failedEvent.runID else {
            return XCTFail("Expected a persisted failed-run progress event")
        }
        let failedRun = try await store.migrationRun(id: failedRunID)
        XCTAssertEqual(failedRun?.status, "failed")
        XCTAssertEqual(
            failedRun?.errorMessage,
            "metadata migration stopped; recovery report required"
        )
        XCTAssertFalse(failedRun?.errorMessage?.contains(targetRow.destinationStorageID) == true)
    }
}

private actor MigrationProgressRecorder {
    private(set) var values: [SQLiteMigrationProgress] = []

    func append(_ value: SQLiteMigrationProgress) {
        values.append(value)
    }
}
