import Foundation

enum SQLiteMigrationSourceCoordinatorError: LocalizedError, Equatable, Sendable {
    case sourceChanged(startingRevision: Int64, endingRevision: Int64)

    var errorDescription: String? {
        switch self {
        case let .sourceChanged(startingRevision, endingRevision):
            return "The source library changed during migration preparation "
                + "(revision \(startingRevision) to \(endingRevision))."
        }
    }
}

/// Drives the isolated migration coordinator from the real Core Data/defaults
/// source while holding one exclusive maintenance lease.
///
/// This is an app-wiring harness, not a startup hook. The caller supplies the
/// destination store and target normalization context explicitly. The source
/// observation is anchored only after the gate is acquired, so writes that
/// completed before quiescence are included in the captured snapshot. Any
/// committed source change observed before import blocks the run instead of
/// allowing an unverified snapshot to reach SQLite.
struct SQLiteMigrationSourceCoordinator: Sendable {
    private let inputReader: CoreDataMigrationInputReader
    private let observation: any LibraryObservation
    private let maintenanceGate: LibraryMaintenanceGate
    private let migrationCoordinator: SQLiteMigrationCoordinator

    init(
        inputReader: CoreDataMigrationInputReader,
        observation: any LibraryObservation,
        maintenanceGate: LibraryMaintenanceGate,
        migrationCoordinator: SQLiteMigrationCoordinator = SQLiteMigrationCoordinator()
    ) {
        self.inputReader = inputReader
        self.observation = observation
        self.maintenanceGate = maintenanceGate
        self.migrationCoordinator = migrationCoordinator
    }

    func migrate(
        sourceKeys: [String],
        normalizationContext: LibrarySettingsNormalizationContext,
        into store: SQLiteLibraryStore,
        batchSize: Int = 100,
        runID: String? = nil,
        at date: Date = Date(),
        progress: SQLiteMigrationProgressHandler? = nil
    ) async throws -> SQLiteMigrationCoordinatorResult {
        try await maintenanceGate.withExclusiveMaintenance {
            var subscription = try await LibraryObservationSubscription.anchored(
                to: observation
            )
            let startingRevision = subscription.cursor
            let input = try await inputReader.snapshot(
                sourceKeys: sourceKeys,
                normalizationContext: normalizationContext
            )
            let changes = try await subscription.poll()
            if let endingRevision = changes.last?.revision {
                throw SQLiteMigrationSourceCoordinatorError.sourceChanged(
                    startingRevision: startingRevision,
                    endingRevision: endingRevision
                )
            }

            try Task.checkCancellation()
            return try await migrationCoordinator.migrate(
                input: input,
                into: store,
                batchSize: batchSize,
                runID: runID,
                at: date,
                progress: progress
            )
        }
    }
}
