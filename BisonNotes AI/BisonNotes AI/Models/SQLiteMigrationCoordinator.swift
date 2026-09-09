import Foundation

// The coordinator keeps the durable phase transitions and failure policy in
// one reviewable state machine; splitting these cases solely for size limits
// would make the resumability rules harder to audit.
// swiftlint:disable file_length

enum SQLiteMigrationCoordinatorPhase: String, Equatable, Sendable {
    case preparing
    case importingMetadata
    case applyingSettings
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
    let settingsCompleted: Int
    let settingsTotal: Int

    var fractionCompleted: Double {
        let totalUnits = metadataTotal + settingsTotal
        guard totalUnits > 0 else {
            return phase == .completed ? 1 : 0
        }
        let completedUnits = metadataCompleted + settingsCompleted
        return min(1, max(0, Double(completedUnits) / Double(totalUnits)))
    }
}

typealias SQLiteMigrationProgressHandler = @Sendable (SQLiteMigrationProgress) async -> Void

private struct SQLiteMigrationImportContext {
    let snapshot: SQLiteMigrationSourceSnapshot
    let settings: LibrarySettingsSnapshot?
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
    let settingsTotal: Int
    let date: Date
    let progress: SQLiteMigrationProgressHandler?
}

private struct SQLiteMigrationSettingsContext {
    let snapshot: SQLiteMigrationSourceSnapshot
    let settings: LibrarySettingsSnapshot
    let importResult: SQLiteMigrationImportResult
    let store: SQLiteLibraryStore
    let date: Date
    let progress: SQLiteMigrationProgressHandler?
}

private struct SQLiteMigrationFinalizationContext {
    let snapshot: SQLiteMigrationSourceSnapshot
    let importResult: SQLiteMigrationImportResult
    let activeRun: SQLiteMigrationRun
    let settingsTotal: Int
    let store: SQLiteLibraryStore
    let date: Date
    let progress: SQLiteMigrationProgressHandler?
}

struct SQLiteMigrationCoordinatorResult: Equatable, Sendable {
    let run: SQLiteMigrationRun
    let verification: SQLiteMigrationVerificationReport
}

enum SQLiteMigrationCoordinatorError: LocalizedError, Equatable {
    case verificationFailed(SQLiteMigrationVerificationReport)
    case settingsVerificationFailed

