import Foundation
import CloudKit
import SwiftUI

// MARK: - Unified iCloud Sync Manager
// Handles CloudKit sync for the new unified data structure

@MainActor
class UnifiediCloudSyncManager: ObservableObject {
    
    @Published var isEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "unifiedICloudSyncEnabled")
            if isEnabled {
                Task { await enableSync() }
            } else {
                Task { await disableSync() }
            }
        }
    }
    
    @Published var syncStatus: SyncStatus = .idle
    @Published var lastSyncDate: Date?
    @Published var networkStatus: NetworkStatus = .available
    
    private let registryManager: RecordingRegistryManager
    private var container: CKContainer?
    private var database: CKDatabase?
    private let deviceIdentifier: String
    private var isInitialized = false
    
    // CloudKit Record Types
    private struct RecordTypes {
        static let recording = "CD_RecordingEntry"
        static let transcript = "CD_TranscriptEntry" 
        static let summary = "CD_SummaryEntry"
    }
    
    init(registryManager: RecordingRegistryManager) {
        self.registryManager = registryManager
        self.deviceIdentifier = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        self.isEnabled = UserDefaults.standard.bool(forKey: "unifiedICloudSyncEnabled")
        
        if let lastSyncTimestamp = UserDefaults.standard.object(forKey: "lastUnifiedSyncDate") as? Date {
            self.lastSyncDate = lastSyncTimestamp
        }
        
        Task { await initializeCloudKit() }
    }
    
    private func initializeCloudKit() async {
        guard !isInitialized else { return }
        
        // Skip in preview environments
        let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        if isPreview { return }
        
        self.container = CKContainer.default()
        self.database = container?.privateCloudDatabase
        
        guard container != nil, database != nil else {
            await updateSyncStatus(.failed("CloudKit initialization failed"))
            return
        }
        
        isInitialized = true
        print("✅ Unified CloudKit initialized")
    }
    
    // MARK: - Sync Operations
    
    func enableSync() async {
        guard let container = container else {
            await updateSyncStatus(.failed("CloudKit not initialized"))
            return
        }
        
        do {
            let accountStatus = try await container.accountStatus()
            guard accountStatus == .available else {
                await updateSyncStatus(.failed("iCloud account not available"))
                return
            }
            
            await updateSyncStatus(.completed)
            print("✅ Unified iCloud sync enabled")
            
        } catch {
            await updateSyncStatus(.failed(error.localizedDescription))
            await MainActor.run { self.isEnabled = false }
        }
    }
    
    func disableSync() async {
        await updateSyncStatus(.idle)
        print("✅ Unified iCloud sync disabled")
    }
    
    func syncAllData() async throws {
        guard isEnabled, let _ = database else { return }
        
        await updateSyncStatus(.syncing)
        
        do {
            // Sync recordings first (they're the foundation)
            try await syncRecordings()
            
            // Then sync transcripts and summaries
            try await syncTranscripts()
            try await syncSummaries()
            
            await updateSyncStatus(.completed)
            await MainActor.run {
                self.lastSyncDate = Date()
                UserDefaults.standard.set(self.lastSyncDate, forKey: "lastUnifiedSyncDate")
            }
            
            print("✅ All data synced successfully")
            
        } catch {
            await updateSyncStatus(.failed(error.localizedDescription))
            throw error
        }
    }
    
    private func syncRecordings() async throws {
        guard let database = database else { return }
        
        for recording in registryManager.recordings {
            let record = createRecordingRecord(from: recording)
            _ = try await database.save(record)
        }
        
        print("✅ Synced \(registryManager.recordings.count) recordings")
    }
    
    private func syncTranscripts() async throws {
        guard let database = database else { return }
        
        for transcript in registryManager.transcripts {
            let record = createTranscriptRecord(from: transcript)
            _ = try await database.save(record)
        }
        
        print("✅ Synced \(registryManager.transcripts.count) transcripts")
    }
    
    private func syncSummaries() async throws {
        guard let database = database else { return }
        
        for summary in registryManager.enhancedSummaries {
            let record = createSummaryRecord(from: summary)
            _ = try await database.save(record)
        }
        
        print("✅ Synced \(registryManager.enhancedSummaries.count) summaries")
    }
    
    // MARK: - CloudKit Record Creation
    
    private func createRecordingRecord(from recording: RegistryRecordingEntry) -> CKRecord {
        let recordID = CKRecord.ID(recordName: recording.id.uuidString)
        let record = CKRecord(recordType: RecordTypes.recording, recordID: recordID)
        
        record["recordingURL"] = recording.recordingURL.absoluteString
        record["recordingName"] = recording.recordingName
        record["recordingDate"] = recording.recordingDate
        record["createdAt"] = recording.createdAt
        record["lastModified"] = recording.lastModified
        record["fileSize"] = recording.fileSize
        record["duration"] = recording.duration
        record["audioQuality"] = recording.audioQuality.rawValue
        record["transcriptionStatus"] = recording.transcriptionStatus.rawValue
        record["summaryStatus"] = recording.summaryStatus.rawValue
        record["transcriptId"] = recording.transcriptId?.uuidString
        record["summaryId"] = recording.summaryId?.uuidString
        record["deviceIdentifier"] = deviceIdentifier
        
        return record
    }
    
    private func createTranscriptRecord(from transcript: TranscriptData) -> CKRecord {
        let recordID = CKRecord.ID(recordName: transcript.id.uuidString)
        let record = CKRecord(recordType: RecordTypes.transcript, recordID: recordID)
        
        record["recordingId"] = transcript.recordingId?.uuidString
        record["engine"] = transcript.engine?.rawValue
        record["createdAt"] = transcript.createdAt
        record["lastModified"] = transcript.lastModified
        record["processingTime"] = transcript.processingTime
        record["confidence"] = transcript.confidence
        record["deviceIdentifier"] = deviceIdentifier
        
        // Encode complex data as JSON strings
        if let segmentsData = try? JSONEncoder().encode(transcript.segments),
           let segmentsString = String(data: segmentsData, encoding: .utf8) {
            record["segments"] = segmentsString
        }
        
        if let mappingsData = try? JSONEncoder().encode(transcript.speakerMappings),
           let mappingsString = String(data: mappingsData, encoding: .utf8) {
            record["speakerMappings"] = mappingsString
        }
        
        return record
    }
    
    private func createSummaryRecord(from summary: EnhancedSummaryData) -> CKRecord {
        let recordID = CKRecord.ID(recordName: summary.id.uuidString)
        let record = CKRecord(recordType: RecordTypes.summary, recordID: recordID)
        
        record["recordingId"] = summary.recordingId?.uuidString
        record["transcriptId"] = summary.transcriptId?.uuidString
        record["summary"] = summary.summary
        record["contentType"] = summary.contentType.rawValue
        record["aiMethod"] = summary.aiModel
        record["generatedAt"] = summary.generatedAt
        record["version"] = summary.version
        record["wordCount"] = summary.wordCount
        record["originalLength"] = summary.originalLength
        record["compressionRatio"] = summary.compressionRatio
        record["confidence"] = summary.confidence
        record["processingTime"] = summary.processingTime
        record["deviceIdentifier"] = deviceIdentifier
        
        // Encode complex data as JSON strings
        if let tasksData = try? JSONEncoder().encode(summary.tasks),
           let tasksString = String(data: tasksData, encoding: .utf8) {
            record["tasks"] = tasksString
        }
        
        if let remindersData = try? JSONEncoder().encode(summary.reminders),
           let remindersString = String(data: remindersData, encoding: .utf8) {
            record["reminders"] = remindersString
        }
        
        if let titlesData = try? JSONEncoder().encode(summary.titles),
           let titlesString = String(data: titlesData, encoding: .utf8) {
            record["titles"] = titlesString
        }
        
        return record
    }
    
    // MARK: - Data Fetching
    
    func fetchAllDataFromCloud() async throws {
        guard isEnabled, let _ = database else { return }
        
        await updateSyncStatus(.syncing)
        
        do {
            // Fetch recordings first
            let recordings = try await fetchRecordingsFromCloud()
            
            // Fetch transcripts and summaries
            let transcripts = try await fetchTranscriptsFromCloud()
            let summaries = try await fetchSummariesFromCloud()
            
            // Update local registry
            await updateLocalRegistry(recordings: recordings, transcripts: transcripts, summaries: summaries)
            
            await updateSyncStatus(.completed)
            print("✅ Fetched all data from cloud")
            
        } catch {
            await updateSyncStatus(.failed(error.localizedDescription))
            throw error
        }
    }
    
    private func fetchRecordingsFromCloud() async throws -> [RegistryRecordingEntry] {
        guard let database = database else { return [] }
        
        let query = CKQuery(recordType: RecordTypes.recording, predicate: NSPredicate(value: true))
        let (matchResults, _) = try await database.records(matching: query)
        
        var recordings: [RegistryRecordingEntry] = []
        
        for (_, result) in matchResults {
            switch result {
            case .success(let record):
                if let recording = createRecordingEntry(from: record) {
                    recordings.append(recording)
                }
            case .failure(let error):
                print("❌ Failed to process recording record: \(error)")
            }
        }
        
        return recordings
    }
    
    private func fetchTranscriptsFromCloud() async throws -> [TranscriptData] {
        guard let database = database else { return [] }
        
        let query = CKQuery(recordType: RecordTypes.transcript, predicate: NSPredicate(value: true))
        let (matchResults, _) = try await database.records(matching: query)
        
        var transcripts: [TranscriptData] = []
        
        for (_, result) in matchResults {
            switch result {
            case .success(let record):
                if let transcript = createTranscriptData(from: record) {
                    transcripts.append(transcript)
                }
            case .failure(let error):
                print("❌ Failed to process transcript record: \(error)")
            }
        }
        
        return transcripts
    }
    
    private func fetchSummariesFromCloud() async throws -> [EnhancedSummaryData] {
        guard let database = database else { return [] }
        
        let query = CKQuery(recordType: RecordTypes.summary, predicate: NSPredicate(value: true))
        let (matchResults, _) = try await database.records(matching: query)
        
        var summaries: [EnhancedSummaryData] = []
        
        for (_, result) in matchResults {
            switch result {
            case .success(let record):
                if let summary = createSummaryData(from: record) {
                    summaries.append(summary)
                }
            case .failure(let error):
                print("❌ Failed to process summary record: \(error)")
            }
        }
        
        return summaries
    }
    
    // MARK: - Record to Data Conversion
    
    private func createRecordingEntry(from record: CKRecord) -> RegistryRecordingEntry? {
        guard let urlString = record["recordingURL"] as? String,
              let url = URL(string: urlString),
              let name = record["recordingName"] as? String,
              let date = record["recordingDate"] as? Date,
              let _ = record["createdAt"] as? Date,
              let lastModified = record["lastModified"] as? Date,
              let fileSize = record["fileSize"] as? Int64,
              let duration = record["duration"] as? TimeInterval,
              let qualityString = record["audioQuality"] as? String,
              let quality = AudioQuality(rawValue: qualityString),
              let transcriptionStatusString = record["transcriptionStatus"] as? String,
              let transcriptionStatus = ProcessingStatus(rawValue: transcriptionStatusString),
              let summaryStatusString = record["summaryStatus"] as? String,
              let summaryStatus = ProcessingStatus(rawValue: summaryStatusString) else {
            return nil
        }
        
        var entry = RegistryRecordingEntry(
            recordingURL: url,
            recordingName: name,
            recordingDate: date,
            fileSize: fileSize,
            duration: duration,
            audioQuality: quality
        )
        
        // Update with cloud data
        entry.lastModified = lastModified
        entry.transcriptionStatus = transcriptionStatus
        entry.summaryStatus = summaryStatus
        
        if let transcriptIdString = record["transcriptId"] as? String {
            entry.transcriptId = UUID(uuidString: transcriptIdString)
        }
        
        if let summaryIdString = record["summaryId"] as? String {
            entry.summaryId = UUID(uuidString: summaryIdString)
        }
        
        return entry
    }
    
    private func createTranscriptData(from record: CKRecord) -> TranscriptData? {
        guard let recordingIdString = record["recordingId"] as? String,
              let recordingId = UUID(uuidString: recordingIdString),
              let engineString = record["engine"] as? String,
              let engine = TranscriptionEngine(rawValue: engineString),
              let _ = record["createdAt"] as? Date,
              let _ = record["lastModified"] as? Date,
              let processingTime = record["processingTime"] as? TimeInterval,
              let confidence = record["confidence"] as? Double else {
            return nil
        }
        
        // Decode segments
        var segments: [TranscriptSegment] = []
        if let segmentsString = record["segments"] as? String,
           let segmentsData = segmentsString.data(using: .utf8) {
            segments = (try? JSONDecoder().decode([TranscriptSegment].self, from: segmentsData)) ?? []
        }
        
        // Decode speaker mappings
        var speakerMappings: [String: String] = [:]
        if let mappingsString = record["speakerMappings"] as? String,
           let mappingsData = mappingsString.data(using: .utf8) {
            speakerMappings = (try? JSONDecoder().decode([String: String].self, from: mappingsData)) ?? [:]
        }
        
        return TranscriptData(
            recordingId: recordingId,
            recordingURL: URL(string: "file://placeholder")!, // This should be the actual URL
            recordingName: "Imported Transcript",
            recordingDate: Date(),
            segments: segments,
            speakerMappings: speakerMappings,
            engine: engine,
            processingTime: processingTime,
            confidence: confidence
        )
    }
    
    private func createSummaryData(from record: CKRecord) -> EnhancedSummaryData? {
        guard let recordingIdString = record["recordingId"] as? String,
              let recordingId = UUID(uuidString: recordingIdString),
              let summary = record["summary"] as? String,
              let contentTypeString = record["contentType"] as? String,
              let contentType = ContentType(rawValue: contentTypeString),
              let aiMethod = record["aiMethod"] as? String,
              let _ = record["generatedAt"] as? Date,
              let _ = record["version"] as? Int,
              let _ = record["wordCount"] as? Int,
              let originalLength = record["originalLength"] as? Int,
              let _ = record["compressionRatio"] as? Double,
              let _ = record["confidence"] as? Double,
              let processingTime = record["processingTime"] as? TimeInterval else {
            return nil
        }
        
        let transcriptId = (record["transcriptId"] as? String).flatMap { UUID(uuidString: $0) }
        
        // Decode tasks
        var tasks: [TaskItem] = []
        if let tasksString = record["tasks"] as? String,
           let tasksData = tasksString.data(using: .utf8) {
            tasks = (try? JSONDecoder().decode([TaskItem].self, from: tasksData)) ?? []
        }
        
        // Decode reminders
        var reminders: [ReminderItem] = []
        if let remindersString = record["reminders"] as? String,
           let remindersData = remindersString.data(using: .utf8) {
            reminders = (try? JSONDecoder().decode([ReminderItem].self, from: remindersData)) ?? []
        }
        
        // Decode titles
        var titles: [TitleItem] = []
        if let titlesString = record["titles"] as? String,
           let titlesData = titlesString.data(using: .utf8) {
            titles = (try? JSONDecoder().decode([TitleItem].self, from: titlesData)) ?? []
        }
        
        // Infer engine from method until we have a proper field in CloudKit
        let engine: String
        let methodLower = aiMethod.lowercased()
        if methodLower.contains("google") || methodLower.contains("gemini") {
            engine = "Google AI"
        } else if methodLower.contains("openai") || methodLower.contains("gpt") {
            engine = "OpenAI"
        } else if methodLower.contains("bedrock") || methodLower.contains("claude") || methodLower.contains("aws") {
            engine = "AWS Bedrock"
        } else if methodLower.contains("ollama") {
            engine = "Ollama"
        } else if methodLower.contains("apple") || methodLower.contains("intelligence") {
            engine = "Apple Intelligence"
        } else if methodLower.contains("device") || methodLower.contains("gemma") || methodLower.contains("phi") || methodLower.contains("qwen") || methodLower.contains("llama") || methodLower.contains("mistral") || methodLower.contains("olmo") {
            engine = "On Device LLM"
        } else {
            engine = "AI Assistant"
        }
        
        return EnhancedSummaryData(
            recordingId: recordingId,
            transcriptId: transcriptId,
            recordingURL: URL(string: "file://placeholder")!, // This should be the actual URL
            recordingName: "Imported Summary",
            recordingDate: Date(),
            summary: summary,
            tasks: tasks,
            reminders: reminders,
            titles: titles,
            contentType: contentType,
            aiEngine: engine,
            aiModel: aiMethod,
            originalLength: originalLength,
            processingTime: processingTime
        )
    }
    
    private func updateLocalRegistry(recordings: [RegistryRecordingEntry], transcripts: [TranscriptData], summaries: [EnhancedSummaryData]) async {
        // Update recordings
        for recording in recordings {
            if registryManager.getRecording(id: recording.id) == nil {
                registryManager.recordings.append(recording)
            }
        }
        
        // Update transcripts
        for transcript in transcripts {
            if !registryManager.transcripts.contains(where: { $0.id == transcript.id }) {
                registryManager.transcripts.append(transcript)
            }
        }
        
        // Update summaries
        for summary in summaries {
            if !registryManager.enhancedSummaries.contains(where: { $0.id == summary.id }) {
                registryManager.enhancedSummaries.append(summary)
            }
        }
        
        print("✅ Local registry updated with cloud data")
    }
    
    private func updateSyncStatus(_ status: SyncStatus) async {
        await MainActor.run {
            self.syncStatus = status
        }
    }
}