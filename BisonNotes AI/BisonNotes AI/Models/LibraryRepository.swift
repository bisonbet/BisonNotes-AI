import Foundation

/// Storage-neutral recording values returned by the first repository boundary.
///
/// The snapshot deliberately contains values that can be copied out of either
/// Core Data or SQLite. It does not expose managed objects, GRDB rows, or
/// mutable relationships to callers.
struct LibraryRecordingSnapshot: Equatable, Sendable {
    let storageID: String
    let legacyID: String?
    let name: String?
    let recordingDate: Date?
    let duration: Double?
    let fileSize: Int64?
    let recordingURL: String?
    let isArchived: Bool?
    let lastModified: Date?

    static func stableOrder(
        _ lhs: LibraryRecordingSnapshot,
        _ rhs: LibraryRecordingSnapshot
    ) -> Bool {
        switch (lhs.recordingDate, rhs.recordingDate) {
        case let (leftDate?, rightDate?) where leftDate != rightDate:
            return leftDate < rightDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.storageID < rhs.storageID
        }
    }
}

struct LibraryTranscriptSnapshot: Equatable, Sendable {
    let storageID: String
    let legacyID: String?
    let confidence: Double?
    let createdAt: Date?
    let engine: String?
    let lastModified: Date?
    let processingTime: Double?
    let recordingStorageID: String?
    let recordingLegacyID: String?
    let segments: String?
    let speakerMappings: String?
}

struct LibrarySummarySnapshot: Equatable, Sendable {
    let storageID: String
    let aiMethod: String?
    let compressionRatio: Double?
    let confidence: Double?
    let contentType: String?
    let generatedAt: Date?
    let legacyID: String?
    let originalLength: Int64?
    let processingTime: Double?
    let recordingStorageID: String?
    let recordingLegacyID: String?
    let reminders: String?
    let summary: String?
    let tasks: String?
    let titles: String?
    let transcriptStorageID: String?
    let transcriptLegacyID: String?
    let version: Int64?
    let wordCount: Int64?
}

struct LibraryProcessingJobSnapshot: Equatable, Sendable {
    let storageID: String
    let completionTime: Date?
    let engine: String?
    let error: String?
    let legacyID: String?
    let jobType: String?
    let lastModified: Date?
    let modelName: String?
    let progress: Double?
    let recordingName: String?
    let recordingURL: String?
    let recordingStorageID: String?
    let startTime: Date?
    let status: String?
}

struct LibraryArchiveLocationSnapshot: Equatable, Sendable {
    let storageID: String
    let bookmarkData: Data?
    let destinationURLString: String?
    let displayName: String?
    let exportedAt: Date?
    let exportedFilename: String?
    let fileSize: Int64?
    let legacyID: String?
    let lastVerifiedAt: Date?
    let providerDisplayName: String?
    let recordingLegacyID: String?
    let status: String?
}

struct LibraryPendingCloudMutationSnapshot: Equatable, Sendable {
    let storageID: String
    let kind: String?
    let payload: Data?
    let recordingLegacyID: String?
    let requestedAt: Date?
    let targetID: String?
    let version: Int64?
}

/// The deliberately small read-only contract used while the migration is
/// being introduced. Existing Core Data callers remain authoritative until a
/// later checkpoint wires this capability into application startup.
protocol LibraryRepository {
    func fetchRecordingSummaries() async throws -> [LibraryRecordingSnapshot]
    func fetchTranscriptSnapshots() async throws -> [LibraryTranscriptSnapshot]
    func fetchSummarySnapshots() async throws -> [LibrarySummarySnapshot]
    func fetchProcessingJobSnapshots() async throws -> [LibraryProcessingJobSnapshot]
    func fetchArchiveLocationSnapshots() async throws -> [LibraryArchiveLocationSnapshot]
    func fetchPendingCloudMutationSnapshots() async throws -> [LibraryPendingCloudMutationSnapshot]
}

enum LibraryRepositoryError: LocalizedError, Equatable {
    case invalidRecord(entity: String, field: String)

    var errorDescription: String? {
        switch self {
        case .invalidRecord(let entity, let field):
            return "The \(entity) record has an invalid \(field) value."
        }
    }
}
