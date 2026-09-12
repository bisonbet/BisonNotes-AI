//
//  FileImportManager.swift
//  Audio Journal
//
//  Handles importing audio files from the device
//

import Foundation
@preconcurrency import AVFoundation
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif
import SwiftUI
import CoreData

private struct SQLiteImportedAudioMetadata: Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let recordingID: UUID
    let recordingName: String
    let recordingDate: Date
    let createdAt: Date
    let duration: TimeInterval
    let fileSize: Int64
    let audioQuality: String
    let transcriptionStatus: String
    let summaryStatus: String
}

private enum SQLiteImportedAudioTransferError: LocalizedError {
    case persistenceUnavailable
    case sourceNotEligible
    case invalidDescriptor
    case destinationUnavailable

    var errorDescription: String? {
        switch self {
        case .persistenceUnavailable:
            return "Durable storage is unavailable for the shared audio import."
        case .sourceNotEligible:
            return "The shared audio source is not in an approved import inbox."
        case .invalidDescriptor:
            return "The shared audio import metadata descriptor is invalid."
        case .destinationUnavailable:
            return "The shared audio import destination is unavailable."
        }
    }
}

private enum SQLiteImportedAudioTransferSupport {
    static let allowedSourceRoots: Set<SQLiteApplicationMediaRootID> = [
        .documentsInbox,
        .shareInbox
    ]

