import Foundation

struct SQLiteMediaReconciliationProgress: Equatable, Sendable {
    let total: Int
    let completed: Int
    let failed: Int
}

struct SQLiteMediaReconciliationReport: Equatable, Sendable {
    let recoveredOperationCount: Int
    let selectedOperationCount: Int
    let completedOperationCount: Int
    let failedOperationCount: Int
}

/// Serializes bounded background reconciliation for durable media operations.
///
/// The reconciler copies media, invokes the idempotent metadata callback, and
/// records a committed receipt only after both durable halves succeed. Source
/// retention remains an explicit follow-up through
/// `SQLiteMediaSourceRetentionExecutor`, so a retry or process termination
/// cannot turn an incomplete acknowledgement into data loss.
actor SQLiteMediaBackgroundReconciler {
    let store: SQLiteLibraryStore
    let rootRegistry: SQLiteMediaRootRegistry

    init(
        store: SQLiteLibraryStore,
        rootRegistry: SQLiteMediaRootRegistry
    ) {
        self.store = store
        self.rootRegistry = rootRegistry
    }

    func run(
        maxOperations: Int = 8,
        at date: Date = Date(),
        metadataCommit: @escaping SQLiteMediaMetadataCommit,
        progress: (@Sendable (SQLiteMediaReconciliationProgress) -> Void)? = nil
    ) async throws -> SQLiteMediaReconciliationReport {
        try SQLiteMediaFileOperationValidation.batchLimit(maxOperations)
        let recoveredCount = try await store.recoverInterruptedMediaOperations(at: date)
        let operations = try await store.mediaOperationsNeedingReconciliation(
            limit: maxOperations
        )
        var completedCount = 0
        var failedCount = 0
        progress?(SQLiteMediaReconciliationProgress(
            total: operations.count,
            completed: completedCount,
            failed: failedCount
        ))

        let worker = SQLiteMediaFileOperationWorker(store: store)
        let acknowledger = SQLiteMediaMetadataAcknowledger(store: store)
        for operation in operations {
            try Task.checkCancellation()
            do {
                let publishedOperation = try await worker.run(
                    operationID: operation.id,
                    rootRegistry: rootRegistry,
                    at: date
                )
                let completedOperation = try await acknowledger.run(
                    for: publishedOperation,
                    at: date,
                    metadataCommit: metadataCommit
                )
                guard let sourceTransferID = completedOperation.sourceTransferID,
                      let assetID = completedOperation.assetID else {
                    throw SQLiteMediaFileOperationError.operationConflict
                }
                _ = try await store.recordImportReceipt(
                    sourceTransferID: sourceTransferID,
                    destinationStorageID: assetID,
                    outcome: .committed,
                    at: date
                )
                completedCount += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failedCount += 1
            }
            progress?(SQLiteMediaReconciliationProgress(
                total: operations.count,
                completed: completedCount,
                failed: failedCount
            ))
        }

        return SQLiteMediaReconciliationReport(
            recoveredOperationCount: recoveredCount,
            selectedOperationCount: operations.count,
            completedOperationCount: completedCount,
            failedOperationCount: failedCount
        )
    }
}

struct SQLiteArchiveRestoreProgress: Equatable, Sendable {
    let total: Int
    let completed: Int
    let failed: Int
}

struct SQLiteArchiveRestoreReport: Equatable, Sendable {
    let recoveredOperationCount: Int
    let selectedOperationCount: Int
    let completedOperationCount: Int
    let failedOperationCount: Int
}

/// Holds the logical roots and any process-local security scope needed while
/// one archive restore is copied and, after metadata acknowledgement, cleaned
/// up. The lease must stay alive for the whole operation; returning only a URL
/// would silently drop provider access before the detached worker runs.
struct SQLiteArchiveRestoreRootAccess: Sendable {
    let rootRegistry: SQLiteMediaRootRegistry
    let securityScopedBookmarkLease: SQLiteSecurityScopedBookmarkLease?

    init(
        rootRegistry: SQLiteMediaRootRegistry,
        securityScopedBookmarkLease: SQLiteSecurityScopedBookmarkLease? = nil
    ) {
        self.rootRegistry = rootRegistry
        self.securityScopedBookmarkLease = securityScopedBookmarkLease
    }
}

