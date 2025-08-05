import Foundation
import AVFoundation

// MARK: - Recording Registry
// Central data model that manages relationships between recordings, transcripts, and summaries

public struct RegistryRecordingEntry: Codable, Identifiable {
    public let id: UUID
    public let recordingURL: URL
    public let recordingName: String
    public let recordingDate: Date
    public let createdAt: Date
    public var lastModified: Date
    
    // File metadata
    public let fileSize: Int64
    public var duration: TimeInterval
    public let audioQuality: AudioQuality
    
    // Processing status
    public var transcriptionStatus: ProcessingStatus
    public var summaryStatus: ProcessingStatus
    
    // Linked data IDs
    public var transcriptId: UUID?
    public var summaryId: UUID?
    
    public init(recordingURL: URL, recordingName: String, recordingDate: Date, fileSize: Int64, duration: TimeInterval, audioQuality: AudioQuality) {
        self.id = UUID()
        self.recordingURL = recordingURL
        self.recordingName = recordingName
        self.recordingDate = recordingDate
        self.createdAt = Date()
        self.lastModified = Date()
        self.fileSize = fileSize
        self.duration = duration
        self.audioQuality = audioQuality
        self.transcriptionStatus = .notStarted
        self.summaryStatus = .notStarted
        self.transcriptId = nil
        self.summaryId = nil
    }
    
    mutating func updateTranscript(id: UUID) {
        self.transcriptId = id
        self.transcriptionStatus = .completed
        self.lastModified = Date()
    }
    
    mutating func updateSummary(id: UUID) {
        self.summaryId = id
        self.summaryStatus = .completed
        self.lastModified = Date()
    }
    
    mutating func setTranscriptionStatus(_ status: ProcessingStatus) {
        self.transcriptionStatus = status
        self.lastModified = Date()
    }
    
    mutating func setSummaryStatus(_ status: ProcessingStatus) {
        self.summaryStatus = status
        self.lastModified = Date()
    }
    
    var hasTranscript: Bool {
        return transcriptId != nil && transcriptionStatus == .completed
    }
    
    var hasSummary: Bool {
        return summaryId != nil && summaryStatus == .completed
    }
    
    var isProcessingComplete: Bool {
        return hasTranscript && hasSummary
    }
}

// MARK: - Processing Status

public enum ProcessingStatus: String, Codable, CaseIterable {
    case notStarted = "Not Started"
    case queued = "Queued"
    case processing = "Processing"
    case completed = "Completed"
    case failed = "Failed"
    case cancelled = "Cancelled"
    
    public var description: String {
        return self.rawValue
    }
    
    public var isActive: Bool {
        return self == .queued || self == .processing
    }
    
    public var isComplete: Bool {
        return self == .completed
    }
    
    public var hasError: Bool {
        return self == .failed || self == .cancelled
    }
}

// MARK: - Recording Registry Manager

@MainActor
public class RecordingRegistryManager: ObservableObject {
    @Published public var recordings: [RegistryRecordingEntry] = []
    @Published public var transcripts: [TranscriptData] = []
    @Published public var enhancedSummaries: [EnhancedSummaryData] = []
    
    private let recordingsKey = "SavedRecordings"
    private let transcriptsKey = "SavedTranscripts"
    private let enhancedSummariesKey = "SavedEnhancedSummaries"
    
    // MARK: - Enhanced Summarization Integration
    
    private var currentEngine: SummarizationEngine?
    private var availableEngines: [String: SummarizationEngine] = [:]
    // Task and Reminder Extractors for enhanced processing
    private let taskExtractor = TaskExtractor()
    private let reminderExtractor = ReminderExtractor()
    
    // MARK: - Error Handling Integration
    
    private let errorHandler = ErrorHandler()
    @Published var currentError: AppError?
    @Published var showingErrorAlert = false
    
    // MARK: - Performance Monitoring Integration
    
    private lazy var performanceMonitor = EnginePerformanceMonitor()
    
    // MARK: - iCloud Integration
    
    private let iCloudManager: iCloudStorageManager = {
        // Use preview instance in preview environments
        let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" ||
                       ProcessInfo.processInfo.processName.contains("PreviewShell") ||
                       ProcessInfo.processInfo.arguments.contains("--enable-previews")
        
        if isPreview {
            print("🔍 RecordingRegistryManager using preview iCloudManager")
            return iCloudStorageManager.preview
        }
        return iCloudStorageManager()
    }()
    
    init() {
        loadRecordings()
        loadTranscripts()
        loadEnhancedSummaries()
        initializeEngines()
    }
    
    // MARK: - Recording Management
    
    func addRecording(url: URL, name: String, date: Date, fileSize: Int64, duration: TimeInterval, quality: AudioQuality) -> UUID {
        let recording = RegistryRecordingEntry(
            recordingURL: url,
            recordingName: name,
            recordingDate: date,
            fileSize: fileSize,
            duration: duration,
            audioQuality: quality
        )
        
        recordings.append(recording)
        saveRecordings()
        
        return recording.id
    }
    
    func getRecording(id: UUID) -> RegistryRecordingEntry? {
        return recordings.first { $0.id == id }
    }
    
    func getRecording(url: URL) -> RegistryRecordingEntry? {
        print("🔍 getRecording(url:) called with: \(url.lastPathComponent)")
        let result = recordings.first { recording in
            let matches = recording.recordingURL.lastPathComponent == url.lastPathComponent
            print("   Comparing: \(recording.recordingURL.lastPathComponent) == \(url.lastPathComponent) -> \(matches)")
            return matches
        }
        print("   Result: \(result?.recordingName ?? "nil")")
        return result
    }
    
    func deleteRecording(id: UUID) {
        recordings.removeAll { $0.id == id }
        saveRecordings()
    }
    
    // MARK: - Transcript Management
    
    func addTranscript(_ transcript: TranscriptData) {
        transcripts.append(transcript)
        saveTranscripts()
        
        // Update recording status
        if let recordingId = transcript.recordingId,
           let recording = getRecording(id: recordingId) {
            var updatedRecording = recording
            updatedRecording.updateTranscript(id: transcript.id)
            updateRecording(updatedRecording)
        }
    }
    
    func getTranscript(for url: URL) -> TranscriptData? {
        guard let recording = getRecording(url: url) else { return nil }
        return transcripts.first { $0.recordingId == recording.id }
    }
    
    func deleteTranscript(for url: URL) {
        guard let recording = getRecording(url: url) else { return }
        transcripts.removeAll { $0.recordingId == recording.id }
        saveTranscripts()
    }
    
