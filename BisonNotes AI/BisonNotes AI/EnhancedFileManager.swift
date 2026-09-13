import Foundation
import SwiftUI

// MARK: - File Relationships Model

struct FileRelationships: Codable, Identifiable, Sendable {
    let id: UUID
    let recordingURL: URL?
    let recordingName: String
    let recordingDate: Date
    let transcriptExists: Bool
    let summaryExists: Bool
    /// Indicates that this item is eligible for iCloud sync, not that a cloud
    /// record has been confirmed. Cloud record existence requires an async
    /// CloudKit lookup and is intentionally not represented here.
    let iCloudSyncEligible: Bool
    let lastUpdated: Date

    init(
        recordingURL: URL?,
        recordingName: String,
        recordingDate: Date,
        transcriptExists: Bool = false,
        summaryExists: Bool = false,
        iCloudSyncEligible: Bool = false
    ) {
        self.id = UUID()
        self.recordingURL = recordingURL
        self.recordingName = recordingName
        self.recordingDate = recordingDate
        self.transcriptExists = transcriptExists
        self.summaryExists = summaryExists
        self.iCloudSyncEligible = iCloudSyncEligible
        self.lastUpdated = Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case recordingURL
        case recordingName
        case recordingDate
        case transcriptExists
        case summaryExists
        case iCloudSyncEligible
        case legacyICloudSynced = "iCloudSynced"
        case lastUpdated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        recordingURL = try container.decodeIfPresent(URL.self, forKey: .recordingURL)
        recordingName = try container.decode(String.self, forKey: .recordingName)
        recordingDate = try container.decode(Date.self, forKey: .recordingDate)
        transcriptExists = try container.decode(Bool.self, forKey: .transcriptExists)
        summaryExists = try container.decode(Bool.self, forKey: .summaryExists)
        if let eligible = try container.decodeIfPresent(Bool.self, forKey: .iCloudSyncEligible) {
            iCloudSyncEligible = eligible
        } else {
            iCloudSyncEligible = try container.decodeIfPresent(Bool.self, forKey: .legacyICloudSynced) ?? false
        }
        lastUpdated = try container.decode(Date.self, forKey: .lastUpdated)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(recordingURL, forKey: .recordingURL)
        try container.encode(recordingName, forKey: .recordingName)
        try container.encode(recordingDate, forKey: .recordingDate)
        try container.encode(transcriptExists, forKey: .transcriptExists)
        try container.encode(summaryExists, forKey: .summaryExists)
        try container.encode(iCloudSyncEligible, forKey: .iCloudSyncEligible)
        try container.encode(lastUpdated, forKey: .lastUpdated)
    }

    var hasRecording: Bool {
        guard let url = recordingURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    var isOrphaned: Bool {
        return !hasRecording && (transcriptExists || summaryExists)
    }

    var availabilityStatus: FileAvailabilityStatus {
        if hasRecording && transcriptExists && summaryExists {
            return .complete
        } else if hasRecording {
            return .recordingOnly
        } else if summaryExists {
            return .summaryOnly
        } else if transcriptExists {
            return .transcriptOnly
        } else {
            return .none
        }
    }
}

enum FileAvailabilityStatus: String, CaseIterable {
    case complete = "Complete"
    case recordingOnly = "Recording Only"
    case summaryOnly = "Summary Only"
    case transcriptOnly = "Transcript Only"
    case archived = "Archived"
    case none = "None"

    var icon: String {
        switch self {
        case .complete:
            return "checkmark.circle.fill"
        case .recordingOnly:
            return "waveform"
        case .summaryOnly:
            return "doc.text"
        case .transcriptOnly:
            return "text.quote"
        case .archived:
            return "archivebox.fill"
        case .none:
            return "questionmark.circle"
        }
    }

    var color: String {
        switch self {
        case .complete:
            return "green"
        case .recordingOnly:
            return "blue"
        case .summaryOnly:
            return "orange"
        case .transcriptOnly:
            return "purple"
        case .archived:
            return "orange"
        case .none:
            return "gray"
        }
    }

