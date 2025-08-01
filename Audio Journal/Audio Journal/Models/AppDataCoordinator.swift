import Foundation
import SwiftUI

// MARK: - App Data Coordinator
// Manages the unified registry system for recordings, transcripts, and summaries

@MainActor
class AppDataCoordinator: ObservableObject {
    
    // Unified system
    @Published var registryManager: RecordingRegistryManager
    @Published var unifiedSyncManager: UnifiediCloudSyncManager
    
    @Published var isInitialized = false
    
    init() {
        // Initialize unified system
        let registryManager = RecordingRegistryManager()
        self.registryManager = registryManager
        self.unifiedSyncManager = UnifiediCloudSyncManager(registryManager: registryManager)
        
        Task {
            await initializeSystem()
        }
    }
    
    private func initializeSystem() async {
        print("🚀 Initializing unified data system...")
        
        // Initialize sync if enabled
        if unifiedSyncManager.isEnabled {
            do {
                try await unifiedSyncManager.syncAllData()
            } catch {
                print("⚠️ Initial sync failed: \(error)")
            }
        }
        
        isInitialized = true
        print("✅ Unified data system initialized")
    }
    
    // MARK: - Public Interface
    
    func addRecording(url: URL, name: String, date: Date, fileSize: Int64, duration: TimeInterval, quality: AudioQuality) -> UUID {
        return registryManager.addRecording(
            url: url,
            name: name,
            date: date,
            fileSize: fileSize,
            duration: duration,
            quality: quality
        )
    }
    
    func addTranscript(_ transcript: TranscriptData) {
        registryManager.addTranscript(transcript)
        
        // Sync to cloud if enabled
        if unifiedSyncManager.isEnabled {
            Task {
                try? await unifiedSyncManager.syncAllData()
            }
        }
    }
    
    func addSummary(_ summary: EnhancedSummaryData) {
        registryManager.addSummary(summary)
        
        // Sync to cloud if enabled
        if unifiedSyncManager.isEnabled {
            Task {
                try? await unifiedSyncManager.syncAllData()
            }
        }
    }
    
    func getRecording(id: UUID) -> RegistryRecordingEntry? {
        return registryManager.getRecording(id: id)
    }
    
    func getRecording(url: URL) -> RegistryRecordingEntry? {
        return registryManager.getRecording(url: url)
    }
    
    func getCompleteRecordingData(id: UUID) -> (recording: RegistryRecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)? {
        return registryManager.getCompleteRecordingData(id: id)
    }
    
    func getAllRecordingsWithData() -> [(recording: RegistryRecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)] {
        return registryManager.getAllRecordingsWithData()
    }
    
    func deleteRecording(id: UUID) {
        registryManager.deleteRecording(id: id)
        
        // Sync deletion to cloud if enabled
        if unifiedSyncManager.isEnabled {
            Task {
                try? await unifiedSyncManager.syncAllData()
            }
        }
    }
    
    func updateTranscriptionStatus(recordingId: UUID, status: ProcessingStatus) {
        registryManager.updateTranscriptionStatus(recordingId: recordingId, status: status)
    }
    
    func updateSummaryStatus(recordingId: UUID, status: ProcessingStatus) {
        registryManager.updateSummaryStatus(recordingId: recordingId, status: status)
    }
    
    func refreshRecordingsFromDisk() {
        registryManager.refreshRecordingsFromDisk()
    }
    
    // MARK: - Sync Management
    
    func enableCloudSync() {
        unifiedSyncManager.isEnabled = true
    }
    
    func disableCloudSync() {
        unifiedSyncManager.isEnabled = false
    }
    
    func performManualSync() async throws {
        try await unifiedSyncManager.syncAllData()
    }
    
    func fetchFromCloud() async throws {
        try await unifiedSyncManager.fetchAllDataFromCloud()
    }
    
    // MARK: - Legacy Compatibility Methods
    
    func getBestAvailableSummary(for url: URL) -> EnhancedSummaryData? {
        return registryManager.getBestAvailableSummary(for: url)
    }
    
    func getTranscript(for url: URL) -> TranscriptData? {
        return registryManager.getTranscript(for: url)
    }
    
    func deleteSummary(for url: URL) {
        registryManager.deleteSummary(for: url)
    }
    
    func setEngine(_ engine: String) {
        registryManager.setEngine(engine)
    }
    
    func generateEnhancedSummary(from transcriptText: String, for url: URL, recordingName: String, recordingDate: Date) async throws -> EnhancedSummaryData {
        // Set the current AI engine to use the currently selected engine from settings
        let selectedEngine = UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? "Enhanced Apple Intelligence"
        print("🔧 AppDataCoordinator: Using selected engine: \(selectedEngine)")
        registryManager.setEngine(selectedEngine)
        
        return try await registryManager.generateEnhancedSummary(from: transcriptText, for: url, recordingName: recordingName, recordingDate: recordingDate)
    }
    