    // MARK: - Summary Management
    
    func addSummary(_ summary: EnhancedSummaryData) {
        print("🔧 RecordingRegistry: Adding summary for recording: \(summary.recordingName)")
        print("   - Recording ID: \(summary.recordingId?.uuidString ?? "nil")")
        print("   - AI Method: \(summary.aiMethod)")
        print("   - Generated at: \(summary.generatedAt)")
        
        // Remove any existing summaries for the same recording to prevent duplicates
        if let recordingId = summary.recordingId {
            let existingCount = enhancedSummaries.filter { $0.recordingId == recordingId }.count
            if existingCount > 0 {
                print("🗑️ Removing \(existingCount) existing summaries for recording ID: \(recordingId)")
            }
            enhancedSummaries.removeAll { $0.recordingId == recordingId }
        }
        
        enhancedSummaries.append(summary)
        saveEnhancedSummaries()
        
        print("✅ Summary added. Total summaries: \(enhancedSummaries.count)")
        
        // Update recording status
        if let recordingId = summary.recordingId,
           let recording = getRecording(id: recordingId) {
            var updatedRecording = recording
            updatedRecording.updateSummary(id: summary.id)
            updateRecording(updatedRecording)
            print("✅ Updated recording status for: \(recording.recordingName)")
        }
    }
    
    func getSummary(for url: URL) -> EnhancedSummaryData? {
        guard let recording = getRecording(url: url) else { 
            print("❌ RecordingRegistry: No recording found for URL: \(url.lastPathComponent)")
            return nil 
        }
        
        let matchingSummaries = enhancedSummaries.filter { $0.recordingId == recording.id }
        print("🔍 RecordingRegistry: Looking for summary for recording: \(recording.recordingName)")
        print("   - Recording ID: \(recording.id)")
        print("   - Found \(matchingSummaries.count) matching summaries")
        
        // Debug: Show all summaries and their recording IDs
        print("   - All summaries in registry:")
        for (index, summary) in enhancedSummaries.enumerated() {
            print("     \(index): \(summary.recordingName) - recordingId: \(summary.recordingId?.uuidString ?? "nil")")
        }
        
        // Get the most recent summary for this recording (by generatedAt date)
        let summary = matchingSummaries.max { $0.generatedAt < $1.generatedAt }
        
        if let summary = summary {
            print("✅ Found summary: \(summary.aiMethod) (generated at: \(summary.generatedAt))")
        } else {
            print("❌ No summary found for recording: \(recording.recordingName)")
        }
        
        return summary
    }
    
    func deleteSummary(for url: URL) {
        guard let recording = getRecording(url: url) else { return }
        enhancedSummaries.removeAll { $0.recordingId == recording.id }
        saveEnhancedSummaries()
    }
    
    func getBestAvailableSummary(for url: URL) -> EnhancedSummaryData? {
        return getSummary(for: url)
    }
    
    // MARK: - Complete Data Access
    
    func getCompleteRecordingData(id: UUID) -> (recording: RegistryRecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)? {
        guard let recording = getRecording(id: id) else { 
            print("❌ RecordingRegistry: No recording found for ID: \(id)")
            return nil 
        }
        
        let transcript = transcripts.first { $0.recordingId == id }
        let matchingSummaries = enhancedSummaries.filter { $0.recordingId == id }
        
        print("🔍 RecordingRegistry: Getting complete data for recording: \(recording.recordingName)")
        print("   - Recording ID: \(id)")
        print("   - Has transcript: \(transcript != nil)")
        print("   - Found \(matchingSummaries.count) summaries")
        
        // Get the most recent summary for this recording (by generatedAt date)
        let summary = matchingSummaries.max { $0.generatedAt < $1.generatedAt }
        
        if let summary = summary {
            print("✅ Using summary: \(summary.aiMethod) (generated at: \(summary.generatedAt))")
        }
        
        return (recording: recording, transcript: transcript, summary: summary)
    }
    
    func getAllRecordingsWithData() -> [(recording: RegistryRecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)] {
        print("🔄 getAllRecordingsWithData() called")
        print("📊 Total recordings: \(recordings.count)")
        print("📊 Total transcripts: \(transcripts.count)")
        print("📊 Total summaries: \(enhancedSummaries.count)")
        
        // Debug: Print all transcripts
        print("🔍 All transcripts:")
        for (index, transcript) in transcripts.enumerated() {
            print("   \(index): \(transcript.recordingName) - ID: \(transcript.recordingId?.uuidString ?? "nil")")
        }
        
        let result = recordings.map { recording in
            let transcript = transcripts.first { $0.recordingId == recording.id }
            // Get the most recent summary for this recording (by generatedAt date)
            let summary = enhancedSummaries
                .filter { $0.recordingId == recording.id }
                .max { $0.generatedAt < $1.generatedAt }
            
            print("🔍 Recording: \(recording.recordingName)")
            print("   - Recording ID: \(recording.id)")
            print("   - Has transcript: \(transcript != nil)")
            print("   - Has summary: \(summary != nil)")
            
            if transcript != nil {
                print("   ✅ Found transcript: \(transcript!.recordingName)")
            } else {
                print("   ❌ No transcript found for recording ID: \(recording.id)")
            }
            
            return (recording: recording, transcript: transcript, summary: summary)
        }
        
        print("📊 Returning \(result.count) recordings with data")
        return result
    }
    
    // MARK: - Status Updates
    
    func updateTranscriptionStatus(recordingId: UUID, status: ProcessingStatus) {
        if let index = recordings.firstIndex(where: { $0.id == recordingId }) {
            recordings[index].setTranscriptionStatus(status)
            saveRecordings()
        }
    }
    
    func updateSummaryStatus(recordingId: UUID, status: ProcessingStatus) {
        if let index = recordings.firstIndex(where: { $0.id == recordingId }) {
            recordings[index].setSummaryStatus(status)
            saveRecordings()
        }
    }
    
    // MARK: - Engine Management
    
    func setEngine(_ engine: String) {
        print("🔧 RecordingRegistry: Setting engine to: \(engine)")
        print("   - Available engines: \(availableEngines.keys.joined(separator: ", "))")
        
        currentEngine = availableEngines[engine]
        
        if let currentEngine = currentEngine {
            print("✅ Engine set successfully: \(currentEngine.name)")
        } else {
            print("❌ Failed to set engine: \(engine)")
            print("   - Available engines: \(availableEngines.keys.joined(separator: ", "))")
        }
    }
    
