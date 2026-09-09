import Foundation
import GRDB

enum SQLiteMigrationSourceEntity: String, CaseIterable, Hashable, Sendable {
    case recordings
    case summaries
    case transcripts
    case processingJobs = "processing_jobs"
    case archiveLocations = "archive_locations"
    case pendingCloudMutations = "pending_cloud_mutations"

    var destinationColumns: Set<String> {
        switch self {
        case .recordings:
            return [
                "storageID", "audioQuality", "createdAt", "duration", "fileSize", "id",
                "isCloudSyncDisabled", "lastModified", "locationAccuracy", "locationAddress",
                "locationLatitude", "locationLongitude", "locationTimestamp", "recordingDate",
                "recordingName", "recordingURL", "summaryId", "summaryStatus", "transcriptId",
                "transcriptionStatus", "isArchived", "archivedAt", "archiveNote"
            ]
        case .summaries:
            return [
                "storageID", "aiMethod", "compressionRatio", "confidence", "contentType",
                "generatedAt", "id", "originalLength", "processingTime", "recordingStorageID",
                "recordingId", "reminders", "summary", "tasks", "titles", "transcriptStorageID",
                "transcriptId", "version", "wordCount"
            ]
        case .transcripts:
            return [
                "storageID", "confidence", "createdAt", "engine", "id", "lastModified",
                "processingTime", "recordingStorageID", "recordingId", "segments", "speakerMappings"
            ]
        case .processingJobs:
            return [
                "storageID", "completionTime", "engine", "error", "id", "jobType", "lastModified",
                "modelName", "progress", "recordingName", "recordingURL", "recordingStorageID",
                "startTime", "status"
            ]
        case .archiveLocations:
            return [
                "storageID", "bookmarkData", "destinationURLString", "displayName", "exportedAt",
                "exportedFilename", "fileSize", "id", "lastVerifiedAt", "providerDisplayName",
                "recordingId", "status"
            ]
        case .pendingCloudMutations:
            return [
                "storageID", "kind", "payload", "recordingId", "requestedAt", "targetId", "version"
            ]
        }
    }
}

enum SQLiteMigrationValue: Equatable, Sendable {
    case null
    case text(String)
    case integer(Int64)
    case real(Double)
    case blob(Data)
    case boolean(Bool)

    var databaseValue: DatabaseValue {
        switch self {
        case .null:
            return .null
        case .text(let value):
            return value.databaseValue
        case .integer(let value):
            return value.databaseValue
        case .real(let value):
            return value.databaseValue
        case .blob(let value):
            return value.databaseValue
        case .boolean(let value):
            return Int64(value ? 1 : 0).databaseValue
        }
    }

    init(databaseValue: DatabaseValue) {
        switch databaseValue.storage {
        case .null:
            self = .null
        case .int64(let value):
            self = .integer(value)
        case .double(let value):
            self = .real(value)
        case .string(let value):
            self = .text(value)
        case .blob(let value):
            self = .blob(value)
        }
    }
}

struct SQLiteMigrationExpectedRow: Equatable, Sendable {
    let entity: SQLiteMigrationSourceEntity
    let sourceObjectID: String
    let destinationStorageID: String
    let values: [String: SQLiteMigrationValue]
}

struct SQLiteMigrationSourceSnapshot: Equatable, Sendable {
    let sourceModel: String
    let sourceFingerprint: String
    let migrationRunID: String?
    let rows: [SQLiteMigrationExpectedRow]
}

enum SQLiteMigrationVerificationMismatchKind: String, Equatable, Sendable {
    case migrationRun
    case missingRow
    case unexpectedRow
    case valueMismatch
}

struct SQLiteMigrationVerificationMismatch: Equatable, Sendable {
    let kind: SQLiteMigrationVerificationMismatchKind
    let entity: SQLiteMigrationSourceEntity?
    let storageID: String
    let column: String?
    let expected: SQLiteMigrationValue?
    let actual: SQLiteMigrationValue?
    let detail: String
}

struct SQLiteMigrationVerificationReport: Equatable, Sendable {
    let sourceFingerprint: String
    let expectedRowCount: Int
    let verifiedRowCount: Int
    let mismatches: [SQLiteMigrationVerificationMismatch]

    var isValid: Bool {
        verifiedRowCount == expectedRowCount && mismatches.isEmpty
    }
}

enum SQLiteMigrationVerificationError: LocalizedError, Equatable {
    case invalidDatabaseURL
    case databaseNotFound(URL)
    case invalidSnapshot(String)
    case unsupportedSchema(String)

    var errorDescription: String? {
        switch self {
        case .invalidDatabaseURL:
            return "The SQLite verification database URL is invalid."
        case .databaseNotFound(let url):
            return "The SQLite verification database does not exist: \(url.path)"
        case .invalidSnapshot(let detail):
            return "The SQLite source snapshot is invalid: \(detail)"
        case .unsupportedSchema(let detail):
            return "The SQLite verification schema is unsupported: \(detail)"
        }
    }
}
