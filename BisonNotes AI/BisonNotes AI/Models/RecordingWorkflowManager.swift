//
//  RecordingWorkflowManager.swift
//  Audio Journal
//
//  Created by Kiro on 8/1/25.
//

import Foundation
import CoreData

/// Manages the complete workflow from recording creation through transcription to summarization
/// Ensures consistent UUID linking throughout the entire process
@MainActor
class RecordingWorkflowManager: ObservableObject {
    private let persistenceController: PersistenceController
    private let context: NSManagedObjectContext
    private var appCoordinator: AppDataCoordinator?
    
    init(persistenceController: PersistenceController = PersistenceController.shared) {
        self.persistenceController = persistenceController
        self.context = persistenceController.container.viewContext
        self.appCoordinator = nil // Will be set later to avoid circular dependency
    }
    
    func setAppCoordinator(_ coordinator: AppDataCoordinator) {
        self.appCoordinator = coordinator
    }
    
    // MARK: - Recording Creation
    
    /// Creates a new recording with proper Core Data entry and UUID
    func createRecording(url: URL, name: String, date: Date, fileSize: Int64, duration: TimeInterval, quality: AudioQuality, locationData: LocationData? = nil) -> UUID {
        print("🎵 Creating new recording: \(name)")
        
        // Create Core Data entry
        let recordingEntry = RecordingEntry(context: context)
        let recordingId = UUID()
        print("🆔 Recording UUID: \(recordingId)")
        
        recordingEntry.id = recordingId
        recordingEntry.recordingName = name
        recordingEntry.recordingURL = url.absoluteString
        recordingEntry.recordingDate = date
        recordingEntry.createdAt = Date()
        recordingEntry.lastModified = Date()
        recordingEntry.fileSize = fileSize
        recordingEntry.duration = duration
        recordingEntry.audioQuality = quality.rawValue
        recordingEntry.transcriptionStatus = ProcessingStatus.notStarted.rawValue
        recordingEntry.summaryStatus = ProcessingStatus.notStarted.rawValue
        
        // Store location data if available
        if let locationData = locationData {
            recordingEntry.locationLatitude = locationData.latitude
            recordingEntry.locationLongitude = locationData.longitude
            recordingEntry.locationTimestamp = locationData.timestamp
            recordingEntry.locationAccuracy = locationData.accuracy ?? 0.0
            recordingEntry.locationAddress = locationData.address
        }
        
        // Save to Core Data
        do {
            try context.save()
            print("✅ Recording saved to Core Data with ID: \(recordingId)")
        } catch {
            print("❌ Failed to save recording to Core Data: \(error)")
        }
        
        return recordingId
    }
    
    // MARK: - Transcription Workflow
    
    /// Creates a transcript linked to a recording with proper UUID relationships
    func createTranscript(for recordingId: UUID, segments: [TranscriptSegment], speakerMappings: [String: String] = [:], engine: TranscriptionEngine? = nil, processingTime: TimeInterval = 0, confidence: Double = 0.5) -> UUID? {
        
        // Get the recording from Core Data
        guard let recordingEntry = getRecordingEntry(id: recordingId) else {
            print("❌ Recording not found for ID: \(recordingId)")
            return nil
        }
        
        print("🎯 Creating transcript for recording: \(recordingEntry.recordingName ?? "unknown")")
        print("🆔 Recording UUID: \(recordingId)")
        
        // Create transcript data with proper UUID linking
        let transcriptData = TranscriptData(
            recordingId: recordingId,
            recordingURL: URL(string: recordingEntry.recordingURL ?? "")!,
            recordingName: recordingEntry.recordingName ?? "",
            recordingDate: recordingEntry.recordingDate ?? Date(),
            segments: segments,
            speakerMappings: speakerMappings,
            engine: engine,
            processingTime: processingTime,
            confidence: confidence
        )
        print("🆔 Transcript UUID: \(transcriptData.id)")
        
        // Create Core Data transcript entry
        let transcriptEntry = TranscriptEntry(context: context)
        transcriptEntry.id = transcriptData.id
        transcriptEntry.recordingId = recordingId
        transcriptEntry.createdAt = transcriptData.createdAt
        transcriptEntry.lastModified = transcriptData.lastModified
        transcriptEntry.engine = engine?.rawValue
        transcriptEntry.processingTime = processingTime
        transcriptEntry.confidence = confidence
        
        // Store segments as JSON
        if let segmentsData = try? JSONEncoder().encode(segments),
           let segmentsString = String(data: segmentsData, encoding: .utf8) {
            transcriptEntry.segments = segmentsString
        }
        
        // Store speaker mappings as JSON
        if let speakerData = try? JSONEncoder().encode(speakerMappings),
           let speakerString = String(data: speakerData, encoding: .utf8) {
            transcriptEntry.speakerMappings = speakerString
        }
        
        // Link to recording
        transcriptEntry.recording = recordingEntry
        recordingEntry.transcript = transcriptEntry
        recordingEntry.transcriptId = transcriptData.id
        recordingEntry.transcriptionStatus = ProcessingStatus.completed.rawValue
        recordingEntry.lastModified = Date()
        
        // Save to Core Data
        do {
            try context.save()
            print("✅ Transcript saved to Core Data with ID: \(transcriptData.id)")
        } catch {
            print("❌ Failed to save transcript to Core Data: \(error)")
            return nil
        }
        
        return transcriptData.id
    }
    
