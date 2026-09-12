import Foundation

struct SQLiteMediaTransferPlan: Equatable, Sendable {
    let sourceTransferID: String
    let copyPlan: SQLiteMediaCopyPlan

    func validate() throws {
        try SQLiteImportReceiptValidation.identifier(sourceTransferID)
        try copyPlan.validate()
    }
}

enum SQLiteMediaSourceRetentionDisposition: Equatable, Sendable {
    case retain
    case eligibleForRemoval
}

struct SQLiteMediaTransferResult: Equatable, Sendable {
    let operation: SQLiteMediaFileOperation
    let receipt: SQLiteImportReceipt
    let sourceRetention: SQLiteMediaSourceRetentionDisposition
}

struct SQLiteWebImportStagingCleanupReport: Equatable, Sendable {
    let deletedCount: Int
    let reclaimedBytes: Int64
    let retainedReferencedCount: Int
    let retainedRecentCount: Int
    let failedCount: Int
}

/// Removes only abandoned, completed web-audio staging files that are not
/// represented by the durable media journal.
///
/// Web audio staging is an app-owned handoff directory, not a user library
/// location. A completed download can still be present when the process dies
/// before it enqueues the journal operation, so the cleanup uses a separate
/// conservative age floor. Files referenced by any journal operation are
/// always retained; an unreadable journal must be handled by the caller as a
/// fail-closed condition rather than passed as an empty reference set.
struct SQLiteWebImportStagingCleaner: Sendable {
    static let supportedAudioExtensions: Set<String> = [
        "m4a", "mp3", "wav", "caf", "aiff", "aif"
    ]

    let rootURL: URL

    func run(
        referencedSourceRelativePaths: Set<String>,
        cutoff: Date,
        fileManager: FileManager = .default
    ) -> SQLiteWebImportStagingCleanupReport {
        let root = rootURL.standardizedFileURL
        guard root.isFileURL,
              !root.path.isEmpty,
              root.path != "/" else {
            return SQLiteWebImportStagingCleanupReport(
                deletedCount: 0,
                reclaimedBytes: 0,
                retainedReferencedCount: 0,
                retainedRecentCount: 0,
                failedCount: 0
            )
        }

        var deletedCount = 0
        var reclaimedBytes: Int64 = 0
        var retainedReferencedCount = 0
        var retainedRecentCount = 0
        var failedCount = 0

        let candidates = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .creationDateKey,
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ],
            options: [.skipsHiddenFiles]
        )) ?? []

        for candidate in candidates {
            guard let relativePath = relativePath(for: candidate, under: root),
                  isGeneratedAudioFile(candidate, fileManager: fileManager) else {
                continue
            }

            if referencedSourceRelativePaths.contains(relativePath) {
                retainedReferencedCount += 1
                continue
            }
            guard isOlderThanCutoff(candidate, cutoff: cutoff, fileManager: fileManager) else {
                retainedRecentCount += 1
                continue
            }

            let size = fileSize(candidate, fileManager: fileManager)
            do {
                try fileManager.removeItem(at: candidate)
                deletedCount += 1
                reclaimedBytes += size
            } catch {
                failedCount += 1
            }
        }

        return SQLiteWebImportStagingCleanupReport(
            deletedCount: deletedCount,
            reclaimedBytes: reclaimedBytes,
            retainedReferencedCount: retainedReferencedCount,
            retainedRecentCount: retainedRecentCount,
            failedCount: failedCount
        )
    }
}

private extension SQLiteWebImportStagingCleaner {
    func relativePath(for candidate: URL, under root: URL) -> String? {
        let rootPath = root.path
        let candidatePath = candidate.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard candidatePath.hasPrefix(prefix) else { return nil }
        let relativePath = String(candidatePath.dropFirst(prefix.count))
        guard !relativePath.isEmpty,
              !relativePath.contains("/") else {
            return nil
        }
        return relativePath
    }

    func isGeneratedAudioFile(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        guard Self.supportedAudioExtensions.contains(url.pathExtension.lowercased()),
              let values = try? url.resourceValues(
                  forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            return false
        }

        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.count > 37 else { return false }
        let uuidStart = stem.index(stem.endIndex, offsetBy: -36)
        let separator = stem.index(before: uuidStart)
        guard stem[separator] == "-" else { return false }
        return UUID(uuidString: String(stem[uuidStart...])) != nil
            && fileManager.fileExists(atPath: url.path)
    }

    func isOlderThanCutoff(
        _ url: URL,
        cutoff: Date,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let values = try? url.resourceValues(
                  forKeys: [.contentModificationDateKey, .creationDateKey]
              ),
              let date = values.contentModificationDate ?? values.creationDate,
              date < cutoff else {
            return false
        }
        return true
    }

    func fileSize(_ url: URL, fileManager: FileManager) -> Int64 {
        guard fileManager.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else {
            return 0
        }
        return Int64(values.fileSize ?? 0)
    }
}

enum SQLiteMediaSourceRetentionPolicy {
    static func disposition(
        sourceTransferID: String,
        operation: SQLiteMediaFileOperation,
        receipt: SQLiteImportReceipt?
    ) throws -> SQLiteMediaSourceRetentionDisposition {
        try SQLiteImportReceiptValidation.identifier(sourceTransferID)
        guard operation.state == "completed",
              operation.metadataState == SQLiteMediaMetadataState.committed ||
                operation.metadataState == SQLiteMediaMetadataState.legacy,
              let assetID = operation.assetID,
              let receipt,
              receipt.sourceTransferID == sourceTransferID,
              receipt.destinationStorageID == assetID,
              receipt.outcome == .committed else {
            return .retain
        }
        return .eligibleForRemoval
    }
}
