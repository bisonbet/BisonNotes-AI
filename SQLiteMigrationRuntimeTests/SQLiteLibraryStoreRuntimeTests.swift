import Foundation
import GRDB
import XCTest
@testable import BisonNotesSQLiteRuntime

private enum MigrationProbeError: Error {
    case expected
}

final class SQLiteLibraryStoreRuntimeTests: XCTestCase {
    func testDatabaseBootstrapsOutsideAnAppHost() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let store = try SQLiteLibraryStore(databaseURL: databaseURL)
        let diagnostics = try await store.diagnostics()
        let tables = Set(try await store.tableNames())

        XCTAssertFalse(diagnostics.libraryID.isEmpty)
        XCTAssertFalse(diagnostics.generationID.isEmpty)
        XCTAssertEqual(diagnostics.schemaVersion, SQLiteLibraryStore.schemaVersion)
        XCTAssertTrue(diagnostics.foreignKeysEnabled)
        XCTAssertEqual(diagnostics.synchronousMode, 2) // FULL
        XCTAssertEqual(diagnostics.journalMode, "wal")
        XCTAssertEqual(diagnostics.integrityCheck, "ok")
        XCTAssertTrue(tables.contains("migration_runs"))
        XCTAssertTrue(tables.contains("library_changes"))
        XCTAssertTrue(tables.contains("library_metadata"))
    }

    func testCheckpointPersistsAcrossReopenOutsideAnAppHost() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let checkpoint: SQLiteMigrationRun
        do {
            let store = try SQLiteLibraryStore(databaseURL: databaseURL)
            let run = try await store.beginMigrationRun(
                sourceFingerprint: "fixture-source",
                importerVersion: "fixture-importer-1",
                metadataTotal: 4,
                at: Date(timeIntervalSinceReferenceDate: 100)
            )
            checkpoint = try await store.checkpointMigrationRun(
                id: run.id,
                phase: "importing",
                status: "running",
                metadataCompleted: 2,
                batchCursor: Data([2]),
                batchCount: 2,
                batchSHA256: "fixture-batch",
                at: Date(timeIntervalSinceReferenceDate: 200)
            )
        }

        let reopenedStore = try SQLiteLibraryStore(databaseURL: databaseURL)
        let persisted = try await reopenedStore.migrationRun(id: checkpoint.id)
        XCTAssertEqual(persisted, checkpoint)
    }

    func testInvalidCheckpointLeavesDurableStateUnchanged() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let store = try SQLiteLibraryStore(databaseURL: databaseURL)
        let run = try await store.beginMigrationRun(
            sourceFingerprint: "fixture-source",
            importerVersion: "fixture-importer-1",
            metadataTotal: 2
        )

        do {
            _ = try await store.checkpointMigrationRun(
                id: run.id,
                phase: "importing",
                status: "running",
                metadataCompleted: 3,
                batchCount: 1
            )
            XCTFail("Expected invalid progress to be rejected")
        } catch {
            guard case .invalidMigrationCheckpoint = error as? SQLiteLibraryStoreError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let persisted = try await store.migrationRun(id: run.id)
        XCTAssertEqual(persisted?.metadataCompleted, 0)
        XCTAssertEqual(persisted?.phase, "preparing")
    }

    func testRelationshipForeignKeysRejectMissingRowsAndRestrictDeletes() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("library.sqlite")
        do {
            _ = try SQLiteLibraryStore(databaseURL: databaseURL)
        }

        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let database = try DatabaseQueue(path: databaseURL.path, configuration: configuration)

        XCTAssertThrowsError(try database.write { sqliteDatabase in
            try sqliteDatabase.execute(
                sql: """
                INSERT INTO transcripts (storageID, recordingStorageID)
                VALUES (?, ?)
                """,
                arguments: ["transcript", "missing-recording"]
            )
        })

        try database.write { sqliteDatabase in
            try sqliteDatabase.execute(
                sql: "INSERT INTO recordings (storageID) VALUES (?)",
                arguments: ["recording"]
            )
            try sqliteDatabase.execute(
                sql: """
                INSERT INTO transcripts (storageID, recordingStorageID)
                VALUES (?, ?)
                """,
                arguments: ["transcript", "recording"]
            )
        }

        XCTAssertThrowsError(try database.write { sqliteDatabase in
            try sqliteDatabase.execute(
                sql: "DELETE FROM recordings WHERE storageID = ?",
                arguments: ["recording"]
            )
        })
    }

    func testFailedMigrationRollsBackItsSchemaChanges() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("migration.sqlite")
        let database = try DatabaseQueue(path: databaseURL.path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("fixture migration") { sqliteDatabase in
            try sqliteDatabase.create(table: "should_rollback") { table in
                table.autoIncrementedPrimaryKey("id")
            }
            throw MigrationProbeError.expected
        }

        XCTAssertThrowsError(try migrator.migrate(database))
        let tableExists = try database.read { sqliteDatabase in
            try Bool.fetchOne(
                sqliteDatabase,
                sql: """
                SELECT EXISTS(
                    SELECT 1 FROM sqlite_master
                    WHERE type = 'table' AND name = 'should_rollback'
                )
                """
            ) ?? false
        }
        XCTAssertFalse(tableExists)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BisonNotesSQLiteRuntime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

}
