//
//  AdvancedTroubleshootingService.swift
//  BisonNotes AI
//
//  Read-only local diagnostics and explicitly confirmed audio cleanup.
//

import CoreData
import Foundation

// The report values and safety protocol live together so the review contract
// remains easy to audit as one implementation surface.
// swiftlint:disable file_length

// MARK: - Value snapshots

/// A value-only copy of the Core Data rows needed by troubleshooting. The
/// managed objects never leave CoreDataManager's main-actor context.
struct AdvancedTroubleshootingDatabaseSnapshot: Equatable, Sendable {
    struct Recording: Equatable, Sendable {
        let id: UUID?
        let name: String?
        let storedURL: String?
        let audioQuality: String?
        let isArchived: Bool
        /// The denormalized column, falling back to the relationship when the
        /// column is empty. Existence and classification use this.
        let transcriptID: UUID?
        let summaryID: UUID?
        /// The relationship's own identity, kept beside the column rather than
        /// coalesced into it. When a row's column names one existing transcript
        /// and its relationship names a different one, both look individually
        /// valid, so only comparing the two can surface the conflict.
        let relationshipTranscriptID: UUID?
        let relationshipSummaryID: UUID?
    }

    struct Transcript: Equatable, Sendable {
        let id: UUID?
        let recordingID: UUID?
        let relationshipRecordingID: UUID?
    }

    struct Summary: Equatable, Sendable {
        let id: UUID?
        let recordingID: UUID?
        let transcriptID: UUID?
        let relationshipRecordingID: UUID?
        let relationshipTranscriptID: UUID?
    }

    struct ProcessingJob: Equatable, Sendable {
        let id: UUID?
        let recordingURL: String?
        let recordingID: UUID?
        let status: String?
    }

    let recordings: [Recording]
    let transcripts: [Transcript]
    let summaries: [Summary]
    let processingJobs: [ProcessingJob]

    var protection: TroubleshootingProtectionSnapshot {
        TroubleshootingProtectionSnapshot(recordings: recordings, processingJobs: processingJobs)
    }
}

/// The only rows the reviewed-audio guards actually read.
///
/// `TranscriptEntry.segments` and `SummaryEntry.summary` hold entire transcript
/// and summary bodies, and revalidation never looks at either, so the delete
/// path fetches this instead of the full report snapshot.
struct TroubleshootingProtectionSnapshot: Equatable, Sendable {
    let recordings: [AdvancedTroubleshootingDatabaseSnapshot.Recording]
    let processingJobs: [AdvancedTroubleshootingDatabaseSnapshot.ProcessingJob]
}

// MARK: - Local data report

enum LocalDataInspectionStatus: String, Equatable, Sendable {
    case complete
    case partial
    case failed

    var displayName: String {
        switch self {
        case .complete:
            return "Complete"
        case .partial:
            return "Partial"
        case .failed:
            return "Failed"
        }
    }
}

enum LocalDataIssueCategory: String, Equatable, Sendable {
    case relationship
    case duplicateIdentity
    case missingAudio
    case inspection

    var displayName: String {
        switch self {
        case .relationship:
            return "Relationship"
        case .duplicateIdentity:
            return "Duplicate identity"
        case .missingAudio:
            return "Missing audio"
        case .inspection:
            return "Inspection"
        }
    }
}

struct LocalDataIssue: Equatable, Identifiable, Sendable {
    let id: String
    let category: LocalDataIssueCategory
    let message: String
}

enum LocalDataRecordKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case regular
    case archived
    case imported
    case summaryOnly
    case metadataOnly

    var displayName: String {
        switch self {
        case .regular:
            return "Regular"
        case .archived:
            return "Archived"
        case .imported:
            return "Imported"
        case .summaryOnly:
            return "Summary-only"
        case .metadataOnly:
            return "Metadata-only"
        }
    }
}

struct LocalDataRecordClassification: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let kind: LocalDataRecordKind
}

struct LocalDataReport: Equatable, Sendable {
    let generatedAt: Date
    let status: LocalDataInspectionStatus
    let recordingCount: Int
    let transcriptCount: Int
    let summaryCount: Int
    let processingJobCount: Int
    let classifications: [LocalDataRecordClassification]
    let issues: [LocalDataIssue]
    let warnings: [String]

    var issueCount: Int {
        issues.count
    }

    /// An incomplete inspection is not a successful empty result.
    var hasIssues: Bool {
        status != .complete || !issues.isEmpty
    }

    func count(for kind: LocalDataRecordKind) -> Int {
        classifications.count { $0.kind == kind }
    }
}

// MARK: - Audio scan and cleanup values

struct AudioFileFingerprint: Equatable, Sendable {
    let path: String
    let byteCount: Int64
    let modificationDate: Date?
    let fileIdentifier: UInt64?
}

struct UnreferencedAudioCandidate: Equatable, Identifiable, Sendable {
    /// The canonical path is stable for the duration of a review session.
    let id: String
    let path: String
    let fileName: String
    let byteCount: Int64
    let fingerprint: AudioFileFingerprint
}

struct UnreferencedAudioScanResult: Equatable, Sendable {
    let generatedAt: Date
    let directoryDescription: String
    let candidates: [UnreferencedAudioCandidate]
    let protectedFileCount: Int
    let deletionUnavailableReason: String?
}

enum AdvancedTroubleshootingActivityKind: String, Equatable, Sendable {
    case idle
    case recording
    case importing
    case processing
    case restore
}

struct AdvancedTroubleshootingActivitySnapshot: Equatable, Sendable {
    let blockAllDeletion: Bool
    let reason: String?
    let ownedPaths: Set<String>
    /// Required at every construction site: it is the only thing that decides
    /// how a block is reported, so no caller may fall back to a default.
    let kind: AdvancedTroubleshootingActivityKind

    static let idle = AdvancedTroubleshootingActivitySnapshot(
        blockAllDeletion: false,
        reason: nil,
        ownedPaths: [],
        kind: .idle
    )
}

enum AudioCleanupSkipReason: String, Equatable, Sendable {
    case becameReferenced
    case changedOrReplaced
    case missing
    case activeRecording
    case activeImport
    case activeProcessingJob
    case activeRestore
    case outsideScope
    /// The audio was removed, but its sidecars are shared with another audio
    /// file of the same base name and were left in place.
    case sidecarShared
    /// The run stopped before this selection could be checked.
    case notEvaluated

