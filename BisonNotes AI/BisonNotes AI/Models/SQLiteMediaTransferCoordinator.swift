import Foundation

typealias SQLiteMediaMetadataCommit = @Sendable (SQLiteMediaFileOperation) async throws -> Void

/// Runs the metadata half of a generic media transfer after its destination
/// has been verified. The callback must be idempotent because a process can
/// terminate after the caller's metadata transaction but before this journal
/// records the acknowledgement.
struct SQLiteMediaMetadataAcknowledger: Sendable {
    let store: SQLiteLibraryStore

    func run(
        for operation: SQLiteMediaFileOperation,
        at date: Date,
        metadataCommit: @escaping SQLiteMediaMetadataCommit
    ) async throws -> SQLiteMediaFileOperation {
        switch operation.metadataState {
        case SQLiteMediaMetadataState.committed,
             SQLiteMediaMetadataState.legacy:
            return operation
        case SQLiteMediaMetadataState.pending,
             SQLiteMediaMetadataState.failed:
            break
        case SQLiteMediaMetadataState.committing:
            throw SQLiteMediaFileOperationError.operationConflict
        default:
            throw SQLiteMediaFileOperationError.operationConflict
        }

        let committing = try await store.claimMediaMetadataAcknowledgement(
            id: operation.id,
            at: date
        )
        do {
            try Task.checkCancellation()
            try await metadataCommit(committing)
            try Task.checkCancellation()
        } catch is CancellationError {
            _ = try? await store.requeueMediaMetadataAcknowledgement(
                id: committing.id,
                at: date
            )
            throw CancellationError()
        } catch {
            _ = try? await store.failMediaMetadataAcknowledgement(
                id: committing.id,
                at: date
            )
            throw error
        }

        return try await store.completeMediaMetadataAcknowledgement(
            id: committing.id,
            at: date
        )
    }
}

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
        at date: Date = Date(),
        metadataCommit: @escaping SQLiteMediaMetadataCommit
    ) async throws -> SQLiteMediaTransferResult {
        let operation = try await enqueue(transfer, at: date)
        let publishedOperation = try await SQLiteMediaFileOperationWorker(
            store: store
        ).run(
            operationID: operation.id,
            rootRegistry: rootRegistry,
            at: date
        )
        let completedOperation = try await SQLiteMediaMetadataAcknowledger(
            store: store
        ).run(
            for: publishedOperation,
            at: date,
            metadataCommit: metadataCommit
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
