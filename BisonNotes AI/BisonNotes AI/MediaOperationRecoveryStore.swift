//
//  MediaOperationRecoveryStore.swift
//  BisonNotes AI
//
//  Durable ownership for media publication boundaries. This is deliberately
//  separate from Core Data: a receipt can explain a file that exists before
//  its recording row is durable, without creating a new model version.
//

import Foundation
import Darwin
import CryptoKit

enum MediaOperationKind: String, Codable, Sendable {
    case audioImport = "audio-import"
    case videoImport = "video-import"
    case transcriptImport = "transcript-import"
    case watchImport = "watch-import"
    case archiveRestore = "archive-restore"
    case recordingFinalization = "recording-finalization"
}

enum MediaOperationPhase: String, Codable, Sendable {
    case prepared
    case staged
    case published
    case metadataPending = "metadata-pending"
    case metadataCommitted = "metadata-committed"
}

struct MediaOperationReceipt: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let operationID: UUID
    let kind: MediaOperationKind
    let sourceName: String
    let stagingRelativePath: String
    let publishedRelativePath: String
    let createdAt: Date
    var updatedAt: Date
    var phase: MediaOperationPhase
    var recordingID: UUID?
    var sourceFileSize: Int64?
    var sourceFingerprint: String?
    var publishedFileSize: Int64?
    var publishedFingerprint: String?
}

struct MediaOperationArtifactIdentity: Equatable, Sendable {
    let fileSize: Int64
    let fingerprint: String
}

struct MediaOperation: Equatable, Sendable {
    var receipt: MediaOperationReceipt
    let stagingURL: URL
    let publishedURL: URL
}

struct MediaOperationReconciliationResult: Equatable, Sendable {
    var committedCount = 0
    var retainedCount = 0
    var removedReceiptCount = 0
    var failedCount = 0
}

enum MediaOperationRecoveryError: LocalizedError {
    case unavailable
    case invalidPath
    case destinationConflict(URL)
    case missingStagingArtifact
    case artifactIntegrityMismatch
    case receiptWriteFailed(String)
    case receiptReadFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Media recovery storage is unavailable."
        case .invalidPath:
            return "The media recovery path is outside the app-owned container."
        case .destinationConflict(let url):
            return "A file already exists at the destination: \(url.lastPathComponent)"
        case .missingStagingArtifact:
            return "The staged media artifact is no longer available."
        case .artifactIntegrityMismatch:
            return "The media artifact no longer matches the recorded operation identity."
        case .receiptWriteFailed(let reason):
            return "Could not record media recovery state: \(reason)"
        case .receiptReadFailed(let reason):
            return "Could not read media recovery state: \(reason)"
        }
    }
}

/// Stores operation receipts and stages media before it becomes visible in
/// Documents. The receipt paths are relative, bounded, and private to this
/// app. Callers own the external source URL and decide when that source may be
/// acknowledged or deleted.
struct MediaOperationRecoveryStore {
    static let receiptFilePrefix = "media-operation-"
    static let receiptFileExtension = "json"
    static let stagingDirectoryName = "Staging"
    static let defaultRecoveryDirectoryName = "MediaOperationRecovery"
    static let defaultRetention: TimeInterval = 7 * 24 * 60 * 60

    let recoveryDirectory: URL
    let stagingDirectory: URL
    let documentsDirectory: URL
    let fileManager: FileManager

    init(
        recoveryDirectory: URL,
        documentsDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.recoveryDirectory = recoveryDirectory.standardizedFileURL
        self.stagingDirectory = recoveryDirectory
            .appendingPathComponent(Self.stagingDirectoryName, isDirectory: true)
            .standardizedFileURL
        self.documentsDirectory = documentsDirectory.standardizedFileURL
        self.fileManager = fileManager
    }

    static func live(fileManager: FileManager = .default) -> Self? {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }

        return Self(
            recoveryDirectory: applicationSupport.appendingPathComponent(
                Self.defaultRecoveryDirectoryName,
                isDirectory: true
            ),
            documentsDirectory: documents,
            fileManager: fileManager
        )
    }

    func begin(
        kind: MediaOperationKind,
        sourceName: String,
        destinationURL: URL,
        fileExtension: String? = nil,
        recordingID: UUID? = nil,
        sourceFileSize: Int64? = nil,
        sourceFingerprint: String? = nil,
        now: Date = Date()
    ) throws -> MediaOperation {
        guard isSafeChild(destinationURL, of: documentsDirectory) else {
            throw MediaOperationRecoveryError.invalidPath
        }

        try fileManager.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        let operationID = UUID()
        let ext = sanitizedExtension(fileExtension ?? destinationURL.pathExtension)
        let stagingName = ext.isEmpty
            ? "\(kind.rawValue)-\(operationID.uuidString)"
            : "\(kind.rawValue)-\(operationID.uuidString).\(ext)"
        let stagingURL = stagingDirectory.appendingPathComponent(stagingName, isDirectory: false)
        let publishedRelativePath = try relativePath(for: destinationURL, under: documentsDirectory)
        let receipt = MediaOperationReceipt(
            version: MediaOperationReceipt.currentVersion,
            operationID: operationID,
            kind: kind,
            sourceName: boundedSourceName(sourceName),
            stagingRelativePath: stagingName,
            publishedRelativePath: publishedRelativePath,
            createdAt: now,
            updatedAt: now,
            phase: .prepared,
            recordingID: recordingID,
            sourceFileSize: sourceFileSize,
            sourceFingerprint: sourceFingerprint,
            publishedFileSize: nil,
            publishedFingerprint: nil
        )

        do {
            try writeReceipt(receipt)
        } catch {
            throw MediaOperationRecoveryError.receiptWriteFailed(error.localizedDescription)
        }

        return MediaOperation(
            receipt: receipt,
            stagingURL: stagingURL,
            publishedURL: destinationURL.standardizedFileURL
        )
    }

    func stageCopy(
        from sourceURL: URL,
        for operation: MediaOperation,
        now: Date = Date()
    ) throws -> MediaOperation {
        guard isSafeChild(operation.stagingURL, of: stagingDirectory) else {
            throw MediaOperationRecoveryError.invalidPath
        }
        guard !fileManager.fileExists(atPath: operation.stagingURL.path) else {
            throw MediaOperationRecoveryError.receiptWriteFailed("The staging path is already in use.")
        }

        try validateSourceIdentity(sourceURL, for: operation.receipt)

        do {
            try fileManager.copyItem(at: sourceURL, to: operation.stagingURL)
            AppFileProtection.apply(to: operation.stagingURL)
        } catch {
            throw error
        }

        do {
            return try updateWithPublishedIdentity(operation, phase: .staged, now: now)
        } catch MediaOperationRecoveryError.artifactIntegrityMismatch {
            try? fileManager.removeItem(at: operation.stagingURL)
            throw MediaOperationRecoveryError.artifactIntegrityMismatch
        }
    }

    /// Marks an artifact produced directly into the app-owned staging URL,
    /// such as an AVAssetExportSession output.
    func markStaged(
        _ operation: MediaOperation,
        now: Date = Date()
    ) throws -> MediaOperation {
        guard fileManager.fileExists(atPath: operation.stagingURL.path) else {
            throw MediaOperationRecoveryError.missingStagingArtifact
        }
        return try updateWithPublishedIdentity(operation, phase: .staged, now: now)
    }

    /// Publishes without overwriting. A same-volume hard link gives the
    /// destination an atomic, no-replace visibility point. When staging and
    /// destination are on different volumes, a destination-volume sibling is
    /// copied first and then linked into place.
    func publish(
        _ operation: MediaOperation,
        now: Date = Date()
    ) throws -> MediaOperation {
        guard fileManager.fileExists(atPath: operation.stagingURL.path) else {
            throw MediaOperationRecoveryError.missingStagingArtifact
        }
        guard isSafeChild(operation.publishedURL, of: documentsDirectory) else {
            throw MediaOperationRecoveryError.invalidPath
        }
        guard !fileManager.fileExists(atPath: operation.publishedURL.path) else {
            throw MediaOperationRecoveryError.destinationConflict(operation.publishedURL)
        }

        let verified = try operationWithPublishedIdentity(operation, at: operation.stagingURL)
        try atomicNoReplaceInstall(from: verified.stagingURL, to: verified.publishedURL)
        AppFileProtection.apply(to: operation.publishedURL)

        do {
            return try update(verified, phase: .published, now: now)
        } catch {
            // The published bytes are intentionally retained. Reconciliation
            // can see the destination even if the receipt update was killed.
            throw error
        }
    }

    func markMetadataPending(
        _ operation: MediaOperation,
        recordingID: UUID? = nil,
        now: Date = Date()
    ) throws -> MediaOperation {
        guard fileManager.fileExists(atPath: operation.publishedURL.path) else {
            throw MediaOperationRecoveryError.missingStagingArtifact
        }
        var pending = try operationWithPublishedIdentity(operation, at: operation.publishedURL)
        if let recordingID {
            pending.receipt.recordingID = recordingID
        }
        if pending.receipt.phase == .metadataCommitted {
            return pending
        }
        return try update(pending, phase: .metadataPending, now: now)
    }

    func markMetadataCommitted(
        _ operation: MediaOperation,
        recordingID: UUID? = nil,
        now: Date = Date()
    ) throws -> MediaOperation {
        var committed = try operationWithPublishedIdentity(operation, at: operation.publishedURL)
        committed.receipt.phase = .metadataCommitted
        committed.receipt.updatedAt = now
        if let recordingID {
            committed.receipt.recordingID = recordingID
        }
        try writeReceipt(committed.receipt)
        return committed
    }

    /// Closes only the app-owned receipt and staging artifact. It never
    /// removes the published recording or the borrowed source.
    func finish(_ operation: MediaOperation) throws {
        if fileManager.fileExists(atPath: operation.stagingURL.path) {
            try fileManager.removeItem(at: operation.stagingURL)
        }
        // Keep a compact committed identity for flows whose borrowed source
        // may be delivered again after cleanup/acknowledgement is interrupted.
        if operation.receipt.phase == .metadataCommitted,
           operation.receipt.kind == .transcriptImport || operation.receipt.kind == .videoImport {
            return
        }
        let receiptURL = try receiptURL(for: operation.receipt.operationID)
        if fileManager.fileExists(atPath: receiptURL.path) {
            try fileManager.removeItem(at: receiptURL)
        }
    }

    /// Closes every receipt for one logical inbound delivery. A retried Watch
    /// transfer may leave more than one staged attempt for the same sender ID;
    /// all are app-owned and can be removed only after the recording save has
    /// been acknowledged.
    func finishOperations(for recordingID: UUID) throws {
        guard fileManager.fileExists(atPath: recoveryDirectory.path) else { return }
        let receiptURLs = try fileManager.contentsOfDirectory(
            at: recoveryDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { url in
            url.lastPathComponent.hasPrefix(Self.receiptFilePrefix)
                && url.pathExtension.lowercased() == Self.receiptFileExtension
        }

        for receiptURL in receiptURLs {
            let receipt = try readReceipt(at: receiptURL)
            guard receipt.recordingID == recordingID else { continue }
            let operation = MediaOperation(
                receipt: receipt,
                stagingURL: try stagingURL(for: receipt),
                publishedURL: try publishedURL(for: receipt)
            )
            try finish(operation)
        }
    }

}