    var errorDescription: String? {
        switch self {
        case .verificationFailed:
            return "The SQLite metadata migration did not pass destination verification."
        case .settingsVerificationFailed:
            return "The SQLite settings migration did not pass destination verification."
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
        input: CoreDataMigrationInputSnapshot,
        into store: SQLiteLibraryStore,
        batchSize: Int = 100,
        runID: String? = nil,
        at date: Date = Date(),
        progress: SQLiteMigrationProgressHandler? = nil
    ) async throws -> SQLiteMigrationCoordinatorResult {
        try await migrate(
            snapshot: input.metadata,
            into: store,
            settings: input.settings,
            batchSize: batchSize,
            runID: runID,
            at: date,
            progress: progress
        )
    }

    // swiftlint:disable:next function_body_length
    func migrate(
        snapshot: SQLiteMigrationSourceSnapshot,
        into store: SQLiteLibraryStore,
        settings: LibrarySettingsSnapshot? = nil,
        batchSize: Int = 100,
        runID: String? = nil,
        at date: Date = Date(),
        progress: SQLiteMigrationProgressHandler? = nil
    ) async throws -> SQLiteMigrationCoordinatorResult {
        var activeRun: SQLiteMigrationRun?

        do {
            try validate(snapshot: snapshot, batchSize: batchSize)
            try validate(settings: settings)
            activeRun = try await resolveRun(
                snapshot: snapshot,
                store: store,
                runID: runID
            )
            if activeRun?.phase == "settings", settings == nil {
                throw SQLiteMigrationImportError.runConfigurationMismatch(
                    "settings snapshot is required to resume the settings phase"
                )
            }
            await emitPreparation(
                for: snapshot,
                run: activeRun,
                settingsTotal: settings?.values.count ?? 0,
                progress: progress
            )

            let importResult = try await importMetadata(
                SQLiteMigrationImportContext(
                    snapshot: snapshot,
                    settings: settings,
                    store: store,
                    batchSize: batchSize,
                    run: activeRun,
                    date: date,
                    progress: progress
                )
            )
            activeRun = importResult.run

            if let settings {
                activeRun = try await applySettingsPhase(
                    SQLiteMigrationSettingsContext(
                        snapshot: snapshot,
                        settings: settings,
                        importResult: importResult,
                        store: store,
                        date: date,
                        progress: progress
                    )
                )
            }

            guard let activeRun else {
                throw SQLiteMigrationImportError.incompleteImport(
                    expected: snapshot.rows.count,
                    actual: 0
                )
            }
            return try await finalizeMigration(
                SQLiteMigrationFinalizationContext(
                    snapshot: snapshot,
                    importResult: importResult,
                    activeRun: activeRun,
                    settingsTotal: settings?.values.count ?? 0,
                    store: store,
                    date: date,
                    progress: progress
                )
            )
        } catch {
            await handleFailure(
                error,
                context: SQLiteMigrationFailureContext(
                    snapshot: snapshot,
                    store: store,
                    activeRun: activeRun,
                    settingsTotal: settings?.values.count ?? 0,
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

    private func validate(settings: LibrarySettingsSnapshot?) throws {
        guard let settings else { return }
        try LibrarySettingsCatalog.validateMigratableSnapshot(settings)
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
            guard run?.status != "failed" else {
                throw SQLiteMigrationImportError.runNotResumable(
                    "the run is already failed"
                )
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
        settingsTotal: Int,
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
                skippedRowCount: 0,
                settingsCompleted: 0,
                settingsTotal: settingsTotal
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
                skippedRowCount: 0,
                settingsCompleted: 0,
                settingsTotal: context.settings?.values.count ?? 0
            ),
            to: context.progress
        )

        return try await SQLiteMigrationMetadataImporter.importSnapshot(
            context.snapshot,
            into: context.store,
            options: SQLiteMigrationImportOptions(
                batchSize: context.batchSize,
                runID: context.run?.id,
                date: context.date,
                finalizeRun: context.settings == nil,
                progress: { [progress = context.progress] batch in
                    await progress?(
                        SQLiteMigrationProgress(
                            phase: .importingMetadata,
                            runID: batch.run.id,
                            metadataCompleted: batch.run.metadataCompleted,
                            metadataTotal: batch.run.metadataTotal ?? context.snapshot.rows.count,
                            batchCount: batch.run.batchCount,
                            importedRowCount: batch.importedRowCount,
                            skippedRowCount: batch.skippedRowCount,
                            settingsCompleted: 0,
                            settingsTotal: context.settings?.values.count ?? 0
                        )
                    )
                }
            )
        )
    }

    private func applySettingsPhase(
        _ context: SQLiteMigrationSettingsContext
    ) async throws -> SQLiteMigrationRun {
        let settingsRun = try await beginSettingsImport(
            run: context.importResult.run,
            store: context.store,
            at: context.date
        )
        await emitSettingsProgress(
            settingsCompleted: 0,
            settingsTotal: context.settings.values.count,
            run: settingsRun,
            metadataTotal: context.snapshot.rows.count,
            progress: context.progress
        )
        try Task.checkCancellation()
        try await applySettings(context.settings, to: context.store)
        try Task.checkCancellation()
        await emitSettingsProgress(
            settingsCompleted: context.settings.values.count,
            settingsTotal: context.settings.values.count,
            run: settingsRun,
            metadataTotal: context.snapshot.rows.count,
            progress: context.progress
        )
        try await verifySettings(context.settings, in: context.store)
        return settingsRun
    }

    private func finalizeMigration(
        _ context: SQLiteMigrationFinalizationContext
    ) async throws -> SQLiteMigrationCoordinatorResult {
        let verification = try await verify(
            snapshot: context.snapshot,
            importResult: context.importResult,
            store: context.store,
            settingsTotal: context.settingsTotal,
            progress: context.progress
        )
        try Task.checkCancellation()
        let completedRun = try await completeRun(
            context.activeRun,
            store: context.store,
            phase: context.settingsTotal == 0 ? context.importResult.run.phase : "completed",
            at: context.date
        )
        await emitCompletion(
            for: SQLiteMigrationImportResult(
                run: completedRun,
                importedRowCount: context.importResult.importedRowCount,
                skippedRowCount: context.importResult.skippedRowCount
            ),
            total: context.snapshot.rows.count,
            settingsTotal: context.settingsTotal,
            progress: context.progress
        )
        return SQLiteMigrationCoordinatorResult(run: completedRun, verification: verification)
    }

    private func beginSettingsImport(
        run: SQLiteMigrationRun,
        store: SQLiteLibraryStore,
        at date: Date
    ) async throws -> SQLiteMigrationRun {
        guard run.status != "failed" else {
            throw SQLiteMigrationImportError.runNotResumable(
                "the run is already failed"
            )
        }
        return try await store.checkpointMigrationRun(
            id: run.id,
            phase: "settings",
            status: "running",
            metadataCompleted: run.metadataCompleted,
            batchCursor: run.batchCursor,
            batchCount: run.batchCount,
            batchSHA256: run.batchSHA256,
            at: date
        )
    }

    private func emitSettingsProgress(
        settingsCompleted: Int,
        settingsTotal: Int,
        run: SQLiteMigrationRun,
        metadataTotal: Int,
        progress: SQLiteMigrationProgressHandler?
    ) async {
        await emit(
            SQLiteMigrationProgress(
                phase: .applyingSettings,
                runID: run.id,
                metadataCompleted: run.metadataCompleted,
                metadataTotal: metadataTotal,
                batchCount: run.batchCount,
                importedRowCount: 0,
                skippedRowCount: 0,
                settingsCompleted: settingsCompleted,
                settingsTotal: settingsTotal
            ),
            to: progress
        )
    }

    private func applySettings(
        _ settings: LibrarySettingsSnapshot,
        to store: SQLiteLibraryStore
    ) async throws {
        let destination = try SQLiteLibrarySettingsStore(
            store: store,
            allowedKeys: LibrarySettingsCatalog.blockingMetadataKeys
        )
        try await destination.apply(settings)
    }

    private func verifySettings(
        _ expected: LibrarySettingsSnapshot,
        in store: SQLiteLibraryStore
    ) async throws {
        let destination = try SQLiteLibrarySettingsStore(
            store: store,
            allowedKeys: LibrarySettingsCatalog.blockingMetadataKeys
        )
        let actual = try await destination.read()
        guard actual == expected else {
            throw SQLiteMigrationCoordinatorError.settingsVerificationFailed
        }
    }

    private func completeRun(
        _ run: SQLiteMigrationRun,
        store: SQLiteLibraryStore,
        phase: String,
        at date: Date
    ) async throws -> SQLiteMigrationRun {
        guard run.status != "failed" else {
            throw SQLiteMigrationImportError.runNotResumable(
                "the run is already failed"
            )
        }
        guard run.status != "completed" || run.phase != phase else {
            return run
        }
        return try await store.checkpointMigrationRun(
            id: run.id,
            phase: phase,
            status: "completed",
            metadataCompleted: run.metadataCompleted,
            batchCursor: run.batchCursor,
            batchCount: run.batchCount,
            batchSHA256: run.batchSHA256,
            at: date
        )
    }

    private func verify(
        snapshot: SQLiteMigrationSourceSnapshot,
        importResult: SQLiteMigrationImportResult,
        store: SQLiteLibraryStore,
        settingsTotal: Int,
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
                skippedRowCount: importResult.skippedRowCount,
                settingsCompleted: settingsTotal,
                settingsTotal: settingsTotal
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
        settingsTotal: Int,
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
                skippedRowCount: result.skippedRowCount,
                settingsCompleted: settingsTotal,
                settingsTotal: settingsTotal
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

        if error is CancellationError ||
            (!Self.shouldPersistFailure(for: error) && resumableRun != nil) {
            let pausedRun = await awaitPauseMigrationRun(
                runID: resumableRun?.id,
                store: context.store,
                at: context.date
            )
            await emitStatus(
                .paused,
                run: pausedRun ?? resumableRun,
                total: context.snapshot.rows.count,
                settingsTotal: context.settingsTotal,
                progress: context.progress
            )
        } else {
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
                settingsTotal: context.settingsTotal,
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

    private func awaitPauseMigrationRun(
        runID: String?,
        store: SQLiteLibraryStore,
        at date: Date
    ) async -> SQLiteMigrationRun? {
        guard let runID else { return nil }
        return try? await store.pauseMigrationRun(id: runID, at: date)
    }

    private func emitStatus(
        _ phase: SQLiteMigrationCoordinatorPhase,
        run: SQLiteMigrationRun?,
        total: Int,
        settingsTotal: Int,
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
                skippedRowCount: 0,
                settingsCompleted: 0,
                settingsTotal: settingsTotal
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
// swiftlint:enable file_length
