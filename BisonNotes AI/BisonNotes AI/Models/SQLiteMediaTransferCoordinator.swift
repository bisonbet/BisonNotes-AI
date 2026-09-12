import Foundation

typealias SQLiteMediaMetadataCommit = @Sendable (SQLiteMediaFileOperation) async throws -> Void

enum SQLiteApplicationMediaTransferLifecycle {
    static let retryRequested = Notification.Name(
        "BisonNotes.SQLiteApplicationMediaTransferRetryRequested"
    )
}

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

/// Adapts the generic media journal to application-owned logical roots.
///
/// This is a pre-cutover service: it journals an incoming media handoff beside
/// the current Core Data store, while the caller keeps Core Data authoritative
/// for metadata. The destination root is selected in the request so this
/// boundary cannot silently move audio into the future SQLite media root.
struct SQLiteApplicationMediaTransferCoordinator: Sendable {
    let store: SQLiteLibraryStore
    let mapping: SQLiteApplicationMediaRootMapping

    func transfer(
        _ request: SQLiteMediaTransferRequest,
        at date: Date = Date(),
        metadataCommit: @escaping SQLiteMediaMetadataCommit,
        progress: (@Sendable (SQLiteMediaReconciliationProgress) -> Void)? = nil
    ) async throws -> SQLiteMediaTransferResult {
        let plan = try SQLiteApplicationMediaTransferPlanner(
            mapping: mapping
        ).makePlan(request)
        return try await SQLiteMediaTransferCoordinator(
            store: store,
            rootRegistry: mapping.registry
        ).reconcile(
            plan,
            at: date,
            metadataCommit: metadataCommit
        )
    }

    func enqueue(
        _ request: SQLiteMediaTransferRequest,
        fileManager: FileManager = .default,
        at date: Date = Date()
    ) async throws -> SQLiteMediaFileOperation {
        let plan = try SQLiteApplicationMediaTransferPlanner(
            mapping: mapping
        ).makePlan(request, fileManager: fileManager)
        return try await SQLiteMediaTransferCoordinator(
            store: store,
            rootRegistry: mapping.registry
        ).enqueue(plan, at: date)
    }

    func reconcilePending(
        maxOperations: Int = 8,
        at date: Date = Date(),
        metadataCommit: @escaping SQLiteMediaMetadataCommit,
        progress: (@Sendable (SQLiteMediaReconciliationProgress) -> Void)? = nil
    ) async throws -> SQLiteMediaReconciliationReport {
        try await SQLiteMediaBackgroundReconciler(
            store: store,
            rootRegistry: mapping.registry
        ).run(
            maxOperations: maxOperations,
            at: date,
            metadataCommit: metadataCommit,
            progress: progress
        )
    }

    func removeSourceIfEligible(
        sourceTransferID: String,
        operationID: String
    ) async throws -> SQLiteMediaFileOperation {
        try await SQLiteMediaSourceRetentionExecutor(
            store: store,
            rootRegistry: mapping.registry
        ).removeSourceIfEligible(
            sourceTransferID: sourceTransferID,
            operationID: operationID
        )
    }

    /// Finishes source cleanup that may have been interrupted after the
    /// receipt was recorded. The source root filter prevents a Watch retry
    /// pass from deleting an unrelated provider or share source.
    func removeEligibleSources(
        sourceRoot: String,
        maxOperations: Int = 8
    ) async throws -> Int {
        try SQLiteMediaFileOperationValidation.root(sourceRoot)
        let operations = try await store.mediaOperationsEligibleForSourceRemoval(
            sourceRoot: sourceRoot,
            limit: maxOperations
        )
        let executor = SQLiteMediaSourceRetentionExecutor(
            store: store,
            rootRegistry: mapping.registry
        )
        var removedCount = 0
        for operation in operations {
            guard let sourceTransferID = operation.sourceTransferID else { continue }
            do {
                _ = try await executor.removeSourceIfEligible(
                    sourceTransferID: sourceTransferID,
                    operationID: operation.id
                )
                removedCount += 1
            } catch {
                // A failed cleanup remains eligible for the next bounded
                // pass. Never turn a cleanup failure into data loss.
            }
        }
        return removedCount
    }
}

/// Serializes direct application transfers with restart reconciliation against
/// the same durable journal. The actor prevents an activation retry from
/// racing a just-arrived Watch/share handoff.
actor SQLiteApplicationMediaTransferRuntime {
    let coordinator: SQLiteApplicationMediaTransferCoordinator

    init(coordinator: SQLiteApplicationMediaTransferCoordinator) {
        self.coordinator = coordinator
    }

    func transfer(
        _ request: SQLiteMediaTransferRequest,
        at date: Date = Date(),
        metadataCommit: @escaping SQLiteMediaMetadataCommit,
        progress: (@Sendable (SQLiteMediaReconciliationProgress) -> Void)? = nil
    ) async throws -> SQLiteMediaTransferResult {
        try await coordinator.transfer(
            request,
            at: date,
            metadataCommit: metadataCommit,
            progress: progress
        )
    }

    func reconcilePending(
        maxOperations: Int = 8,
        at date: Date = Date(),
        metadataCommit: @escaping SQLiteMediaMetadataCommit,
        progress: (@Sendable (SQLiteMediaReconciliationProgress) -> Void)? = nil
    ) async throws -> SQLiteMediaReconciliationReport {
        try await coordinator.reconcilePending(
            maxOperations: maxOperations,
            at: date,
            metadataCommit: metadataCommit,
            progress: progress
        )
    }

    func removeSourceIfEligible(
        sourceTransferID: String,
        operationID: String
    ) async throws -> SQLiteMediaFileOperation {
        try await coordinator.removeSourceIfEligible(
            sourceTransferID: sourceTransferID,
            operationID: operationID
        )
    }

    func removeEligibleSources(
        sourceRoot: String,
        maxOperations: Int = 8
    ) async throws -> Int {
        try await coordinator.removeEligibleSources(
            sourceRoot: sourceRoot,
            maxOperations: maxOperations
        )
    }
}
