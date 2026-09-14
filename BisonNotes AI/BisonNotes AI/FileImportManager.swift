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
    private let coreDataManager: CoreDataManager
    private let context: NSManagedObjectContext
    private let mediaRecoveryStore: MediaOperationRecoveryStore?

    override init() {
        let resolvedPersistenceController = PersistenceController.shared
        let resolvedCoreDataManager = CoreDataManager(persistenceController: resolvedPersistenceController)
        self.persistenceController = resolvedPersistenceController
        self.coreDataManager = resolvedCoreDataManager
        self.context = resolvedCoreDataManager.managedObjectContext
        self.mediaRecoveryStore = MediaOperationRecoveryStore.live()
        super.init()
    }

    init(
        persistenceController: PersistenceController,
        mediaRecoveryStore: MediaOperationRecoveryStore? = nil
    ) {
        let resolvedCoreDataManager = CoreDataManager(persistenceController: persistenceController)
        self.persistenceController = persistenceController
        self.coreDataManager = resolvedCoreDataManager
        self.context = resolvedCoreDataManager.managedObjectContext
        self.mediaRecoveryStore = mediaRecoveryStore ?? MediaOperationRecoveryStore.live()
        super.init()
    }

}

extension FileImportManager {
    // MARK: - Import Methods

    @discardableResult
    func importAudioFiles(from urls: [URL]) async -> Set<URL> {
        guard persistenceController.storeState.isOperational else {
            AppLog.shared.coreData(
                "Audio import withheld because local storage is unavailable",
                level: .fault
            )
            completeImport(with: ImportResults(
                total: urls.count,
                successful: 0,
                failed: urls.count,
                errors: urls.map { "\($0.lastPathComponent): Local storage is unavailable" }
            ))
            return []
        }
        guard !isImporting else { return [] }

        isImporting = true
        importProgress = 0.0
        currentlyImporting = "Preparing..."

        let totalCount = urls.count
        guard totalCount > 0 else {
            completeImport(with: ImportResults(total: 0, successful: 0, failed: 0, errors: []))
            return []
        }

        var acknowledged: Set<URL> = []
        var successful = 0
        var failed = 0
        var errors: [String] = []

        for (index, sourceURL) in urls.enumerated() {
            currentlyImporting = "Importing \(sourceURL.lastPathComponent)..."
            importProgress = Double(index) / Double(totalCount)

            do {
                try await importAudioFile(from: sourceURL)
                acknowledged.insert(sourceURL)
                successful += 1
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
            errors: errors
        )

        completeImport(with: results)
        return acknowledged
    }

    private func importAudioFile(from sourceURL: URL) async throws {
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

        // If the filename carries an archive token, try to restore onto the
        // original recording entry rather than create a duplicate.
        if let restoreCandidate = try matchArchivedRecording(for: sourceURL) {
            try await restoreArchivedRecording(restoreCandidate, from: sourceURL)
            return
        }

        guard let mediaRecoveryStore else {
            throw ImportError.recoveryStateUnavailable
        }

        let startedAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if startedAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let sourceFileSize: Int64
        do {
            let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize, size > 0 else {
                throw ImportError.copyFailed("The source file is empty or its size is unavailable.")
            }
            sourceFileSize = Int64(size)
        } catch let error as ImportError {
            throw error
        } catch {
            throw ImportError.copyFailed("Could not read the source file: \(error.localizedDescription)")
        }
        let sourceFingerprint = try fileFingerprint(for: sourceURL)
        let recordingName = importedRecordingName(for: sourceURL)

        // An earlier metadata failure leaves a published operation receipt.
        // Reuse it only when the source identity matches exactly by size and
        // content; a filename match alone cannot authorize a retry or cleanup.
        if let pending = try mediaRecoveryStore.pendingOperation(
            kind: .audioImport,
            sourceName: sourceURL.lastPathComponent,
            sourceFileSize: sourceFileSize,
            sourceFingerprint: sourceFingerprint
        ) {
            try await retryPendingAudioImport(
                pending,
                recordingName: recordingName,
                mediaRecoveryStore: mediaRecoveryStore
            )
            return
        }

        // Avoid creating a second row when an identical source was already
        // committed. Different content with the same display name remains a
        // distinct import.
        if try hasExistingRecording(named: recordingName, matching: sourceFingerprint) {
            AppLog.shared.fileManagement(
                "Identical imported recording already exists; acknowledging without republishing",
                level: .debug
            )
            return
        }

        try await importNewAudio(from: sourceURL, fileExtension: fileExtension, recordingName: recordingName,
            sourceFileSize: sourceFileSize, sourceFingerprint: sourceFingerprint, mediaRecoveryStore: mediaRecoveryStore)
    }

    private func importNewAudio(from sourceURL: URL, fileExtension: String, recordingName: String,
                                sourceFileSize: Int64, sourceFingerprint: String,
                                mediaRecoveryStore: MediaOperationRecoveryStore) async throws {
        // Get documents directory
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        // Generate unique filename
        let filename = generateUniqueFilename(for: sourceURL)
        let destinationURL = documentsPath.appendingPathComponent(filename)

        // Check if file already exists
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            throw ImportError.fileAlreadyExists(filename)
        }

        var operation: MediaOperation?
        do {
            operation = try mediaRecoveryStore.begin(
                kind: .audioImport,
                sourceName: sourceURL.lastPathComponent,
                destinationURL: destinationURL,
                fileExtension: fileExtension,
                sourceFileSize: sourceFileSize,
                sourceFingerprint: sourceFingerprint
            )
            guard let prepared = operation else {
                throw MediaOperationRecoveryError.unavailable
            }

            operation = try mediaRecoveryStore.stageCopy(from: sourceURL, for: prepared)
            guard let staged = operation else {
                throw MediaOperationRecoveryError.missingStagingArtifact
            }
            try validateAudioFile(at: staged.stagingURL)

            if try hasExistingRecording(named: recordingName, matching: sourceFingerprint) {
                try mediaRecoveryStore.abortBeforePublish(staged)
                operation = nil
                return
            }

            operation = try mediaRecoveryStore.publish(staged)
            guard let published = operation else {
                throw MediaOperationRecoveryError.unavailable
            }
            operation = try mediaRecoveryStore.markMetadataPending(published)

            // The copied file is now app-owned. A failed metadata save leaves
            // the published bytes and receipt available for a later, explicit
            // recovery; the borrowed source is not acknowledged by the caller.
            try await createRecordingEntryForImportedFile(
                at: destinationURL,
                recordingName: recordingName
            )

            if let committed = operation {
                do {
                    let durable = try mediaRecoveryStore.markMetadataCommitted(committed)
                    try mediaRecoveryStore.finish(durable)
                } catch {
                    // Core Data is already the durable commitment. Keeping the
                    // receipt is safe: launch reconciliation can remove it once
                    // the recording URL is verified.
                    AppLog.shared.fileManagement(
                        "Media operation closed with deferred receipt cleanup: \(error.localizedDescription)",
                        level: .error
                    )
                }
            }
        } catch {
            if let operation,
               FileManager.default.fileExists(atPath: operation.publishedURL.path) {
                AppLog.shared.fileManagement(
                    "Imported media retained after a failed metadata/publication step: \(error.localizedDescription)",
                    level: .error
                )
            } else if let operation {
                do {
                    try mediaRecoveryStore.abortBeforePublish(operation)
                } catch {
                    AppLog.shared.fileManagement(
                        "Could not remove failed media staging state: \(error.localizedDescription)",
                        level: .error
                    )
                }
            }

            if let importError = error as? ImportError {
                throw importError
            }
            if error is MediaOperationRecoveryError {
                throw ImportError.recoveryStateUnavailable
            }
            throw ImportError.copyFailed(error.localizedDescription)
        }

        AppLog.shared.fileManagement("Successfully imported: \(filename)")
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
    private func matchArchivedRecording(for sourceURL: URL) throws -> ArchiveMatchResult? {
        guard let parsed = RecordingArchiveService.parseArchiveToken(fromFilename: sourceURL.lastPathComponent) else {
            return nil
        }

        let candidates = try coreDataManager.getAllRecordings()

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
            try RecordingArchiveService.shared.clearArchiveFlags(for: recording)
            NotificationCenter.default.post(name: NSNotification.Name("RecordingAdded"), object: nil)
            AppLog.shared.fileManagement("Cleared archive flags for \(recording.recordingName ?? "unknown") (local audio still present)")

        case .restoreWithCopy(let recording):
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let filename = generateUniqueFilename(for: sourceURL)
            let destinationURL = documentsPath.appendingPathComponent(filename)

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                throw ImportError.fileAlreadyExists(filename)
            }

            guard let mediaRecoveryStore else {
                throw ImportError.recoveryStateUnavailable
            }
            let startedAccessing = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if startedAccessing {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            var operation: MediaOperation?
            do {
                operation = try mediaRecoveryStore.begin(
                    kind: .archiveRestore,
                    sourceName: sourceURL.lastPathComponent,
                    destinationURL: destinationURL,
                    fileExtension: sourceURL.pathExtension
                )
                guard let prepared = operation else {
                    throw MediaOperationRecoveryError.unavailable
                }
                operation = try mediaRecoveryStore.stageCopy(from: sourceURL, for: prepared)
                guard let staged = operation else {
                    throw MediaOperationRecoveryError.missingStagingArtifact
                }
                try validateAudioFile(at: staged.stagingURL)
                operation = try mediaRecoveryStore.publish(staged)
                guard let published = operation else {
                    throw MediaOperationRecoveryError.unavailable
                }
                operation = try mediaRecoveryStore.markMetadataPending(published)
                try RecordingArchiveService.shared.restoreRecording(recording, newAudioURL: destinationURL)

                if let committed = operation {
                    do {
                        let durable = try mediaRecoveryStore.markMetadataCommitted(committed, recordingID: recording.id)
                        try mediaRecoveryStore.finish(durable)
                    } catch {
                        AppLog.shared.fileManagement(
                            "Archive import closed with deferred receipt cleanup: \(error.localizedDescription)",
                            level: .error
                        )
                    }
                }
            } catch {
                if let operation,
                   FileManager.default.fileExists(atPath: operation.publishedURL.path) {
                    AppLog.shared.fileManagement(
                        "Restored archive media retained after a failed metadata/publication step: \(error.localizedDescription)",
                        level: .error
                    )
                } else if let operation {
                    do {
                        try mediaRecoveryStore.abortBeforePublish(operation)
                    } catch {
                        AppLog.shared.fileManagement(
                            "Could not remove failed archive staging state: \(error.localizedDescription)",
                            level: .error
                        )
                    }
                }
                if let importError = error as? ImportError {
                    throw importError
                }
                if error is MediaOperationRecoveryError {
                    throw ImportError.recoveryStateUnavailable
                }
                throw error
            }
            NotificationCenter.default.post(name: NSNotification.Name("RecordingAdded"), object: nil)
            AppLog.shared.fileManagement("Restored archived recording \(recording.recordingName ?? "unknown") from import \(sourceURL.lastPathComponent)")
        }
    }

