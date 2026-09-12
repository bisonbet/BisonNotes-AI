import Foundation
import GRDB

extension SQLiteLibraryStoreSchema {
    static func addMediaTransferSource(in database: Database) throws {
        try database.execute(
            sql: "ALTER TABLE asset_catalog ADD COLUMN sourceTransferID TEXT"
        )
        try database.execute(
            sql: """
            CREATE INDEX assets_by_source_transfer
            ON asset_catalog (sourceTransferID)
            """
        )

        try database.execute(
            sql: """
            UPDATE library_metadata
            SET schemaVersion = ?, updatedAt = ?
            WHERE id = 1
            """,
            arguments: [
                mediaTransferSchemaVersion,
                Date().timeIntervalSinceReferenceDate
            ]
        )
    }

    static func addArchiveRestoreOperations(in database: Database) throws {
        try database.execute(
            sql: """
            CREATE TABLE archive_restore_operations (
                id TEXT NOT NULL PRIMARY KEY,
                archiveLocationID TEXT NOT NULL,
                ownerStorageID TEXT,
                ownerRevision INTEGER,
                sourceRoot TEXT NOT NULL,
                sourceRelativePath TEXT NOT NULL,
                destinationRoot TEXT NOT NULL,
                destinationRelativePath TEXT NOT NULL,
                expectedByteLength INTEGER NOT NULL CHECK (expectedByteLength >= 0),
                expectedSHA256 TEXT NOT NULL,
                phase TEXT NOT NULL CHECK (phase IN (
                    'pending', 'copying', 'copyFailed', 'copied',
                    'committingMetadata', 'metadataFailed', 'metadataCommitted',
                    'deletingSource', 'sourceDeletionFailed', 'completed'
                )),
                attemptCount INTEGER NOT NULL DEFAULT 0 CHECK (attemptCount >= 0),
                lastError TEXT,
                createdAt REAL NOT NULL,
                updatedAt REAL NOT NULL,
                CHECK (sourceRelativePath <> '' AND
                    substr(sourceRelativePath, 1, 1) <> '/' AND
                    sourceRelativePath NOT LIKE '../%' AND
                    sourceRelativePath NOT LIKE '%/../%' AND
                    sourceRelativePath NOT LIKE '%/..'),
                CHECK (destinationRelativePath <> '' AND
                    substr(destinationRelativePath, 1, 1) <> '/' AND
                    destinationRelativePath NOT LIKE '../%' AND
                    destinationRelativePath NOT LIKE '%/../%' AND
                    destinationRelativePath NOT LIKE '%/..')
            )
            """
        )

        try database.execute(
            sql: """
            CREATE INDEX archive_restore_operations_by_phase
            ON archive_restore_operations (phase, updatedAt, id)
            """
        )

        try database.execute(
            sql: """
            CREATE INDEX archive_restore_operations_by_location
            ON archive_restore_operations (archiveLocationID, updatedAt, id)
            """
        )

        try database.execute(
            sql: """
            UPDATE library_metadata
            SET schemaVersion = ?, updatedAt = ?
            WHERE id = 1
            """,
            arguments: [
                archiveRestoreSchemaVersion,
                Date().timeIntervalSinceReferenceDate
            ]
        )
    }

    static func addArchiveRestoreOwnerLastModified(in database: Database) throws {
        try database.execute(
            sql: "ALTER TABLE archive_restore_operations ADD COLUMN ownerLastModified REAL"
        )

        try database.execute(
            sql: """
            UPDATE library_metadata
            SET schemaVersion = ?, updatedAt = ?
            WHERE id = 1
            """,
            arguments: [
                archiveRestoreRevisionSchemaVersion,
                Date().timeIntervalSinceReferenceDate
            ]
        )
    }

    static func addMediaMetadataAcknowledgement(in database: Database) throws {
        try database.execute(
            sql: """
            ALTER TABLE file_operations
            ADD COLUMN metadataState TEXT NOT NULL DEFAULT 'pending'
            CHECK (metadataState IN (
                'pending', 'committing', 'failed', 'committed', 'legacy'
            ))
            """
        )
        try database.execute(
            sql: """
            ALTER TABLE file_operations
            ADD COLUMN metadataAcknowledgedAt REAL
            """
        )

        // Existing v6 rows were governed by the copy/receipt boundary. Keep
        // that behavior explicit without fabricating a metadata timestamp;
        // newly enqueued rows use `pending` and must receive a real callback.
        try database.execute(
            sql: """
            UPDATE file_operations
            SET metadataState = CASE
                    WHEN state = 'completed' THEN 'legacy'
                    ELSE 'pending'
                END,
                metadataAcknowledgedAt = NULL
            """
        )

        try database.execute(
            sql: """
            UPDATE library_metadata
            SET schemaVersion = ?, updatedAt = ?
            WHERE id = 1
            """,
            arguments: [
                mediaMetadataAcknowledgementSchemaVersion,
                Date().timeIntervalSinceReferenceDate
            ]
        )
    }

    static func addMediaMetadataPayload(in database: Database) throws {
        try database.execute(
            sql: """
            ALTER TABLE file_operations
            ADD COLUMN metadataPayload BLOB
            """
        )

        try database.execute(
            sql: """
            UPDATE library_metadata
            SET schemaVersion = ?, updatedAt = ?
            WHERE id = 1
            """,
            arguments: [
                mediaMetadataPayloadSchemaVersion,
                Date().timeIntervalSinceReferenceDate
            ]
        )
    }
}
