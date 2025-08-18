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
    func createRecording(url: URL, name: String, date: Date, fileSize: Int64, duration: TimeInterval, quality: AudioQuality, locationData: LocationData? = nil, recordingSource: RecordingSource = .phone, watchData: WatchRecordingData? = nil) -> UUID {
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
        
        // Store recording source information and set appropriate name
        // Note: If Core Data model doesn't have these fields, we'll store in existing fields for now
        // recordingEntry.recordingSource = recordingSource.rawValue // TODO: Add to Core Data model
        // recordingEntry.isWatchRecording = recordingSource == .watch // TODO: Add to Core Data model
        
        // Set recording name based on source
        if recordingSource == .watch {
            recordingEntry.recordingName = "\(name) [Watch]" // Mark as watch recording
        } else {
            recordingEntry.recordingName = name // Use original name for phone recordings
        }
        
        // Store watch recording data if available
        if let watchData = watchData {
            // For now, store watch metadata as JSON in a description field or similar
            // TODO: Add proper watch metadata fields to Core Data model
            let watchMetadata = createWatchMetadataString(from: watchData)
            // recordingEntry.metadata = watchMetadata // TODO: Add to Core Data model
            print("⌚ Watch recording metadata: \(watchMetadata)")
        }
        
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
        } catch {
            print("❌ Failed to save recording to Core Data: \(error)")
        }
        
        return recordingId
    }
    
    /// Creates a recording specifically for watch-originated recordings
    func createWatchRecording(
        url: URL, 
        name: String, 
        date: Date, 
        fileSize: Int64, 
        duration: TimeInterval, 
        quality: AudioQuality = .whisperOptimized,
        watchSessionId: UUID,
        batteryLevel: Float,
        chunkCount: Int,
        transferMethod: WatchTransferMethod = .realTime,
        locationData: LocationData? = nil
    ) -> UUID {
        
        let watchData = WatchRecordingData(
            sessionId: watchSessionId,
            batteryLevel: batteryLevel,
            chunkCount: chunkCount,
            transferMethod: transferMethod,
            recordingTimestamp: date
        )
        
        return createRecording(
            url: url,
            name: name,
            date: date,
            fileSize: fileSize,
            duration: duration,
            quality: quality,
            locationData: locationData,
            recordingSource: .watch,
            watchData: watchData
        )
    }
    
    /// Helper method to create watch metadata string for storage
    private func createWatchMetadataString(from watchData: WatchRecordingData) -> String {
        let metadata: [String: Any] = [
            "sessionId": watchData.sessionId.uuidString,
            "batteryLevel": watchData.batteryLevel,
            "chunkCount": watchData.chunkCount,
            "transferMethod": watchData.transferMethod.rawValue,
            "recordingTimestamp": watchData.recordingTimestamp.timeIntervalSince1970,
            "source": "appleWatch"
        ]
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: metadata)
            return String(data: jsonData, encoding: .utf8) ?? ""
        } catch {
            print("❌ Failed to create watch metadata JSON: \(error)")
            return "watchRecording: \(watchData.sessionId.uuidString)"
        }
    }
    
    /// Check if a recording was originated from watch
    func isWatchRecording(_ recordingId: UUID) -> Bool {
        guard let recordingEntry = getRecordingEntry(id: recordingId) else { return false }
        return recordingEntry.recordingName?.contains("[Watch]") == true
    }
    
    /// Get watch recording data if available
    func getWatchRecordingData(_ recordingId: UUID) -> WatchRecordingData? {
        guard isWatchRecording(recordingId) else { return nil }
        
        // TODO: Extract from proper metadata field when Core Data model is updated
        // For now, return basic data based on the recording entry
        guard let recordingEntry = getRecordingEntry(id: recordingId) else { return nil }
        
        return WatchRecordingData(
            sessionId: recordingId, // Use recording ID as session ID for now
            batteryLevel: 0.5, // Default value
            chunkCount: 0, // Default value
            transferMethod: .realTime,
            recordingTimestamp: recordingEntry.recordingDate ?? Date()
        )
    }
    
    // MARK: - Transcription Workflow
    
    /// Creates a transcript linked to a recording with proper UUID relationships
    func createTranscript(for recordingId: UUID, segments: [TranscriptSegment], speakerMappings: [String: String] = [:], engine: TranscriptionEngine? = nil, processingTime: TimeInterval = 0, confidence: Double = 0.5) -> UUID? {
        
        // Get the recording from Core Data
        guard let recordingEntry = getRecordingEntry(id: recordingId) else {
            print("❌ Recording not found for ID: \(recordingId)")
            return nil
        }
        
        // Log recording source for debugging/analytics
        let recordingSource = isWatchRecording(recordingId) ? "watch" : "phone"
        print("📝 Creating transcript for \(recordingSource) recording: \(recordingEntry.recordingName ?? "unknown")")
        
        // Check if a transcript already exists for this recording
        if let existingTranscript = recordingEntry.transcript {
            print("🔄 Existing transcript found, replacing with new transcript...")
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
        
        // Clear speaker mappings (no longer used)
        transcriptEntry.speakerMappings = nil
        
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
            print("❌ Failed to save transcript to Core Data: \(error)")
            return nil
        }
        
        return transcriptData.id
    }
    
    /// Replaces an existing transcript with new content while preserving the same UUID
    private func replaceTranscript(_ existingTranscript: TranscriptEntry, with segments: [TranscriptSegment], speakerMappings: [String: String] = [:], engine: TranscriptionEngine? = nil, processingTime: TimeInterval = 0, confidence: Double = 0.5) -> UUID? {
        
        print("🔄 Replacing existing transcript with ID: \(existingTranscript.id?.uuidString ?? "unknown")")
        
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
        
        // Clear speaker mappings (no longer used)
        existingTranscript.speakerMappings = nil
        
        // Update the recording's last modified date
        existingTranscript.recording?.lastModified = Date()
        
        // Save to Core Data
        do {
            try context.save()
            print("✅ Transcript replaced successfully with ID: \(existingTranscript.id?.uuidString ?? "unknown")")
            return existingTranscript.id
        } catch {
            print("❌ Failed to replace transcript in Core Data: \(error)")
            return nil
        }
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
        
        // Log recording source for debugging/analytics
        let recordingSource = isWatchRecording(recordingId) ? "watch" : "phone"
        print("📝 Creating summary for \(recordingSource) recording: \(recordingEntry.recordingName ?? "unknown")")
        print("🆔 Recording UUID: \(recordingId)")
        print("🆔 Transcript UUID: \(transcriptId)")
        
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
            
            // Post notification to refresh UI views
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: NSNotification.Name("SummaryCreated"),
                    object: nil,
                    userInfo: ["recordingId": recordingId, "summaryId": summaryData.id]
                )
            }
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
    
    /// Validate that watch recordings are compatible with all AI processing engines
    func validateWatchRecordingCompatibility(_ recordingId: UUID) async -> Bool {
        guard let recordingEntry = getRecordingEntry(id: recordingId) else {
            print("❌ Recording not found for compatibility check")
            return false
        }
        
        // Check if recording file exists and is accessible
        guard let urlString = recordingEntry.recordingURL,
              let url = URL(string: urlString),
              FileManager.default.fileExists(atPath: url.path) else {
            print("❌ Watch recording file not accessible for AI processing")
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
            print("❌ Failed to load asset properties: \(error)")
            return false
        }
        
        if duration <= 0 {
            print("❌ Watch recording has invalid duration")
            return false
        }
        
        // Verify audio tracks exist
        if audioTracks.isEmpty {
            print("❌ Watch recording has no audio tracks")
            return false
        }
        
        let recordingSource = isWatchRecording(recordingId) ? "watch" : "phone"
        print("✅ \(recordingSource) recording is compatible with AI processing (duration: \(duration)s)")
        return true
    }
}

// MARK: - Supporting Types for Watch Integration

/// Recording source to track where the recording originated
enum RecordingSource: String, CaseIterable {
    case phone = "phone"
    case watch = "watch"
    case imported = "imported"
    
    var description: String {
        switch self {
        case .phone:
            return "Phone"
        case .watch:
            return "Apple Watch"
        case .imported:
            return "Imported"
        }
    }
    
    var icon: String {
        switch self {
        case .phone:
            return "iphone"
        case .watch:
            return "applewatch"
        case .imported:
            return "square.and.arrow.down"
        }
    }
}

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