import Foundation

/// A root-relative, checksum-bound media install request.
///
/// The roots are logical identifiers persisted in SQLite; callers resolve them
/// to current sandbox URLs only while executing the operation. Absolute paths
/// never cross this boundary.
struct SQLiteMediaCopyPlan: Equatable, Sendable {
    let operationID: String
    let assetID: String
    let ownerStorageID: String?
    let ownerRevision: Int?
    let sourceRoot: String
    let sourceRelativePath: String
    let destinationRoot: String
    let destinationRelativePath: String
    let expectedByteLength: Int64
    let expectedSHA256: String

    /// A small, caller-owned descriptor used to reconstruct the metadata
    /// acknowledgement after a process restart. This is deliberately not an
    /// audio payload; the media bytes remain in the source/destination files.
    let metadataPayload: Data?

    init(
        operationID: String,
        assetID: String,
        ownerStorageID: String?,
        ownerRevision: Int?,
        sourceRoot: String,
        sourceRelativePath: String,
        destinationRoot: String,
        destinationRelativePath: String,
        expectedByteLength: Int64,
        expectedSHA256: String,
        metadataPayload: Data? = nil
    ) {
        self.operationID = operationID
        self.assetID = assetID
        self.ownerStorageID = ownerStorageID
        self.ownerRevision = ownerRevision
        self.sourceRoot = sourceRoot
        self.sourceRelativePath = sourceRelativePath
        self.destinationRoot = destinationRoot
        self.destinationRelativePath = destinationRelativePath
        self.expectedByteLength = expectedByteLength
        self.expectedSHA256 = expectedSHA256
        self.metadataPayload = metadataPayload
    }

    func validate() throws {
        try SQLiteMediaFileOperationValidation.identifier(operationID)
        try SQLiteMediaFileOperationValidation.identifier(assetID)
        try SQLiteMediaFileOperationValidation.root(sourceRoot)
        try SQLiteMediaFileOperationValidation.root(destinationRoot)
        try SQLiteMediaFileOperationValidation.relativePath(sourceRelativePath)
        try SQLiteMediaFileOperationValidation.relativePath(destinationRelativePath)
        guard expectedByteLength >= 0 else {
            throw SQLiteMediaFileOperationError.invalidByteLength
        }
        try SQLiteMediaFileOperationValidation.sha256(expectedSHA256)
        try SQLiteMediaFileOperationValidation.metadataPayload(metadataPayload)
    }
}

/// The durable state of one media operation.
struct SQLiteMediaFileOperation: Equatable, Sendable {
    let id: String
    let assetID: String?
    let sourceTransferID: String?
    let operation: String
    let state: String
    let metadataState: String
    let metadataAcknowledgedAt: Date?
    let ownerStorageID: String?
    let ownerRevision: Int?
    let sourceRoot: String?
    let sourceRelativePath: String?
    let destinationRoot: String?
    let destinationRelativePath: String?
    let expectedByteLength: Int64?
    let expectedSHA256: String?
    let metadataPayload: Data?
    let attemptCount: Int
    let lastError: String?
    let createdAt: Date
    let updatedAt: Date
}

enum SQLiteMediaMetadataState {
    static let pending = "pending"
    static let committing = "committing"
    static let failed = "failed"
    static let committed = "committed"

    /// Rows created before the metadata acknowledgement boundary retain their
    /// historical copy/receipt semantics after the schema upgrade. They are
    /// never assigned a synthetic acknowledgement timestamp.
    static let legacy = "legacy"

    static let all: Set<String> = [
        pending,
        committing,
        failed,
        committed,
        legacy
    ]
}

