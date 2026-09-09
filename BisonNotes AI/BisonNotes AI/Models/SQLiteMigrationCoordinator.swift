import Foundation

enum SQLiteMigrationCoordinatorPhase: String, Equatable, Sendable {
    case preparing
    case importingMetadata
    case verifying
    case completed
    case paused
    case failed
}

/// UI-safe progress emitted only after a durable migration checkpoint has
/// committed. It deliberately contains counts and phase, not source values.
struct SQLiteMigrationProgress: Equatable, Sendable {
    let phase: SQLiteMigrationCoordinatorPhase
    let runID: String?
    let metadataCompleted: Int
    let metadataTotal: Int
    let batchCount: Int
    let importedRowCount: Int
    let skippedRowCount: Int

    var fractionCompleted: Double {
        guard metadataTotal > 0 else {
            return phase == .completed ? 1 : 0
        }
        return min(1, max(0, Double(metadataCompleted) / Double(metadataTotal)))
    }
}

typealias SQLiteMigrationProgressHandler = @Sendable (SQLiteMigrationProgress) async -> Void

private struct SQLiteMigrationImportContext {
    let snapshot: SQLiteMigrationSourceSnapshot
    let store: SQLiteLibraryStore
    let batchSize: Int
    let run: SQLiteMigrationRun?
    let date: Date
    let progress: SQLiteMigrationProgressHandler?
}

private struct SQLiteMigrationFailureContext {
    let snapshot: SQLiteMigrationSourceSnapshot
    let store: SQLiteLibraryStore
    let activeRun: SQLiteMigrationRun?
    let date: Date
    let progress: SQLiteMigrationProgressHandler?
}

struct SQLiteMigrationCoordinatorResult: Equatable, Sendable {
    let run: SQLiteMigrationRun
    let verification: SQLiteMigrationVerificationReport
}

enum SQLiteMigrationCoordinatorError: LocalizedError, Equatable {
    case verificationFailed(SQLiteMigrationVerificationReport)

    var errorDescription: String? {
        switch self {
        case .verificationFailed:
            return "The SQLite metadata migration did not pass destination verification."
        }
    }
}

// swiftlint:disable type_body_length
/// Coordinates only the isolated metadata migration foundation.
///
/// This is intentionally not an app-startup hook and does not select a live
/// user store. It owns the safe sequence needed before that wiring exists:
/// validate a closed source snapshot, find an unfinished run after a restart,
/// import durable batches, verify the destination, and report a resumable
/// pause or a blocking failure. Audio/media copying and activation remain
/// separate phases.
struct SQLiteMigrationCoordinator: Sendable {
    func migrate(
        snapshot: SQLiteMigrationSourceSnapshot,
        into store: SQLiteLibraryStore,
        batchSize: Int = 100,
        runID: String? = nil,
        at date: Date = Date(),
        progress: SQLiteMigrationProgressHandler? = nil
    ) async throws -> SQLiteMigrationCoordinatorResult {
        var activeRun: SQLiteMigrationRun?

        do {
            try validate(snapshot: snapshot, batchSize: batchSize)
            activeRun = try await resolveRun(
                snapshot: snapshot,
                store: store,
                runID: runID
            )
            await emitPreparation(
                for: snapshot,
                run: activeRun,
                progress: progress
            )

            let importResult = try await importMetadata(
                SQLiteMigrationImportContext(
                    snapshot: snapshot,
                    store: store,
                    batchSize: batchSize,
                    run: activeRun,
                    date: date,
                    progress: progress
                )
            )
            activeRun = importResult.run

            let verification = try await verify(
                snapshot: snapshot,
                importResult: importResult,
                store: store,
                progress: progress
            )
            await emitCompletion(
                for: importResult,
                total: snapshot.rows.count,
                progress: progress
            )
            return SQLiteMigrationCoordinatorResult(run: importResult.run, verification: verification)
        } catch {
            await handleFailure(
                error,
                context: SQLiteMigrationFailureContext(
                    snapshot: snapshot,
                    store: store,
                    activeRun: activeRun,
                    date: date,
                    progress: progress
                )
            )
            throw error
        }
    }

