import Foundation
import GRDB

extension SQLiteLibraryStore {
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerInitialSchemaMigration(on: &migrator)
        registerSettingsSchemaMigration(on: &migrator)
        registerChangesSchemaMigration(on: &migrator)
        return migrator
    }

    private static func registerInitialSchemaMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(Self.initialSchemaMigrationIdentifier) { database in
            try SQLiteLibraryStoreSchema.createInitial(in: database)
            try database.execute(
                sql: """
                INSERT INTO schema_migrations (version, identifier, appliedAt)
                VALUES (?, ?, ?)
                """,
                arguments: [
                    SQLiteLibraryStoreSchema.initialSchemaVersion,
                    Self.initialSchemaMigrationIdentifier,
                    Date().timeIntervalSinceReferenceDate
                ]
            )
        }
    }

    private static func registerSettingsSchemaMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(Self.settingsSchemaMigrationIdentifier) { database in
            try SQLiteLibraryStoreSchema.addSettings(in: database)
            try database.execute(
                sql: """
                INSERT INTO schema_migrations (version, identifier, appliedAt)
                VALUES (?, ?, ?)
                """,
                arguments: [
                    SQLiteLibraryStoreSchema.settingsSchemaVersion,
                    Self.settingsSchemaMigrationIdentifier,
                    Date().timeIntervalSinceReferenceDate
                ]
            )
        }
    }

    private static func registerChangesSchemaMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(Self.changesSchemaMigrationIdentifier) { database in
            try SQLiteLibraryStoreSchema.addChanges(in: database)
            try database.execute(
                sql: """
                INSERT INTO schema_migrations (version, identifier, appliedAt)
                VALUES (?, ?, ?)
                """,
                arguments: [
                    SQLiteLibraryStoreSchema.changesSchemaVersion,
                    Self.changesSchemaMigrationIdentifier,
                    Date().timeIntervalSinceReferenceDate
                ]
            )
        }
    }
}
