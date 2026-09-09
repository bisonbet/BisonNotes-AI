import Foundation
import GRDB
import XCTest
@testable import BisonNotesSQLiteRuntime

final class SQLiteLibraryStoreMigrationVersionTests: XCTestCase {
    func testExistingV2StoreMigratesToV3ObservationSchema() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let legacyDatabase = try DatabaseQueue(path: databaseURL.path)
        var legacyMigrator = DatabaseMigrator()
        legacyMigrator.registerMigration("v1") { database in
            try SQLiteLibraryStoreSchema.createInitial(in: database)
            try database.execute(
                sql: """
                INSERT INTO schema_migrations (version, identifier, appliedAt)
                VALUES (?, ?, ?)
                """,
                arguments: [1, "v1", Date().timeIntervalSinceReferenceDate]
            )
        }
        legacyMigrator.registerMigration("v2") { database in
            try SQLiteLibraryStoreSchema.addSettings(in: database)
            try database.execute(
                sql: """
                INSERT INTO schema_migrations (version, identifier, appliedAt)
                VALUES (?, ?, ?)
                """,
                arguments: [2, "v2", Date().timeIntervalSinceReferenceDate]
            )
        }
        try legacyMigrator.migrate(legacyDatabase)

        let store = try SQLiteLibraryStore(databaseURL: databaseURL)
        let diagnostics = try await store.diagnostics()
        let tables = Set(try await store.tableNames())
        XCTAssertEqual(diagnostics.schemaVersion, 3)
        XCTAssertEqual(diagnostics.revision, 0)
        XCTAssertTrue(tables.contains("library_settings"))
        XCTAssertTrue(tables.contains("library_changes"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BisonNotesSQLiteRuntime-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
