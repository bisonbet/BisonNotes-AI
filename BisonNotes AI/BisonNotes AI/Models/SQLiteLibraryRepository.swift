import Foundation
import GRDB

/// Read-only repository adapter for the app-owned SQLite generation.
///
/// This adapter is intentionally not connected to production app startup yet.
/// It provides the storage-neutral boundary and contract-test target needed
/// before any caller is moved away from Core Data.
struct SQLiteLibraryRepository: LibraryRepository, LibraryObservation, Sendable {
    let store: SQLiteLibraryStore

    func currentRevision() async throws -> Int64 {
        try await store.currentLibraryRevision()
    }

    func changes(since revision: Int64) async throws -> [LibraryChange] {
        try await store.libraryChanges(since: revision)
    }

    func fetchRecordingSummaries() async throws -> [LibraryRecordingSnapshot] {
        try await store.fetchRecordingSummaries()
    }

    func fetchTranscriptSnapshots() async throws -> [LibraryTranscriptSnapshot] {
        try await store.fetchTranscriptSnapshots()
    }

    func fetchSummarySnapshots() async throws -> [LibrarySummarySnapshot] {
        try await store.fetchSummarySnapshots()
    }

    func fetchProcessingJobSnapshots() async throws -> [LibraryProcessingJobSnapshot] {
        try await store.fetchProcessingJobSnapshots()
    }

    func fetchArchiveLocationSnapshots() async throws -> [LibraryArchiveLocationSnapshot] {
        try await store.fetchArchiveLocationSnapshots()
    }

    func fetchPendingCloudMutationSnapshots() async throws -> [LibraryPendingCloudMutationSnapshot] {
        try await store.fetchPendingCloudMutationSnapshots()
    }

    func renameRecording(
        _ command: LibraryRecordingRenameCommand
    ) async throws -> LibraryRecordingSnapshot {
        try await store.renameRecording(command)
    }
}

extension SQLiteLibraryStore {
    func renameRecording(
        _ command: LibraryRecordingRenameCommand
    ) throws -> LibraryRecordingSnapshot {
        let reference = try Self.normalizedReference(command.reference)
        return try databaseQueue.write { database in
            let rows = try Self.fetchRecordingRows(for: reference, in: database)
            let current = try Self.validateRenameTarget(
                rows: rows,
                reference: reference,
                command: command
            )
            try Self.updateRecording(current: current, command: command, in: database)
            _ = try SQLiteLibraryStore.recordChange(
                in: database,
                entity: .recording,
                storageID: current.storageID,
                operation: .updated,
                at: command.modifiedAt
            )
            return try Self.fetchUpdatedRecording(storageID: current.storageID, in: database)
        }
    }

    private static func normalizedReference(
        _ reference: LibraryRecordingReference
    ) throws -> LibraryRecordingReference {
        let storageID = reference.storageID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyID = reference.legacyID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard storageID?.isEmpty == false || legacyID?.isEmpty == false else {
            throw LibraryRepositoryError.invalidCommand(
                "recording reference must contain a storage ID or legacy ID"
            )
        }
        return LibraryRecordingReference(
            storageID: storageID?.isEmpty == false ? storageID : nil,
            legacyID: legacyID?.isEmpty == false ? legacyID : nil
        )
    }

    private static func fetchRecordingRows(
        for reference: LibraryRecordingReference,
        in database: Database
    ) throws -> [Row] {
        let columns = """
            storageID, id, recordingName, recordingDate, duration,
            fileSize, recordingURL, isArchived, lastModified
            """
        if let storageID = reference.storageID {
            return try Row.fetchAll(
                database,
                sql: "SELECT \(columns) FROM recordings WHERE storageID = ? LIMIT 2",
                arguments: [storageID]
            )
        }
        guard let legacyID = reference.legacyID else {
            throw LibraryRepositoryError.invalidCommand(
                "recording reference must contain a storage ID or legacy ID"
            )
        }
        return try Row.fetchAll(
            database,
            sql: "SELECT \(columns) FROM recordings WHERE id = ? LIMIT 2",
            arguments: [legacyID]
        )
    }

    private static func validateRenameTarget(
        rows: [Row],
        reference: LibraryRecordingReference,
        command: LibraryRecordingRenameCommand
    ) throws -> LibraryRecordingSnapshot {
        guard !rows.isEmpty else {
            throw LibraryRepositoryError.recordingNotFound(reference: reference.displayValue)
        }
        guard rows.count == 1 else {
            throw LibraryRepositoryError.ambiguousRecording(reference: reference.displayValue)
        }

        let current = try SQLiteLibraryRepositoryMapper.snapshot(from: rows[0])
        guard command.expectedLastModified == nil
                || command.expectedLastModified == current.lastModified else {
            throw LibraryRepositoryError.staleRecording(
                reference: reference.displayValue,
                expected: command.expectedLastModified,
                actual: current.lastModified
            )
        }
        return current
    }

