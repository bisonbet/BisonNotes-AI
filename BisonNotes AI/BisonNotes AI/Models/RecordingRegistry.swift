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
    case interrupted = "Interrupted"

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

    public var isResumable: Bool {
        return self == .interrupted
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
    
    // MARK: - iCloud Integration
    
    private let iCloudManager = iCloudStorageManager.shared
    
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
        AppLog.shared.fileManagement("getRecording(url:) called with: \(url.lastPathComponent)", level: .debug)
        let result = recordings.first { recording in
            let matches = recording.recordingURL.lastPathComponent == url.lastPathComponent
            return matches
        }
        AppLog.shared.fileManagement("getRecording(url:) result: \(result?.recordingName ?? "nil")", level: .debug)
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
        // Remove any existing summaries for the same recording to prevent duplicates
        if let recordingId = summary.recordingId {
            enhancedSummaries.removeAll { $0.recordingId == recordingId }
        }
        
        enhancedSummaries.append(summary)
        saveEnhancedSummaries()
        
        // Update recording status
        if let recordingId = summary.recordingId,
           let recording = getRecording(id: recordingId) {
            var updatedRecording = recording
            updatedRecording.updateSummary(id: summary.id)
            updateRecording(updatedRecording)
        }
    }
    
    func getSummary(for url: URL) -> EnhancedSummaryData? {
        guard let recording = getRecording(url: url) else { 
            return nil 
        }
        
        let matchingSummaries = enhancedSummaries.filter { $0.recordingId == recording.id }
        
        // Get the most recent summary for this recording (by generatedAt date)
        let summary = matchingSummaries.max { $0.generatedAt < $1.generatedAt }
        
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
            return nil 
        }
        
        let transcript = transcripts.first { $0.recordingId == id }
        let matchingSummaries = enhancedSummaries.filter { $0.recordingId == id }
        
        // Get the most recent summary for this recording (by generatedAt date)
        let summary = matchingSummaries.max { $0.generatedAt < $1.generatedAt }
        
        return (recording: recording, transcript: transcript, summary: summary)
    }
    
    func getAllRecordingsWithData() -> [(recording: RegistryRecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)] {
        let result = recordings.map { recording in
            let transcript = transcripts.first { $0.recordingId == recording.id }
            // Get the most recent summary for this recording (by generatedAt date)
            let summary = enhancedSummaries
                .filter { $0.recordingId == recording.id }
                .max { $0.generatedAt < $1.generatedAt }
            
            return (recording: recording, transcript: transcript, summary: summary)
        }
        
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
        AppLog.shared.fileManagement("RecordingRegistry: Setting engine to: \(engine)")
        AppLog.shared.fileManagement("Available engines: \(availableEngines.keys.joined(separator: ", "))", level: .debug)

        currentEngine = availableEngines[engine]

        if let currentEngine = currentEngine {
            AppLog.shared.fileManagement("Engine set successfully: \(currentEngine.name)")
        } else {
            AppLog.shared.fileManagement("Failed to set engine: \(engine)", level: .error)
            AppLog.shared.fileManagement("Available engines: \(availableEngines.keys.joined(separator: ", "))", level: .debug)
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
    
    func generateEnhancedSummary(from transcriptText: String, for url: URL, recordingName: String, recordingDate: Date) async throws -> EnhancedSummaryData {
        guard let engine = currentEngine else {
            throw SummarizationError.aiServiceUnavailable(service: "No engine available")
        }
        
        let recordingId = getRecording(url: url)?.id ?? UUID()
        
        // Use the engine's processComplete method
        let result = try await engine.processComplete(text: transcriptText)
        AppLog.shared.fileManagement("Titles: \(result.titles.count)", level: .debug)
        
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
            aiEngine: engine.engineType,
            aiModel: engine.metadataName,
            originalLength: transcriptText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count,
            processingTime: 0
        )
    }
    
    // MARK: - Data Repair Methods
    
    func forceReloadTranscripts() {
        AppLog.shared.fileManagement("Force reloading all transcripts...")

        // Clear existing transcripts
        transcripts.removeAll()

        // Reload from files
        loadTranscripts()

        AppLog.shared.fileManagement("Transcript reload complete. Total transcripts: \(transcripts.count)")
    }
    
    func updateRecordingDurations() {
        AppLog.shared.fileManagement("Updating recording durations...")

        var updatedCount = 0
        for (index, recording) in recordings.enumerated() {
            let actualDuration = getRecordingDuration(url: recording.recordingURL)
            if actualDuration > 0 && recording.duration == 0 {
                var updatedRecording = recording
                updatedRecording.duration = actualDuration
                recordings[index] = updatedRecording
                updatedCount += 1
                AppLog.shared.fileManagement("Updated duration for \(recording.recordingName): \(formatDuration(actualDuration))", level: .debug)
            }
        }

        AppLog.shared.fileManagement("Updated \(updatedCount) recording durations")
        saveRecordings()
    }
    
    func removeDuplicateRecordings() {
        AppLog.shared.fileManagement("Removing duplicate recordings...")

        let initialCount = recordings.count
        var seenURLs = Set<URL>()
        var seenNames = Set<String>()

        recordings = recordings.filter { recording in
            let urlExists = seenURLs.contains(recording.recordingURL)
            let nameExists = seenNames.contains(recording.recordingName)

            if urlExists || nameExists {
                AppLog.shared.fileManagement("Removing duplicate recording: \(recording.recordingName)", level: .debug)
                return false
            } else {
                seenURLs.insert(recording.recordingURL)
                seenNames.insert(recording.recordingName)
                return true
            }
        }

        let finalCount = recordings.count
        AppLog.shared.fileManagement("Removed \(initialCount - finalCount) duplicate recordings")
        AppLog.shared.fileManagement("Registry now contains \(finalCount) recordings", level: .debug)
        
        saveRecordings()
    }
    

    
    func loadTranscriptsFromDiskOnly() {
        AppLog.shared.fileManagement("Loading transcripts from disk only...")

        // Clear any existing transcripts
        transcripts.removeAll()

        // Scan the documents directory for transcript files
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: [.creationDateKey], options: [])
            let transcriptFiles = fileURLs.filter { $0.pathExtension.lowercased() == "transcript" }

            AppLog.shared.fileManagement("Found \(transcriptFiles.count) transcript files in documents directory", level: .debug)

            for transcriptURL in transcriptFiles {
                // Get the corresponding audio file URL
                let audioURL = transcriptURL.deletingPathExtension()
                let transcriptName = transcriptURL.deletingPathExtension().lastPathComponent

                AppLog.shared.fileManagement("Processing transcript: \(transcriptName)", level: .debug)

                // Check if we have a recording for this audio file
                if let recording = getRecording(url: audioURL) {
                    AppLog.shared.fileManagement("Found matching recording: \(recording.recordingName)", level: .debug)

                    // Try to load the transcript data
                    if let transcriptData = loadTranscriptFromFile(transcriptURL, for: recording) {
                        transcripts.append(transcriptData)

                        // Update the recording status
                        var updatedRecording = recording
                        updatedRecording.updateTranscript(id: transcriptData.id)
                        updateRecording(updatedRecording)

                        AppLog.shared.fileManagement("Successfully loaded transcript for: \(recording.recordingName)")
                    }
                } else {
                    AppLog.shared.fileManagement("No matching recording found for transcript: \(transcriptName)", level: .error)
                }
            }

            // Save the updated transcripts
            saveTranscripts()

            AppLog.shared.fileManagement("Final transcript count from disk: \(transcripts.count)", level: .debug)
        } catch {
            AppLog.shared.fileManagement("Error scanning for transcript files: \(error)", level: .error)
        }
    }
    
    func clearOrphanedTranscripts() {
        AppLog.shared.fileManagement("Clearing orphaned transcripts...")

        let initialCount = transcripts.count
        var orphanedTranscripts: [TranscriptData] = []

        for transcript in transcripts {
            // Check if the recording file actually exists on disk
            let fileExists = FileManager.default.fileExists(atPath: transcript.recordingURL.path)

            if !fileExists {
                AppLog.shared.fileManagement("Found orphaned transcript for non-existent recording: \(transcript.recordingURL.lastPathComponent)", level: .debug)
                orphanedTranscripts.append(transcript)
            }
        }

        // Remove orphaned transcripts
        for orphanedTranscript in orphanedTranscripts {
            transcripts.removeAll { $0.id == orphanedTranscript.id }
        }

        let removedCount = initialCount - transcripts.count
        AppLog.shared.fileManagement("Removed \(removedCount) orphaned transcripts")
        saveTranscripts()
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    func debugTranscriptStatus() {
        AppLog.shared.fileManagement("Transcript Debug Status:", level: .debug)
        AppLog.shared.fileManagement("Total transcripts: \(transcripts.count)", level: .debug)
        AppLog.shared.fileManagement("Total recordings: \(recordings.count)", level: .debug)

        for (index, transcript) in transcripts.enumerated() {
            AppLog.shared.fileManagement("Transcript \(index): ID=\(transcript.id), RecordingID=\(transcript.recordingId?.uuidString ?? "None"), File=\(transcript.recordingURL.lastPathComponent), Name=\(transcript.recordingName), Segments=\(transcript.segments.count)", level: .debug)
        }

        for (index, recording) in recordings.enumerated() {
            AppLog.shared.fileManagement("Recording \(index): ID=\(recording.id), File=\(recording.recordingURL.lastPathComponent), Name=\(recording.recordingName), HasTranscript=\(recording.hasTranscript), TranscriptID=\(recording.transcriptId?.uuidString ?? "None")", level: .debug)
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
        AppLog.shared.fileManagement("Initializing AI engines...")

        // Initialize available engines
        availableEngines["OpenAI"] = OpenAISummarizationEngine()
        availableEngines["Ollama"] = LocalLLMEngine()
        availableEngines["OpenAI API Compatible"] = OpenAICompatibleEngine()
        availableEngines["Google AI Studio"] = GoogleAIStudioEngine()
        availableEngines["Mistral AI"] = MistralAIEngine()
        availableEngines["On-Device AI"] = OnDeviceLLMEngine()

        AppLog.shared.fileManagement("Available engines: \(availableEngines.keys.joined(separator: ", "))")

        // Set default engine based on user's selection
        let selectedEngineName = UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? "On-Device AI"
        currentEngine = availableEngines[selectedEngineName] ?? availableEngines["On-Device AI"]

        if let engine = currentEngine {
            AppLog.shared.fileManagement("Current engine set to: \(engine.name)")
        } else {
            AppLog.shared.fileManagement("Failed to set current engine!", level: .error)
        }
    }
    
    func checkEngineStatus() {
        AppLog.shared.fileManagement("Engine Status Check:", level: .debug)
        AppLog.shared.fileManagement("Available engines: \(availableEngines.count)", level: .debug)
        AppLog.shared.fileManagement("Current engine: \(currentEngine?.name ?? "None")", level: .debug)
        AppLog.shared.fileManagement("Engine names: \(availableEngines.keys.joined(separator: ", "))", level: .debug)

        if let engine = currentEngine {
            AppLog.shared.fileManagement("Current engine is available: \(engine.name)")
        } else {
            AppLog.shared.fileManagement("No current engine available!", level: .error)
            AppLog.shared.fileManagement("Re-initializing engines...")
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
            AppLog.shared.fileManagement("Error scanning documents directory: \(error)", level: .error)
        }
    }
    
    private func saveRecordings() {
        if let data = try? JSONEncoder().encode(recordings) {
            UserDefaults.standard.set(data, forKey: recordingsKey)
        }
    }
    
    private func loadTranscripts() {
        AppLog.shared.fileManagement("Loading transcripts...")

        // First load any saved transcripts from UserDefaults
        if let data = UserDefaults.standard.data(forKey: transcriptsKey),
           let loadedTranscripts = try? JSONDecoder().decode([TranscriptData].self, from: data) {
            transcripts = loadedTranscripts
            AppLog.shared.fileManagement("Loaded \(loadedTranscripts.count) transcripts from UserDefaults", level: .debug)
        } else {
            AppLog.shared.fileManagement("No transcripts found in UserDefaults", level: .debug)
        }

        // Then scan the documents directory for any transcript files that aren't in the registry
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: [.creationDateKey], options: [])
            let transcriptFiles = fileURLs.filter { $0.pathExtension.lowercased() == "transcript" }

            AppLog.shared.fileManagement("Found \(transcriptFiles.count) transcript files in documents directory", level: .debug)

            for transcriptURL in transcriptFiles {
                // Get the corresponding audio file URL
                let audioURL = transcriptURL.deletingPathExtension()
                let transcriptName = transcriptURL.deletingPathExtension().lastPathComponent

                AppLog.shared.fileManagement("Processing transcript: \(transcriptName)", level: .debug)

                // Check if we have a recording for this audio file
                if let recording = getRecording(url: audioURL) {
                    AppLog.shared.fileManagement("Found matching recording: \(recording.recordingName)", level: .debug)

                    // Check if we already have a transcript for this recording
                    if !transcripts.contains(where: { $0.recordingId == recording.id }) {
                        AppLog.shared.fileManagement("Loading transcript for recording: \(recording.recordingName)", level: .debug)

                        // Try to load the transcript data
                        if let transcriptData = loadTranscriptFromFile(transcriptURL, for: recording) {
                            transcripts.append(transcriptData)

                            // Update the recording status
                            var updatedRecording = recording
                            updatedRecording.updateTranscript(id: transcriptData.id)
                            updateRecording(updatedRecording)

                            AppLog.shared.fileManagement("Successfully loaded transcript for: \(recording.recordingName)")
                        }
                    } else {
                        AppLog.shared.fileManagement("Transcript already exists for recording: \(recording.recordingName)", level: .debug)
                    }
                } else {
                    AppLog.shared.fileManagement("No matching recording found for transcript: \(transcriptName)", level: .error)
                }
            }

            // Fix any transcripts with nil recordingId
            AppLog.shared.fileManagement("Calling fixTranscriptRecordingIds()...", level: .debug)
            fixTranscriptRecordingIds()

            // Clean up any duplicate transcripts
            removeDuplicateTranscripts()

            // Save the updated transcripts
            saveTranscripts()

            AppLog.shared.fileManagement("Final transcript count: \(transcripts.count)", level: .debug)
        } catch {
            AppLog.shared.fileManagement("Error scanning for transcript files: \(error)", level: .error)
        }
    }
    
    func clearAndReloadRegistry() {
        AppLog.shared.fileManagement("Clearing and reloading registry completely...")

        // Clear all data
        recordings.removeAll()
        transcripts.removeAll()
        enhancedSummaries.removeAll()

        // Clear UserDefaults
        UserDefaults.standard.removeObject(forKey: recordingsKey)
        UserDefaults.standard.removeObject(forKey: transcriptsKey)
        UserDefaults.standard.removeObject(forKey: enhancedSummariesKey)

        AppLog.shared.fileManagement("Cleared all registry data")

        // Reload from disk only
        loadRecordings()
        loadTranscripts()
        loadEnhancedSummaries()

        AppLog.shared.fileManagement("Registry cleared and reloaded")
        AppLog.shared.fileManagement("Current state: Recordings=\(recordings.count), Transcripts=\(transcripts.count), Summaries=\(enhancedSummaries.count)", level: .debug)
    }
    
    func debugTranscriptLinking() {
        AppLog.shared.fileManagement("Debugging transcript linking...", level: .debug)

        for transcript in transcripts {
            AppLog.shared.fileManagement("Transcript: \(transcript.recordingName), ID=\(transcript.id), RecordingID=\(transcript.recordingId?.uuidString ?? "nil"), File=\(transcript.recordingURL.lastPathComponent)", level: .debug)

            if let recordingId = transcript.recordingId {
                if let recording = getRecording(id: recordingId) {
                    AppLog.shared.fileManagement("Linked to recording: \(recording.recordingName)", level: .debug)
                } else {
                    AppLog.shared.fileManagement("Recording not found for ID: \(recordingId)", level: .error)
                }
            } else {
                AppLog.shared.fileManagement("No recording ID for transcript: \(transcript.recordingName)", level: .debug)
            }
        }
    }
    
    func recoverTranscriptsFromDisk() {
        AppLog.shared.fileManagement("Recovering transcripts from disk...")

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: [.creationDateKey], options: [])
            let transcriptFiles = fileURLs.filter { $0.pathExtension.lowercased() == "transcript" }

            AppLog.shared.fileManagement("Found \(transcriptFiles.count) transcript files on disk", level: .debug)

            for transcriptURL in transcriptFiles {
                let transcriptName = transcriptURL.deletingPathExtension().lastPathComponent
                AppLog.shared.fileManagement("Processing transcript file: \(transcriptName)", level: .debug)

                // Try to find a matching recording
                let audioURL = transcriptURL.deletingPathExtension()
                if let recording = getRecording(url: audioURL) {
                    AppLog.shared.fileManagement("Found matching recording: \(recording.recordingName)", level: .debug)

                    // Check if we already have this transcript in the registry
                    let alreadyExists = transcripts.contains { transcript in
                        transcript.recordingId == recording.id || transcript.recordingURL == recording.recordingURL
                    }

                    if !alreadyExists {
                        AppLog.shared.fileManagement("Loading transcript for recording: \(recording.recordingName)", level: .debug)

                        // Try to load the transcript data
                        if let transcriptData = loadTranscriptFromFile(transcriptURL, for: recording) {
                            transcripts.append(transcriptData)

                            // Update the recording status
                            var updatedRecording = recording
                            updatedRecording.updateTranscript(id: transcriptData.id)
                            updateRecording(updatedRecording)

                            AppLog.shared.fileManagement("Successfully recovered transcript for: \(recording.recordingName)")
                        } else {
                            AppLog.shared.fileManagement("Failed to load transcript data from: \(transcriptURL.lastPathComponent)", level: .error)
                        }
                    } else {
                        AppLog.shared.fileManagement("Transcript already exists in registry for: \(recording.recordingName)", level: .debug)
                    }
                } else {
                    AppLog.shared.fileManagement("No matching recording found for transcript: \(transcriptName)", level: .error)
                    AppLog.shared.fileManagement("Audio file: \(audioURL.lastPathComponent), exists: \(FileManager.default.fileExists(atPath: audioURL.path))", level: .debug)
                    AppLog.shared.fileManagement("Available recordings: \(recordings.map { $0.recordingName }.joined(separator: ", "))", level: .debug)
                }
            }

            // Save the updated transcripts
            saveTranscripts()

            AppLog.shared.fileManagement("Final transcript count: \(transcripts.count)", level: .debug)
        } catch {
            AppLog.shared.fileManagement("Error scanning for transcript files: \(error)", level: .error)
        }
    }
    
    func cleanupDuplicateSummaries() {
        AppLog.shared.fileManagement("Cleaning up duplicate summaries...")

        var cleanedSummaries: [EnhancedSummaryData] = []
        var removedCount = 0
        var fixedCount = 0

        // Group summaries by recording ID
        let groupedSummaries = Dictionary(grouping: enhancedSummaries) { $0.recordingId }

        for (recordingId, summaries) in groupedSummaries {
            if summaries.count > 1 {
                AppLog.shared.fileManagement("Found \(summaries.count) summaries for recording ID: \(recordingId?.uuidString ?? "nil")", level: .debug)

                // Keep only the most recent summary
                if let mostRecent = summaries.max(by: { $0.generatedAt < $1.generatedAt }) {
                    cleanedSummaries.append(mostRecent)
                    removedCount += summaries.count - 1
                    AppLog.shared.fileManagement("Kept most recent summary (generated at: \(mostRecent.generatedAt))", level: .debug)
                }
            } else {
                // Single summary, keep it
                cleanedSummaries.append(contentsOf: summaries)
            }
        }

        // Fix summaries with nil recordingId by matching them to recordings
        for (index, summary) in cleanedSummaries.enumerated() {
            if summary.recordingId == nil {
                AppLog.shared.fileManagement("Found summary with nil recordingId: \(summary.recordingName)", level: .debug)

                // Try to find a matching recording by URL
                if let recording = getRecording(url: summary.recordingURL) {
                    AppLog.shared.fileManagement("Found matching recording: \(recording.recordingName)", level: .debug)
                    
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
                        aiEngine: summary.aiEngine,
            aiModel: summary.aiModel,
                        originalLength: summary.originalLength,
                        processingTime: summary.processingTime
                    )
                    
                    cleanedSummaries[index] = fixedSummary
                    fixedCount += 1
                    AppLog.shared.fileManagement("Fixed summary recordingId for: \(summary.recordingName)")
                } else {
                    AppLog.shared.fileManagement("No matching recording found for summary: \(summary.recordingName)", level: .error)
                }
            }
        }

        enhancedSummaries = cleanedSummaries
        saveEnhancedSummaries()

        AppLog.shared.fileManagement("Cleanup complete. Removed \(removedCount) duplicate summaries and fixed \(fixedCount) summaries with nil recordingId.")
    }
    
    func fixSummariesWithNilRecordingId() {
        AppLog.shared.fileManagement("Fixing summaries with nil recordingId...")

        var fixedCount = 0

        for (index, summary) in enhancedSummaries.enumerated() {
            if summary.recordingId == nil {
                AppLog.shared.fileManagement("Found summary with nil recordingId: \(summary.recordingName)", level: .debug)

                // Try to find a matching recording by URL first
                if let recording = getRecording(url: summary.recordingURL) {
                    AppLog.shared.fileManagement("Found matching recording by URL: \(recording.recordingName)", level: .debug)
                    
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
                        aiEngine: summary.aiEngine,
            aiModel: summary.aiModel,
                        originalLength: summary.originalLength,
                        processingTime: summary.processingTime
                    )
                    
                    enhancedSummaries[index] = fixedSummary
                    fixedCount += 1
                    AppLog.shared.fileManagement("Fixed summary recordingId for: \(summary.recordingName)")
                } else {
                    // Try to find a matching recording by name
                    let matchingRecordings = recordings.filter { $0.recordingName == summary.recordingName }
                    if let recording = matchingRecordings.first {
                        AppLog.shared.fileManagement("Found matching recording by name: \(recording.recordingName)", level: .debug)
                        
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
                            aiEngine: summary.aiEngine,
            aiModel: summary.aiModel,
                            originalLength: summary.originalLength,
                            processingTime: summary.processingTime
                        )
                        
                        enhancedSummaries[index] = fixedSummary
                        fixedCount += 1
                        AppLog.shared.fileManagement("Fixed summary recordingId for: \(summary.recordingName)")
                    } else {
                        AppLog.shared.fileManagement("No matching recording found for summary: \(summary.recordingName)", level: .error)
                        AppLog.shared.fileManagement("Available recordings: \(recordings.map { $0.recordingName }.joined(separator: ", "))", level: .debug)
                    }
                }
            }
        }

        if fixedCount > 0 {
            saveEnhancedSummaries()
            AppLog.shared.fileManagement("Fixed \(fixedCount) summaries with nil recordingId.")
        } else {
            AppLog.shared.fileManagement("No summaries with nil recordingId found.", level: .debug)
        }
    }
    
    func linkSummariesToRecordings() {
        AppLog.shared.fileManagement("Linking summaries to recordings...")

        var linkedCount = 0

        for (index, summary) in enhancedSummaries.enumerated() {
            AppLog.shared.fileManagement("Processing summary: \(summary.recordingName), recordingId=\(summary.recordingId?.uuidString ?? "nil")", level: .debug)

            // Try to find a matching recording by name
            let matchingRecordings = recordings.filter { $0.recordingName == summary.recordingName }

            if let recording = matchingRecordings.first {
                AppLog.shared.fileManagement("Found matching recording: \(recording.recordingName), ID=\(recording.id)", level: .debug)
                
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
                    aiEngine: summary.aiEngine,
            aiModel: summary.aiModel,
                    originalLength: summary.originalLength,
                    processingTime: summary.processingTime
                )
                
                enhancedSummaries[index] = linkedSummary
                linkedCount += 1
                AppLog.shared.fileManagement("Linked summary to recording: \(summary.recordingName)")
            } else {
                AppLog.shared.fileManagement("No matching recording found for summary: \(summary.recordingName)", level: .error)
                AppLog.shared.fileManagement("Available recordings: \(recordings.map { $0.recordingName }.joined(separator: ", "))", level: .debug)
            }
        }

        if linkedCount > 0 {
            saveEnhancedSummaries()
            AppLog.shared.fileManagement("Linked \(linkedCount) summaries to recordings.")
        } else {
            AppLog.shared.fileManagement("No summaries needed linking.", level: .debug)
        }
    }

    func linkSummariesToRecordingsWithTranscripts() {
        AppLog.shared.fileManagement("Linking summaries to recordings that have transcripts...")

        var linkedCount = 0

        // Get recordings that have transcripts
        let recordingsWithTranscripts = recordings.filter { recording in
            transcripts.contains { transcript in
                transcript.recordingId == recording.id || transcript.recordingURL == recording.recordingURL
            }
        }

        AppLog.shared.fileManagement("Found \(recordingsWithTranscripts.count) recordings with transcripts", level: .debug)
        for recording in recordingsWithTranscripts {
            AppLog.shared.fileManagement("Recording with transcript: \(recording.recordingName)", level: .debug)
        }

        // Get summaries that don't have matching recordings with transcripts
        let orphanedSummaries = enhancedSummaries.filter { summary in
            !recordingsWithTranscripts.contains { recording in
                recording.id == summary.recordingId
            }
        }

        AppLog.shared.fileManagement("Found \(orphanedSummaries.count) orphaned summaries", level: .debug)
        for summary in orphanedSummaries {
            AppLog.shared.fileManagement("Orphaned summary: \(summary.recordingName), recordingId=\(summary.recordingId?.uuidString ?? "nil")", level: .debug)
        }

        // Link orphaned summaries to recordings with transcripts
        for (index, summary) in enhancedSummaries.enumerated() {
            // Check if this summary is orphaned (not linked to a recording with transcript)
            let isOrphaned = !recordingsWithTranscripts.contains { recording in
                recording.id == summary.recordingId
            }

            if isOrphaned {
                AppLog.shared.fileManagement("Found orphaned summary: \(summary.recordingName)", level: .debug)

                // Find a recording with transcript that doesn't have a summary
                let availableRecordings = recordingsWithTranscripts.filter { recording in
                    !enhancedSummaries.contains { summary in
                        summary.recordingId == recording.id
                    }
                }

                if let targetRecording = availableRecordings.first {
                    AppLog.shared.fileManagement("Linking to recording with transcript: \(targetRecording.recordingName)", level: .debug)
                    
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
                        aiEngine: summary.aiEngine,
            aiModel: summary.aiModel,
                        originalLength: summary.originalLength,
                        processingTime: summary.processingTime
                    )
                    
                    enhancedSummaries[index] = linkedSummary
                    linkedCount += 1
                    AppLog.shared.fileManagement("Linked summary to recording: \(targetRecording.recordingName)")
                } else {
                    AppLog.shared.fileManagement("No available recording with transcript for summary: \(summary.recordingName)", level: .error)
                }
            }
        }

        if linkedCount > 0 {
            saveEnhancedSummaries()
            AppLog.shared.fileManagement("Linked \(linkedCount) summaries to recordings with transcripts.")
        } else {
            AppLog.shared.fileManagement("No summaries needed linking.", level: .debug)
        }
    }
    
    private func fixTranscriptRecordingIds() {
        AppLog.shared.fileManagement("Fixing transcripts with nil recordingId...")
        AppLog.shared.fileManagement("Total transcripts to check: \(transcripts.count), Total recordings available: \(recordings.count)", level: .debug)

        var fixedCount = 0

        for (index, transcript) in transcripts.enumerated() {
            AppLog.shared.fileManagement("Checking transcript \(index): \(transcript.recordingName), RecordingId=\(transcript.recordingId?.uuidString ?? "nil"), File=\(transcript.recordingURL.lastPathComponent)", level: .debug)

            if transcript.recordingId == nil {
                AppLog.shared.fileManagement("Found transcript with nil recordingId: \(transcript.recordingName)", level: .debug)

                // Try to find a matching recording by URL
                if let matchingRecording = recordings.first(where: { $0.recordingURL.lastPathComponent == transcript.recordingURL.lastPathComponent }) {
                    AppLog.shared.fileManagement("Found matching recording for transcript: \(transcript.recordingName), RecordingID=\(matchingRecording.id)", level: .debug)
                    
                    // Update the transcript with the correct recording ID
                    var updatedTranscript = transcript
                    updatedTranscript.recordingId = matchingRecording.id
                    transcripts[index] = updatedTranscript
                    
                    // Update the recording status
                    var updatedRecording = matchingRecording
                    updatedRecording.updateTranscript(id: updatedTranscript.id)
                    updateRecording(updatedRecording)
                    
                    AppLog.shared.fileManagement("Fixed transcript recordingId for: \(transcript.recordingName)")
                    fixedCount += 1
                } else {
                    AppLog.shared.fileManagement("No matching recording found for transcript: \(transcript.recordingName)", level: .error)
                    AppLog.shared.fileManagement("Available recording files: \(recordings.map { $0.recordingURL.lastPathComponent }.joined(separator: ", "))", level: .debug)
                }
            } else {
                AppLog.shared.fileManagement("Transcript already has recordingId: \(transcript.recordingId?.uuidString ?? "nil")", level: .debug)
            }
        }

        AppLog.shared.fileManagement("Fixed \(fixedCount) transcripts with nil recordingId")
    }
    
    private func removeDuplicateTranscripts() {
        AppLog.shared.fileManagement("Starting duplicate transcript cleanup...")
        AppLog.shared.fileManagement("Initial transcript count: \(transcripts.count)", level: .debug)

        var seenRecordingIds: Set<UUID> = []
        var seenRecordingURLs: Set<URL> = []
        var transcriptsToRemove: [Int] = []

        for (index, transcript) in transcripts.enumerated() {
            AppLog.shared.fileManagement("Checking transcript \(index): \(transcript.recordingName)", level: .debug)

            // Check for duplicate recording IDs
            if let recordingId = transcript.recordingId {
                if seenRecordingIds.contains(recordingId) {
                    AppLog.shared.fileManagement("Removing duplicate transcript with recording ID: \(recordingId)", level: .debug)
                    transcriptsToRemove.append(index)
                    continue
                }
                seenRecordingIds.insert(recordingId)
            }

            // Check for duplicate recording URLs
            if seenRecordingURLs.contains(transcript.recordingURL) {
                AppLog.shared.fileManagement("Removing duplicate transcript with file: \(transcript.recordingURL.lastPathComponent)", level: .debug)
                transcriptsToRemove.append(index)
                continue
            }
            seenRecordingURLs.insert(transcript.recordingURL)
        }

        // Remove duplicates in reverse order to maintain indices
        for index in transcriptsToRemove.sorted(by: >) {
            transcripts.remove(at: index)
        }

        if !transcriptsToRemove.isEmpty {
            AppLog.shared.fileManagement("Cleaned up \(transcriptsToRemove.count) duplicate transcripts")
        } else {
            AppLog.shared.fileManagement("No duplicate transcripts found", level: .debug)
        }

        AppLog.shared.fileManagement("Final transcript count after deduplication: \(transcripts.count)", level: .debug)
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
            AppLog.shared.fileManagement("Error loading transcript from file \(transcriptURL.lastPathComponent): \(error)", level: .error)
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
            AppLog.shared.fileManagement("Error scanning for summary files: \(error)", level: .error)
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
                aiEngine: "Local Processing",
                aiModel: "Legacy Import",
                originalLength: summaryText.count,
                processingTime: 0
            )
        } catch {
            AppLog.shared.fileManagement("Error loading summary from file \(summaryURL.lastPathComponent): \(error)", level: .error)
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
                AppLog.shared.fileManagement("Failed to load duration for \(url.lastPathComponent): \(error.localizedDescription)", level: .error)
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
        AppLog.shared.fileManagement("Refreshing recordings from disk...")

        // Get all audio files from documents directory
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: [.creationDateKey], options: [])
            let audioFiles = fileURLs.filter { ["m4a", "mp3", "wav"].contains($0.pathExtension.lowercased()) }

            AppLog.shared.fileManagement("Found \(audioFiles.count) audio files in documents directory", level: .debug)

            var addedCount = 0
            for url in audioFiles {
                // Check if this file is already in our registry
                if !recordings.contains(where: { $0.recordingURL.lastPathComponent == url.lastPathComponent }) {
                    AppLog.shared.fileManagement("Adding missing recording: \(url.lastPathComponent)", level: .debug)

                    // Add it to the registry
                    guard let creationDate = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate else {
                        AppLog.shared.fileManagement("Could not get creation date for \(url.lastPathComponent)", level: .error)
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
                    AppLog.shared.fileManagement("Added recording: \(recording.recordingName)", level: .debug)
                }
            }

            if addedCount > 0 {
                // Remove any duplicate recordings
                removeDuplicateRecordings()

                // Save the updated recordings
                saveRecordings()
                AppLog.shared.fileManagement("Added \(addedCount) new recordings to registry", level: .debug)
            } else {
                AppLog.shared.fileManagement("No new recordings to add", level: .debug)
            }

        } catch {
            AppLog.shared.fileManagement("Error scanning documents directory: \(error)", level: .error)
        }
    }
}
