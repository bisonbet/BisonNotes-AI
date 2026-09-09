import Foundation
import GRDB

extension SQLiteLibraryStore {
    /// Returns the newest unfinished run for the exact source generation.
    ///
    /// The migration coordinator uses this lookup after a process kill or
    /// crash. The source fingerprint/model pair is the identity boundary; a
    /// run ID kept only in memory is not sufficient for a resumable first
    /// boot.
    func latestResumableMigrationRun(
        sourceFingerprint: String,
        importerVersion: String,
        sourceModel: String?
    ) throws -> SQLiteMigrationRun? {
        guard !sourceFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !importerVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SQLiteLibraryStoreError.invalidMigrationCheckpoint(
                "source fingerprint and importer version must not be empty"
            )
        }

        return try databaseQueue.read { database in
            let runID: String?
            if let sourceModel {
                runID = try String.fetchOne(
                    database,
                    sql: """
                    SELECT id
                    FROM migration_runs
                    WHERE sourceFingerprint = ?
                      AND importerVersion = ?
                      AND sourceModel = ?
                      AND status IN ('pending', 'running', 'paused')
                    ORDER BY updatedAt DESC, startedAt DESC, id DESC
                    LIMIT 1
                    """,
                    arguments: [sourceFingerprint, importerVersion, sourceModel]
                )
            } else {
                runID = try String.fetchOne(
                    database,
                    sql: """
                    SELECT id
                    FROM migration_runs
                    WHERE sourceFingerprint = ?
                      AND importerVersion = ?
                      AND sourceModel IS NULL
                      AND status IN ('pending', 'running', 'paused')
                    ORDER BY updatedAt DESC, startedAt DESC, id DESC
                    LIMIT 1
                    """,
                    arguments: [sourceFingerprint, importerVersion]
                )
            }

            guard let runID else { return nil }
            return try SQLiteMigrationStoreSupport.fetchRun(id: runID, from: database)
        }
    }

    /// Marks a run as failed without retaining the underlying error text.
    ///
    /// Detailed diagnostics belong in the redacted recovery report. Keeping a
    /// generic checkpoint message avoids putting source values or file paths
    /// into the durable migration database while still preventing accidental
    /// activation of a partially verified generation.
    func failMigrationRun(
        id: String,
        at date: Date = Date()
    ) throws -> SQLiteMigrationRun {
        guard let run = try migrationRun(id: id) else {
            throw SQLiteLibraryStoreError.migrationRunNotFound(id)
        }
        if run.status == "failed" {
            return run
        }
        return try checkpointMigrationRun(
            id: run.id,
            phase: run.phase,
            status: "failed",
            metadataCompleted: run.metadataCompleted,
            batchCursor: run.batchCursor,
            batchCount: run.batchCount,
            batchSHA256: run.batchSHA256,
            errorMessage: "metadata migration stopped; recovery report required",
            at: date
        )
    }

    /// Marks a run paused without retaining transient error text.
    ///
    /// A paused run is still eligible for exact-source resume after the app is
    /// relaunched. The checkpoint preserves the last committed metadata batch
    /// and any settings-phase marker, so cancellation cannot look like a
    /// successful completion or require an in-memory run ID.
    func pauseMigrationRun(
        id: String,
        at date: Date = Date()
    ) throws -> SQLiteMigrationRun {
        guard let run = try migrationRun(id: id) else {
            throw SQLiteLibraryStoreError.migrationRunNotFound(id)
        }
        guard run.status != "failed", run.status != "completed" else {
            return run
        }
        return try checkpointMigrationRun(
            id: run.id,
            phase: run.phase,
            status: "paused",
            metadataCompleted: run.metadataCompleted,
            batchCursor: run.batchCursor,
            batchCount: run.batchCount,
            batchSHA256: run.batchSHA256,
            errorMessage: nil,
            at: date
        )
    }
}
