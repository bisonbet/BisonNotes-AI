import Foundation
import GRDB

extension SQLiteLibraryStore {
    static func completeMediaFileOperation(
        id: String,
        byteLength: Int64,
        sha256: String,
        timestamp: Double,
        in database: Database
    ) throws -> SQLiteMediaFileOperation {
        guard let operation = try Self.fetchMediaFileOperation(id: id, from: database) else {
            throw SQLiteMediaFileOperationError.operationNotFound
        }
        guard operation.operation == "copy" else {
            throw SQLiteMediaFileOperationError.unsupportedOperation
        }
        guard operation.state != "completed" else {
            return operation
        }
        guard operation.state == "running" else {
            throw SQLiteMediaFileOperationError.operationConflict
        }
        guard operation.expectedByteLength == byteLength,
              operation.expectedSHA256?.lowercased() == sha256.lowercased() else {
            throw SQLiteMediaFileOperationError.integrityMismatch
        }
        guard let assetID = operation.assetID else {
            throw SQLiteMediaFileOperationError.operationConflict
        }

        try database.execute(
            sql: """
            UPDATE file_operations
            SET state = 'completed',
                lastError = NULL,
                updatedAt = ?
            WHERE id = ?
            """,
            arguments: [timestamp, id]
        )
        try database.execute(
            sql: """
            UPDATE asset_catalog
            SET byteLength = ?,
                sha256 = ?,
                state = 'available',
                updatedAt = ?
            WHERE storageID = ?
            """,
            arguments: [byteLength, sha256.lowercased(), timestamp, assetID]
        )
        guard let completed = try Self.fetchMediaFileOperation(id: id, from: database) else {
            throw SQLiteLibraryStoreError.invalidMetadata
        }
        return completed
    }

    static func claimMediaFileOperation(
        id: String,
        timestamp: Double,
        in database: Database
    ) throws -> SQLiteMediaFileOperation {
        guard let existing = try Self.fetchMediaFileOperation(id: id, from: database) else {
            throw SQLiteMediaFileOperationError.operationNotFound
        }
        guard existing.operation == "copy" else {
            throw SQLiteMediaFileOperationError.unsupportedOperation
        }
        guard existing.state != "completed" else {
            return existing
        }
        guard ["pending", "paused", "failed"].contains(existing.state) else {
            throw SQLiteMediaFileOperationError.operationConflict
        }

        try database.execute(
            sql: """
            UPDATE file_operations
            SET state = 'running',
                attemptCount = attemptCount + 1,
                lastError = NULL,
                updatedAt = ?
            WHERE id = ?
            """,
            arguments: [timestamp, id]
        )
        if let assetID = existing.assetID {
            try Self.setMediaAssetState(
                "pending",
                assetID: assetID,
                timestamp: timestamp,
                in: database
            )
        }
        guard let claimed = try Self.fetchMediaFileOperation(id: id, from: database) else {
            throw SQLiteLibraryStoreError.invalidMetadata
        }
        return claimed
    }

    static func setMediaAssetState(
        _ state: String,
        assetID: String,
        timestamp: Double,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
            UPDATE asset_catalog
            SET state = ?,
                updatedAt = ?
            WHERE storageID = ?
            """,
            arguments: [state, timestamp, assetID]
        )
    }

    static func insertAssetCatalog(
        plan: SQLiteMediaCopyPlan,
        timestamp: Double,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
            INSERT INTO asset_catalog (
                storageID, sourceRoot, sourceRelativePath, destinationRoot,
                destinationRelativePath, kind, byteLength, sha256, state,
                isExternal, createdAt, updatedAt
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                plan.assetID,
                plan.sourceRoot,
                plan.sourceRelativePath,
                plan.destinationRoot,
                plan.destinationRelativePath,
                "audio",
                plan.expectedByteLength,
                plan.expectedSHA256.lowercased(),
                "pending",
                false,
                timestamp,
                timestamp
            ]
        )
    }

    static func insertFileOperation(
        plan: SQLiteMediaCopyPlan,
        timestamp: Double,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
            INSERT INTO file_operations (
                id, assetID, operation, state, ownerStorageID, ownerRevision,
                sourceRoot, sourceRelativePath, destinationRoot,
                destinationRelativePath, expectedByteLength, expectedSHA256,
                attemptCount, lastError, createdAt, updatedAt
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                plan.operationID,
                plan.assetID,
                "copy",
                "pending",
                plan.ownerStorageID,
                plan.ownerRevision,
                plan.sourceRoot,
                plan.sourceRelativePath,
                plan.destinationRoot,
                plan.destinationRelativePath,
                plan.expectedByteLength,
                plan.expectedSHA256.lowercased(),
                0,
                nil,
                timestamp,
                timestamp
            ]
        )
    }

    static func fetchMediaFileOperation(
        id: String,
        from database: Database
    ) throws -> SQLiteMediaFileOperation? {
        guard let row = try Row.fetchOne(
            database,
            sql: """
            SELECT id, assetID, operation, state, ownerStorageID, ownerRevision,
                   sourceRoot, sourceRelativePath, destinationRoot,
                   destinationRelativePath, expectedByteLength, expectedSHA256,
                   attemptCount, lastError, createdAt, updatedAt
            FROM file_operations
            WHERE id = ?
            """,
            arguments: [id]
        ) else {
            return nil
        }

        guard let operationID: String = row["id"],
              let operation: String = row["operation"],
              let state: String = row["state"],
              let attemptCount: Int = row["attemptCount"],
              let createdAt: Double = row["createdAt"],
              let updatedAt: Double = row["updatedAt"] else {
            throw SQLiteLibraryStoreError.invalidMetadata
        }
        return SQLiteMediaFileOperation(
            id: operationID,
            assetID: row["assetID"],
            operation: operation,
            state: state,
            ownerStorageID: row["ownerStorageID"],
            ownerRevision: row["ownerRevision"],
            sourceRoot: row["sourceRoot"],
            sourceRelativePath: row["sourceRelativePath"],
            destinationRoot: row["destinationRoot"],
            destinationRelativePath: row["destinationRelativePath"],
            expectedByteLength: row["expectedByteLength"],
            expectedSHA256: row["expectedSHA256"],
            attemptCount: attemptCount,
            lastError: row["lastError"],
            createdAt: Date(timeIntervalSinceReferenceDate: createdAt),
            updatedAt: Date(timeIntervalSinceReferenceDate: updatedAt)
        )
    }

    static func matches(
        _ operation: SQLiteMediaFileOperation,
        plan: SQLiteMediaCopyPlan
    ) -> Bool {
        operation.id == plan.operationID &&
            operation.assetID == plan.assetID &&
            operation.operation == "copy" &&
            operation.ownerStorageID == plan.ownerStorageID &&
            operation.ownerRevision == plan.ownerRevision &&
            operation.sourceRoot == plan.sourceRoot &&
            operation.sourceRelativePath == plan.sourceRelativePath &&
            operation.destinationRoot == plan.destinationRoot &&
            operation.destinationRelativePath == plan.destinationRelativePath &&
            operation.expectedByteLength == plan.expectedByteLength &&
            operation.expectedSHA256?.lowercased() == plan.expectedSHA256.lowercased()
    }
}