/// Reconciles provider archive restores in bounded, durable phases.
///
/// The metadata callback is supplied by the eventual app integration because
/// the current production source is still Core Data. It must be idempotent for
/// the operation's owner/revision. The journal acknowledges that callback only
/// after it returns, and source deletion is attempted only after that durable
/// acknowledgement.
actor SQLiteArchiveRestoreReconciler {
    let store: SQLiteLibraryStore
    let rootRegistry: SQLiteMediaRootRegistry

    init(
        store: SQLiteLibraryStore,
        rootRegistry: SQLiteMediaRootRegistry
    ) {
        self.store = store
        self.rootRegistry = rootRegistry
    }

    func run(
        maxOperations: Int = 8,
        at date: Date = Date(),
        metadataCommit: @escaping @Sendable (SQLiteArchiveRestoreOperation) async throws -> Void,
        progress: (@Sendable (SQLiteArchiveRestoreProgress) -> Void)? = nil
    ) async throws -> SQLiteArchiveRestoreReport {
        try await run(
            maxOperations: maxOperations,
            at: date,
            operationID: nil,
            rootAccessForOperation: { _ in
                SQLiteArchiveRestoreRootAccess(rootRegistry: self.rootRegistry)
            },
            metadataCommit: metadataCommit,
            progress: progress
        )
    }

    /// Runs the same durable state machine when each archive location resolves
    /// to its own security-scoped root. The resolver is called once per selected
    /// operation and its returned lease remains alive through source deletion.
    func run(
        maxOperations: Int = 8,
        at date: Date = Date(),
        operationID: String? = nil,
        rootAccessForOperation: @escaping @Sendable (SQLiteArchiveRestoreOperation) async throws -> SQLiteArchiveRestoreRootAccess,
        metadataCommit: @escaping @Sendable (SQLiteArchiveRestoreOperation) async throws -> Void,
        progress: (@Sendable (SQLiteArchiveRestoreProgress) -> Void)? = nil
    ) async throws -> SQLiteArchiveRestoreReport {
        guard (1...100).contains(maxOperations) else {
            throw SQLiteArchiveRestoreError.invalidBatchLimit
        }

        let recoveredCount = try await store.recoverInterruptedArchiveRestores(at: date)
        let operations: [SQLiteArchiveRestoreOperation]
        if let operationID {
            try SQLiteMediaFileOperationValidation.identifier(operationID)
            guard let operation = try await store.archiveRestoreOperation(id: operationID) else {
                throw SQLiteArchiveRestoreError.operationNotFound
            }
            operations = SQLiteArchiveRestorePhase.retryable.contains(operation.phase)
                ? [operation]
                : []
        } else {
            operations = try await store.archiveRestoreOperationsNeedingReconciliation(
                limit: maxOperations
            )
        }
        var completedCount = 0
        var failedCount = 0
        progress?(SQLiteArchiveRestoreProgress(
            total: operations.count,
            completed: completedCount,
            failed: failedCount
        ))

        let copyWorker = SQLiteArchiveRestoreCopyWorker(store: store)
        let sourceDeletionWorker = SQLiteArchiveRestoreSourceDeletionWorker(store: store)

        for operation in operations {
            try Task.checkCancellation()
            do {
                let rootAccess = try await rootAccessForOperation(operation)
                let securityScopedBookmarkLease = rootAccess.securityScopedBookmarkLease
                defer { securityScopedBookmarkLease?.stopAccessing() }
                let afterCopy = try await copyWorker.run(
                    operationID: operation.id,
                    rootRegistry: rootAccess.rootRegistry,
                    at: date
                )
                let afterMetadata = try await commitMetadataIfNeeded(
                    for: afterCopy,
                    at: date,
                    metadataCommit: metadataCommit
                )
                let finalOperation = try await sourceDeletionWorker.run(
                    operationID: afterMetadata.id,
                    rootRegistry: rootAccess.rootRegistry,
                    at: date
                )
                if finalOperation.phase == SQLiteArchiveRestorePhase.completed {
                    completedCount += 1
                } else {
                    throw SQLiteArchiveRestoreError.operationConflict
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failedCount += 1
            }
            progress?(SQLiteArchiveRestoreProgress(
                total: operations.count,
                completed: completedCount,
                failed: failedCount
            ))
        }

        return SQLiteArchiveRestoreReport(
            recoveredOperationCount: recoveredCount,
            selectedOperationCount: operations.count,
            completedOperationCount: completedCount,
            failedOperationCount: failedCount
        )
    }
}

private extension SQLiteArchiveRestoreReconciler {
    func commitMetadataIfNeeded(
        for operation: SQLiteArchiveRestoreOperation,
        at date: Date,
        metadataCommit: @escaping @Sendable (SQLiteArchiveRestoreOperation) async throws -> Void
    ) async throws -> SQLiteArchiveRestoreOperation {
        switch operation.phase {
        case SQLiteArchiveRestorePhase.copied,
             SQLiteArchiveRestorePhase.metadataFailed:
            let committing = try await store.claimArchiveRestoreMetadata(
                id: operation.id,
                at: date
            )
            do {
                try await metadataCommit(committing)
            } catch is CancellationError {
                _ = try? await store.requeueArchiveRestore(id: committing.id, at: date)
                throw CancellationError()
            } catch {
                _ = try? await store.failArchiveRestoreMetadata(
                    id: committing.id,
                    at: date
                )
                throw error
            }
            return try await store.completeArchiveRestoreMetadata(
                id: committing.id,
                at: date
            )
        case SQLiteArchiveRestorePhase.metadataCommitted,
             SQLiteArchiveRestorePhase.sourceDeletionFailed:
            return operation
        case SQLiteArchiveRestorePhase.completed:
            return operation
        default:
            throw SQLiteArchiveRestoreError.operationConflict
        }
    }
}