    func getEngineAvailabilityStatus() -> [String: EngineAvailabilityStatus] {
        var statuses: [String: EngineAvailabilityStatus] = [:]
        
        for (engineName, engine) in availableEngines {
            statuses[engineName] = EngineAvailabilityStatus(
                name: engineName,
                description: engine.description,
                isAvailable: engine.isAvailable,
                isComingSoon: false,
                requirements: [],
                version: engine.version,
                isCurrentEngine: currentEngine?.name == engineName
            )
        }
        
        return statuses
    }
    
    func validateEngineAvailability(_ engine: String) -> EngineValidationResult {
        guard let engineInstance = availableEngines[engine] else {
            return .unavailable("Unknown engine: \(engine)")
        }
        
        return engineInstance.isAvailable ? .available : .unavailable("Engine not available")
    }
    
    func refreshEngineAvailability() async {
        // Engines don't have refreshAvailability method, so we'll just reinitialize them
        initializeEngines()
    }
    
    func isPerformanceMonitoringEnabled() -> Bool {
        return true // Assume monitoring is always enabled for now
    }
    
    // MARK: - Legacy Compatibility
    
    func convertLegacyToEnhanced(_ summary: SummaryData) -> EnhancedSummaryData {
        // Convert legacy SummaryData to EnhancedSummaryData
        return EnhancedSummaryData(
            recordingId: UUID(), // This should be the actual recording ID
            transcriptId: nil,
            recordingURL: summary.recordingURL,
            recordingName: summary.recordingName,
            recordingDate: summary.recordingDate,
            summary: summary.summary,
            tasks: [],
            reminders: [],
            titles: [],
            contentType: .general,
            aiMethod: "Legacy Conversion",
            originalLength: summary.summary.count,
            processingTime: 0
        )
    }
    
    func generateEnhancedSummary(from transcriptText: String, for url: URL, recordingName: String, recordingDate: Date) async throws -> EnhancedSummaryData {
        print("🔍 RecordingRegistryManager.generateEnhancedSummary called")
        print("📝 Transcript length: \(transcriptText.count) characters")
        print("📁 URL: \(url.lastPathComponent)")
        print("📝 Recording name: \(recordingName)")
        print("📅 Recording date: \(recordingDate)")
        
        guard let engine = currentEngine else {
            print("❌ No current engine available")
            print("🔧 Available engines: \(availableEngines.keys.joined(separator: ", "))")
            throw SummarizationError.aiServiceUnavailable(service: "No engine available")
        }
        
        print("✅ Using engine: \(engine.name)")
        print("🔧 Engine type: \(type(of: engine))")
        
        let recordingId = getRecording(url: url)?.id ?? UUID()
        print("📋 Recording ID: \(recordingId)")
        
        // Use the engine's processComplete method
        print("🔧 Calling engine.processComplete...")
        let result = try await engine.processComplete(text: transcriptText)
        
        print("✅ Engine processed successfully")
        print("📄 Summary length: \(result.summary.count) characters")
        print("📋 Tasks: \(result.tasks.count)")
        print("📋 Reminders: \(result.reminders.count)")
        print("📋 Titles: \(result.titles.count)")
        
        return EnhancedSummaryData(
            recordingId: recordingId,
            transcriptId: nil,
            recordingURL: url,
            recordingName: recordingName,
            recordingDate: recordingDate,
            summary: result.summary,
            tasks: result.tasks,
            reminders: result.reminders,
            titles: result.titles,
            contentType: result.contentType,
            aiMethod: engine.name,
            originalLength: transcriptText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count,
            processingTime: 0
        )
    }
    
    // MARK: - Data Repair Methods
    
    func forceReloadTranscripts() {
        print("🔄 Force reloading all transcripts...")
        
        // Clear existing transcripts
        transcripts.removeAll()
        
        // Reload from files
        loadTranscripts()
        
        print("✅ Transcript reload complete. Total transcripts: \(transcripts.count)")
    }
    
    func updateRecordingDurations() {
        print("🔄 Updating recording durations...")
        
        var updatedCount = 0
        for (index, recording) in recordings.enumerated() {
            let actualDuration = getRecordingDuration(url: recording.recordingURL)
            if actualDuration > 0 && recording.duration == 0 {
                var updatedRecording = recording
                updatedRecording.duration = actualDuration
                recordings[index] = updatedRecording
                updatedCount += 1
                print("✅ Updated duration for \(recording.recordingName): \(formatDuration(actualDuration))")
            }
        }
        
        print("✅ Updated \(updatedCount) recording durations")
        saveRecordings()
    }
    
    func removeDuplicateRecordings() {
        print("🧹 Removing duplicate recordings...")
        
        let initialCount = recordings.count
        var seenURLs = Set<URL>()
        var seenNames = Set<String>()
        
        recordings = recordings.filter { recording in
            let urlExists = seenURLs.contains(recording.recordingURL)
            let nameExists = seenNames.contains(recording.recordingName)
            
            if urlExists || nameExists {
                print("🗑️ Removing duplicate recording: \(recording.recordingName)")
                return false
            } else {
                seenURLs.insert(recording.recordingURL)
                seenNames.insert(recording.recordingName)
                return true
            }
        }
        
        let finalCount = recordings.count
        print("✅ Removed \(initialCount - finalCount) duplicate recordings")
        print("📊 Registry now contains \(finalCount) recordings")
        
        saveRecordings()
    }
    

    
    func loadTranscriptsFromDiskOnly() {
        print("🔄 Loading transcripts from disk only...")
        
        // Clear any existing transcripts
        transcripts.removeAll()
        
        // Scan the documents directory for transcript files
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: [.creationDateKey], options: [])
            let transcriptFiles = fileURLs.filter { $0.pathExtension.lowercased() == "transcript" }
            
            print("🔍 Found \(transcriptFiles.count) transcript files in documents directory")
            
            for transcriptURL in transcriptFiles {
                // Get the corresponding audio file URL
                let audioURL = transcriptURL.deletingPathExtension()
                let transcriptName = transcriptURL.deletingPathExtension().lastPathComponent
                
                print("🔍 Processing transcript: \(transcriptName)")
                
                // Check if we have a recording for this audio file
                if let recording = getRecording(url: audioURL) {
                    print("✅ Found matching recording: \(recording.recordingName)")
                    
                    // Try to load the transcript data
                    if let transcriptData = loadTranscriptFromFile(transcriptURL, for: recording) {
                        transcripts.append(transcriptData)
                        
                        // Update the recording status
                        var updatedRecording = recording
                        updatedRecording.updateTranscript(id: transcriptData.id)
                        updateRecording(updatedRecording)
                        
                        print("✅ Successfully loaded transcript for: \(recording.recordingName)")
                    }
                } else {
                    print("❌ No matching recording found for transcript: \(transcriptName)")
                }
            }
            
