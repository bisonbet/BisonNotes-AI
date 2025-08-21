import Foundation
import SwiftUI

// MARK: - File Relationships Model

struct FileRelationships: Codable, Identifiable {
    let id: UUID
    let recordingURL: URL?
    let recordingName: String
    let recordingDate: Date
    let transcriptExists: Bool
    let summaryExists: Bool
    let iCloudSynced: Bool
    let lastUpdated: Date
    
    init(recordingURL: URL?, recordingName: String, recordingDate: Date, transcriptExists: Bool = false, summaryExists: Bool = false, iCloudSynced: Bool = false) {
        self.id = UUID()
        self.recordingURL = recordingURL
        self.recordingName = recordingName
        self.recordingDate = recordingDate
        self.transcriptExists = transcriptExists
        self.summaryExists = summaryExists
        self.iCloudSynced = iCloudSynced
        self.lastUpdated = Date()
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
        case .none:
            return "No files available"
        }
    }
}

// MARK: - Enhanced File Manager

class EnhancedFileManager: ObservableObject {
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
    
    func setCoordinator(_ coordinator: AppDataCoordinator) {
        self.appCoordinator = coordinator
    }
    
    func getCoordinator() -> AppDataCoordinator? {
        return appCoordinator
    }
    
    // MARK: - Relationship Management
    
    func getFileRelationships(for url: URL) -> FileRelationships? {
        return fileRelationships[url]
    }
    
    func updateFileRelationships(for url: URL, relationships: FileRelationships) async {
        await MainActor.run {
            fileRelationships[url] = relationships
            saveFileRelationships()
        }
    }
    
    func refreshRelationships(for url: URL) async {
        let recordingExists = FileManager.default.fileExists(atPath: url.path)
        
        let transcriptExists = await MainActor.run { 
            guard let appCoordinator = appCoordinator else { return false }
            
            // Sync URLs first to ensure they're up to date
            appCoordinator.syncRecordingURLs()
            
            // Use the improved getRecording method that handles renamed files
            let coreDataRecording = appCoordinator.getRecording(url: url)
            
            guard let recording = coreDataRecording,
                  let recordingId = recording.id else { return false }
            return appCoordinator.getTranscript(for: recordingId) != nil
        }
        
        let summaryExists = await MainActor.run { 
            guard let appCoordinator = appCoordinator else { return false }
            
            // Sync URLs first to ensure they're up to date
            appCoordinator.syncRecordingURLs()
            
            // Use the improved getRecording method that handles renamed files
            let coreDataRecording = appCoordinator.getRecording(url: url)
            
            guard let recording = coreDataRecording,
                  let recordingId = recording.id else { return false }
            return appCoordinator.getSummary(for: recordingId) != nil
        }
        
        // Check iCloud sync status (placeholder for now)
        let iCloudSynced = false // TODO: Implement actual iCloud sync check
        
        let recordingName = url.deletingPathExtension().lastPathComponent
        let recordingDate = getRecordingDate(for: url)
        
        // Only create relationships if we have some data to work with
        // or if the recording actually exists
        if recordingExists || transcriptExists || summaryExists {
            let relationships = FileRelationships(
                recordingURL: recordingExists ? url : nil,
                recordingName: recordingName,
                recordingDate: recordingDate,
                transcriptExists: transcriptExists,
                summaryExists: summaryExists,
                iCloudSynced: iCloudSynced
            )
            
            await updateFileRelationships(for: url, relationships: relationships)
        } else {
            // If nothing exists for this URL, remove it from relationships
            await MainActor.run {
                _ = fileRelationships.removeValue(forKey: url)
                saveFileRelationships()
            }
            print("🧹 Cleaned up non-existent file relationship for: \(url.lastPathComponent)")
        }
    }
    
