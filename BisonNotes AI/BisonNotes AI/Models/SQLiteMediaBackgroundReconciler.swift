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
/// The reconciler only copies media and records committed receipts. Source
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
        for operation in operations {
            try Task.checkCancellation()
            do {
                let completedOperation = try await worker.run(
                    operationID: operation.id,
                    rootRegistry: rootRegistry,
                    at: date
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
