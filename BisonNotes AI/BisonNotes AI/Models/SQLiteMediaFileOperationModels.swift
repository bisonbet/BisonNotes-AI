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
    }
}

/// The durable state of one media operation.
struct SQLiteMediaFileOperation: Equatable, Sendable {
    let id: String
    let assetID: String?
    let sourceTransferID: String?
    let operation: String
    let state: String
    let ownerStorageID: String?
    let ownerRevision: Int?
    let sourceRoot: String?
    let sourceRelativePath: String?
    let destinationRoot: String?
    let destinationRelativePath: String?
    let expectedByteLength: Int64?
    let expectedSHA256: String?
    let attemptCount: Int
    let lastError: String?
    let createdAt: Date
    let updatedAt: Date
}

enum SQLiteMediaFileOperationError: LocalizedError, Equatable {
    case invalidIdentifier
    case invalidRoot
    case invalidRelativePath
    case invalidByteLength
    case invalidSHA256
    case invalidBatchLimit
    case operationNotFound
    case operationConflict
    case unsupportedOperation
    case sourceMissing
    case destinationConflict
    case integrityMismatch
    case copyFailed

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

    static func batchLimit(_ value: Int) throws {
        guard (1...100).contains(value) else {
            throw SQLiteMediaFileOperationError.invalidBatchLimit
        }
    }
}