    var description: String {
        switch self {
        case .complete:
            return "Recording, transcript, and summary available"
        case .recordingOnly:
            return "Only recording available"
        case .summaryOnly:
            return "Only summary available (recording deleted)"
        case .transcriptOnly:
            return "Only transcript available (recording deleted)"
        case .archived:
            return "Audio exported to external storage"
        case .none:
            return "No files available"
        }
    }
}

// MARK: - Enhanced File Manager

@MainActor
final class EnhancedFileManager: ObservableObject {
    static let shared = EnhancedFileManager()

    @Published var fileRelationships: [URL: FileRelationships] = [:]

    private let relationshipsFileName = "file_relationships.json"

    // Reference to the coordinator (will be set by the app)
    private weak var appCoordinator: AppDataCoordinator?

    private init() {
        loadFileRelationships()
        // Note: Automatic cleanup disabled to prevent false positives during app startup
        // refreshAllRelationships()
    }

    // MARK: - Coordinator Setup

    func setCoordinator(_ coordinator: AppDataCoordinator?) {
        self.appCoordinator = coordinator
    }

    func getCoordinator() -> AppDataCoordinator? {
        return appCoordinator
    }

    // MARK: - URL Normalization

    /// Normalizes a URL to ensure consistent representation for dictionary keys
    /// This prevents duplicates from different URL representations (absolute vs relative, file:// vs path-only, etc.)
    private func normalizeURL(_ url: URL) -> URL {
        // For file URLs, use standardizedFileURL to resolve symlinks and normalize path
        if url.isFileURL {
            return url.standardizedFileURL
        }
        // For non-file URLs, return as-is (though we primarily deal with file URLs)
        return url
    }

    // MARK: - Relationship Management

    func getFileRelationships(for url: URL) -> FileRelationships? {
        let normalizedURL = normalizeURL(url)
        return fileRelationships[normalizedURL]
    }

    func updateFileRelationships(for url: URL, relationships: FileRelationships) async {
        await MainActor.run {
            let normalizedURL = normalizeURL(url)
            fileRelationships[normalizedURL] = relationships
            saveFileRelationships()
        }
    }

    func refreshRelationships(for url: URL) async throws {
        try appCoordinator?.syncRecordingURLs()
        let normalizedURL = normalizeURL(url)
        let relationship = try makeRelationship(for: normalizedURL)
        fileRelationships[normalizedURL] = relationship
        saveFileRelationships()
    }

    func refreshAllRelationships() {
        Task {
            do {
                try refreshAllRelationshipsFromStore()
            } catch {
                AppLog.shared.fileManagement(
                    "Relationship refresh withheld: \(error.localizedDescription)", level: .error
                )
            }
        }
    }

    /// Stage the entire refresh before publishing or saving relationship changes.
    func refreshAllRelationshipsFromStore() throws {
        try appCoordinator?.syncRecordingURLs()
        let urls = try relationshipURLs()
        var updated: [URL: FileRelationships] = [:]
        for url in urls {
            updated[url] = try makeRelationship(for: url)
        }
        fileRelationships = updated
        saveFileRelationships()
    }

    // MARK: - Selective Deletion

