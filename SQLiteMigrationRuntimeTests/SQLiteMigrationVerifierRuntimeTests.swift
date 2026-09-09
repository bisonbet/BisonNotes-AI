import Foundation
import GRDB
import XCTest
@testable import BisonNotesSQLiteRuntime

final class SQLiteMigrationVerifierRuntimeTests: XCTestCase {
    func testVerifierAcceptsCompleteClosedSourceSnapshot() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let snapshot: SQLiteMigrationSourceSnapshot
        do {
            let store = try SQLiteLibraryStore(databaseURL: databaseURL)
            let run = try await store.beginMigrationRun(
                sourceFingerprint: "closed-fixture-sha256",
                importerVersion: "fixture-importer-1",
                sourceModel: "BisonNotes_AI_v2"
            )
            snapshot = makeVerifierSnapshot(migrationRunID: run.id)
        }

        try insertVerifierRows(rows: snapshot.rows, into: databaseURL)
        let report = try SQLiteMigrationVerifier.verify(
            snapshot: snapshot,
            databaseURL: databaseURL
        )

        XCTAssertTrue(report.isValid)
        XCTAssertEqual(report.expectedRowCount, 6)
        XCTAssertEqual(report.verifiedRowCount, 6)
        XCTAssertTrue(report.mismatches.isEmpty)
    }

    func testVerifierReportsValueAndUnexpectedRowMismatches() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let snapshot: SQLiteMigrationSourceSnapshot
        do {
            let store = try SQLiteLibraryStore(databaseURL: databaseURL)
            let run = try await store.beginMigrationRun(
                sourceFingerprint: "closed-fixture-sha256",
                importerVersion: "fixture-importer-1"
            )
            snapshot = makeVerifierSnapshot(migrationRunID: run.id)
        }

        try insertVerifierRows(rows: snapshot.rows, into: databaseURL)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        do {
            let database = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
            try await database.write { sqliteDatabase in
                try sqliteDatabase.execute(
                    sql: "UPDATE recordings SET recordingName = ? WHERE storageID = ?",
                    arguments: ["changed", "recording-storage"]
                )
                try sqliteDatabase.execute(
                    sql: "INSERT INTO recordings (storageID) VALUES (?)",
                    arguments: ["unexpected-recording"]
                )
                try sqliteDatabase.execute(
                    sql: "DELETE FROM processing_jobs WHERE storageID = ?",
                    arguments: ["job-storage"]
                )
            }
        }

        let report = try SQLiteMigrationVerifier.verify(
            snapshot: snapshot,
            databaseURL: databaseURL
        )
        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.mismatches.contains { $0.kind == .valueMismatch })
        XCTAssertTrue(report.mismatches.contains { $0.kind == .unexpectedRow })
        XCTAssertTrue(report.mismatches.contains { $0.kind == .missingRow })
    }

    func testVerifierRejectsIncompleteSnapshotRows() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let store = try SQLiteLibraryStore(databaseURL: databaseURL)
        let run = try await store.beginMigrationRun(
            sourceFingerprint: "closed-fixture-sha256",
            importerVersion: "fixture-importer-1"
        )
        let snapshot = makeVerifierSnapshot(migrationRunID: run.id)
        var incompleteValues = snapshot.rows[0].values
        incompleteValues.removeValue(forKey: "recordingName")
        let incompleteRow = SQLiteMigrationExpectedRow(
            entity: snapshot.rows[0].entity,
            sourceObjectID: snapshot.rows[0].sourceObjectID,
            destinationStorageID: snapshot.rows[0].destinationStorageID,
            values: incompleteValues
        )
        var incompleteRows = snapshot.rows
        incompleteRows[0] = incompleteRow
        let incompleteSnapshot = SQLiteMigrationSourceSnapshot(
            sourceModel: snapshot.sourceModel,
            sourceFingerprint: snapshot.sourceFingerprint,
            migrationRunID: snapshot.migrationRunID,
            rows: incompleteRows
        )

        XCTAssertThrowsError(
            try SQLiteMigrationVerifier.verify(
                snapshot: incompleteSnapshot,
                databaseURL: databaseURL
            )
        ) { error in
            guard case .invalidSnapshot = error as? SQLiteMigrationVerificationError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}