    func convertLegacyToEnhanced(_ summary: SummaryData) -> EnhancedSummaryData {
        return registryManager.convertLegacyToEnhanced(summary)
    }
    
    // MARK: - Data Repair Methods
    
    func forceReloadTranscripts() {
        registryManager.forceReloadTranscripts()
    }
    
    func debugTranscriptStatus() {
        registryManager.debugTranscriptStatus()
    }
    
    func updateRecordingDurations() {
        registryManager.updateRecordingDurations()
    }
    
    func removeDuplicateRecordings() {
        registryManager.removeDuplicateRecordings()
    }
    
    func clearAndReloadRegistry() {
        registryManager.clearAndReloadRegistry()
    }
    
    func debugTranscriptLinking() {
        registryManager.debugTranscriptLinking()
    }
    
    func cleanupDuplicateSummaries() {
        registryManager.cleanupDuplicateSummaries()
    }
    
    func fixSummariesWithNilRecordingId() {
        registryManager.fixSummariesWithNilRecordingId()
    }
    
    func linkSummariesToRecordings() {
        registryManager.linkSummariesToRecordings()
    }
    
    func linkSummariesToRecordingsWithTranscripts() {
        registryManager.linkSummariesToRecordingsWithTranscripts()
    }
    
    // MARK: - Debug and Recovery Methods
    
    func debugTranscriptRecovery() {
        print("🔍 Debugging transcript recovery...")
        
        let allRecordings = registryManager.recordings
        let allTranscripts = registryManager.transcripts
        
        print("📊 Current state:")
        print("   - Recordings in registry: \(allRecordings.count)")
        print("   - Transcripts in registry: \(allTranscripts.count)")
        
        // Check for recordings that should have transcripts but don't
        for recording in allRecordings {
            let hasTranscript = allTranscripts.contains { transcript in
                transcript.recordingId == recording.id || transcript.recordingURL == recording.recordingURL
            }
            
            if !hasTranscript {
                print("⚠️  Recording without transcript: \(recording.recordingName)")
                print("   - Recording ID: \(recording.id)")
                print("   - Recording URL: \(recording.recordingURL.lastPathComponent)")
                
                // Check if the file exists on disk
                let fileExists = FileManager.default.fileExists(atPath: recording.recordingURL.path)
                print("   - File exists on disk: \(fileExists)")
                
                // Check if there might be a transcript file on disk
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let transcriptURL = documentsPath.appendingPathComponent("\(recording.recordingName).transcript")
                let transcriptFileExists = FileManager.default.fileExists(atPath: transcriptURL.path)
                print("   - Transcript file exists: \(transcriptFileExists)")
                
                if transcriptFileExists {
                    print("🔧 Found transcript file on disk that's not in registry!")
                    print("   - Transcript file: \(transcriptURL.lastPathComponent)")
                    
                    // Try to load and add the transcript
                    do {
                        let transcriptData = try Data(contentsOf: transcriptURL)
                        if let transcript = try? JSONDecoder().decode(TranscriptData.self, from: transcriptData) {
                            print("✅ Successfully loaded transcript from disk")
                            print("   - Transcript ID: \(transcript.id)")
                            print("   - Transcript segments: \(transcript.segments.count)")
                            
                            // Create a new transcript instance with updated recording info
                            let updatedTranscript = TranscriptData(
                                recordingId: recording.id,
                                recordingURL: recording.recordingURL,
                                recordingName: recording.recordingName,
                                recordingDate: recording.recordingDate,
                                segments: transcript.segments,
                                speakerMappings: transcript.speakerMappings,
                                engine: transcript.engine,
                                processingTime: transcript.processingTime,
                                confidence: transcript.confidence
                            )
                            
                            // Add to registry
                            registryManager.addTranscript(updatedTranscript)
                            print("✅ Added transcript back to registry")
                        }
                    } catch {
                        print("❌ Failed to load transcript from disk: \(error)")
                    }
                }
            }
        }
        
        // Check for orphaned transcripts
        for transcript in allTranscripts {
            let hasMatchingRecording = allRecordings.contains { recording in
                recording.id == transcript.recordingId || recording.recordingURL == transcript.recordingURL
            }
            
            if !hasMatchingRecording {
                print("🗑️  Orphaned transcript: \(transcript.recordingName)")
                print("   - Transcript ID: \(transcript.id)")
                print("   - Recording ID: \(transcript.recordingId?.uuidString ?? "nil")")
                print("   - Recording URL: \(transcript.recordingURL.lastPathComponent)")
            }
        }
        
        print("🔍 Debug complete")
    }
    
    func recoverTranscriptsFromDisk() {
        registryManager.recoverTranscriptsFromDisk()
    }
}