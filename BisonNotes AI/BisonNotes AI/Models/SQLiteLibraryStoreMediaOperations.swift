import Foundation
import GRDB

extension SQLiteLibraryStore {
    /// Enqueues a media transfer while persisting the source acknowledgement
    /// identity needed to finish the receipt after a process restart.
    func enqueueMediaCopy(
        _ transfer: SQLiteMediaTransferPlan,
        at date: Date = Date()
    ) throws -> SQLiteMediaFileOperation {
        try transfer.validate()
        return try enqueueMediaCopy(
            transfer.copyPlan,
            sourceTransferID: transfer.sourceTransferID,
            at: date
        )
    }

    /// Enqueues a root-relative media copy and its asset catalog row together.
    ///
    /// Repeating the exact operation ID and plan is idempotent. Reusing an ID
    /// for different content is a hard conflict rather than an overwrite.
    func enqueueMediaCopy(
        _ plan: SQLiteMediaCopyPlan,
        sourceTransferID: String? = nil,
        at date: Date = Date()
    ) throws -> SQLiteMediaFileOperation {
        try plan.validate()
        if let sourceTransferID {
            try SQLiteImportReceiptValidation.identifier(sourceTransferID)
        }
        let timestamp = date.timeIntervalSinceReferenceDate
        return try databaseQueue.write { database in
            if let existing = try Self.fetchMediaFileOperation(
                id: plan.operationID,
                from: database
            ) {
                guard Self.matches(
                    existing,
                    plan: plan,
                    sourceTransferID: sourceTransferID
                ) else {
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
                sourceTransferID: sourceTransferID,
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

    /// Returns every root-relative source path currently represented by the
    /// media journal. A staging cleanup caller uses this set to avoid deleting
    /// a source that is still pending, failed, or awaiting receipt cleanup.
    func mediaSourceRelativePaths(sourceRoot: String) throws -> Set<String> {
        try SQLiteMediaFileOperationValidation.root(sourceRoot)
        return try databaseQueue.read { database in
            let paths = try String.fetchAll(
                database,
                sql: """
                SELECT DISTINCT sourceRelativePath
                FROM file_operations
                WHERE sourceRoot = ?
                  AND sourceRelativePath IS NOT NULL
                """,
                arguments: [sourceRoot]
            )
            var validatedPaths = Set<String>(minimumCapacity: paths.count)
            for path in paths {
                do {
                    try SQLiteMediaFileOperationValidation.relativePath(path)
                } catch {
                    throw SQLiteLibraryStoreError.invalidMetadata
                }
                validatedPaths.insert(path)
            }
            return validatedPaths
        }
    }

    /// Returns self-describing operations that can be resumed by a background
    /// worker. Completed operations without a receipt are included so a
    /// process kill between publication, metadata acknowledgement and receipt
    /// recording is recoverable.
    func mediaOperationsNeedingReconciliation(
        limit: Int = 8
    ) throws -> [SQLiteMediaFileOperation] {
        try SQLiteMediaFileOperationValidation.batchLimit(limit)
        return try databaseQueue.read { database in
            let operationIDs = try String.fetchAll(
                database,
                sql: """
                SELECT file_operations.id
                FROM file_operations
                JOIN asset_catalog
                    ON asset_catalog.storageID = file_operations.assetID
                LEFT JOIN import_receipts
                    ON import_receipts.sourceTransferID = asset_catalog.sourceTransferID
                WHERE asset_catalog.sourceTransferID IS NOT NULL
                  AND (
                      file_operations.state IN ('pending', 'failed') OR
                      (file_operations.state = 'completed' AND import_receipts.receiptID IS NULL)
                  )
                ORDER BY file_operations.updatedAt, file_operations.id
                LIMIT ?
                """,
                arguments: [limit]
            )
            return try operationIDs.compactMap { operationID in
                try Self.fetchMediaFileOperation(id: operationID, from: database)
            }
        }
    }

    /// Returns completed operations whose committed receipt makes source
    /// removal eligible. A caller uses this after relaunch to finish cleanup
    /// that may have been interrupted after the receipt was recorded but
    /// before the source-specific retention action ran.
    func mediaOperationsEligibleForSourceRemoval(
        sourceRoot: String? = nil,
        limit: Int = 8
    ) throws -> [SQLiteMediaFileOperation] {
        try SQLiteMediaFileOperationValidation.batchLimit(limit)
        if let sourceRoot {
            try SQLiteMediaFileOperationValidation.root(sourceRoot)
        }
        return try databaseQueue.read { database in
            let operationIDs = try String.fetchAll(
                database,
                sql: """
                SELECT file_operations.id
                FROM file_operations
                JOIN asset_catalog
                    ON asset_catalog.storageID = file_operations.assetID
                JOIN import_receipts
                    ON import_receipts.sourceTransferID = asset_catalog.sourceTransferID
                WHERE file_operations.state = 'completed'
                  AND file_operations.metadataState IN ('committed', 'legacy')
                  AND asset_catalog.sourceTransferID IS NOT NULL
                  AND import_receipts.outcome = 'committed'
                  AND (? IS NULL OR file_operations.sourceRoot = ?)
                ORDER BY file_operations.updatedAt, file_operations.id
                LIMIT ?
                """,
                arguments: [sourceRoot, sourceRoot, limit]
            )
            return try operationIDs.compactMap { operationID in
                try Self.fetchMediaFileOperation(id: operationID, from: database)
            }
        }
    }

    /// Converts copy or metadata operations left in-flight by a terminated
    /// process back to retryable work. The operation and asset updates happen
    /// together so a later worker cannot observe a stale in-flight state.
    func recoverInterruptedMediaOperations(
        at date: Date = Date()
    ) throws -> Int {
        let timestamp = date.timeIntervalSinceReferenceDate
        return try databaseQueue.write { database in
            try database.execute(
                sql: """
                UPDATE file_operations
                SET state = CASE
                        WHEN state = 'running' THEN 'pending'
                        ELSE state
                    END,
                    metadataState = CASE
                        WHEN metadataState = 'committing' THEN 'pending'
                        ELSE metadataState
                    END,
                    lastError = NULL,
                    updatedAt = ?
                WHERE state = 'running' OR metadataState = 'committing'
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

    /// Claims the metadata half after the destination file has been verified.
    /// A process kill after this claim is normalized back to `pending` by
    /// `recoverInterruptedMediaOperations`, so the caller's idempotent
    /// metadata callback can be retried.
    func claimMediaMetadataAcknowledgement(
        id: String,
        at date: Date = Date()
    ) throws -> SQLiteMediaFileOperation {
        try SQLiteMediaFileOperationValidation.identifier(id)
        let timestamp = date.timeIntervalSinceReferenceDate
        return try databaseQueue.write { database in
            guard let operation = try Self.fetchMediaFileOperation(id: id, from: database) else {
                throw SQLiteMediaFileOperationError.operationNotFound
            }
            guard operation.operation == "copy",
                  operation.state == "completed" else {
                throw SQLiteMediaFileOperationError.metadataAcknowledgementRequired
            }
            switch operation.metadataState {
            case SQLiteMediaMetadataState.pending,
                 SQLiteMediaMetadataState.failed:
                try database.execute(
                    sql: """
                    UPDATE file_operations
                    SET metadataState = ?,
                        lastError = NULL,
                        updatedAt = ?
                    WHERE id = ?
                    """,
                    arguments: [
                        SQLiteMediaMetadataState.committing,
                        timestamp,
                        id
                    ]
                )
                guard let claimed = try Self.fetchMediaFileOperation(id: id, from: database) else {
                    throw SQLiteLibraryStoreError.invalidMetadata
                }
                return claimed
            case SQLiteMediaMetadataState.committing:
                throw SQLiteMediaFileOperationError.operationConflict
            case SQLiteMediaMetadataState.committed,
                 SQLiteMediaMetadataState.legacy:
                return operation
            default:
                throw SQLiteMediaFileOperationError.operationConflict
            }
        }
    }

    /// Durably records that the caller's metadata transaction succeeded.
    /// This does not create the source-transfer receipt; that separate write
    /// remains the final acknowledgement after this state is durable.
    func completeMediaMetadataAcknowledgement(
        id: String,
        at date: Date = Date()
    ) throws -> SQLiteMediaFileOperation {
        try SQLiteMediaFileOperationValidation.identifier(id)
        let timestamp = date.timeIntervalSinceReferenceDate
        return try databaseQueue.write { database in
            guard let operation = try Self.fetchMediaFileOperation(id: id, from: database) else {
                throw SQLiteMediaFileOperationError.operationNotFound
            }
            guard operation.operation == "copy",
                  operation.state == "completed" else {
                throw SQLiteMediaFileOperationError.metadataAcknowledgementRequired
            }
            switch operation.metadataState {
            case SQLiteMediaMetadataState.committing:
                try database.execute(
                    sql: """
                    UPDATE file_operations
                    SET metadataState = ?,
                        metadataAcknowledgedAt = ?,
                        lastError = NULL,
                        updatedAt = ?
                    WHERE id = ?
                    """,
                    arguments: [
                        SQLiteMediaMetadataState.committed,
                        timestamp,
                        timestamp,
                        id
                    ]
                )
                guard let completed = try Self.fetchMediaFileOperation(id: id, from: database) else {
                    throw SQLiteLibraryStoreError.invalidMetadata
                }
                return completed
            case SQLiteMediaMetadataState.committed,
                 SQLiteMediaMetadataState.legacy:
                return operation
            default:
                throw SQLiteMediaFileOperationError.operationConflict
            }
        }
    }

    /// Records a retryable metadata failure without retaining source-specific
    /// error text or making the source eligible for removal.
    func failMediaMetadataAcknowledgement(
        id: String,
        at date: Date = Date()
    ) throws -> SQLiteMediaFileOperation {
        try SQLiteMediaFileOperationValidation.identifier(id)
        let timestamp = date.timeIntervalSinceReferenceDate
        return try databaseQueue.write { database in
            guard let operation = try Self.fetchMediaFileOperation(id: id, from: database) else {
                throw SQLiteMediaFileOperationError.operationNotFound
            }
            guard operation.operation == "copy",
                  operation.state == "completed" else {
                throw SQLiteMediaFileOperationError.metadataAcknowledgementRequired
            }
            switch operation.metadataState {
            case SQLiteMediaMetadataState.pending,
                 SQLiteMediaMetadataState.committing,
                 SQLiteMediaMetadataState.failed:
                try database.execute(
                    sql: """
                    UPDATE file_operations
                    SET metadataState = ?,
                        metadataAcknowledgedAt = NULL,
                        lastError = ?,
                        updatedAt = ?
                    WHERE id = ?
                    """,
                    arguments: [
                        SQLiteMediaMetadataState.failed,
                        "media metadata acknowledgement failed; retry required",
                        timestamp,
                        id
                    ]
                )
                guard let failed = try Self.fetchMediaFileOperation(id: id, from: database) else {
                    throw SQLiteLibraryStoreError.invalidMetadata
                }
                return failed
            case SQLiteMediaMetadataState.committed,
                 SQLiteMediaMetadataState.legacy:
                return operation
            default:
                throw SQLiteMediaFileOperationError.operationConflict
            }
        }
    }

    /// Requeues a metadata acknowledgement after cancellation without
    /// changing the already-verified copy state.
    func requeueMediaMetadataAcknowledgement(
        id: String,
        at date: Date = Date()
    ) throws -> SQLiteMediaFileOperation {
        try SQLiteMediaFileOperationValidation.identifier(id)
        let timestamp = date.timeIntervalSinceReferenceDate
        return try databaseQueue.write { database in
            guard let operation = try Self.fetchMediaFileOperation(id: id, from: database) else {
                throw SQLiteMediaFileOperationError.operationNotFound
            }
            guard operation.operation == "copy",
                  operation.state == "completed" else {
                throw SQLiteMediaFileOperationError.metadataAcknowledgementRequired
            }
            guard [
                SQLiteMediaMetadataState.pending,
                SQLiteMediaMetadataState.committing,
                SQLiteMediaMetadataState.failed
            ].contains(operation.metadataState) else {
                return operation
            }
            try database.execute(
                sql: """
                UPDATE file_operations
                SET metadataState = ?,
                    metadataAcknowledgedAt = NULL,
                    lastError = NULL,
                    updatedAt = ?
                WHERE id = ?
                """,
                arguments: [
                    SQLiteMediaMetadataState.pending,
                    timestamp,
                    id
                ]
            )
            guard let requeued = try Self.fetchMediaFileOperation(id: id, from: database) else {
                throw SQLiteLibraryStoreError.invalidMetadata
            }
            return requeued
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

extension SQLiteLibraryStore {
    /// Enqueues the durable lifecycle for a provider archive restore.
    ///
    /// The operation is intentionally separate from the generic imported-media
    /// transfer journal: provider restores must acknowledge the recording
    /// metadata before their external source can be deleted.
    func enqueueArchiveRestore(
        _ plan: SQLiteArchiveRestorePlan,
        at date: Date = Date()
    ) throws -> SQLiteArchiveRestoreOperation {
        try plan.validate()
        let timestamp = date.timeIntervalSinceReferenceDate
        return try databaseQueue.write { database in
            if let existing = try Self.fetchArchiveRestoreOperation(
                id: plan.operationID,
                from: database
            ) {
                guard Self.matches(existing, plan: plan) else {
                    throw SQLiteArchiveRestoreError.operationConflict
                }
                return existing
            }

            try database.execute(
                sql: """
                INSERT INTO archive_restore_operations (
                    id, archiveLocationID, ownerStorageID, ownerRevision,
                    ownerLastModified,
                    sourceRoot, sourceRelativePath, destinationRoot,
                    destinationRelativePath, expectedByteLength, expectedSHA256,
                    phase, attemptCount, lastError, createdAt, updatedAt
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    plan.operationID,
                    plan.archiveLocationID,
                    plan.ownerStorageID,
                    plan.ownerRevision,
                    plan.ownerLastModified?.timeIntervalSinceReferenceDate,
                    plan.sourceRoot,
                    plan.sourceRelativePath,
                    plan.destinationRoot,
                    plan.destinationRelativePath,
                    plan.expectedByteLength,
                    plan.expectedSHA256.lowercased(),
                    SQLiteArchiveRestorePhase.pending,
                    0,
                    nil,
                    timestamp,
                    timestamp
                ]
            )

            guard let operation = try Self.fetchArchiveRestoreOperation(
                id: plan.operationID,
                from: database
            ) else {
                throw SQLiteLibraryStoreError.invalidMetadata
            }
            return operation
        }
    }

    func archiveRestoreOperation(
        id: String
    ) throws -> SQLiteArchiveRestoreOperation? {
        try SQLiteMediaFileOperationValidation.identifier(id)
        return try databaseQueue.read { database in
            try Self.fetchArchiveRestoreOperation(id: id, from: database)
        }
    }

    /// Returns all phases that can make progress after a restart. In-flight
    /// phases are first normalized by `recoverInterruptedArchiveRestores`.
    func archiveRestoreOperationsNeedingReconciliation(
        limit: Int = 8
    ) throws -> [SQLiteArchiveRestoreOperation] {
        guard (1...100).contains(limit) else {
            throw SQLiteArchiveRestoreError.invalidBatchLimit
        }
        return try databaseQueue.read { database in
            let ids = try String.fetchAll(
                database,
                sql: """
                SELECT id
                FROM archive_restore_operations
                WHERE phase IN (
                    'pending', 'copyFailed', 'copied', 'metadataFailed',
                    'metadataCommitted', 'sourceDeletionFailed'
                )
                ORDER BY updatedAt, id
                LIMIT ?
                """,
                arguments: [limit]
            )
            return try ids.compactMap { id in
                try Self.fetchArchiveRestoreOperation(id: id, from: database)
            }
        }
    }

    /// Converts phases that were interrupted by process termination into the
    /// phase whose work can be retried without losing either copy or metadata.
    func recoverInterruptedArchiveRestores(
        at date: Date = Date()
    ) throws -> Int {
        let timestamp = date.timeIntervalSinceReferenceDate
        return try databaseQueue.write { database in
            var recoveredCount = 0

            try database.execute(
                sql: """
                UPDATE archive_restore_operations
                SET phase = ?, lastError = NULL, updatedAt = ?
                WHERE phase = ?
                """,
                arguments: [
                    SQLiteArchiveRestorePhase.pending,
                    timestamp,
                    SQLiteArchiveRestorePhase.copying
                ]
            )
            recoveredCount += database.changesCount

            try database.execute(
                sql: """
                UPDATE archive_restore_operations
                SET phase = ?, lastError = NULL, updatedAt = ?
                WHERE phase = ?
                """,
                arguments: [
                    SQLiteArchiveRestorePhase.copied,
                    timestamp,
                    SQLiteArchiveRestorePhase.committingMetadata
                ]
            )
            recoveredCount += database.changesCount

            try database.execute(
                sql: """
                UPDATE archive_restore_operations
                SET phase = ?, lastError = NULL, updatedAt = ?
                WHERE phase = ?
                """,
                arguments: [
                    SQLiteArchiveRestorePhase.metadataCommitted,
                    timestamp,
                    SQLiteArchiveRestorePhase.deletingSource
                ]
            )
            recoveredCount += database.changesCount
            return recoveredCount
        }
    }

    /// Claims the copy half. Later phases are returned unchanged so a retry
    /// cannot copy over a committed metadata result.
    func claimArchiveRestoreCopy(
        id: String,
        at date: Date = Date()
    ) throws -> SQLiteArchiveRestoreOperation {
        try SQLiteMediaFileOperationValidation.identifier(id)
        let timestamp = date.timeIntervalSinceReferenceDate
        return try databaseQueue.write { database in
            guard let operation = try Self.fetchArchiveRestoreOperation(
                id: id,
                from: database
            ) else {
                throw SQLiteArchiveRestoreError.operationNotFound
            }
            switch operation.phase {
            case SQLiteArchiveRestorePhase.pending,
                 SQLiteArchiveRestorePhase.copyFailed:
                return try Self.updateArchiveRestorePhase(
                    id: id,
                    from: [operation.phase],
                    to: SQLiteArchiveRestorePhase.copying,
                    timestamp: timestamp,
                    incrementAttempt: true,
                    in: database
                )
            case SQLiteArchiveRestorePhase.copied,
                 SQLiteArchiveRestorePhase.committingMetadata,
                 SQLiteArchiveRestorePhase.metadataFailed,
                 SQLiteArchiveRestorePhase.metadataCommitted,
                 SQLiteArchiveRestorePhase.deletingSource,
                 SQLiteArchiveRestorePhase.sourceDeletionFailed,
                 SQLiteArchiveRestorePhase.completed:
                return operation
            default:
                throw SQLiteArchiveRestoreError.unsupportedPhase
            }
        }
    }

    func completeArchiveRestoreCopy(
        id: String,
        byteLength: Int64,
        sha256: String,
        at date: Date = Date()
    ) throws -> SQLiteArchiveRestoreOperation {
        try SQLiteMediaFileOperationValidation.identifier(id)
        guard byteLength >= 0 else {
            throw SQLiteMediaFileOperationError.invalidByteLength
        }
        try SQLiteMediaFileOperationValidation.sha256(sha256)
        let timestamp = date.timeIntervalSinceReferenceDate
        return try databaseQueue.write { database in
            guard let operation = try Self.fetchArchiveRestoreOperation(
                id: id,
                from: database
            ) else {
                throw SQLiteArchiveRestoreError.operationNotFound
            }
            switch operation.phase {
            case SQLiteArchiveRestorePhase.copying:
                guard operation.expectedByteLength == byteLength,
                      operation.expectedSHA256.lowercased() == sha256.lowercased() else {
                    throw SQLiteArchiveRestoreError.integrityMismatch
                }
                return try Self.updateArchiveRestorePhase(
                    id: id,
                    from: [SQLiteArchiveRestorePhase.copying],
                    to: SQLiteArchiveRestorePhase.copied,
                    timestamp: timestamp,
                    incrementAttempt: false,
                    in: database
                )
            case SQLiteArchiveRestorePhase.copied,
                 SQLiteArchiveRestorePhase.committingMetadata,
                 SQLiteArchiveRestorePhase.metadataFailed,
                 SQLiteArchiveRestorePhase.metadataCommitted,
                 SQLiteArchiveRestorePhase.deletingSource,
                 SQLiteArchiveRestorePhase.sourceDeletionFailed,
                 SQLiteArchiveRestorePhase.completed:
                return operation
            default:
                throw SQLiteArchiveRestoreError.operationConflict
            }
        }
    }

    func failArchiveRestoreCopy(
        id: String,
        at date: Date = Date()
    ) throws -> SQLiteArchiveRestoreOperation {
        try updateArchiveRestoreFailure(
            id: id,
            expectedPhase: SQLiteArchiveRestorePhase.copying,
            failedPhase: SQLiteArchiveRestorePhase.copyFailed,
            message: "archive restore copy failed; retry required",
            at: date
        )
    }

    /// Claims the Core Data/SQLite recording-link acknowledgement. A process
    /// kill after this claim is recovered to `copied`, so the acknowledgement
    /// callback is retried before any source deletion is allowed.
    func claimArchiveRestoreMetadata(
        id: String,
        at date: Date = Date()
    ) throws -> SQLiteArchiveRestoreOperation {
        try SQLiteMediaFileOperationValidation.identifier(id)
        let timestamp = date.timeIntervalSinceReferenceDate
        return try databaseQueue.write { database in
            guard let operation = try Self.fetchArchiveRestoreOperation(
                id: id,
                from: database
            ) else {
                throw SQLiteArchiveRestoreError.operationNotFound
            }
            switch operation.phase {
            case SQLiteArchiveRestorePhase.copied,
                 SQLiteArchiveRestorePhase.metadataFailed:
                return try Self.updateArchiveRestorePhase(
                    id: id,
                    from: [operation.phase],
                    to: SQLiteArchiveRestorePhase.committingMetadata,
                    timestamp: timestamp,
                    incrementAttempt: true,
                    in: database
                )
            case SQLiteArchiveRestorePhase.metadataCommitted,
                 SQLiteArchiveRestorePhase.deletingSource,
                 SQLiteArchiveRestorePhase.sourceDeletionFailed,
                 SQLiteArchiveRestorePhase.completed:
                return operation
            default:
                throw SQLiteArchiveRestoreError.operationConflict
            }
        }
    }

    func completeArchiveRestoreMetadata(
        id: String,
        at date: Date = Date()
    ) throws -> SQLiteArchiveRestoreOperation {
        try updateArchiveRestorePhase(
            id: id,
            from: [SQLiteArchiveRestorePhase.committingMetadata],
            to: SQLiteArchiveRestorePhase.metadataCommitted,
            timestamp: date.timeIntervalSinceReferenceDate,
            incrementAttempt: false
        )
    }

    func failArchiveRestoreMetadata(
        id: String,
        at date: Date = Date()
    ) throws -> SQLiteArchiveRestoreOperation {
        try updateArchiveRestoreFailure(
            id: id,
            expectedPhase: SQLiteArchiveRestorePhase.committingMetadata,
            failedPhase: SQLiteArchiveRestorePhase.metadataFailed,
            message: "archive restore metadata commit failed; retry required",
            at: date
        )
    }

    /// Claims the source-delete half only after metadata has been committed.
    func claimArchiveRestoreSourceDeletion(
        id: String,
        at date: Date = Date()
    ) throws -> SQLiteArchiveRestoreOperation {
        try SQLiteMediaFileOperationValidation.identifier(id)
        let timestamp = date.timeIntervalSinceReferenceDate
        return try databaseQueue.write { database in
            guard let operation = try Self.fetchArchiveRestoreOperation(
                id: id,
                from: database
            ) else {
                throw SQLiteArchiveRestoreError.operationNotFound
            }
            switch operation.phase {
            case SQLiteArchiveRestorePhase.metadataCommitted,
                 SQLiteArchiveRestorePhase.sourceDeletionFailed:
                return try Self.updateArchiveRestorePhase(
                    id: id,
                    from: [operation.phase],
                    to: SQLiteArchiveRestorePhase.deletingSource,
                    timestamp: timestamp,
                    incrementAttempt: true,
                    in: database
                )
            case SQLiteArchiveRestorePhase.completed:
                return operation
            default:
                throw SQLiteArchiveRestoreError.operationConflict
            }
        }
    }

    func completeArchiveRestoreSourceDeletion(
        id: String,
        at date: Date = Date()
    ) throws -> SQLiteArchiveRestoreOperation {
        try updateArchiveRestorePhase(
            id: id,
            from: [SQLiteArchiveRestorePhase.deletingSource],
            to: SQLiteArchiveRestorePhase.completed,
            timestamp: date.timeIntervalSinceReferenceDate,
            incrementAttempt: false
        )
    }

    func failArchiveRestoreSourceDeletion(
        id: String,
        at date: Date = Date()
    ) throws -> SQLiteArchiveRestoreOperation {
        try updateArchiveRestoreFailure(
            id: id,
            expectedPhase: SQLiteArchiveRestorePhase.deletingSource,
            failedPhase: SQLiteArchiveRestorePhase.sourceDeletionFailed,
            message: "archive restore source deletion failed; retry required",
            at: date
        )
    }

    /// Requeues only the in-flight phase that was canceled. This preserves the
    /// already-completed copy or metadata acknowledgement.
    func requeueArchiveRestore(
        id: String,
        at date: Date = Date()
    ) throws -> SQLiteArchiveRestoreOperation {
        try SQLiteMediaFileOperationValidation.identifier(id)
        let timestamp = date.timeIntervalSinceReferenceDate
        return try databaseQueue.write { database in
            guard let operation = try Self.fetchArchiveRestoreOperation(
                id: id,
                from: database
            ) else {
                throw SQLiteArchiveRestoreError.operationNotFound
            }
            let nextPhase: String
            switch operation.phase {
            case SQLiteArchiveRestorePhase.copying:
                nextPhase = SQLiteArchiveRestorePhase.pending
            case SQLiteArchiveRestorePhase.committingMetadata:
                nextPhase = SQLiteArchiveRestorePhase.copied
            case SQLiteArchiveRestorePhase.deletingSource:
                nextPhase = SQLiteArchiveRestorePhase.metadataCommitted
            case SQLiteArchiveRestorePhase.pending,
                 SQLiteArchiveRestorePhase.copyFailed,
                 SQLiteArchiveRestorePhase.copied,
                 SQLiteArchiveRestorePhase.metadataFailed,
                 SQLiteArchiveRestorePhase.metadataCommitted,
                 SQLiteArchiveRestorePhase.sourceDeletionFailed,
                 SQLiteArchiveRestorePhase.completed:
                return operation
            default:
                throw SQLiteArchiveRestoreError.operationConflict
            }
            return try Self.updateArchiveRestorePhase(
                id: id,
                from: [operation.phase],
                to: nextPhase,
                timestamp: timestamp,
                incrementAttempt: false,
                in: database
            )
        }
    }
}

private extension SQLiteLibraryStore {
    func updateArchiveRestorePhase(
        id: String,
        from phases: Set<String>,
        to phase: String,
        timestamp: Double,
        incrementAttempt: Bool
    ) throws -> SQLiteArchiveRestoreOperation {
        try databaseQueue.write { database in
            try Self.updateArchiveRestorePhase(
                id: id,
                from: phases,
                to: phase,
                timestamp: timestamp,
                incrementAttempt: incrementAttempt,
                in: database
            )
        }
    }

    func updateArchiveRestoreFailure(
        id: String,
        expectedPhase: String,
        failedPhase: String,
        message: String,
        at date: Date
    ) throws -> SQLiteArchiveRestoreOperation {
        try SQLiteMediaFileOperationValidation.identifier(id)
        let timestamp = date.timeIntervalSinceReferenceDate
        return try databaseQueue.write { database in
            guard let operation = try Self.fetchArchiveRestoreOperation(
                id: id,
                from: database
            ) else {
                throw SQLiteArchiveRestoreError.operationNotFound
            }
            guard operation.phase == expectedPhase else {
                if SQLiteArchiveRestorePhase.all.contains(operation.phase),
                   operation.phase != SQLiteArchiveRestorePhase.copying,
                   operation.phase != SQLiteArchiveRestorePhase.committingMetadata,
                   operation.phase != SQLiteArchiveRestorePhase.deletingSource {
                    return operation
                }
                throw SQLiteArchiveRestoreError.operationConflict
            }
            try database.execute(
                sql: """
                UPDATE archive_restore_operations
                SET phase = ?, lastError = ?, updatedAt = ?
                WHERE id = ?
                """,
                arguments: [failedPhase, message, timestamp, id]
            )
            guard let failed = try Self.fetchArchiveRestoreOperation(
                id: id,
                from: database
            ) else {
                throw SQLiteLibraryStoreError.invalidMetadata
            }
            return failed
        }
    }

    static func updateArchiveRestorePhase(
        id: String,
        from phases: Set<String>,
        to phase: String,
        timestamp: Double,
        incrementAttempt: Bool,
        in database: Database
    ) throws -> SQLiteArchiveRestoreOperation {
        guard let operation = try fetchArchiveRestoreOperation(id: id, from: database) else {
            throw SQLiteArchiveRestoreError.operationNotFound
        }
        guard phases.contains(operation.phase) else {
            throw SQLiteArchiveRestoreError.operationConflict
        }
        try database.execute(
            sql: """
            UPDATE archive_restore_operations
            SET phase = ?,
                attemptCount = attemptCount + ?,
                lastError = NULL,
                updatedAt = ?
            WHERE id = ?
            """,
            arguments: [phase, incrementAttempt ? 1 : 0, timestamp, id]
        )
        guard let updated = try fetchArchiveRestoreOperation(id: id, from: database) else {
            throw SQLiteLibraryStoreError.invalidMetadata
        }
        return updated
    }
}