    func deleteRecording(_ url: URL, preserveSummary: Bool) async throws {
        let normalizedURL = normalizeURL(url)
        guard let relationships = fileRelationships[normalizedURL] else {
            throw FileManagementError.relationshipNotFound
        }

        // Get the recording ID from the coordinator
        guard let appCoordinator = appCoordinator,
              let recordingEntry = try appCoordinator.coreDataManager.fetchRecording(url: normalizedURL),
              let recordingId = recordingEntry.id else {
            throw FileManagementError.relationshipNotFound
        }

        // Stop any playback if this recording is currently playing
        // Note: This would need to be coordinated with the AudioRecorderViewModel

        // Handle selective deletion based on preserveSummary parameter
        if preserveSummary && relationships.summaryExists {
            // Preserve summary: remove audio + transcript, keep the recording entry to anchor the summary in UI

            // Read the summary before deleting the transcript. A failed summary
            // lookup must stop this mutation with all related rows intact.
            let summary = try appCoordinator.coreDataManager.fetchSummary(for: recordingId)

            // Delete transcript if present
            if let transcript = try appCoordinator.coreDataManager.fetchTranscript(for: recordingId) {
                guard let transcriptId = transcript.id else {
                    throw FileManagementError.deletionFailed("Transcript persistence is missing its identifier")
                }
                try await appCoordinator.deleteTranscript(id: transcriptId)
                guard try appCoordinator.coreDataManager.fetchTranscript(for: recordingId) == nil else {
                    throw FileManagementError.deletionFailed("Transcript persistence still contains the deleted entry")
                }
                AppLog.shared.fileManagement("Deleted transcript for recording")
            }

            // Keep summary linked to the recording; ensure IDs/relationships are consistent
            let previousRecordingURL = recordingEntry.recordingURL
            let previousRecordingLastModified = recordingEntry.lastModified
            let previousSummaryRecording = summary?.recording
            let previousSummaryRecordingID = summary?.recordingId
            let previousSummaryTranscript = summary?.transcript
            let previousSummaryTranscriptID = summary?.transcriptId
            if let summary {
                summary.recording = recordingEntry
                summary.recordingId = recordingId
                summary.transcript = nil
                summary.transcriptId = nil
            }

            // Clear recording's file URL so it won't appear in audio listings
            recordingEntry.recordingURL = nil
            recordingEntry.lastModified = Date()

            // Persist changes
            do {
                try appCoordinator.coreDataManager.saveContext(operation: "recording audio removal")
            } catch {
                // `saveContext` intentionally leaves failed edits staged for a
                // retry. Restore only the fields owned by this operation so an
                // unrelated pending edit remains intact without being committed
                // accidentally by a later save.
                recordingEntry.recordingURL = previousRecordingURL
                recordingEntry.lastModified = previousRecordingLastModified
                if let summary {
                    summary.recording = previousSummaryRecording
                    summary.recordingId = previousSummaryRecordingID
                    summary.transcript = previousSummaryTranscript
                    summary.transcriptId = previousSummaryTranscriptID
                }
                AppLog.shared.fileManagement("Error saving preservation changes: \(error)", level: .error)
                throw FileManagementError.persistenceError(error.localizedDescription)
            }

            do {
                // The metadata unlink is durable; only now release the owned
                // source and sidecars. If cleanup fails, the committed metadata
                // remains deleted and the relationship cache stays available for
                // a retry of this post-commit filesystem step.
                try deleteAudioAndSidecars(at: normalizedURL, hasRecording: relationships.hasRecording)
                AppLog.shared.fileManagement("Preserved summary (kept recording entry, removed transcript)")
            } catch {
                AppLog.shared.fileManagement("Saved preservation changes but could not remove audio: \(error)", level: .error)
                throw FileManagementError.deletionFailed(error.localizedDescription)
            }

            // Update relationships to reflect that only summary remains
            let updatedRelationships = FileRelationships(
                recordingURL: nil,
                recordingName: relationships.recordingName,
                recordingDate: relationships.recordingDate,
                transcriptExists: false,
                summaryExists: true,
                iCloudSyncEligible: relationships.iCloudSyncEligible
            )
            await updateFileRelationships(for: normalizedURL, relationships: updatedRelationships)
        } else {
            // Delete everything (recording, transcript, and summary)
            try appCoordinator.deleteRecording(id: recordingId)
            guard try appCoordinator.coreDataManager.fetchRecording(id: recordingId) == nil else {
                throw FileManagementError.deletionFailed("Recording persistence still contains the deleted entry")
            }
            try deleteAudioAndSidecars(at: normalizedURL, hasRecording: relationships.hasRecording)
            AppLog.shared.fileManagement("Deleted recording, transcript, and summary")

            // Remove the relationship entirely
            await MainActor.run {
                _ = fileRelationships.removeValue(forKey: normalizedURL)
                saveFileRelationships()
            }
        }

        AppLog.shared.fileManagement("Recording deletion completed")
    }

