import Foundation
import GRDB

extension SQLiteLibraryStore {
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerInitialSchemaMigration(on: &migrator)
        registerSettingsSchemaMigration(on: &migrator)
        registerChangesSchemaMigration(on: &migrator)
        registerMediaTransferSchemaMigration(on: &migrator)
        registerArchiveRestoreSchemaMigration(on: &migrator)
        registerArchiveRestoreRevisionSchemaMigration(on: &migrator)
        registerMediaMetadataAcknowledgementSchemaMigration(on: &migrator)
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

    private static func registerMediaTransferSchemaMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(Self.mediaTransferSchemaMigrationIdentifier) { database in
            try SQLiteLibraryStoreSchema.addMediaTransferSource(in: database)
            try database.execute(
                sql: """
                INSERT INTO schema_migrations (version, identifier, appliedAt)
                VALUES (?, ?, ?)
                """,
                arguments: [
                    SQLiteLibraryStoreSchema.mediaTransferSchemaVersion,
                    Self.mediaTransferSchemaMigrationIdentifier,
                    Date().timeIntervalSinceReferenceDate
                ]
            )
        }
    }

    private static func registerArchiveRestoreSchemaMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(Self.archiveRestoreSchemaMigrationIdentifier) { database in
            try SQLiteLibraryStoreSchema.addArchiveRestoreOperations(in: database)
            try database.execute(
                sql: """
                INSERT INTO schema_migrations (version, identifier, appliedAt)
                VALUES (?, ?, ?)
                """,
                arguments: [
                    SQLiteLibraryStoreSchema.archiveRestoreSchemaVersion,
                    Self.archiveRestoreSchemaMigrationIdentifier,
                    Date().timeIntervalSinceReferenceDate
                ]
            )
        }
    }

    private static func registerArchiveRestoreRevisionSchemaMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(Self.archiveRestoreRevisionSchemaMigrationIdentifier) { database in
            try SQLiteLibraryStoreSchema.addArchiveRestoreOwnerLastModified(in: database)
            try database.execute(
                sql: """
                INSERT INTO schema_migrations (version, identifier, appliedAt)
                VALUES (?, ?, ?)
                """,
                arguments: [
                    SQLiteLibraryStoreSchema.archiveRestoreRevisionSchemaVersion,
                    Self.archiveRestoreRevisionSchemaMigrationIdentifier,
                    Date().timeIntervalSinceReferenceDate
                ]
            )
        }
    }

    private static func registerMediaMetadataAcknowledgementSchemaMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(Self.mediaMetadataAcknowledgementSchemaMigrationIdentifier) { database in
            try SQLiteLibraryStoreSchema.addMediaMetadataAcknowledgement(in: database)
            try database.execute(
                sql: """
                INSERT INTO schema_migrations (version, identifier, appliedAt)
                VALUES (?, ?, ?)
                """,
                arguments: [
                    SQLiteLibraryStoreSchema.mediaMetadataAcknowledgementSchemaVersion,
                    Self.mediaMetadataAcknowledgementSchemaMigrationIdentifier,
                    Date().timeIntervalSinceReferenceDate
                ]
            )
        }
    }
}
