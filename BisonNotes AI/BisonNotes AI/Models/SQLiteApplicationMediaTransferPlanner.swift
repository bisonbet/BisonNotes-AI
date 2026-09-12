import CryptoKit
import Foundation

enum SQLiteMediaPlanningError: LocalizedError, Equatable {
    case invalidSourceURL
    case invalidSourceRoot
    case sourceOutsideManagedRoots
    case sourceMissing
    case sourceNotRegularFile
    case sourceFingerprintFailed
    case sourceDestinationAlias

    var errorDescription: String? {
        switch self {
        case .invalidSourceURL:
            return "The media source URL is invalid."
        case .invalidSourceRoot:
            return "The media source root is invalid."
        case .sourceOutsideManagedRoots:
            return "The media source is outside the registered application roots."
        case .sourceMissing:
            return "The media source is unavailable."
        case .sourceNotRegularFile:
            return "The media source is not a regular file."
        case .sourceFingerprintFailed:
            return "The media source could not be fingerprinted."
        case .sourceDestinationAlias:
            return "The media source and destination must remain distinct."
        }
    }
}

/// Converts an existing app-owned file into a checksum-bound transfer plan.
/// This is read-only: it neither creates directories nor starts a copy.
struct SQLiteMediaTransferRequest: Sendable {
    let sourceTransferID: String
    let operationID: String
    let assetID: String
    let ownerStorageID: String?
    let ownerRevision: Int?
    let sourceURL: URL
    let destinationRelativePath: String
}

struct SQLiteApplicationMediaTransferPlanner: Sendable {
    let mapping: SQLiteApplicationMediaRootMapping

    func makePlan(
        _ request: SQLiteMediaTransferRequest,
        fileManager: FileManager = .default
    ) throws -> SQLiteMediaTransferPlan {
        let source = try resolveSource(at: request.sourceURL, fileManager: fileManager)
        let destinationRoot = SQLiteApplicationMediaRootID.sqliteMedia.rawValue
        let destinationURL = try mapping.registry.destinationURL(
            root: destinationRoot,
            relativePath: request.destinationRelativePath
        )
        guard source.url.resolvingSymlinksInPath().standardizedFileURL
                != destinationURL.resolvingSymlinksInPath().standardizedFileURL else {
            throw SQLiteMediaPlanningError.sourceDestinationAlias
        }
        let fingerprint = try SQLiteApplicationMediaPlanningSupport.fingerprint(
            at: source.url,
            fileManager: fileManager
        )
        let plan = SQLiteMediaCopyPlan(
            operationID: request.operationID,
            assetID: request.assetID,
            ownerStorageID: request.ownerStorageID,
            ownerRevision: request.ownerRevision,
            sourceRoot: source.root.rawValue,
            sourceRelativePath: source.relativePath,
            destinationRoot: destinationRoot,
            destinationRelativePath: request.destinationRelativePath,
            expectedByteLength: fingerprint.byteLength,
            expectedSHA256: fingerprint.sha256
        )
        try plan.validate()
        return SQLiteMediaTransferPlan(
            sourceTransferID: request.sourceTransferID,
            copyPlan: plan
        )
    }
}

/// The values needed to journal one provider archive restore. The caller must
/// resolve the saved security-scoped bookmark before constructing this value
/// and provide the current directory containing the resolved source URL. The
/// directory becomes a logical root in the plan; its absolute URL never enters
/// SQLite and can be reconstructed from the bookmark on a later retry.
struct SQLiteArchiveRestoreRequest: Sendable {
    let operationID: String
    let archiveLocationID: String
    let ownerStorageID: String?
    let ownerRevision: Int?
    let ownerLastModified: Date?
    let sourceRootID: String
    let sourceRootURL: URL
    let sourceURL: URL
    let destinationRootID: String
    let destinationRelativePath: String

    init(
        operationID: String,
        archiveLocationID: String,
        ownerStorageID: String?,
        ownerRevision: Int?,
        ownerLastModified: Date? = nil,
        sourceRootID: String,
        sourceRootURL: URL,
        sourceURL: URL,
        destinationRootID: String = SQLiteApplicationMediaRootID.sqliteMedia.rawValue,
        destinationRelativePath: String
    ) {
        self.operationID = operationID
        self.archiveLocationID = archiveLocationID
        self.ownerStorageID = ownerStorageID
        self.ownerRevision = ownerRevision
        self.ownerLastModified = ownerLastModified
        self.sourceRootID = sourceRootID
        self.sourceRootURL = sourceRootURL
        self.sourceURL = sourceURL
        self.destinationRootID = destinationRootID
        self.destinationRelativePath = destinationRelativePath
    }
}

/// Builds a root-relative, checksum-bound archive restore plan without
/// creating directories or copying/deleting provider files. The destination
/// is the candidate app-owned SQLite media root; production wiring must still
/// choose the final root registry and retain the bookmark needed for retries.
struct SQLiteApplicationArchiveRestorePlanner: Sendable {
    let mapping: SQLiteApplicationMediaRootMapping

