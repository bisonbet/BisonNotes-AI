import Foundation
import GRDB

private struct SQLiteRecordingDeletionPayload: Codable {
    let transcriptIds: [String]
    let summaryIds: [String]
}

/// Read-only repository adapter for the app-owned SQLite generation.
///
/// This adapter is intentionally not connected to production app startup yet.
/// It provides the storage-neutral boundary and contract-test target needed
/// before any caller is moved away from Core Data.
struct SQLiteLibraryRepository: LibraryRepository, LibraryObservation, Sendable {
    let store: SQLiteLibraryStore
    let maintenanceGate: LibraryMaintenanceGate

    init(
        store: SQLiteLibraryStore,
        maintenanceGate: LibraryMaintenanceGate = LibraryMaintenanceGate()
    ) {
        self.store = store
        self.maintenanceGate = maintenanceGate
    }

    func currentRevision() async throws -> Int64 {
        try await store.currentLibraryRevision()
    }

    func changes(since revision: Int64) async throws -> [LibraryChange] {
        try await store.libraryChanges(since: revision)
    }

    func fetchRecordingSummaries() async throws -> [LibraryRecordingSnapshot] {
        try await withNormalAccess { [store] in
            try await store.fetchRecordingSummaries()
        }
    }

    func fetchTranscriptSnapshots() async throws -> [LibraryTranscriptSnapshot] {
        try await withNormalAccess { [store] in
            try await store.fetchTranscriptSnapshots()
        }
    }

    func fetchSummarySnapshots() async throws -> [LibrarySummarySnapshot] {
        try await withNormalAccess { [store] in
            try await store.fetchSummarySnapshots()
        }
    }

    func fetchProcessingJobSnapshots() async throws -> [LibraryProcessingJobSnapshot] {
        try await withNormalAccess { [store] in
            try await store.fetchProcessingJobSnapshots()
        }
    }

    func fetchArchiveLocationSnapshots() async throws -> [LibraryArchiveLocationSnapshot] {
        try await withNormalAccess { [store] in
            try await store.fetchArchiveLocationSnapshots()
        }
    }

    func fetchPendingCloudMutationSnapshots() async throws -> [LibraryPendingCloudMutationSnapshot] {
        try await withNormalAccess { [store] in
            try await store.fetchPendingCloudMutationSnapshots()
        }
    }

    func createRecording(
        _ command: LibraryRecordingCreateCommand
    ) async throws -> LibraryRecordingSnapshot {
        try await withNormalAccess { [store] in
            try await store.createRecording(command)
        }
    }

    func discardRecording(
        _ command: LibraryRecordingDiscardCommand
    ) async throws {
        try await withNormalAccess { [store] in
            try await store.discardRecording(command)
        }
    }

    func deleteRecording(
        _ command: LibraryRecordingDeleteCommand
    ) async throws {
        try await withNormalAccess { [store] in
            try await store.deleteRecording(command)
        }
    }

    func deleteRecordingPreservingSummary(
        _ command: LibraryRecordingPreserveSummaryDeleteCommand
    ) async throws {
        try await withNormalAccess { [store] in
            try await store.deleteRecordingPreservingSummary(command)
        }
    }

    @discardableResult
    func deleteTranscript(
        _ command: LibraryTranscriptDeleteCommand
    ) async throws -> Bool {
        try await withNormalAccess { [store] in
            try await store.deleteTranscript(command)
        }
    }

    @discardableResult
    func deleteSummary(
        _ command: LibrarySummaryDeleteCommand
    ) async throws -> Bool {
        try await withNormalAccess { [store] in
            try await store.deleteSummary(command)
        }
    }

    @discardableResult
    func removeImportedAudio(
        _ command: LibraryImportedAudioRemovalCommand
    ) async throws -> Bool {
        try await withNormalAccess { [store] in
            try await store.removeImportedAudio(command)
        }
    }

    func renameRecording(
        _ command: LibraryRecordingRenameCommand
    ) async throws -> LibraryRecordingSnapshot {
        try await withNormalAccess { [store] in
            try await store.renameRecording(command)
        }
    }

    func setCloudSyncDisabled(
        _ command: LibraryRecordingCloudSyncCommand
    ) async throws -> LibraryRecordingSnapshot {
        try await withNormalAccess { [store] in
            try await store.setCloudSyncDisabled(command)
        }
    }

    func setArchiveState(
        _ command: LibraryRecordingArchiveCommand
    ) async throws -> LibraryRecordingSnapshot {
        try await withNormalAccess { [store] in
            try await store.setArchiveState(command)
        }
    }

    func upsertArchiveLocation(
        _ command: LibraryArchiveLocationUpsertCommand
    ) async throws -> LibraryArchiveLocationSnapshot {
        try await withNormalAccess { [store] in
            try await store.upsertArchiveLocation(command)
        }
    }

    func upsertTranscript(
        _ command: LibraryTranscriptUpsertCommand
    ) async throws -> LibraryTranscriptSnapshot {
        try await withNormalAccess { [store] in
            try await store.upsertTranscript(command)
        }
    }

    func upsertSummary(
        _ command: LibrarySummaryUpsertCommand
    ) async throws -> LibrarySummarySnapshot {
        try await withNormalAccess { [store] in
            try await store.upsertSummary(command)
        }
    }

    func createProcessingJob(
        _ command: LibraryProcessingJobCreateCommand
    ) async throws -> LibraryProcessingJobSnapshot {
        try await withNormalAccess { [store] in
            try await store.createProcessingJob(command)
        }
    }

    func updateProcessingJob(
        _ command: LibraryProcessingJobUpdateCommand
    ) async throws -> LibraryProcessingJobSnapshot {
        try await withNormalAccess { [store] in
            try await store.updateProcessingJob(command)
        }
    }

    func deleteProcessingJob(
        _ command: LibraryProcessingJobDeleteCommand
    ) async throws -> LibraryProcessingJobSnapshot {
        try await withNormalAccess { [store] in
            try await store.deleteProcessingJob(command)
        }
    }

    func deleteTerminalProcessingJobs(
        _ command: LibraryProcessingJobTerminalCleanupCommand
    ) async throws -> [LibraryProcessingJobSnapshot] {
        try await withNormalAccess { [store] in
            try await store.deleteTerminalProcessingJobs(command)
        }
    }

    func recoverProcessingJobsAfterCrash(
        _ command: LibraryProcessingJobCrashRecoveryCommand
    ) async throws -> [LibraryProcessingJobSnapshot] {
        try await withNormalAccess { [store] in
            try await store.recoverProcessingJobsAfterCrash(command)
        }
    }

    private func withNormalAccess<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await maintenanceGate.withNormalAccess(operation)
    }
}

extension SQLiteLibraryStore {
    private static let localOnlyRemovalKind = "localOnlyRemoval"
    private static let recordingDeletionKind = "recordingDeletion"
    private static let summaryRemovalKind = "summaryRemoval"
    private static let transcriptRemovalKind = "transcriptRemoval"
    private static let importedAudioRemovalKind = "importedAudioRemoval"
    private static let pendingMutationPayloadVersion: Int64 = 1

