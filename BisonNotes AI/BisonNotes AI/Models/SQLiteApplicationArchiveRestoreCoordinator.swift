import Foundation

enum SQLiteApplicationArchiveRestoreError: LocalizedError, Equatable, Sendable {
    case operationDidNotComplete(phase: String)

    var errorDescription: String? {
        switch self {
        case .operationDidNotComplete(let phase):
            return "The archive restore did not complete; its durable phase is \(phase)."
        }
    }
}

/// Connects the root-relative archive journal to application-owned paths.
///
/// This coordinator does not choose a live library backend. Callers supply the
/// SQLite store, root mapping, resolved bookmark lease and metadata acknowledgement
/// so Core Data can remain authoritative until the migration cutover is approved.
struct SQLiteArchiveRestoreCoordinator: Sendable {
    typealias MetadataCommit = @Sendable (
        SQLiteArchiveRestoreOperation,
        URL
    ) async throws -> Void

    let store: SQLiteLibraryStore
    let mapping: SQLiteApplicationMediaRootMapping

    /// Enqueues or resumes exactly this restore operation. A targeted run is
    /// important when an older pending operation exists: a user retry must not
    /// accidentally process a different archive location with its bookmark.
    func restore(
        _ request: SQLiteArchiveRestoreRequest,
        rootAccess: SQLiteArchiveRestoreRootAccess,
        at date: Date = Date(),
        metadataCommit: @escaping MetadataCommit,
        progress: (@Sendable (SQLiteArchiveRestoreProgress) -> Void)? = nil
    ) async throws -> SQLiteArchiveRestoreOperation {
        let plan = try SQLiteApplicationArchiveRestorePlanner(
            mapping: mapping
        ).makePlan(request)
        let enqueued = try await store.enqueueArchiveRestore(plan, at: date)
        let reconciler = SQLiteArchiveRestoreReconciler(
            store: store,
            rootRegistry: mapping.registry
        )
        _ = try await reconciler.run(
            maxOperations: 1,
            at: date,
            operationID: enqueued.id,
            rootAccessForOperation: { operation in
                guard operation.id == enqueued.id else {
                    throw SQLiteArchiveRestoreError.operationConflict
                }
                return rootAccess
            },
            metadataCommit: { operation in
                let destinationURL = try mapping.registry.destinationURL(
                    root: operation.destinationRoot,
                    relativePath: operation.destinationRelativePath
                )
                try await metadataCommit(operation, destinationURL)
            },
            progress: progress
        )

        guard let completed = try await store.archiveRestoreOperation(id: enqueued.id) else {
            throw SQLiteArchiveRestoreError.operationNotFound
        }
        guard completed.phase == SQLiteArchiveRestorePhase.completed else {
            throw SQLiteApplicationArchiveRestoreError.operationDidNotComplete(
                phase: completed.phase
            )
        }
        return completed
    }

    /// Runs bounded retry work after a process restart. Each operation resolves
    /// its own bookmark/root, so one inaccessible provider location cannot grant
    /// a different operation access to the wrong file tree.
    func reconcilePending(
        maxOperations: Int = 8,
        at date: Date = Date(),
        rootAccessForOperation: @escaping @Sendable (
            SQLiteArchiveRestoreOperation
        ) async throws -> SQLiteArchiveRestoreRootAccess,
        metadataCommit: @escaping MetadataCommit,
        progress: (@Sendable (SQLiteArchiveRestoreProgress) -> Void)? = nil
    ) async throws -> SQLiteArchiveRestoreReport {
        let reconciler = SQLiteArchiveRestoreReconciler(
            store: store,
            rootRegistry: mapping.registry
        )
        return try await reconciler.run(
            maxOperations: maxOperations,
            at: date,
            rootAccessForOperation: rootAccessForOperation,
            metadataCommit: { operation in
                let destinationURL = try mapping.registry.destinationURL(
                    root: operation.destinationRoot,
                    relativePath: operation.destinationRelativePath
                )
                try await metadataCommit(operation, destinationURL)
            },
            progress: progress
        )
    }
}

/// Serializes direct user restores and bounded restart retries against the
/// same durable journal. The actor is intentionally independent of app UI and
/// can be invoked from a lifecycle/background scheduler later.
actor SQLiteApplicationArchiveRestoreRuntime {
    let coordinator: SQLiteArchiveRestoreCoordinator

    init(coordinator: SQLiteArchiveRestoreCoordinator) {
        self.coordinator = coordinator
    }

    func restore(
        _ request: SQLiteArchiveRestoreRequest,
        rootAccess: SQLiteArchiveRestoreRootAccess,
        at date: Date = Date(),
        metadataCommit: @escaping SQLiteArchiveRestoreCoordinator.MetadataCommit,
        progress: (@Sendable (SQLiteArchiveRestoreProgress) -> Void)? = nil
    ) async throws -> SQLiteArchiveRestoreOperation {
        try await coordinator.restore(
            request,
            rootAccess: rootAccess,
            at: date,
            metadataCommit: metadataCommit,
            progress: progress
        )
    }

    func reconcilePending(
        maxOperations: Int = 8,
        at date: Date = Date(),
        rootAccessForOperation: @escaping @Sendable (
            SQLiteArchiveRestoreOperation
        ) async throws -> SQLiteArchiveRestoreRootAccess,
        metadataCommit: @escaping SQLiteArchiveRestoreCoordinator.MetadataCommit,
        progress: (@Sendable (SQLiteArchiveRestoreProgress) -> Void)? = nil
    ) async throws -> SQLiteArchiveRestoreReport {
        try await coordinator.reconcilePending(
            maxOperations: maxOperations,
            at: date,
            rootAccessForOperation: rootAccessForOperation,
            metadataCommit: metadataCommit,
            progress: progress
        )
    }
}