    static func stableKey(
        for sourceURL: URL,
        fileSize: Int64,
        metadataDate: Date
    ) -> String {
        let filenamePrefix = sourceURL.deletingPathExtension()
            .lastPathComponent
            .split(separator: "_", maxSplits: 1, omittingEmptySubsequences: true)
            .first
        if let filenamePrefix,
           let uuid = UUID(uuidString: String(filenamePrefix)) {
            return uuid.uuidString.lowercased()
        }

        let seed = [
            sourceURL.standardizedFileURL.path,
            String(fileSize),
            String(metadataDate.timeIntervalSinceReferenceDate)
        ].joined(separator: "|")
        return SHA256.hash(data: Data(seed.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func stableUUID(for key: String) -> UUID {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let characters = Array(hex)
        let uuidString = [
            String(characters[0..<8]),
            String(characters[8..<12]),
            String(characters[12..<16]),
            String(characters[16..<20]),
            String(characters[20..<32])
        ].joined(separator: "-")
        return UUID(uuidString: uuidString)!
    }

    static func sourceRoot(
        for sourceURL: URL,
        mapping: SQLiteApplicationMediaRootMapping
    ) -> SQLiteApplicationMediaRootID? {
        let candidate = sourceURL.standardizedFileURL
        return allowedSourceRoots
            .sorted { $0.rawValue < $1.rawValue }
            .first { rootID in
                guard let rootURL = mapping.sourceURLs[rootID] else { return false }
                let rootPath = rootURL.standardizedFileURL.path
                let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
                return candidate.path.hasPrefix(prefix)
            }
    }

    static func documentsRelativePath(
        for destinationURL: URL,
        documentsRoot: URL
    ) -> String? {
        let root = documentsRoot.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard destination.path.hasPrefix(prefix) else { return nil }
        let relativePath = String(destination.path.dropFirst(prefix.count))
        return relativePath.isEmpty ? nil : relativePath
    }

    static func datesMatch(_ lhs: Date?, _ rhs: Date) -> Bool {
        guard let lhs else { return false }
        return abs(lhs.timeIntervalSince1970 - rhs.timeIntervalSince1970) < 0.001
    }

    static func durationsMatch(_ lhs: Double?, _ rhs: Double) -> Bool {
        guard let lhs else { return false }
        return abs(lhs - rhs) < 0.001
    }

    static func validate(
        _ existing: LibraryRecordingSnapshot,
        command: LibraryRecordingCreateCommand
    ) throws {
        guard existing.legacyID?.caseInsensitiveCompare(command.id.uuidString) == .orderedSame,
              existing.recordingURL == command.recordingURL,
              existing.name == command.name,
              datesMatch(existing.recordingDate, command.recordingDate),
              datesMatch(existing.lastModified, command.modifiedAt),
              existing.fileSize == command.fileSize,
              durationsMatch(existing.duration, command.duration) else {
            throw LibraryRepositoryError.recordingAlreadyExists(
                reference: command.id.uuidString.lowercased()
            )
        }
    }
}

// MARK: - File Import Manager

@MainActor
class FileImportManager: NSObject, ObservableObject {

    @Published var isImporting = false
    @Published var importProgress: Double = 0.0
    @Published var currentlyImporting: String = ""
    @Published var importResults: ImportResults?
    @Published var showingImportAlert = false

    nonisolated static let supportedExtensions = ["m4a", "mp3", "wav", "caf", "aiff", "aif"]
    nonisolated static let supportedVideoExtensions = ["mp4", "mov", "m4v", "avi", "mkv"]
    private let persistenceController: PersistenceController
    private let context: NSManagedObjectContext
    private let libraryRepository: any LibraryRepository
    private var mediaTransferRuntime: SQLiteApplicationMediaTransferRuntime?
    private var mediaTransferMapping: SQLiteApplicationMediaRootMapping?
    private var mediaTransferRetryTask: Task<Void, Never>?

    override init() {
        let persistenceController = PersistenceController.shared
        self.persistenceController = persistenceController
        self.context = persistenceController.container.viewContext
        self.libraryRepository = CoreDataLibraryRepository(
            context: persistenceController.container.viewContext,
            maintenanceGate: persistenceController.maintenanceGate
        )
        super.init()
    }

    init(persistenceController: PersistenceController) {
        self.persistenceController = persistenceController
        self.context = persistenceController.container.viewContext
        self.libraryRepository = CoreDataLibraryRepository(
            context: persistenceController.container.viewContext,
            maintenanceGate: persistenceController.maintenanceGate
        )
        super.init()
    }

    // MARK: - Import Methods

    func importAudioFiles(
        from urls: [URL],
        useDurableMediaJournal: Bool = false
    ) async {
        guard !isImporting else { return }

        isImporting = true
        importProgress = 0.0
        currentlyImporting = "Preparing..."

        let totalCount = urls.count
        guard totalCount > 0 else {
            completeImport(with: ImportResults(total: 0, successful: 0, failed: 0, errors: []))
            return
        }

        var successful = 0
        var failed = 0
        var errors: [String] = []
        var successfulSourcePaths: Set<String> = []

        for (index, sourceURL) in urls.enumerated() {
            currentlyImporting = "Importing \(sourceURL.lastPathComponent)..."
            importProgress = Double(index) / Double(totalCount)

            do {
                try await importAudioFile(
                    from: sourceURL,
                    useDurableMediaJournal: useDurableMediaJournal
                )
                successful += 1
                successfulSourcePaths.insert(sourceURL.standardizedFileURL.path)
            } catch {
                failed += 1
                errors.append("\(sourceURL.lastPathComponent): \(error.localizedDescription)")
            }

            // Small delay to show progress
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }

        importProgress = 1.0
        currentlyImporting = "Complete"

        let results = ImportResults(
            total: totalCount,
            successful: successful,
            failed: failed,
            errors: errors,
            successfulSourcePaths: successfulSourcePaths
        )

        completeImport(with: results)
    }

    private func importAudioFile(
        from sourceURL: URL,
        useDurableMediaJournal: Bool
    ) async throws {
        let fileExtension = sourceURL.pathExtension.lowercased()

        // Route video files through audio extraction
        if Self.supportedVideoExtensions.contains(fileExtension) {
            try await importVideoFile(from: sourceURL)
            return
        }

        // Validate audio file extension
        guard Self.supportedExtensions.contains(fileExtension) else {
            throw ImportError.unsupportedFormat(fileExtension)
        }

        if useDurableMediaJournal {
            do {
                try await importAudioFileUsingMediaJournal(from: sourceURL)
                return
            } catch SQLiteImportedAudioTransferError.sourceNotEligible {
                // Direct document-picker and web-import URLs can live outside
                // the two inbox roots. Preserve their existing import path;
                // only inbox-owned sources receive journal-driven cleanup.
            }
        }

        // If the filename carries an archive token, try to restore onto the
        // original recording entry rather than create a duplicate.
        if let restoreCandidate = matchArchivedRecording(for: sourceURL) {
            try await restoreArchivedRecording(restoreCandidate, from: sourceURL)
            return
        }

        // Get documents directory
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        // Generate unique filename
        let filename = generateUniqueFilename(for: sourceURL)
        let destinationURL = documentsPath.appendingPathComponent(filename)

        // Check if file already exists
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            throw ImportError.fileAlreadyExists(filename)
        }

        var importCompleted = false
        defer {
            if !importCompleted {
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }

        // Copy file to documents directory with comprehensive error handling for thumbnail issues
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            AppFileProtection.apply(to: destinationURL)

        } catch {
            // Check if this is a thumbnail-related error that we can ignore
            if error.isThumbnailGenerationError {
                AppLog.shared.fileManagement("Thumbnail generation warning: \(error.localizedDescription)", level: .debug)
                // Continue with import even if thumbnail generation fails
                // The file copy operation itself succeeded, only thumbnail generation failed
            } else {
                throw ImportError.copyFailed(error.localizedDescription)
            }
        }
        AppFileProtection.apply(to: destinationURL)

        // Validate the copied file
        try validateAudioFile(at: destinationURL)

        // Create Core Data entry for the imported file
        try await createRecordingEntryForImportedFile(at: destinationURL)
        importCompleted = true

        AppLog.shared.fileManagement("Successfully imported: \(filename)")
    }

    /// Imports an audio file from one of the app's share/document inboxes
    /// through the durable media journal. The source stays in its inbox until
    /// the destination is verified, Core Data metadata is committed, the
    /// receipt is recorded and the source-removal check succeeds.
    private func importAudioFileUsingMediaJournal(from sourceURL: URL) async throws {
        guard persistenceController.storageStatus.isDurable else {
            throw SQLiteImportedAudioTransferError.persistenceUnavailable
        }

        guard let dependencies = try mediaTransferDependencies(createIfMissing: true),
              SQLiteImportedAudioTransferSupport.sourceRoot(
                  for: sourceURL,
                  mapping: dependencies.mapping
              ) != nil else {
            throw SQLiteImportedAudioTransferError.sourceNotEligible
        }

        try validateAudioFile(at: sourceURL)
        let resourceValues = try sourceURL.resourceValues(
            forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey]
        )
        let metadataDate = resourceValues.contentModificationDate
            ?? resourceValues.creationDate
            ?? Date()
        let fileSize = Int64(resourceValues.fileSize ?? 0)
        let duration = await getAudioDuration(url: sourceURL)
        let stableKey = SQLiteImportedAudioTransferSupport.stableKey(
            for: sourceURL,
            fileSize: fileSize,
            metadataDate: metadataDate
        )
        let recordingID = SQLiteImportedAudioTransferSupport.stableUUID(for: stableKey)
        let recordingName = AudioRecorderViewModel.generateImportedFileName(
            originalName: sourceURL.deletingPathExtension().lastPathComponent
        )
        let fileExtension = sourceURL.pathExtension.lowercased()
        let destinationRelativePath = "apprecording-import-\(stableKey).\(fileExtension)"
        let metadata = SQLiteImportedAudioMetadata(
            schemaVersion: SQLiteImportedAudioMetadata.currentSchemaVersion,
            recordingID: recordingID,
            recordingName: recordingName,
            recordingDate: metadataDate,
            createdAt: metadataDate,
            duration: duration,
            fileSize: fileSize,
            audioQuality: "high",
            transcriptionStatus: "Not Started",
            summaryStatus: "Not Started"
        )
        let metadataPayload = try JSONEncoder().encode(metadata)
        let request = SQLiteMediaTransferRequest(
            sourceTransferID: "import-media-\(stableKey)",
            operationID: "import-media-copy-\(stableKey)",
            assetID: "import-media-asset-\(stableKey)",
            ownerStorageID: "core-data-recording-\(recordingID.uuidString.lowercased())",
            ownerRevision: nil,
            sourceURL: sourceURL,
            destinationRootID: SQLiteApplicationMediaRootID.documents.rawValue,
            destinationRelativePath: destinationRelativePath,
            metadataPayload: metadataPayload
        )
        NotificationCenter.default.post(
            name: SQLiteApplicationMediaTransferLifecycle.retryRequested,
            object: nil
        )
        let metadataCommit = makeImportedAudioMetadataCommit(
            mapping: dependencies.mapping
        )
        let result = try await dependencies.runtime.transfer(
            request,
            metadataCommit: metadataCommit
        )
        guard result.sourceRetention == .eligibleForRemoval else {
            throw SQLiteImportedAudioTransferError.destinationUnavailable
        }
        _ = try await dependencies.runtime.removeSourceIfEligible(
            sourceTransferID: request.sourceTransferID,
            operationID: request.operationID
        )
        AppLog.shared.fileManagement(
            "Journaled shared audio import: \(sourceURL.lastPathComponent)"
        )
    }

    /// Replays shared/inbox media operations left by a terminated process.
    /// Only the two inbox roots are eligible for cleanup; generic Documents
    /// media is never removed by this retry pass.
    func retryPendingMediaTransfers() {
        mediaTransferRetryTask?.cancel()
        mediaTransferRetryTask = Task { @MainActor [weak self] in
            await self?.reconcilePendingMediaTransfers(requestOSRetry: true)
        }
    }

    /// Runs one bounded media retry pass and reports whether the caller should
    /// request another opportunity from the OS scheduler.
    func reconcilePendingMediaTransfersForBackgroundTask() async -> Bool {
        mediaTransferRetryTask?.cancel()
        mediaTransferRetryTask = nil
        return await reconcilePendingMediaTransfers(requestOSRetry: false)
    }

    @discardableResult
    private func reconcilePendingMediaTransfers(requestOSRetry: Bool) async -> Bool {
        guard persistenceController.storageStatus.isDurable else { return false }

        do {
            guard let dependencies = try mediaTransferDependencies(createIfMissing: false) else {
                return false
            }
            let maxOperations = 8
            let metadataCommit = makeImportedAudioMetadataCommit(
                mapping: dependencies.mapping
            )
            let report = try await dependencies.runtime.reconcilePending(
                maxOperations: maxOperations,
                metadataCommit: metadataCommit
            )
            let inboxRemoved = try await dependencies.runtime.removeEligibleSources(
                sourceRoot: SQLiteApplicationMediaRootID.documentsInbox.rawValue,
                maxOperations: maxOperations
            )
            let shareRemoved = try await dependencies.runtime.removeEligibleSources(
                sourceRoot: SQLiteApplicationMediaRootID.shareInbox.rawValue,
                maxOperations: maxOperations
            )
            let shouldRetry = report.selectedOperationCount >= maxOperations
                || report.failedOperationCount > 0
                || inboxRemoved >= maxOperations
                || shareRemoved >= maxOperations
            if shouldRetry && requestOSRetry {
                NotificationCenter.default.post(
                    name: SQLiteApplicationMediaTransferLifecycle.retryRequested,
                    object: nil
                )
            }
            if report.selectedOperationCount > 0 || inboxRemoved > 0 || shareRemoved > 0 {
                AppLog.shared.fileManagement(
                    "Shared media retry pass: selected=\(report.selectedOperationCount), "
                        + "completed=\(report.completedOperationCount), "
                        + "failed=\(report.failedOperationCount), "
                        + "sourcesRemoved=\(inboxRemoved + shareRemoved)",
                    level: .debug
                )
            }
            return shouldRetry
        } catch is CancellationError {
            return true
        } catch {
            AppLog.shared.fileManagement(
                "Shared media retry pass failed; sources remain for retry: \(error)",
                level: .error
            )
            if requestOSRetry {
                NotificationCenter.default.post(
                    name: SQLiteApplicationMediaTransferLifecycle.retryRequested,
                    object: nil
                )
            }
            return true
        }
    }

    private func mediaTransferDependencies(
        createIfMissing: Bool
    ) throws -> (
        runtime: SQLiteApplicationMediaTransferRuntime,
        mapping: SQLiteApplicationMediaRootMapping
    )? {
        if let mediaTransferRuntime,
           let mediaTransferMapping {
            return (
                runtime: mediaTransferRuntime,
                mapping: mediaTransferMapping
            )
        }

        let fileManager = FileManager.default
        guard let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw SQLiteImportedAudioTransferError.persistenceUnavailable
        }
        let journalDirectory = applicationSupportURL.appendingPathComponent(
            "SQLiteMigration",
            isDirectory: true
        )
        let databaseURL = journalDirectory.appendingPathComponent(
            "shared-media-transfer-journal.sqlite",
            isDirectory: false
        )
        if !createIfMissing,
           !fileManager.fileExists(atPath: databaseURL.path) {
            return nil
        }

        try fileManager.createDirectory(
            at: journalDirectory,
            withIntermediateDirectories: true
        )
        AppFileProtection.apply(to: journalDirectory)
        let mapping = try SQLiteApplicationMediaRootMapping(
            fileManager: fileManager,
            appGroupIdentifier: ShareExtensionContract.appGroupIdentifier
        )
        let store = try SQLiteLibraryStore(databaseURL: databaseURL)
        AppFileProtection.apply(to: databaseURL)
        let runtime = SQLiteApplicationMediaTransferRuntime(
            coordinator: SQLiteApplicationMediaTransferCoordinator(
                store: store,
                mapping: mapping
            )
        )
        mediaTransferMapping = mapping
        mediaTransferRuntime = runtime
        return (runtime: runtime, mapping: mapping)
    }

