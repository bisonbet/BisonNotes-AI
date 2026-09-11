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
    let isCloudSyncDisabled: Bool?
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

/// Changes whether a recording participates in iCloud sync.
///
/// The command includes the pending local-only removal intent because those
/// two values must commit together. A caller may supply an expected source
/// revision when it is editing a snapshot that could have become stale.
struct LibraryRecordingCloudSyncCommand: Equatable, Sendable {
    let reference: LibraryRecordingReference
    let disabled: Bool
    let expectedLastModified: Date?
    let modifiedAt: Date
    let requestedAt: Date

    init(
        reference: LibraryRecordingReference,
        disabled: Bool,
        expectedLastModified: Date? = nil,
        modifiedAt: Date = Date(),
        requestedAt: Date? = nil
    ) {
        self.reference = reference
        self.disabled = disabled
        self.expectedLastModified = expectedLastModified
        self.modifiedAt = modifiedAt
        self.requestedAt = requestedAt ?? modifiedAt
    }
}

/// Stable identifiers used by processing-job commands.
struct LibraryProcessingJobReference: Equatable, Sendable {
    let storageID: String?
    let legacyID: String?

    init(storageID: String? = nil, legacyID: String? = nil) {
        self.storageID = storageID
        self.legacyID = legacyID
    }

    var displayValue: String {
        storageID ?? legacyID ?? "<missing processing-job identity>"
    }
}

/// Creates one processing job without exposing a managed object or SQLite
/// row to the caller. The optional recording reference is explicit: a job may
/// be created without a relationship for legacy/external callers, but a
/// supplied reference must resolve to exactly one recording.
struct LibraryProcessingJobCreateCommand: Equatable, Sendable {
    let id: UUID
    let jobType: String
    let engine: String
    let recordingURL: String
    let recordingName: String
    let modelName: String?
    let status: String
    let progress: Double
    let startTime: Date
    let completionTime: Date?
    let error: String?
    let recordingReference: LibraryRecordingReference?
    let modifiedAt: Date

    init(
        id: UUID,
        jobType: String,
        engine: String,
        recordingURL: String,
        recordingName: String,
        modelName: String? = nil,
        status: String,
        progress: Double,
        startTime: Date,
        completionTime: Date? = nil,
        error: String? = nil,
        recordingReference: LibraryRecordingReference? = nil,
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.jobType = jobType
        self.engine = engine
        self.recordingURL = recordingURL
        self.recordingName = recordingName
        self.modelName = modelName
        self.status = status
        self.progress = progress
        self.startTime = startTime
        self.completionTime = completionTime
        self.error = error
        self.recordingReference = recordingReference
        self.modifiedAt = modifiedAt
    }
}

extension LibraryProcessingJobCreateCommand {
    func validate() throws {
        let requiredText: [(String, String)] = [
            (jobType, "job type"),
            (engine, "engine"),
            (recordingURL, "recording URL"),
            (recordingName, "recording name"),
            (status, "status")
        ]
        for (value, field) in requiredText {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LibraryRepositoryError.invalidCommand(
                    "processing-job \(field) must not be empty"
                )
            }
        }

        guard progress.isFinite, (0...1).contains(progress) else {
            throw LibraryRepositoryError.invalidCommand(
                "processing-job progress must be finite and between 0 and 1"
            )
        }

        let dates = [
            startTime,
            completionTime,
            modifiedAt
        ]
        guard dates.compactMap({ $0 }).allSatisfy({
            $0.timeIntervalSinceReferenceDate.isFinite
        }) else {
            throw LibraryRepositoryError.invalidCommand(
                "processing-job dates must be finite"
            )
        }
    }
}

/// Describes how a processing-job error is changed by an update command.
enum LibraryProcessingJobErrorUpdate: Equatable, Sendable {
    case preserve
    case set(String?)
}

/// Describes how a processing-job completion timestamp is changed by an update
/// command. The explicit cases distinguish preserving an existing timestamp
/// from intentionally clearing one.
enum LibraryProcessingJobCompletionTimeUpdate: Equatable, Sendable {
    case preserve
    case set(Date?)
}

