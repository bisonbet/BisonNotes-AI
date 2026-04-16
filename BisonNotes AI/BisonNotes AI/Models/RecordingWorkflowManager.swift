//
//  RecordingWorkflowManager.swift
//  Audio Journal
//
//  Created by Kiro on 8/1/25.
//

import Foundation
import CoreData
import AVFoundation

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
        // Create Core Data entry
        let recordingEntry = RecordingEntry(context: context)
        let recordingId = UUID()
        
        recordingEntry.id = recordingId
        // Store relative path instead of absolute URL for resilience across app launches
        recordingEntry.recordingURL = urlToRelativePath(url)
        recordingEntry.recordingDate = date
        recordingEntry.createdAt = Date()
        recordingEntry.lastModified = Date()
        recordingEntry.fileSize = fileSize
        recordingEntry.duration = duration
        recordingEntry.audioQuality = quality.rawValue
        recordingEntry.transcriptionStatus = ProcessingStatus.notStarted.rawValue
        recordingEntry.summaryStatus = ProcessingStatus.notStarted.rawValue
        
        // Set recording name
        recordingEntry.recordingName = name
        
        
        // Store location data if available
        if let locationData = locationData {
            AppLog.shared.backgroundProcessing("Saving location data - lat: \(locationData.latitude), lon: \(locationData.longitude)")
            recordingEntry.locationLatitude = locationData.latitude
            recordingEntry.locationLongitude = locationData.longitude
            recordingEntry.locationTimestamp = locationData.timestamp
            recordingEntry.locationAccuracy = locationData.accuracy ?? 0.0
            recordingEntry.locationAddress = locationData.address
            AppLog.shared.backgroundProcessing("Location saved to Core Data entry")
        } else {
            AppLog.shared.backgroundProcessing("No location data provided", level: .debug)
        }
        
        // Save to Core Data
        do {
            try context.save()
        } catch {
            AppLog.shared.backgroundProcessing("Failed to save recording to Core Data: \(error)", level: .error)
        }
        
        return recordingId
    }
    
    
    
    // MARK: - Transcription Workflow
    
    /// Creates a transcript linked to a recording with proper UUID relationships
    func createTranscript(for recordingId: UUID, segments: [TranscriptSegment], speakerMappings: [String: String] = [:], engine: TranscriptionEngine? = nil, processingTime: TimeInterval = 0, confidence: Double = 0.5) -> UUID? {
        
        // Get the recording from Core Data
        guard let recordingEntry = getRecordingEntry(id: recordingId) else {
            AppLog.shared.backgroundProcessing("Recording not found for ID: \(recordingId)", level: .error)
            return nil
        }

        // Log recording for debugging/analytics
        AppLog.shared.backgroundProcessing("Creating transcript for recording: \(recordingEntry.recordingName ?? "unknown")")
        
        // Check if a transcript already exists for this recording
        if let existingTranscript = recordingEntry.transcript {
            AppLog.shared.backgroundProcessing("Existing transcript found, replacing with new transcript")
            return replaceTranscript(existingTranscript, with: segments, speakerMappings: speakerMappings, engine: engine, processingTime: processingTime, confidence: confidence)
        }
        
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
        if !speakerMappings.isEmpty,
           let mappingsData = try? JSONEncoder().encode(speakerMappings),
           let mappingsString = String(data: mappingsData, encoding: .utf8) {
            transcriptEntry.speakerMappings = mappingsString
        } else {
            transcriptEntry.speakerMappings = nil
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
        } catch {
            AppLog.shared.backgroundProcessing("Failed to save transcript to Core Data: \(error)", level: .error)
            return nil
        }
        
        return transcriptData.id
    }
    
    /// Replaces an existing transcript with new content while preserving the same UUID
    private func replaceTranscript(_ existingTranscript: TranscriptEntry, with segments: [TranscriptSegment], speakerMappings: [String: String] = [:], engine: TranscriptionEngine? = nil, processingTime: TimeInterval = 0, confidence: Double = 0.5) -> UUID? {
        
        AppLog.shared.backgroundProcessing("Replacing existing transcript with ID: \(existingTranscript.id?.uuidString ?? "unknown")")
        
        // Update the existing transcript entry with new data
        existingTranscript.lastModified = Date() 
        existingTranscript.engine = engine?.rawValue
        existingTranscript.processingTime = processingTime
        existingTranscript.confidence = confidence
        
        // Store new segments as JSON
        if let segmentsData = try? JSONEncoder().encode(segments),
           let segmentsString = String(data: segmentsData, encoding: .utf8) {
            existingTranscript.segments = segmentsString
        }

        // Store speaker mappings as JSON
        if !speakerMappings.isEmpty,
           let mappingsData = try? JSONEncoder().encode(speakerMappings),
           let mappingsString = String(data: mappingsData, encoding: .utf8) {
            existingTranscript.speakerMappings = mappingsString
        } else {
            existingTranscript.speakerMappings = nil
        }
        
        // Update the recording's last modified date
        existingTranscript.recording?.lastModified = Date()
        
        // Save to Core Data
        do {
            try context.save()
            AppLog.shared.backgroundProcessing("Transcript replaced successfully with ID: \(existingTranscript.id?.uuidString ?? "unknown")")
            return existingTranscript.id
        } catch {
            AppLog.shared.backgroundProcessing("Failed to replace transcript in Core Data: \(error)", level: .error)
            return nil
        }
    }
    
    // MARK: - Summary Workflow
    
    /// Creates a summary linked to both recording and transcript with proper UUID relationships
    func createSummary(for recordingId: UUID, transcriptId: UUID, summary: String, tasks: [TaskItem] = [], reminders: [ReminderItem] = [], titles: [TitleItem] = [], contentType: ContentType = .general, aiEngine: String = "Unknown", aiModel: String, originalLength: Int, processingTime: TimeInterval = 0) -> UUID? {
        
        // Get the recording from Core Data
        guard let recordingEntry = getRecordingEntry(id: recordingId) else {
            AppLog.shared.backgroundProcessing("Recording not found for ID: \(recordingId)", level: .error)
            return nil
        }

        // Get the transcript from Core Data
        guard let transcriptEntry = getTranscriptEntry(id: transcriptId) else {
            AppLog.shared.backgroundProcessing("Transcript not found for ID: \(transcriptId)", level: .error)
            return nil
        }
        
        // Reject obviously-failed summaries before touching Core Data at all
        let summaryTrimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard summaryTrimmed.count >= 30 else {
            AppLog.shared.backgroundProcessing("Summary too short (\(summaryTrimmed.count) chars) -- skipping save to avoid storing a failed result")
            return nil
        }

        // Log recording for debugging/analytics
        AppLog.shared.backgroundProcessing("Creating summary for recording: \(recordingEntry.recordingName ?? "unknown")")
        AppLog.shared.backgroundProcessing("Recording UUID: \(recordingId), Transcript UUID: \(transcriptId)", level: .debug)

        // Capture existing summaries BEFORE creating new one using context directly
        // (appCoordinator may be nil, so we use context to avoid silent no-ops)
        // We'll delete these only AFTER successfully saving the new summary
        let existingSummaryFetch: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
        existingSummaryFetch.predicate = NSPredicate(format: "recordingId == %@", recordingId as CVarArg)
        let existingSummaries = (try? context.fetch(existingSummaryFetch)) ?? []
        if !existingSummaries.isEmpty {
            AppLog.shared.backgroundProcessing("Found \(existingSummaries.count) existing summary(ies) to clean up after save", level: .debug)
        }

        // Create summary data with proper UUID linking
        // Use proper URL resolution instead of force unwrapping
        let recordingURL = appCoordinator?.coreDataManager.getAbsoluteURL(for: recordingEntry) ?? URL(fileURLWithPath: "")
        
        let summaryData = EnhancedSummaryData(
            recordingId: recordingId,
            transcriptId: transcriptId,
            recordingURL: recordingURL,
            recordingName: recordingEntry.recordingName ?? "",
            recordingDate: recordingEntry.recordingDate ?? Date(),
            summary: summary,
            tasks: tasks,
            reminders: reminders,
            titles: titles,
            contentType: contentType,
            aiEngine: aiEngine,
            aiModel: aiModel,
            originalLength: originalLength,
            processingTime: processingTime
        )
        AppLog.shared.backgroundProcessing("Summary UUID: \(summaryData.id)", level: .debug)
        
        // Create Core Data summary entry
        let summaryEntry = SummaryEntry(context: context)
        summaryEntry.id = summaryData.id
        summaryEntry.recordingId = recordingId
        summaryEntry.transcriptId = transcriptId
        summaryEntry.generatedAt = summaryData.generatedAt
        summaryEntry.aiMethod = SummaryMetadataCodec.encode(aiEngine: aiEngine, aiModel: aiModel)
        
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
            AppLog.shared.backgroundProcessing("Summary saved to Core Data with ID: \(summaryData.id)")

            // NOW clean up old summaries using context directly (only after new one is safely saved)
            if !existingSummaries.isEmpty {
                // Migrate supplemental data (notes/attachments) from the most recent old summary
                // to the new summary so user data is not lost on regeneration.
                if let primaryOld = existingSummaries.first, let oldId = primaryOld.id {
                    do {
                        try SummaryAttachmentStore.shared.migrate(from: oldId, to: summaryData.id)
                        AppLog.shared.backgroundProcessing("Migrated supplemental data from \(oldId) to \(summaryData.id)", level: .debug)
                    } catch {
                        AppLog.shared.backgroundProcessing("Failed to migrate supplemental data from \(oldId): \(error)", level: .error)
                    }
                }

                var deletedCount = 0
                for oldSummary in existingSummaries {
                    let oldId = oldSummary.id?.uuidString ?? "nil"
                    // Clean up any remaining supplemental folders that were not migrated
                    if let oldUUID = oldSummary.id, oldUUID != existingSummaries.first?.id {
                        try? SummaryAttachmentStore.shared.deleteAll(for: oldUUID)
                    }
                    context.delete(oldSummary)
                    deletedCount += 1
                    AppLog.shared.backgroundProcessing("Deleted old summary \(oldId)", level: .debug)
                }
                if deletedCount > 0 {
                    try? context.save()
                    AppLog.shared.backgroundProcessing("Cleaned up \(deletedCount) old summary(ies) for recording \(recordingId)", level: .debug)
                }
            }

            // Post notification to refresh UI views
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: NSNotification.Name("SummaryCreated"),
                    object: nil,
                    userInfo: ["recordingId": recordingId, "summaryId": summaryData.id]
                )
            }
        } catch {
            AppLog.shared.backgroundProcessing("Failed to save summary to Core Data: \(error)", level: .error)
            // Note: We did NOT delete old summaries, so user still has their previous data
            return nil
        }

        return summaryData.id
    }
    
    // MARK: - Name Updates
    
    /// Updates the name of a recording and all its related files when the AI suggests a better name
    func updateRecordingName(recordingId: UUID, newName: String) {
        guard let recordingEntry = getRecordingEntry(id: recordingId) else {
            AppLog.shared.backgroundProcessing("Recording not found for ID: \(recordingId)", level: .error)
            return
        }

        let oldName = recordingEntry.recordingName ?? "unknown"
        AppLog.shared.backgroundProcessing("Updating recording name from '\(oldName)' to '\(newName)'")
        
        // Clean any [Watch] tags from the new name and use it directly
        let finalName = newName.replacingOccurrences(of: " [Watch]", with: "")
        
        // Update Core Data
        recordingEntry.recordingName = finalName
        recordingEntry.lastModified = Date()
        
        // Note: Transcript and summary data is stored in Core Data, no file renaming needed
        
        // Update audio file name on disk
        updateAudioFileName(recordingEntry: recordingEntry, oldName: oldName, newName: finalName)
        
        // Save changes
        do {
            try context.save()
            AppLog.shared.backgroundProcessing("Recording name updated successfully")
        } catch {
            AppLog.shared.backgroundProcessing("Failed to save name update: \(error)", level: .error)
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
            AppLog.shared.backgroundProcessing("Error fetching recording: \(error)", level: .error)
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
            AppLog.shared.backgroundProcessing("Error fetching transcript: \(error)", level: .error)
            return nil
        }
    }
    

    
    private func updateAudioFileName(recordingEntry: RecordingEntry, oldName: String, newName: String) {
        guard let urlString = recordingEntry.recordingURL,
              let oldURL = URL(string: urlString) else { 
            AppLog.shared.backgroundProcessing("No valid URL found for recording: \(recordingEntry.recordingName ?? "unknown")", level: .error)
            return 
        }
        
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent("\(newName).\(oldURL.pathExtension)")
        
        do {
            // Check if the old file exists before trying to rename
            if FileManager.default.fileExists(atPath: oldURL.path) {
                try FileManager.default.moveItem(at: oldURL, to: newURL)
                recordingEntry.recordingURL = newURL.absoluteString
                recordingEntry.lastModified = Date()
                AppLog.shared.backgroundProcessing("Audio file renamed: \(oldURL.lastPathComponent) -> \(newURL.lastPathComponent)")

                // Save the changes to Core Data
                try context.save()
                AppLog.shared.backgroundProcessing("Core Data updated with new URL")
            } else {
                AppLog.shared.backgroundProcessing("Audio file not found at expected location, checking new name", level: .debug)
                
                // Check if the file already exists with the new name
                if FileManager.default.fileExists(atPath: newURL.path) {
                    recordingEntry.recordingURL = newURL.absoluteString
                    recordingEntry.lastModified = Date()
                    AppLog.shared.backgroundProcessing("Updated Core Data URL to match existing file: \(newURL.lastPathComponent)")

                    // Save the changes to Core Data
                    try context.save()
                    AppLog.shared.backgroundProcessing("Core Data updated with correct URL")
                } else {
                    AppLog.shared.backgroundProcessing("File not found at either old or new location", level: .error)
                }
            }
        } catch {
            // Check if this is a thumbnail-related error that we can ignore
            if error.isThumbnailGenerationError {
                AppLog.shared.backgroundProcessing("Thumbnail generation warning during file rename (can be ignored)", level: .debug)
                // Continue with the operation even if thumbnail generation fails
                // The file move operation itself succeeded, only thumbnail generation failed
                
                // Update the URL and save to Core Data since the file move was successful
                recordingEntry.recordingURL = newURL.absoluteString
                recordingEntry.lastModified = Date()
                
                do {
                    try context.save()
                    AppLog.shared.backgroundProcessing("Core Data updated with new URL (despite thumbnail warning)")
                } catch {
                    AppLog.shared.backgroundProcessing("Failed to save Core Data after file rename: \(error)", level: .error)
                }
            } else {
                AppLog.shared.backgroundProcessing("Failed to rename audio file: \(error.localizedDescription)", level: .error)
            }
        }
    }
    
    /// Converts an absolute URL to a relative path for storage
    private func urlToRelativePath(_ url: URL) -> String? {
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
    
    /// Validate that recordings are compatible with all AI processing engines
    func validateRecordingCompatibility(_ recordingId: UUID) async -> Bool {
        guard let recordingEntry = getRecordingEntry(id: recordingId) else {
            AppLog.shared.backgroundProcessing("Recording not found for compatibility check", level: .error)
            return false
        }
        
        // Check if recording file exists and is accessible
        guard let urlString = recordingEntry.recordingURL,
              let url = URL(string: urlString),
              FileManager.default.fileExists(atPath: url.path) else {
            AppLog.shared.backgroundProcessing("Recording file not accessible for AI processing", level: .error)
            return false
        }
        
        // Check audio format compatibility
        let asset = AVURLAsset(url: url)
        
        // Use modern async APIs
        let duration: TimeInterval
        let audioTracks: [AVAssetTrack]
        
        do {
            if #available(iOS 16.0, *) {
                // Use modern async APIs for iOS 16+
                let assetDuration = try await asset.load(.duration)
                duration = CMTimeGetSeconds(assetDuration)
                audioTracks = try await asset.loadTracks(withMediaType: .audio)
            } else {
                // Fallback for iOS 15 and below
                duration = CMTimeGetSeconds(asset.duration)
                audioTracks = asset.tracks(withMediaType: .audio)
            }
        } catch {
            AppLog.shared.backgroundProcessing("Failed to load asset properties: \(error)", level: .error)
            return false
        }
        
        if duration <= 0 {
            AppLog.shared.backgroundProcessing("Recording has invalid duration", level: .error)
            return false
        }
        
        // Verify audio tracks exist
        if audioTracks.isEmpty {
            AppLog.shared.backgroundProcessing("Recording has no audio tracks", level: .error)
            return false
        }
        
        AppLog.shared.backgroundProcessing("Recording is compatible with AI processing (duration: \(duration)s)")
        return true
    }
}

// MARK: - Supporting Types for Watch Integration


/// Data structure for watch recording metadata
struct WatchRecordingData {
    let sessionId: UUID
    let batteryLevel: Float
    let chunkCount: Int
    let transferMethod: WatchTransferMethod
    let recordingTimestamp: Date
    
    var batteryPercentage: Int {
        return Int(batteryLevel * 100)
    }
    
    var isLowBattery: Bool {
        return batteryLevel < 0.2
    }
}

/// Method used to transfer watch audio to phone
enum WatchTransferMethod: String, CaseIterable {
    case realTime = "realtime"
    case postRecording = "post_recording"
    case manual = "manual"
    
    var description: String {
        switch self {
        case .realTime:
            return "Real-time streaming"
        case .postRecording:
            return "Post-recording transfer"
        case .manual:
            return "Manual sync"
        }
    }
}