    private func makeImportedAudioMetadataCommit(
        mapping: SQLiteApplicationMediaRootMapping
    ) -> SQLiteMediaMetadataCommit {
        let libraryRepository = self.libraryRepository
        return { operation in
            guard let payload = operation.metadataPayload,
                  let metadata = try? JSONDecoder().decode(
                      SQLiteImportedAudioMetadata.self,
                      from: payload
                  ),
                  metadata.schemaVersion == SQLiteImportedAudioMetadata.currentSchemaVersion,
                  let destinationRoot = operation.destinationRoot,
                  let destinationRelativePath = operation.destinationRelativePath,
                  let documentsRoot = mapping.destinationURLs[
                      SQLiteApplicationMediaRootID.documents
                  ] else {
                throw SQLiteImportedAudioTransferError.invalidDescriptor
            }

            let destinationURL: URL
            do {
                destinationURL = try mapping.registry.destinationURL(
                    root: destinationRoot,
                    relativePath: destinationRelativePath
                )
            } catch {
                throw SQLiteImportedAudioTransferError.destinationUnavailable
            }
            let values = try destinationURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  Int64(values.fileSize ?? 0) == metadata.fileSize,
                  operation.expectedByteLength == metadata.fileSize,
                  let recordingURL = SQLiteImportedAudioTransferSupport.documentsRelativePath(
                      for: destinationURL,
                      documentsRoot: documentsRoot
                  ) else {
                throw SQLiteImportedAudioTransferError.destinationUnavailable
            }

            AppFileProtection.apply(to: destinationURL)
            let command = LibraryRecordingCreateCommand(
                id: metadata.recordingID,
                recordingURL: recordingURL,
                name: metadata.recordingName,
                recordingDate: metadata.recordingDate,
                createdAt: metadata.createdAt,
                duration: metadata.duration,
                fileSize: metadata.fileSize,
                audioQuality: metadata.audioQuality,
                transcriptionStatus: metadata.transcriptionStatus,
                summaryStatus: metadata.summaryStatus
            )
            let existingRecordings = try await libraryRepository.fetchRecordingSummaries()
            if let existing = existingRecordings.first(where: { recording in
                recording.legacyID?.caseInsensitiveCompare(
                    metadata.recordingID.uuidString
                ) == .orderedSame
            }) {
                try SQLiteImportedAudioTransferSupport.validate(
                    existing,
                    command: command
                )
            } else {
                do {
                    _ = try await libraryRepository.createRecording(command)
                } catch let error as LibraryRepositoryError {
                    guard case .recordingAlreadyExists = error else {
                        throw error
                    }
                    let recordingsAfterRace = try await libraryRepository.fetchRecordingSummaries()
                    guard let existing = recordingsAfterRace.first(where: { recording in
                        recording.legacyID?.caseInsensitiveCompare(
                            metadata.recordingID.uuidString
                        ) == .orderedSame
                    }) else {
                        throw error
                    }
                    try SQLiteImportedAudioTransferSupport.validate(
                        existing,
                        command: command
                    )
                }
            }
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: NSNotification.Name("RecordingAdded"),
                    object: nil
                )
            }
        }
    }

    /// Decision about how to handle an incoming import URL based on the archive
    /// token embedded in its filename.
    private enum ArchiveMatchResult {
        /// Audio is missing locally — copy the imported file into Documents and
        /// relink it onto this recording entry, clearing archive flags.
        case restoreWithCopy(RecordingEntry)
        /// The recording already has its audio present (user archived without
        /// removing local). Just clear the archive flags.
        case clearFlagsOnly(RecordingEntry)
        /// All matching recordings are healthy duplicates — user is re-importing
        /// a file whose original is already on the device.
        case alreadyImported(String)
    }

    /// Decide how to handle an incoming import URL based on the archive token
    /// embedded in its filename (if any). Returns nil when the file should go
    /// through the regular new-entry import path.
    private func matchArchivedRecording(for sourceURL: URL) -> ArchiveMatchResult? {
        guard let parsed = RecordingArchiveService.parseArchiveToken(fromFilename: sourceURL.lastPathComponent) else {
            return nil
        }

        let fetchRequest: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        let candidates: [RecordingEntry]
        do {
            candidates = try context.fetch(fetchRequest)
        } catch {
            AppLog.shared.fileManagement("Archive restore: fetch failed: \(error.localizedDescription)", level: .error)
            return nil
        }

        let matches = candidates.filter { recording in
            guard let id = recording.id?.uuidString.replacingOccurrences(of: "-", with: "").lowercased() else {
                return false
            }
            return id.hasPrefix(parsed.token)
        }

        guard !matches.isEmpty else { return nil }

        if matches.count > 1 {
            AppLog.shared.fileManagement("Archive restore: \(matches.count) UUID-prefix matches for token \(parsed.token)", level: .debug)
        }

        func hasLocalAudio(_ recording: RecordingEntry) -> Bool {
            guard let urlString = recording.recordingURL,
                  let url = RecordingArchiveService.resolveLocalURL(from: urlString) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }

        // 1. Archived recording missing its audio — the pure restore case.
        if let recording = matches.first(where: { $0.isArchived && !hasLocalAudio($0) }) {
            return .restoreWithCopy(recording)
        }
        // 2. Non-archived recording whose local audio has gone missing — re-link.
        if let recording = matches.first(where: { !$0.isArchived && !hasLocalAudio($0) }) {
            return .restoreWithCopy(recording)
        }
        // 3. Archived but local audio still present (archive kept local copy).
        //    Reuse existing file; just flip the flags.
        if let recording = matches.first(where: { $0.isArchived && hasLocalAudio($0) }) {
            return .clearFlagsOnly(recording)
        }
        // 4. Every match is a healthy, non-archived recording — duplicate import.
        let name = matches.first?.recordingName ?? parsed.baseName
        return .alreadyImported(name)
    }

    private func restoreArchivedRecording(_ match: ArchiveMatchResult, from sourceURL: URL) async throws {
        switch match {
        case .alreadyImported(let name):
            throw ImportError.alreadyImported(name)

        case .clearFlagsOnly(let recording):
            try await RecordingArchiveService.shared.clearArchiveFlags(for: recording)
            NotificationCenter.default.post(name: NSNotification.Name("RecordingAdded"), object: nil)
            AppLog.shared.fileManagement("Cleared archive flags for \(recording.recordingName ?? "unknown") (local audio still present)")

        case .restoreWithCopy(let recording):
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let filename = generateUniqueFilename(for: sourceURL)
            let destinationURL = documentsPath.appendingPathComponent(filename)

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                throw ImportError.fileAlreadyExists(filename)
            }

            var restoreCompleted = false
            defer {
                if !restoreCompleted {
                    try? FileManager.default.removeItem(at: destinationURL)
                }
            }

            do {
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                AppFileProtection.apply(to: destinationURL)
            } catch {
                if error.isThumbnailGenerationError {
                    AppLog.shared.fileManagement("Thumbnail generation warning: \(error.localizedDescription)", level: .debug)
                } else {
                    throw ImportError.copyFailed(error.localizedDescription)
                }
            }
            AppFileProtection.apply(to: destinationURL)

            try validateAudioFile(at: destinationURL)

            try await RecordingArchiveService.shared.restoreRecordingUsingRepository(
                recording,
                newAudioURL: destinationURL
            )
            restoreCompleted = true
            NotificationCenter.default.post(name: NSNotification.Name("RecordingAdded"), object: nil)
            AppLog.shared.fileManagement("Restored archived recording \(recording.recordingName ?? "unknown") from import \(sourceURL.lastPathComponent)")
        }
    }

    private func importVideoFile(from sourceURL: URL) async throws {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let audioFilename = "\(baseName)_\(timestamp).m4a"
        let destinationURL = documentsPath.appendingPathComponent(audioFilename)

        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw ImportError.fileAlreadyExists(audioFilename)
        }

        var importCompleted = false
        defer {
            if !importCompleted {
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }

        let asset = AVURLAsset(url: sourceURL)

        // Verify the asset has an audio track
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw ImportError.invalidAudioFile("Video contains no audio track")
        }

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ImportError.copyFailed("Could not create audio export session")
        }

        exportSession.outputURL = destinationURL
        exportSession.outputFileType = .m4a

        try await exportSession.export(to: destinationURL, as: .m4a)
        AppFileProtection.apply(to: destinationURL)

        // Validate the extracted audio
        try validateAudioFile(at: destinationURL)

        // Create Core Data entry
        try await createRecordingEntryForImportedFile(at: destinationURL)
        importCompleted = true

        AppLog.shared.fileManagement("Successfully extracted audio from video: \(audioFilename)")
    }

    private func generateUniqueFilename(for sourceURL: URL) -> String {
        let originalName = sourceURL.deletingPathExtension().lastPathComponent
        let fileExtension = sourceURL.pathExtension

        // Generate timestamp
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())

        // Create base filename
        let baseFilename = "\(originalName)_\(timestamp).\(fileExtension)"

        // Check if file exists and append number if needed
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destinationURL = documentsPath.appendingPathComponent(baseFilename)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            var counter = 1
            var newFilename = baseFilename

            repeat {
                let nameWithoutExt = originalName
                newFilename = "\(nameWithoutExt)_\(timestamp)_\(counter).\(fileExtension)"
                let newURL = documentsPath.appendingPathComponent(newFilename)

                if !FileManager.default.fileExists(atPath: newURL.path) {
                    break
                }
                counter += 1
            } while true

            return newFilename
        }

        return baseFilename
    }

    private func validateAudioFile(at url: URL) throws {
        // Try to create an AVAudioPlayer to validate the file
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            if player.duration <= 0 {
                throw ImportError.invalidAudioFile("File has no audio content")
            }
        } catch {
            throw ImportError.invalidAudioFile("Unable to read audio file: \(error.localizedDescription)")
        }
    }

    private func completeImport(with results: ImportResults) {
        importResults = results
        isImporting = false
        showingImportAlert = true
        if results.successful > 0 {
            NotificationCenter.default.post(name: NSNotification.Name("RecordingAdded"), object: nil)
        }
    }

    // MARK: - Progress Tracking

    var progressText: String {
        if isImporting {
            return "\(Int(importProgress * 100))% - \(currentlyImporting)"
        }
        return ""
    }

    var canImport: Bool {
        return !isImporting
    }

    // MARK: - Core Data Integration

    private func createRecordingEntryForImportedFile(at fileURL: URL) async throws {
        let originalName = fileURL.deletingPathExtension().lastPathComponent
        let recordingName = AudioRecorderViewModel.generateImportedFileName(originalName: originalName)

        // Check if recording already exists
        let fetchRequest: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "recordingName == %@", recordingName)

        do {
            let existingRecordings = try context.fetch(fetchRequest)
            if !existingRecordings.isEmpty {
                AppLog.shared.fileManagement("Recording entry already exists for imported file", level: .debug)
                return
            }
        } catch {
            AppLog.shared.fileManagement("Error checking for existing recording: \(error)", level: .error)
            throw ImportError.copyFailed("Failed to check existing recordings: \(error.localizedDescription)")
        }

        // Get file metadata. Prefer the file's modification date as the recording
        // date: archives exported by this app stamp mtime with the original
        // recording date, and iCloud preserves mtime across round-trips (while
        // it resets creation date to upload time).
        let metadataDate: Date
        let fileSize: Int64
        let duration: TimeInterval
        do {
            let resourceValues = try fileURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
            let originalDate = resourceValues.contentModificationDate
                ?? resourceValues.creationDate
                ?? Date()
            metadataDate = originalDate
            fileSize = Int64(resourceValues.fileSize ?? 0)

            // Get duration
            duration = await getAudioDuration(url: fileURL)

        } catch {
            AppLog.shared.fileManagement("Error getting file metadata: \(error)", level: .error)
            metadataDate = Date()
            fileSize = 0
            duration = 0
        }

        guard let recordingURL = urlToRelativePath(fileURL) else {
            throw ImportError.copyFailed("Could not represent imported audio path")
        }

        do {
            _ = try await libraryRepository.createRecording(
                LibraryRecordingCreateCommand(
                    recordingURL: recordingURL,
                    name: recordingName,
                    recordingDate: metadataDate,
                    createdAt: metadataDate,
                    duration: duration,
                    fileSize: fileSize,
                    audioQuality: "high",
                    transcriptionStatus: "Not Started",
                    summaryStatus: "Not Started"
                )
            )
            AppLog.shared.fileManagement("Created Core Data entry for imported file")
        } catch {
            AppLog.shared.fileManagement("Failed to save recording metadata: \(error)", level: .error)
            throw ImportError.copyFailed("Failed to save recording metadata: \(error.localizedDescription)")
        }
    }

    private func getAudioDuration(url: URL) async -> TimeInterval {
        do {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            return CMTimeGetSeconds(duration)
        } catch {
            AppLog.shared.fileManagement("Error getting audio duration: \(error)", level: .error)
            return 0
        }
    }

    /// Converts an absolute URL to a relative path for storage
    private func urlToRelativePath(_ url: URL) -> String? {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }

        // Check if URL is within documents directory
        let urlString = url.absoluteString
        let documentsString = documentsURL.absoluteString

        if urlString.hasPrefix(documentsString) {
            // Remove the documents path prefix to get relative path
            let relativePath = String(urlString.dropFirst(documentsString.count))
            return relativePath.isEmpty ? nil : relativePath
        }

        // If not in documents directory, store the filename only
        return url.lastPathComponent
    }
}