enum SQLiteMediaFileOperationError: LocalizedError, Equatable {
    case invalidIdentifier
    case invalidRoot
    case invalidRelativePath
    case invalidByteLength
    case invalidSHA256
    case invalidMetadataPayload
    case invalidBatchLimit
    case operationNotFound
    case operationConflict
    case unsupportedOperation
    case sourceMissing
    case destinationConflict
    case integrityMismatch
    case copyFailed
    case metadataAcknowledgementRequired

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            return "The media operation identifier is invalid."
        case .invalidRoot:
            return "The media operation root identifier is invalid."
        case .invalidRelativePath:
            return "The media operation path is invalid."
        case .invalidByteLength:
            return "The media operation byte length is invalid."
        case .invalidSHA256:
            return "The media operation checksum is invalid."
        case .invalidMetadataPayload:
            return "The media operation metadata descriptor is too large."
        case .invalidBatchLimit:
            return "The media operation batch limit is invalid."
        case .operationNotFound:
            return "The media operation was not found."
        case .operationConflict:
            return "The media operation conflicts with an existing operation."
        case .unsupportedOperation:
            return "The media operation type is unsupported."
        case .sourceMissing:
            return "The media source is unavailable."
        case .destinationConflict:
            return "The media destination contains different content."
        case .integrityMismatch:
            return "The copied media failed integrity verification."
        case .copyFailed:
            return "The media copy could not be completed."
        case .metadataAcknowledgementRequired:
            return "The media metadata acknowledgement is required before the transfer can complete."
        }
    }
}

enum SQLiteMediaFileOperationValidation {
    static func identifier(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.contains("\0") else {
            throw SQLiteMediaFileOperationError.invalidIdentifier
        }
    }

    static func root(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains("\0") else {
            throw SQLiteMediaFileOperationError.invalidRoot
        }
    }

    static func relativePath(_ value: String) throws {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.isEmpty,
              !value.hasPrefix("/"),
              !value.contains("\\"),
              !value.contains("\0"),
              components.allSatisfy({ $0 != "." && $0 != ".." && !$0.isEmpty }) else {
            throw SQLiteMediaFileOperationError.invalidRelativePath
        }
    }

    static func sha256(_ value: String) throws {
        let normalized = value.lowercased()
        guard normalized.count == 64,
              normalized.allSatisfy({ $0.isHexDigit }) else {
            throw SQLiteMediaFileOperationError.invalidSHA256
        }
    }

    static func metadataPayload(_ value: Data?) throws {
        guard let value else { return }
        guard value.count <= 64 * 1024 else {
            throw SQLiteMediaFileOperationError.invalidMetadataPayload
        }
    }

    static func batchLimit(_ value: Int) throws {
        guard (1...100).contains(value) else {
            throw SQLiteMediaFileOperationError.invalidBatchLimit
        }
    }
}

/// A root-relative archive restore request.
///
/// Archive locations are resolved from a security-scoped bookmark by the
/// eventual application caller. Only the logical roots and relative paths are
/// persisted here, so a container relocation or bookmark refresh never writes
/// an absolute provider path into the SQLite journal.
struct SQLiteArchiveRestorePlan: Equatable, Sendable {
    let operationID: String
    let archiveLocationID: String
    let ownerStorageID: String?
    let ownerRevision: Int?
    /// The source recording's optimistic date at enqueue time. Unlike the
    /// integer owner revision used by generic media plans, this value can be
    /// compared by the Core Data metadata acknowledgement after a restart.
    let ownerLastModified: Date?
    let sourceRoot: String
    let sourceRelativePath: String
    let destinationRoot: String
    let destinationRelativePath: String
    let expectedByteLength: Int64
    let expectedSHA256: String

    init(
        operationID: String,
        archiveLocationID: String,
        ownerStorageID: String?,
        ownerRevision: Int?,
        ownerLastModified: Date? = nil,
        sourceRoot: String,
        sourceRelativePath: String,
        destinationRoot: String,
        destinationRelativePath: String,
        expectedByteLength: Int64,
        expectedSHA256: String
    ) {
        self.operationID = operationID
        self.archiveLocationID = archiveLocationID
        self.ownerStorageID = ownerStorageID
        self.ownerRevision = ownerRevision
        self.ownerLastModified = ownerLastModified
        self.sourceRoot = sourceRoot
        self.sourceRelativePath = sourceRelativePath
        self.destinationRoot = destinationRoot
        self.destinationRelativePath = destinationRelativePath
        self.expectedByteLength = expectedByteLength
        self.expectedSHA256 = expectedSHA256
    }