/// Updates the mutable state of a persisted processing job without exposing a
/// managed object or SQLite row to the caller.
struct LibraryProcessingJobUpdateCommand: Equatable, Sendable {
    let reference: LibraryProcessingJobReference
    let status: String
    let progress: Double
    let error: LibraryProcessingJobErrorUpdate
    let completionTime: LibraryProcessingJobCompletionTimeUpdate
    let expectedLastModified: Date?
    let modifiedAt: Date

    init(
        reference: LibraryProcessingJobReference,
        status: String,
        progress: Double,
        error: LibraryProcessingJobErrorUpdate = .preserve,
        completionTime: LibraryProcessingJobCompletionTimeUpdate = .preserve,
        expectedLastModified: Date? = nil,
        modifiedAt: Date = Date()
    ) {
        self.reference = reference
        self.status = status
        self.progress = progress
        self.error = error
        self.completionTime = completionTime
        self.expectedLastModified = expectedLastModified
        self.modifiedAt = modifiedAt
    }
}

/// Deletes one persisted processing job through its stable identity. The
/// optional revision guard prevents a cleanup pass from deleting a job that a
/// newer writer has already changed.
struct LibraryProcessingJobDeleteCommand: Equatable, Sendable {
    let reference: LibraryProcessingJobReference
    let expectedLastModified: Date?
    let deletedAt: Date

    init(
        reference: LibraryProcessingJobReference,
        expectedLastModified: Date? = nil,
        deletedAt: Date = Date()
    ) {
        self.reference = reference
        self.expectedLastModified = expectedLastModified
        self.deletedAt = deletedAt
    }
}

/// Deletes persisted processing jobs whose status is terminal. Status matching
/// is case-insensitive and whitespace-insensitive because legacy Core Data
/// rows use both lowercase and display-name values.
struct LibraryProcessingJobTerminalCleanupCommand: Equatable, Sendable {
    let statuses: [String]
    let deletedAt: Date

    init(
        statuses: [String] = ["completed", "failed", "cancelled"],
        deletedAt: Date = Date()
    ) {
        self.statuses = statuses
        self.deletedAt = deletedAt
    }
}

/// Marks a known set of jobs as failed after an app crash. Missing rows are
/// ignored so a retry is safe, while terminal rows are preserved if another
/// writer already completed or cancelled them.
struct LibraryProcessingJobCrashRecoveryCommand: Equatable, Sendable {
    let references: [LibraryProcessingJobReference]
    let failureMessage: String
    let modifiedAt: Date

    init(
        references: [LibraryProcessingJobReference],
        failureMessage: String,
        modifiedAt: Date = Date()
    ) {
        self.references = references
        self.failureMessage = failureMessage
        self.modifiedAt = modifiedAt
    }

    var status: String {
        "Failed"
    }
}

extension LibraryProcessingJobUpdateCommand {
    func validate() throws {
        guard !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibraryRepositoryError.invalidCommand(
                "processing-job status must not be empty"
            )
        }
        guard progress.isFinite, (0...1).contains(progress) else {
            throw LibraryRepositoryError.invalidCommand(
                "processing-job progress must be finite and between 0 and 1"
            )
        }

        let dates = [
            modifiedAt,
            expectedLastModified,
            completionDate(from: completionTime)
        ]
        guard dates.compactMap({ $0 }).allSatisfy({
            $0.timeIntervalSinceReferenceDate.isFinite
        }) else {
            throw LibraryRepositoryError.invalidCommand(
                "processing-job dates must be finite"
            )
        }
    }

    private func completionDate(
        from update: LibraryProcessingJobCompletionTimeUpdate
    ) -> Date? {
        guard case .set(let date) = update else { return nil }
        return date
    }
}