// MARK: - Import Errors

enum ImportError: LocalizedError {
    case unsupportedFormat(String)
    case fileAlreadyExists(String)
    case invalidAudioFile(String)
    case copyFailed(String)
    case alreadyImported(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            return "Unsupported format: \(format). Supported audio: m4a, mp3, wav, caf, aiff. Supported video: mp4, mov, m4v"
        case .fileAlreadyExists(let filename):
            return "File already exists: \(filename)"
        case .invalidAudioFile(let reason):
            return "Invalid audio file: \(reason)"
        case .copyFailed(let reason):
            return "Failed to copy file: \(reason)"
        case .alreadyImported(let name):
            return "Already imported: \(name). The original recording still has its audio on this device."
        }
    }
}

// MARK: - Supporting Structures

struct ImportResults {
    let total: Int
    let successful: Int
    let failed: Int
    let errors: [String]
    let successfulSourcePaths: Set<String>

    init(
        total: Int,
        successful: Int,
        failed: Int,
        errors: [String],
        successfulSourcePaths: Set<String> = []
    ) {
        self.total = total
        self.successful = successful
        self.failed = failed
        self.errors = errors
        self.successfulSourcePaths = successfulSourcePaths
    }

    var successRate: Double {
        return total > 0 ? Double(successful) / Double(total) : 0.0
    }

    var formattedSuccessRate: String {
        return String(format: "%.1f%%", successRate * 100)
    }

    var summary: String {
        if total == 0 {
            return "No files selected for import"
        } else if failed == 0 {
            return "Successfully imported all \(successful) files"
        } else {
            return "Imported \(successful) of \(total) files successfully"
        }
    }
}