    var displayName: String {
        switch self {
        case .becameReferenced:
            return "Referenced by local data"
        case .changedOrReplaced:
            return "Changed or replaced since scan"
        case .missing:
            return "No longer present"
        case .activeRecording:
            return "Owned by an active recording"
        case .activeImport:
            return "Owned by an import"
        case .activeProcessingJob:
            return "Owned by an active processing job"
        case .activeRestore:
            return "Owned by an active restore"
        case .outsideScope:
            return "Outside the reviewed folder"
        case .sidecarShared:
            return "Sidecars shared with another audio file"
        case .notEvaluated:
            return "Not evaluated"
        }
    }
}

struct AudioCleanupSkip: Equatable, Identifiable, Sendable {
    let id: String
    let path: String
    let reason: AudioCleanupSkipReason
    let detail: String
}

struct AudioCleanupFailure: Equatable, Identifiable, Sendable {
    let id: String
    let path: String
    let message: String
}

struct AudioCleanupResult: Equatable, Sendable {
    let requestedCount: Int
    let deletedAudioCount: Int
    let deletedAudioBytes: Int64
    let deletedSidecarCount: Int
    let deletedSidecarBytes: Int64
    let deletedPaths: [String]
    let skipped: [AudioCleanupSkip]
    let failures: [AudioCleanupFailure]
    let cancelled: Bool

    var changedAnything: Bool {
        deletedAudioCount > 0 || deletedSidecarCount > 0
    }
}

// MARK: - File system boundary

protocol AdvancedTroubleshootingFileSystem: Sendable {
    func regularFiles(in directory: URL, allowedExtensions: Set<String>) throws -> [AudioFileFingerprint]
    func metadata(for url: URL) throws -> AudioFileFingerprint
    func deleteFile(at url: URL) throws
}

private enum LocalTroubleshootingFileSystemError: LocalizedError {
    case notARegularFile(URL)

    var errorDescription: String? {
        switch self {
        case .notARegularFile(let url):
            return "The item is not a regular file: \(url.lastPathComponent)"
        }
    }
}

