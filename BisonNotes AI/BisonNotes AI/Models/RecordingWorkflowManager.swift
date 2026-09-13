//
//  RecordingWorkflowManager.swift
//  Audio Journal
//
//  Created by Kiro on 8/1/25.
//

import Foundation
import CoreData
import AVFoundation

enum RecordingWorkflowError: Error, LocalizedError {
    case encodingFailed(String)
    case recordingNotFound(UUID)
    case transcriptNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .encodingFailed(let value):
            return "The \(value) could not be encoded for local persistence."
        case .recordingNotFound(let id):
            return "Recording not found: \(id.uuidString)"
        case .transcriptNotFound(let id):
            return "Transcript not found: \(id.uuidString)"
        }
    }
}

/// Manages the complete workflow from recording creation through transcription to summarization
/// Ensures consistent UUID linking throughout the entire process
@MainActor
class RecordingWorkflowManager: ObservableObject {
    private let persistenceController: PersistenceController
    private let context: NSManagedObjectContext
    private let coreDataManager: CoreDataManager
    private var appCoordinator: AppDataCoordinator?

    init(
        persistenceController: PersistenceController? = nil,
        coreDataManager: CoreDataManager? = nil
    ) {
        let resolvedPersistenceController = persistenceController ?? PersistenceController.shared
        let resolvedCoreDataManager = coreDataManager ?? CoreDataManager(persistenceController: resolvedPersistenceController)
        self.persistenceController = resolvedPersistenceController
        self.context = resolvedCoreDataManager.managedObjectContext
        self.coreDataManager = resolvedCoreDataManager
        self.appCoordinator = nil // Will be set later to avoid circular dependency
    }

    func setAppCoordinator(_ coordinator: AppDataCoordinator) {
        self.appCoordinator = coordinator
    }

    // MARK: - Recording Creation

    /// Creates a new recording with proper Core Data entry and UUID
    func createRecording(url: URL, name: String, date: Date, fileSize: Int64, duration: TimeInterval, quality: AudioQuality, locationData: LocationData? = nil) throws -> UUID {
        return try coreDataManager.performIsolatedMutation(operation: "recording creation") { isolatedContext in
            let recordingEntry = RecordingEntry(context: isolatedContext)
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

            return recordingId
        }
    }

    // MARK: - Transcription Workflow

    /// Creates a transcript linked to a recording with proper UUID relationships
    func createTranscript(for recordingId: UUID, segments: [TranscriptSegment], speakerMappings: [String: String] = [:], engine: TranscriptionEngine? = nil, processingTime: TimeInterval = 0, confidence: Double = 0.5) throws -> UUID? {

        guard let recording = try coreDataManager.fetchRecording(id: recordingId) else {
            throw RecordingWorkflowError.recordingNotFound(recordingId)
        }
        guard !recording.objectID.isTemporaryID else { throw CoreDataMutationError.contextUnavailable }
        let operation = recording.transcript == nil ? "transcript creation" : "transcript replacement"
        let segmentsString = try encodedString(segments)
        let mappingsString = speakerMappings.isEmpty ? nil : try encodedString(speakerMappings)
        return try coreDataManager.performIsolatedMutation(operation: operation) { isolatedContext in
            guard let storedRecording = try isolatedContext.existingObject(with: recording.objectID) as? RecordingEntry else {
                throw RecordingWorkflowError.recordingNotFound(recordingId)
            }
            let transcript = storedRecording.transcript ?? TranscriptEntry(context: isolatedContext)
            if transcript.id == nil { transcript.id = UUID() }
            if transcript.createdAt == nil { transcript.createdAt = Date() }
            transcript.lastModified = Date()
            transcript.recordingId = recordingId
            transcript.recording = storedRecording
            transcript.engine = engine?.rawValue
            transcript.processingTime = processingTime
            transcript.confidence = confidence
            transcript.segments = segmentsString
            transcript.speakerMappings = mappingsString
            storedRecording.transcript = transcript
            storedRecording.transcriptId = transcript.id
            storedRecording.transcriptionStatus = ProcessingStatus.completed.rawValue
            storedRecording.lastModified = Date()
            return transcript.id
        }
    }

    private func encodedString<Value: Encodable>(_ value: Value) throws -> String {
        guard let string = String(data: try JSONEncoder().encode(value), encoding: .utf8) else {
            throw RecordingWorkflowError.encodingFailed("structured content")
        }
        return string
    }

    // MARK: - Summary Workflow

