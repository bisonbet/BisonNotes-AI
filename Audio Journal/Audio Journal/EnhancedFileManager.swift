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
    
    private let transcriptManager = TranscriptManager.shared
    private let relationshipsFileName = "file_relationships.json"
    
    // Lazy initialization to avoid main actor issues
    private var _summaryManager: SummaryManager?
    private var summaryManager: SummaryManager {
        get async {
            if let manager = _summaryManager {
                return manager
            }
            let manager = await MainActor.run { SummaryManager() }
            _summaryManager = manager
            return manager
        }
    }
    
    private init() {
        loadFileRelationships()
        refreshAllRelationships()
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
        let transcriptExists = await MainActor.run { transcriptManager.hasTranscript(for: url) }
        let manager = await summaryManager
        let summaryExists = await MainActor.run { manager.hasSummary(for: url) }
        
        // Check iCloud sync status (placeholder for now)
        let iCloudSynced = false // TODO: Implement actual iCloud sync check
        
        let recordingName = url.deletingPathExtension().lastPathComponent
        let recordingDate = getRecordingDate(for: url)
        
        let relationships = FileRelationships(
            recordingURL: recordingExists ? url : nil,
            recordingName: recordingName,
            recordingDate: recordingDate,
            transcriptExists: transcriptExists,
            summaryExists: summaryExists,
            iCloudSynced: iCloudSynced
        )
        
        await updateFileRelationships(for: url, relationships: relationships)
    }
    
    func refreshAllRelationships() {
        Task {
            // Get all known recording URLs from various sources
            var allURLs = Set<URL>()
            
            // Add URLs from existing relationships
            allURLs.formUnion(fileRelationships.keys)
            
            // Add URLs from transcript manager
            for transcript in transcriptManager.transcripts {
                allURLs.insert(transcript.recordingURL)
            }
            
            // Add URLs from summary manager
            let manager = await summaryManager
            let summaries = await MainActor.run { manager.summaries }
            for summary in summaries {
                allURLs.insert(summary.recordingURL)
            }
            
            // Add URLs from file system
            if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                do {
                    let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
                    let audioURLs = fileURLs.filter { ["m4a", "mp3", "wav"].contains($0.pathExtension.lowercased()) }
                    allURLs.formUnion(audioURLs)
                } catch {
                    print("❌ Error scanning documents directory: \(error)")
                }
            }
            
            // Refresh relationships for all URLs
            for url in allURLs {
                await refreshRelationships(for: url)
            }
        }
    }
    
    // MARK: - Selective Deletion
    
    func deleteRecording(_ url: URL, preserveSummary: Bool) async throws {
        guard let relationships = fileRelationships[url] else {
            throw FileManagementError.relationshipNotFound
        }
        
        // Stop any playback if this recording is currently playing
        // Note: This would need to be coordinated with the AudioRecorderViewModel
        
        // Delete the audio file if it exists
        if relationships.hasRecording {
            try FileManager.default.removeItem(at: url)
            print("✅ Deleted audio file: \(url.lastPathComponent)")
            
            // Delete associated location file if it exists
            let locationURL = url.deletingPathExtension().appendingPathExtension("location")
            if FileManager.default.fileExists(atPath: locationURL.path) {
                try FileManager.default.removeItem(at: locationURL)
                print("✅ Deleted location file: \(locationURL.lastPathComponent)")
            }
        }
        
        // Always delete transcript when recording is deleted
        if relationships.transcriptExists {
            transcriptManager.deleteTranscript(for: url)
            print("✅ Deleted transcript for: \(relationships.recordingName)")
        }
        
        // Delete summary only if not preserving it
        if relationships.summaryExists && !preserveSummary {
            let manager = await summaryManager
            await MainActor.run { manager.deleteSummary(for: url) }
            print("✅ Deleted summary for: \(relationships.recordingName)")
        }
        
        // Update relationships
        if preserveSummary && relationships.summaryExists {
            // Keep the relationship but mark recording as unavailable
            let updatedRelationships = FileRelationships(
                recordingURL: nil, // Recording no longer available
                recordingName: relationships.recordingName,
                recordingDate: relationships.recordingDate,
                transcriptExists: false, // Transcript deleted with recording
                summaryExists: true, // Summary preserved
                iCloudSynced: relationships.iCloudSynced
            )
            await updateFileRelationships(for: url, relationships: updatedRelationships)
        } else {
            // Remove the relationship entirely
            await MainActor.run {
                fileRelationships.removeValue(forKey: url)
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
            let manager = await summaryManager
            await MainActor.run { manager.deleteSummary(for: url) }
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
                fileRelationships.removeValue(forKey: url)
                saveFileRelationships()
            }
        }
    }
    
    func deleteTranscript(for url: URL) async throws {
        guard let relationships = fileRelationships[url] else {
            throw FileManagementError.relationshipNotFound
        }
        
        if relationships.transcriptExists {
            transcriptManager.deleteTranscript(for: url)
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
                fileRelationships.removeValue(forKey: url)
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
    
    private func getRecordingDate(for url: URL) -> Date {
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
            print("✅ Loaded file relationships: \(fileRelationships.count) entries")
        } catch {
            print("❌ Error loading file relationships: \(error)")
            fileRelationships = [:]
        }
    }
}

// MARK: - Error Types

enum FileManagementError: Error, LocalizedError {
    case relationshipNotFound
    case fileNotFound
    case deletionFailed(String)
    case persistenceError(String)
    
    var errorDescription: String? {
        switch self {
        case .relationshipNotFound:
            return "File relationship not found"
        case .fileNotFound:
            return "File not found"
        case .deletionFailed(let message):
            return "Deletion failed: \(message)"
        case .persistenceError(let message):
            return "Persistence error: \(message)"
        }
    }
}