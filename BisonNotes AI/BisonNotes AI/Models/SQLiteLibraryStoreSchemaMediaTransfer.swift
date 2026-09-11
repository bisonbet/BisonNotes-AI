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
}
