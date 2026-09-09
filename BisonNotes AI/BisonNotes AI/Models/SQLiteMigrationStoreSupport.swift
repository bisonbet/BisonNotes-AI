import Foundation
import GRDB

enum SQLiteMigrationStoreSupport {
    static func fetchRun(
        id: String,
        from database: Database
    ) throws -> SQLiteMigrationRun? {
        guard let row = try Row.fetchOne(
            database,
            sql: """
            SELECT id, sourceFingerprint, importerVersion, sourceModel,
                   phase, status, metadataTotal, metadataCompleted,
                   batchCursor, batchCount, batchSHA256, startedAt,
                   updatedAt, errorMessage
            FROM migration_runs
            WHERE id = ?
            """,
            arguments: [id]
        ) else {
            return nil
        }

        guard let runID: String = row["id"],
              let sourceFingerprint: String = row["sourceFingerprint"],
              let importerVersion: String = row["importerVersion"],
              let phase: String = row["phase"],
              let status: String = row["status"],
              let metadataCompleted: Int = row["metadataCompleted"],
              let batchCount: Int = row["batchCount"],
              let startedAt: Double = row["startedAt"],
              let updatedAt: Double = row["updatedAt"] else {
            throw SQLiteLibraryStoreError.invalidMetadata
        }

        let sourceModel: String? = row["sourceModel"]
        let metadataTotal: Int? = row["metadataTotal"]
        let batchCursor: Data? = row["batchCursor"]
        let batchSHA256: String? = row["batchSHA256"]
        let errorMessage: String? = row["errorMessage"]

        return SQLiteMigrationRun(
            id: runID,
            sourceFingerprint: sourceFingerprint,
            importerVersion: importerVersion,
            sourceModel: sourceModel,
            phase: phase,
            status: status,
            metadataTotal: metadataTotal,
            metadataCompleted: metadataCompleted,
            batchCursor: batchCursor,
            batchCount: batchCount,
            batchSHA256: batchSHA256,
            startedAt: Date(timeIntervalSinceReferenceDate: startedAt),
            updatedAt: Date(timeIntervalSinceReferenceDate: updatedAt),
            errorMessage: errorMessage
        )
    }

    static func validateProgress(
        phase: String,
        status: String,
        metadataTotal: Int?,
        metadataCompleted: Int,
        batchCount: Int
    ) throws {
        guard !phase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SQLiteLibraryStoreError.invalidMigrationCheckpoint("phase must not be empty")
        }
        guard !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SQLiteLibraryStoreError.invalidMigrationCheckpoint("status must not be empty")
        }
        if let metadataTotal, metadataTotal < 0 {
            throw SQLiteLibraryStoreError.invalidMigrationCheckpoint(
                "metadataTotal must be non-negative"
            )
        }
        guard metadataCompleted >= 0 else {
            throw SQLiteLibraryStoreError.invalidMigrationCheckpoint(
                "metadataCompleted must be non-negative"
            )
        }
        if let metadataTotal, metadataCompleted > metadataTotal {
            throw SQLiteLibraryStoreError.invalidMigrationCheckpoint(
                "metadataCompleted must not exceed metadataTotal"
            )
        }
        guard batchCount >= 0 else {
            throw SQLiteLibraryStoreError.invalidMigrationCheckpoint(
                "batchCount must be non-negative"
            )
        }
    }

    static func validateCheckpointTarget(
        id: String,
        metadataCompleted: Int,
        from database: Database
    ) throws {
        guard let existingRun = try fetchRun(id: id, from: database) else {
            throw SQLiteLibraryStoreError.migrationRunNotFound(id)
        }
        if let metadataTotal = existingRun.metadataTotal,
           metadataCompleted > metadataTotal {
            throw SQLiteLibraryStoreError.invalidMigrationCheckpoint(
                "metadataCompleted must not exceed metadataTotal"
            )
        }
    }
}
