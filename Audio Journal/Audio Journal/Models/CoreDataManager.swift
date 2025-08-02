//
//  CoreDataManager.swift
//  Audio Journal
//
//  Created by Kiro on 8/1/25.
//

import Foundation
import CoreData
import CoreLocation

/// Core Data manager that provides clean access to recordings, transcripts, and summaries
/// Replaces the legacy registry system with proper Core Data operations
@MainActor
class CoreDataManager: ObservableObject {
    private let persistenceController: PersistenceController
    private let context: NSManagedObjectContext
    
    init(persistenceController: PersistenceController = PersistenceController.shared) {
        self.persistenceController = persistenceController
        self.context = persistenceController.container.viewContext
    }
    
    // MARK: - Recording Operations
    
    func getAllRecordings() -> [RecordingEntry] {
        let fetchRequest: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \RecordingEntry.recordingDate, ascending: false)]
        
        do {
            return try context.fetch(fetchRequest)
        } catch {
            print("❌ Error fetching recordings: \(error)")
            return []
        }
    }
    
    // MARK: - Location Data Helpers
    
    func getLocationData(for recording: RecordingEntry) -> LocationData? {
        // Check if location data exists
        guard recording.locationLatitude != 0.0 || recording.locationLongitude != 0.0 else {
            return nil
        }
        
        // Create LocationData from Core Data fields
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: recording.locationLatitude,
                longitude: recording.locationLongitude
            ),
            altitude: 0,
            horizontalAccuracy: recording.locationAccuracy,
            verticalAccuracy: 0,
            timestamp: recording.locationTimestamp ?? Date()
        )
        
        var locationData = LocationData(location: location)
        
        // Override address if stored
        if let storedAddress = recording.locationAddress {
            // Create a new LocationData with the stored address
            locationData = LocationData(
                id: UUID(),
                latitude: recording.locationLatitude,
                longitude: recording.locationLongitude,
                timestamp: recording.locationTimestamp ?? Date(),
                accuracy: recording.locationAccuracy,
                address: storedAddress
            )
        }
        
        return locationData
    }
    
    func getRecording(id: UUID) -> RecordingEntry? {
        let fetchRequest: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        
        do {
            return try context.fetch(fetchRequest).first
        } catch {
            print("❌ Error fetching recording: \(error)")
            return nil
        }
    }
    
    func getRecording(url: URL) -> RecordingEntry? {
        print("🔍 DEBUG: getRecording(url:) called with: \(url)")
        print("🔍 DEBUG: URL absoluteString: \(url.absoluteString)")
        
        // Extract filename from URL
        let filename = url.lastPathComponent
        print("🔍 DEBUG: Filename: \(filename)")
        
        // First try exact URL match
        let fetchRequest: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "recordingURL == %@", url.absoluteString)
        
        do {
            let results = try context.fetch(fetchRequest)
            print("🔍 DEBUG: Found \(results.count) recordings with exact URL: \(url.absoluteString)")
            if !results.isEmpty {
                return results.first
            }
            
            // If no exact match, try matching by filename
            let filenameFetchRequest: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
            filenameFetchRequest.predicate = NSPredicate(format: "recordingURL ENDSWITH %@", filename)
            
            let filenameResults = try context.fetch(filenameFetchRequest)
            print("🔍 DEBUG: Found \(filenameResults.count) recordings with filename: \(filename)")
            
            if !filenameResults.isEmpty {
                let recording = filenameResults.first!
                // Update the URL if it doesn't match the actual file URL
                if recording.recordingURL != url.absoluteString {
                    print("🔄 Updating recording URL to match actual file location")
                    updateRecordingURL(recording: recording, newURL: url)
                }
                return recording
            }
            
            // If still no match, try to sync URLs and search again
            print("🔍 DEBUG: No matches found, attempting to sync URLs...")
            syncRecordingURLs()
            
            // Try filename match again after sync
            let retryResults = try context.fetch(filenameFetchRequest)
            print("🔍 DEBUG: After sync, found \(retryResults.count) recordings with filename: \(filename)")
            
            if !retryResults.isEmpty {
                let recording = retryResults.first!
                // Update the URL if it doesn't match the actual file URL
                if recording.recordingURL != url.absoluteString {
                    print("🔄 Updating recording URL to match actual file location (after sync)")
                    updateRecordingURL(recording: recording, newURL: url)
                }
                return recording
            }
            
            if retryResults.isEmpty {
                // Debug: List all recordings to see what URLs are stored
                let allRecordings = getAllRecordings()
                print("🔍 DEBUG: All recordings in Core Data:")
                for recording in allRecordings {
                    print("   - \(recording.recordingName ?? "unknown"): \(recording.recordingURL ?? "no URL")")
                }
            }
            
            return retryResults.first
        } catch {
            print("❌ Error fetching recording by URL: \(error)")
            return nil
        }
    }
    
    func getRecording(name: String) -> RecordingEntry? {
        let fetchRequest: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "recordingName == %@", name)
        
        do {
            return try context.fetch(fetchRequest).first
        } catch {
            print("❌ Error fetching recording by name: \(error)")
            return nil
        }
    }
    
    // MARK: - Transcript Operations
    
    func getTranscript(for recordingId: UUID) -> TranscriptEntry? {
        let fetchRequest: NSFetchRequest<TranscriptEntry> = TranscriptEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "recordingId == %@", recordingId as CVarArg)
        
        do {
            return try context.fetch(fetchRequest).first
        } catch {
            print("❌ Error fetching transcript: \(error)")
            return nil
        }
    }
    
    func getTranscriptData(for recordingId: UUID) -> TranscriptData? {
        guard let transcriptEntry = getTranscript(for: recordingId),
              let recordingEntry = getRecording(id: recordingId) else {
            return nil
        }
        
        return convertToTranscriptData(transcriptEntry: transcriptEntry, recordingEntry: recordingEntry)
    }
    
    func getAllTranscripts() -> [TranscriptEntry] {
        let fetchRequest: NSFetchRequest<TranscriptEntry> = TranscriptEntry.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \TranscriptEntry.createdAt, ascending: false)]
        
        do {
            return try context.fetch(fetchRequest)
        } catch {
            print("❌ Error fetching transcripts: \(error)")
            return []
        }
    }
    
    func deleteTranscript(id: UUID?) {
        guard let id = id else { return }
        
        let fetchRequest: NSFetchRequest<TranscriptEntry> = TranscriptEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        
        do {
            let transcripts = try context.fetch(fetchRequest)
            for transcript in transcripts {
                context.delete(transcript)
            }
            try? saveContext()
            print("✅ Deleted transcript with ID: \(id)")
        } catch {
            print("❌ Error deleting transcript: \(error)")
        }
    }
    
    // MARK: - Summary Operations
    
    func getSummary(for recordingId: UUID) -> SummaryEntry? {
        let fetchRequest: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "recordingId == %@", recordingId as CVarArg)
        
        do {
            return try context.fetch(fetchRequest).first
        } catch {
            print("❌ Error fetching summary: \(error)")
            return nil
        }
    }
    
    func getSummaryData(for recordingId: UUID) -> EnhancedSummaryData? {
        guard let summaryEntry = getSummary(for: recordingId),
              let recordingEntry = getRecording(id: recordingId) else {
            return nil
        }
        
        return convertToEnhancedSummaryData(summaryEntry: summaryEntry, recordingEntry: recordingEntry)
    }
    
    func getAllSummaries() -> [SummaryEntry] {
        let fetchRequest: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \SummaryEntry.generatedAt, ascending: false)]
        
        do {
            return try context.fetch(fetchRequest)
        } catch {
            print("❌ Error fetching summaries: \(error)")
            return []
        }
    }
    
    func deleteSummary(id: UUID?) {
        guard let id = id else { return }
        
        let fetchRequest: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        
        do {
            let summaries = try context.fetch(fetchRequest)
            for summary in summaries {
                context.delete(summary)
            }
            try? saveContext()
            print("✅ Deleted summary with ID: \(id)")
        } catch {
            print("❌ Error deleting summary: \(error)")
        }
    }
    
    // MARK: - Combined Operations
    
    func getCompleteRecordingData(id: UUID) -> (recording: RecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)? {
        guard let recording = getRecording(id: id) else {
            return nil
        }
        
        let transcript = getTranscriptData(for: id)
        let summary = getSummaryData(for: id)
        
        return (recording: recording, transcript: transcript, summary: summary)
    }
    
    func getAllRecordingsWithData() -> [(recording: RecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)] {
        let recordings = getAllRecordings()
        
        return recordings.map { recording in
            let transcript = recording.id.flatMap { getTranscriptData(for: $0) }
            let summary = recording.id.flatMap { getSummaryData(for: $0) }
            return (recording: recording, transcript: transcript, summary: summary)
        }
    }
    
    func getRecordingsWithTranscripts() -> [(recording: RecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)] {
        return getAllRecordingsWithData().filter { $0.transcript != nil }
    }
    
    // MARK: - Delete Operations
    
    func deleteRecording(id: UUID) {
        guard let recording = getRecording(id: id) else {
            print("❌ Recording not found for deletion: \(id)")
            return
        }
        
        // Core Data will handle cascade deletion of related transcript and summary
        context.delete(recording)
        
        do {
            try context.save()
            print("✅ Recording deleted: \(recording.recordingName ?? "unknown")")
        } catch {
            print("❌ Error deleting recording: \(error)")
        }
    }
    
    func saveContext() throws {
        try context.save()
    }
    
    // MARK: - Conversion Helpers
    
    private func convertToTranscriptData(transcriptEntry: TranscriptEntry, recordingEntry: RecordingEntry) -> TranscriptData? {
        guard let _ = transcriptEntry.id,
              let recordingId = recordingEntry.id,
              let recordingURL = recordingEntry.recordingURL,
              let url = URL(string: recordingURL) else {
            return nil
        }
        
        // Decode segments from JSON
        var segments: [TranscriptSegment] = []
        if let segmentsString = transcriptEntry.segments,
           let segmentsData = segmentsString.data(using: .utf8) {
            segments = (try? JSONDecoder().decode([TranscriptSegment].self, from: segmentsData)) ?? []
        }
        
        // Decode speaker mappings from JSON
        var speakerMappings: [String: String] = [:]
        if let speakerString = transcriptEntry.speakerMappings,
           let speakerData = speakerString.data(using: .utf8) {
            speakerMappings = (try? JSONDecoder().decode([String: String].self, from: speakerData)) ?? [:]
        }
        
        // Convert engine string to enum
        let engine = transcriptEntry.engine.flatMap { TranscriptionEngine(rawValue: $0) }
        
        return TranscriptData(
            id: transcriptEntry.id ?? UUID(),
            recordingId: recordingId,
            recordingURL: url,
            recordingName: recordingEntry.recordingName ?? "",
            recordingDate: recordingEntry.recordingDate ?? Date(),
            segments: segments,
            speakerMappings: speakerMappings,
            engine: engine,
            processingTime: transcriptEntry.processingTime,
            confidence: transcriptEntry.confidence,
            createdAt: transcriptEntry.createdAt,
            lastModified: transcriptEntry.lastModified
        )
    }
    
    private func convertToEnhancedSummaryData(summaryEntry: SummaryEntry, recordingEntry: RecordingEntry) -> EnhancedSummaryData? {
        guard let _ = summaryEntry.id,
              let recordingId = recordingEntry.id,
              let recordingURL = recordingEntry.recordingURL,
              let url = URL(string: recordingURL) else {
            return nil
        }
        
        // Decode structured data from JSON
        var titles: [TitleItem] = []
        if let titlesString = summaryEntry.titles,
           let titlesData = titlesString.data(using: .utf8) {
            titles = (try? JSONDecoder().decode([TitleItem].self, from: titlesData)) ?? []
        }
        
        var tasks: [TaskItem] = []
        if let tasksString = summaryEntry.tasks,
           let tasksData = tasksString.data(using: .utf8) {
            tasks = (try? JSONDecoder().decode([TaskItem].self, from: tasksData)) ?? []
        }
        
        var reminders: [ReminderItem] = []
        if let remindersString = summaryEntry.reminders,
           let remindersData = remindersString.data(using: .utf8) {
            reminders = (try? JSONDecoder().decode([ReminderItem].self, from: remindersData)) ?? []
        }
        
        // Convert content type string to enum
        let contentType = summaryEntry.contentType.flatMap { ContentType(rawValue: $0) } ?? .general
        
        return EnhancedSummaryData(
            id: summaryEntry.id ?? UUID(),
            recordingId: recordingId,
            transcriptId: summaryEntry.transcriptId,
            recordingURL: url,
            recordingName: recordingEntry.recordingName ?? "",
            recordingDate: recordingEntry.recordingDate ?? Date(),
            summary: summaryEntry.summary ?? "",
            tasks: tasks,
            reminders: reminders,
            titles: titles,
            contentType: contentType,
            aiMethod: summaryEntry.aiMethod ?? "",
            originalLength: Int(summaryEntry.originalLength),
            processingTime: summaryEntry.processingTime,
            generatedAt: summaryEntry.generatedAt,
            version: Int(summaryEntry.version),
            wordCount: Int(summaryEntry.wordCount),
            compressionRatio: summaryEntry.compressionRatio,
            confidence: summaryEntry.confidence
        )
    }
    
    // MARK: - Processing Job Operations
    
    func getAllProcessingJobs() -> [ProcessingJobEntry] {
        let fetchRequest: NSFetchRequest<ProcessingJobEntry> = ProcessingJobEntry.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \ProcessingJobEntry.startTime, ascending: false)]
        
        do {
            return try context.fetch(fetchRequest)
        } catch {
            print("❌ Error fetching processing jobs: \(error)")
            return []
        }
    }
    
    func getProcessingJob(id: UUID) -> ProcessingJobEntry? {
        let fetchRequest: NSFetchRequest<ProcessingJobEntry> = ProcessingJobEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        
        do {
            return try context.fetch(fetchRequest).first
        } catch {
            print("❌ Error fetching processing job: \(error)")
            return nil
        }
    }
    
    func getActiveProcessingJobs() -> [ProcessingJobEntry] {
        let fetchRequest: NSFetchRequest<ProcessingJobEntry> = ProcessingJobEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "status IN %@", ["queued", "processing"])
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \ProcessingJobEntry.startTime, ascending: true)]
        
        do {
            return try context.fetch(fetchRequest)
        } catch {
            print("❌ Error fetching active processing jobs: \(error)")
            return []
        }
    }
    
    func createProcessingJob(
        id: UUID,
        jobType: String,
        engine: String,
        recordingURL: URL,
        recordingName: String
    ) -> ProcessingJobEntry {
        let job = ProcessingJobEntry(context: context)
        job.id = id
        job.jobType = jobType
        job.engine = engine
        job.recordingURL = recordingURL.absoluteString
        job.recordingName = recordingName
        job.status = "queued"
        job.progress = 0.0
        job.startTime = Date()
        job.completionTime = nil
        job.error = nil
        
        // Link to recording if it exists
        if let recording = getRecording(url: recordingURL) {
            job.recording = recording
        }
        
        do {
            try saveContext()
            print("✅ Created processing job: \(recordingName)")
        } catch {
            print("❌ Error saving processing job: \(error)")
        }
        return job
    }
    
    func updateProcessingJob(_ job: ProcessingJobEntry) {
        job.lastModified = Date()
        try? saveContext()
    }
    
    func deleteProcessingJob(_ job: ProcessingJobEntry) {
        context.delete(job)
        try? saveContext()
        print("✅ Deleted processing job: \(job.recordingName ?? "unknown")")
    }
    
    func deleteCompletedProcessingJobs() {
        let fetchRequest: NSFetchRequest<ProcessingJobEntry> = ProcessingJobEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "status IN %@", ["completed", "failed"])
        
        do {
            let completedJobs = try context.fetch(fetchRequest)
            for job in completedJobs {
                context.delete(job)
            }
            try? saveContext()
            print("✅ Deleted \(completedJobs.count) completed processing jobs")
        } catch {
            print("❌ Error deleting completed processing jobs: \(error)")
        }
    }
    
    // MARK: - Debug Operations
    
    func debugDatabaseContents() {
        let recordings = getAllRecordings()
        print("📊 Core Data contains \(recordings.count) recordings:")
        
        for recording in recordings {
            print("  - \(recording.recordingName ?? "unknown") (ID: \(recording.id?.uuidString ?? "nil"))")
            print("    Has transcript: \(recording.transcript != nil)")
            print("    Has summary: \(recording.summary != nil)")
            print("    Transcription status: \(recording.transcriptionStatus ?? "unknown")")
            print("    Summary status: \(recording.summaryStatus ?? "unknown")")
            
            // Show location data if available
            if let locationData = getLocationData(for: recording) {
                print("    Location: \(locationData.displayLocation)")
            } else {
                print("    Location: None")
            }
        }
    }
    
    // MARK: - URL Synchronization
    
    /// Syncs Core Data recording URLs with actual files on disk
    func syncRecordingURLs() {
        print("🔄 Starting URL synchronization...")
        
        let allRecordings = getAllRecordings()
        var updatedCount = 0
        
        for recording in allRecordings {
            guard let urlString = recording.recordingURL,
                  let oldURL = URL(string: urlString) else { continue }
            
            // Check if the file exists at the stored URL
            if !FileManager.default.fileExists(atPath: oldURL.path) {
                // File doesn't exist at stored URL, try to find it by name
                let filename = oldURL.lastPathComponent
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                
                // Look for the file with the same name in documents directory
                do {
                    let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: nil, options: [])
                    let matchingFiles = fileURLs.filter { $0.lastPathComponent == filename }
                    
                    if let newURL = matchingFiles.first {
                        // Update the Core Data entry with the correct URL
                        recording.recordingURL = newURL.absoluteString
                        recording.lastModified = Date()
                        updatedCount += 1
                        print("✅ Updated URL for \(recording.recordingName ?? "unknown"): \(oldURL.lastPathComponent) → \(newURL.lastPathComponent)")
                    } else {
                        // If no exact filename match, try to find by recording name
                        // This handles cases where the file was renamed but Core Data still has old name
                        let recordingName = recording.recordingName ?? ""
                        if !recordingName.isEmpty {
                            let matchingFilesByName = fileURLs.filter { url in
                                let fileName = url.deletingPathExtension().lastPathComponent
                                return fileName == recordingName
                            }
                            
                            if let newURL = matchingFilesByName.first {
                                // Update the Core Data entry with the correct URL
                                recording.recordingURL = newURL.absoluteString
                                recording.lastModified = Date()
                                updatedCount += 1
                                print("✅ Updated URL by name match for \(recording.recordingName ?? "unknown"): \(oldURL.lastPathComponent) → \(newURL.lastPathComponent)")
                            } else {
                                print("⚠️ Could not find file for recording: \(recording.recordingName ?? "unknown")")
                                print("   - Expected filename: \(filename)")
                                print("   - Recording name: \(recordingName)")
                                print("   - Available files: \(fileURLs.map { $0.lastPathComponent })")
                            }
                        } else {
                            print("⚠️ Could not find file for recording: \(recording.recordingName ?? "unknown")")
                        }
                    }
                } catch {
                    print("❌ Error scanning documents directory: \(error)")
                }
            }
        }
        
        // Save changes if any updates were made
        if updatedCount > 0 {
            do {
                try context.save()
                print("✅ Saved \(updatedCount) URL updates to Core Data")
            } catch {
                print("❌ Failed to save URL updates: \(error)")
            }
        } else {
            print("ℹ️ No URL updates needed")
        }
    }
    
    /// Updates a recording's URL when it's found by filename but the URL is outdated
    func updateRecordingURL(recording: RecordingEntry, newURL: URL) {
        recording.recordingURL = newURL.absoluteString
        recording.lastModified = Date()
        
        do {
            try context.save()
            print("✅ Updated recording URL: \(recording.recordingName ?? "unknown") → \(newURL.lastPathComponent)")
        } catch {
            print("❌ Failed to save URL update: \(error)")
        }
    }
}