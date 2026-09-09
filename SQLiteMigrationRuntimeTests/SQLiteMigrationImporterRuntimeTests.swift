import Foundation
import XCTest
@testable import BisonNotesSQLiteRuntime

final class SQLiteMigrationImporterRuntimeTests: XCTestCase {
    func testImporterWritesRowsAndVerifierAcceptsReopenedDestination() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let sourceSnapshot = makeVerifierSnapshot(migrationRunID: nil)
        let store = try SQLiteLibraryStore(databaseURL: databaseURL)
        let result = try await SQLiteMigrationMetadataImporter.importSnapshot(
            sourceSnapshot,
            into: store,
            batchSize: 2,
            at: Date(timeIntervalSinceReferenceDate: 200)
        )

        XCTAssertEqual(result.importedRowCount, sourceSnapshot.rows.count)
        XCTAssertEqual(result.skippedRowCount, 0)
        XCTAssertEqual(result.run.phase, "metadata")
        XCTAssertEqual(result.run.status, "completed")
        XCTAssertEqual(result.run.metadataCompleted, sourceSnapshot.rows.count)
        XCTAssertEqual(result.run.batchCount, 3)

        let destinationSnapshot = SQLiteMigrationSourceSnapshot(
            sourceModel: sourceSnapshot.sourceModel,
            sourceFingerprint: sourceSnapshot.sourceFingerprint,
            migrationRunID: result.run.id,
            rows: sourceSnapshot.rows
        )
        let report = try SQLiteMigrationVerifier.verify(
            snapshot: destinationSnapshot,
            databaseURL: databaseURL
        )
        XCTAssertTrue(report.isValid)
        XCTAssertEqual(report.verifiedRowCount, sourceSnapshot.rows.count)

        let reopenedStore = try SQLiteLibraryStore(databaseURL: databaseURL)
        let persistedRun = try await reopenedStore.migrationRun(id: result.run.id)
        XCTAssertEqual(persistedRun, result.run)
    }

    func testImporterResumesCommittedBatchWithoutDuplicatingRows() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let sourceSnapshot = makeVerifierSnapshot(migrationRunID: nil)
        let store = try SQLiteLibraryStore(databaseURL: databaseURL)
        let run = try await store.beginMigrationRun(
            sourceFingerprint: sourceSnapshot.sourceFingerprint,
            importerVersion: SQLiteMigrationMetadataImporter.version,
            sourceModel: sourceSnapshot.sourceModel,
            metadataTotal: sourceSnapshot.rows.count,
            at: Date(timeIntervalSinceReferenceDate: 300)
        )
        let firstBatch = Array(
            SQLiteMigrationImportSupport.orderedRows(sourceSnapshot.rows).prefix(2)
        )
        let firstResult = try await store.importMetadataBatch(
            runID: run.id,
            rows: firstBatch,
            at: Date(timeIntervalSinceReferenceDate: 301)
        )
        XCTAssertEqual(firstResult.importedRowCount, 2)
        XCTAssertEqual(firstResult.skippedRowCount, 0)
        XCTAssertEqual(firstResult.run.metadataCompleted, 2)

        let reopenedStore = try SQLiteLibraryStore(databaseURL: databaseURL)
        let resumed = try await SQLiteMigrationMetadataImporter.importSnapshot(
            sourceSnapshot,
            into: reopenedStore,
            batchSize: 2,
            runID: run.id,
            at: Date(timeIntervalSinceReferenceDate: 400)
        )

        XCTAssertEqual(resumed.importedRowCount, 4)
        XCTAssertEqual(resumed.skippedRowCount, 2)
        XCTAssertEqual(resumed.run.metadataCompleted, sourceSnapshot.rows.count)
        XCTAssertEqual(resumed.run.status, "completed")
        XCTAssertEqual(resumed.run.batchCount, 3)

        let destinationSnapshot = SQLiteMigrationSourceSnapshot(
            sourceModel: sourceSnapshot.sourceModel,
            sourceFingerprint: sourceSnapshot.sourceFingerprint,
            migrationRunID: resumed.run.id,
            rows: sourceSnapshot.rows
        )
        let report = try SQLiteMigrationVerifier.verify(
            snapshot: destinationSnapshot,
            databaseURL: databaseURL
        )
        XCTAssertTrue(report.isValid)
    }
}
