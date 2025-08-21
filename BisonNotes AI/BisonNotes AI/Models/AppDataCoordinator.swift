import Foundation
import SwiftUI

// MARK: - App Data Coordinator
// Manages the unified registry system for recordings, transcripts, and summaries

@MainActor
class AppDataCoordinator: ObservableObject {
    
    // Core Data system
    @Published var coreDataManager: CoreDataManager
    @Published var workflowManager: RecordingWorkflowManager
    
    @Published var isInitialized = false
    
    init() {
        // Initialize Core Data system
        self.coreDataManager = CoreDataManager()
        self.workflowManager = RecordingWorkflowManager()
        
        // Set up the circular reference after initialization
        self.workflowManager.setAppCoordinator(self)
        
        Task {
            await initializeSystem()
        }
    }
    
    private func initializeSystem() async {
        // Core Data system initialization
        isInitialized = true
    }
    
    // MARK: - Public Interface
    
    func addRecording(url: URL, name: String, date: Date, fileSize: Int64, duration: TimeInterval, quality: AudioQuality, locationData: LocationData? = nil) -> UUID {
        return workflowManager.createRecording(
            url: url,
            name: name,
            date: date,
            fileSize: fileSize,
            duration: duration,
            quality: quality,
            locationData: locationData
        )
    }
    
    func addWatchRecording(url: URL, name: String, date: Date, fileSize: Int64, duration: TimeInterval, quality: AudioQuality, locationData: LocationData? = nil) -> UUID {
        return workflowManager.createRecording(
            url: url,
            name: name,
            date: date,
            fileSize: fileSize,
            duration: duration,
            quality: quality,
            locationData: locationData
        )
    }
    
    func addTranscript(for recordingId: UUID, segments: [TranscriptSegment], speakerMappings: [String: String] = [:], engine: TranscriptionEngine? = nil, processingTime: TimeInterval = 0, confidence: Double = 0.5) -> UUID? {
        return workflowManager.createTranscript(
            for: recordingId,
            segments: segments,
            speakerMappings: speakerMappings,
            engine: engine,
            processingTime: processingTime,
            confidence: confidence
        )
    }
    
    func addSummary(for recordingId: UUID, transcriptId: UUID, summary: String, tasks: [TaskItem] = [], reminders: [ReminderItem] = [], titles: [TitleItem] = [], contentType: ContentType = .general, aiMethod: String, originalLength: Int, processingTime: TimeInterval = 0) -> UUID? {
        return workflowManager.createSummary(
            for: recordingId,
            transcriptId: transcriptId,
            summary: summary,
            tasks: tasks,
            reminders: reminders,
            titles: titles,
            contentType: contentType,
            aiMethod: aiMethod,
            originalLength: originalLength,
            processingTime: processingTime
        )
    }
    
    func getRecording(id: UUID) -> RecordingEntry? {
        return coreDataManager.getRecording(id: id)
    }
    
    func getRecording(url: URL) -> RecordingEntry? {
        return coreDataManager.getRecording(url: url)
    }
    
    /// Gets the current absolute URL for a recording, handling container ID changes automatically
    func getAbsoluteURL(for recording: RecordingEntry) -> URL? {
        return coreDataManager.getAbsoluteURL(for: recording)
    }
    
    /// Gets transcript entry for a recording
    func getTranscript(for recordingId: UUID) -> TranscriptEntry? {
        return coreDataManager.getTranscript(for: recordingId)
    }
    
    /// Gets transcript data for a recording
    func getTranscriptData(for recordingId: UUID) -> TranscriptData? {
        return coreDataManager.getTranscriptData(for: recordingId)
    }
    
    /// Gets all transcripts
    func getAllTranscripts() -> [TranscriptEntry] {
        return coreDataManager.getAllTranscripts()
    }
    
    /// Gets summary entry for a recording
    func getSummary(for recordingId: UUID) -> SummaryEntry? {
        return coreDataManager.getSummary(for: recordingId)
    }
    