    func refreshAllRelationships() {
        Task {
            // Sync URLs first to ensure they're up to date
            await MainActor.run {
                if let coordinator = appCoordinator {
                    coordinator.syncRecordingURLs()
                }
            }
            
            // Get all known recording URLs from various sources
            var allURLs = Set<URL>()
            
            // First, scan the documents directory for actual audio files
            if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                do {
                    let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: [.creationDateKey], options: [])
                    let audioFiles = fileURLs.filter { url in
                        let fileExtension = url.pathExtension.lowercased()
                        return fileExtension == "m4a" || fileExtension == "mp3" || fileExtension == "wav" || fileExtension == "aac"
                    }
                    allURLs.formUnion(audioFiles)
                    print("🔍 Found \(audioFiles.count) actual audio files in documents directory")
                } catch {
                    print("❌ Error scanning documents directory: \(error)")
                }
            }
            
            // Add URLs from existing relationships (but only if they actually exist)
            for url in fileRelationships.keys {
                if FileManager.default.fileExists(atPath: url.path) {
                    allURLs.insert(url)
                } else {
                    print("🧹 Removing relationship for non-existent file: \(url.lastPathComponent)")
                    await MainActor.run {
                        _ = fileRelationships.removeValue(forKey: url)
                    }
                }
            }
            
            // Add URLs from coordinator (but only if they actually exist)
            if let coordinator = appCoordinator {
                let recordings = await coordinator.getAllRecordingsWithData()
                for recordingData in recordings {
                    if let urlString = recordingData.recording.recordingURL,
                       let url = URL(string: urlString),
                       FileManager.default.fileExists(atPath: url.path) {
                        allURLs.insert(url)
                    }
                }
            }
            
            // Refresh relationships for all URLs
            for url in allURLs {
                await refreshRelationships(for: url)
            }
            
            await MainActor.run {
                saveFileRelationships()
            }
            