/// File operations run in the detached work used by the service. The value
/// type has no mutable state; every operation uses Foundation's process-wide
/// default file manager.
struct LocalAdvancedTroubleshootingFileSystem: AdvancedTroubleshootingFileSystem, Sendable {
    func regularFiles(in directory: URL, allowedExtensions: Set<String>) throws -> [AudioFileFingerprint] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        return try urls.compactMap { url in
            guard allowedExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isRegularFile == true else { return nil }
            return try metadata(for: url)
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func metadata(for url: URL) throws -> AudioFileFingerprint {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        let values = try url.resourceValues(forKeys: keys)
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw LocalTroubleshootingFileSystemError.notARegularFile(url)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modificationDate = attributes[.modificationDate] as? Date
        let fileIdentifier = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value

        return AudioFileFingerprint(
            path: AdvancedTroubleshootingService.canonicalPath(for: url),
            byteCount: byteCount,
            modificationDate: modificationDate,
            fileIdentifier: fileIdentifier
        )
    }

    func deleteFile(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

// MARK: - Service

enum AdvancedTroubleshootingError: LocalizedError {
    case documentsDirectoryUnavailable
    case databaseReadFailed(String)
    case directoryReadFailed(String)

    var errorDescription: String? {
        switch self {
        case .documentsDirectoryUnavailable:
            return "The app's Documents folder could not be located. No local data was changed."
        case .databaseReadFailed(let message):
            return "The local database could not be read: \(message). No local data was changed."
        case .directoryReadFailed(let message):
            return "The local audio folder could not be read: \(message). No audio was deleted."
        }
    }
}

@MainActor
protocol AdvancedTroubleshootingDatabaseReader: AnyObject {
    func fetchRecordingsForDiagnostics() throws -> [RecordingEntry]
    func fetchTranscriptsForDiagnostics() throws -> [TranscriptEntry]
    func fetchSummariesForDiagnostics() throws -> [SummaryEntry]
    func fetchProcessingJobsForDiagnostics() throws -> [ProcessingJobEntry]
}

extension CoreDataManager: AdvancedTroubleshootingDatabaseReader { }

@MainActor
// The complete revalidation sequence is intentionally linear: each selected
// path must pass every guard immediately before it can be deleted.
// swiftlint:disable:next type_body_length
final class AdvancedTroubleshootingService {
    nonisolated static let orphanedAudioExtensions: Set<String> = ["m4a", "wav", "mp3", "aac"]
    nonisolated static let reportAudioExtensions: Set<String> = ["m4a", "wav", "mp3", "aac", "caf", "aiff", "aif"]
    nonisolated static let permittedSidecarExtensions = ["location", "recordingmeta"]

    private let databaseReader: any AdvancedTroubleshootingDatabaseReader
    private let fileSystem: any AdvancedTroubleshootingFileSystem
    private let documentsURL: URL?

    init(
        coreDataManager: CoreDataManager,
        fileSystem: any AdvancedTroubleshootingFileSystem = LocalAdvancedTroubleshootingFileSystem(),
        documentsURL: URL? = nil,
        databaseReader: (any AdvancedTroubleshootingDatabaseReader)? = nil
    ) {
        self.databaseReader = databaseReader ?? coreDataManager
        self.fileSystem = fileSystem
        self.documentsURL = documentsURL
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    /// Runs blocking file work off the main actor while keeping it cancellable.
    ///
    /// `Task.detached` inherits neither cancellation nor priority, and awaiting
    /// an unstructured task's `value` is not a cancellation point, so without
    /// this handler a cancelled report or scan would keep running to completion.
    nonisolated private static func runCancellable<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try work()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func makeLocalDataReport() async throws -> LocalDataReport {
        let snapshot = try makeDatabaseSnapshot()
        let documentsURL = try requiredDocumentsURL()
        let fileSystem = self.fileSystem

        return try await Self.runCancellable {
            try Self.buildLocalDataReport(
                snapshot: snapshot,
                documentsURL: documentsURL,
                fileSystem: fileSystem,
                generatedAt: Date()
            )
        }
    }

    func scanUnreferencedAudio(
        activity: AdvancedTroubleshootingActivitySnapshot = .idle
    ) async throws -> UnreferencedAudioScanResult {
        let snapshot = try makeProtectionSnapshot()
        let documentsURL = try requiredDocumentsURL()
        let fileSystem = self.fileSystem

        return try await Self.runCancellable {
            try Self.buildAudioScan(
                snapshot: snapshot,
                documentsURL: documentsURL,
                fileSystem: fileSystem,
                activity: activity,
                generatedAt: Date()
            )
        }
    }

    // swiftlint:disable cyclomatic_complexity function_body_length
    /// Deletes only files from the reviewed scan snapshot. Every selected
    /// file is checked against a fresh database snapshot, fresh file metadata,
    /// and a fresh activity snapshot immediately before deletion.
    func deleteSelectedAudio(
        candidates: [UnreferencedAudioCandidate],
        selectedIDs: Set<String>,
        activityProvider: @escaping () -> AdvancedTroubleshootingActivitySnapshot = { .idle }
    ) async throws -> AudioCleanupResult {
        let selectedCandidates = candidates.filter { selectedIDs.contains($0.id) }
        guard !selectedCandidates.isEmpty else {
            return AudioCleanupResult(
                requestedCount: 0,
                deletedAudioCount: 0,
                deletedAudioBytes: 0,
                deletedSidecarCount: 0,
                deletedSidecarBytes: 0,
                deletedPaths: [],
                skipped: [],
                failures: [],
                cancelled: false
            )
        }

        var deletedAudioCount = 0
        var deletedAudioBytes: Int64 = 0
        var deletedSidecarCount = 0
        var deletedSidecarBytes: Int64 = 0
        var deletedPaths: [String] = []
        var skipped: [AudioCleanupSkip] = []
        var failures: [AudioCleanupFailure] = []

        func result(cancelled: Bool = false) -> AudioCleanupResult {
            AudioCleanupResult(
                requestedCount: selectedCandidates.count,
                deletedAudioCount: deletedAudioCount,
                deletedAudioBytes: deletedAudioBytes,
                deletedSidecarCount: deletedSidecarCount,
                deletedSidecarBytes: deletedSidecarBytes,
                deletedPaths: deletedPaths,
                skipped: skipped,
                failures: failures,
                cancelled: cancelled
            )
        }

        func appendSkip(
            _ candidate: UnreferencedAudioCandidate,
            reason: AudioCleanupSkipReason,
            detail: String
        ) {
            skipped.append(AudioCleanupSkip(
                id: "\(candidate.id)-\(reason.rawValue)",
                path: candidate.path,
                reason: reason,
                detail: detail
            ))
        }

        func appendFailure(_ path: String, _ message: String) {
            failures.append(AudioCleanupFailure(
                id: "\(path)-\(failures.count)",
                path: path,
                message: message
            ))
        }

        let initialActivity = activityProvider()
        if initialActivity.blockAllDeletion {
            selectedCandidates.forEach {
                appendSkip(
                    $0,
                    reason: Self.cleanupSkipReason(for: initialActivity),
                    detail: initialActivity.reason ?? "A local operation is still active."
                )
            }
            return result()
        }

        // Verify that the store and directory are readable before any delete.
        // A failure here must never be interpreted as an empty folder.
        let documentsURL = try requiredDocumentsURL()
        // Rebuilding the reference and protection sets per candidate meant one
        // full-store fetch and a `resolvingSymlinksInPath` syscall per recording
        // for every selected file. They are derived from the store alone, so the
        // watcher recomputes them only once the store has actually changed —
        // which is still "immediately before deletion" for every guard below.
        let storeWatcher = DatabaseChangeWatcher()
        defer { storeWatcher.stop() }
        var cachedEvaluation: ProtectionEvaluation?

        func currentEvaluation() throws -> ProtectionEvaluation {
            if let cachedEvaluation, !storeWatcher.hasChanged {
                return cachedEvaluation
            }
            storeWatcher.markEvaluated()
            let evaluation = Self.protectionEvaluation(
                snapshot: try makeProtectionSnapshot(),
                documentsURL: documentsURL
            )
            cachedEvaluation = evaluation
            return evaluation
        }

        func appendUnevaluatedSkips(after index: Int, detail: String) {
            let remaining = index + 1
            guard remaining < selectedCandidates.count else { return }
            for candidate in selectedCandidates[remaining...] {
                appendSkip(candidate, reason: .notEvaluated, detail: detail)
            }
        }

        let initialFiles = try await regularAudioFiles(in: documentsURL)
        let initialFilesByPath = Dictionary(
            initialFiles.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let initialProcessingProtection = try currentEvaluation().processing
        if initialProcessingProtection.blocksAll {
            selectedCandidates.forEach {
                appendSkip(
                    $0,
                    reason: .activeProcessingJob,
                    detail: initialProcessingProtection.reason ?? "A processing job has an unknown active state."
                )
            }
            return result()
        }

        for (candidateIndex, candidate) in selectedCandidates.enumerated() {
            do {
                try Task.checkCancellation()
            } catch {
                return result(cancelled: true)
            }

            guard Self.isDirectChild(path: candidate.path, of: documentsURL) else {
                appendSkip(
                    candidate,
                    reason: .outsideScope,
                    detail: "Only regular audio files directly inside Documents can be removed."
                )
                continue
            }

            guard Self.orphanedAudioExtensions.contains(
                URL(fileURLWithPath: candidate.path).pathExtension.lowercased()
            ) else {
                appendSkip(
                    candidate,
                    reason: .outsideScope,
                    detail: "Only m4a, wav, mp3, and aac files can be removed."
                )
                continue
            }

            guard let initialFile = initialFilesByPath[candidate.path],
                  Self.fingerprintsMatch(candidate.fingerprint, initialFile) else {
                appendSkip(
                    candidate,
                    reason: .changedOrReplaced,
                    detail: "It is not the same regular audio file that was present in the current review snapshot."
                )
                continue
            }

            let firstEvaluation: ProtectionEvaluation
            do {
                firstEvaluation = try currentEvaluation()
            } catch {
                let message = AdvancedTroubleshootingError
                    .databaseReadFailed(error.localizedDescription).localizedDescription
                appendFailure(candidate.path, message)
                appendUnevaluatedSkips(
                    after: candidateIndex,
                    detail: "The run stopped because the local database could not be read."
                )
                break
            }

            let candidateURL = URL(fileURLWithPath: candidate.path)
            let firstMetadata: AudioFileFingerprint
            do {
                firstMetadata = try await metadata(for: candidateURL)
            } catch {
                if Self.isMissingFileError(error) {
                    appendSkip(candidate, reason: .missing, detail: "The reviewed audio file is no longer present.")
                } else {
                    appendFailure(candidate.path, error.localizedDescription)
                }
                continue
            }

            guard Self.fingerprintsMatch(candidate.fingerprint, firstMetadata) else {
                appendSkip(
                    candidate,
                    reason: .changedOrReplaced,
                    detail: "Its size, modification time, or file identity changed after the scan."
                )
                continue
            }

            if firstEvaluation.referencedPaths.contains(candidate.path) {
                appendSkip(
                    candidate,
                    reason: .becameReferenced,
                    detail: "A current local recording now references this path."
                )
                continue
            }

            let firstProcessingProtection = firstEvaluation.processing
            if firstProcessingProtection.blocksAll
                || firstProcessingProtection.protectedPaths.contains(candidate.path) {
                appendSkip(
                    candidate,
                    reason: .activeProcessingJob,
                    detail: firstProcessingProtection.reason ?? "A current processing job owns this path."
                )
                continue
            }

            let firstActivity = activityProvider()
            if firstActivity.blockAllDeletion {
                appendSkip(
                    candidate,
                    reason: Self.cleanupSkipReason(for: firstActivity),
                    detail: firstActivity.reason ?? "A local operation started during revalidation."
                )
                continue
            }
            if firstActivity.ownedPaths.contains(candidate.path) {
                appendSkip(
                    candidate,
                    reason: .activeRecording,
                    detail: "The recorder currently owns this path."
                )
                continue
            }

            // Identity is confirmed before the ownership guards, not after, so
            // that no suspension separates those guards from the delete. Reading
            // metadata hands the main actor back, and a recording, import,
            // processing job, or restore that starts in that gap would otherwise
            // claim this path after the last check had already passed.
            let finalMetadata: AudioFileFingerprint
            do {
                finalMetadata = try await metadata(for: candidateURL)
            } catch {
                if Self.isMissingFileError(error) {
                    appendSkip(candidate, reason: .missing, detail: "The reviewed audio file is no longer present.")
                } else {
                    appendFailure(candidate.path, error.localizedDescription)
                }
                continue
            }

            guard Self.fingerprintsMatch(candidate.fingerprint, finalMetadata) else {
                appendSkip(
                    candidate,
                    reason: .changedOrReplaced,
                    detail: "Its identity changed during final revalidation."
                )
                continue
            }

            // Everything from here to `deleteFile` runs without an `await`, so
            // the store and the owning operations cannot change underneath these
            // last checks. This second read closes the review-to-delete race: a
            // reference or processing job may have appeared while metadata was
            // being checked just above.
            let finalEvaluation: ProtectionEvaluation
            do {
                finalEvaluation = try currentEvaluation()
            } catch {
                let message = AdvancedTroubleshootingError
                    .databaseReadFailed(error.localizedDescription).localizedDescription
                appendFailure(candidate.path, message)
                appendUnevaluatedSkips(
                    after: candidateIndex,
                    detail: "The run stopped because the local database could not be read."
                )
                break
            }

            if finalEvaluation.referencedPaths.contains(candidate.path) {
                appendSkip(
                    candidate,
                    reason: .becameReferenced,
                    detail: "A local recording started referencing this path during revalidation."
                )
                continue
            }

            let finalProcessingProtection = finalEvaluation.processing
            if finalProcessingProtection.blocksAll
                || finalProcessingProtection.protectedPaths.contains(candidate.path) {
                appendSkip(
                    candidate,
                    reason: .activeProcessingJob,
                    detail: finalProcessingProtection.reason ?? "A processing job started during revalidation."
                )
                continue
            }

            let finalActivity = activityProvider()
            if finalActivity.blockAllDeletion {
                appendSkip(
                    candidate,
                    reason: Self.cleanupSkipReason(for: finalActivity),
                    detail: finalActivity.reason ?? "A local operation started during final revalidation."
                )
                continue
            }
            if finalActivity.ownedPaths.contains(candidate.path) {
                appendSkip(
                    candidate,
                    reason: .activeRecording,
                    detail: "The recorder now owns this path."
                )
                continue
            }

            do {
                try Task.checkCancellation()
                // Removed without hopping off the main actor, so the guards
                // above and the removal are one uninterrupted step. Unlinking a
                // single file is a single syscall; handing it to a detached task
                // would reopen the very window those guards just closed.
                try fileSystem.deleteFile(at: candidateURL)
                deletedAudioCount += 1
                deletedAudioBytes += candidate.byteCount
                deletedPaths.append(candidate.path)
            } catch is CancellationError {
                return result(cancelled: true)
            } catch {
                appendFailure(candidate.path, error.localizedDescription)
                continue
            }

            // Sidecars are keyed by base name, not by audio extension, so
            // `interview_2026-01-01_10-00-00.m4a` and the `.wav` beside it share
            // one `.location` and one `.recordingmeta`. Removing the sidecars of
            // an unreferenced file would then strip the location and metadata off
            // whichever sibling is still referenced, so they survive unless this
            // base name belongs to the deleted file alone. A failed check leaves
            // them in place too: an unprovable sibling is treated as a real one.
            let sidecarsAreShared: Bool
            do {
                sidecarsAreShared = try await hasOtherAudioSibling(
                    ofCandidatePath: candidate.path
                )
            } catch {
                sidecarsAreShared = true
            }
            guard !sidecarsAreShared else {
                appendSkip(
                    candidate,
                    reason: .sidecarShared,
                    detail: "Its sidecars are shared with another audio file of the same name and were kept."
                )
                continue
            }

            // Sidecars are explicitly limited to the two formats used by the
            // app and are removed only as siblings of a successfully removed
            // selected audio file.
            for sidecarExtension in Self.permittedSidecarExtensions {
                if Task.isCancelled {
                    return result(cancelled: true)
                }
                let sidecarURL = candidateURL
                    .deletingPathExtension()
                    .appendingPathExtension(sidecarExtension)
                let sidecarPath = Self.canonicalPath(for: sidecarURL)
                guard Self.isDirectChild(path: sidecarPath, of: documentsURL) else { continue }

                let sidecarMetadata: AudioFileFingerprint
                do {
                    sidecarMetadata = try await metadata(for: sidecarURL)
                } catch {
                    if Self.isMissingFileError(error) { continue }
                    appendFailure(sidecarPath, error.localizedDescription)
                    continue
                }

                do {
                    try Task.checkCancellation()
                    try await deleteFile(at: sidecarURL)
                    deletedSidecarCount += 1
                    deletedSidecarBytes += sidecarMetadata.byteCount
                } catch is CancellationError {
                    return result(cancelled: true)
                } catch {
                    appendFailure(sidecarPath, error.localizedDescription)
                }
            }
        }

        return result()
    }
    // swiftlint:enable cyclomatic_complexity function_body_length

    // MARK: Snapshot construction

    /// Fetches only the rows the reviewed-audio guards read.
    ///
    /// Deliberately does not touch `TranscriptEntry` or `SummaryEntry`: both
    /// carry the full text bodies, and nothing in `deleteSelectedAudio` or
    /// `buildAudioScan` consults them.
    private func makeProtectionSnapshot() throws -> TroubleshootingProtectionSnapshot {
        do {
            let recordings = try databaseReader.fetchRecordingsForDiagnostics()
            let processingJobs = try databaseReader.fetchProcessingJobsForDiagnostics()
            return TroubleshootingProtectionSnapshot(
                recordings: recordings.map(Self.recordingValue),
                processingJobs: processingJobs.map(Self.processingJobValue)
            )
        } catch {
            throw AdvancedTroubleshootingError.databaseReadFailed(error.localizedDescription)
        }
    }

    private static func recordingValue(
        _ entry: RecordingEntry
    ) -> AdvancedTroubleshootingDatabaseSnapshot.Recording {
        AdvancedTroubleshootingDatabaseSnapshot.Recording(
            id: entry.id,
            name: entry.recordingName,
            storedURL: entry.recordingURL,
            audioQuality: entry.audioQuality,
            isArchived: entry.isArchived,
            transcriptID: entry.transcriptId ?? entry.transcript?.id,
            summaryID: entry.summaryId ?? entry.summary?.id,
            relationshipTranscriptID: entry.transcript?.id,
            relationshipSummaryID: entry.summary?.id
        )
    }

    private static func processingJobValue(
        _ entry: ProcessingJobEntry
    ) -> AdvancedTroubleshootingDatabaseSnapshot.ProcessingJob {
        AdvancedTroubleshootingDatabaseSnapshot.ProcessingJob(
            id: entry.id,
            recordingURL: entry.recordingURL,
            recordingID: entry.recording?.id,
            status: entry.status
        )
    }

    private func makeDatabaseSnapshot() throws -> AdvancedTroubleshootingDatabaseSnapshot {
        do {
            let recordings = try databaseReader.fetchRecordingsForDiagnostics()
            let transcripts = try databaseReader.fetchTranscriptsForDiagnostics()
            let summaries = try databaseReader.fetchSummariesForDiagnostics()
            let processingJobs = try databaseReader.fetchProcessingJobsForDiagnostics()

            return AdvancedTroubleshootingDatabaseSnapshot(
                recordings: recordings.map(Self.recordingValue),
                transcripts: transcripts.map {
                    AdvancedTroubleshootingDatabaseSnapshot.Transcript(
                        id: $0.id,
                        recordingID: $0.recordingId,
                        relationshipRecordingID: $0.recording?.id
                    )
                },
                summaries: summaries.map {
                    AdvancedTroubleshootingDatabaseSnapshot.Summary(
                        id: $0.id,
                        recordingID: $0.recordingId,
                        transcriptID: $0.transcriptId,
                        relationshipRecordingID: $0.recording?.id,
                        relationshipTranscriptID: $0.transcript?.id
                    )
                },
                processingJobs: processingJobs.map(Self.processingJobValue)
            )
        } catch {
            throw AdvancedTroubleshootingError.databaseReadFailed(error.localizedDescription)
        }
    }

    private func requiredDocumentsURL() throws -> URL {
        guard let documentsURL else {
            throw AdvancedTroubleshootingError.documentsDirectoryUnavailable
        }
        return documentsURL
    }

    private func regularAudioFiles(in documentsURL: URL) async throws -> [AudioFileFingerprint] {
        let fileSystem = self.fileSystem
        do {
            return try await Self.runCancellable {
                try fileSystem.regularFiles(
                    in: documentsURL,
                    allowedExtensions: Self.orphanedAudioExtensions
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AdvancedTroubleshootingError {
            throw error
        } catch {
            throw AdvancedTroubleshootingError.directoryReadFailed(error.localizedDescription)
        }
    }

    private func metadata(for url: URL) async throws -> AudioFileFingerprint {
        let fileSystem = self.fileSystem
        return try await Self.runCancellable {
            try fileSystem.metadata(for: url)
        }
    }

    private func deleteFile(at url: URL) async throws {
        let fileSystem = self.fileSystem
        try await Self.runCancellable {
            try fileSystem.deleteFile(at: url)
        }
    }

    /// True when another audio file in the same folder shares this file's base
    /// name, which means the `.location` and `.recordingmeta` sidecars beside it
    /// may belong to that sibling rather than to the file being removed.
    ///
    /// Every audio extension the report understands is checked, not just the
    /// four the scan offers for deletion: an `.aiff` sibling owns its sidecars
    /// exactly as much as an `.m4a` one does.
    private func hasOtherAudioSibling(ofCandidatePath path: String) async throws -> Bool {
        let base = URL(fileURLWithPath: path).deletingPathExtension()
        for fileExtension in Self.reportAudioExtensions.sorted() {
            let siblingURL = base.appendingPathExtension(fileExtension)
            guard Self.canonicalPath(for: siblingURL) != path else { continue }
            do {
                _ = try await metadata(for: siblingURL)
                return true
            } catch {
                if Self.isMissingFileError(error) { continue }
                throw error
            }
        }
        return false
    }

    // MARK: Pure evaluation

    // Keep report predicates together so each diagnostic is derived from the
    // same immutable snapshot and cannot accidentally mutate local state.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    nonisolated private static func buildLocalDataReport(
        snapshot: AdvancedTroubleshootingDatabaseSnapshot,
        documentsURL: URL,
        fileSystem: any AdvancedTroubleshootingFileSystem,
        generatedAt: Date
    ) throws -> LocalDataReport {
        var issues: [LocalDataIssue] = []
        var warnings: [String] = []
        var status = LocalDataInspectionStatus.complete

        let recordingIDs = Set(snapshot.recordings.compactMap(\.id))
        let transcriptIDs = Set(snapshot.transcripts.compactMap(\.id))
        let summaryIDs = Set(snapshot.summaries.compactMap(\.id))

        func addIssue(_ category: LocalDataIssueCategory, _ key: String, _ message: String) {
            issues.append(
                LocalDataIssue(
                    id: "\(category.rawValue)-\(key)-\(issues.count)",
                    category: category,
                    message: message
                )
            )
        }

        for (index, recording) in snapshot.recordings.enumerated() where recording.id == nil {
            addIssue(.relationship, "recording-missing-id-\(index)", "A recording row has no stable identity.")
        }
        for (index, transcript) in snapshot.transcripts.enumerated() where transcript.id == nil {
            addIssue(.relationship, "transcript-missing-id-\(index)", "A transcript row has no stable identity.")
        }
        for (index, summary) in snapshot.summaries.enumerated() where summary.id == nil {
            addIssue(.relationship, "summary-missing-id-\(index)", "A summary row has no stable identity.")
        }

        for group in Dictionary(
            grouping: snapshot.recordings.compactMap { $0.id },
            by: { $0 }
        ) where group.value.count > 1 {
            addIssue(
                .duplicateIdentity,
                "recording-\(group.key.uuidString)",
                "Multiple recording rows share ID \(group.key.uuidString)."
            )
        }
        for group in Dictionary(
            grouping: snapshot.transcripts.compactMap { $0.id },
            by: { $0 }
        ) where group.value.count > 1 {
            addIssue(
                .duplicateIdentity,
                "transcript-\(group.key.uuidString)",
                "Multiple transcript rows share ID \(group.key.uuidString)."
            )
        }
        for group in Dictionary(
            grouping: snapshot.summaries.compactMap { $0.id },
            by: { $0 }
        ) where group.value.count > 1 {
            addIssue(
                .duplicateIdentity,
                "summary-\(group.key.uuidString)",
                "Multiple summary rows share ID \(group.key.uuidString)."
            )
        }

        let transcriptReferences = snapshot.transcripts.compactMap { transcript ->
            (UUID, AdvancedTroubleshootingDatabaseSnapshot.Transcript)? in
            guard let recordingID = transcript.recordingID else { return nil }
            return (recordingID, transcript)
        }
        let transcriptsByRecording = Dictionary(grouping: transcriptReferences, by: { $0.0 })
        for (recordingID, values) in transcriptsByRecording where values.count > 1 {
            addIssue(
                .relationship,
                "transcripts-for-\(recordingID.uuidString)",
                "Multiple transcripts reference recording \(recordingID.uuidString)."
            )
        }

        let summaryReferences = snapshot.summaries.compactMap { summary ->
            (UUID, AdvancedTroubleshootingDatabaseSnapshot.Summary)? in
            guard let recordingID = summary.recordingID else { return nil }
            return (recordingID, summary)
        }
        let summariesByRecording = Dictionary(grouping: summaryReferences, by: { $0.0 })
        for (recordingID, values) in summariesByRecording where values.count > 1 {
            addIssue(
                .relationship,
                "summaries-for-\(recordingID.uuidString)",
                "Multiple summaries reference recording \(recordingID.uuidString)."
            )
        }

        for recording in snapshot.recordings {
            guard let recordingID = recording.id else { continue }
            let recordingLabel = displayName(recording.name, fallback: recordingID.uuidString)

            if let transcriptID = recording.transcriptID, !transcriptIDs.contains(transcriptID) {
                addIssue(
                    .relationship,
                    "recording-transcript-\(recordingID.uuidString)",
                    "Recording \(recordingLabel) points to a missing transcript."
                )
            }
            if let summaryID = recording.summaryID, !summaryIDs.contains(summaryID) {
                addIssue(
                    .relationship,
                    "recording-summary-\(recordingID.uuidString)",
                    "Recording \(recordingLabel) points to a missing summary."
                )
            }

            // Both sides can name a row that exists, so the missing-row checks
            // above pass while the two still disagree. `transcriptID` only falls
            // back to the relationship when the column is empty, so a mismatch
            // here means the column and the relationship name different rows.
            if let transcriptID = recording.transcriptID,
               let relationshipTranscriptID = recording.relationshipTranscriptID,
               relationshipTranscriptID != transcriptID {
                addIssue(
                    .relationship,
                    "recording-transcript-conflict-\(recordingID.uuidString)",
                    "Recording \(recordingLabel) has conflicting transcript identities."
                )
            }
            if let summaryID = recording.summaryID,
               let relationshipSummaryID = recording.relationshipSummaryID,
               relationshipSummaryID != summaryID {
                addIssue(
                    .relationship,
                    "recording-summary-conflict-\(recordingID.uuidString)",
                    "Recording \(recordingLabel) has conflicting summary identities."
                )
            }
        }

        for transcript in snapshot.transcripts {
            guard let transcriptID = transcript.id else { continue }
            if let recordingID = transcript.recordingID {
                if !recordingIDs.contains(recordingID) {
                    addIssue(
                        .relationship,
                        "transcript-recording-\(transcriptID.uuidString)",
                        "Transcript \(transcriptID.uuidString) points to a missing recording."
                    )
                }
                if let relationshipRecordingID = transcript.relationshipRecordingID,
                   relationshipRecordingID != recordingID {
                    addIssue(
                        .relationship,
                        "transcript-relationship-\(transcriptID.uuidString)",
                        "Transcript \(transcriptID.uuidString) has conflicting recording identities."
                    )
                } else if transcript.relationshipRecordingID == nil {
                    addIssue(
                        .relationship,
                        "transcript-link-\(transcriptID.uuidString)",
                        "Transcript \(transcriptID.uuidString) has no recording relationship."
                    )
                }
            } else if transcript.relationshipRecordingID != nil {
                addIssue(
                    .relationship,
                    "transcript-denormalized-\(transcriptID.uuidString)",
                    "Transcript \(transcriptID.uuidString) has a relationship without a recording ID."
                )
            }
        }

        for summary in snapshot.summaries {
            guard let summaryID = summary.id else { continue }
            if let recordingID = summary.recordingID {
                if !recordingIDs.contains(recordingID) {
                    addIssue(
                        .relationship,
                        "summary-recording-\(summaryID.uuidString)",
                        "Summary \(summaryID.uuidString) points to a missing recording."
                    )
                }
                if let relationshipRecordingID = summary.relationshipRecordingID,
                   relationshipRecordingID != recordingID {
                    addIssue(
                        .relationship,
                        "summary-relationship-\(summaryID.uuidString)",
                        "Summary \(summaryID.uuidString) has conflicting recording identities."
                    )
                } else if summary.relationshipRecordingID == nil {
                    addIssue(
                        .relationship,
                        "summary-link-\(summaryID.uuidString)",
                        "Summary \(summaryID.uuidString) has no recording relationship."
                    )
                }
            } else if summary.relationshipRecordingID != nil {
                addIssue(
                    .relationship,
                    "summary-denormalized-\(summaryID.uuidString)",
                    "Summary \(summaryID.uuidString) has a relationship without a recording ID."
                )
            }

            if let transcriptID = summary.transcriptID {
                if !transcriptIDs.contains(transcriptID) {
                    addIssue(
                        .relationship,
                        "summary-transcript-\(summaryID.uuidString)",
                        "Summary \(summaryID.uuidString) points to a missing transcript."
                    )
                }
                if let relationshipTranscriptID = summary.relationshipTranscriptID,
                   relationshipTranscriptID != transcriptID {
                    addIssue(
                        .relationship,
                        "summary-transcript-relationship-\(summaryID.uuidString)",
                        "Summary \(summaryID.uuidString) has conflicting transcript identities."
                    )
                }
            } else if summary.relationshipTranscriptID != nil {
                addIssue(
                    .relationship,
                    "summary-transcript-denormalized-\(summaryID.uuidString)",
                    "Summary \(summaryID.uuidString) has a transcript relationship without a transcript ID."
                )
            }
        }

        let classifications = snapshot.recordings.map { recording in
            let hasTranscript = recording.transcriptID != nil
            let hasSummary = recording.summaryID != nil
            let kind: LocalDataRecordKind
            if recording.isArchived {
                kind = .archived
            } else if recording.audioQuality?.lowercased() == "imported" {
                kind = .imported
            } else if hasSummary && !hasTranscript {
                kind = .summaryOnly
            } else if recording.storedURL == nil {
                kind = .metadataOnly
            } else {
                kind = .regular
            }

            let id = recording.id?.uuidString ?? "row-\(recording.name ?? "unnamed")"
            return LocalDataRecordClassification(
                id: id,
                name: displayName(recording.name, fallback: "Untitled recording"),
                kind: kind
            )
        }

        // The listing answers "is this recording's audio present?" for every
        // file directly inside Documents, so it is kept as a lookup set rather
        // than stat'ed once here and then re-stat'ed per recording below.
        var documentsAudioPaths: Set<String> = []
        do {
            let documentsAudio = try fileSystem.regularFiles(
                in: documentsURL,
                allowedExtensions: reportAudioExtensions
            )
            documentsAudioPaths = Set(documentsAudio.map(\.path))
        } catch {
            status = .failed
            let message = "The local Documents audio scan failed: \(error.localizedDescription)"
            warnings.append(message)
            addIssue(.inspection, "documents-audio", message)
        }

        for recording in snapshot.recordings {
            try Task.checkCancellation()

            guard !recording.isArchived,
                  recording.audioQuality?.lowercased() != "imported",
                  recording.storedURL != nil,
                  recording.summaryID == nil || recording.transcriptID != nil,
                  let storedURL = recording.storedURL,
                  let resolvedURL = storedURLCandidates(storedURL, documentsURL: documentsURL).first,
                  reportAudioExtensions.contains(resolvedURL.pathExtension.lowercased()) else {
                continue
            }

            var foundAudio = false
            var inspectionError: Error?
            for candidateURL in storedURLCandidates(storedURL, documentsURL: documentsURL) {
                // Anything the listing already found needs no second stat. Only
                // paths it could not cover — a nested folder, or a run where the
                // listing itself failed — fall through to the file system.
                if documentsAudioPaths.contains(canonicalPath(for: candidateURL)) {
                    foundAudio = true
                    break
                }
                do {
                    _ = try fileSystem.metadata(for: candidateURL)
                    foundAudio = true
                    break
                } catch {
                    if !isMissingFileError(error) {
                        inspectionError = error
                        break
                    }
                }
            }

            guard !foundAudio else { continue }
            if let inspectionError {
                status = status == .failed ? .failed : .partial
                let label = displayName(recording.name, fallback: "recording")
                let message = "Could not inspect audio for \(label): "
                    + inspectionError.localizedDescription
                warnings.append(message)
                addIssue(.inspection, "audio-\(recording.id?.uuidString ?? storedURL)", message)
            } else {
                let label = displayName(recording.name, fallback: recording.id?.uuidString ?? "recording")
                addIssue(
                    .missingAudio,
                    "missing-\(recording.id?.uuidString ?? storedURL)",
                    "\(label) references local audio that is not present: \(storedURL)."
                )
            }
        }

        return LocalDataReport(
            generatedAt: generatedAt,
            status: status,
            recordingCount: snapshot.recordings.count,
            transcriptCount: snapshot.transcripts.count,
            summaryCount: snapshot.summaries.count,
            processingJobCount: snapshot.processingJobs.count,
            classifications: classifications,
            issues: issues,
            warnings: warnings
        )
    }

    nonisolated private static func buildAudioScan(
        snapshot: TroubleshootingProtectionSnapshot,
        documentsURL: URL,
        fileSystem: any AdvancedTroubleshootingFileSystem,
        activity: AdvancedTroubleshootingActivitySnapshot,
        generatedAt: Date
    ) throws -> UnreferencedAudioScanResult {
        let files = try fileSystem.regularFiles(in: documentsURL, allowedExtensions: orphanedAudioExtensions)
        let evaluation = protectionEvaluation(snapshot: snapshot, documentsURL: documentsURL)
        let referencedPaths = evaluation.referencedPaths
        let processingProtection = evaluation.processing
        let ownedPaths = activity.ownedPaths.union(processingProtection.protectedPaths)

        let candidates = files.compactMap { file -> UnreferencedAudioCandidate? in
            guard isDirectChild(path: file.path, of: documentsURL) else { return nil }
            guard !referencedPaths.contains(file.path) else { return nil }
            guard !ownedPaths.contains(file.path) else { return nil }
            return UnreferencedAudioCandidate(
                id: file.path,
                path: file.path,
                fileName: URL(fileURLWithPath: file.path).lastPathComponent,
                byteCount: file.byteCount,
                fingerprint: file
            )
        }

        let candidatePaths = Set(candidates.map(\.path))
        let protectedFileCount = files.count - candidatePaths.count
        let deletionUnavailableReason: String?
        if activity.blockAllDeletion {
            deletionUnavailableReason = activity.reason
                ?? "A local recording or import is active. Finish it before deleting audio."
        } else if processingProtection.blocksAll {
            deletionUnavailableReason = processingProtection.reason ?? "A processing job has an unknown active state."
        } else {
            deletionUnavailableReason = nil
        }

        return UnreferencedAudioScanResult(
            generatedAt: generatedAt,
            directoryDescription: "Non-hidden regular m4a, wav, mp3, and aac files directly inside Documents",
            candidates: candidates,
            protectedFileCount: max(0, protectedFileCount),
            deletionUnavailableReason: deletionUnavailableReason
        )
    }

    /// Everything the guards derive from one store read, computed together.
    ///
    /// Both halves walk every recording and resolve symlinks per stored URL, so
    /// they are built once per snapshot rather than once per reviewed file.
    private struct ProtectionEvaluation: Sendable {
        let referencedPaths: Set<String>
        let processing: ProcessingProtection
    }

    nonisolated private static func protectionEvaluation(
        snapshot: TroubleshootingProtectionSnapshot,
        documentsURL: URL
    ) -> ProtectionEvaluation {
        ProtectionEvaluation(
            referencedPaths: referencedPaths(in: snapshot, documentsURL: documentsURL),
            processing: processingProtection(snapshot: snapshot, documentsURL: documentsURL)
        )
    }

    nonisolated private static func referencedPaths(
        in snapshot: TroubleshootingProtectionSnapshot,
        documentsURL: URL
    ) -> Set<String> {
        Set(snapshot.recordings.flatMap { (recording) -> [String] in
            guard let storedURL = recording.storedURL else { return [] }
            return storedURLCandidates(storedURL, documentsURL: documentsURL)
                .map { canonicalPath(for: $0) }
        })
    }

    private struct ProcessingProtection: Sendable {
        let blocksAll: Bool
        let reason: String?
        let protectedPaths: Set<String>
    }

    /// Indexes recordings by id once, so resolving a job's recording does not
    /// scan the whole array per job.
    nonisolated private static func indexedRecordings(
        in snapshot: TroubleshootingProtectionSnapshot
    ) -> [UUID: AdvancedTroubleshootingDatabaseSnapshot.Recording] {
        var indexed: [UUID: AdvancedTroubleshootingDatabaseSnapshot.Recording] = [:]
        for recording in snapshot.recordings {
            guard let id = recording.id else { continue }
            // Duplicate ids are a reported issue, not a crash: keep the first
            // row so the lookup stays deterministic.
            if indexed[id] == nil { indexed[id] = recording }
        }
        return indexed
    }

    nonisolated private static func processingProtection(
        snapshot: TroubleshootingProtectionSnapshot,
        documentsURL: URL
    ) -> ProcessingProtection {
        let terminalStatuses: Set<String> = ["completed", "failed", "cancelled", "canceled"]
        let activeStatuses: Set<String> = [
            "ready", "queued", "processing", "interrupted", "pending", "running",
            "inprogress", "in-progress", "in progress"
        ]
        var protectedPaths: Set<String> = []
        let recordingsByID = indexedRecordings(in: snapshot)

        for job in snapshot.processingJobs {
            guard let normalizedStatus = job.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !normalizedStatus.isEmpty else {
                return ProcessingProtection(
                    blocksAll: true,
                    reason: "A processing job has no readable status, so audio deletion is disabled.",
                    protectedPaths: protectedPaths
                )
            }
            guard !terminalStatuses.contains(normalizedStatus) else { continue }
            guard activeStatuses.contains(normalizedStatus) else {
                return ProcessingProtection(
                    blocksAll: true,
                    reason: "A processing job has an unknown status, so audio deletion is disabled.",
                    protectedPaths: protectedPaths
                )
            }

            var jobPaths: Set<String> = []
            if let recordingURL = job.recordingURL {
                jobPaths.formUnion(
                    storedURLCandidates(recordingURL, documentsURL: documentsURL)
                        .map { canonicalPath(for: $0) }
                )
            }
            if let recordingID = job.recordingID,
               let recording = recordingsByID[recordingID],
               let storedURL = recording.storedURL {
                jobPaths.formUnion(
                    storedURLCandidates(storedURL, documentsURL: documentsURL)
                        .map { canonicalPath(for: $0) }
                )
            }

            guard !jobPaths.isEmpty else {
                return ProcessingProtection(
                    blocksAll: true,
                    reason: "An active processing job has no resolvable recording path, so audio deletion is disabled.",
                    protectedPaths: protectedPaths
                )
            }
            protectedPaths.formUnion(jobPaths)
        }

        return ProcessingProtection(blocksAll: false, reason: nil, protectedPaths: protectedPaths)
    }

    nonisolated static func resolveStoredURL(_ storedURL: String, documentsURL: URL) -> URL? {
        storedURLCandidates(storedURL, documentsURL: documentsURL).first
    }

    /// CoreDataManager owns these rules, including the legacy filename fallback
    /// used when a container path changed. Calling its pure form rather than
    /// restating it keeps this scan protecting exactly the files
    /// `getAbsoluteURL` resolves, and returning both possibilities lets a
    /// diagnostic protect the current file without mutating the managed row.
    nonisolated private static func storedURLCandidates(
        _ storedURL: String,
        documentsURL: URL
    ) -> [URL] {
        CoreDataManager.storedURLCandidates(storedURL, documentsURL: documentsURL)
    }

    nonisolated static func canonicalPath(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    nonisolated private static func isDirectChild(path: String, of directory: URL) -> Bool {
        let directoryPath = canonicalPath(for: directory)
        let candidateURL = URL(fileURLWithPath: path)
        let candidatePath = canonicalPath(for: candidateURL)
        guard candidatePath.hasPrefix(directoryPath + "/") else { return false }
        return URL(fileURLWithPath: candidatePath).deletingLastPathComponent().path == directoryPath
    }

    nonisolated private static func fingerprintsMatch(
        _ expected: AudioFileFingerprint,
        _ current: AudioFileFingerprint
    ) -> Bool {
        guard expected.path == current.path, expected.byteCount == current.byteCount else { return false }
        guard let expectedIdentifier = expected.fileIdentifier,
              let currentIdentifier = current.fileIdentifier,
              expectedIdentifier == currentIdentifier else {
            return false
        }
        return expected.modificationDate == current.modificationDate
    }

    nonisolated private static func isMissingFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(nsError.code)
    }

    nonisolated private static func cleanupSkipReason(
        for activity: AdvancedTroubleshootingActivitySnapshot
    ) -> AudioCleanupSkipReason {
        // `kind` is the only input: it is required at every construction site,
        // so classifying a block by sniffing its user-facing `reason` text for
        // words like "import" would only add a way to get this wrong when that
        // wording is reworded or localized.
        switch activity.kind {
        case .importing:
            return .activeImport
        case .processing:
            return .activeProcessingJob
        case .restore:
            return .activeRestore
        case .recording, .idle:
            return .activeRecording
        }
    }

    nonisolated private static func displayName(_ name: String?, fallback: String) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }
}

/// Reports whether any Core Data context has changed since the last check.
///
/// The reviewed-audio guards must see the store as it is immediately before
/// each delete, but rereading it per file cost a full fetch and a symlink
/// resolution per recording every time. Watching for change notifications
/// instead keeps the same guarantee while collapsing an unchanged run to a
/// single read. It deliberately does not filter by context: a change anywhere
/// re-reads, so an unexpected source of mutation makes the guards more
/// conservative rather than less.
@MainActor
private final class DatabaseChangeWatcher {
    private(set) var hasChanged = true
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .NSManagedObjectContextObjectsDidChange,
            .NSManagedObjectContextDidSave
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hasChanged = true }
            }
        }
    }

    func markEvaluated() {
        hasChanged = false
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}

// swiftlint:enable file_length
