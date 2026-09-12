import Foundation
import GRDB
import XCTest
@testable import BisonNotes_AI

private enum MigrationProbeError: Error {
    case expected
}

final class SQLiteLibraryStoreTests: XCTestCase {
    func testSchemaBootstrapsWithDurablePragmasAndRequiredTables() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let store = try SQLiteLibraryStore(databaseURL: databaseURL)

        let diagnostics = try await store.diagnostics()
        XCTAssertFalse(diagnostics.libraryID.isEmpty)
        XCTAssertFalse(diagnostics.generationID.isEmpty)
        XCTAssertEqual(diagnostics.schemaVersion, SQLiteLibraryStore.schemaVersion)
        XCTAssertEqual(diagnostics.minimumReaderVersion, SQLiteLibraryStore.minimumReaderVersion)
        XCTAssertEqual(diagnostics.revision, 0)
        XCTAssertTrue(diagnostics.foreignKeysEnabled)
        XCTAssertEqual(diagnostics.synchronousMode, 2) // FULL
        XCTAssertEqual(diagnostics.journalMode, "wal")
        XCTAssertFalse(diagnostics.sqliteVersion.isEmpty)
        XCTAssertFalse(diagnostics.compileOptions.isEmpty)
        XCTAssertEqual(diagnostics.integrityCheck, "ok")

        let tables = Set(try await store.tableNames())
        let requiredTables: Set<String> = [
            "schema_migrations",
            "library_metadata",
            "recordings",
            "summaries",
            "transcripts",
            "processing_jobs",
            "archive_locations",
            "pending_cloud_mutations",
            "migration_runs",
            "migration_row_map",
            "asset_catalog",
            "file_operations",
            "archive_restore_operations",
            "import_receipts",
            "sync_state",
            "sync_outbox",
            "recovery_items",
            "content_revisions"
        ]
        XCTAssertTrue(requiredTables.isSubset(of: tables))
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
    }

    func testSchemaReopensWithoutReapplyingMigration() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let firstResult = try await inspectStore(at: databaseURL)

        let secondStore = try SQLiteLibraryStore(databaseURL: databaseURL)
        let secondTables = try await secondStore.tableNames()
        let secondDiagnostics = try await secondStore.diagnostics()
        XCTAssertEqual(secondTables, firstResult.tables)
        XCTAssertEqual(secondDiagnostics, firstResult.diagnostics)
    }

    func testMigrationCheckpointPersistsAndReopens() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let checkpoint: SQLiteMigrationRun
        do {
            let store = try SQLiteLibraryStore(databaseURL: databaseURL)
            let run = try await store.beginMigrationRun(
                sourceFingerprint: "core-data-fixture-sha256",
                importerVersion: "sqlite-importer-1",
                sourceModel: "BisonNotes_AI_v2",
                metadataTotal: 10,
                at: Date(timeIntervalSinceReferenceDate: 100)
            )
            XCTAssertEqual(run.phase, "preparing")
            XCTAssertEqual(run.status, "pending")

            checkpoint = try await store.checkpointMigrationRun(
                id: run.id,
                phase: "importing",
                status: "running",
                metadataCompleted: 3,
                batchCursor: Data([3, 0]),
                batchCount: 3,
                batchSHA256: "batch-sha256",
                at: Date(timeIntervalSinceReferenceDate: 200)
            )
            XCTAssertEqual(checkpoint.metadataCompleted, 3)
            XCTAssertEqual(checkpoint.batchCursor, Data([3, 0]))
            XCTAssertEqual(checkpoint.updatedAt, Date(timeIntervalSinceReferenceDate: 200))
        }

        let reopenedStore = try SQLiteLibraryStore(databaseURL: databaseURL)
        let persisted = try await reopenedStore.migrationRun(id: checkpoint.id)
        XCTAssertEqual(persisted, checkpoint)
    }

    func testInvalidMigrationCheckpointDoesNotChangeRun() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let store = try SQLiteLibraryStore(databaseURL: databaseURL)
        let run = try await store.beginMigrationRun(
            sourceFingerprint: "source",
            importerVersion: "importer",
            metadataTotal: 5
        )

        do {
            _ = try await store.checkpointMigrationRun(
                id: run.id,
                phase: "importing",
                status: "running",
                metadataCompleted: 6,
                batchCount: 1
            )
            XCTFail("Expected an invalid progress error")
        } catch {
            guard case .invalidMigrationCheckpoint = error as? SQLiteLibraryStoreError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let persisted = try await store.migrationRun(id: run.id)
        XCTAssertEqual(persisted?.metadataCompleted, 0)
        XCTAssertEqual(persisted?.phase, "preparing")

        do {
            _ = try await store.checkpointMigrationRun(
                id: "missing-run",
                phase: "importing",
                status: "running",
                metadataCompleted: 0,
                batchCount: 0
            )
            XCTFail("Expected a missing migration run error")
        } catch {
            guard case .migrationRunNotFound = error as? SQLiteLibraryStoreError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
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

        let integrityCheck = try database.read { sqliteDatabase in
            try String.fetchOne(sqliteDatabase, sql: "PRAGMA integrity_check")
        }
        XCTAssertEqual(integrityCheck, "ok")
    }

    func testFailedMigrationRollsBackItsSchemaChanges() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("migration.sqlite")
        let database = try DatabaseQueue(path: databaseURL.path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("descriptive migration identifier") { sqliteDatabase in
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

    func testMissingParentDirectoryFailsWithoutCreatingIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BisonNotesSQLite-\(UUID().uuidString)", isDirectory: true)
        let missingParent = root.appendingPathComponent("missing", isDirectory: true)
        let databaseURL = missingParent.appendingPathComponent("library.sqlite")

        XCTAssertThrowsError(try SQLiteLibraryStore(databaseURL: databaseURL)) { error in
            XCTAssertEqual(error as? SQLiteLibraryStoreError, .parentDirectoryMissing(missingParent))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BisonNotesSQLite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func inspectStore(
        at databaseURL: URL
    ) async throws -> (tables: [String], diagnostics: SQLiteLibraryStore.Diagnostics) {
        let store = try SQLiteLibraryStore(databaseURL: databaseURL)
        return (
            try await store.tableNames(),
            try await store.diagnostics()
        )
    }
}