    private func validate(
        snapshot: SQLiteMigrationSourceSnapshot,
        batchSize: Int
    ) throws {
        guard batchSize > 0 else {
            throw SQLiteMigrationImportError.invalidSnapshot(
                "batch size must be greater than zero"
            )
        }
        try SQLiteMigrationImportSupport.validate(snapshot: snapshot)
        guard snapshot.migrationRunID == nil else {
            throw SQLiteMigrationImportError.invalidSnapshot(
                "source snapshot must not contain a destination migration run ID"
            )
        }
    }

    private func resolveRun(
        snapshot: SQLiteMigrationSourceSnapshot,
        store: SQLiteLibraryStore,
        runID: String?
    ) async throws -> SQLiteMigrationRun? {
        if let runID {
            let run = try await store.migrationRun(id: runID)
            guard run != nil else {
                throw SQLiteMigrationImportError.runNotFound(runID)
            }
            return run
        }
        return try await store.latestResumableMigrationRun(
            sourceFingerprint: snapshot.sourceFingerprint,
            importerVersion: SQLiteMigrationMetadataImporter.version,
            sourceModel: snapshot.sourceModel
        )
    }

    private func emitPreparation(
        for snapshot: SQLiteMigrationSourceSnapshot,
        run: SQLiteMigrationRun?,
        progress: SQLiteMigrationProgressHandler?
    ) async {
        let completed = run?.metadataCompleted ?? 0
        let batches = run?.batchCount ?? 0
        await emit(
            SQLiteMigrationProgress(
                phase: .preparing,
                runID: run?.id,
                metadataCompleted: completed,
                metadataTotal: snapshot.rows.count,
                batchCount: batches,
                importedRowCount: 0,
                skippedRowCount: 0
            ),
            to: progress
        )
    }

    private func importMetadata(
        _ context: SQLiteMigrationImportContext
    ) async throws -> SQLiteMigrationImportResult {
        await emit(
            SQLiteMigrationProgress(
                phase: .importingMetadata,
                runID: context.run?.id,
                metadataCompleted: context.run?.metadataCompleted ?? 0,
                metadataTotal: context.snapshot.rows.count,
                batchCount: context.run?.batchCount ?? 0,
                importedRowCount: 0,
                skippedRowCount: 0
            ),
            to: context.progress
        )

        return try await SQLiteMigrationMetadataImporter.importSnapshot(
            context.snapshot,
            into: context.store,
            batchSize: context.batchSize,
            runID: context.run?.id,
            at: context.date
        ) { [progress = context.progress] batch in
            await progress?(
                SQLiteMigrationProgress(
                    phase: .importingMetadata,
                    runID: batch.run.id,
                    metadataCompleted: batch.run.metadataCompleted,
                    metadataTotal: batch.run.metadataTotal ?? context.snapshot.rows.count,
                    batchCount: batch.run.batchCount,
                    importedRowCount: batch.importedRowCount,
                    skippedRowCount: batch.skippedRowCount
                )
            )
        }
    }

    private func verify(
        snapshot: SQLiteMigrationSourceSnapshot,
        importResult: SQLiteMigrationImportResult,
        store: SQLiteLibraryStore,
        progress: SQLiteMigrationProgressHandler?
    ) async throws -> SQLiteMigrationVerificationReport {
        await emit(
            SQLiteMigrationProgress(
                phase: .verifying,
                runID: importResult.run.id,
                metadataCompleted: importResult.run.metadataCompleted,
                metadataTotal: snapshot.rows.count,
                batchCount: importResult.run.batchCount,
                importedRowCount: importResult.importedRowCount,
                skippedRowCount: importResult.skippedRowCount
            ),
            to: progress
        )

        let verificationSnapshot = SQLiteMigrationSourceSnapshot(
            sourceModel: snapshot.sourceModel,
            sourceFingerprint: snapshot.sourceFingerprint,
            migrationRunID: importResult.run.id,
            rows: snapshot.rows
        )
        let verification = try SQLiteMigrationVerifier.verify(
            snapshot: verificationSnapshot,
            databaseURL: store.databaseURL
        )
        guard verification.isValid else {
            throw SQLiteMigrationCoordinatorError.verificationFailed(verification)
        }
        return verification
    }

