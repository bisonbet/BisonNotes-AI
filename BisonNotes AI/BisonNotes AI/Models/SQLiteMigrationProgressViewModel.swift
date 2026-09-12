import SwiftUI

typealias SQLiteMigrationPresentationOperation = @Sendable (
    @escaping SQLiteMigrationProgressHandler
) async throws -> SQLiteMigrationCoordinatorResult

/// Main-actor bridge for the blocking first-boot migration screen. The
/// injected operation is intentionally separate from app startup until the
/// production SQLite generation, source bookmark scheduler and final media
/// root have been selected.
@MainActor
final class SQLiteMigrationProgressViewModel: ObservableObject {
    @Published private(set) var state: SQLiteMigrationPresentationState = .idle
    @Published private(set) var progress: SQLiteMigrationProgress?
    @Published private(set) var failureMessage: String?

    private let operation: SQLiteMigrationPresentationOperation
    private var presentation = SQLiteMigrationPresentationModel()
    private var task: Task<Void, Never>?

    init(operation: @escaping SQLiteMigrationPresentationOperation) {
        self.operation = operation
    }

    var isRunning: Bool {
        task != nil
    }

    var canStart: Bool {
        task == nil && presentation.canStart
    }

    func start() {
        guard canStart else { return }
        presentation.start()
        publish()

        let operation = self.operation
        task = Task { [weak self] in
            do {
                let result = try await operation { [weak self] progress in
                    await self?.receive(progress)
                }
                await self?.complete(with: result)
            } catch is CancellationError {
                await self?.pauseAfterCancellation()
            } catch {
                await self?.fail()
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func retry() {
        guard task == nil else { return }
        presentation.retry()
        publish()
        start()
    }

    deinit {
        task?.cancel()
    }

    private func receive(_ progress: SQLiteMigrationProgress) {
        presentation.apply(progress)
        publish()
    }

    private func complete(with result: SQLiteMigrationCoordinatorResult) {
        let current = progress
        let completedProgress = current ?? SQLiteMigrationProgress(
            phase: .completed,
            runID: result.run.id,
            metadataCompleted: result.run.metadataCompleted,
            metadataTotal: result.run.metadataTotal ?? result.verification.expectedRowCount,
            batchCount: result.run.batchCount,
            importedRowCount: 0,
            skippedRowCount: 0,
            settingsCompleted: 0,
            settingsTotal: 0
        )
        presentation.complete(with: completedProgress)
        publish()
        task = nil
    }

    private func pauseAfterCancellation() {
        presentation.pause()
        publish()
        task = nil
    }

    private func fail() {
        presentation.fail()
        publish()
        task = nil
    }

    private func publish() {
        state = presentation.state
        progress = presentation.progress
        failureMessage = presentation.failureMessage
    }
}
