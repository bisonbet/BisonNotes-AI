import Foundation

enum SQLiteMigrationPresentationState: String, Equatable, Sendable {
    case idle
    case running
    case paused
    case failed
    case completed
}

/// Pure state for the blocking first-boot migration screen. It deliberately
/// stores only durable progress counts and generic failure state; source rows,
/// paths and raw errors never enter the presentation model.
struct SQLiteMigrationPresentationModel: Equatable, Sendable {
    static let genericFailureMessage =
        "Your existing library is unchanged. Try the migration again, or contact support if the problem persists."

    private(set) var state: SQLiteMigrationPresentationState = .idle
    private(set) var progress: SQLiteMigrationProgress?
    private(set) var failureMessage: String?

    var canStart: Bool {
        state == .idle || state == .paused || state == .failed
    }

    mutating func start() {
        guard canStart else { return }
        state = .running
        failureMessage = nil
    }

    mutating func apply(_ progress: SQLiteMigrationProgress) {
        guard state != .completed else { return }
        self.progress = progress
        switch progress.phase {
        case .paused:
            state = .paused
            failureMessage = nil
        case .failed:
            state = .failed
            failureMessage = Self.genericFailureMessage
        case .completed:
            state = .completed
            failureMessage = nil
        default:
            state = .running
            failureMessage = nil
        }
    }

    mutating func pause() {
        guard state != .completed else { return }
        state = .paused
        failureMessage = nil
        progress = progress.map { $0.withPhase(.paused) }
    }

    mutating func fail() {
        guard state != .completed else { return }
        state = .failed
        failureMessage = Self.genericFailureMessage
        progress = progress.map { $0.withPhase(.failed) }
    }

    mutating func complete(with progress: SQLiteMigrationProgress) {
        self.progress = progress.withPhase(.completed)
        state = .completed
        failureMessage = nil
    }

    mutating func retry() {
        guard state == .paused || state == .failed else { return }
        state = .idle
        failureMessage = nil
    }
}

private extension SQLiteMigrationProgress {
    func withPhase(_ phase: SQLiteMigrationCoordinatorPhase) -> SQLiteMigrationProgress {
        SQLiteMigrationProgress(
            phase: phase,
            runID: runID,
            metadataCompleted: metadataCompleted,
            metadataTotal: metadataTotal,
            batchCount: batchCount,
            importedRowCount: importedRowCount,
            skippedRowCount: skippedRowCount,
            settingsCompleted: settingsCompleted,
            settingsTotal: settingsTotal
        )
    }
}