    /// Creates a summary linked to both recording and transcript with proper UUID relationships
    func createSummary(for recordingId: UUID, transcriptId: UUID, summary: String, tasks: [TaskItem] = [], reminders: [ReminderItem] = [], titles: [TitleItem] = [], contentType: ContentType = .general, aiEngine: String = "Unknown", aiModel: String, originalLength: Int, processingTime: TimeInterval = 0) throws -> UUID? {

        guard let recordingEntry = try coreDataManager.fetchRecording(id: recordingId) else {
            AppLog.shared.backgroundProcessing("Recording not found for ID: \(recordingId)", level: .error)
            throw RecordingWorkflowError.recordingNotFound(recordingId)
        }

        guard let transcriptEntry = try coreDataManager.fetchTranscript(id: transcriptId) else {
            AppLog.shared.backgroundProcessing("Transcript not found for ID: \(transcriptId)", level: .error)
            throw RecordingWorkflowError.transcriptNotFound(transcriptId)
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

        // Capture existing summaries before creating the new one. A failed
        // read is not an empty library and must stop the mutation.
        let existingSummaries = try coreDataManager.fetchSummaries(forRecordingId: recordingId)
        if !existingSummaries.isEmpty {
            AppLog.shared.backgroundProcessing("Found \(existingSummaries.count) existing summary(ies) to clean up after save", level: .debug)
        }

        let titlesData = try JSONEncoder().encode(titles)
        guard let titlesString = String(data: titlesData, encoding: .utf8) else {
            throw RecordingWorkflowError.encodingFailed("summary titles")
        }
        let tasksData = try JSONEncoder().encode(tasks)
        guard let tasksString = String(data: tasksData, encoding: .utf8) else {
            throw RecordingWorkflowError.encodingFailed("summary tasks")
        }
        let remindersData = try JSONEncoder().encode(reminders)
        guard let remindersString = String(data: remindersData, encoding: .utf8) else {
            throw RecordingWorkflowError.encodingFailed("summary reminders")
        }

        // Create summary data with proper UUID linking. Preserve a stable,
        // recoverable reference when the external file is unavailable; an
        // empty URL would make a failed lookup look like a valid save.
        let recordingURL = coreDataManager.getStoredURL(for: recordingEntry)
            ?? URL(fileURLWithPath: "/preserved-recordings/\(recordingId.uuidString)")

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

        guard !recordingEntry.objectID.isTemporaryID, !transcriptEntry.objectID.isTemporaryID else {
            throw CoreDataMutationError.contextUnavailable
        }
        try coreDataManager.performIsolatedMutation(operation: "summary creation") { isolatedContext in
            guard let recordingEntry = try isolatedContext.existingObject(with: recordingEntry.objectID) as? RecordingEntry,
                  let transcriptEntry = try isolatedContext.existingObject(with: transcriptEntry.objectID) as? TranscriptEntry else {
                throw CoreDataMutationError.contextUnavailable
            }
            // Create Core Data summary entry
            let summaryEntry = SummaryEntry(context: isolatedContext)
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

            // Store structured data as JSON. Encoding errors are part of the
            // failed mutation; do not create a partially populated success row.
            summaryEntry.titles = titlesString
            summaryEntry.tasks = tasksString
            summaryEntry.reminders = remindersString

            // Link to recording and transcript
            summaryEntry.recording = recordingEntry
            summaryEntry.transcript = transcriptEntry
            recordingEntry.summary = summaryEntry
            recordingEntry.summaryId = summaryData.id
            recordingEntry.summaryStatus = ProcessingStatus.completed.rawValue
            recordingEntry.lastModified = Date()

        }
        AppLog.shared.backgroundProcessing("Summary saved to Core Data with ID: \(summaryData.id)")
        finishSummaryCreation(summaryData, existingSummaries: existingSummaries, recordingId: recordingId)
        return summaryData.id
    }

    private func finishSummaryCreation(
        _ summaryData: EnhancedSummaryData,
        existingSummaries: [SummaryEntry],
        recordingId: UUID
    ) {
        // Clean up old summaries only after the new summary is durable.
        // This secondary cleanup is isolated so a failed delete cannot
        // roll back the new summary or commit unrelated pending edits.
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

            let migratedSummaryId = existingSummaries.first?.id
            var effects = DeferredDeletionEffects()
            var summaryIDs: [UUID] = []

            for oldSummary in existingSummaries {
                let oldId = oldSummary.id?.uuidString ?? "nil"
                if let oldSummaryId = oldSummary.id {
                    summaryIDs.append(oldSummaryId)
                    // Keep the primary folder because its supplemental data was
                    // migrated to the new summary. Other folders are removed only
                    // after the row deletion and its outbox intent commit.
                    effects.stage(
                        summary: oldSummary,
                        deleteAttachments: oldSummaryId != migratedSummaryId
                    )
                }
                AppLog.shared.backgroundProcessing("Queued old summary \(oldId) for cleanup after save", level: .debug)
            }

            if !summaryIDs.isEmpty {
                do {
                    try coreDataManager.deleteSummariesAfterSave(ids: summaryIDs, effects: effects)

                    AppLog.shared.backgroundProcessing("Cleaned up \(summaryIDs.count) old summary(ies) for recording \(recordingId)", level: .debug)
                } catch {
                    // The new summary is already durable. Leave old rows and
                    // their attachments for a later reconcile rather than
                    // reporting a false primary-save failure.
                    AppLog.shared.backgroundProcessing(
                        "Failed to clean up \(summaryIDs.count) old summary(ies) for recording \(recordingId); " +
                        "keeping them locally and in iCloud: \(error)",
                        level: .error
                    )
                }
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
