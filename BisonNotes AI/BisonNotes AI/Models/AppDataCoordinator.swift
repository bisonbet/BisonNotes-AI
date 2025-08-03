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
        print("🚀 Initializing Core Data system...")
        
        // Debug current database state
        coreDataManager.debugDatabaseContents()
        
        isInitialized = true
        print("✅ Core Data system initialized")
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
    
    func updateRecordingName(recordingId: UUID, newName: String) {
        workflowManager.updateRecordingName(recordingId: recordingId, newName: newName)
    }
    
    func syncRecordingURLs() {
        coreDataManager.syncRecordingURLs()
    }
    
    // MARK: - Debug Methods
    
    func debugDatabaseContents() {
        coreDataManager.debugDatabaseContents()
    }
}