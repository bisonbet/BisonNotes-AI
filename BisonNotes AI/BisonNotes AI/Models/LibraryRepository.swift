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

/// Stable identifiers used by repository commands.
///
/// Existing Core Data rows are addressed by their legacy UUID, while the
/// app-owned SQLite generation also has an independent storage ID. Commands
/// may carry either or both so adapters can resolve the same operation without
/// exposing managed objects or database rows to callers.
struct LibraryRecordingReference: Equatable, Sendable {
    let storageID: String?
    let legacyID: String?

    init(storageID: String? = nil, legacyID: String? = nil) {
        self.storageID = storageID
        self.legacyID = legacyID
    }

    var displayValue: String {
        storageID ?? legacyID ?? "<missing recording identity>"
    }
}

/// The first write command shared by the Core Data and SQLite adapters.
///
/// `expectedLastModified` is an optimistic-concurrency guard. A nil value
/// means the caller intentionally accepts the current revision. The timestamp
/// is supplied by the caller so tests and future coordinators can make the
/// commit deterministic without creating time-dependent work inside a write
/// transaction.
struct LibraryRecordingRenameCommand: Equatable, Sendable {
    let reference: LibraryRecordingReference
    let name: String
    let expectedLastModified: Date?
    let modifiedAt: Date

    init(
        reference: LibraryRecordingReference,
        name: String,
        expectedLastModified: Date? = nil,
        modifiedAt: Date = Date()
    ) {
        self.reference = reference
        self.name = name
        self.expectedLastModified = expectedLastModified
        self.modifiedAt = modifiedAt
    }

    /// Preserve the existing Watch-import cleanup rule at the domain boundary
    /// so both backends apply the same behavior.
    var normalizedName: String {
        name.replacingOccurrences(of: " [Watch]", with: "")
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
protocol LibraryRepository: Sendable {
    func fetchRecordingSummaries() async throws -> [LibraryRecordingSnapshot]
    func fetchTranscriptSnapshots() async throws -> [LibraryTranscriptSnapshot]
    func fetchSummarySnapshots() async throws -> [LibrarySummarySnapshot]
    func fetchProcessingJobSnapshots() async throws -> [LibraryProcessingJobSnapshot]
    func fetchArchiveLocationSnapshots() async throws -> [LibraryArchiveLocationSnapshot]
    func fetchPendingCloudMutationSnapshots() async throws -> [LibraryPendingCloudMutationSnapshot]
    func renameRecording(_ command: LibraryRecordingRenameCommand) async throws -> LibraryRecordingSnapshot
}

enum LibraryRepositoryError: LocalizedError, Equatable {
    case invalidRecord(entity: String, field: String)
    case invalidCommand(String)
    case recordingNotFound(reference: String)
    case ambiguousRecording(reference: String)
    case staleRecording(reference: String, expected: Date?, actual: Date?)
    case writeFailed(operation: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidRecord(let entity, let field):
            return "The \(entity) record has an invalid \(field) value."
        case .invalidCommand(let detail):
            return "The library command is invalid: \(detail)"
        case .recordingNotFound(let reference):
            return "The recording could not be found: \(reference)"
        case .ambiguousRecording(let reference):
            return "The recording identity is ambiguous: \(reference)"
        case .staleRecording(let reference, let expected, let actual):
            return "The recording changed before it could be updated (\(reference)); "
                + "expected last modified \(String(describing: expected)), "
                + "found \(String(describing: actual))."
        case .writeFailed(let operation, let reason):
            return "The library could not complete \(operation): \(reason)"
        }
    }
}