    func createRecording(
        _ command: LibraryRecordingCreateCommand
    ) throws -> LibraryRecordingSnapshot {
        try command.validate()
        let storageID = Self.recordingStorageID(for: command.id)

        return try databaseQueue.write { database in
            let duplicateCount = try Int.fetchOne(
                database,
                sql: """
                SELECT COUNT(*)
                FROM recordings
                WHERE storageID = ? OR lower(id) = lower(?)
                """,
                arguments: [storageID, command.id.uuidString.lowercased()]
            ) ?? 0
            guard duplicateCount == 0 else {
                throw LibraryRepositoryError.recordingAlreadyExists(
                    reference: command.id.uuidString.lowercased()
                )
            }

            try database.execute(
                sql: """
                INSERT INTO recordings (
                    storageID, audioQuality, createdAt, duration, fileSize, id,
                    isCloudSyncDisabled, lastModified, locationAccuracy,
                    locationAddress, locationLatitude, locationLongitude,
                    locationTimestamp, recordingDate, recordingName, recordingURL,
                    summaryId, summaryStatus, transcriptId, transcriptionStatus,
                    isArchived, archivedAt, archiveNote
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    storageID,
                    command.audioQuality,
                    command.createdAt.timeIntervalSinceReferenceDate,
                    command.duration,
                    command.fileSize,
                    command.id.uuidString.lowercased(),
                    command.isCloudSyncDisabled ? 1 : 0,
                    command.modifiedAt.timeIntervalSinceReferenceDate,
                    command.locationAccuracy,
                    command.locationAddress,
                    command.locationLatitude,
                    command.locationLongitude,
                    command.locationTimestamp?.timeIntervalSinceReferenceDate,
                    command.recordingDate.timeIntervalSinceReferenceDate,
                    command.name,
                    command.recordingURL,
                    nil,
                    command.summaryStatus,
                    nil,
                    command.transcriptionStatus,
                    0,
                    nil,
                    nil
                ]
            )
            guard database.changesCount == 1 else {
                throw LibraryRepositoryError.writeFailed(
                    operation: "create recording",
                    reason: "the recording row was not inserted"
                )
            }

            _ = try SQLiteLibraryStore.recordChange(
                in: database,
                entity: .recording,
                storageID: storageID,
                operation: .inserted,
                at: command.modifiedAt
            )
            return try Self.fetchUpdatedRecording(
                storageID: storageID,
                in: database,
                operation: "create recording"
            )
        }
    }

    func discardRecording(
        _ command: LibraryRecordingDiscardCommand
    ) throws {
        try command.validate()
        let reference = try Self.normalizedReference(command.reference)

        try databaseQueue.write { database in
            let rows = try Self.fetchRecordingRows(for: reference, in: database)
            let current = try Self.validateRecordingTarget(
                rows: rows,
                reference: reference,
                expectedLastModified: command.expectedLastModified
            )
            guard let legacyID = current.legacyID, !legacyID.isEmpty else {
                throw LibraryRepositoryError.invalidRecord(
                    entity: "recordings",
                    field: "id"
                )
            }

            let dependentCounts = [
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM transcripts WHERE recordingStorageID = ? OR lower(recordingId) = lower(?)",
                    arguments: [current.storageID, legacyID]
                ) ?? 0,
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM summaries WHERE recordingStorageID = ? OR lower(recordingId) = lower(?)",
                    arguments: [current.storageID, legacyID]
                ) ?? 0,
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM processing_jobs WHERE recordingStorageID = ?",
                    arguments: [current.storageID]
                ) ?? 0,
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM archive_locations WHERE lower(recordingId) = lower(?)",
                    arguments: [legacyID]
                ) ?? 0,
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM pending_cloud_mutations WHERE lower(recordingId) = lower(?) OR lower(targetId) = lower(?)",
                    arguments: [legacyID, legacyID]
                ) ?? 0
            ]
            guard dependentCounts.allSatisfy({ $0 == 0 }) else {
                throw LibraryRepositoryError.recordingHasDependents(
                    reference: reference.displayValue
                )
            }

            try database.execute(
                sql: "DELETE FROM recordings WHERE storageID = ?",
                arguments: [current.storageID]
            )
            guard database.changesCount == 1 else {
                throw LibraryRepositoryError.writeFailed(
                    operation: "discard recording",
                    reason: "the recording row was not deleted"
                )
            }
            _ = try SQLiteLibraryStore.recordChange(
                in: database,
                entity: .recording,
                storageID: current.storageID,
                operation: .deleted,
                at: command.discardedAt
            )
        }
    }

    func deleteRecording(
        _ command: LibraryRecordingDeleteCommand
    ) throws {
        try command.validate()
        let reference = try Self.normalizedReference(command.reference)
        let requestedAt = command.requestedAt.timeIntervalSinceReferenceDate

        try databaseQueue.write { database in
            let rows = try Self.fetchRecordingRows(for: reference, in: database)
            let current = try Self.validateRecordingTarget(
                rows: rows,
                reference: reference,
                expectedLastModified: command.expectedLastModified
            )
            guard let legacyID = current.legacyID,
                  !legacyID.isEmpty else {
                throw LibraryRepositoryError.invalidRecord(
                    entity: "recordings",
                    field: "id"
                )
            }

            let transcriptRows = try Row.fetchAll(
                database,
                sql: """
                SELECT storageID, id
                FROM transcripts
                WHERE recordingStorageID = ? OR lower(recordingId) = lower(?)
                ORDER BY storageID
                """,
                arguments: [current.storageID, legacyID]
            )
            let summaryRows = try Row.fetchAll(
                database,
                sql: """
                SELECT storageID, id
                FROM summaries
                WHERE recordingStorageID = ? OR lower(recordingId) = lower(?)
                ORDER BY storageID
                """,
                arguments: [current.storageID, legacyID]
            )
            let processingJobRows = try Row.fetchAll(
                database,
                sql: """
                SELECT storageID
                FROM processing_jobs
                WHERE recordingStorageID = ?
                ORDER BY storageID
                """,
                arguments: [current.storageID]
            )

            let transcriptIDs = try transcriptRows.map {
                try Self.requiredLegacyID(from: $0, entity: "transcripts")
            }
            let summaryIDs = try summaryRows.map {
                try Self.requiredLegacyID(from: $0, entity: "summaries")
            }
            let transcriptStorageIDs = try transcriptRows.map {
                try Self.requiredStorageID(from: $0, entity: "transcripts")
            }
            let summaryStorageIDs = try summaryRows.map {
                try Self.requiredStorageID(from: $0, entity: "summaries")
            }

            if command.enqueueCloudDeletion {
                try Self.removePendingMutations(
                    kind: Self.importedAudioRemovalKind,
                    targetID: legacyID,
                    in: database,
                    committedAt: command.requestedAt
                )
                try Self.enqueueRecordingDeletionMutation(
                    recordingStorageID: current.storageID,
                    recordingID: legacyID,
                    transcriptIDs: transcriptIDs,
                    summaryIDs: summaryIDs,
                    requestedAt: requestedAt,
                    in: database,
                    committedAt: command.requestedAt
                )
                for (summaryRow, summaryID) in zip(summaryRows, summaryIDs) {
                    try Self.enqueueSummaryRemovalMutation(
                        summaryStorageID: try Self.requiredStorageID(
                            from: summaryRow,
                            entity: "summaries"
                        ),
                        summaryID: summaryID,
                        recordingID: legacyID,
                        requestedAt: requestedAt,
                        in: database,
                        committedAt: command.requestedAt
                    )
                }
            }

            // Core Data's transcript relationship is nullifying. Apply that
            // behavior explicitly before SQLite's restrictive foreign key can
            // reject the parent delete if a retained summary references one of
            // these transcript rows.
            try Self.clearRetainedTranscriptReferences(
                transcriptStorageIDs: Set(transcriptStorageIDs),
                transcriptIDs: Set(transcriptIDs.map(Self.normalizedID)),
                deletedSummaryStorageIDs: Set(summaryStorageIDs),
                in: database,
                committedAt: command.requestedAt
            )

            for storageID in summaryStorageIDs {
                try Self.deleteRow(
                    table: "summaries",
                    storageID: storageID,
                    entity: .summary,
                    operation: "delete recording",
                    at: command.requestedAt,
                    in: database
                )
            }
            for storageID in transcriptStorageIDs {
                try Self.deleteRow(
                    table: "transcripts",
                    storageID: storageID,
                    entity: .transcript,
                    operation: "delete recording",
                    at: command.requestedAt,
                    in: database
                )
            }
            for row in processingJobRows {
                let storageID = try Self.requiredStorageID(
                    from: row,
                    entity: "processing_jobs"
                )
                try Self.deleteRow(
                    table: "processing_jobs",
                    storageID: storageID,
                    entity: .processingJob,
                    operation: "delete recording",
                    at: command.requestedAt,
                    in: database
                )
            }

            try database.execute(
                sql: "DELETE FROM recordings WHERE storageID = ?",
                arguments: [current.storageID]
            )
            guard database.changesCount == 1 else {
                throw LibraryRepositoryError.writeFailed(
                    operation: "delete recording",
                    reason: "the recording row was not deleted"
                )
            }
            _ = try SQLiteLibraryStore.recordChange(
                in: database,
                entity: .recording,
                storageID: current.storageID,
                operation: .deleted,
                at: command.requestedAt
            )

        }
    }

    func deleteRecordingPreservingSummary(
        _ command: LibraryRecordingPreserveSummaryDeleteCommand
    ) throws {
        try command.validate()
        let reference = try Self.normalizedReference(command.reference)
        let requestedAt = command.requestedAt.timeIntervalSinceReferenceDate

        try databaseQueue.write { database in
            let rows = try Self.fetchRecordingRows(for: reference, in: database)
            let current = try Self.validateRecordingTarget(
                rows: rows,
                reference: reference,
                expectedLastModified: command.expectedLastModified
            )
            guard let legacyID = current.legacyID,
                  !legacyID.isEmpty else {
                throw LibraryRepositoryError.invalidRecord(
                    entity: "recordings",
                    field: "id"
                )
            }

            let recordingRow = rows[0]
            var transcriptIDs = Set(command.transcriptIds.map {
                $0.uuidString.lowercased()
            })
            if let transcriptID: String = recordingRow["transcriptId"] {
                let normalizedTranscriptID = Self.normalizedID(transcriptID)
                guard !normalizedTranscriptID.isEmpty else {
                    throw LibraryRepositoryError.invalidRecord(
                        entity: "recordings",
                        field: "transcriptId"
                    )
                }
                transcriptIDs.insert(normalizedTranscriptID)
            }

            let summaryRows = try Row.fetchAll(
                database,
                sql: """
                SELECT storageID, id, transcriptStorageID, transcriptId
                FROM summaries
                WHERE recordingStorageID = ? OR lower(recordingId) = lower(?)
                ORDER BY storageID
                """,
                arguments: [current.storageID, legacyID]
            )
            guard !summaryRows.isEmpty else {
                throw LibraryRepositoryError.recordingSummaryNotFound(
                    reference: reference.displayValue
                )
            }

            for row in summaryRows {
                _ = try Self.requiredStorageID(from: row, entity: "summaries")
                _ = try Self.requiredLegacyID(from: row, entity: "summaries")
                if let transcriptID: String = row["transcriptId"] {
                    let normalizedTranscriptID = Self.normalizedID(transcriptID)
                    guard !normalizedTranscriptID.isEmpty else {
                        throw LibraryRepositoryError.invalidRecord(
                            entity: "summaries",
                            field: "transcriptId"
                        )
                    }
                    transcriptIDs.insert(normalizedTranscriptID)
                }
            }

            var transcriptRows = try Row.fetchAll(
                database,
                sql: """
                SELECT storageID, id, recordingStorageID, recordingId
                FROM transcripts
                WHERE recordingStorageID = ? OR lower(recordingId) = lower(?)
                ORDER BY storageID
                """,
                arguments: [current.storageID, legacyID]
            )
            for row in transcriptRows {
                _ = try Self.requiredStorageID(from: row, entity: "transcripts")
                let transcriptID = try Self.requiredLegacyID(from: row, entity: "transcripts")
                transcriptIDs.insert(Self.normalizedID(transcriptID))
            }

            let transcriptStorageIDs = Set(summaryRows.compactMap { row -> String? in
                let transcriptStorageID: String? = row["transcriptStorageID"]
                guard let transcriptStorageID, !transcriptStorageID.isEmpty else {
                    return nil
                }
                return transcriptStorageID
            })
            if !transcriptStorageIDs.isEmpty {
                let placeholders = Array(repeating: "?", count: transcriptStorageIDs.count)
                    .joined(separator: ", ")
                let storageLinkedRows = try Row.fetchAll(
                    database,
                    sql: """
                    SELECT storageID, id, recordingStorageID, recordingId
                    FROM transcripts
                    WHERE storageID IN (\(placeholders))
                    ORDER BY storageID
                    """,
                    arguments: StatementArguments(
                        transcriptStorageIDs.sorted().map(\.databaseValue)
                    )
                )
                let knownStorageIDs = Set(
                    transcriptRows.compactMap { row -> String? in
                        row["storageID"]
                    }
                )
                for row in storageLinkedRows {
                    let storageID = try Self.requiredStorageID(
                        from: row,
                        entity: "transcripts"
                    )
                    let transcriptID = try Self.requiredLegacyID(
                        from: row,
                        entity: "transcripts"
                    )
                    let rowRecordingStorageID: String? = row["recordingStorageID"]
                    let rowRecordingID: String? = row["recordingId"]
                    let storageMatches = rowRecordingStorageID == nil
                        || rowRecordingStorageID == current.storageID
                    let legacyMatches = rowRecordingID == nil
                        || Self.normalizedID(rowRecordingID ?? "") == Self.normalizedID(legacyID)
                    guard storageMatches || legacyMatches else {
                        throw LibraryRepositoryError.invalidCommand(
                            "transcript \(Self.normalizedID(transcriptID)) belongs to another recording"
                        )
                    }
                    transcriptIDs.insert(Self.normalizedID(transcriptID))
                    if !knownStorageIDs.contains(storageID) {
                        transcriptRows.append(row)
                    }
                }
            }

            for transcriptID in command.transcriptIds {
                let normalizedTranscriptID = transcriptID.uuidString.lowercased()
                let explicitRows = try Row.fetchAll(
                    database,
                    sql: """
                    SELECT storageID, id, recordingStorageID, recordingId
                    FROM transcripts
                    WHERE lower(id) = lower(?)
                    ORDER BY storageID
                    """,
                    arguments: [normalizedTranscriptID]
                )
                guard explicitRows.count <= 1 else {
                    throw LibraryRepositoryError.ambiguousTranscript(
                        reference: normalizedTranscriptID
                    )
                }
                for row in explicitRows {
                    _ = try Self.requiredStorageID(from: row, entity: "transcripts")
                    let rowRecordingStorageID: String? = row["recordingStorageID"]
                    let rowRecordingID: String? = row["recordingId"]
                    let storageMatches = rowRecordingStorageID == nil
                        || rowRecordingStorageID == current.storageID
                    let legacyMatches = rowRecordingID == nil
                        || Self.normalizedID(rowRecordingID ?? "") == Self.normalizedID(legacyID)
                    guard storageMatches || legacyMatches else {
                        throw LibraryRepositoryError.invalidCommand(
                            "transcript \(normalizedTranscriptID) belongs to another recording"
                        )
                    }
                    transcriptRows.append(row)
                }
                transcriptIDs.insert(normalizedTranscriptID)
            }

            if command.enqueueCloudDeletion {
                for transcriptID in transcriptIDs.sorted() {
                    try Self.enqueueTranscriptRemovalMutation(
                        transcriptID: transcriptID,
                        recordingID: legacyID,
                        requestedAt: requestedAt,
                        in: database,
                        committedAt: command.requestedAt
                    )
                }
                try Self.enqueueImportedAudioRemovalMutation(
                    recordingStorageID: current.storageID,
                    recordingID: legacyID,
                    requestedAt: requestedAt,
                    in: database,
                    committedAt: command.requestedAt
                )
            }

            for row in summaryRows {
                let summaryStorageID = try Self.requiredStorageID(from: row, entity: "summaries")
                try database.execute(
                    sql: """
                    UPDATE summaries
                    SET transcriptStorageID = ?, transcriptId = ?
                    WHERE storageID = ?
                    """,
                    arguments: [nil, nil, summaryStorageID]
                )
                guard database.changesCount == 1 else {
                    throw LibraryRepositoryError.writeFailed(
                        operation: "delete recording preserving summary",
                        reason: "a retained summary transcript link was not cleared"
                    )
                }
                _ = try SQLiteLibraryStore.recordChange(
                    in: database,
                    entity: .summary,
                    storageID: summaryStorageID,
                    operation: .updated,
                    at: command.requestedAt
                )
            }

            try database.execute(
                sql: """
                UPDATE recordings
                SET recordingURL = ?, transcriptId = ?, transcriptionStatus = ?, lastModified = ?
                WHERE storageID = ?
                """,
                arguments: [nil, nil, "Not Started", requestedAt, current.storageID]
            )
            guard database.changesCount == 1 else {
                throw LibraryRepositoryError.writeFailed(
                    operation: "delete recording preserving summary",
                    reason: "the recording row was not updated"
                )
            }
            _ = try SQLiteLibraryStore.recordChange(
                in: database,
                entity: .recording,
                storageID: current.storageID,
                operation: .updated,
                at: command.requestedAt
            )

            var deletedStorageIDs = Set<String>()
            for row in transcriptRows {
                let storageID = try Self.requiredStorageID(from: row, entity: "transcripts")
                guard deletedStorageIDs.insert(storageID).inserted else { continue }
                try Self.deleteRow(
                    table: "transcripts",
                    storageID: storageID,
                    entity: .transcript,
                    operation: "delete recording preserving summary",
                    at: command.requestedAt,
                    in: database
                )
            }
        }
    }

    @discardableResult
    func deleteTranscript(
        _ command: LibraryTranscriptDeleteCommand
    ) throws -> Bool {
        try command.validate()
        let requestedAt = command.requestedAt.timeIntervalSinceReferenceDate
        let requestedID = command.id.uuidString.lowercased()
        let stableStorageID = Self.transcriptStorageID(for: command.id)

        return try databaseQueue.write { database in
            let transcriptRows = try Row.fetchAll(
                database,
                sql: """
                SELECT storageID, id, recordingStorageID, recordingId
                FROM transcripts
                WHERE storageID = ? OR lower(id) = lower(?)
                ORDER BY storageID
                LIMIT 2
                """,
                arguments: [stableStorageID, requestedID]
            )
            guard !transcriptRows.isEmpty else {
                return false
            }
            guard transcriptRows.count == 1 else {
                throw LibraryRepositoryError.ambiguousTranscript(
                    reference: requestedID
                )
            }

            let transcriptRow = transcriptRows[0]
            let transcriptStorageID = try Self.requiredStorageID(
                from: transcriptRow,
                entity: "transcripts"
            )
            let transcriptLegacyID = try Self.requiredLegacyID(
                from: transcriptRow,
                entity: "transcripts"
            )
            let normalizedTranscriptID = Self.normalizedID(transcriptLegacyID)
            guard normalizedTranscriptID == requestedID else {
                throw LibraryRepositoryError.invalidRecord(
                    entity: "transcripts",
                    field: "id"
                )
            }

            let transcriptRecordingStorageID: String? = transcriptRow["recordingStorageID"]
            let transcriptRecordingID: String? = transcriptRow["recordingId"]
            let recordingRows = try Row.fetchAll(
                database,
                sql: """
                SELECT storageID, id
                FROM recordings
                WHERE lower(transcriptId) = lower(?)
                   OR (? IS NOT NULL AND storageID = ?)
                   OR (? IS NOT NULL AND lower(id) = lower(?))
                ORDER BY storageID
                """,
                arguments: [
                    normalizedTranscriptID,
                    transcriptRecordingStorageID,
                    transcriptRecordingStorageID,
                    transcriptRecordingID,
                    transcriptRecordingID
                ]
            )
            let resolvedRecordingID: String? = {
                if let recordingID = transcriptRecordingID?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ), !recordingID.isEmpty {
                    return recordingID
                }
                return recordingRows.compactMap { row -> String? in
                    guard let id: String = row["id"] else { return nil }
                    let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmedID.isEmpty ? nil : trimmedID
                }.first
            }()

            if command.enqueueCloudDeletion {
                try Self.enqueueTranscriptRemovalMutation(
                    transcriptID: normalizedTranscriptID,
                    recordingID: resolvedRecordingID,
                    requestedAt: requestedAt,
                    in: database,
                    committedAt: command.requestedAt
                )
            }

            for row in recordingRows {
                let recordingStorageID = try Self.requiredStorageID(
                    from: row,
                    entity: "recordings"
                )
                try database.execute(
                    sql: """
                    UPDATE recordings
                    SET transcriptId = ?, transcriptionStatus = ?, lastModified = ?
                    WHERE storageID = ?
                    """,
                    arguments: [nil, "Not Started", requestedAt, recordingStorageID]
                )
                guard database.changesCount == 1 else {
                    throw LibraryRepositoryError.writeFailed(
                        operation: "delete transcript",
                        reason: "a recording transcript link was not cleared"
                    )
                }
                _ = try SQLiteLibraryStore.recordChange(
                    in: database,
                    entity: .recording,
                    storageID: recordingStorageID,
                    operation: .updated,
                    at: command.requestedAt
                )
            }

            let summaryRows = try Row.fetchAll(
                database,
                sql: """
                SELECT storageID
                FROM summaries
                WHERE transcriptStorageID = ? OR lower(transcriptId) = lower(?)
                ORDER BY storageID
                """,
                arguments: [transcriptStorageID, normalizedTranscriptID]
            )
            for row in summaryRows {
                let summaryStorageID = try Self.requiredStorageID(
                    from: row,
                    entity: "summaries"
                )
                try database.execute(
                    sql: """
                    UPDATE summaries
                    SET transcriptStorageID = ?, transcriptId = ?
                    WHERE storageID = ?
                    """,
                    arguments: [nil, nil, summaryStorageID]
                )
                guard database.changesCount == 1 else {
                    throw LibraryRepositoryError.writeFailed(
                        operation: "delete transcript",
                        reason: "a summary transcript link was not cleared"
                    )
                }
                _ = try SQLiteLibraryStore.recordChange(
                    in: database,
                    entity: .summary,
                    storageID: summaryStorageID,
                    operation: .updated,
                    at: command.requestedAt
                )
            }

            try Self.deleteRow(
                table: "transcripts",
                storageID: transcriptStorageID,
                entity: .transcript,
                operation: "delete transcript",
                at: command.requestedAt,
                in: database
            )
            return true
        }
    }

    @discardableResult
    func removeImportedAudio(
        _ command: LibraryImportedAudioRemovalCommand
    ) throws -> Bool {
        try command.validate()
        let requestedAt = command.requestedAt.timeIntervalSinceReferenceDate
        let reference = LibraryRecordingReference(
            legacyID: command.id.uuidString.lowercased()
        )

        return try databaseQueue.write { database in
            let rows = try Self.fetchRecordingRows(for: reference, in: database)
            guard !rows.isEmpty else {
                return false
            }
            guard rows.count == 1 else {
                throw LibraryRepositoryError.ambiguousRecording(
                    reference: reference.displayValue
                )
            }

            let current = try Self.validateRecordingTarget(
                rows: rows,
                reference: reference,
                expectedLastModified: nil
            )
            guard current.recordingURL != nil else {
                return false
            }
            guard let legacyID = current.legacyID, !legacyID.isEmpty else {
                throw LibraryRepositoryError.invalidRecord(
                    entity: "recordings",
                    field: "id"
                )
            }

            if command.enqueueCloudDeletion {
                try Self.enqueueImportedAudioRemovalMutation(
                    recordingStorageID: current.storageID,
                    recordingID: legacyID,
                    requestedAt: requestedAt,
                    in: database,
                    committedAt: command.requestedAt
                )
            }

            let updatedAt: Date
            if let existingLastModified = current.lastModified,
               existingLastModified > command.requestedAt {
                updatedAt = existingLastModified
            } else {
                updatedAt = command.requestedAt
            }
            try database.execute(
                sql: "UPDATE recordings SET recordingURL = ?, lastModified = ? WHERE storageID = ?",
                arguments: [nil, updatedAt.timeIntervalSinceReferenceDate, current.storageID]
            )
            guard database.changesCount == 1 else {
                throw LibraryRepositoryError.writeFailed(
                    operation: "remove imported audio",
                    reason: "the recording row was not updated"
                )
            }
            _ = try SQLiteLibraryStore.recordChange(
                in: database,
                entity: .recording,
                storageID: current.storageID,
                operation: .updated,
                at: command.requestedAt
            )
            return true
        }
    }

    @discardableResult
    func deleteSummary(
        _ command: LibrarySummaryDeleteCommand
    ) throws -> Bool {
        try command.validate()
        let requestedAt = command.requestedAt.timeIntervalSinceReferenceDate
        let requestedID = command.id.uuidString.lowercased()
        let stableStorageID = Self.summaryStorageID(for: command.id)

        return try databaseQueue.write { database in
            let summaryRows = try Row.fetchAll(
                database,
                sql: """
                SELECT storageID, id, recordingStorageID, recordingId
                FROM summaries
                WHERE storageID = ? OR lower(id) = lower(?)
                ORDER BY storageID
                LIMIT 2
                """,
                arguments: [stableStorageID, requestedID]
            )
            guard !summaryRows.isEmpty else {
                return false
            }
            guard summaryRows.count == 1 else {
                throw LibraryRepositoryError.ambiguousSummary(
                    reference: requestedID
                )
            }

            let summaryRow = summaryRows[0]
            let summaryStorageID = try Self.requiredStorageID(
                from: summaryRow,
                entity: "summaries"
            )
            let summaryLegacyID = try Self.requiredLegacyID(
                from: summaryRow,
                entity: "summaries"
            )
            let normalizedSummaryID = Self.normalizedID(summaryLegacyID)
            guard normalizedSummaryID == requestedID else {
                throw LibraryRepositoryError.invalidRecord(
                    entity: "summaries",
                    field: "id"
                )
            }

            let summaryRecordingStorageID: String? = summaryRow["recordingStorageID"]
            let summaryRecordingID: String? = summaryRow["recordingId"]
            let recordingRows = try Row.fetchAll(
                database,
                sql: """
                SELECT storageID, id
                FROM recordings
                WHERE lower(summaryId) = lower(?)
                   OR (? IS NOT NULL AND storageID = ?)
                   OR (? IS NOT NULL AND lower(id) = lower(?))
                ORDER BY storageID
                """,
                arguments: [
                    normalizedSummaryID,
                    summaryRecordingStorageID,
                    summaryRecordingStorageID,
                    summaryRecordingID,
                    summaryRecordingID
                ]
            )
            let resolvedRecordingID: String? = {
                if let recordingID = summaryRecordingID?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ), !recordingID.isEmpty {
                    return Self.normalizedID(recordingID)
                }
                return recordingRows.compactMap { row -> String? in
                    guard let id: String = row["id"] else { return nil }
                    let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmedID.isEmpty ? nil : Self.normalizedID(trimmedID)
                }.first
            }()

            if command.enqueueCloudDeletion {
                try Self.enqueueSummaryRemovalMutation(
                    summaryStorageID: summaryStorageID,
                    summaryID: normalizedSummaryID,
                    recordingID: resolvedRecordingID,
                    requestedAt: requestedAt,
                    in: database,
                    committedAt: command.requestedAt
                )
            }

            for row in recordingRows {
                let recordingStorageID = try Self.requiredStorageID(
                    from: row,
                    entity: "recordings"
                )
                try database.execute(
                    sql: """
                    UPDATE recordings
                    SET summaryId = ?, summaryStatus = ?, lastModified = ?
                    WHERE storageID = ?
                    """,
                    arguments: [nil, "Not Started", requestedAt, recordingStorageID]
                )
                guard database.changesCount == 1 else {
                    throw LibraryRepositoryError.writeFailed(
                        operation: "delete summary",
                        reason: "a recording summary link was not cleared"
                    )
                }
                _ = try SQLiteLibraryStore.recordChange(
                    in: database,
                    entity: .recording,
                    storageID: recordingStorageID,
                    operation: .updated,
                    at: command.requestedAt
                )
            }

            try Self.deleteRow(
                table: "summaries",
                storageID: summaryStorageID,
                entity: .summary,
                operation: "delete summary",
                at: command.requestedAt,
                in: database
            )
            return true
        }
    }

    func renameRecording(
        _ command: LibraryRecordingRenameCommand
    ) throws -> LibraryRecordingSnapshot {
        let reference = try Self.normalizedReference(command.reference)
        return try databaseQueue.write { database in
            let rows = try Self.fetchRecordingRows(for: reference, in: database)
            let current = try Self.validateRecordingTarget(
                rows: rows,
                reference: reference,
                expectedLastModified: command.expectedLastModified
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

    func setCloudSyncDisabled(
        _ command: LibraryRecordingCloudSyncCommand
    ) throws -> LibraryRecordingSnapshot {
        let reference = try Self.normalizedReference(command.reference)
        let modifiedAt = command.modifiedAt.timeIntervalSinceReferenceDate
        let requestedAt = command.requestedAt.timeIntervalSinceReferenceDate
        guard modifiedAt.isFinite, requestedAt.isFinite else {
            throw LibraryRepositoryError.invalidCommand(
                "cloud sync dates must be finite"
            )
        }

        return try databaseQueue.write { database in
            let rows = try Self.fetchRecordingRows(for: reference, in: database)
            let current = try Self.validateRecordingTarget(
                rows: rows,
                reference: reference,
                expectedLastModified: command.expectedLastModified
            )
            guard let legacyID = current.legacyID, !legacyID.isEmpty else {
                throw LibraryRepositoryError.invalidRecord(
                    entity: "recordings",
                    field: "id"
                )
            }

            try database.execute(
                sql: """
                UPDATE recordings
                SET isCloudSyncDisabled = ?, lastModified = ?
                WHERE storageID = ?
                """,
                arguments: [
                    command.disabled ? 1 : 0,
                    modifiedAt,
                    current.storageID
                ]
            )
            guard database.changesCount == 1 else {
                throw LibraryRepositoryError.writeFailed(
                    operation: "set cloud sync preference",
                    reason: "the recording row was not updated"
                )
            }
            _ = try SQLiteLibraryStore.recordChange(
                in: database,
                entity: .recording,
                storageID: current.storageID,
                operation: .updated,
                at: command.modifiedAt
            )

            if command.disabled {
                try Self.upsertLocalOnlyMutation(
                    targetID: legacyID,
                    requestedAt: requestedAt,
                    recordingStorageID: current.storageID,
                    in: database,
                    committedAt: command.modifiedAt
                )
            } else {
                try Self.removeLocalOnlyMutations(
                    targetID: legacyID,
                    in: database,
                    committedAt: command.modifiedAt
                )
            }

            return try Self.fetchUpdatedRecording(storageID: current.storageID, in: database)
        }
    }

    func setArchiveState(
        _ command: LibraryRecordingArchiveCommand
    ) throws -> LibraryRecordingSnapshot {
        try command.validate()
        let reference = try Self.normalizedReference(command.reference)
        let modifiedAt = command.modifiedAt.timeIntervalSinceReferenceDate

        return try databaseQueue.write { database in
            let rows = try Self.fetchRecordingRows(for: reference, in: database)
            let current = try Self.validateRecordingTarget(
                rows: rows,
                reference: reference,
                expectedLastModified: command.expectedLastModified
            )

            try database.execute(
                sql: """
                UPDATE recordings
                SET isArchived = ?, archivedAt = ?, archiveNote = ?, lastModified = ?
                WHERE storageID = ?
                """,
                arguments: [
                    command.archived ? 1 : 0,
                    command.persistedArchivedAt?.timeIntervalSinceReferenceDate,
                    command.persistedArchiveNote,
                    modifiedAt,
                    current.storageID
                ]
            )
            guard database.changesCount == 1 else {
                throw LibraryRepositoryError.writeFailed(
                    operation: "set archive state",
                    reason: "the recording row was not updated"
                )
            }
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

    func upsertArchiveLocation(
        _ command: LibraryArchiveLocationUpsertCommand
    ) throws -> LibraryArchiveLocationSnapshot {
        try command.validate()
        let recordingReference = try Self.normalizedReference(
            command.recordingReference
        )
        let exportedAt = command.exportedAt?.timeIntervalSinceReferenceDate
        let lastVerifiedAt = command.lastVerifiedAt?.timeIntervalSinceReferenceDate
        let requestedID = command.id.uuidString.lowercased()
        let columns = """
            storageID, bookmarkData, destinationURLString, displayName,
            exportedAt, exportedFilename, fileSize, id, lastVerifiedAt,
            providerDisplayName, recordingId, status
            """

        return try databaseQueue.write { database in
            let recordingRows = try Self.fetchRecordingRows(
                for: recordingReference,
                in: database
            )
            let recording = try Self.validateRecordingTarget(
                rows: recordingRows,
                reference: recordingReference,
                expectedLastModified: nil
            )
            guard let recordingLegacyID = recording.legacyID,
                  !recordingLegacyID.isEmpty else {
                throw LibraryRepositoryError.invalidRecord(
                    entity: "recordings",
                    field: "id"
                )
            }

            let idMatches = try Row.fetchAll(
                database,
                sql: """
                SELECT \(columns)
                FROM archive_locations
                WHERE lower(id) = lower(?)
                LIMIT 2
                """,
                arguments: [requestedID]
            )
            guard idMatches.count <= 1 else {
                throw LibraryRepositoryError.ambiguousArchiveLocation(
                    reference: requestedID
                )
            }

            let destinationMatches: [Row]
            if let destinationURLString = command.destinationURLString {
                destinationMatches = try Row.fetchAll(
                    database,
                    sql: """
                    SELECT \(columns)
                    FROM archive_locations
                    WHERE lower(recordingId) = lower(?)
                      AND destinationURLString = ?
                    LIMIT 2
                    """,
                    arguments: [recordingLegacyID, destinationURLString]
                )
            } else {
                destinationMatches = []
            }
            guard destinationMatches.count <= 1 else {
                throw LibraryRepositoryError.ambiguousArchiveLocation(
                    reference: command.destinationURLString ?? requestedID
                )
            }

            let existing = idMatches.first ?? destinationMatches.first
            let storageID: String
            let persistedID: String
            let operation: LibraryChangeOperation
            if let existing {
                guard let existingStorageID: String = existing["storageID"],
                      !existingStorageID.isEmpty else {
                    throw LibraryRepositoryError.invalidRecord(
                        entity: "archive_locations",
                        field: "storageID"
                    )
                }
                let existingRecordingID: String? = existing["recordingId"]
                if let existingRecordingID,
                   existingRecordingID.lowercased() != recordingLegacyID.lowercased() {
                    throw LibraryRepositoryError.archiveLocationAlreadyExists(
                        reference: requestedID
                    )
                }
                if let destinationURLString = command.destinationURLString,
                   let competing = destinationMatches.first,
                   (competing["storageID"] as String?) != existingStorageID {
                    throw LibraryRepositoryError.archiveLocationAlreadyExists(
                        reference: destinationURLString
                    )
                }
                storageID = existingStorageID
                persistedID = (existing["id"] as String?) ?? requestedID
                operation = .updated

                try database.execute(
                    sql: """
                    UPDATE archive_locations
                    SET bookmarkData = ?, destinationURLString = ?, displayName = ?,
                        exportedAt = ?, exportedFilename = ?, fileSize = ?, id = ?,
                        lastVerifiedAt = ?, providerDisplayName = ?, recordingId = ?,
                        status = ?
                    WHERE storageID = ?
                    """,
                    arguments: [
                        command.bookmarkData,
                        command.destinationURLString,
                        command.displayName,
                        exportedAt,
                        command.exportedFilename,
                        command.fileSize,
                        persistedID,
                        lastVerifiedAt,
                        command.providerDisplayName,
                        recordingLegacyID,
                        command.status,
                        storageID
                    ]
                )
                guard database.changesCount == 1 else {
                    throw LibraryRepositoryError.writeFailed(
                        operation: "upsert archive location",
                        reason: "the archive-location row was not updated"
                    )
                }
            } else {
                storageID = Self.archiveLocationStorageID(for: command.id)
                persistedID = requestedID
                operation = .inserted
                guard try Row.fetchOne(
                    database,
                    sql: "SELECT 1 FROM archive_locations WHERE storageID = ?",
                    arguments: [storageID]
                ) == nil else {
                    throw LibraryRepositoryError.archiveLocationAlreadyExists(
                        reference: storageID
                    )
                }

                try database.execute(
                    sql: """
                    INSERT INTO archive_locations (
                        storageID, bookmarkData, destinationURLString, displayName,
                        exportedAt, exportedFilename, fileSize, id, lastVerifiedAt,
                        providerDisplayName, recordingId, status
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        storageID,
                        command.bookmarkData,
                        command.destinationURLString,
                        command.displayName,
                        exportedAt,
                        command.exportedFilename,
                        command.fileSize,
                        persistedID,
                        lastVerifiedAt,
                        command.providerDisplayName,
                        recordingLegacyID,
                        command.status
                    ]
                )
                guard database.changesCount == 1 else {
                    throw LibraryRepositoryError.writeFailed(
                        operation: "upsert archive location",
                        reason: "the archive-location row was not inserted"
                    )
                }
            }

            _ = try SQLiteLibraryStore.recordChange(
                in: database,
                entity: .archiveLocation,
                storageID: storageID,
                operation: operation,
                at: command.modifiedAt
            )
            return try Self.fetchUpdatedArchiveLocation(
                storageID: storageID,
                in: database
            )
        }
    }

    func upsertTranscript(
        _ command: LibraryTranscriptUpsertCommand
    ) throws -> LibraryTranscriptSnapshot {
        try command.validate()
        let recordingReference = try Self.normalizedReference(
            command.recordingReference
        )
        let createdAt = command.createdAt.timeIntervalSinceReferenceDate
        let modifiedAt = command.modifiedAt.timeIntervalSinceReferenceDate
        let requestedLegacyID = command.id.uuidString.lowercased()

        return try databaseQueue.write { database in
            let recordingRows = try Self.fetchRecordingRows(
                for: recordingReference,
                in: database
            )
            let recording = try Self.validateRecordingTarget(
                rows: recordingRows,
                reference: recordingReference,
                expectedLastModified: nil
            )

            let transcriptColumns = """
                storageID, confidence, createdAt, engine, id, lastModified,
                processingTime, recordingStorageID, recordingId, segments,
                speakerMappings
                """
            let transcripts = try Row.fetchAll(
                database,
                sql: """
                SELECT \(transcriptColumns)
                FROM transcripts
                WHERE recordingStorageID = ? OR recordingId = ?
                ORDER BY storageID
                LIMIT 2
                """,
                arguments: [recording.storageID, recording.legacyID]
            )
            guard transcripts.count <= 1 else {
                throw LibraryRepositoryError.ambiguousTranscript(
                    reference: recordingReference.displayValue
                )
            }

            let transcriptStorageID: String
            let transcriptID: String
            let operation: LibraryChangeOperation
            if let existingRow = transcripts.first {
                let existing = try SQLiteLibraryRepositoryMapper.transcript(
                    from: existingRow
                )
                guard let existingID = existing.legacyID,
                      !existingID.isEmpty else {
                    throw LibraryRepositoryError.invalidRecord(
                        entity: "transcripts",
                        field: "id"
                    )
                }
                transcriptStorageID = existing.storageID
                transcriptID = existingID
                operation = .updated
            } else {
                let duplicateCount = try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM transcripts WHERE id = ?",
                    arguments: [requestedLegacyID]
                ) ?? 0
                guard duplicateCount == 0 else {
                    throw LibraryRepositoryError.transcriptAlreadyExists(
                        reference: requestedLegacyID
                    )
                }
                transcriptStorageID = Self.transcriptStorageID(for: command.id)
                transcriptID = requestedLegacyID
                operation = .inserted
            }

            if operation == .inserted {
                try database.execute(
                    sql: """
                    INSERT INTO transcripts (
                        storageID, confidence, createdAt, engine, id, lastModified,
                        processingTime, recordingStorageID, recordingId, segments,
                        speakerMappings
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        transcriptStorageID,
                        command.confidence,
                        createdAt,
                        command.engine,
                        transcriptID,
                        modifiedAt,
                        command.processingTime,
                        recording.storageID,
                        recording.legacyID,
                        command.segments,
                        command.speakerMappings
                    ]
                )
                guard database.changesCount == 1 else {
                    throw LibraryRepositoryError.writeFailed(
                        operation: "upsert transcript",
                        reason: "the transcript row was not inserted"
                    )
                }
            } else {
                try database.execute(
                    sql: """
                    UPDATE transcripts
                    SET confidence = ?, engine = ?, lastModified = ?,
                        processingTime = ?, recordingStorageID = ?, recordingId = ?,
                        segments = ?, speakerMappings = ?
                    WHERE storageID = ?
                    """,
                    arguments: [
                        command.confidence,
                        command.engine,
                        modifiedAt,
                        command.processingTime,
                        recording.storageID,
                        recording.legacyID,
                        command.segments,
                        command.speakerMappings,
                        transcriptStorageID
                    ]
                )
                guard database.changesCount == 1 else {
                    throw LibraryRepositoryError.writeFailed(
                        operation: "upsert transcript",
                        reason: "the transcript row was not updated"
                    )
                }
            }

            _ = try SQLiteLibraryStore.recordChange(
                in: database,
                entity: .transcript,
                storageID: transcriptStorageID,
                operation: operation,
                at: command.modifiedAt
            )

            try database.execute(
                sql: """
                UPDATE recordings
                SET transcriptId = ?, transcriptionStatus = ?, lastModified = ?
                WHERE storageID = ?
                """,
                arguments: [
                    transcriptID,
                    "Completed",
                    modifiedAt,
                    recording.storageID
                ]
            )
            guard database.changesCount == 1 else {
                throw LibraryRepositoryError.writeFailed(
                    operation: "upsert transcript",
                    reason: "the recording row was not updated"
                )
            }
            _ = try SQLiteLibraryStore.recordChange(
                in: database,
                entity: .recording,
                storageID: recording.storageID,
                operation: .updated,
                at: command.modifiedAt
            )

            return try Self.fetchUpdatedTranscript(
                storageID: transcriptStorageID,
                in: database
            )
        }
    }

    func upsertSummary(
        _ command: LibrarySummaryUpsertCommand
    ) throws -> LibrarySummarySnapshot {
        try command.validate()
        let recordingReference = try Self.normalizedReference(
            command.recordingReference
        )
        let generatedAt = command.generatedAt.timeIntervalSinceReferenceDate
        let requestedLegacyID = command.id.uuidString.lowercased()

        return try databaseQueue.write { database in
            let recordingRows = try Self.fetchRecordingRows(
                for: recordingReference,
                in: database
            )
            let recording = try Self.validateRecordingTarget(
                rows: recordingRows,
                reference: recordingReference,
                expectedLastModified: nil
            )

            let summaryColumns = """
                storageID, aiMethod, compressionRatio, confidence, contentType,
                generatedAt, id, originalLength, processingTime,
                recordingStorageID, recordingId, reminders, summary, tasks,
                titles, transcriptStorageID, transcriptId, version, wordCount
                """
            let summaries = try Row.fetchAll(
                database,
                sql: """
                SELECT \(summaryColumns)
                FROM summaries
                WHERE recordingStorageID = ? OR recordingId = ?
                ORDER BY generatedAt DESC, storageID
                LIMIT 2
                """,
                arguments: [recording.storageID, recording.legacyID]
            )
            guard summaries.count <= 1 else {
                throw LibraryRepositoryError.ambiguousSummary(
                    reference: recordingReference.displayValue
                )
            }

            let summaryStorageID: String
            let summaryID: String
            let operation: LibraryChangeOperation
            if let existingRow = summaries.first {
                let existing = try SQLiteLibraryRepositoryMapper.summary(
                    from: existingRow
                )
                guard let existingID = existing.legacyID,
                      !existingID.isEmpty else {
                    throw LibraryRepositoryError.invalidRecord(
                        entity: "summaries",
                        field: "id"
                    )
                }
                summaryStorageID = existing.storageID
                summaryID = existingID
                operation = .updated
            } else {
                let duplicateCount = try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM summaries WHERE id = ?",
                    arguments: [requestedLegacyID]
                ) ?? 0
                guard duplicateCount == 0 else {
                    throw LibraryRepositoryError.summaryAlreadyExists(
                        reference: requestedLegacyID
                    )
                }
                summaryStorageID = Self.summaryStorageID(for: command.id)
                summaryID = requestedLegacyID
                operation = .inserted
            }

            var transcriptStorageID: String?
            var transcriptID: String?
            if let transcriptIDValue = command.transcriptID {
                let requestedTranscriptID = transcriptIDValue.uuidString.lowercased()
                let transcriptRows = try Row.fetchAll(
                    database,
                    sql: """
                    SELECT storageID, id
                    FROM transcripts
                    WHERE storageID = ? OR LOWER(id) = ?
                    LIMIT 2
                    """,
                    arguments: [
                        Self.transcriptStorageID(for: transcriptIDValue),
                        requestedTranscriptID
                    ]
                )
                guard !transcriptRows.isEmpty else {
                    throw LibraryRepositoryError.transcriptNotFound(
                        reference: requestedTranscriptID
                    )
                }
                guard transcriptRows.count == 1 else {
                    throw LibraryRepositoryError.ambiguousTranscript(
                        reference: requestedTranscriptID
                    )
                }
                guard let resolvedStorageID: String = transcriptRows[0]["storageID"],
                      !resolvedStorageID.isEmpty,
                      let resolvedID: String = transcriptRows[0]["id"],
                      !resolvedID.isEmpty else {
                    throw LibraryRepositoryError.invalidRecord(
                        entity: "transcripts",
                        field: "id"
                    )
                }
                transcriptStorageID = resolvedStorageID
                transcriptID = resolvedID
            } else if let existingRow = summaries.first {
                transcriptStorageID = existingRow["transcriptStorageID"]
                transcriptID = existingRow["transcriptId"]
            }

            if operation == .inserted {
                try database.execute(
                    sql: """
                    INSERT INTO summaries (
                        storageID, aiMethod, compressionRatio, confidence, contentType,
                        generatedAt, id, originalLength, processingTime,
                        recordingStorageID, recordingId, reminders, summary, tasks,
                        titles, transcriptStorageID, transcriptId, version, wordCount
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        summaryStorageID,
                        command.aiMethod,
                        command.compressionRatio,
                        command.confidence,
                        command.contentType,
                        generatedAt,
                        summaryID,
                        command.originalLength,
                        command.processingTime,
                        recording.storageID,
                        recording.legacyID,
                        command.reminders,
                        command.summary,
                        command.tasks,
                        command.titles,
                        transcriptStorageID,
                        transcriptID,
                        command.version,
                        command.wordCount
                    ]
                )
                guard database.changesCount == 1 else {
                    throw LibraryRepositoryError.writeFailed(
                        operation: "upsert summary",
                        reason: "the summary row was not inserted"
                    )
                }
            } else {
                try database.execute(
                    sql: """
                    UPDATE summaries
                    SET aiMethod = ?, compressionRatio = ?, confidence = ?,
                        contentType = ?, generatedAt = ?, originalLength = ?,
                        processingTime = ?, recordingStorageID = ?, recordingId = ?,
                        reminders = ?, summary = ?, tasks = ?, titles = ?,
                        transcriptStorageID = ?, transcriptId = ?, version = ?,
                        wordCount = ?
                    WHERE storageID = ?
                    """,
                    arguments: [
                        command.aiMethod,
                        command.compressionRatio,
                        command.confidence,
                        command.contentType,
                        generatedAt,
                        command.originalLength,
                        command.processingTime,
                        recording.storageID,
                        recording.legacyID,
                        command.reminders,
                        command.summary,
                        command.tasks,
                        command.titles,
                        transcriptStorageID,
                        transcriptID,
                        command.version,
                        command.wordCount,
                        summaryStorageID
                    ]
                )
                guard database.changesCount == 1 else {
                    throw LibraryRepositoryError.writeFailed(
                        operation: "upsert summary",
                        reason: "the summary row was not updated"
                    )
                }
            }

            _ = try SQLiteLibraryStore.recordChange(
                in: database,
                entity: .summary,
                storageID: summaryStorageID,
                operation: operation,
                at: command.generatedAt
            )

            try database.execute(
                sql: """
                UPDATE recordings
                SET summaryId = ?, summaryStatus = ?, lastModified = ?
                WHERE storageID = ?
                """,
                arguments: [
                    summaryID,
                    "Completed",
                    generatedAt,
                    recording.storageID
                ]
            )
            guard database.changesCount == 1 else {
                throw LibraryRepositoryError.writeFailed(
                    operation: "upsert summary",
                    reason: "the recording row was not updated"
                )
            }
            _ = try SQLiteLibraryStore.recordChange(
                in: database,
                entity: .recording,
                storageID: recording.storageID,
                operation: .updated,
                at: command.generatedAt
            )

            return try Self.fetchUpdatedSummary(
                storageID: summaryStorageID,
                in: database
            )
        }
    }

    func createProcessingJob(
        _ command: LibraryProcessingJobCreateCommand
    ) throws -> LibraryProcessingJobSnapshot {
        try command.validate()
        let storageID = Self.processingJobStorageID(for: command.id)
        let startTime = command.startTime.timeIntervalSinceReferenceDate
        let modifiedAt = command.modifiedAt.timeIntervalSinceReferenceDate
        let completionTime = command.completionTime?.timeIntervalSinceReferenceDate

        return try databaseQueue.write { database in
            let duplicateCount = try Int.fetchOne(
                database,
                sql: """
                SELECT COUNT(*)
                FROM processing_jobs
                WHERE storageID = ? OR id = ?
                """,
                arguments: [storageID, command.id.uuidString.lowercased()]
            ) ?? 0
            guard duplicateCount == 0 else {
                throw LibraryRepositoryError.processingJobAlreadyExists(
                    reference: command.id.uuidString.lowercased()
                )
            }

            let recordingStorageID: String?
            if let reference = command.recordingReference {
                let normalizedReference = try Self.normalizedReference(reference)
                let rows = try Self.fetchRecordingRows(
                    for: normalizedReference,
                    in: database
                )
                recordingStorageID = try Self.validateRecordingTarget(
                    rows: rows,
                    reference: normalizedReference,
                    expectedLastModified: nil
                ).storageID
            } else {
                recordingStorageID = nil
            }

            try database.execute(
                sql: """
                INSERT INTO processing_jobs (
                    storageID, completionTime, engine, error, id, jobType,
                    lastModified, modelName, progress, recordingName, recordingURL,
                    recordingStorageID, startTime, status
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    storageID,
                    completionTime,
                    command.engine,
                    command.error,
                    command.id.uuidString.lowercased(),
                    command.jobType,
                    modifiedAt,
                    command.modelName,
                    command.progress,
                    command.recordingName,
                    command.recordingURL,
                    recordingStorageID,
                    startTime,
                    command.status
                ]
            )
            guard database.changesCount == 1 else {
                throw LibraryRepositoryError.writeFailed(
                    operation: "create processing job",
                    reason: "the processing-job row was not inserted"
                )
            }

            _ = try SQLiteLibraryStore.recordChange(
                in: database,
                entity: .processingJob,
                storageID: storageID,
                operation: .inserted,
                at: command.modifiedAt
            )
            return try Self.fetchUpdatedProcessingJob(
                storageID: storageID,
                in: database
            )
        }
    }

    func updateProcessingJob(
        _ command: LibraryProcessingJobUpdateCommand
    ) throws -> LibraryProcessingJobSnapshot {
        try command.validate()
        let reference = try Self.normalizedProcessingJobReference(command.reference)
        let modifiedAt = command.modifiedAt.timeIntervalSinceReferenceDate

        return try databaseQueue.write { database in
            let rows = try Self.fetchProcessingJobRows(for: reference, in: database)
            let current = try Self.validateProcessingJobTarget(
                rows: rows,
                reference: reference,
                expectedLastModified: command.expectedLastModified
            )

            let error: String?
            switch command.error {
            case .preserve:
                error = current.error
            case .set(let value):
                error = value
            }

            let completionTime: Double?
            switch command.completionTime {
            case .preserve:
                completionTime = current.completionTime?.timeIntervalSinceReferenceDate
            case .set(let value):
                completionTime = value?.timeIntervalSinceReferenceDate
            }

            try database.execute(
                sql: """
                UPDATE processing_jobs
                SET status = ?, progress = ?, error = ?, completionTime = ?, lastModified = ?
                WHERE storageID = ?
                """,
                arguments: [
                    command.status,
                    command.progress,
                    error,
                    completionTime,
                    modifiedAt,
                    current.storageID
                ]
            )
            guard database.changesCount == 1 else {
                throw LibraryRepositoryError.writeFailed(
                    operation: "update processing job",
                    reason: "the processing-job row was not updated"
                )
            }

            _ = try SQLiteLibraryStore.recordChange(
                in: database,
                entity: .processingJob,
                storageID: current.storageID,
                operation: .updated,
                at: command.modifiedAt
            )
            return try Self.fetchUpdatedProcessingJob(
                storageID: current.storageID,
                in: database
            )
        }
    }

    func deleteProcessingJob(
        _ command: LibraryProcessingJobDeleteCommand
    ) throws -> LibraryProcessingJobSnapshot {
        guard command.deletedAt.timeIntervalSinceReferenceDate.isFinite,
              command.expectedLastModified?.timeIntervalSinceReferenceDate.isFinite ?? true else {
            throw LibraryRepositoryError.invalidCommand(
                "processing-job expected last modified date must be finite"
            )
        }
        let reference = try Self.normalizedProcessingJobReference(command.reference)

        return try databaseQueue.write { database in
            let rows = try Self.fetchProcessingJobRows(for: reference, in: database)
            let current = try Self.validateProcessingJobTarget(
                rows: rows,
                reference: reference,
                expectedLastModified: command.expectedLastModified
            )

            try database.execute(
                sql: "DELETE FROM processing_jobs WHERE storageID = ?",
                arguments: [current.storageID]
            )
            guard database.changesCount == 1 else {
                throw LibraryRepositoryError.writeFailed(
                    operation: "delete processing job",
                    reason: "the processing-job row was not deleted"
                )
            }

            _ = try SQLiteLibraryStore.recordChange(
                in: database,
                entity: .processingJob,
                storageID: current.storageID,
                operation: .deleted,
                at: command.deletedAt
            )
            return current
        }
    }

    func deleteTerminalProcessingJobs(
        _ command: LibraryProcessingJobTerminalCleanupCommand
    ) throws -> [LibraryProcessingJobSnapshot] {
        try command.validate()
        let statuses = command.normalizedStatuses
        let placeholders = Array(repeating: "?", count: statuses.count)
            .joined(separator: ", ")

        return try databaseQueue.write { database in
            let columns = """
                storageID, completionTime, engine, error, id, jobType,
                lastModified, modelName, progress, recordingName, recordingURL,
                recordingStorageID, startTime, status
                """
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT \(columns)
                FROM processing_jobs
                WHERE LOWER(TRIM(status)) IN (\(placeholders))
                ORDER BY storageID
                """,
                arguments: StatementArguments(statuses.map(\.databaseValue))
            )
            let snapshots = try rows.map(SQLiteLibraryRepositoryMapper.processingJob(from:))

            for snapshot in snapshots {
                try database.execute(
                    sql: "DELETE FROM processing_jobs WHERE storageID = ?",
                    arguments: [snapshot.storageID]
                )
                guard database.changesCount == 1 else {
                    throw LibraryRepositoryError.writeFailed(
                        operation: "delete terminal processing jobs",
                        reason: "a processing-job row was not deleted"
                    )
                }
                _ = try SQLiteLibraryStore.recordChange(
                    in: database,
                    entity: .processingJob,
                    storageID: snapshot.storageID,
                    operation: .deleted,
                    at: command.deletedAt
                )
            }
            return snapshots
        }
    }

    func recoverProcessingJobsAfterCrash(
        _ command: LibraryProcessingJobCrashRecoveryCommand
    ) throws -> [LibraryProcessingJobSnapshot] {
        try command.validate()
        let terminalStatuses = Set(["completed", "failed", "cancelled"])

        return try databaseQueue.write { database in
            var jobsToRecover: [LibraryProcessingJobSnapshot] = []
            var seenStorageIDs = Set<String>()

            for reference in command.references {
                let normalizedReference = try Self.normalizedProcessingJobReference(reference)
                let rows = try Self.fetchProcessingJobRows(
                    for: normalizedReference,
                    in: database
                )
                guard !rows.isEmpty else {
                    continue
                }
                let current = try Self.validateProcessingJobTarget(
                    rows: rows,
                    reference: normalizedReference,
                    expectedLastModified: nil
                )
                guard seenStorageIDs.insert(current.storageID).inserted else {
                    continue
                }
                let normalizedStatus = current.status?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard !terminalStatuses.contains(normalizedStatus ?? "") else {
                    continue
                }
                jobsToRecover.append(current)
            }

            for job in jobsToRecover {
                try database.execute(
                    sql: """
                    UPDATE processing_jobs
                    SET status = ?, error = ?, completionTime = ?, lastModified = ?
                    WHERE storageID = ?
                    """,
                    arguments: [
                        command.status,
                        command.failureMessage,
                        command.modifiedAt.timeIntervalSinceReferenceDate,
                        command.modifiedAt.timeIntervalSinceReferenceDate,
                        job.storageID
                    ]
                )
                guard database.changesCount == 1 else {
                    throw LibraryRepositoryError.writeFailed(
                        operation: "recover processing jobs after crash",
                        reason: "a processing-job row was not updated"
                    )
                }
                _ = try SQLiteLibraryStore.recordChange(
                    in: database,
                    entity: .processingJob,
                    storageID: job.storageID,
                    operation: .updated,
                    at: command.modifiedAt
                )
            }

            return try jobsToRecover.map { job in
                try Self.fetchUpdatedProcessingJob(
                    storageID: job.storageID,
                    in: database
                )
            }
        }
    }

    private static func normalizedReference(
        _ reference: LibraryRecordingReference
    ) throws -> LibraryRecordingReference {
        let storageID = reference.storageID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyID = canonicalLegacyID(reference.legacyID)
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

    private static func normalizedProcessingJobReference(
        _ reference: LibraryProcessingJobReference
    ) throws -> LibraryProcessingJobReference {
        let storageID = reference.storageID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyID = canonicalLegacyID(reference.legacyID)
        guard storageID?.isEmpty == false || legacyID?.isEmpty == false else {
            throw LibraryRepositoryError.invalidCommand(
                "processing-job reference must contain a storage ID or legacy ID"
            )
        }
        return LibraryProcessingJobReference(
            storageID: storageID?.isEmpty == false ? storageID : nil,
            legacyID: legacyID?.isEmpty == false ? legacyID : nil
        )
    }

    private static func processingJobStorageID(for id: UUID) -> String {
        "sqlite-processingjob-\(id.uuidString.lowercased())"
    }

    private static func recordingStorageID(for id: UUID) -> String {
        "sqlite-recording-\(id.uuidString.lowercased())"
    }

    private static func canonicalLegacyID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        guard let uuid = UUID(uuidString: value) else {
            return value
        }
        return uuid.uuidString.lowercased()
    }

    private static func fetchRecordingRows(
        for reference: LibraryRecordingReference,
        in database: Database
    ) throws -> [Row] {
        let columns = """
            storageID, id, recordingName, recordingDate, duration,
            fileSize, recordingURL, isArchived, archivedAt, archiveNote,
            isCloudSyncDisabled, lastModified, summaryId, transcriptId
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

    private static func fetchProcessingJobRows(
        for reference: LibraryProcessingJobReference,
        in database: Database
    ) throws -> [Row] {
        let columns = """
            storageID, completionTime, engine, error, id, jobType,
            lastModified, modelName, progress, recordingName, recordingURL,
            recordingStorageID, startTime, status
            """
        if let storageID = reference.storageID {
            return try Row.fetchAll(
                database,
                sql: "SELECT \(columns) FROM processing_jobs WHERE storageID = ? LIMIT 2",
                arguments: [storageID]
            )
        }
        guard let legacyID = reference.legacyID else {
            throw LibraryRepositoryError.invalidCommand(
                "processing-job reference must contain a storage ID or legacy ID"
            )
        }
        return try Row.fetchAll(
            database,
            sql: "SELECT \(columns) FROM processing_jobs WHERE id = ? LIMIT 2",
            arguments: [legacyID]
        )
    }

    private static func validateRecordingTarget(
        rows: [Row],
        reference: LibraryRecordingReference,
        expectedLastModified: Date?
    ) throws -> LibraryRecordingSnapshot {
        guard !rows.isEmpty else {
            throw LibraryRepositoryError.recordingNotFound(reference: reference.displayValue)
        }
        guard rows.count == 1 else {
            throw LibraryRepositoryError.ambiguousRecording(reference: reference.displayValue)
        }

        let current = try SQLiteLibraryRepositoryMapper.snapshot(from: rows[0])
        guard expectedLastModified == nil
                || expectedLastModified == current.lastModified else {
            throw LibraryRepositoryError.staleRecording(
                reference: reference.displayValue,
                expected: expectedLastModified,
                actual: current.lastModified
            )
        }
        return current
    }

    private static func validateProcessingJobTarget(
        rows: [Row],
        reference: LibraryProcessingJobReference,
        expectedLastModified: Date?
    ) throws -> LibraryProcessingJobSnapshot {
        guard !rows.isEmpty else {
            throw LibraryRepositoryError.processingJobNotFound(
                reference: reference.displayValue
            )
        }
        guard rows.count == 1 else {
            throw LibraryRepositoryError.ambiguousProcessingJob(
                reference: reference.displayValue
            )
        }

        let current = try SQLiteLibraryRepositoryMapper.processingJob(from: rows[0])
        guard expectedLastModified == nil
                || expectedLastModified == current.lastModified else {
            throw LibraryRepositoryError.staleProcessingJob(
                reference: reference.displayValue,
                expected: expectedLastModified,
                actual: current.lastModified
            )
        }
        return current
    }

    private static func requiredStorageID(
        from row: Row,
        entity: String
    ) throws -> String {
        guard let storageID: String = row["storageID"], !storageID.isEmpty else {
            throw LibraryRepositoryError.invalidRecord(entity: entity, field: "storageID")
        }
        return storageID
    }

    private static func requiredLegacyID(
        from row: Row,
        entity: String
    ) throws -> String {
        guard let legacyID: String = row["id"], !legacyID.isEmpty else {
            throw LibraryRepositoryError.invalidRecord(entity: entity, field: "id")
        }
        return legacyID
    }

    private static func normalizedID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func pendingMutationRows(
        kind: String,
        targetID: String,
        in database: Database
    ) throws -> [Row] {
        try Row.fetchAll(
            database,
            sql: """
            SELECT storageID, payload, recordingId, requestedAt, targetId, version
            FROM pending_cloud_mutations
            WHERE kind = ? AND lower(targetId) = lower(?)
            ORDER BY requestedAt IS NULL, requestedAt, storageID
            """,
            arguments: [kind, targetID]
        )
    }

    private static func encodeRecordingDeletionPayload(
        transcriptIDs: [String],
        summaryIDs: [String]
    ) throws -> Data {
        do {
            return try JSONEncoder().encode(
                SQLiteRecordingDeletionPayload(
                    transcriptIds: Array(Set(transcriptIDs.map(Self.normalizedID))).sorted(),
                    summaryIds: Array(Set(summaryIDs.map(Self.normalizedID))).sorted()
                )
            )
        } catch {
            throw LibraryRepositoryError.writeFailed(
                operation: "delete recording",
                reason: "the recording deletion payload could not be encoded"
            )
        }
    }

    private static func decodeRecordingDeletionPayload(
        from data: Data?
    ) throws -> SQLiteRecordingDeletionPayload {
        guard let data else {
            return SQLiteRecordingDeletionPayload(transcriptIds: [], summaryIds: [])
        }
        do {
            return try JSONDecoder().decode(SQLiteRecordingDeletionPayload.self, from: data)
        } catch {
            throw LibraryRepositoryError.invalidRecord(
                entity: "pending_cloud_mutations",
                field: "payload"
            )
        }
    }

    private static func enqueueRecordingDeletionMutation(
        recordingStorageID: String,
        recordingID: String,
        transcriptIDs: [String],
        summaryIDs: [String],
        requestedAt: Double,
        in database: Database,
        committedAt: Date
    ) throws {
        let rows = try pendingMutationRows(
            kind: recordingDeletionKind,
            targetID: recordingID,
            in: database
        )
        let payloadData: Data
        if let canonicalRow = rows.first {
            let canonicalStorageID = try requiredStorageID(
                from: canonicalRow,
                entity: "pending_cloud_mutations"
            )
            guard let version: Int64 = canonicalRow["version"],
                  version == pendingMutationPayloadVersion else {
                throw LibraryRepositoryError.invalidRecord(
                    entity: "pending_cloud_mutations",
                    field: "version"
                )
            }
            let existingPayload = try decodeRecordingDeletionPayload(
                from: canonicalRow["payload"]
            )
            payloadData = try encodeRecordingDeletionPayload(
                transcriptIDs: existingPayload.transcriptIds + transcriptIDs,
                summaryIDs: existingPayload.summaryIds + summaryIDs
            )
            let existingRequestedAt: Double? = canonicalRow["requestedAt"]
            let mergedRequestedAt = min(existingRequestedAt ?? requestedAt, requestedAt)

            try database.execute(
                sql: """
                UPDATE pending_cloud_mutations
                SET payload = ?, recordingId = ?, requestedAt = ?, version = ?
                WHERE storageID = ?
                """,
                arguments: [
                    payloadData,
                    nil,
                    mergedRequestedAt,
                    pendingMutationPayloadVersion,
                    canonicalStorageID
                ]
            )
            guard database.changesCount == 1 else {
                throw LibraryRepositoryError.writeFailed(
                    operation: "delete recording",
                    reason: "the recording deletion marker was not updated"
                )
            }
            _ = try SQLiteLibraryStore.recordChange(
                in: database,
                entity: .pendingCloudMutation,
                storageID: canonicalStorageID,
                operation: .updated,
                at: committedAt
            )

            for duplicateRow in rows.dropFirst() {
                try deletePendingMutationRow(
                    duplicateRow,
                    operation: "delete recording",
                    at: committedAt,
                    in: database
                )
            }
            return
        }

        payloadData = try encodeRecordingDeletionPayload(
            transcriptIDs: transcriptIDs,
            summaryIDs: summaryIDs
        )
        let storageID = "recording-deletion-\(recordingStorageID)"
        try database.execute(
            sql: """
            INSERT INTO pending_cloud_mutations (
                storageID, kind, payload, recordingId, requestedAt, targetId, version
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                storageID,
                recordingDeletionKind,
                payloadData,
                nil,
                requestedAt,
                recordingID,
                pendingMutationPayloadVersion
            ]
        )
        guard database.changesCount == 1 else {
            throw LibraryRepositoryError.writeFailed(
                operation: "delete recording",
                reason: "the recording deletion marker was not inserted"
            )
        }
        _ = try SQLiteLibraryStore.recordChange(
            in: database,
            entity: .pendingCloudMutation,
            storageID: storageID,
            operation: .inserted,
            at: committedAt
        )
    }

    private static func enqueueSummaryRemovalMutation(
        summaryStorageID: String,
        summaryID: String,
        recordingID: String?,
        requestedAt: Double,
        in database: Database,
        committedAt: Date
    ) throws {
        let rows = try pendingMutationRows(
            kind: summaryRemovalKind,
            targetID: summaryID,
            in: database
        )
        if let canonicalRow = rows.first {
            let canonicalStorageID = try requiredStorageID(
                from: canonicalRow,
                entity: "pending_cloud_mutations"
            )
            guard let version: Int64 = canonicalRow["version"],
                  version == pendingMutationPayloadVersion else {
                throw LibraryRepositoryError.invalidRecord(
                    entity: "pending_cloud_mutations",
                    field: "version"
                )
            }
            let existingRequestedAt: Double? = canonicalRow["requestedAt"]
            let mergedRequestedAt = min(existingRequestedAt ?? requestedAt, requestedAt)
            let existingRecordingID: String? = canonicalRow["recordingId"]
            try database.execute(
                sql: """
                UPDATE pending_cloud_mutations
                SET payload = ?, recordingId = ?, requestedAt = ?, version = ?
                WHERE storageID = ?
                """,
                arguments: [
                    nil,
                    existingRecordingID ?? recordingID,
                    mergedRequestedAt,
                    pendingMutationPayloadVersion,
                    canonicalStorageID
                ]
            )
            guard database.changesCount == 1 else {
                throw LibraryRepositoryError.writeFailed(
                    operation: "delete recording",
                    reason: "the summary deletion marker was not updated"
                )
            }
            _ = try SQLiteLibraryStore.recordChange(
                in: database,
                entity: .pendingCloudMutation,
                storageID: canonicalStorageID,
                operation: .updated,
                at: committedAt
            )
            for duplicateRow in rows.dropFirst() {
                try deletePendingMutationRow(
                    duplicateRow,
                    operation: "delete recording",
                    at: committedAt,
                    in: database
                )
            }
            return
        }

        let storageID = "summary-removal-\(summaryStorageID)"
        try database.execute(
            sql: """
            INSERT INTO pending_cloud_mutations (
                storageID, kind, payload, recordingId, requestedAt, targetId, version
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                storageID,
                summaryRemovalKind,
                nil,
                recordingID,
                requestedAt,
                summaryID,
                pendingMutationPayloadVersion
            ]
        )
        guard database.changesCount == 1 else {
            throw LibraryRepositoryError.writeFailed(
                operation: "delete recording",
                reason: "the summary deletion marker was not inserted"
            )
        }
        _ = try SQLiteLibraryStore.recordChange(
            in: database,
            entity: .pendingCloudMutation,
            storageID: storageID,
            operation: .inserted,
            at: committedAt
        )
    }

    private static func enqueueTranscriptRemovalMutation(
        transcriptID: String,
        recordingID: String?,
        requestedAt: Double,
        in database: Database,
        committedAt: Date
    ) throws {
        let rows = try pendingMutationRows(
            kind: transcriptRemovalKind,
            targetID: transcriptID,
            in: database
        )
        if let canonicalRow = rows.first {
            let canonicalStorageID = try requiredStorageID(
                from: canonicalRow,
                entity: "pending_cloud_mutations"
            )
            guard let version: Int64 = canonicalRow["version"],
                  version == pendingMutationPayloadVersion else {
                throw LibraryRepositoryError.invalidRecord(
                    entity: "pending_cloud_mutations",
                    field: "version"
                )
            }
            let existingRequestedAt: Double? = canonicalRow["requestedAt"]
            let mergedRequestedAt = min(existingRequestedAt ?? requestedAt, requestedAt)
            let existingRecordingID: String? = canonicalRow["recordingId"]
            try database.execute(
                sql: """
                UPDATE pending_cloud_mutations
                SET payload = ?, recordingId = ?, requestedAt = ?, version = ?
                WHERE storageID = ?
                """,
                arguments: [
                    nil,
                    existingRecordingID ?? recordingID,
                    mergedRequestedAt,
                    pendingMutationPayloadVersion,
                    canonicalStorageID
                ]
            )
            guard database.changesCount == 1 else {
                throw LibraryRepositoryError.writeFailed(
                    operation: "delete recording preserving summary",
                    reason: "the transcript deletion marker was not updated"
                )
            }
            _ = try SQLiteLibraryStore.recordChange(
                in: database,
                entity: .pendingCloudMutation,
                storageID: canonicalStorageID,
                operation: .updated,
                at: committedAt
            )
            for duplicateRow in rows.dropFirst() {
                try deletePendingMutationRow(
                    duplicateRow,
                    operation: "delete recording preserving summary",
                    at: committedAt,
                    in: database
                )
            }
            return
        }

        let storageID = "transcript-removal-\(transcriptID)"
        try database.execute(
            sql: """
            INSERT INTO pending_cloud_mutations (
                storageID, kind, payload, recordingId, requestedAt, targetId, version
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                storageID,
                transcriptRemovalKind,
                nil,
                recordingID,
                requestedAt,
                transcriptID,
                pendingMutationPayloadVersion
            ]
        )
        guard database.changesCount == 1 else {
            throw LibraryRepositoryError.writeFailed(
                operation: "delete recording preserving summary",
                reason: "the transcript deletion marker was not inserted"
            )
        }
        _ = try SQLiteLibraryStore.recordChange(
            in: database,
            entity: .pendingCloudMutation,
            storageID: storageID,
            operation: .inserted,
            at: committedAt
        )
    }

    private static func enqueueImportedAudioRemovalMutation(
        recordingStorageID: String,
        recordingID: String,
        requestedAt: Double,
        in database: Database,
        committedAt: Date
    ) throws {
        let rows = try pendingMutationRows(
            kind: importedAudioRemovalKind,
            targetID: recordingID,
            in: database
        )
        if let canonicalRow = rows.first {
            let canonicalStorageID = try requiredStorageID(
                from: canonicalRow,
                entity: "pending_cloud_mutations"
            )
            guard let version: Int64 = canonicalRow["version"],
                  version == pendingMutationPayloadVersion else {
                throw LibraryRepositoryError.invalidRecord(
                    entity: "pending_cloud_mutations",
                    field: "version"
                )
            }
            let existingRequestedAt: Double? = canonicalRow["requestedAt"]
            let mergedRequestedAt = min(existingRequestedAt ?? requestedAt, requestedAt)
            try database.execute(
                sql: """
                UPDATE pending_cloud_mutations
                SET payload = ?, recordingId = ?, requestedAt = ?, version = ?
                WHERE storageID = ?
                """,
                arguments: [
                    nil,
                    nil,
                    mergedRequestedAt,
                    pendingMutationPayloadVersion,
                    canonicalStorageID
                ]
            )
            guard database.changesCount == 1 else {
                throw LibraryRepositoryError.writeFailed(
                    operation: "delete recording preserving summary",
                    reason: "the imported-audio deletion marker was not updated"
                )
            }
            _ = try SQLiteLibraryStore.recordChange(
                in: database,
                entity: .pendingCloudMutation,
                storageID: canonicalStorageID,
                operation: .updated,
                at: committedAt
            )
            for duplicateRow in rows.dropFirst() {
                try deletePendingMutationRow(
                    duplicateRow,
                    operation: "delete recording preserving summary",
                    at: committedAt,
                    in: database
                )
            }
            return
        }

        let storageID = "imported-audio-removal-\(recordingStorageID)"
        try database.execute(
            sql: """
            INSERT INTO pending_cloud_mutations (
                storageID, kind, payload, recordingId, requestedAt, targetId, version
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                storageID,
                importedAudioRemovalKind,
                nil,
                nil,
                requestedAt,
                recordingID,
                pendingMutationPayloadVersion
            ]
        )
        guard database.changesCount == 1 else {
            throw LibraryRepositoryError.writeFailed(
                operation: "delete recording preserving summary",
                reason: "the imported-audio deletion marker was not inserted"
            )
        }
        _ = try SQLiteLibraryStore.recordChange(
            in: database,
            entity: .pendingCloudMutation,
            storageID: storageID,
            operation: .inserted,
            at: committedAt
        )
    }

    private static func removePendingMutations(
        kind: String,
        targetID: String,
        in database: Database,
        committedAt: Date
    ) throws {
        for row in try pendingMutationRows(kind: kind, targetID: targetID, in: database) {
            try deletePendingMutationRow(
                row,
                operation: "delete recording",
                at: committedAt,
                in: database
            )
        }
    }

    private static func deletePendingMutationRow(
        _ row: Row,
        operation: String,
        at date: Date,
        in database: Database
    ) throws {
        let storageID = try requiredStorageID(
            from: row,
            entity: "pending_cloud_mutations"
        )
        try database.execute(
            sql: "DELETE FROM pending_cloud_mutations WHERE storageID = ?",
            arguments: [storageID]
        )
        guard database.changesCount == 1 else {
            throw LibraryRepositoryError.writeFailed(
                operation: operation,
                reason: "a pending deletion marker was not removed"
            )
        }
        _ = try SQLiteLibraryStore.recordChange(
            in: database,
            entity: .pendingCloudMutation,
            storageID: storageID,
            operation: .deleted,
            at: date
        )
    }

    private static func clearRetainedTranscriptReferences(
        transcriptStorageIDs: Set<String>,
        transcriptIDs: Set<String>,
        deletedSummaryStorageIDs: Set<String>,
        in database: Database,
        committedAt: Date
    ) throws {
        guard !transcriptStorageIDs.isEmpty || !transcriptIDs.isEmpty else { return }
        let rows = try Row.fetchAll(
            database,
            sql: "SELECT storageID, transcriptStorageID, transcriptId FROM summaries"
        )
        for row in rows {
            let summaryStorageID = try requiredStorageID(from: row, entity: "summaries")
            guard !deletedSummaryStorageIDs.contains(summaryStorageID) else { continue }
            let transcriptStorageID: String? = row["transcriptStorageID"]
            let transcriptID: String? = row["transcriptId"]
            guard transcriptStorageID.map({ transcriptStorageIDs.contains($0) }) == true
                    || transcriptID.map({ transcriptIDs.contains(Self.normalizedID($0)) }) == true else {
                continue
            }

            try database.execute(
                sql: """
                UPDATE summaries
                SET transcriptStorageID = ?, transcriptId = ?
                WHERE storageID = ?
                """,
                arguments: [nil, nil, summaryStorageID]
            )
            guard database.changesCount == 1 else {
                throw LibraryRepositoryError.writeFailed(
                    operation: "delete recording",
                    reason: "a retained summary transcript link was not cleared"
                )
            }
            _ = try SQLiteLibraryStore.recordChange(
                in: database,
                entity: .summary,
                storageID: summaryStorageID,
                operation: .updated,
                at: committedAt
            )
        }
    }

    private static func deleteRow(
        table: String,
        storageID: String,
        entity: LibraryChangeEntity,
        operation: String,
        at date: Date,
        in database: Database
    ) throws {
        try database.execute(
            sql: "DELETE FROM \(table) WHERE storageID = ?",
            arguments: [storageID]
        )
        guard database.changesCount == 1 else {
            throw LibraryRepositoryError.writeFailed(
                operation: operation,
                reason: "the \(table) row was not deleted"
            )
        }
        _ = try SQLiteLibraryStore.recordChange(
            in: database,
            entity: entity,
            storageID: storageID,
            operation: .deleted,
            at: date
        )
    }

    private static func upsertLocalOnlyMutation(
        targetID: String,
        requestedAt: Double,
        recordingStorageID: String,
        in database: Database,
        committedAt: Date
    ) throws {
        let rows = try Row.fetchAll(
            database,
            sql: """
            SELECT storageID, requestedAt
            FROM pending_cloud_mutations
            WHERE kind = ? AND targetId = ?
            ORDER BY requestedAt IS NULL, requestedAt, storageID
            """,
            arguments: [localOnlyRemovalKind, targetID]
        )

        guard let canonicalRow = rows.first else {
            let storageID = "local-only-removal-\(recordingStorageID)"
            try database.execute(
                sql: """
                INSERT INTO pending_cloud_mutations (
                    storageID, kind, payload, recordingId, requestedAt, targetId, version
                )
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    storageID,
                    localOnlyRemovalKind,
                    nil,
                    nil,
                    requestedAt,
                    targetID,
                    1
                ]
            )
            _ = try SQLiteLibraryStore.recordChange(
                in: database,
                entity: .pendingCloudMutation,
                storageID: storageID,
                operation: .inserted,
                at: committedAt
            )
            return
        }

        guard let canonicalStorageID: String = canonicalRow["storageID"],
              !canonicalStorageID.isEmpty else {
            throw LibraryRepositoryError.invalidRecord(
                entity: "pending_cloud_mutations",
                field: "storageID"
            )
        }

        let existingRequestedAt: Double? = canonicalRow["requestedAt"]
        let mergedRequestedAt = min(existingRequestedAt ?? requestedAt, requestedAt)
        if existingRequestedAt != mergedRequestedAt {
            try database.execute(
                sql: """
                UPDATE pending_cloud_mutations
                SET requestedAt = ?
                WHERE storageID = ?
                """,
                arguments: [mergedRequestedAt, canonicalStorageID]
            )
            guard database.changesCount == 1 else {
                throw LibraryRepositoryError.writeFailed(
                    operation: "set cloud sync preference",
                    reason: "the pending local-only marker was not updated"
                )
            }
            _ = try SQLiteLibraryStore.recordChange(
                in: database,
                entity: .pendingCloudMutation,
                storageID: canonicalStorageID,
                operation: .updated,
                at: committedAt
            )
        }

        for duplicateRow in rows.dropFirst() {
            guard let duplicateStorageID: String = duplicateRow["storageID"],
                  !duplicateStorageID.isEmpty else {
                throw LibraryRepositoryError.invalidRecord(
                    entity: "pending_cloud_mutations",
                    field: "storageID"
                )
            }
            try database.execute(
                sql: "DELETE FROM pending_cloud_mutations WHERE storageID = ?",
                arguments: [duplicateStorageID]
            )
            guard database.changesCount == 1 else {
                throw LibraryRepositoryError.writeFailed(
                    operation: "set cloud sync preference",
                    reason: "a duplicate pending local-only marker was not removed"
                )
            }
            _ = try SQLiteLibraryStore.recordChange(
                in: database,
                entity: .pendingCloudMutation,
                storageID: duplicateStorageID,
                operation: .deleted,
                at: committedAt
            )
        }
    }

    private static func removeLocalOnlyMutations(
        targetID: String,
        in database: Database,
        committedAt: Date
    ) throws {
        let rows = try Row.fetchAll(
            database,
            sql: """
            SELECT storageID
            FROM pending_cloud_mutations
            WHERE kind = ? AND targetId = ?
            ORDER BY storageID
            """,
            arguments: [localOnlyRemovalKind, targetID]
        )
        for row in rows {
            guard let storageID: String = row["storageID"], !storageID.isEmpty else {
                throw LibraryRepositoryError.invalidRecord(
                    entity: "pending_cloud_mutations",
                    field: "storageID"
                )
            }
            try database.execute(
                sql: "DELETE FROM pending_cloud_mutations WHERE storageID = ?",
                arguments: [storageID]
            )
            guard database.changesCount == 1 else {
                throw LibraryRepositoryError.writeFailed(
                    operation: "set cloud sync preference",
                    reason: "the pending local-only marker was not removed"
                )
            }
            _ = try SQLiteLibraryStore.recordChange(
                in: database,
                entity: .pendingCloudMutation,
                storageID: storageID,
                operation: .deleted,
                at: committedAt
            )
        }
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

    private static func transcriptStorageID(for id: UUID) -> String {
        "sqlite-transcript-\(id.uuidString.lowercased())"
    }

    private static func summaryStorageID(for id: UUID) -> String {
        "sqlite-summary-\(id.uuidString.lowercased())"
    }

    private static func archiveLocationStorageID(for id: UUID) -> String {
        "sqlite-archive-location-\(id.uuidString.lowercased())"
    }

    private static func fetchUpdatedArchiveLocation(
        storageID: String,
        in database: Database
    ) throws -> LibraryArchiveLocationSnapshot {
        let columns = """
            storageID, bookmarkData, destinationURLString, displayName,
            exportedAt, exportedFilename, fileSize, id, lastVerifiedAt,
            providerDisplayName, recordingId, status
            """
        guard let updatedRow = try Row.fetchOne(
            database,
            sql: "SELECT \(columns) FROM archive_locations WHERE storageID = ?",
            arguments: [storageID]
        ) else {
            throw LibraryRepositoryError.writeFailed(
                operation: "upsert archive location",
                reason: "the updated archive-location row could not be read"
            )
        }
        return try SQLiteLibraryRepositoryMapper.archiveLocation(from: updatedRow)
    }

    private static func fetchUpdatedRecording(
        storageID: String,
        in database: Database,
        operation: String = "write recording"
    ) throws -> LibraryRecordingSnapshot {
        let columns = """
            storageID, id, recordingName, recordingDate, duration,
            fileSize, recordingURL, isArchived, archivedAt, archiveNote,
            isCloudSyncDisabled, lastModified
            """
        guard let updatedRow = try Row.fetchOne(
            database,
            sql: "SELECT \(columns) FROM recordings WHERE storageID = ?",
            arguments: [storageID]
        ) else {
            throw LibraryRepositoryError.writeFailed(
                operation: operation,
                reason: "the updated recording row could not be read"
            )
        }
        return try SQLiteLibraryRepositoryMapper.snapshot(from: updatedRow)
    }

    private static func fetchUpdatedProcessingJob(
        storageID: String,
        in database: Database
    ) throws -> LibraryProcessingJobSnapshot {
        let columns = """
            storageID, completionTime, engine, error, id, jobType,
            lastModified, modelName, progress, recordingName, recordingURL,
            recordingStorageID, startTime, status
            """
        guard let updatedRow = try Row.fetchOne(
            database,
            sql: "SELECT \(columns) FROM processing_jobs WHERE storageID = ?",
            arguments: [storageID]
        ) else {
            throw LibraryRepositoryError.writeFailed(
                operation: "update processing job",
                reason: "the updated processing-job row could not be read"
            )
        }
        return try SQLiteLibraryRepositoryMapper.processingJob(from: updatedRow)
    }

    private static func fetchUpdatedTranscript(
        storageID: String,
        in database: Database
    ) throws -> LibraryTranscriptSnapshot {
        let columns = """
            storageID, confidence, createdAt, engine, id, lastModified,
            processingTime, recordingStorageID, recordingId, segments,
            speakerMappings
            """
        guard let updatedRow = try Row.fetchOne(
            database,
            sql: "SELECT \(columns) FROM transcripts WHERE storageID = ?",
            arguments: [storageID]
        ) else {
            throw LibraryRepositoryError.writeFailed(
                operation: "upsert transcript",
                reason: "the updated transcript row could not be read"
            )
        }
        return try SQLiteLibraryRepositoryMapper.transcript(from: updatedRow)
    }

    private static func fetchUpdatedSummary(
        storageID: String,
        in database: Database
    ) throws -> LibrarySummarySnapshot {
        let columns = """
            storageID, aiMethod, compressionRatio, confidence, contentType,
            generatedAt, id, originalLength, processingTime,
            recordingStorageID, recordingId, reminders, summary, tasks, titles,
            transcriptStorageID, transcriptId, version, wordCount
            """
        guard let updatedRow = try Row.fetchOne(
            database,
            sql: "SELECT \(columns) FROM summaries WHERE storageID = ?",
            arguments: [storageID]
        ) else {
            throw LibraryRepositoryError.writeFailed(
                operation: "upsert summary",
                reason: "the updated summary row could not be read"
            )
        }
        return try SQLiteLibraryRepositoryMapper.summary(from: updatedRow)
    }

    func fetchRecordingSummaries() throws -> [LibraryRecordingSnapshot] {
        try databaseQueue.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT storageID, id, recordingName, recordingDate, duration,
                       fileSize, recordingURL, isArchived, archivedAt, archiveNote,
                       isCloudSyncDisabled, lastModified
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
