import CryptoKit
import Foundation

enum SQLiteMediaPlanningError: LocalizedError, Equatable {
    case invalidSourceURL
    case sourceOutsideManagedRoots
    case sourceMissing
    case sourceNotRegularFile
    case sourceFingerprintFailed
    case sourceDestinationAlias

    var errorDescription: String? {
        switch self {
        case .invalidSourceURL:
            return "The media source URL is invalid."
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
        let fingerprint = try Self.fingerprint(
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
            guard let relativePath = Self.relativePath(
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
