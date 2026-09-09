import Foundation
import GRDB

/// Errors raised while opening the app-owned SQLite generation.
enum SQLiteLibraryStoreError: LocalizedError, Equatable {
    case invalidDatabaseURL
    case parentDirectoryMissing(URL)
    case invalidMetadata
    case unsupportedConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .invalidDatabaseURL:
            return "The SQLite database URL is invalid."
        case .parentDirectoryMissing(let directory):
            return "The SQLite database directory does not exist: \(directory.path)"
        case .invalidMetadata:
            return "The SQLite database metadata is incomplete."
        case .unsupportedConfiguration(let detail):
            return "The SQLite database configuration is unsupported: \(detail)"
        }
    }
}

private struct SQLiteLibraryMetadata {
    let libraryID: String
    let generationID: String
    let schemaVersion: Int
    let minimumReaderVersion: Int
    let revision: Int
}

private struct SQLiteRuntimeSnapshot {
    let foreignKeysEnabled: Bool
    let synchronousMode: Int
    let journalMode: String
    let sqliteVersion: String
    let compileOptions: [String]
    let integrityCheck: String
}

private func readSQLiteLibraryMetadata(from database: Database) throws -> SQLiteLibraryMetadata {
    guard let schemaVersion = try Int.fetchOne(
        database,
        sql: "SELECT MAX(version) FROM schema_migrations"
    ) else {
        throw SQLiteLibraryStoreError.invalidMetadata
    }
    guard let metadataSchemaVersion = try Int.fetchOne(
        database,
        sql: "SELECT schemaVersion FROM library_metadata WHERE id = 1"
    ), metadataSchemaVersion == schemaVersion else {
        throw SQLiteLibraryStoreError.invalidMetadata
    }
    guard let libraryID = try String.fetchOne(
        database,
        sql: "SELECT libraryID FROM library_metadata WHERE id = 1"
    ), !libraryID.isEmpty else {
        throw SQLiteLibraryStoreError.invalidMetadata
    }
    guard let generationID = try String.fetchOne(
        database,
        sql: "SELECT generationID FROM library_metadata WHERE id = 1"
    ), !generationID.isEmpty else {
        throw SQLiteLibraryStoreError.invalidMetadata
    }
    guard let minimumReaderVersion = try Int.fetchOne(
        database,
        sql: "SELECT minimumReaderVersion FROM library_metadata WHERE id = 1"
    ), minimumReaderVersion > 0 else {
        throw SQLiteLibraryStoreError.invalidMetadata
    }
    guard let revision = try Int.fetchOne(
        database,
        sql: "SELECT revision FROM library_metadata WHERE id = 1"
    ) else {
        throw SQLiteLibraryStoreError.invalidMetadata
    }

    return SQLiteLibraryMetadata(
        libraryID: libraryID,
        generationID: generationID,
        schemaVersion: schemaVersion,
        minimumReaderVersion: minimumReaderVersion,
        revision: revision
    )
}

private func readSQLiteRuntimeSnapshot(from database: Database) throws -> SQLiteRuntimeSnapshot {
    SQLiteRuntimeSnapshot(
        foreignKeysEnabled: (try Int.fetchOne(database, sql: "PRAGMA foreign_keys") ?? 0) == 1,
        synchronousMode: try Int.fetchOne(database, sql: "PRAGMA synchronous") ?? 0,
        journalMode: try String.fetchOne(database, sql: "PRAGMA journal_mode") ?? "",
        sqliteVersion: try String.fetchOne(database, sql: "SELECT sqlite_version()") ?? "",
        compileOptions: try String.fetchAll(database, sql: "PRAGMA compile_options").sorted(),
        integrityCheck: try String.fetchOne(database, sql: "PRAGMA integrity_check") ?? ""
    )
}

/// The first app-owned SQLite schema. This is intentionally not connected to
/// the production Core Data coordinator yet. It provides one serialized writer,
/// durable schema migrations and the operational tables required by the import
/// and recovery work that follows.
actor SQLiteLibraryStore {
    static let schemaVersion = 1
    static let minimumReaderVersion = 1
    static let schemaMigrationIdentifier = "v1"

    struct Diagnostics: Equatable, Sendable {
        let libraryID: String
        let generationID: String
        let schemaVersion: Int
        let minimumReaderVersion: Int
        let revision: Int
        let foreignKeysEnabled: Bool
        let synchronousMode: Int
        let journalMode: String
        let sqliteVersion: String
        let compileOptions: [String]
        let integrityCheck: String
    }

    let databaseURL: URL
    private let databaseQueue: DatabaseQueue

    init(databaseURL: URL, fileManager: FileManager = .default) throws {
        guard databaseURL.isFileURL, !databaseURL.path.isEmpty else {
            throw SQLiteLibraryStoreError.invalidDatabaseURL
        }

        let normalizedURL = databaseURL.standardizedFileURL
        let parentDirectory = normalizedURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parentDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SQLiteLibraryStoreError.parentDirectoryMissing(parentDirectory)
        }

        var configuration = Configuration()
        configuration.label = "BisonNotes.SQLiteLibraryStore"
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(5)
        configuration.journalMode = .wal

        let queue = try DatabaseQueue(path: normalizedURL.path, configuration: configuration)

        // GRDB sets WAL connections to NORMAL synchronous mode as part of its
        // journal setup. This queue is the only connection owned by this
        // actor, so restore and verify FULL before any migration transaction
        // or future database access can occur.
        try queue.write { database in
            try database.execute(sql: "PRAGMA synchronous = FULL")
            let synchronousMode = try Int.fetchOne(database, sql: "PRAGMA synchronous") ?? 0
            guard synchronousMode == 2 else { // FULL
                throw SQLiteLibraryStoreError.unsupportedConfiguration(
                    "synchronous mode is \(synchronousMode), expected FULL"
                )
            }
        }

        var migrator = DatabaseMigrator()
        migrator.registerMigration(Self.schemaMigrationIdentifier) { database in
            try SQLiteLibraryStoreSchema.create(in: database)
            try database.execute(
                sql: """
                INSERT INTO schema_migrations (version, identifier, appliedAt)
                VALUES (?, ?, ?)
                """,
                arguments: [
                    Self.schemaVersion,
                    Self.schemaMigrationIdentifier,
                    Date().timeIntervalSinceReferenceDate
                ]
            )
        }

        try migrator.migrate(queue)

        self.databaseURL = normalizedURL
        self.databaseQueue = queue
    }

    func diagnostics() throws -> Diagnostics {
        try databaseQueue.read { database in
            let metadata = try readSQLiteLibraryMetadata(from: database)
            let runtime = try readSQLiteRuntimeSnapshot(from: database)

            return Diagnostics(
                libraryID: metadata.libraryID,
                generationID: metadata.generationID,
                schemaVersion: metadata.schemaVersion,
                minimumReaderVersion: metadata.minimumReaderVersion,
                revision: metadata.revision,
                foreignKeysEnabled: runtime.foreignKeysEnabled,
                synchronousMode: runtime.synchronousMode,
                journalMode: runtime.journalMode,
                sqliteVersion: runtime.sqliteVersion,
                compileOptions: runtime.compileOptions,
                integrityCheck: runtime.integrityCheck
            )
        }
    }

    func tableNames() throws -> [String] {
        try databaseQueue.read { database in
            try String.fetchAll(
                database,
                sql: """
                SELECT name
                FROM sqlite_master
                WHERE type = 'table'
                  AND name NOT LIKE 'sqlite_%'
                  AND name <> 'grdb_migrations'
                ORDER BY name
                """
            )
        }
    }
}