    private func emitCompletion(
        for result: SQLiteMigrationImportResult,
        total: Int,
        progress: SQLiteMigrationProgressHandler?
    ) async {
        await emit(
            SQLiteMigrationProgress(
                phase: .completed,
                runID: result.run.id,
                metadataCompleted: result.run.metadataCompleted,
                metadataTotal: total,
                batchCount: result.run.batchCount,
                importedRowCount: result.importedRowCount,
                skippedRowCount: result.skippedRowCount
            ),
            to: progress
        )
    }

    private func handleFailure(
        _ error: Error,
        context: SQLiteMigrationFailureContext
    ) async {
        let resumableRun: SQLiteMigrationRun?
        if let activeRun = context.activeRun {
            resumableRun = activeRun
        } else {
            resumableRun = try? await context.store.latestResumableMigrationRun(
                sourceFingerprint: context.snapshot.sourceFingerprint,
                importerVersion: SQLiteMigrationMetadataImporter.version,
                sourceModel: context.snapshot.sourceModel
            )
        }

        if error is CancellationError {
            await emitStatus(
                .paused,
                run: resumableRun,
                total: context.snapshot.rows.count,
                progress: context.progress
            )
        } else if Self.shouldPersistFailure(for: error) || resumableRun == nil {
            let failedRun: SQLiteMigrationRun?
            if let resumableRun {
                failedRun = await awaitFailMigrationRun(
                    runID: resumableRun.id,
                    store: context.store,
                    at: context.date
                )
            } else {
                failedRun = nil
            }
            await emitStatus(
                .failed,
                run: failedRun ?? resumableRun,
                total: context.snapshot.rows.count,
                progress: context.progress
            )
        } else {
            await emitStatus(
                .paused,
                run: resumableRun,
                total: context.snapshot.rows.count,
                progress: context.progress
            )
        }
    }

    private func awaitFailMigrationRun(
        runID: String,
        store: SQLiteLibraryStore,
        at date: Date
    ) async -> SQLiteMigrationRun? {
        try? await store.failMigrationRun(id: runID, at: date)
    }

    private func emitStatus(
        _ phase: SQLiteMigrationCoordinatorPhase,
        run: SQLiteMigrationRun?,
        total: Int,
        progress: SQLiteMigrationProgressHandler?
    ) async {
        await emit(
            SQLiteMigrationProgress(
                phase: phase,
                runID: run?.id,
                metadataCompleted: run?.metadataCompleted ?? 0,
                metadataTotal: total,
                batchCount: run?.batchCount ?? 0,
                importedRowCount: 0,
                skippedRowCount: 0
            ),
            to: progress
        )
    }

    private static func shouldPersistFailure(for error: Error) -> Bool {
        switch error {
        case is SQLiteMigrationCoordinatorError:
            return true
        case let error as SQLiteMigrationImportError:
            switch error {
            case .destinationRowConflict, .sourceRowConflict, .incompleteImport:
                return true
            case .invalidSnapshot, .runNotFound, .runConfigurationMismatch, .runNotResumable:
                return false
            }
        default:
            return false
        }
    }

    private func emit(
        _ value: SQLiteMigrationProgress,
        to progress: SQLiteMigrationProgressHandler?
    ) async {
        await progress?(value)
    }
}
// swiftlint:enable type_body_length
