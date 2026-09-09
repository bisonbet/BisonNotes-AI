import Foundation
import GRDB

/// Read-only repository adapter for the app-owned SQLite generation.
///
/// This adapter is intentionally not connected to production app startup yet.
/// It provides the storage-neutral boundary and contract-test target needed
/// before any caller is moved away from Core Data.
struct SQLiteLibraryRepository: LibraryRepository, Sendable {
    let store: SQLiteLibraryStore

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
}

extension SQLiteLibraryStore {
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

private enum SQLiteLibraryRepositoryMapper {
    static func snapshot(from row: Row) throws -> LibraryRecordingSnapshot {
        guard let storageID: String = row["storageID"], !storageID.isEmpty else {
            throw LibraryRepositoryError.invalidRecord(
                entity: "recordings",
                field: "storageID"
            )
        }

        let archivedValue: Int64? = row["isArchived"]
        return LibraryRecordingSnapshot(
            storageID: storageID,
            legacyID: row["id"],
            name: row["recordingName"],
            recordingDate: date(from: row["recordingDate"]),
            duration: row["duration"],
            fileSize: row["fileSize"],
            recordingURL: row["recordingURL"],
            isArchived: archivedValue.map { $0 != 0 },
            lastModified: date(from: row["lastModified"])
        )
    }

    static func transcript(from row: Row) throws -> LibraryTranscriptSnapshot {
        let storageID = try requireStorageID(from: row, entity: "transcripts")
        return LibraryTranscriptSnapshot(
            storageID: storageID,
            legacyID: row["id"],
            confidence: row["confidence"],
            createdAt: date(from: row["createdAt"]),
            engine: row["engine"],
            lastModified: date(from: row["lastModified"]),
            processingTime: row["processingTime"],
            recordingStorageID: row["recordingStorageID"],
            recordingLegacyID: row["recordingId"],
            segments: row["segments"],
            speakerMappings: row["speakerMappings"]
        )
    }

    static func summary(from row: Row) throws -> LibrarySummarySnapshot {
        let storageID = try requireStorageID(from: row, entity: "summaries")
        return LibrarySummarySnapshot(
            storageID: storageID,
            aiMethod: row["aiMethod"],
            compressionRatio: row["compressionRatio"],
            confidence: row["confidence"],
            contentType: row["contentType"],
            generatedAt: date(from: row["generatedAt"]),
            legacyID: row["id"],
            originalLength: row["originalLength"],
            processingTime: row["processingTime"],
            recordingStorageID: row["recordingStorageID"],
            recordingLegacyID: row["recordingId"],
            reminders: row["reminders"],
            summary: row["summary"],
            tasks: row["tasks"],
            titles: row["titles"],
            transcriptStorageID: row["transcriptStorageID"],
            transcriptLegacyID: row["transcriptId"],
            version: row["version"],
            wordCount: row["wordCount"]
        )
    }

    static func processingJob(from row: Row) throws -> LibraryProcessingJobSnapshot {
        let storageID = try requireStorageID(from: row, entity: "processing_jobs")
        return LibraryProcessingJobSnapshot(
            storageID: storageID,
            completionTime: date(from: row["completionTime"]),
            engine: row["engine"],
            error: row["error"],
            legacyID: row["id"],
            jobType: row["jobType"],
            lastModified: date(from: row["lastModified"]),
            modelName: row["modelName"],
            progress: row["progress"],
            recordingName: row["recordingName"],
            recordingURL: row["recordingURL"],
            recordingStorageID: row["recordingStorageID"],
            startTime: date(from: row["startTime"]),
            status: row["status"]
        )
    }

    static func archiveLocation(from row: Row) throws -> LibraryArchiveLocationSnapshot {
        let storageID = try requireStorageID(from: row, entity: "archive_locations")
        return LibraryArchiveLocationSnapshot(
            storageID: storageID,
            bookmarkData: row["bookmarkData"],
            destinationURLString: row["destinationURLString"],
            displayName: row["displayName"],
            exportedAt: date(from: row["exportedAt"]),
            exportedFilename: row["exportedFilename"],
            fileSize: row["fileSize"],
            legacyID: row["id"],
            lastVerifiedAt: date(from: row["lastVerifiedAt"]),
            providerDisplayName: row["providerDisplayName"],
            recordingLegacyID: row["recordingId"],
            status: row["status"]
        )
    }

    static func pendingCloudMutation(from row: Row) throws -> LibraryPendingCloudMutationSnapshot {
        let storageID = try requireStorageID(
            from: row,
            entity: "pending_cloud_mutations"
        )
        return LibraryPendingCloudMutationSnapshot(
            storageID: storageID,
            kind: row["kind"],
            payload: row["payload"],
            recordingLegacyID: row["recordingId"],
            requestedAt: date(from: row["requestedAt"]),
            targetID: row["targetId"],
            version: row["version"]
        )
    }

    private static func requireStorageID(
        from row: Row,
        entity: String
    ) throws -> String {
        guard let storageID: String = row["storageID"], !storageID.isEmpty else {
            throw LibraryRepositoryError.invalidRecord(
                entity: entity,
                field: "storageID"
            )
        }
        return storageID
    }

    private static func date(from value: Double?) -> Date? {
        value.map(Date.init(timeIntervalSinceReferenceDate:))
    }
}