    // MARK: - Summary Workflow
    
    /// Creates a summary linked to both recording and transcript with proper UUID relationships
    func createSummary(for recordingId: UUID, transcriptId: UUID, summary: String, tasks: [TaskItem] = [], reminders: [ReminderItem] = [], titles: [TitleItem] = [], contentType: ContentType = .general, aiMethod: String, originalLength: Int, processingTime: TimeInterval = 0) -> UUID? {
        
        // Get the recording from Core Data
        guard let recordingEntry = getRecordingEntry(id: recordingId) else {
            print("❌ Recording not found for ID: \(recordingId)")
            return nil
        }
        
        // Get the transcript from Core Data
        guard let transcriptEntry = getTranscriptEntry(id: transcriptId) else {
            print("❌ Transcript not found for ID: \(transcriptId)")
            return nil
        }
        
        print("📝 Creating summary for recording: \(recordingEntry.recordingName ?? "unknown")")
        print("🆔 Recording UUID: \(recordingId)")
        print("🆔 Transcript UUID: \(transcriptId)")
        
        // Create summary data with proper UUID linking
        let summaryData = EnhancedSummaryData(
            recordingId: recordingId,
            transcriptId: transcriptId,
            recordingURL: URL(string: recordingEntry.recordingURL ?? "")!,
            recordingName: recordingEntry.recordingName ?? "",
            recordingDate: recordingEntry.recordingDate ?? Date(),
            summary: summary,
            tasks: tasks,
            reminders: reminders,
            titles: titles,
            contentType: contentType,
            aiMethod: aiMethod,
            originalLength: originalLength,
            processingTime: processingTime
        )
        print("🆔 Summary UUID: \(summaryData.id)")
        
        // Create Core Data summary entry
        let summaryEntry = SummaryEntry(context: context)
        summaryEntry.id = summaryData.id
        summaryEntry.recordingId = recordingId
        summaryEntry.transcriptId = transcriptId
        summaryEntry.generatedAt = summaryData.generatedAt
        summaryEntry.aiMethod = aiMethod
        summaryEntry.processingTime = processingTime
        summaryEntry.confidence = summaryData.confidence
        summaryEntry.summary = summary
        summaryEntry.contentType = contentType.rawValue
        summaryEntry.wordCount = Int32(summaryData.wordCount)
        summaryEntry.originalLength = Int32(originalLength)
        summaryEntry.compressionRatio = summaryData.compressionRatio
        summaryEntry.version = Int32(summaryData.version)
        
        // Store structured data as JSON
        if let titlesData = try? JSONEncoder().encode(titles),
           let titlesString = String(data: titlesData, encoding: .utf8) {
            summaryEntry.titles = titlesString
        }
        if let tasksData = try? JSONEncoder().encode(tasks),
           let tasksString = String(data: tasksData, encoding: .utf8) {
            summaryEntry.tasks = tasksString
        }
        if let remindersData = try? JSONEncoder().encode(reminders),
           let remindersString = String(data: remindersData, encoding: .utf8) {
            summaryEntry.reminders = remindersString
        }
        
        // Link to recording and transcript
        summaryEntry.recording = recordingEntry
        summaryEntry.transcript = transcriptEntry
        recordingEntry.summary = summaryEntry
        recordingEntry.summaryId = summaryData.id
        recordingEntry.summaryStatus = ProcessingStatus.completed.rawValue
        recordingEntry.lastModified = Date()
        
        // Save to Core Data
        do {
            try context.save()
            print("✅ Summary saved to Core Data with ID: \(summaryData.id)")
        } catch {
            print("❌ Failed to save summary to Core Data: \(error)")
            return nil
        }
        
        return summaryData.id
    }
    