extension LibraryProcessingJobTerminalCleanupCommand {
    var normalizedStatuses: [String] {
        Array(
            Set(
                statuses.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }
            )
        )
        .sorted()
    }

    func validate() throws {
        guard !statuses.isEmpty else {
            throw LibraryRepositoryError.invalidCommand(
                "processing-job terminal cleanup requires at least one status"
            )
        }
        guard statuses.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw LibraryRepositoryError.invalidCommand(
                "processing-job terminal cleanup statuses must not be empty"
            )
        }
        guard deletedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw LibraryRepositoryError.invalidCommand(
                "processing-job terminal cleanup date must be finite"
            )
        }
    }
}

extension LibraryProcessingJobCrashRecoveryCommand {
    func validate() throws {
        guard !failureMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibraryRepositoryError.invalidCommand(
                "processing-job crash recovery requires a failure message"
            )
        }
        guard modifiedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw LibraryRepositoryError.invalidCommand(
                "processing-job crash recovery date must be finite"
            )
        }
        for reference in references {
            let storageID = reference.storageID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let legacyID = reference.legacyID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard storageID?.isEmpty == false || legacyID?.isEmpty == false else {
                throw LibraryRepositoryError.invalidCommand(
                    "processing-job crash recovery references must contain an ID"
                )
            }
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
protocol LibraryRepository: Sendable {
    func fetchRecordingSummaries() async throws -> [LibraryRecordingSnapshot]
    func fetchTranscriptSnapshots() async throws -> [LibraryTranscriptSnapshot]
    func fetchSummarySnapshots() async throws -> [LibrarySummarySnapshot]
    func fetchProcessingJobSnapshots() async throws -> [LibraryProcessingJobSnapshot]
    func fetchArchiveLocationSnapshots() async throws -> [LibraryArchiveLocationSnapshot]
    func fetchPendingCloudMutationSnapshots() async throws -> [LibraryPendingCloudMutationSnapshot]
    func renameRecording(_ command: LibraryRecordingRenameCommand) async throws -> LibraryRecordingSnapshot
    func setCloudSyncDisabled(
        _ command: LibraryRecordingCloudSyncCommand
    ) async throws -> LibraryRecordingSnapshot
    func createProcessingJob(
        _ command: LibraryProcessingJobCreateCommand
    ) async throws -> LibraryProcessingJobSnapshot
    func updateProcessingJob(
        _ command: LibraryProcessingJobUpdateCommand
    ) async throws -> LibraryProcessingJobSnapshot
    func deleteProcessingJob(
        _ command: LibraryProcessingJobDeleteCommand
    ) async throws -> LibraryProcessingJobSnapshot
    func deleteTerminalProcessingJobs(
        _ command: LibraryProcessingJobTerminalCleanupCommand
    ) async throws -> [LibraryProcessingJobSnapshot]
    func recoverProcessingJobsAfterCrash(
        _ command: LibraryProcessingJobCrashRecoveryCommand
    ) async throws -> [LibraryProcessingJobSnapshot]
}

enum LibraryRepositoryError: LocalizedError, Equatable {
    case invalidRecord(entity: String, field: String)
    case invalidCommand(String)
    case recordingNotFound(reference: String)
    case ambiguousRecording(reference: String)
    case staleRecording(reference: String, expected: Date?, actual: Date?)
    case processingJobAlreadyExists(reference: String)
    case processingJobNotFound(reference: String)
    case ambiguousProcessingJob(reference: String)
    case staleProcessingJob(reference: String, expected: Date?, actual: Date?)
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
        case .processingJobAlreadyExists(let reference):
            return "The processing job already exists: \(reference)"
        case .processingJobNotFound(let reference):
            return "The processing job could not be found: \(reference)"
        case .ambiguousProcessingJob(let reference):
            return "The processing-job identity is ambiguous: \(reference)"
        case .staleProcessingJob(let reference, let expected, let actual):
            return "The processing job changed before it could be updated (\(reference)); "
                + "expected last modified \(String(describing: expected)), "
                + "found \(String(describing: actual))."
        case .writeFailed(let operation, let reason):
            return "The library could not complete \(operation): \(reason)"
        }
    }
}
