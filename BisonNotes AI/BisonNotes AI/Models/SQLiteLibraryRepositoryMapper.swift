import Foundation
import GRDB

enum SQLiteLibraryRepositoryMapper {
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
            isCloudSyncDisabled: (row["isCloudSyncDisabled"] as Int64?).map { $0 != 0 },
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