extension MediaOperationRecoveryStore {
    /// Returns an app-owned operation only when its source identity matches
    /// exactly. A source filename alone is not sufficient to resume an import.
    /// Ambiguous, malformed, or legacy receipts are left for explicit recovery.
    func pendingOperation(
        kind: MediaOperationKind,
        sourceName: String? = nil,
        sourceFileSize: Int64,
        sourceFingerprint: String,
        recordingID: UUID? = nil
    ) throws -> MediaOperation? {
        guard fileManager.fileExists(atPath: recoveryDirectory.path) else { return nil }
        let receiptURLs = try fileManager.contentsOfDirectory(
            at: recoveryDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { url in
            url.lastPathComponent.hasPrefix(Self.receiptFilePrefix)
                && url.pathExtension.lowercased() == Self.receiptFileExtension
        }

        let matches = try receiptURLs.compactMap { receiptURL -> MediaOperation? in
            let receipt: MediaOperationReceipt
            do {
                receipt = try readReceipt(at: receiptURL)
            } catch {
                // Retain the unreadable receipt; it must not disable unrelated
                // deliveries. Publication still refuses destination replacement.
                AppLog.shared.fileManagement("Unreadable media receipt retained for review", level: .error)
                return nil
            }
            guard receipt.kind == kind,
                  sourceName == nil || receipt.sourceName == boundedSourceName(sourceName ?? ""),
                  receipt.sourceFileSize == sourceFileSize,
                  receipt.sourceFingerprint == sourceFingerprint,
                  recordingID == nil || receipt.recordingID == recordingID,
                  receipt.phase == .staged
                    || receipt.phase == .published
                    || receipt.phase == .metadataPending
                    || receipt.phase == .metadataCommitted else {
                return nil
            }
            let operation = MediaOperation(
                receipt: receipt,
                stagingURL: try stagingURL(for: receipt),
                publishedURL: try publishedURL(for: receipt)
            )
            let publishedExists = fileManager.fileExists(atPath: operation.publishedURL.path)
            let stagingExists = fileManager.fileExists(atPath: operation.stagingURL.path)
            guard publishedExists || stagingExists else {
                return nil
            }

            if publishedExists {
                let publishedIdentity = try artifactIdentity(for: operation.publishedURL)
                guard matchesPublishedIdentity(receipt, actual: publishedIdentity) else {
                    throw MediaOperationRecoveryError.artifactIntegrityMismatch
                }
            }
            if stagingExists {
                let stagingIdentity = try artifactIdentity(for: operation.stagingURL)
                guard matchesPublishedIdentity(receipt, actual: stagingIdentity) else {
                    throw MediaOperationRecoveryError.artifactIntegrityMismatch
                }
            }
            return operation
        }

        guard matches.count <= 1 else {
            throw MediaOperationRecoveryError.receiptReadFailed(
                "Multiple matching media operations require explicit recovery."
            )
        }
        return matches.first
    }

    /// Used only before publication. If publication happened, callers must
    /// retain the receipt and artifact so a metadata save can be retried.
    func abortBeforePublish(_ operation: MediaOperation) throws {
        guard operation.receipt.phase == .prepared || operation.receipt.phase == .staged else {
            return
        }
        if fileManager.fileExists(atPath: operation.stagingURL.path) {
            try fileManager.removeItem(at: operation.stagingURL)
        }
        let receiptURL = try receiptURL(for: operation.receipt.operationID)
        if fileManager.fileExists(atPath: receiptURL.path) {
            try fileManager.removeItem(at: receiptURL)
        }
    }

    /// Reconciles only this store's receipts. A published artifact is cleared
    /// from recovery state only when the caller has already verified a durable
    /// recording reference. Read failure from that caller keeps the receipt.
    @discardableResult
    func reconcile(
        isPublishedArtifactReferenced: (MediaOperationReceipt) throws -> Bool,
        now: Date = Date(),
        retention: TimeInterval = Self.defaultRetention
    ) -> MediaOperationReconciliationResult {
        var result = MediaOperationReconciliationResult()
        let receiptURLs: [URL]
        do {
            receiptURLs = try fileManager.contentsOfDirectory(
                at: recoveryDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { url in
                url.lastPathComponent.hasPrefix(Self.receiptFilePrefix)
                    && url.pathExtension.lowercased() == Self.receiptFileExtension
            }
        } catch {
            return result
        }

        for receiptURL in receiptURLs {
            do {
                let receipt = try readReceipt(at: receiptURL)
                let stagingURL = try stagingURL(for: receipt)
                let publishedURL = try publishedURL(for: receipt)

                // A committed receipt has no pending work left to reconcile: it
                // survives `finish` only as a deduplication token, so a source
                // redelivered after an interrupted acknowledgement is recognized
                // instead of imported twice.
                //
                // Verifying one costs a full SHA-256 of the published media, and
                // then `markMetadataCommitted` hashes it a second time — for
                // every video ever imported, on every launch *and* every
                // activation, synchronously on the main actor. A library with a
                // few large extracted videos turned becoming active into
                // gigabytes of I/O. Nothing about that work could change the
                // outcome, so skip straight to aging the token out.
                if receipt.phase == .metadataCommitted {
                    if fileManager.fileExists(atPath: stagingURL.path) {
                        try fileManager.removeItem(at: stagingURL)
                    }
                    // Only the borrowed-source flows keep a token. Any other kind
                    // reaching here is a receipt `finish` did not get to delete.
                    let isDeduplicationToken = receipt.kind == .transcriptImport
                        || receipt.kind == .videoImport
                    guard isDeduplicationToken,
                          now.timeIntervalSince(receipt.updatedAt) < retention else {
                        try fileManager.removeItem(at: receiptURL)
                        result.removedReceiptCount += 1
                        logReconciliation(receipt, disposition: "receipt-removed")
                        continue
                    }
                    result.retainedCount += 1
                    logReconciliation(receipt, disposition: "committed-token-retained")
                    continue
                }

                let publishedExists = fileManager.fileExists(atPath: publishedURL.path)
                let stagingExists = fileManager.fileExists(atPath: stagingURL.path)
                let publishedMatches: Bool
                if publishedExists {
                    let publishedIdentity = try artifactIdentity(for: publishedURL)
                    publishedMatches = matchesPublishedIdentity(
                        receipt,
                        actual: publishedIdentity
                    )
                } else {
                    publishedMatches = false
                }
                let publicationIsOwned: Bool
                switch receipt.phase {
                case .published, .metadataPending, .metadataCommitted:
                    publicationIsOwned = publishedMatches
                case .staged:
                    // If staging still exists, a destination file may be an
                    // unrelated conflict. Only the post-link state (staging
                    // gone plus an exact identity match) can be considered a
                    // publication interrupted before its receipt update.
                    publicationIsOwned = publishedMatches && !stagingExists
                case .prepared:
                    publicationIsOwned = false
                }

                let shouldCheckReference = receipt.phase != .prepared
                    && !(receipt.phase == .staged && stagingExists)
                let referenced = shouldCheckReference
                    ? try isPublishedArtifactReferenced(receipt)
                    : false

                if referenced && publicationIsOwned {
                    if stagingExists {
                        try fileManager.removeItem(at: stagingURL)
                    }
                    let operation = MediaOperation(receipt: receipt, stagingURL: stagingURL, publishedURL: publishedURL)
                    let committed = try markMetadataCommitted(operation)
                    try finish(committed)
                    result.committedCount += 1
                    logReconciliation(receipt, disposition: "committed")
                    continue
                }

                if referenced && !publicationIsOwned {
                    result.failedCount += 1
                    logReconciliation(receipt, disposition: "unresolved")
                    continue
                }

                // A `.prepared` receipt whose staging copy exists is a process
                // killed between stageCopy writing the bytes and the receipt
                // reaching `.staged`. Nothing can ever resume it — pendingOperation
                // only matches `.staged` and later — so retaining it on age alone
                // leaked a full media file per affected import, permanently.
                // Publication never happened, so the staging copy is the only
                // thing this receipt owns and the published path is never touched.
                if receipt.phase == .prepared,
                   now.timeIntervalSince(receipt.updatedAt) >= retention {
                    if stagingExists {
                        try fileManager.removeItem(at: stagingURL)
                    }
                    try fileManager.removeItem(at: receiptURL)
                    result.removedReceiptCount += 1
                    logReconciliation(receipt, disposition: "unreachable-staging-expired")
                    continue
                }

                if publishedExists || stagingExists {
                    let age = now.timeIntervalSince(receipt.updatedAt)
                    let disposition = age >= retention ? "retained-after-grace" : "retained"
                    result.retainedCount += 1
                    logReconciliation(receipt, disposition: disposition)
                    continue
                }

                // Once publication was recorded, the absence of its published
                // artifact is unresolved—not an expired receipt that may be
                // discarded. Keeping this evidence avoids authorizing a fresh
                // import against a missing result whose fate is unknown.
                if receipt.phase == .published
                    || receipt.phase == .metadataPending
                    || receipt.phase == .metadataCommitted {
                    result.failedCount += 1
                    logReconciliation(receipt, disposition: "unresolved")
                    continue
                }

                // A receipt with no artifact is safe to discard only after its
                // grace period. Before then it remains evidence of a possible
                // kill between receipt creation and the first filesystem write.
                if now.timeIntervalSince(receipt.updatedAt) >= retention {
                    try fileManager.removeItem(at: receiptURL)
                    result.removedReceiptCount += 1
                    logReconciliation(receipt, disposition: "receipt-removed")
                } else {
                    result.retainedCount += 1
                    logReconciliation(receipt, disposition: "receipt-retained")
                }
            } catch {
                result.failedCount += 1
                if let receipt = try? readReceipt(at: receiptURL) {
                    logReconciliation(receipt, disposition: "unresolved")
                }
            }
        }

        return result
    }

}

extension MediaOperationRecoveryStore {
    private func update(
        _ operation: MediaOperation,
        phase: MediaOperationPhase,
        now: Date
    ) throws -> MediaOperation {
        var updated = operation
        updated.receipt.phase = phase
        updated.receipt.updatedAt = now
        do {
            try writeReceipt(updated.receipt)
        } catch {
            throw MediaOperationRecoveryError.receiptWriteFailed(error.localizedDescription)
        }
        return updated
    }

    private func updateWithPublishedIdentity(
        _ operation: MediaOperation,
        phase: MediaOperationPhase,
        now: Date
    ) throws -> MediaOperation {
        var identified = try operationWithPublishedIdentity(operation, at: operation.stagingURL)
        identified.receipt.phase = phase
        identified.receipt.updatedAt = now
        do {
            try writeReceipt(identified.receipt)
        } catch {
            throw MediaOperationRecoveryError.receiptWriteFailed(error.localizedDescription)
        }
        return identified
    }

    private func operationWithPublishedIdentity(
        _ operation: MediaOperation,
        at artifactURL: URL
    ) throws -> MediaOperation {
        let actual = try artifactIdentity(for: artifactURL)
        if !matchesPublishedIdentity(operation.receipt, actual: actual),
           (operation.receipt.publishedFileSize != nil
                || operation.receipt.publishedFingerprint != nil) {
            throw MediaOperationRecoveryError.artifactIntegrityMismatch
        }

        var identified = operation
        identified.receipt.publishedFileSize = actual.fileSize
        identified.receipt.publishedFingerprint = actual.fingerprint
        return identified
    }

    private func validateSourceIdentity(
        _ sourceURL: URL,
        for receipt: MediaOperationReceipt
    ) throws {
        guard receipt.sourceFileSize != nil || receipt.sourceFingerprint != nil else {
            return
        }
        let actual = try artifactIdentity(for: sourceURL)
        guard receipt.sourceFileSize == actual.fileSize,
              receipt.sourceFingerprint == actual.fingerprint else {
            throw MediaOperationRecoveryError.artifactIntegrityMismatch
        }
    }

    private func matchesPublishedIdentity(
        _ receipt: MediaOperationReceipt,
        actual: MediaOperationArtifactIdentity
    ) -> Bool {
        receipt.publishedFileSize == actual.fileSize
            && receipt.publishedFingerprint == actual.fingerprint
    }

    func artifactIdentity(for url: URL) throws -> MediaOperationArtifactIdentity {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? NSNumber else {
            throw MediaOperationRecoveryError.missingStagingArtifact
        }
        return MediaOperationArtifactIdentity(
            fileSize: fileSize.int64Value,
            fingerprint: try Self.fingerprint(for: url)
        )
    }

    static func fingerprint(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func fingerprint(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func writeReceipt(_ receipt: MediaOperationReceipt) throws {
        let url = try receiptURL(for: receipt.operationID)
        let data = try JSONEncoder().encode(receipt)
        try data.write(to: url, options: .atomic)
        AppFileProtection.apply(to: url)
    }

    private func readReceipt(at url: URL) throws -> MediaOperationReceipt {
        do {
            let receipt = try JSONDecoder().decode(MediaOperationReceipt.self, from: Data(contentsOf: url))
            guard receipt.version == MediaOperationReceipt.currentVersion,
                  url.lastPathComponent.caseInsensitiveCompare(
                      "\(Self.receiptFilePrefix)\(receipt.operationID.uuidString).\(Self.receiptFileExtension)"
                  ) == .orderedSame else {
                throw MediaOperationRecoveryError.receiptReadFailed("Unsupported receipt identity.")
            }
            _ = try stagingURL(for: receipt)
            _ = try publishedURL(for: receipt)
            return receipt
        } catch let error as MediaOperationRecoveryError {
            throw error
        } catch {
            throw MediaOperationRecoveryError.receiptReadFailed(error.localizedDescription)
        }
    }

    private func receiptURL(for operationID: UUID) throws -> URL {
        return recoveryDirectory.appendingPathComponent(
            "\(Self.receiptFilePrefix)\(operationID.uuidString).\(Self.receiptFileExtension)",
            isDirectory: false
        )
    }

    private func stagingURL(for receipt: MediaOperationReceipt) throws -> URL {
        let url = stagingDirectory.appendingPathComponent(receipt.stagingRelativePath, isDirectory: false)
        guard isSafeChild(url, of: stagingDirectory),
              url.lastPathComponent == receipt.stagingRelativePath else {
            throw MediaOperationRecoveryError.invalidPath
        }
        return url
    }

    private func publishedURL(for receipt: MediaOperationReceipt) throws -> URL {
        let url = documentsDirectory.appendingPathComponent(receipt.publishedRelativePath, isDirectory: false)
        guard isSafeChild(url, of: documentsDirectory) else {
            throw MediaOperationRecoveryError.invalidPath
        }
        return url
    }

    private func relativePath(for url: URL, under root: URL) throws -> String {
        let standardizedURL = url.standardizedFileURL
        let standardizedRoot = root.standardizedFileURL
        guard isSafeChild(standardizedURL, of: standardizedRoot),
              standardizedURL.path != standardizedRoot.path else {
            throw MediaOperationRecoveryError.invalidPath
        }
        return String(standardizedURL.path.dropFirst(standardizedRoot.path.count + 1))
    }

    private func isSafeChild(_ url: URL, of root: URL) -> Bool {
        let childURL = url.standardizedFileURL
        let rootURL = root.standardizedFileURL
        let childPath = childURL.path
        let rootPath = rootURL.path
        guard childPath == rootPath || childPath.hasPrefix(rootPath + "/") else {
            return false
        }

        // `resolvingSymlinksInPath()` does not reliably resolve a symlinked
        // parent when the final destination does not exist yet. Inspect every
        // path component instead and fail closed for both live and broken
        // symlinks.
        guard !isSymbolicLink(atPath: rootPath) else { return false }
        guard childPath != rootPath else { return true }

        var currentURL = rootURL
        let relativePath = childPath.dropFirst(rootPath.count + 1)
        for component in relativePath.split(separator: "/") {
            currentURL.appendPathComponent(String(component), isDirectory: false)
            if isSymbolicLink(atPath: currentURL.path) {
                return false
            }
        }
        return true
    }

    private func isSymbolicLink(atPath path: String) -> Bool {
        var fileInfo = stat()
        guard lstat(path, &fileInfo) == 0 else { return false }
        return (fileInfo.st_mode & S_IFMT) == S_IFLNK
    }

    private func boundedSourceName(_ sourceName: String) -> String {
        let lastComponent = URL(fileURLWithPath: sourceName).lastPathComponent
        return String(lastComponent.prefix(160))
    }

    private func sanitizedExtension(_ value: String) -> String {
        let filtered = value.lowercased().filter { $0.isNumber || ($0 >= "a" && $0 <= "z") }
        return String(filtered.prefix(12))
    }

    private func atomicNoReplaceInstall(from sourceURL: URL, to destinationURL: URL) throws {
        var linkResult: Int32 = -1
        var pathError: Error?
        sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else {
                    pathError = MediaOperationRecoveryError.invalidPath
                    return
                }
                linkResult = Darwin.link(sourcePath, destinationPath)
            }
        }
        if let pathError {
            throw pathError
        }

        if linkResult == 0 {
            try fileManager.removeItem(at: sourceURL)
            return
        }

        let linkError = errno
        if linkError == EEXIST {
            throw MediaOperationRecoveryError.destinationConflict(destinationURL)
        }
        guard linkError == EXDEV else {
            throw POSIXError(POSIXErrorCode(rawValue: linkError) ?? .EIO)
        }

        let destinationStagingURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(Self.receiptFilePrefix)\(UUID().uuidString).tmp",
                isDirectory: false
            )
        defer {
            if fileManager.fileExists(atPath: destinationStagingURL.path) {
                try? fileManager.removeItem(at: destinationStagingURL)
            }
        }

        try fileManager.copyItem(at: sourceURL, to: destinationStagingURL)
        AppFileProtection.apply(to: destinationStagingURL)
        var destinationLinkResult: Int32 = -1
        var destinationPathError: Error?
        destinationStagingURL.withUnsafeFileSystemRepresentation { stagingPath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let stagingPath, let destinationPath else {
                    destinationPathError = MediaOperationRecoveryError.invalidPath
                    return
                }
                destinationLinkResult = Darwin.link(stagingPath, destinationPath)
            }
        }
        if let destinationPathError {
            throw destinationPathError
        }
        guard destinationLinkResult == 0 else {
            let errorCode = errno
            if errorCode == EEXIST {
                throw MediaOperationRecoveryError.destinationConflict(destinationURL)
            }
            throw POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EIO)
        }
        try fileManager.removeItem(at: sourceURL)
    }

    private func logReconciliation(_ receipt: MediaOperationReceipt, disposition: String) {
        AppLog.shared.fileManagement(
            "staging_reconciled kind=\(receipt.kind.rawValue) disposition=\(disposition)",
            level: disposition == "unresolved" ? .error : .debug
        )
    }
}
