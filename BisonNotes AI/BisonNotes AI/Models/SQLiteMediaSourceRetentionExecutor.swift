import CryptoKit
import Foundation

enum SQLiteMediaSourceRetentionError: LocalizedError, Equatable {
    case operationNotFound
    case sourceNotEligible
    case sourceDestinationAlias
    case sourceRemovalFailed

    var errorDescription: String? {
        switch self {
        case .operationNotFound:
            return "The media operation was not found."
        case .sourceNotEligible:
            return "The media source is not eligible for removal."
        case .sourceDestinationAlias:
            return "The media source and destination must remain distinct."
        case .sourceRemovalFailed:
            return "The verified media source could not be removed."
        }
    }
}

/// Applies an already-approved retention decision to one source file.
///
/// The operation must be completed and its committed receipt must name the
/// same destination asset. Removal is idempotent when the source is already
/// absent, and no raw filesystem error is retained or surfaced.
struct SQLiteMediaSourceRetentionExecutor: Sendable {
    let store: SQLiteLibraryStore
    let rootRegistry: SQLiteMediaRootRegistry

    func removeSourceIfEligible(
        sourceTransferID: String,
        operationID: String,
        fileManager: FileManager = .default
    ) async throws -> SQLiteMediaFileOperation {
        try SQLiteImportReceiptValidation.identifier(sourceTransferID)
        try SQLiteMediaFileOperationValidation.identifier(operationID)
        guard let operation = try await store.mediaFileOperation(id: operationID) else {
            throw SQLiteMediaSourceRetentionError.operationNotFound
        }
        let receipt = try await store.importReceipt(
            sourceTransferID: sourceTransferID
        )
        guard try SQLiteMediaSourceRetentionPolicy.disposition(
            sourceTransferID: sourceTransferID,
            operation: operation,
            receipt: receipt
        ) == .eligibleForRemoval else {
            throw SQLiteMediaSourceRetentionError.sourceNotEligible
        }
        guard operation.sourceTransferID == sourceTransferID else {
            throw SQLiteMediaSourceRetentionError.sourceNotEligible
        }
        let urls = try Self.resolveURLs(for: operation, using: rootRegistry)
        guard urls.source.resolvingSymlinksInPath().standardizedFileURL
                != urls.destination.resolvingSymlinksInPath().standardizedFileURL else {
            throw SQLiteMediaSourceRetentionError.sourceDestinationAlias
        }
        guard let expectedByteLength = operation.expectedByteLength,
              let expectedSHA256 = operation.expectedSHA256,
              Self.destinationMatches(
                  urls.destination,
                  expectedByteLength: expectedByteLength,
                  expectedSHA256: expectedSHA256,
                  fileManager: fileManager
              ) else {
            throw SQLiteMediaSourceRetentionError.sourceNotEligible
        }
        try Self.removeSourceIfPresent(at: urls.source, using: fileManager)
        return operation
    }
}

private extension SQLiteMediaSourceRetentionExecutor {
    static func resolveURLs(
        for operation: SQLiteMediaFileOperation,
        using rootRegistry: SQLiteMediaRootRegistry
    ) throws -> (source: URL, destination: URL) {
        guard let sourceRoot = operation.sourceRoot,
              let sourceRelativePath = operation.sourceRelativePath,
              let destinationRoot = operation.destinationRoot,
              let destinationRelativePath = operation.destinationRelativePath else {
            throw SQLiteMediaSourceRetentionError.sourceNotEligible
        }
        do {
            return (
                source: try rootRegistry.sourceURL(
                    root: sourceRoot,
                    relativePath: sourceRelativePath
                ),
                destination: try rootRegistry.destinationURL(
                    root: destinationRoot,
                    relativePath: destinationRelativePath
                )
            )
        } catch {
            throw SQLiteMediaSourceRetentionError.sourceNotEligible
        }
    }

    static func removeSourceIfPresent(
        at sourceURL: URL,
        using fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: sourceURL.path) else { return }
        do {
            let values = try sourceURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw SQLiteMediaSourceRetentionError.sourceNotEligible
            }
            try fileManager.removeItem(at: sourceURL)
        } catch let error as SQLiteMediaSourceRetentionError {
            throw error
        } catch {
            throw SQLiteMediaSourceRetentionError.sourceRemovalFailed
        }
    }

    static func destinationMatches(
        _ destinationURL: URL,
        expectedByteLength: Int64,
        expectedSHA256: String,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.fileExists(atPath: destinationURL.path) else {
            return false
        }
        do {
            let values = try destinationURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                return false
            }
            let fingerprint = try fingerprint(at: destinationURL)
            return fingerprint.byteLength == expectedByteLength &&
                fingerprint.sha256 == expectedSHA256.lowercased()
        } catch {
            return false
        }
    }

    static func fingerprint(
        at url: URL
    ) throws -> (byteLength: Int64, sha256: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var byteLength: Int64 = 0
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            digest.update(data: chunk)
            byteLength += Int64(chunk.count)
        }
        let digestBytes = digest.finalize()
        return (
            byteLength: byteLength,
            sha256: digestBytes.map { String(format: "%02x", $0) }.joined()
        )
    }
}