    // MARK: - Name Updates
    
    /// Updates the name of a recording and all its related files when the AI suggests a better name
    func updateRecordingName(recordingId: UUID, newName: String) {
        guard let recordingEntry = getRecordingEntry(id: recordingId) else {
            print("❌ Recording not found for ID: \(recordingId)")
            return
        }
        
        let oldName = recordingEntry.recordingName ?? "unknown"
        print("📝 Updating recording name from '\(oldName)' to '\(newName)'")
        
        // Update Core Data
        recordingEntry.recordingName = newName
        recordingEntry.lastModified = Date()
        
        // Note: Transcript and summary data is stored in Core Data, no file renaming needed
        
        // Update audio file name on disk
        updateAudioFileName(recordingEntry: recordingEntry, oldName: oldName, newName: newName)
        
        // Save changes
        do {
            try context.save()
            print("✅ Recording name updated successfully")
        } catch {
            print("❌ Failed to save name update: \(error)")
        }
    }
    
    // MARK: - Helper Methods
    
    private func getRecordingEntry(id: UUID) -> RecordingEntry? {
        let fetchRequest: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        
        do {
            let results = try context.fetch(fetchRequest)
            return results.first
        } catch {
            print("❌ Error fetching recording: \(error)")
            return nil
        }
    }
    
    private func getTranscriptEntry(id: UUID) -> TranscriptEntry? {
        let fetchRequest: NSFetchRequest<TranscriptEntry> = TranscriptEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        
        do {
            let results = try context.fetch(fetchRequest)
            return results.first
        } catch {
            print("❌ Error fetching transcript: \(error)")
            return nil
        }
    }
    

    
    private func updateAudioFileName(recordingEntry: RecordingEntry, oldName: String, newName: String) {
        guard let urlString = recordingEntry.recordingURL,
              let oldURL = URL(string: urlString) else { 
            print("❌ No valid URL found for recording: \(recordingEntry.recordingName ?? "unknown")")
            return 
        }
        
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent("\(newName).\(oldURL.pathExtension)")
        
        do {
            // Check if the old file exists before trying to rename
            if FileManager.default.fileExists(atPath: oldURL.path) {
                try FileManager.default.moveItem(at: oldURL, to: newURL)
                recordingEntry.recordingURL = newURL.absoluteString
                recordingEntry.lastModified = Date()
                print("📁 Audio file renamed: \(oldURL.lastPathComponent) → \(newURL.lastPathComponent)")
                
                // Save the changes to Core Data
                try context.save()
                print("✅ Core Data updated with new URL")
            } else {
                print("⚠️ Audio file not found at expected location: \(oldURL.path)")
                print("🔍 Checking if file exists with new name...")
                
                // Check if the file already exists with the new name
                if FileManager.default.fileExists(atPath: newURL.path) {
                    recordingEntry.recordingURL = newURL.absoluteString
                    recordingEntry.lastModified = Date()
                    print("📁 Updated Core Data URL to match existing file: \(newURL.lastPathComponent)")
                    
                    // Save the changes to Core Data
                    try context.save()
                    print("✅ Core Data updated with correct URL")
                } else {
                    print("❌ File not found at either old or new location")
                }
            }
        } catch {
            // Check if this is a thumbnail-related error that we can ignore
            if error.isThumbnailGenerationError {
                print("⚠️ Thumbnail generation warning during file rename (can be ignored): \(error.localizedDescription)")
                // Continue with the operation even if thumbnail generation fails
                // The file move operation itself succeeded, only thumbnail generation failed
                
                // Update the URL and save to Core Data since the file move was successful
                recordingEntry.recordingURL = newURL.absoluteString
                recordingEntry.lastModified = Date()
                
                do {
                    try context.save()
                    print("✅ Core Data updated with new URL (despite thumbnail warning)")
                } catch {
                    print("❌ Failed to save Core Data after file rename: \(error)")
                }
            } else {
                print("❌ Failed to rename audio file: \(error)")
                print("🔍 Error details: \(error.localizedDescription)")
            }
        }
    }
    
}