    /// Gets all summaries
    func getAllSummaries() -> [SummaryEntry] {
        return coreDataManager.getAllSummaries()
    }
    
    func getCompleteRecordingData(id: UUID) -> (recording: RecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)? {
        return coreDataManager.getCompleteRecordingData(id: id)
    }
    
    func getAllRecordingsWithData() -> [(recording: RecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)] {
        return coreDataManager.getAllRecordingsWithData()
    }
    
    func getRecordingsWithTranscripts() -> [(recording: RecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)] {
        return coreDataManager.getRecordingsWithTranscripts()
    }
    
    func deleteRecording(id: UUID) {
        coreDataManager.deleteRecording(id: id)
    }

    func deleteSummary(id: UUID) async throws {
        try coreDataManager.deleteSummary(id: id)
        do {
            try await SummaryManager.shared.getiCloudManager().deleteSummaryFromiCloud(id)
        } catch {
            print("⚠️ Failed to delete summary from iCloud: \(error)")
            // Re-throw the error so caller can handle the partial failure
            throw error
        }
    }

    func updateRecordingName(recordingId: UUID, newName: String) {
        workflowManager.updateRecordingName(recordingId: recordingId, newName: newName)
    }
    
    func syncRecordingURLs() {
        // First, migrate any remaining absolute URLs to relative paths
        coreDataManager.migrateURLsToRelativePaths()
        
        // Then run the legacy sync (should be minimal after migration)
        coreDataManager.syncRecordingURLs()
    }
    
    // MARK: - Location Methods
    
    /// Gets the absolute URL for a location file associated with a recording
    func getLocationFileURL(for recording: RecordingEntry) -> URL? {
        return coreDataManager.getLocationFileURL(for: recording)
    }
    
    /// Loads location data for a recording using proper URL resolution
    func loadLocationData(for recording: RecordingEntry) -> LocationData? {
        return coreDataManager.loadLocationData(for: recording)
    }
    
    // MARK: - Cleanup Methods
    
    /// Cleans up orphaned recordings that have no audio file and no meaningful content
    func cleanupOrphanedRecordings() -> Int {
        return coreDataManager.cleanupOrphanedRecordings()
    }
    
    /// Fixes recordings that should have been deleted completely but still exist as orphans
    func fixIncompletelyDeletedRecordings() -> Int {
        return coreDataManager.fixIncompletelyDeletedRecordings()
    }
    
    /// Cleans up recordings that reference missing files
    func cleanupRecordingsWithMissingFiles() -> Int {
        return coreDataManager.cleanupRecordingsWithMissingFiles()
    }
    
    // MARK: - Watch Sync Methods
    
    func handleWatchSyncRecording(audioData: Data, syncRequest: WatchSyncRequest) async {
        do {
            // Create temporary file from audio data
            let tempDirectory = FileManager.default.temporaryDirectory
            let tempURL = tempDirectory.appendingPathComponent(syncRequest.filename)
            
            try audioData.write(to: tempURL)
            
            // Convert watch location data if available
            let locationData: LocationData? = syncRequest.locationData?.toLocationData()
            
            // Create recording entry
            let recordingId = addWatchRecording(
                url: tempURL,
                name: syncRequest.filename.replacingOccurrences(of: ".m4a", with: ""),
                date: syncRequest.createdAt,
                fileSize: syncRequest.fileSize,
                duration: syncRequest.duration,
                quality: .whisperOptimized,
                locationData: locationData
            )
            
            print("✅ Watch recording synced successfully: \(syncRequest.filename)")
            
            // Notify completion
            WatchConnectivityManager.shared.onWatchRecordingSyncCompleted?(recordingId, true)
            
        } catch {
            print("❌ Failed to sync watch recording: \(error)")
            WatchConnectivityManager.shared.onWatchRecordingSyncCompleted?(syncRequest.recordingId, false)
        }
    }
    
    // MARK: - Debug Methods
    
    func debugDatabaseContents() {
        coreDataManager.debugDatabaseContents()
    }
}