    private static func updateRecording(
        current: LibraryRecordingSnapshot,
        command: LibraryRecordingRenameCommand,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
            UPDATE recordings
            SET recordingName = ?, lastModified = ?
            WHERE storageID = ?
            """,
            arguments: [
                command.normalizedName,
                command.modifiedAt.timeIntervalSinceReferenceDate,
                current.storageID
            ]
        )
        guard database.changesCount == 1 else {
            throw LibraryRepositoryError.writeFailed(
                operation: "rename recording",
                reason: "the recording row was not updated"
            )
        }
    }

    private static func fetchUpdatedRecording(
        storageID: String,
        in database: Database
    ) throws -> LibraryRecordingSnapshot {
        let columns = """
            storageID, id, recordingName, recordingDate, duration,
            fileSize, recordingURL, isArchived, lastModified
            """
        guard let updatedRow = try Row.fetchOne(
            database,
            sql: "SELECT \(columns) FROM recordings WHERE storageID = ?",
            arguments: [storageID]
        ) else {
            throw LibraryRepositoryError.writeFailed(
                operation: "rename recording",
                reason: "the updated recording row could not be read"
            )
        }
        return try SQLiteLibraryRepositoryMapper.snapshot(from: updatedRow)
    }

    func fetchRecordingSummaries() throws -> [LibraryRecordingSnapshot] {
        try databaseQueue.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT storageID, id, recordingName, recordingDate, duration,
                       fileSize, recordingURL, isArchived, lastModified
                FROM recordings
                """
            )
            return try rows
                .map(SQLiteLibraryRepositoryMapper.snapshot(from:))
                .sorted(by: LibraryRecordingSnapshot.stableOrder)
        }
    }

    func fetchTranscriptSnapshots() throws -> [LibraryTranscriptSnapshot] {
        try databaseQueue.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT storageID, confidence, createdAt, engine, id, lastModified,
                       processingTime, recordingStorageID, recordingId, segments,
                       speakerMappings
                FROM transcripts
                """
            )
            return try rows
                .map(SQLiteLibraryRepositoryMapper.transcript(from:))
                .sorted { $0.storageID < $1.storageID }
        }
    }

    func fetchSummarySnapshots() throws -> [LibrarySummarySnapshot] {
        try databaseQueue.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT storageID, aiMethod, compressionRatio, confidence, contentType,
                       generatedAt, id, originalLength, processingTime,
                       recordingStorageID, recordingId, reminders, summary, tasks,
                       titles, transcriptStorageID, transcriptId, version, wordCount
                FROM summaries
                """
            )
            return try rows
                .map(SQLiteLibraryRepositoryMapper.summary(from:))
                .sorted { $0.storageID < $1.storageID }
        }
    }

    func fetchProcessingJobSnapshots() throws -> [LibraryProcessingJobSnapshot] {
        try databaseQueue.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT storageID, completionTime, engine, error, id, jobType,
                       lastModified, modelName, progress, recordingName,
                       recordingURL, recordingStorageID, startTime, status
                FROM processing_jobs
                """
            )
            return try rows
                .map(SQLiteLibraryRepositoryMapper.processingJob(from:))
                .sorted { $0.storageID < $1.storageID }
        }
    }

    func fetchArchiveLocationSnapshots() throws -> [LibraryArchiveLocationSnapshot] {
        try databaseQueue.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT storageID, bookmarkData, destinationURLString, displayName,
                       exportedAt, exportedFilename, fileSize, id, lastVerifiedAt,
                       providerDisplayName, recordingId, status
                FROM archive_locations
                """
            )
            return try rows
                .map(SQLiteLibraryRepositoryMapper.archiveLocation(from:))
                .sorted { $0.storageID < $1.storageID }
        }
    }

    func fetchPendingCloudMutationSnapshots() throws -> [LibraryPendingCloudMutationSnapshot] {
        try databaseQueue.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT storageID, kind, payload, recordingId, requestedAt,
                       targetId, version
                FROM pending_cloud_mutations
                """
            )
            return try rows
                .map(SQLiteLibraryRepositoryMapper.pendingCloudMutation(from:))
                .sorted { $0.storageID < $1.storageID }
        }
    }
}