    func validate() throws {
        try SQLiteMediaFileOperationValidation.identifier(operationID)
        try SQLiteMediaFileOperationValidation.identifier(archiveLocationID)
        if let ownerStorageID {
            try SQLiteMediaFileOperationValidation.identifier(ownerStorageID)
        }
        if let ownerRevision {
            guard ownerRevision >= 0 else {
                throw SQLiteArchiveRestoreError.invalidOwnerRevision
            }
        }
        if let ownerLastModified {
            guard ownerLastModified.timeIntervalSinceReferenceDate.isFinite else {
                throw SQLiteArchiveRestoreError.invalidOwnerRevision
            }
        }
        try SQLiteMediaFileOperationValidation.root(sourceRoot)
        try SQLiteMediaFileOperationValidation.root(destinationRoot)
        try SQLiteMediaFileOperationValidation.relativePath(sourceRelativePath)
        try SQLiteMediaFileOperationValidation.relativePath(destinationRelativePath)
        guard expectedByteLength >= 0 else {
            throw SQLiteMediaFileOperationError.invalidByteLength
        }
        try SQLiteMediaFileOperationValidation.sha256(expectedSHA256)
    }
}

/// Durable phases for a provider archive restore.
///
/// The metadata acknowledgement is intentionally a separate phase. The
/// destination file may be safely retained while a Core Data or SQLite
/// recording-link transaction is retried, and source deletion is never
/// attempted until that acknowledgement is durable.
struct SQLiteArchiveRestoreOperation: Equatable, Sendable {
    let id: String
    let archiveLocationID: String
    let ownerStorageID: String?
    let ownerRevision: Int?
    let ownerLastModified: Date?
    let sourceRoot: String
    let sourceRelativePath: String
    let destinationRoot: String
    let destinationRelativePath: String
    let expectedByteLength: Int64
    let expectedSHA256: String
    let phase: String
    let attemptCount: Int
    let lastError: String?
    let createdAt: Date
    let updatedAt: Date
}

enum SQLiteArchiveRestoreError: LocalizedError, Equatable {
    case invalidOwnerRevision
    case invalidBatchLimit
    case operationNotFound
    case operationConflict
    case unsupportedPhase
    case sourceMissing
    case sourceNotRegularFile
    case sourceDestinationAlias
    case destinationConflict
    case integrityMismatch
    case copyFailed
    case sourceDeletionFailed

    var errorDescription: String? {
        switch self {
        case .invalidOwnerRevision:
            return "The archive restore owner revision is invalid."
        case .invalidBatchLimit:
            return "The archive restore batch limit is invalid."
        case .operationNotFound:
            return "The archive restore operation was not found."
        case .operationConflict:
            return "The archive restore operation is in an incompatible phase."
        case .unsupportedPhase:
            return "The archive restore phase is unsupported."
        case .sourceMissing:
            return "The archived audio source is unavailable."
        case .sourceNotRegularFile:
            return "The archived audio source is not a regular file."
        case .sourceDestinationAlias:
            return "The archive source and local destination must remain distinct."
        case .destinationConflict:
            return "The local restore destination contains different content."
        case .integrityMismatch:
            return "The archive restore file failed integrity verification."
        case .copyFailed:
            return "The archive restore copy could not be completed."
        case .sourceDeletionFailed:
            return "The archived source could not be removed."
        }
    }
}

enum SQLiteArchiveRestorePhase {
    static let pending = "pending"
    static let copying = "copying"
    static let copyFailed = "copyFailed"
    static let copied = "copied"
    static let committingMetadata = "committingMetadata"
    static let metadataFailed = "metadataFailed"
    static let metadataCommitted = "metadataCommitted"
    static let deletingSource = "deletingSource"
    static let sourceDeletionFailed = "sourceDeletionFailed"
    static let completed = "completed"

    static let all: Set<String> = [
        pending,
        copying,
        copyFailed,
        copied,
        committingMetadata,
        metadataFailed,
        metadataCommitted,
        deletingSource,
        sourceDeletionFailed,
        completed
    ]

    static let retryable: Set<String> = [
        pending,
        copyFailed,
        copied,
        metadataFailed,
        metadataCommitted,
        sourceDeletionFailed
    ]
}
