import Foundation
import GRDB

extension SQLiteLibraryStore {
    /// Enqueues a root-relative media copy and its asset catalog row together.
    ///
    /// Repeating the exact operation ID and plan is idempotent. Reusing an ID
    /// for different content is a hard conflict rather than an overwrite.
    func enqueueMediaCopy(
        _ plan: SQLiteMediaCopyPlan,
        at date: Date = Date()
    ) throws -> SQLiteMediaFileOperation {
        try plan.validate()
        let timestamp = date.timeIntervalSinceReferenceDate
        return try databaseQueue.write { database in
            if let existing = try Self.fetchMediaFileOperation(
                id: plan.operationID,
                from: database
            ) {
                guard Self.matches(existing, plan: plan) else {
                    throw SQLiteMediaFileOperationError.operationConflict
                }
                return existing
            }

            let assetExists = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM asset_catalog WHERE storageID = ?",
                arguments: [plan.assetID]
            ) == 1
            guard !assetExists else {
                throw SQLiteMediaFileOperationError.operationConflict
            }

            try Self.insertAssetCatalog(
                plan: plan,
                timestamp: timestamp,
                in: database
            )
            try Self.insertFileOperation(
                plan: plan,
                timestamp: timestamp,
                in: database
            )

            guard let operation = try Self.fetchMediaFileOperation(
                id: plan.operationID,
                from: database
            ) else {
                throw SQLiteLibraryStoreError.invalidMetadata
            }
            return operation
        }
    }

    func mediaFileOperation(id: String) throws -> SQLiteMediaFileOperation? {
        try SQLiteMediaFileOperationValidation.identifier(id)
        return try databaseQueue.read { database in
            try Self.fetchMediaFileOperation(id: id, from: database)
        }
    }

    /// Converts operations left in `running` state by a terminated process
    /// back to retryable work. The operation and asset updates happen together
    /// so a later worker cannot observe a stale in-flight state.
    func recoverInterruptedMediaOperations(
        at date: Date = Date()
    ) throws -> Int {
        let timestamp = date.timeIntervalSinceReferenceDate
        return try databaseQueue.write { database in
            try database.execute(
                sql: """
                UPDATE file_operations
                SET state = 'pending',
                    lastError = NULL,
                    updatedAt = ?
                WHERE state = 'running'
                """,
                arguments: [timestamp]
            )
            let recoveredCount = database.changesCount
            guard recoveredCount > 0 else { return 0 }

            try database.execute(
                sql: """
                UPDATE asset_catalog
                SET state = 'pending',
                    updatedAt = ?
                WHERE storageID IN (
                    SELECT assetID
                    FROM file_operations
                    WHERE state = 'pending'
                      AND assetID IS NOT NULL
                )
                """,
                arguments: [timestamp]
            )
            return recoveredCount
        }
    }

    /// Claims an operation after a crash or retry. A completed operation is
    /// returned unchanged so callers can safely retry an acknowledgement.
    func claimMediaOperation(
        id: String,
        at date: Date = Date()
    ) throws -> SQLiteMediaFileOperation {
        try SQLiteMediaFileOperationValidation.identifier(id)
        let timestamp = date.timeIntervalSinceReferenceDate
        return try databaseQueue.write { database in
            try Self.claimMediaFileOperation(
                id: id,
                timestamp: timestamp,
                in: database
            )
        }
    }

    /// Commits the database half only after the worker has verified the file.
    func completeMediaOperation(
        id: String,
        byteLength: Int64,
        sha256: String,
        at date: Date = Date()
    ) throws -> SQLiteMediaFileOperation {
        try SQLiteMediaFileOperationValidation.identifier(id)
        guard byteLength >= 0 else {
            throw SQLiteMediaFileOperationError.invalidByteLength
        }
        try SQLiteMediaFileOperationValidation.sha256(sha256)
        let timestamp = date.timeIntervalSinceReferenceDate
        return try databaseQueue.write { database in
            try Self.completeMediaFileOperation(
                id: id,
                byteLength: byteLength,
                sha256: sha256,
                timestamp: timestamp,
                in: database
            )
        }
    }

    /// Requeues a canceled operation without retaining transient error text.
    func requeueMediaOperation(
        id: String,
        at date: Date = Date()
    ) throws -> SQLiteMediaFileOperation {
        try SQLiteMediaFileOperationValidation.identifier(id)
        let timestamp = date.timeIntervalSinceReferenceDate
        return try databaseQueue.write { database in
            guard let operation = try Self.fetchMediaFileOperation(id: id, from: database) else {
                throw SQLiteMediaFileOperationError.operationNotFound
            }
            guard operation.state != "completed" else {
                return operation
            }
            try database.execute(
                sql: """
                UPDATE file_operations
                SET state = 'pending',
                    lastError = NULL,
                    updatedAt = ?
                WHERE id = ?
                """,
                arguments: [timestamp, id]
            )
            if let assetID = operation.assetID {
                try Self.setMediaAssetState(
                    "pending",
                    assetID: assetID,
                    timestamp: timestamp,
                    in: database
                )
            }
            guard let requeued = try Self.fetchMediaFileOperation(id: id, from: database) else {
                throw SQLiteLibraryStoreError.invalidMetadata
            }
            return requeued
        }
    }

    /// Records a generic retryable failure. Raw filesystem errors and paths
    /// remain transient and are never persisted in the migration database.
    func failMediaOperation(
        id: String,
        at date: Date = Date()
    ) throws -> SQLiteMediaFileOperation {
        try SQLiteMediaFileOperationValidation.identifier(id)
        let timestamp = date.timeIntervalSinceReferenceDate
        return try databaseQueue.write { database in
            guard let operation = try Self.fetchMediaFileOperation(id: id, from: database) else {
                throw SQLiteMediaFileOperationError.operationNotFound
            }
            guard operation.state != "completed" else {
                return operation
            }
            try database.execute(
                sql: """
                UPDATE file_operations
                SET state = 'failed',
                    lastError = ?,
                    updatedAt = ?
                WHERE id = ?
                """,
                arguments: [
                    "media copy failed; retry required",
                    timestamp,
                    id
                ]
            )
            if let assetID = operation.assetID {
                try Self.setMediaAssetState(
                    "unavailable",
                    assetID: assetID,
                    timestamp: timestamp,
                    in: database
                )
            }
            guard let failed = try Self.fetchMediaFileOperation(id: id, from: database) else {
                throw SQLiteLibraryStoreError.invalidMetadata
            }
            return failed
        }
    }
}