    private func deleteAudioAndSidecars(at url: URL, hasRecording: Bool) throws {
        guard hasRecording else { return }

        do {
            try FileManager.default.removeItem(at: url)
            AppLog.shared.fileManagement("Deleted audio file: \(url.lastPathComponent)")
        } catch {
            if error.isThumbnailGenerationError {
                AppLog.shared.fileManagement(
                    "Thumbnail generation warning during file deletion: \(error.localizedDescription)",
                    level: .debug
                )
            } else {
                throw error
            }
        }

        for ext in ["location", "recordingmeta"] {
            let sidecarURL = url.deletingPathExtension().appendingPathExtension(ext)
            guard FileManager.default.fileExists(atPath: sidecarURL.path) else { continue }
            do {
                try FileManager.default.removeItem(at: sidecarURL)
                AppLog.shared.fileManagement("Deleted \(ext) file: \(sidecarURL.lastPathComponent)")
            } catch {
                if error.isThumbnailGenerationError {
                    AppLog.shared.fileManagement(
                        "Thumbnail generation warning during \(ext) file deletion: \(error.localizedDescription)",
                        level: .debug
                    )
                } else {
                    throw error
                }
            }
        }
    }

    // MARK: - Query Methods

    func getAllRelationships() -> [FileRelationships] {
        return Array(fileRelationships.values).sorted { $0.recordingDate > $1.recordingDate }
    }

    func getOrphanedSummaries() -> [FileRelationships] {
        return fileRelationships.values.filter { $0.isOrphaned && $0.summaryExists }
    }

    func getCompleteFiles() -> [FileRelationships] {
        return fileRelationships.values.filter { $0.availabilityStatus == .complete }
    }

    func getRecordingsWithoutSummaries() -> [FileRelationships] {
        return fileRelationships.values.filter { $0.hasRecording && !$0.summaryExists }
    }

    // MARK: - Utility Methods

    func clearAllFileRelationships() {
        fileRelationships.removeAll()
        saveFileRelationships()
        AppLog.shared.fileManagement("Cleared all file relationships")
    }

    private func getRecordingDate(for url: URL) -> Date {
        // Check if file exists before trying to get its creation date
        guard FileManager.default.fileExists(atPath: url.path) else {
            AppLog.shared.fileManagement("File does not exist, using current date for: \(url.lastPathComponent)", level: .debug)
            return Date()
        }

        do {
            let resourceValues = try url.resourceValues(forKeys: [.creationDateKey])
            return resourceValues.creationDate ?? Date()
        } catch {
            AppLog.shared.fileManagement("Error getting creation date for \(url.lastPathComponent): \(error)", level: .error)
            return Date()
        }
    }

    // MARK: - Persistence

    private func saveFileRelationships() {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            AppLog.shared.fileManagement("Could not get documents directory", level: .error)
            return
        }

        let relationshipsURL = documentsURL.appendingPathComponent(relationshipsFileName)

        do {
            let data = try JSONEncoder().encode(fileRelationships)
            try data.write(to: relationshipsURL)
        } catch {
            AppLog.shared.fileManagement("Error saving file relationships: \(error)", level: .error)
        }
    }

    private func loadFileRelationships() {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            AppLog.shared.fileManagement("Could not get documents directory", level: .error)
            return
        }

        let relationshipsURL = documentsURL.appendingPathComponent(relationshipsFileName)

        guard FileManager.default.fileExists(atPath: relationshipsURL.path) else {
            AppLog.shared.fileManagement("No existing file relationships found", level: .debug)
            return
        }

