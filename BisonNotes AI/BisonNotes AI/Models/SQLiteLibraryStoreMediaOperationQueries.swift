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
        sourceTransferID: String?,
        timestamp: Double,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
            INSERT INTO asset_catalog (
                storageID, sourceRoot, sourceRelativePath, destinationRoot,
                destinationRelativePath, kind, byteLength, sha256, state,
                isExternal, createdAt, updatedAt, sourceTransferID
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                timestamp,
                sourceTransferID
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
            SELECT file_operations.id, file_operations.assetID,
                   file_operations.operation, file_operations.state,
                   file_operations.ownerStorageID, file_operations.ownerRevision,
                   file_operations.sourceRoot, file_operations.sourceRelativePath,
                   file_operations.destinationRoot, file_operations.destinationRelativePath,
                   file_operations.expectedByteLength, file_operations.expectedSHA256,
                   file_operations.attemptCount, file_operations.lastError,
                   file_operations.createdAt, file_operations.updatedAt,
                   asset_catalog.sourceTransferID AS sourceTransferID
            FROM file_operations
            LEFT JOIN asset_catalog
                ON asset_catalog.storageID = file_operations.assetID
            WHERE file_operations.id = ?
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
            sourceTransferID: row["sourceTransferID"],
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
        plan: SQLiteMediaCopyPlan,
        sourceTransferID: String?
    ) -> Bool {
        operation.id == plan.operationID &&
            operation.assetID == plan.assetID &&
            operation.sourceTransferID == sourceTransferID &&
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

    static func fetchArchiveRestoreOperation(
        id: String,
        from database: Database
    ) throws -> SQLiteArchiveRestoreOperation? {
        guard let row = try Row.fetchOne(
            database,
            sql: """
            SELECT id, archiveLocationID, ownerStorageID, ownerRevision,
                   ownerLastModified,
                   sourceRoot, sourceRelativePath, destinationRoot,
                   destinationRelativePath, expectedByteLength, expectedSHA256,
                   phase, attemptCount, lastError, createdAt, updatedAt
            FROM archive_restore_operations
            WHERE id = ?
            """,
            arguments: [id]
        ) else {
            return nil
        }

        guard let operationID: String = row["id"],
              let archiveLocationID: String = row["archiveLocationID"],
              let sourceRoot: String = row["sourceRoot"],
              let sourceRelativePath: String = row["sourceRelativePath"],
              let destinationRoot: String = row["destinationRoot"],
              let destinationRelativePath: String = row["destinationRelativePath"],
              let expectedByteLength: Int64 = row["expectedByteLength"],
              let expectedSHA256: String = row["expectedSHA256"],
              let phase: String = row["phase"],
              let attemptCount: Int = row["attemptCount"],
              let createdAt: Double = row["createdAt"],
              let updatedAt: Double = row["updatedAt"] else {
            throw SQLiteLibraryStoreError.invalidMetadata
        }
        return SQLiteArchiveRestoreOperation(
            id: operationID,
            archiveLocationID: archiveLocationID,
            ownerStorageID: row["ownerStorageID"],
            ownerRevision: row["ownerRevision"],
            ownerLastModified: (row["ownerLastModified"] as Double?)
                .map(Date.init(timeIntervalSinceReferenceDate:)),
            sourceRoot: sourceRoot,
            sourceRelativePath: sourceRelativePath,
            destinationRoot: destinationRoot,
            destinationRelativePath: destinationRelativePath,
            expectedByteLength: expectedByteLength,
            expectedSHA256: expectedSHA256,
            phase: phase,
            attemptCount: attemptCount,
            lastError: row["lastError"],
            createdAt: Date(timeIntervalSinceReferenceDate: createdAt),
            updatedAt: Date(timeIntervalSinceReferenceDate: updatedAt)
        )
    }

    static func matches(
        _ operation: SQLiteArchiveRestoreOperation,
        plan: SQLiteArchiveRestorePlan
    ) -> Bool {
        operation.id == plan.operationID &&
            operation.archiveLocationID == plan.archiveLocationID &&
            operation.ownerStorageID == plan.ownerStorageID &&
            operation.ownerRevision == plan.ownerRevision &&
            operation.ownerLastModified == plan.ownerLastModified &&
            operation.sourceRoot == plan.sourceRoot &&
            operation.sourceRelativePath == plan.sourceRelativePath &&
            operation.destinationRoot == plan.destinationRoot &&
            operation.destinationRelativePath == plan.destinationRelativePath &&
            operation.expectedByteLength == plan.expectedByteLength &&
            operation.expectedSHA256.lowercased() == plan.expectedSHA256.lowercased()
    }
}
