import Foundation

/// Joins verified media publication to its durable transfer receipt.
///
/// This coordinator deliberately reports source-removal eligibility instead of
/// deleting anything. The production caller must apply the decision only after
/// its own source-specific retention and backup rules have been satisfied.
struct SQLiteMediaTransferCoordinator: Sendable {
    let store: SQLiteLibraryStore
    let rootRegistry: SQLiteMediaRootRegistry

    func enqueue(
        _ transfer: SQLiteMediaTransferPlan,
        at date: Date = Date()
    ) async throws -> SQLiteMediaFileOperation {
        try transfer.validate()
        _ = try rootRegistry.roots(
            sourceRoot: transfer.copyPlan.sourceRoot,
            destinationRoot: transfer.copyPlan.destinationRoot
        )
        return try await store.enqueueMediaCopy(transfer, at: date)
    }

    func reconcile(
        _ transfer: SQLiteMediaTransferPlan,
        at date: Date = Date()
    ) async throws -> SQLiteMediaTransferResult {
        let operation = try await enqueue(transfer, at: date)
        let completedOperation = try await SQLiteMediaFileOperationWorker(
            store: store
        ).run(
            operationID: operation.id,
            rootRegistry: rootRegistry,
            at: date
        )
        let receipt = try await store.recordImportReceipt(
            sourceTransferID: transfer.sourceTransferID,
            destinationStorageID: completedOperation.assetID,
            outcome: .committed,
            at: date
        )
        let sourceRetention = try SQLiteMediaSourceRetentionPolicy.disposition(
            sourceTransferID: transfer.sourceTransferID,
            operation: completedOperation,
            receipt: receipt
        )
        return SQLiteMediaTransferResult(
            operation: completedOperation,
            receipt: receipt,
            sourceRetention: sourceRetention
        )
    }
}