        do {
            let data = try Data(contentsOf: relationshipsURL)
            let loadedRelationships = try JSONDecoder().decode([URL: FileRelationships].self, from: data)

            // Normalize all URLs when loading to prevent duplicates
            var normalizedRelationships: [URL: FileRelationships] = [:]
            var duplicateCount = 0

            for (url, relationships) in loadedRelationships {
                let normalizedURL = normalizeURL(url)

                // If we already have an entry for this normalized URL, merge or keep the most recent
                if let existing = normalizedRelationships[normalizedURL] {
                    // Keep the relationship with the most recent lastUpdated date
                    if relationships.lastUpdated > existing.lastUpdated {
                        normalizedRelationships[normalizedURL] = relationships
                        duplicateCount += 1
                    } else {
                        duplicateCount += 1
                    }
                } else {
                    normalizedRelationships[normalizedURL] = relationships
                }
            }

            fileRelationships = normalizedRelationships

            if duplicateCount > 0 {
                AppLog.shared.fileManagement("Normalized \(duplicateCount) duplicate URL entries when loading file relationships")
            }
        } catch {
            AppLog.shared.fileManagement("Error loading file relationships: \(error)", level: .error)
            fileRelationships = [:]
        }
    }

}

// MARK: - Error Types

extension EnhancedFileManager {
    private func relationshipURLs() throws -> Set<URL> {
        var urls = Set(fileRelationships.keys.map { normalizeURL($0) })
        if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let files = try FileManager.default.contentsOfDirectory(
                at: documentsURL, includingPropertiesForKeys: nil
            )
            let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aac"]
            urls.formUnion(files.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
                .map { normalizeURL($0) })
        }
        if let coordinator = appCoordinator {
            for recording in try coordinator.coreDataManager.getAllRecordings() {
                if let url = coordinator.getStoredURL(for: recording) {
                    urls.insert(normalizeURL(url))
                }
            }
        }
        return urls
    }

    private func makeRelationship(for url: URL) throws -> FileRelationships? {
        let recordingExists = FileManager.default.fileExists(atPath: url.path)
        var transcriptExists = false
        var summaryExists = false
        var recordingDate: Date?
        var cloudEligible = false
        if let coordinator = appCoordinator {
            let manager = coordinator.coreDataManager
            let recording = try manager.fetchRecording(url: url)
            // Complete both reads before changing the relationship cache.
            let transcripts = try manager.getAllTranscripts()
            let summaries = try manager.getAllSummaries()
            if let recording, let id = recording.id {
                transcriptExists = transcripts.contains { ($0.recordingId ?? $0.recording?.id) == id }
                summaryExists = summaries.contains { ($0.recordingId ?? $0.recording?.id) == id }
                recordingDate = recording.recordingDate
                cloudEligible = SummaryManager.shared.getiCloudManager().isEnabled && !recording.isCloudSyncDisabled
            }
        }
        guard recordingExists || transcriptExists || summaryExists else { return nil }
        return FileRelationships(
            recordingURL: recordingExists ? url : nil,
            recordingName: url.deletingPathExtension().lastPathComponent,
            recordingDate: recordingDate ?? getRecordingDate(for: url),
            transcriptExists: transcriptExists,
            summaryExists: summaryExists,
            iCloudSyncEligible: cloudEligible
        )
    }
}

enum FileManagementError: Error, LocalizedError {
    case relationshipNotFound
    case fileNotFound
    case permissionDenied
    case insufficientSpace
    case corruptedFile
    case relationshipError
    case deletionFailed(String)
    case persistenceError(String)

    var errorDescription: String? {
        switch self {
        case .relationshipNotFound:
            return "File relationship not found"
        case .fileNotFound:
            return "File not found"
        case .permissionDenied:
            return "Permission denied for file operation"
        case .insufficientSpace:
            return "Insufficient storage space"
        case .corruptedFile:
            return "File is corrupted or invalid"
        case .relationshipError:
            return "Error with file relationships"
        case .deletionFailed(let message):
            return "Deletion failed: \(message)"
        case .persistenceError(let message):
            return "Persistence error: \(message)"
        }
    }
}
