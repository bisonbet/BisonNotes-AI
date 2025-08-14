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
    
    // MARK: - Context Management
    
    /// Refreshes all objects in the Core Data context to ensure fresh data
    func refreshContext() {
        context.refreshAllObjects()
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
    
    // MARK: - URL Management Helpers
    
    /// Migrates all existing absolute URL paths to relative paths for resilience
    func migrateURLsToRelativePaths() {
        let allRecordings = getAllRecordings()
        var updatedCount = 0
        
        // Only show migration progress if there's work to do
        let needsMigration = allRecordings.contains { recording in
            guard let urlString = recording.recordingURL,
                  let url = URL(string: urlString) else { return false }
            return url.scheme != nil
        }
        
        if needsMigration {
            print("🔄 Migrating absolute URLs to relative paths...")
        }
        
        for recording in allRecordings {
            guard let urlString = recording.recordingURL,
                  let url = URL(string: urlString),
                  url.scheme != nil else { continue } // Skip if already relative
            
            // Convert absolute URL to relative path
            if let relativePath = urlToRelativePath(url) {
                recording.recordingURL = relativePath
                recording.lastModified = Date()
                updatedCount += 1
            }
        }
        
        if updatedCount > 0 {
            do {
                try context.save()
                print("✅ Migrated \(updatedCount) URLs to relative paths")
            } catch {
                print("❌ Failed to save URL migrations: \(error)")
            }
        } else if needsMigration {
            print("ℹ️ No URLs needed migration")
        }
    }
    
    /// Converts an absolute URL to a relative path for storage
    func urlToRelativePath(_ url: URL) -> String? {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        
        // Check if URL is within documents directory
        let urlString = url.absoluteString
        let documentsString = documentsURL.absoluteString
        
        if urlString.hasPrefix(documentsString) {
            // Remove the documents path prefix to get relative path
            let relativePath = String(urlString.dropFirst(documentsString.count))
            return relativePath.isEmpty ? nil : relativePath
        }
        
        // If not in documents directory, store the filename only
        return url.lastPathComponent
    }
    
    /// Converts a relative path back to an absolute URL
    private func relativePathToURL(_ relativePath: String) -> URL? {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        
        // Decode URL-encoded characters (like %20 for spaces)
        let decodedPath = relativePath.removingPercentEncoding ?? relativePath
        
        // If it's just a filename, append directly to documents
        if !decodedPath.contains("/") {
            return documentsURL.appendingPathComponent(decodedPath)
        }
        
        // If it's a relative path, construct the full URL using appendingPathComponent
        // This is more reliable than URL(string:relativeTo:) for file paths
        return documentsURL.appendingPathComponent(decodedPath)
    }
    
    /// Gets the current absolute URL for a recording, handling container ID changes
    func getAbsoluteURL(for recording: RecordingEntry) -> URL? {
        guard let urlString = recording.recordingURL else { 
            // Don't log anything - orphaned records are cleaned up at app startup
            return nil 
        }
        
        // First, try to parse as absolute URL (legacy format)
        if let url = URL(string: urlString), url.scheme != nil {
            // This is an absolute URL, check if file exists
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            
            // File doesn't exist at absolute path, try to find by filename
            if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let filename = url.lastPathComponent
                let newURL = documentsURL.appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: newURL.path) {
                    // Update the stored URL to relative path for future resilience
                    recording.recordingURL = urlToRelativePath(newURL)
                    try? context.save()
                    return newURL
                }
            }
        } else {
            // This is a relative path, convert to absolute URL
            if let absoluteURL = relativePathToURL(urlString) {
                if FileManager.default.fileExists(atPath: absoluteURL.path) {
                    return absoluteURL
                }
                
                print("⚠️ File not found at relative path, trying filename search")
                // File doesn't exist, try to find by filename
                if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let filename = absoluteURL.lastPathComponent
                    let newURL = documentsURL.appendingPathComponent(filename)
                    print("🔍 Searching for file: \(newURL.path)")
                    if FileManager.default.fileExists(atPath: newURL.path) {
                        print("✅ File found by filename, updating stored path")
                        // Update the stored relative path
                        recording.recordingURL = urlToRelativePath(newURL)
                        try? context.save()
                        return newURL
                    }
                }
            } else {
                print("❌ Failed to convert relative path to absolute URL")
            }
        }
        
        print("❌ File not found anywhere for recording: \(recording.recordingName ?? "unknown")")
        return nil
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
        let filename = url.lastPathComponent
        
        // Get all recordings and check if any resolve to this URL
        let allRecordings = getAllRecordings()
        
        for recording in allRecordings {
            if let recordingURL = getAbsoluteURL(for: recording) {
                if recordingURL.path == url.path || recordingURL.lastPathComponent == filename {
                    return recording
                }
            }
        }
        
        // If no match found, try legacy URL matching for migration cases
        let fetchRequest: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "recordingURL ENDSWITH %@", filename)
        
        do {
            let results = try context.fetch(fetchRequest)
            if let recording = results.first {
                // Update to relative path format
                recording.recordingURL = urlToRelativePath(url)
                try? context.save()
                return recording
            }
        } catch {
            print("❌ Error fetching recording by URL: \(error)")
        }
        
        return nil
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
        // Sort by lastModified to get the most recent transcript
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \TranscriptEntry.lastModified, ascending: false)]
        
        do {
            let results = try context.fetch(fetchRequest)
            return results.first
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
    
    func deleteSummary(id: UUID?) throws {
        guard let id = id else { 
            print("❌ Cannot delete summary: ID is nil")
            return 
        }
        
        let fetchRequest: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        
        do {
            let summaries = try context.fetch(fetchRequest)
            if summaries.isEmpty {
                print("⚠️ No summary found with ID: \(id)")
                return
            }
            
            for summary in summaries {
                print("🗑️ Deleting summary with ID: \(id)")
                context.delete(summary)
            }
            
            // Properly handle save errors
            do {
                try saveContext()
                print("✅ Successfully deleted summary with ID: \(id)")
            } catch {
                print("❌ Failed to save context after deleting summary: \(error)")
                // Rollback the deletion
                context.rollback()
                throw error
            }
        } catch {
            print("❌ Error deleting summary: \(error)")
            throw error
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
              let url = getAbsoluteURL(for: recordingEntry) else {
            print("❌ Could not get absolute URL for recording: \(recordingEntry.recordingName ?? "unknown")")
            return nil
        }
        
        // Decode segments from JSON
        var segments: [TranscriptSegment] = []
        if let segmentsString = transcriptEntry.segments,
           let segmentsData = segmentsString.data(using: .utf8) {
            segments = (try? JSONDecoder().decode([TranscriptSegment].self, from: segmentsData)) ?? []
        }
        
        // Speaker mappings no longer used (diarization disabled)
        let speakerMappings: [String: String] = [:]
        
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
              let recordingId = recordingEntry.id else {
            print("❌ Missing IDs for summary/recording conversion")
            return nil
        }
        // Allow preserved summaries without an audio URL by falling back to an empty URL
        let url = getAbsoluteURL(for: recordingEntry) ?? URL(fileURLWithPath: "")
        
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
        job.recordingURL = recordingURL.lastPathComponent
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
    
    // MARK: - Cleanup Operations
    
    /// Cleans up orphaned recordings that have no audio file and no meaningful content
    func cleanupOrphanedRecordings() -> Int {
        let allRecordings = getAllRecordings()
        var cleanedCount = 0
        
        for recording in allRecordings {
            // Check if this is an orphaned recording
            let hasNoURL = recording.recordingURL == nil
            let hasNoTranscript = recording.transcript == nil
            let hasNoSummary = recording.summary == nil
            
            // Only clean up recordings that have absolutely no content
            if hasNoURL && hasNoTranscript && hasNoSummary {
                print("🗑️ Cleaning up orphaned recording: \(recording.recordingName ?? "unknown")")
                context.delete(recording)
                cleanedCount += 1
            }
            // For recordings with summaries but no audio, just mark them properly
            else if hasNoURL && recording.summary != nil {
                print("📝 Preserving summary-only recording: \(recording.recordingName ?? "unknown")")
                // These are intentionally preserved summaries
            }
        }
        
        if cleanedCount > 0 {
            do {
                try context.save()
                print("✅ Cleaned up \(cleanedCount) orphaned recordings")
            } catch {
                print("❌ Failed to save cleanup: \(error)")
            }
        }
        
        return cleanedCount
    }
    
    /// Fixes recordings that should have been deleted completely but still exist as orphans
    func fixIncompletelyDeletedRecordings() -> Int {
        print("🔍 Checking for incompletely deleted recordings...")
        let allRecordings = getAllRecordings()
        var fixedCount = 0
        
        for recording in allRecordings {
            // Look for recordings with no URL and no content that appear to be leftover from deletions
            let hasNoURL = recording.recordingURL == nil
            let hasNoTranscript = recording.transcript == nil
            let hasNoSummary = recording.summary == nil
            
            if hasNoURL && hasNoTranscript && hasNoSummary {
                let recordingName = recording.recordingName ?? "unknown"
                print("🗑️ Found incompletely deleted recording: \(recordingName)")
                print("   - This appears to be leftover from a partial deletion")
                
                // Delete this orphaned record
                context.delete(recording)
                fixedCount += 1
            }
        }
        
        if fixedCount > 0 {
            do {
                try context.save()
                print("✅ Fixed \(fixedCount) incompletely deleted recordings")
            } catch {
                print("❌ Failed to save fixes: \(error)")
            }
        } else {
            print("ℹ️ No incompletely deleted recordings found")
        }
        
        return fixedCount
    }
    
    /// Cleans up recordings that reference files that no longer exist
    func cleanupRecordingsWithMissingFiles() -> Int {
        let allRecordings = getAllRecordings()
        var cleanedCount = 0
        
        for recording in allRecordings {
            guard let urlString = recording.recordingURL else { continue }
            
            // Skip if this is a summary-only recording (no URL expected)
            if recording.summary != nil && urlString.isEmpty {
                continue
            }
            
            // Check if the file actually exists
            if let url = getAbsoluteURL(for: recording) {
                if !FileManager.default.fileExists(atPath: url.path) {
                    let recordingName = recording.recordingName ?? "unknown"
                    print("🗑️ Cleaning up recording with missing file: \(recordingName)")
                    print("   - Missing file: \(url.lastPathComponent)")
                    
                    // Only delete if there's no transcript or summary to preserve
                    let hasTranscript = recording.transcript != nil
                    let hasSummary = recording.summary != nil
                    
                    if !hasTranscript && !hasSummary {
                        // No valuable content to preserve, delete the record
                        context.delete(recording)
                        cleanedCount += 1
                    } else {
                        // Has transcript or summary, just clear the URL
                        print("   - Preserving recording with transcript/summary, clearing URL")
                        recording.recordingURL = nil
                        recording.lastModified = Date()
                    }
                }
            } else {
                // Could not resolve URL at all
                let recordingName = recording.recordingName ?? "unknown"
                print("🗑️ Recording with unresolvable URL: \(recordingName)")
                
                let hasTranscript = recording.transcript != nil
                let hasSummary = recording.summary != nil
                
                if !hasTranscript && !hasSummary {
                    context.delete(recording)
                    cleanedCount += 1
                } else {
                    recording.recordingURL = nil
                    recording.lastModified = Date()
                }
            }
        }
        
        if cleanedCount > 0 {
            do {
                try context.save()
                print("✅ Cleaned up \(cleanedCount) recordings with missing files")
            } catch {
                print("❌ Failed to save missing file cleanup: \(error)")
            }
        }
        
        return cleanedCount
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
        let allRecordings = getAllRecordings()
        var updatedCount = 0
        
        // Pre-check if any work is needed to avoid unnecessary logging
        let needsWork = allRecordings.contains { recording in
            guard let urlString = recording.recordingURL else { return false }
            // Skip relative paths - these don't need sync
            if !urlString.contains("/") && !urlString.hasPrefix("file://") {
                return false
            }
            guard let oldURL = URL(string: urlString), oldURL.scheme != nil else { return false }
            return !FileManager.default.fileExists(atPath: oldURL.path)
        }
        
        if needsWork {
            print("🔄 Starting URL synchronization...")
        }
        
        for recording in allRecordings {
            guard let urlString = recording.recordingURL else { continue }
            
            // Skip relative paths (just filenames) - these are handled by getAbsoluteURL()
            if !urlString.contains("/") && !urlString.hasPrefix("file://") {
                continue
            }
            
            guard let oldURL = URL(string: urlString) else { continue }
            
            // Only process absolute URLs that need fixing
            guard oldURL.scheme != nil else { continue }
            
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
                        // Update the Core Data entry with the correct relative path
                        recording.recordingURL = urlToRelativePath(newURL)
                        recording.lastModified = Date()
                        updatedCount += 1
                        // Only log if the filename actually changed or if this is a real path change
                        if oldURL.lastPathComponent != newURL.lastPathComponent {
                            print("✅ Updated URL for \(recording.recordingName ?? "unknown"): \(oldURL.lastPathComponent) → \(newURL.lastPathComponent)")
                        } else {
                            print("🔗 Fixed path for \(recording.recordingName ?? "unknown"): \(newURL.lastPathComponent)")
                        }
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
                                // Update the Core Data entry with the correct relative path
                                recording.recordingURL = urlToRelativePath(newURL)
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
        } else if needsWork {
            print("ℹ️ No URL updates needed")
        }
        // If needsWork was false, we don't log anything to reduce console spam
    }
    
    /// Updates a recording's URL when it's found by filename but the URL is outdated
    func updateRecordingURL(recording: RecordingEntry, newURL: URL) {
        recording.recordingURL = urlToRelativePath(newURL)
        recording.lastModified = Date()
        
        do {
            try context.save()
            print("✅ Updated recording URL: \(recording.recordingName ?? "unknown") → \(newURL.lastPathComponent)")
        } catch {
            print("❌ Failed to save URL update: \(error)")
        }
    }
    
    func updateRecordingName(for recordingId: UUID, newName: String) throws {
        guard let recording = getRecording(id: recordingId) else {
            throw NSError(domain: "CoreDataManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Recording not found with ID: \(recordingId)"])
        }
        
        let oldName = recording.recordingName ?? "Unknown"
        recording.recordingName = newName
        recording.lastModified = Date()
        
        do {
            try context.save()
            print("✅ Updated recording name: '\(oldName)' → '\(newName)'")
        } catch {
            print("❌ Failed to save recording name update: \(error)")
            throw error
        }
    }
    
    // MARK: - Location File Helpers
    
    /// Gets the absolute URL for a location file associated with a recording
    func getLocationFileURL(for recording: RecordingEntry) -> URL? {
        guard let recordingURL = getAbsoluteURL(for: recording) else {
            return nil
        }
        return recordingURL.deletingPathExtension().appendingPathExtension("location")
    }
    
    /// Loads location data for a recording using proper URL resolution
    func loadLocationData(for recording: RecordingEntry) -> LocationData? {
        guard let locationURL = getLocationFileURL(for: recording) else {
            return nil
        }
        
        guard let data = try? Data(contentsOf: locationURL),
              let locationData = try? JSONDecoder().decode(LocationData.self, from: data) else {
            return nil
        }
        
        return locationData
    }
}