            print("🔄 Refreshed relationships for \(allURLs.count) files")
        }
    }
    
    // MARK: - Selective Deletion
    
    func deleteRecording(_ url: URL, preserveSummary: Bool) async throws {
        guard let relationships = fileRelationships[url] else {
            throw FileManagementError.relationshipNotFound
        }
        
        // Get the recording ID from the coordinator
        guard let appCoordinator = appCoordinator,
              let recordingEntry = await appCoordinator.getRecording(url: url),
              let recordingId = recordingEntry.id else {
            throw FileManagementError.relationshipNotFound
        }
        
        // Stop any playback if this recording is currently playing
        // Note: This would need to be coordinated with the AudioRecorderViewModel
        
        // Delete the audio file if it exists
        if relationships.hasRecording {
            do {
                try FileManager.default.removeItem(at: url)
                print("✅ Deleted audio file: \(url.lastPathComponent)")
            } catch {
                if error.isThumbnailGenerationError {
                    print("⚠️ Thumbnail generation warning during file deletion (can be ignored): \(error.localizedDescription)")
                    // Continue with deletion even if thumbnail generation fails
                } else {
                    throw error
                }
            }
            
            // Delete associated location file if it exists
            let locationURL = url.deletingPathExtension().appendingPathExtension("location")
            if FileManager.default.fileExists(atPath: locationURL.path) {
                do {
                    try FileManager.default.removeItem(at: locationURL)
                    print("✅ Deleted location file: \(locationURL.lastPathComponent)")
                } catch {
                    if error.isThumbnailGenerationError {
                        print("⚠️ Thumbnail generation warning during location file deletion (can be ignored): \(error.localizedDescription)")
                        // Continue with deletion even if thumbnail generation fails
                    } else {
                        throw error
                    }
                }
            }
        }
        
        // Handle selective deletion based on preserveSummary parameter
        if preserveSummary && relationships.summaryExists {
            // Preserve summary: remove audio + transcript, keep the recording entry to anchor the summary in UI

            // Delete transcript if present
            if let transcript = await appCoordinator.coreDataManager.getTranscript(for: recordingId) {
                await appCoordinator.coreDataManager.deleteTranscript(id: transcript.id)
                print("✅ Deleted transcript for: \(relationships.recordingName)")
            }

            // Keep summary linked to the recording; ensure IDs/relationships are consistent
            if let summary = await appCoordinator.coreDataManager.getSummary(for: recordingId) {
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
                try await appCoordinator.coreDataManager.saveContext()
                print("✅ Preserved summary (kept recording entry, removed transcript) for: \(relationships.recordingName)")
            } catch {
                print("❌ Error saving preservation changes: \(error)")
            }

            // Update relationships to reflect that only summary remains
            let updatedRelationships = FileRelationships(
                recordingURL: nil,
                recordingName: relationships.recordingName,
                recordingDate: relationships.recordingDate,
                transcriptExists: false,
                summaryExists: true,
                iCloudSynced: relationships.iCloudSynced
            )
            await updateFileRelationships(for: url, relationships: updatedRelationships)
        } else {
            // Delete everything (recording, transcript, and summary)
            await appCoordinator.deleteRecording(id: recordingId)
            print("✅ Deleted recording, transcript, and summary for: \(relationships.recordingName)")
            
            // Remove the relationship entirely
            await MainActor.run {
                _ = fileRelationships.removeValue(forKey: url)
                saveFileRelationships()
            }
        }
        
        print("✅ Recording deletion completed: \(relationships.recordingName)")
    }
    
    func deleteSummary(for url: URL) async throws {
        guard let relationships = fileRelationships[url] else {
            throw FileManagementError.relationshipNotFound
        }
        
        if relationships.summaryExists {
            // This will now be handled by the coordinator
            // let manager = await summaryManager
            // await MainActor.run { manager.deleteSummary(for: url) }
            print("✅ Deleted summary for: \(relationships.recordingName)")
        }
        
        // Update relationships
        if relationships.hasRecording || relationships.transcriptExists {
            let updatedRelationships = FileRelationships(
                recordingURL: relationships.recordingURL,
                recordingName: relationships.recordingName,
                recordingDate: relationships.recordingDate,
                transcriptExists: relationships.transcriptExists,
                summaryExists: false,
                iCloudSynced: relationships.iCloudSynced
            )
            await updateFileRelationships(for: url, relationships: updatedRelationships)
        } else {
            // Remove the relationship entirely if nothing else exists
            await MainActor.run {
                _ = fileRelationships.removeValue(forKey: url)
                saveFileRelationships()
            }
        }
    }
    
    func deleteTranscript(for url: URL) async throws {
        guard let relationships = fileRelationships[url] else {
            throw FileManagementError.relationshipNotFound
        }
        
        if relationships.transcriptExists {
            // This will now be handled by the coordinator
            // transcriptManager.deleteTranscript(for: url)
            print("✅ Deleted transcript for: \(relationships.recordingName)")
        }
        
        // Update relationships
        if relationships.hasRecording || relationships.summaryExists {
            let updatedRelationships = FileRelationships(
                recordingURL: relationships.recordingURL,
                recordingName: relationships.recordingName,
                recordingDate: relationships.recordingDate,
                transcriptExists: false,
                summaryExists: relationships.summaryExists,
                iCloudSynced: relationships.iCloudSynced
            )
            await updateFileRelationships(for: url, relationships: updatedRelationships)
        } else {
            // Remove the relationship entirely if nothing else exists
            await MainActor.run {
                _ = fileRelationships.removeValue(forKey: url)
                saveFileRelationships()
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
        print("🧹 Cleared all file relationships")
    }
    
    private func getRecordingDate(for url: URL) -> Date {
        // Check if file exists before trying to get its creation date
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("⚠️ File does not exist, using current date for: \(url.lastPathComponent)")
            return Date()
        }
        
        do {
            let resourceValues = try url.resourceValues(forKeys: [.creationDateKey])
            return resourceValues.creationDate ?? Date()
        } catch {
            print("❌ Error getting creation date for \(url.lastPathComponent): \(error)")
            return Date()
        }
    }
    
    // MARK: - Persistence
    
    private func saveFileRelationships() {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("❌ Could not get documents directory")
            return
        }
        
        let relationshipsURL = documentsURL.appendingPathComponent(relationshipsFileName)
        
        do {
            let data = try JSONEncoder().encode(fileRelationships)
            try data.write(to: relationshipsURL)
            print("✅ Saved file relationships")
        } catch {
            print("❌ Error saving file relationships: \(error)")
        }
    }
    
    private func loadFileRelationships() {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("❌ Could not get documents directory")
            return
        }
        
        let relationshipsURL = documentsURL.appendingPathComponent(relationshipsFileName)
        
        guard FileManager.default.fileExists(atPath: relationshipsURL.path) else {
            print("ℹ️ No existing file relationships found")
            return
        }
        
        do {
            let data = try Data(contentsOf: relationshipsURL)
            fileRelationships = try JSONDecoder().decode([URL: FileRelationships].self, from: data)
            // File relationships loaded
        } catch {
            print("❌ Error loading file relationships: \(error)")
            fileRelationships = [:]
        }
    }
    
    // MARK: - Orphaned File Cleanup
    
    /// Find orphaned audio files that exist on disk but not in Core Data
    @MainActor
    func findOrphanedAudioFiles(coordinator: AppDataCoordinator) -> [URL] {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        var orphanedFiles: [URL] = []
        
        do {
            let allFiles = try FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
            let audioFiles = allFiles.filter { url in
                let ext = url.pathExtension.lowercased()
                return ext == "m4a" || ext == "wav" || ext == "mp3" || ext == "aac"
            }
            
            print("🔍 Found \(audioFiles.count) audio files on disk")
            
            // Get all valid recording URLs from Core Data using the proper method
            let allRecordings = coordinator.coreDataManager.getAllRecordings()
            let coreDataURLs = Set(allRecordings.compactMap { recording -> String? in
                // Use the proper getAbsoluteURL method that handles all URL conversion logic
                return coordinator.coreDataManager.getAbsoluteURL(for: recording)?.path
            })
            
            print("🔍 Found \(coreDataURLs.count) valid recording references in Core Data")
            
            // Find files that exist on disk but not in Core Data
            for audioFile in audioFiles {
                if !coreDataURLs.contains(audioFile.path) {
                    orphanedFiles.append(audioFile)
                    print("🧹 Found orphaned file: \(audioFile.lastPathComponent)")
                }
            }
            
            print("🔍 Found \(orphanedFiles.count) orphaned audio files")
            return orphanedFiles
            
        } catch {
            print("❌ Error finding orphaned files: \(error)")
            return []
        }
    }
    
    /// Clean up orphaned audio files with confirmation
    @MainActor
    func cleanupOrphanedAudioFiles(coordinator: AppDataCoordinator, dryRun: Bool = true) -> (deleted: Int, totalSize: Int64, errors: [String]) {
        let orphanedFiles = findOrphanedAudioFiles(coordinator: coordinator)
        var deletedCount = 0
        var totalSize: Int64 = 0
        var errors: [String] = []
        
        for file in orphanedFiles {
            do {
                // Get file size
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                let fileSize = attributes[.size] as? Int64 ?? 0
                totalSize += fileSize
                
                if !dryRun {
                    try FileManager.default.removeItem(at: file)
                    print("🗑 Deleted orphaned file: \(file.lastPathComponent) (\(fileSize) bytes)")
                    deletedCount += 1
                } else {
                    print("🔍 Would delete: \(file.lastPathComponent) (\(fileSize) bytes)")
                }
                
            } catch {
                let errorMsg = "Failed to \(dryRun ? "analyze" : "delete") \(file.lastPathComponent): \(error.localizedDescription)"
                errors.append(errorMsg)
                print("❌ \(errorMsg)")
            }
        }
        
        if dryRun {
            print("🔍 Dry run complete: Found \(orphanedFiles.count) orphaned files totaling \(totalSize) bytes")
        } else {
            print("🧹 Cleanup complete: Deleted \(deletedCount) files, freed \(totalSize) bytes")
        }
        
        return (deleted: deletedCount, totalSize: totalSize, errors: errors)
    }
}

// MARK: - Error Types

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