    func makePlan(
        _ request: SQLiteArchiveRestoreRequest,
        fileManager: FileManager = .default
    ) throws -> SQLiteArchiveRestorePlan {
        try SQLiteMediaFileOperationValidation.identifier(request.operationID)
        try SQLiteMediaFileOperationValidation.identifier(request.archiveLocationID)
        try SQLiteMediaFileOperationValidation.root(request.sourceRootID)
        try SQLiteMediaFileOperationValidation.root(request.destinationRootID)
        if let ownerLastModified = request.ownerLastModified {
            guard ownerLastModified.timeIntervalSinceReferenceDate.isFinite else {
                throw SQLiteArchiveRestoreError.invalidOwnerRevision
            }
        }

        let sourceRoot = try Self.validateSourceRoot(
            request.sourceRootURL,
            fileManager: fileManager
        )
        guard request.sourceURL.isFileURL else {
            throw SQLiteMediaPlanningError.invalidSourceURL
        }
        let sourceURL = request.sourceURL.standardizedFileURL
        guard let sourceRelativePath = SQLiteApplicationMediaPlanningSupport.relativePath(
            for: sourceURL,
            under: sourceRoot
        ) else {
            throw SQLiteMediaPlanningError.sourceOutsideManagedRoots
        }
        let resolvedSourceURL = try SQLiteMediaRootPathResolver.resolve(
            relativePath: sourceRelativePath,
            under: sourceRoot
        )
        guard resolvedSourceURL.standardizedFileURL == sourceURL else {
            throw SQLiteMediaPlanningError.sourceOutsideManagedRoots
        }
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw SQLiteMediaPlanningError.sourceMissing
        }
        let values = try sourceURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw SQLiteMediaPlanningError.sourceNotRegularFile
        }

        let destinationRoot = request.destinationRootID
        let destinationURL = try mapping.registry.destinationURL(
            root: destinationRoot,
            relativePath: request.destinationRelativePath
        )
        guard sourceURL.resolvingSymlinksInPath().standardizedFileURL
                != destinationURL.resolvingSymlinksInPath().standardizedFileURL else {
            throw SQLiteMediaPlanningError.sourceDestinationAlias
        }

        let fingerprint = try SQLiteApplicationMediaPlanningSupport.fingerprint(
            at: sourceURL,
            fileManager: fileManager
        )
        let plan = SQLiteArchiveRestorePlan(
            operationID: request.operationID,
            archiveLocationID: request.archiveLocationID,
            ownerStorageID: request.ownerStorageID,
            ownerRevision: request.ownerRevision,
            ownerLastModified: request.ownerLastModified,
            sourceRoot: request.sourceRootID,
            sourceRelativePath: sourceRelativePath,
            destinationRoot: destinationRoot,
            destinationRelativePath: request.destinationRelativePath,
            expectedByteLength: fingerprint.byteLength,
            expectedSHA256: fingerprint.sha256
        )
        try plan.validate()
        return plan
    }
}

private extension SQLiteApplicationMediaTransferPlanner {
    struct ResolvedSource {
        let root: SQLiteApplicationMediaRootID
        let relativePath: String
        let url: URL
    }

    func resolveSource(
        at sourceURL: URL,
        fileManager: FileManager
    ) throws -> ResolvedSource {
        guard sourceURL.isFileURL else {
            throw SQLiteMediaPlanningError.invalidSourceURL
        }
        let candidate = sourceURL.standardizedFileURL
        let roots = mapping.sourceURLs.sorted { lhs, rhs in
            if lhs.value.path.count != rhs.value.path.count {
                return lhs.value.path.count > rhs.value.path.count
            }
            return lhs.key.rawValue < rhs.key.rawValue
        }
        for (rootID, rootURL) in roots {
            guard let relativePath = SQLiteApplicationMediaPlanningSupport.relativePath(
                for: candidate,
                under: rootURL
            ) else {
                continue
            }
            do {
                let resolvedURL = try mapping.registry.sourceURL(
                    root: rootID.rawValue,
                    relativePath: relativePath
                )
                guard resolvedURL.standardizedFileURL == candidate else {
                    continue
                }
                guard fileManager.fileExists(atPath: candidate.path) else {
                    throw SQLiteMediaPlanningError.sourceMissing
                }
                let values = try candidate.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true else {
                    throw SQLiteMediaPlanningError.sourceNotRegularFile
                }
                return ResolvedSource(
                    root: rootID,
                    relativePath: relativePath,
                    url: candidate
                )
            } catch let error as SQLiteMediaPlanningError {
                throw error
            } catch {
                continue
            }
        }
        throw SQLiteMediaPlanningError.sourceOutsideManagedRoots
    }

}

private extension SQLiteApplicationArchiveRestorePlanner {
    static func validateSourceRoot(
        _ sourceRootURL: URL,
        fileManager: FileManager
    ) throws -> URL {
        guard sourceRootURL.isFileURL else {
            throw SQLiteMediaPlanningError.invalidSourceRoot
        }
        let root = sourceRootURL.standardizedFileURL
        guard !root.path.isEmpty, root.path != "/",
              fileManager.fileExists(atPath: root.path) else {
            throw SQLiteMediaPlanningError.invalidSourceRoot
        }
        let values = try root.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw SQLiteMediaPlanningError.invalidSourceRoot
        }
        return root
    }
}

private enum SQLiteApplicationMediaPlanningSupport {
    static func relativePath(for candidate: URL, under root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard candidatePath.hasPrefix(prefix) else { return nil }
        let relativePath = String(candidatePath.dropFirst(prefix.count))
        return relativePath.isEmpty ? nil : relativePath
    }

    static func fingerprint(
        at url: URL,
        fileManager: FileManager
    ) throws -> (byteLength: Int64, sha256: String) {
        guard fileManager.fileExists(atPath: url.path) else {
            throw SQLiteMediaPlanningError.sourceMissing
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw SQLiteMediaPlanningError.sourceFingerprintFailed
        }
        defer { try? handle.close() }

        var digest = SHA256()
        var byteLength: Int64 = 0
        do {
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                digest.update(data: chunk)
                byteLength += Int64(chunk.count)
            }
        } catch {
            throw SQLiteMediaPlanningError.sourceFingerprintFailed
        }
        let digestBytes = digest.finalize()
        return (
            byteLength: byteLength,
            sha256: digestBytes.map { String(format: "%02x", $0) }.joined()
        )
    }
}
