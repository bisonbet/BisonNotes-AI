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

    func setCloudSyncDisabled(
        _ command: LibraryRecordingCloudSyncCommand
    ) async throws -> LibraryRecordingSnapshot {
        try await store.setCloudSyncDisabled(command)
    }

    func setArchiveState(
        _ command: LibraryRecordingArchiveCommand
    ) async throws -> LibraryRecordingSnapshot {
        try await store.setArchiveState(command)
    }

    func upsertTranscript(
        _ command: LibraryTranscriptUpsertCommand
    ) async throws -> LibraryTranscriptSnapshot {
        try await store.upsertTranscript(command)
    }

    func upsertSummary(
        _ command: LibrarySummaryUpsertCommand
    ) async throws -> LibrarySummarySnapshot {
        try await store.upsertSummary(command)
    }

    func createProcessingJob(
        _ command: LibraryProcessingJobCreateCommand
    ) async throws -> LibraryProcessingJobSnapshot {
        try await store.createProcessingJob(command)
    }

    func updateProcessingJob(
        _ command: LibraryProcessingJobUpdateCommand
    ) async throws -> LibraryProcessingJobSnapshot {
        try await store.updateProcessingJob(command)
    }

    func deleteProcessingJob(
        _ command: LibraryProcessingJobDeleteCommand
    ) async throws -> LibraryProcessingJobSnapshot {
        try await store.deleteProcessingJob(command)
    }

    func deleteTerminalProcessingJobs(
        _ command: LibraryProcessingJobTerminalCleanupCommand
    ) async throws -> [LibraryProcessingJobSnapshot] {
        try await store.deleteTerminalProcessingJobs(command)
    }

    func recoverProcessingJobsAfterCrash(
        _ command: LibraryProcessingJobCrashRecoveryCommand
    ) async throws -> [LibraryProcessingJobSnapshot] {
        try await store.recoverProcessingJobsAfterCrash(command)
    }
}

extension SQLiteLibraryStore {
    private static let localOnlyRemovalKind = "localOnlyRemoval"

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
            isCloudSyncDisabled, lastModified
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

    private static func fetchUpdatedRecording(
        storageID: String,
        in database: Database
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
                operation: "rename recording",
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