    private func videoDestination(for sourceURL: URL) -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = sourceURL.deletingPathExtension().lastPathComponent
        return documents.appendingPathComponent("\(name)_\(formatter.string(from: Date())).m4a")
    }

    private func importVideoFile(from sourceURL: URL) async throws {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let destinationURL = videoDestination(for: sourceURL)
        let audioFilename = destinationURL.lastPathComponent

        guard let mediaRecoveryStore else {
            throw ImportError.recoveryStateUnavailable
        }

        let startedAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if startedAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let sourceIdentity = try mediaRecoveryStore.artifactIdentity(for: sourceURL)
        if let pending = try mediaRecoveryStore.pendingOperation(
            kind: .videoImport, sourceName: sourceURL.lastPathComponent,
            sourceFileSize: sourceIdentity.fileSize, sourceFingerprint: sourceIdentity.fingerprint
        ) {
            try await retryPendingAudioImport(
                pending, recordingName: AudioRecorderViewModel.generateImportedFileName(originalName: baseName),
                mediaRecoveryStore: mediaRecoveryStore
            )
            return
        }
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw ImportError.fileAlreadyExists(audioFilename)
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

        var operation: MediaOperation?
        do {
            operation = try mediaRecoveryStore.begin(
                kind: .videoImport,
                sourceName: sourceURL.lastPathComponent,
                destinationURL: destinationURL,
                fileExtension: "m4a",
                sourceFileSize: sourceIdentity.fileSize,
                sourceFingerprint: sourceIdentity.fingerprint
            )
            guard let prepared = operation else {
                throw MediaOperationRecoveryError.unavailable
            }

            exportSession.outputURL = prepared.stagingURL
            try await exportSession.export(to: prepared.stagingURL, as: .m4a)
            operation = try mediaRecoveryStore.markStaged(prepared)
            guard let staged = operation else {
                throw MediaOperationRecoveryError.missingStagingArtifact
            }
            try validateAudioFile(at: staged.stagingURL)
            operation = try mediaRecoveryStore.publish(staged)
            guard let published = operation else {
                throw MediaOperationRecoveryError.unavailable
            }
            operation = try mediaRecoveryStore.markMetadataPending(published)

            try await createRecordingEntryForImportedFile(
                at: destinationURL,
                recordingName: AudioRecorderViewModel.generateImportedFileName(originalName: baseName)
            )

            if let committed = operation {
                do {
                    let durable = try mediaRecoveryStore.markMetadataCommitted(committed)
                    try mediaRecoveryStore.finish(durable)
                } catch {
                    AppLog.shared.fileManagement(
                        "Video import closed with deferred receipt cleanup: \(error.localizedDescription)",
                        level: .error
                    )
                }
            }
        } catch {
            if let operation,
               FileManager.default.fileExists(atPath: operation.publishedURL.path) {
                AppLog.shared.fileManagement(
                    "Extracted audio retained after a failed metadata/publication step: \(error.localizedDescription)",
                    level: .error
                )
            } else if let operation {
                do {
                    try mediaRecoveryStore.abortBeforePublish(operation)
                } catch {
                    AppLog.shared.fileManagement(
                        "Could not remove failed video staging state: \(error.localizedDescription)",
                        level: .error
                    )
                }
            }
            if let importError = error as? ImportError {
                throw importError
            }
            if error is MediaOperationRecoveryError {
                throw ImportError.recoveryStateUnavailable
            }
            throw ImportError.copyFailed(error.localizedDescription)
        }

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

    private func createRecordingEntryForImportedFile(
        at fileURL: URL,
        recordingName: String
    ) async throws {
        // Create new recording entry
        let recordingEntry = RecordingEntry(context: context)
        recordingEntry.id = UUID()
        recordingEntry.recordingName = recordingName
        // Store relative path instead of absolute URL for resilience across app launches
        guard let relativePath = urlToRelativePath(fileURL) else {
            context.delete(recordingEntry)
            throw ImportError.persistenceFailed("Could not determine the imported file's local path")
        }
        recordingEntry.recordingURL = relativePath

        // Get file metadata. Prefer the file's modification date as the recording
        // date: archives exported by this app stamp mtime with the original
        // recording date, and iCloud preserves mtime across round-trips (while
        // it resets creation date to upload time).
        do {
            let resourceValues = try fileURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
            let originalDate = resourceValues.contentModificationDate
                ?? resourceValues.creationDate
            guard let originalDate,
                  let fileSize = resourceValues.fileSize,
                  fileSize > 0 else {
                throw ImportError.persistenceFailed("The imported file has incomplete metadata")
            }
            recordingEntry.recordingDate = originalDate
            recordingEntry.createdAt = originalDate
            recordingEntry.lastModified = Date()
            recordingEntry.fileSize = Int64(fileSize)

            // Get duration
            let duration = try await getAudioDuration(url: fileURL)
            guard duration.isFinite, duration > 0 else {
                throw ImportError.invalidAudioFile("File has no readable duration")
            }
            recordingEntry.duration = duration

        } catch {
            AppLog.shared.fileManagement("Error getting file metadata: \(error)", level: .error)
            context.delete(recordingEntry)
            if let importError = error as? ImportError {
                throw importError
            }
            throw ImportError.persistenceFailed("Unable to read imported file metadata: \(error.localizedDescription)")
        }

        // Set default values
        recordingEntry.audioQuality = "high"
        recordingEntry.transcriptionStatus = "Not Started"
        recordingEntry.summaryStatus = "Not Started"

        // Save the context
        do {
            try coreDataManager.saveContext(operation: "imported recording creation")
            AppLog.shared.fileManagement("Created Core Data entry for imported file")
        } catch {
            AppLog.shared.fileManagement("Failed to save Core Data entry: \(error)", level: .error)
            context.delete(recordingEntry)
            throw ImportError.persistenceFailed(error.localizedDescription)
        }
    }

    private func getAudioDuration(url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        return CMTimeGetSeconds(duration)
    }

    private func importedRecordingName(for sourceURL: URL) -> String {
        let originalName = sourceURL.deletingPathExtension().lastPathComponent
        return AudioRecorderViewModel.generateImportedFileName(originalName: originalName)
    }

    private func hasExistingRecording(named name: String, matching fingerprint: String) throws -> Bool {
        let recordings = try coreDataManager.getAllRecordings()
        for recording in recordings where recording.recordingName == name {
            guard let storedPath = recording.recordingURL,
                  let storedURL = RecordingArchiveService.resolveLocalURL(from: storedPath),
                  FileManager.default.fileExists(atPath: storedURL.path) else {
                continue
            }
            if try fileFingerprint(for: storedURL) == fingerprint {
                return true
            }
        }
        return false
    }

    private func retryPendingAudioImport(
        _ pending: MediaOperation,
        recordingName: String,
        mediaRecoveryStore: MediaOperationRecoveryStore
    ) async throws {
        var operation = pending
        let wasMetadataCommitted = operation.receipt.phase == .metadataCommitted
        if operation.receipt.phase == .staged,
           !FileManager.default.fileExists(atPath: operation.publishedURL.path) {
            try validateAudioFile(at: operation.stagingURL)
            operation = try mediaRecoveryStore.publish(operation)
        }
        try validateAudioFile(at: operation.publishedURL)
        operation = try mediaRecoveryStore.markMetadataPending(operation)

        if try hasRecordingReference(to: operation.publishedURL) {
            do {
                let committed = try mediaRecoveryStore.markMetadataCommitted(operation)
                try mediaRecoveryStore.finish(committed)
            } catch {
                AppLog.shared.fileManagement(
                    "Recovered audio metadata reference but receipt cleanup is deferred: \(error.localizedDescription)",
                    level: .error
                )
            }
            return
        }

        guard !wasMetadataCommitted else {
            throw ImportError.persistenceFailed(
                "A committed import receipt has no matching recording reference."
            )
        }

        try await createRecordingEntryForImportedFile(
            at: operation.publishedURL,
            recordingName: recordingName
        )
        do {
            let committed = try mediaRecoveryStore.markMetadataCommitted(operation)
            try mediaRecoveryStore.finish(committed)
        } catch {
            AppLog.shared.fileManagement(
                "Recovered audio import but receipt cleanup is deferred: \(error.localizedDescription)",
                level: .error
            )
        }
    }

    private func hasRecordingReference(to url: URL) throws -> Bool {
        let target = url.standardizedFileURL.path
        return try coreDataManager.getAllRecordings().contains { recording in
            guard let storedPath = recording.recordingURL,
                  let storedURL = RecordingArchiveService.resolveLocalURL(from: storedPath) else {
                return false
            }
            return storedURL.standardizedFileURL.path == target
        }
    }

    private func fileFingerprint(for url: URL) throws -> String {
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
    case persistenceFailed(String)
    case recoveryStateUnavailable
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
        case .persistenceFailed(let reason):
            return "The imported file was retained, but its metadata could not be saved: \(reason)"
        case .recoveryStateUnavailable:
            return "The imported file was not started because its recovery state could not be recorded."
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

/// Only the current batch's durably acknowledged inputs may be consumed.
enum ImportSourceCleanup {
    static func removeAcknowledged(_ acknowledged: Set<URL>, from sources: [URL]) {
        for source in sources where acknowledged.contains(source) {
            do {
                try FileManager.default.removeItem(at: source)
            } catch {
                AppLog.shared.fileManagement("Acknowledged import source cleanup deferred", level: .error)
            }
        }
    }
}