            // Save the updated transcripts
            saveTranscripts()
            
            print("📊 Final transcript count from disk: \(transcripts.count)")
        } catch {
            print("Error scanning for transcript files: \(error)")
        }
    }
    
    func clearOrphanedTranscripts() {
        print("🧹 Clearing orphaned transcripts...")
        
        let initialCount = transcripts.count
        var orphanedTranscripts: [TranscriptData] = []
        
        for transcript in transcripts {
            // Check if the recording file actually exists on disk
            let fileExists = FileManager.default.fileExists(atPath: transcript.recordingURL.path)
            
            if !fileExists {
                print("🗑️ Found orphaned transcript for non-existent recording: \(transcript.recordingURL.lastPathComponent)")
                orphanedTranscripts.append(transcript)
            }
        }
        
        // Remove orphaned transcripts
        for orphanedTranscript in orphanedTranscripts {
            transcripts.removeAll { $0.id == orphanedTranscript.id }
        }
        
        let removedCount = initialCount - transcripts.count
        print("✅ Removed \(removedCount) orphaned transcripts")
        saveTranscripts()
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    func debugTranscriptStatus() {
        print("🔍 Transcript Debug Status:")
        print("   Total transcripts: \(transcripts.count)")
        print("   Total recordings: \(recordings.count)")
        
        for (index, transcript) in transcripts.enumerated() {
            print("   Transcript \(index):")
            print("     ID: \(transcript.id)")
            print("     Recording ID: \(transcript.recordingId?.uuidString ?? "None")")
            print("     Recording URL: \(transcript.recordingURL.lastPathComponent)")
            print("     Recording Name: \(transcript.recordingName)")
            print("     Segments: \(transcript.segments.count)")
        }
        
        for (index, recording) in recordings.enumerated() {
            print("   Recording \(index):")
            print("     ID: \(recording.id)")
            print("     URL: \(recording.recordingURL.lastPathComponent)")
            print("     Name: \(recording.recordingName)")
            print("     Has Transcript: \(recording.hasTranscript)")
            print("     Transcript ID: \(recording.transcriptId?.uuidString ?? "None")")
        }
    }
    
    // MARK: - Private Methods
    
    private func updateRecording(_ recording: RegistryRecordingEntry) {
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[index] = recording
            saveRecordings()
        }
    }
    
    private func initializeEngines() {
        print("🔧 Initializing AI engines...")
        
        // Initialize available engines
        availableEngines["Enhanced Apple Intelligence"] = EnhancedAppleIntelligenceEngine()
        availableEngines["OpenAI"] = OpenAISummarizationEngine()
        availableEngines["Local LLM (Ollama)"] = LocalLLMEngine()
        availableEngines["OpenAI API Compatible"] = OpenAICompatibleEngine()
        availableEngines["Google AI Studio"] = GoogleAIStudioEngine()
        // AWS Bedrock is coming soon, so we'll add it when available
        // availableEngines["AWS Bedrock"] = AWSBedrockEngine()
        
        print("✅ Available engines: \(availableEngines.keys.joined(separator: ", "))")
        
        // Set default engine
        currentEngine = availableEngines["Enhanced Apple Intelligence"]
        
        if let engine = currentEngine {
            print("✅ Current engine set to: \(engine.name)")
        } else {
            print("❌ Failed to set current engine!")
        }
    }
    
    func checkEngineStatus() {
        print("🔍 Engine Status Check:")
        print("   Available engines: \(availableEngines.count)")
        print("   Current engine: \(currentEngine?.name ?? "None")")
        print("   Engine names: \(availableEngines.keys.joined(separator: ", "))")
        
        if let engine = currentEngine {
            print("✅ Current engine is available: \(engine.name)")
        } else {
            print("❌ No current engine available!")
            print("🔧 Re-initializing engines...")
            initializeEngines()
        }
    }
    
    private func loadRecordings() {
        // First load any saved recordings from UserDefaults
        if let data = UserDefaults.standard.data(forKey: recordingsKey),
           let loadedRecordings = try? JSONDecoder().decode([RegistryRecordingEntry].self, from: data) {
            recordings = loadedRecordings
        }
        
        // Then scan the documents directory for any audio files that aren't in the registry
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: [.creationDateKey], options: [])
            let audioFiles = fileURLs.filter { ["m4a", "mp3", "wav"].contains($0.pathExtension.lowercased()) }
            
            for url in audioFiles {
                // Check if this file is already in our registry
                if !recordings.contains(where: { $0.recordingURL == url }) {
                    // Add it to the registry
                    guard let creationDate = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate else { continue }
                    
                    let duration = getRecordingDuration(url: url)
                    let fileSize = getFileSize(url: url)
                    
                    let recording = RegistryRecordingEntry(
                        recordingURL: url,
                        recordingName: url.deletingPathExtension().lastPathComponent,
                        recordingDate: creationDate,
                        fileSize: fileSize,
                        duration: duration,
                        audioQuality: .whisperOptimized
                    )
                    
                    recordings.append(recording)
                }
            }
            
            // Remove any duplicate recordings
            removeDuplicateRecordings()
            
            // Save the updated recordings
            saveRecordings()
        } catch {
            print("Error scanning documents directory: \(error)")
        }
    }
    
    private func saveRecordings() {
        if let data = try? JSONEncoder().encode(recordings) {
            UserDefaults.standard.set(data, forKey: recordingsKey)
        }
    }
    
    private func loadTranscripts() {
        print("🔄 Loading transcripts...")
        
        // First load any saved transcripts from UserDefaults
        if let data = UserDefaults.standard.data(forKey: transcriptsKey),
           let loadedTranscripts = try? JSONDecoder().decode([TranscriptData].self, from: data) {
            transcripts = loadedTranscripts
            print("📥 Loaded \(loadedTranscripts.count) transcripts from UserDefaults")
        } else {
            print("📥 No transcripts found in UserDefaults")
        }
        
        // Then scan the documents directory for any transcript files that aren't in the registry
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: [.creationDateKey], options: [])
            let transcriptFiles = fileURLs.filter { $0.pathExtension.lowercased() == "transcript" }
            
            print("🔍 Found \(transcriptFiles.count) transcript files in documents directory")
            
            for transcriptURL in transcriptFiles {
                // Get the corresponding audio file URL
                let audioURL = transcriptURL.deletingPathExtension()
                let transcriptName = transcriptURL.deletingPathExtension().lastPathComponent
                
                print("🔍 Processing transcript: \(transcriptName)")
                
                // Check if we have a recording for this audio file
                if let recording = getRecording(url: audioURL) {
                    print("✅ Found matching recording: \(recording.recordingName)")
                    
                    // Check if we already have a transcript for this recording
                    if !transcripts.contains(where: { $0.recordingId == recording.id }) {
                        print("📝 Loading transcript for recording: \(recording.recordingName)")
                        
                        // Try to load the transcript data
                        if let transcriptData = loadTranscriptFromFile(transcriptURL, for: recording) {
                            transcripts.append(transcriptData)
                            
                            // Update the recording status
                            var updatedRecording = recording
                            updatedRecording.updateTranscript(id: transcriptData.id)
                            updateRecording(updatedRecording)
                            
                            print("✅ Successfully loaded transcript for: \(recording.recordingName)")
                        }
                    } else {
                        print("⚠️ Transcript already exists for recording: \(recording.recordingName)")
                    }
                } else {
                    print("❌ No matching recording found for transcript: \(transcriptName)")
                }
            }
            
            // Fix any transcripts with nil recordingId
            print("🔧 Calling fixTranscriptRecordingIds()...")
            fixTranscriptRecordingIds()
            
            // Clean up any duplicate transcripts
            removeDuplicateTranscripts()
            
            // Save the updated transcripts
            saveTranscripts()
            
            print("📊 Final transcript count: \(transcripts.count)")
        } catch {
            print("Error scanning for transcript files: \(error)")
        }
    }
    
    func clearAndReloadRegistry() {
        print("🧹 Clearing and reloading registry completely...")
        
        // Clear all data
        recordings.removeAll()
        transcripts.removeAll()
        enhancedSummaries.removeAll()
        
        // Clear UserDefaults
        UserDefaults.standard.removeObject(forKey: recordingsKey)
        UserDefaults.standard.removeObject(forKey: transcriptsKey)
        UserDefaults.standard.removeObject(forKey: enhancedSummariesKey)
        
        print("🧹 Cleared all registry data")
        
        // Reload from disk only
        loadRecordings()
        loadTranscripts()
        loadEnhancedSummaries()
        
        print("✅ Registry cleared and reloaded")
        print("📊 Current state:")
        print("   • Recordings: \(recordings.count)")
        print("   • Transcripts: \(transcripts.count)")
        print("   • Summaries: \(enhancedSummaries.count)")
    }
    
    func debugTranscriptLinking() {
        print("🔍 Debugging transcript linking...")
        
        for transcript in transcripts {
            print("📝 Transcript: \(transcript.recordingName)")
            print("   - ID: \(transcript.id)")
            print("   - Recording ID: \(transcript.recordingId?.uuidString ?? "nil")")
            print("   - Recording URL: \(transcript.recordingURL.lastPathComponent)")
            
            if let recordingId = transcript.recordingId {
                if let recording = getRecording(id: recordingId) {
                    print("   ✅ Linked to recording: \(recording.recordingName)")
                } else {
                    print("   ❌ Recording not found for ID: \(recordingId)")
                }
            } else {
                print("   ⚠️ No recording ID")
            }
        }
    }
    
    func recoverTranscriptsFromDisk() {
        print("🔧 Recovering transcripts from disk...")
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: [.creationDateKey], options: [])
            let transcriptFiles = fileURLs.filter { $0.pathExtension.lowercased() == "transcript" }
            
            print("🔍 Found \(transcriptFiles.count) transcript files on disk")
            
            for transcriptURL in transcriptFiles {
                let transcriptName = transcriptURL.deletingPathExtension().lastPathComponent
                print("🔍 Processing transcript file: \(transcriptName)")
                
                // Try to find a matching recording
                let audioURL = transcriptURL.deletingPathExtension()
                if let recording = getRecording(url: audioURL) {
                    print("✅ Found matching recording: \(recording.recordingName)")
                    
                    // Check if we already have this transcript in the registry
                    let alreadyExists = transcripts.contains { transcript in
                        transcript.recordingId == recording.id || transcript.recordingURL == recording.recordingURL
                    }
                    
                    if !alreadyExists {
                        print("📝 Loading transcript for recording: \(recording.recordingName)")
                        
                        // Try to load the transcript data
                        if let transcriptData = loadTranscriptFromFile(transcriptURL, for: recording) {
                            transcripts.append(transcriptData)
                            
                            // Update the recording status
                            var updatedRecording = recording
                            updatedRecording.updateTranscript(id: transcriptData.id)
                            updateRecording(updatedRecording)
                            
                            print("✅ Successfully recovered transcript for: \(recording.recordingName)")
                        } else {
                            print("❌ Failed to load transcript data from: \(transcriptURL.lastPathComponent)")
                        }
                    } else {
                        print("⚠️ Transcript already exists in registry for: \(recording.recordingName)")
                    }
                } else {
                    print("❌ No matching recording found for transcript: \(transcriptName)")
                    print("   - Audio URL: \(audioURL.lastPathComponent)")
                    
                    // Check if the audio file exists on disk
                    let audioFileExists = FileManager.default.fileExists(atPath: audioURL.path)
                    print("   - Audio file exists: \(audioFileExists)")
                    
                    // List all recordings to help debug
                    print("   - Available recordings:")
                    for (index, recording) in recordings.enumerated() {
                        print("     \(index): \(recording.recordingName) (\(recording.recordingURL.lastPathComponent))")
                    }
                }
            }
            
            // Save the updated transcripts
            saveTranscripts()
            
            print("📊 Final transcript count: \(transcripts.count)")
        } catch {
            print("❌ Error scanning for transcript files: \(error)")
        }
    }
    
    func cleanupDuplicateSummaries() {
        print("🧹 Cleaning up duplicate summaries...")
        
        var cleanedSummaries: [EnhancedSummaryData] = []
        var removedCount = 0
        var fixedCount = 0
        
        // Group summaries by recording ID
        let groupedSummaries = Dictionary(grouping: enhancedSummaries) { $0.recordingId }
        
        for (recordingId, summaries) in groupedSummaries {
            if summaries.count > 1 {
                print("📁 Found \(summaries.count) summaries for recording ID: \(recordingId?.uuidString ?? "nil")")
                
                // Keep only the most recent summary
                if let mostRecent = summaries.max(by: { $0.generatedAt < $1.generatedAt }) {
                    cleanedSummaries.append(mostRecent)
                    removedCount += summaries.count - 1
                    print("✅ Kept most recent summary (generated at: \(mostRecent.generatedAt))")
                }
            } else {
                // Single summary, keep it
                cleanedSummaries.append(contentsOf: summaries)
            }
        }
        
        // Fix summaries with nil recordingId by matching them to recordings
        for (index, summary) in cleanedSummaries.enumerated() {
            if summary.recordingId == nil {
                print("🔧 Found summary with nil recordingId: \(summary.recordingName)")
                
                // Try to find a matching recording by URL
                if let recording = getRecording(url: summary.recordingURL) {
                    print("✅ Found matching recording: \(recording.recordingName)")
                    
                    // Create a new summary with the correct recordingId
                    let fixedSummary = EnhancedSummaryData(
                        recordingId: recording.id,
                        transcriptId: summary.transcriptId,
                        recordingURL: summary.recordingURL,
                        recordingName: summary.recordingName,
                        recordingDate: summary.recordingDate,
                        summary: summary.summary,
                        tasks: summary.tasks,
                        reminders: summary.reminders,
                        titles: summary.titles,
                        contentType: summary.contentType,
                        aiMethod: summary.aiMethod,
                        originalLength: summary.originalLength,
                        processingTime: summary.processingTime
                    )
                    
                    cleanedSummaries[index] = fixedSummary
                    fixedCount += 1
                    print("✅ Fixed summary recordingId for: \(summary.recordingName)")
                } else {
                    print("❌ No matching recording found for summary: \(summary.recordingName)")
                }
            }
        }
        
        enhancedSummaries = cleanedSummaries
        saveEnhancedSummaries()
        
        print("✅ Cleanup complete. Removed \(removedCount) duplicate summaries and fixed \(fixedCount) summaries with nil recordingId.")
    }
    
    func fixSummariesWithNilRecordingId() {
        print("🔧 Fixing summaries with nil recordingId...")
        
        var fixedCount = 0
        
        for (index, summary) in enhancedSummaries.enumerated() {
            if summary.recordingId == nil {
                print("🔧 Found summary with nil recordingId: \(summary.recordingName)")
                
                // Try to find a matching recording by URL first
                if let recording = getRecording(url: summary.recordingURL) {
                    print("✅ Found matching recording by URL: \(recording.recordingName)")
                    
                    // Create a new summary with the correct recordingId
                    let fixedSummary = EnhancedSummaryData(
                        recordingId: recording.id,
                        transcriptId: summary.transcriptId,
                        recordingURL: summary.recordingURL,
                        recordingName: summary.recordingName,
                        recordingDate: summary.recordingDate,
                        summary: summary.summary,
                        tasks: summary.tasks,
                        reminders: summary.reminders,
                        titles: summary.titles,
                        contentType: summary.contentType,
                        aiMethod: summary.aiMethod,
                        originalLength: summary.originalLength,
                        processingTime: summary.processingTime
                    )
                    
                    enhancedSummaries[index] = fixedSummary
                    fixedCount += 1
                    print("✅ Fixed summary recordingId for: \(summary.recordingName)")
                } else {
                    // Try to find a matching recording by name
                    let matchingRecordings = recordings.filter { $0.recordingName == summary.recordingName }
                    if let recording = matchingRecordings.first {
                        print("✅ Found matching recording by name: \(recording.recordingName)")
                        
                        // Create a new summary with the correct recordingId
                        let fixedSummary = EnhancedSummaryData(
                            recordingId: recording.id,
                            transcriptId: summary.transcriptId,
                            recordingURL: recording.recordingURL, // Use the recording's URL
                            recordingName: summary.recordingName,
                            recordingDate: summary.recordingDate,
                            summary: summary.summary,
                            tasks: summary.tasks,
                            reminders: summary.reminders,
                            titles: summary.titles,
                            contentType: summary.contentType,
                            aiMethod: summary.aiMethod,
                            originalLength: summary.originalLength,
                            processingTime: summary.processingTime
                        )
                        
                        enhancedSummaries[index] = fixedSummary
                        fixedCount += 1
                        print("✅ Fixed summary recordingId for: \(summary.recordingName)")
                    } else {
                        print("❌ No matching recording found for summary: \(summary.recordingName)")
                        print("   - Available recordings:")
                        for recording in recordings {
                            print("     - \(recording.recordingName) (\(recording.recordingURL.lastPathComponent))")
                        }
                    }
                }
            }
        }
        
        if fixedCount > 0 {
            saveEnhancedSummaries()
            print("✅ Fixed \(fixedCount) summaries with nil recordingId.")
        } else {
            print("ℹ️ No summaries with nil recordingId found.")
        }
    }
    
    func linkSummariesToRecordings() {
        print("🔧 Linking summaries to recordings...")
        
        var linkedCount = 0
        
        for (index, summary) in enhancedSummaries.enumerated() {
            print("🔍 Processing summary: \(summary.recordingName)")
            print("   - Current recordingId: \(summary.recordingId?.uuidString ?? "nil")")
            
            // Try to find a matching recording by name
            let matchingRecordings = recordings.filter { $0.recordingName == summary.recordingName }
            
            if let recording = matchingRecordings.first {
                print("✅ Found matching recording: \(recording.recordingName)")
                print("   - Recording ID: \(recording.id)")
                
                // Create a new summary with the correct recordingId
                let linkedSummary = EnhancedSummaryData(
                    recordingId: recording.id,
                    transcriptId: summary.transcriptId,
                    recordingURL: recording.recordingURL,
                    recordingName: summary.recordingName,
                    recordingDate: summary.recordingDate,
                    summary: summary.summary,
                    tasks: summary.tasks,
                    reminders: summary.reminders,
                    titles: summary.titles,
                    contentType: summary.contentType,
                    aiMethod: summary.aiMethod,
                    originalLength: summary.originalLength,
                    processingTime: summary.processingTime
                )
                
                enhancedSummaries[index] = linkedSummary
                linkedCount += 1
                print("✅ Linked summary to recording: \(summary.recordingName)")
            } else {
                print("❌ No matching recording found for summary: \(summary.recordingName)")
                print("   - Available recordings:")
                for recording in recordings {
                    print("     - \(recording.recordingName)")
                }
            }
        }
        
        if linkedCount > 0 {
            saveEnhancedSummaries()
            print("✅ Linked \(linkedCount) summaries to recordings.")
        } else {
            print("ℹ️ No summaries needed linking.")
        }
    }
    
    func linkSummariesToRecordingsWithTranscripts() {
        print("🔧 Linking summaries to recordings that have transcripts...")
        
        var linkedCount = 0
        
        // Get recordings that have transcripts
        let recordingsWithTranscripts = recordings.filter { recording in
            transcripts.contains { transcript in
                transcript.recordingId == recording.id || transcript.recordingURL == recording.recordingURL
            }
        }
        
        print("📊 Found \(recordingsWithTranscripts.count) recordings with transcripts:")
        for recording in recordingsWithTranscripts {
            print("   - \(recording.recordingName)")
        }
        
        // Get summaries that don't have matching recordings with transcripts
        let orphanedSummaries = enhancedSummaries.filter { summary in
            !recordingsWithTranscripts.contains { recording in
                recording.id == summary.recordingId
            }
        }
        
        print("📊 Found \(orphanedSummaries.count) orphaned summaries:")
        for summary in orphanedSummaries {
            print("   - \(summary.recordingName) (recordingId: \(summary.recordingId?.uuidString ?? "nil"))")
        }
        
        // Link orphaned summaries to recordings with transcripts
        for (index, summary) in enhancedSummaries.enumerated() {
            // Check if this summary is orphaned (not linked to a recording with transcript)
            let isOrphaned = !recordingsWithTranscripts.contains { recording in
                recording.id == summary.recordingId
            }
            
            if isOrphaned {
                print("🔧 Found orphaned summary: \(summary.recordingName)")
                
                // Find a recording with transcript that doesn't have a summary
                let availableRecordings = recordingsWithTranscripts.filter { recording in
                    !enhancedSummaries.contains { summary in
                        summary.recordingId == recording.id
                    }
                }
                
                if let targetRecording = availableRecordings.first {
                    print("✅ Linking to recording with transcript: \(targetRecording.recordingName)")
                    
                    // Create a new summary with the correct recordingId
                    let linkedSummary = EnhancedSummaryData(
                        recordingId: targetRecording.id,
                        transcriptId: summary.transcriptId,
                        recordingURL: targetRecording.recordingURL,
                        recordingName: targetRecording.recordingName,
                        recordingDate: targetRecording.recordingDate,
                        summary: summary.summary,
                        tasks: summary.tasks,
                        reminders: summary.reminders,
                        titles: summary.titles,
                        contentType: summary.contentType,
                        aiMethod: summary.aiMethod,
                        originalLength: summary.originalLength,
                        processingTime: summary.processingTime
                    )
                    
                    enhancedSummaries[index] = linkedSummary
                    linkedCount += 1
                    print("✅ Linked summary to recording: \(targetRecording.recordingName)")
                } else {
                    print("❌ No available recording with transcript for summary: \(summary.recordingName)")
                }
            }
        }
        
        if linkedCount > 0 {
            saveEnhancedSummaries()
            print("✅ Linked \(linkedCount) summaries to recordings with transcripts.")
        } else {
            print("ℹ️ No summaries needed linking.")
        }
    }
    
    private func fixTranscriptRecordingIds() {
        print("🔧 Fixing transcripts with nil recordingId...")
        print("📊 Total transcripts to check: \(transcripts.count)")
        print("📊 Total recordings available: \(recordings.count)")
        
        var fixedCount = 0
        
        for (index, transcript) in transcripts.enumerated() {
            print("🔍 Checking transcript \(index): \(transcript.recordingName)")
            print("   - RecordingId: \(transcript.recordingId?.uuidString ?? "nil")")
            print("   - RecordingURL: \(transcript.recordingURL.lastPathComponent)")
            
            if transcript.recordingId == nil {
                print("🔧 Found transcript with nil recordingId: \(transcript.recordingName)")
                
                // Try to find a matching recording by URL
                if let matchingRecording = recordings.first(where: { $0.recordingURL.lastPathComponent == transcript.recordingURL.lastPathComponent }) {
                    print("✅ Found matching recording for transcript: \(transcript.recordingName)")
                    print("   - Recording ID: \(matchingRecording.id)")
                    print("   - Recording URL: \(matchingRecording.recordingURL.lastPathComponent)")
                    
                    // Update the transcript with the correct recording ID
                    var updatedTranscript = transcript
                    updatedTranscript.recordingId = matchingRecording.id
                    transcripts[index] = updatedTranscript
                    
                    // Update the recording status
                    var updatedRecording = matchingRecording
                    updatedRecording.updateTranscript(id: updatedTranscript.id)
                    updateRecording(updatedRecording)
                    
                    print("✅ Fixed transcript recordingId for: \(transcript.recordingName)")
                    fixedCount += 1
                } else {
                    print("❌ No matching recording found for transcript: \(transcript.recordingName)")
                    print("   - Available recording URLs:")
                    for recording in recordings {
                        print("     - \(recording.recordingURL.lastPathComponent)")
                    }
                }
            } else {
                print("✅ Transcript already has recordingId: \(transcript.recordingId?.uuidString ?? "nil")")
            }
        }
        
        print("🔧 Fixed \(fixedCount) transcripts with nil recordingId")
    }
    
    private func removeDuplicateTranscripts() {
        print("🧹 Starting duplicate transcript cleanup...")
        print("📊 Initial transcript count: \(transcripts.count)")
        
        var seenRecordingIds: Set<UUID> = []
        var seenRecordingURLs: Set<URL> = []
        var transcriptsToRemove: [Int] = []
        
        for (index, transcript) in transcripts.enumerated() {
            print("🔍 Checking transcript \(index): \(transcript.recordingName)")
            
            // Check for duplicate recording IDs
            if let recordingId = transcript.recordingId {
                if seenRecordingIds.contains(recordingId) {
                    print("🗑️ Removing duplicate transcript with recording ID: \(recordingId)")
                    transcriptsToRemove.append(index)
                    continue
                }
                seenRecordingIds.insert(recordingId)
                print("✅ Recording ID \(recordingId) is unique")
            }
            
            // Check for duplicate recording URLs
            if seenRecordingURLs.contains(transcript.recordingURL) {
                print("🗑️ Removing duplicate transcript with URL: \(transcript.recordingURL.lastPathComponent)")
                transcriptsToRemove.append(index)
                continue
            }
            seenRecordingURLs.insert(transcript.recordingURL)
            print("✅ Recording URL \(transcript.recordingURL.lastPathComponent) is unique")
        }
        
        // Remove duplicates in reverse order to maintain indices
        for index in transcriptsToRemove.sorted(by: >) {
            transcripts.remove(at: index)
        }
        
        if !transcriptsToRemove.isEmpty {
            print("🧹 Cleaned up \(transcriptsToRemove.count) duplicate transcripts")
        } else {
            print("✅ No duplicate transcripts found")
        }
        
        print("📊 Final transcript count after deduplication: \(transcripts.count)")
    }
    

    
    private func loadTranscriptFromFile(_ transcriptURL: URL, for recording: RegistryRecordingEntry) -> TranscriptData? {
        do {
            let transcriptText = try String(contentsOf: transcriptURL, encoding: .utf8)
            
            // Create a single segment from the plain text
            let segment = TranscriptSegment(
                speaker: "Speaker 1",
                text: transcriptText,
                startTime: 0,
                endTime: recording.duration
            )
            
            return TranscriptData(
                recordingId: recording.id,
                recordingURL: recording.recordingURL,
                recordingName: recording.recordingName,
                recordingDate: recording.recordingDate,
                segments: [segment],
                speakerMappings: [:],
                engine: nil,
                processingTime: 0,
                confidence: 1.0
            )
        } catch {
            print("Error loading transcript from file \(transcriptURL): \(error)")
            return nil
        }
    }
    
    private func saveTranscripts() {
        if let data = try? JSONEncoder().encode(transcripts) {
            UserDefaults.standard.set(data, forKey: transcriptsKey)
        }
    }
    
    private func loadEnhancedSummaries() {
        // First load any saved summaries from UserDefaults
        if let data = UserDefaults.standard.data(forKey: enhancedSummariesKey),
           let loadedSummaries = try? JSONDecoder().decode([EnhancedSummaryData].self, from: data) {
            enhancedSummaries = loadedSummaries
        }
        
        // Then scan the documents directory for any summary files that aren't in the registry
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: [.creationDateKey], options: [])
            let summaryFiles = fileURLs.filter { $0.pathExtension.lowercased() == "summary" }
            
            for summaryURL in summaryFiles {
                // Get the corresponding audio file URL
                let audioURL = summaryURL.deletingPathExtension()
                
                // Check if we have a recording for this audio file
                if let recording = getRecording(url: audioURL) {
                    // Check if we already have a summary for this recording
                    if !enhancedSummaries.contains(where: { $0.recordingId == recording.id }) {
                        // Try to load the summary data
                        if let summaryData = loadSummaryFromFile(summaryURL, for: recording) {
                            enhancedSummaries.append(summaryData)
                            
                            // Update the recording status
                            var updatedRecording = recording
                            updatedRecording.updateSummary(id: summaryData.id)
                            updateRecording(updatedRecording)
                        }
                    }
                }
            }
            
            // Save the updated summaries
            saveEnhancedSummaries()
        } catch {
            print("Error scanning for summary files: \(error)")
        }
    }
    
    private func loadSummaryFromFile(_ summaryURL: URL, for recording: RegistryRecordingEntry) -> EnhancedSummaryData? {
        do {
            let summaryText = try String(contentsOf: summaryURL, encoding: .utf8)
            
            return EnhancedSummaryData(
                recordingId: recording.id,
                transcriptId: nil,
                recordingURL: recording.recordingURL,
                recordingName: recording.recordingName,
                recordingDate: recording.recordingDate,
                summary: summaryText,
                tasks: [],
                reminders: [],
                titles: [],
                contentType: .general,
                aiMethod: "Legacy Import",
                originalLength: summaryText.count,
                processingTime: 0
            )
        } catch {
            print("Error loading summary from file \(summaryURL): \(error)")
            return nil
        }
    }
    
    private func saveEnhancedSummaries() {
        if let data = try? JSONEncoder().encode(enhancedSummaries) {
            UserDefaults.standard.set(data, forKey: enhancedSummariesKey)
        }
    }
    
    private func getRecordingDuration(url: URL) -> TimeInterval {
        let asset = AVURLAsset(url: url)
        
        // Use async loading for duration (required for iOS 16+)
        let semaphore = DispatchSemaphore(value: 0)
        var loadedDuration: TimeInterval = 0
        
        Task {
            do {
                let loadedDurationValue = try await asset.load(.duration)
                loadedDuration = CMTimeGetSeconds(loadedDurationValue)
            } catch {
                print("⚠️ Failed to load duration for \(url.lastPathComponent): \(error.localizedDescription)")
            }
            semaphore.signal()
        }
        
        // Wait for the async loading to complete (with timeout)
        _ = semaphore.wait(timeout: .now() + 2.0)
        
        return loadedDuration
    }
    
    private func getFileSize(url: URL) -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.size] as? Int64 ?? 0
        } catch {
            return 0
        }
    }
    
    // MARK: - Public Interface
    
    func refreshRecordingsFromDisk() {
        print("🔄 Refreshing recordings from disk...")
        
        // Get all audio files from documents directory
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: [.creationDateKey], options: [])
            let audioFiles = fileURLs.filter { ["m4a", "mp3", "wav"].contains($0.pathExtension.lowercased()) }
            
            print("🔍 Found \(audioFiles.count) audio files in documents directory")
            
            var addedCount = 0
            for url in audioFiles {
                // Check if this file is already in our registry
                if !recordings.contains(where: { $0.recordingURL.lastPathComponent == url.lastPathComponent }) {
                    print("📝 Adding missing recording: \(url.lastPathComponent)")
                    
                    // Add it to the registry
                    guard let creationDate = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate else { 
                        print("⚠️ Could not get creation date for \(url.lastPathComponent)")
                        continue 
                    }
                    
                    let duration = getRecordingDuration(url: url)
                    let fileSize = getFileSize(url: url)
                    
                    let recording = RegistryRecordingEntry(
                        recordingURL: url,
                        recordingName: url.deletingPathExtension().lastPathComponent,
                        recordingDate: creationDate,
                        fileSize: fileSize,
                        duration: duration,
                        audioQuality: .whisperOptimized
                    )
                    
                    recordings.append(recording)
                    addedCount += 1
                    print("✅ Added recording: \(recording.recordingName)")
                } else {
                    print("✅ Recording already exists: \(url.lastPathComponent)")
                }
            }
            
            if addedCount > 0 {
                // Remove any duplicate recordings
                removeDuplicateRecordings()
                
                // Save the updated recordings
                saveRecordings()
                print("📊 Added \(addedCount) new recordings to registry")
            } else {
                print("📊 No new recordings to add")
            }
            
        } catch {
            print("❌ Error scanning documents directory: \(error)")
        }
    }
}