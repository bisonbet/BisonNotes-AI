//
//  DataMigrationManager.swift
//  Audio Journal
//
//  Created by Kiro on 8/1/25.
//

import Foundation
import CoreData
import AVFoundation

@MainActor
class DataMigrationManager: ObservableObject {
    private let persistenceController: PersistenceController
    private let context: NSManagedObjectContext

    @Published var migrationProgress: Double = 0.0
    @Published var migrationStatus: String = ""
    @Published var isCompleted: Bool = false

    init(persistenceController: PersistenceController? = nil) {
        let resolvedPersistenceController = persistenceController ?? PersistenceController.shared
        self.persistenceController = resolvedPersistenceController
        self.context = resolvedPersistenceController.container.viewContext
    }

    func performDataMigration() async {
        guard persistenceController.storeState.isOperational else {
            AppLog.shared.dataMigration("Data migration withheld: local storage is unavailable", level: .fault)
            return
        }
        AppLog.shared.dataMigration("Starting data migration")
        migrationStatus = "Starting migration..."
        migrationProgress = 0.0

        do {
            // Step 1: Scan for audio files
            migrationStatus = "Scanning for audio files..."
            let audioFiles = await scanForAudioFiles()
            migrationProgress = 0.2

            // Step 2: Scan for transcript files
            migrationStatus = "Scanning for transcript files..."
            let transcriptFiles = await scanForTranscriptFiles()
            migrationProgress = 0.4

            // Step 3: Scan for summary files
            migrationStatus = "Scanning for summary files..."
            let summaryFiles = await scanForSummaryFiles()
            migrationProgress = 0.6

            // Step 4: Create Core Data entries
            migrationStatus = "Creating database entries..."
            await createCoreDataEntries(audioFiles: audioFiles, transcriptFiles: transcriptFiles, summaryFiles: summaryFiles)
            migrationProgress = 0.8

            // Step 5: Save context
            migrationStatus = "Saving to database..."
            try context.save()
            migrationProgress = 1.0

            migrationStatus = "Migration completed successfully!"
            isCompleted = true
            AppLog.shared.dataMigration("Data migration completed successfully")

        } catch {
            AppLog.shared.dataMigration("Data migration failed: \(error)", level: .error)
            migrationStatus = "Migration failed: \(error.localizedDescription)"
        }
    }

    private func scanForAudioFiles() async -> [URL] {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: documentsPath,
                includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
                options: []
            )

            let audioFiles = fileURLs.filter { url in
                ["m4a", "mp3", "wav", "aac"].contains(url.pathExtension.lowercased())
            }

            AppLog.shared.dataMigration("Found \(audioFiles.count) audio files", level: .debug)
            return audioFiles

        } catch {
            AppLog.shared.dataMigration("Error scanning for audio files: \(error)", level: .error)
            return []
        }
    }

    private func scanForTranscriptFiles() async -> [URL] {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: nil, options: [])
            let transcriptFiles = fileURLs.filter { $0.pathExtension.lowercased() == "transcript" }

            AppLog.shared.dataMigration("Found \(transcriptFiles.count) transcript files", level: .debug)
            return transcriptFiles

        } catch {
            AppLog.shared.dataMigration("Error scanning for transcript files: \(error)", level: .error)
            return []
        }
    }

    private func scanForSummaryFiles() async -> [URL] {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: nil, options: [])
            let summaryFiles = fileURLs.filter { $0.pathExtension.lowercased() == "summary" }

            AppLog.shared.dataMigration("Found \(summaryFiles.count) summary files", level: .debug)
            return summaryFiles

        } catch {
            AppLog.shared.dataMigration("Error scanning for summary files: \(error)", level: .error)
            return []
        }
    }

    private func createCoreDataEntries(audioFiles: [URL], transcriptFiles: [URL], summaryFiles: [URL]) async {
        for audioFile in audioFiles {
            await createRecordingEntry(audioFile: audioFile, transcriptFiles: transcriptFiles, summaryFiles: summaryFiles)
        }
    }

    private func createRecordingEntry(audioFile: URL, transcriptFiles: [URL], summaryFiles: [URL]) async {
        // Check if recording already exists
        let recordingName = audioFile.deletingPathExtension().lastPathComponent
        let fetchRequest: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "recordingName == %@", recordingName)

        do {
            let existingRecordings = try context.fetch(fetchRequest)
            if !existingRecordings.isEmpty {
                AppLog.shared.dataMigration("Recording already exists, skipping", level: .debug)
                return
            }
        } catch {
            AppLog.shared.dataMigration("Error checking for existing recording: \(error)", level: .error)
            return
        }

        // Create new recording entry
        let recordingEntry = RecordingEntry(context: context)
        recordingEntry.id = UUID()
        // Use imported file naming convention for migrated files
        recordingEntry.recordingName = AudioRecorderViewModel.generateImportedFileName(originalName: recordingName)
        // Store relative path instead of absolute URL for resilience across app launches
        recordingEntry.recordingURL = urlToRelativePath(audioFile)

        // Get file metadata
        do {
            let resourceValues = try audioFile.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
            recordingEntry.recordingDate = resourceValues.creationDate ?? Date()
            recordingEntry.createdAt = resourceValues.creationDate ?? Date()
            recordingEntry.lastModified = Date()
            recordingEntry.fileSize = Int64(resourceValues.fileSize ?? 0)

            // Get duration
            let duration = await getAudioDuration(url: audioFile)
            recordingEntry.duration = duration

        } catch {
            AppLog.shared.dataMigration("Error getting file metadata: \(error)", level: .error)
            recordingEntry.recordingDate = Date()
            recordingEntry.createdAt = Date()
            recordingEntry.lastModified = Date()
            recordingEntry.fileSize = 0
            recordingEntry.duration = 0
        }

        // Set default values
        recordingEntry.audioQuality = "high"
        recordingEntry.transcriptionStatus = "Not Started"
        recordingEntry.summaryStatus = "Not Started"

        // Check for location data file
        let locationFile = audioFile.deletingPathExtension().appendingPathExtension("location")
        if FileManager.default.fileExists(atPath: locationFile.path) {
            do {
                let locationData = try Data(contentsOf: locationFile)
                let location = try JSONDecoder().decode(LocationData.self, from: locationData)

                recordingEntry.locationLatitude = location.latitude
                recordingEntry.locationLongitude = location.longitude
                recordingEntry.locationTimestamp = location.timestamp
                recordingEntry.locationAccuracy = location.accuracy ?? 0.0
                recordingEntry.locationAddress = location.address

                AppLog.shared.dataMigration("Location data migrated for recording", level: .debug)
            } catch {
                AppLog.shared.dataMigration("Error migrating location data: \(error)", level: .error)
            }
        }

        // Look for matching transcript
        let transcriptFile = transcriptFiles.first { transcriptURL in
            transcriptURL.deletingPathExtension().lastPathComponent == recordingName
        }

        if let transcriptFile = transcriptFile {
            await createTranscriptEntry(transcriptFile: transcriptFile, recordingEntry: recordingEntry)
        }

        // Look for matching summary
        let summaryFile = summaryFiles.first { summaryURL in
            summaryURL.deletingPathExtension().lastPathComponent == recordingName
        }

        if let summaryFile = summaryFile {
            await createSummaryEntry(summaryFile: summaryFile, recordingEntry: recordingEntry)
        }

        AppLog.shared.dataMigration("Created recording entry")
    }

    private func createTranscriptEntry(transcriptFile: URL, recordingEntry: RecordingEntry) async {
        do {
            let transcriptData = try Data(contentsOf: transcriptFile)
            let transcript = try JSONDecoder().decode(TranscriptData.self, from: transcriptData)

            let transcriptEntry = TranscriptEntry(context: context)
            transcriptEntry.id = transcript.id
            transcriptEntry.recordingId = recordingEntry.id
            transcriptEntry.createdAt = transcript.createdAt
            transcriptEntry.lastModified = transcript.lastModified
            transcriptEntry.engine = transcript.engine?.rawValue
            transcriptEntry.processingTime = transcript.processingTime
            transcriptEntry.confidence = transcript.confidence

            // Store segments as JSON
            if let segmentsData = try? JSONEncoder().encode(transcript.segments) {
                transcriptEntry.segments = String(data: segmentsData, encoding: .utf8)
            }

            // Store speaker mappings as JSON
            if let speakerData = try? JSONEncoder().encode(transcript.speakerMappings) {
                transcriptEntry.speakerMappings = String(data: speakerData, encoding: .utf8)
            }

            // Link to recording
            transcriptEntry.recording = recordingEntry
            recordingEntry.transcript = transcriptEntry
            recordingEntry.transcriptId = transcript.id
            recordingEntry.transcriptionStatus = "Completed"

            AppLog.shared.dataMigration("Created transcript entry for recording ID: \(recordingEntry.id?.uuidString ?? "nil")")

        } catch {
            AppLog.shared.dataMigration("Error creating transcript entry: \(error)", level: .error)
        }
    }

    private func createSummaryEntry(summaryFile: URL, recordingEntry: RecordingEntry) async {
        do {
            let summaryData = try Data(contentsOf: summaryFile)
            let summary = try JSONDecoder().decode(EnhancedSummaryData.self, from: summaryData)

            let summaryEntry = SummaryEntry(context: context)
            summaryEntry.id = summary.id
            summaryEntry.recordingId = recordingEntry.id
            summaryEntry.transcriptId = summary.transcriptId
            summaryEntry.generatedAt = summary.generatedAt
            summaryEntry.aiMethod = SummaryMetadataCodec.encode(aiEngine: summary.aiEngine, aiModel: summary.aiModel)
            summaryEntry.processingTime = summary.processingTime
            summaryEntry.confidence = summary.confidence
            summaryEntry.summary = summary.summary
            summaryEntry.contentType = summary.contentType.rawValue
            summaryEntry.wordCount = Int32(summary.wordCount)
            summaryEntry.originalLength = Int32(summary.originalLength)
            summaryEntry.compressionRatio = summary.compressionRatio
            summaryEntry.version = Int32(summary.version)

            // Store structured data as JSON
            if let titlesData = try? JSONEncoder().encode(summary.titles) {
                summaryEntry.titles = String(data: titlesData, encoding: .utf8)
            }
            if let tasksData = try? JSONEncoder().encode(summary.tasks) {
                summaryEntry.tasks = String(data: tasksData, encoding: .utf8)
            }
            if let remindersData = try? JSONEncoder().encode(summary.reminders) {
                summaryEntry.reminders = String(data: remindersData, encoding: .utf8)
            }

            // Link to recording
            summaryEntry.recording = recordingEntry
            recordingEntry.summary = summaryEntry
            recordingEntry.summaryId = summary.id
            recordingEntry.summaryStatus = "Completed"

            // Link to transcript if available
            if let transcriptEntry = recordingEntry.transcript {
                summaryEntry.transcript = transcriptEntry
            }

            AppLog.shared.dataMigration("Created summary entry for recording ID: \(recordingEntry.id?.uuidString ?? "nil")")

        } catch {
            AppLog.shared.dataMigration("Error creating summary entry: \(error)", level: .error)
        }
    }

    private func getAudioDuration(url: URL) async -> TimeInterval {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            return player.duration
        } catch {
            AppLog.shared.dataMigration("Error getting audio duration: \(error)", level: .error)
            return 0.0
        }
    }

    // MARK: - Utility Methods

    func clearAllCoreData() async {
        // Every entity is read before anything is staged, and a failure on any one
        // of them abandons the whole clear. `try?` turned a transient fetch failure
        // into an empty collection, so a clear could delete transcripts and
        // summaries, tombstone them for every other device, leave the recordings
        // behind, and still log success.
        let recordings: [RecordingEntry]
        let transcripts: [TranscriptEntry]
        let summaries: [SummaryEntry]
        do {
            recordings = try context.fetch(RecordingEntry.fetchRequest())
            transcripts = try context.fetch(TranscriptEntry.fetchRequest())
            summaries = try context.fetch(SummaryEntry.fetchRequest())
        } catch {
            AppLog.shared.dataMigration(
                "Could not read every entity to clear; nothing was deleted so the clear can be retried: \(error)",
                level: .error
            )
            return
        }
        let deletionDate = Date()
        var effects = DeferredDeletionEffects()

        for recording in recordings {
            effects.stage(recording: recording, requestedAt: deletionDate)
        }
        for transcript in transcripts {
            effects.stage(transcript: transcript, requestedAt: deletionDate)
        }
        for summary in summaries {
            effects.stage(summary: summary, requestedAt: deletionDate)
        }

        // Regular context deletes keep the local rows and their outbox intents in
        // the same SQLite transaction. A batch delete executes independently of
        // the context save and would reopen the crash window this outbox closes.
        transcripts.forEach { context.delete($0) }
        summaries.forEach { context.delete($0) }
        recordings.forEach { context.delete($0) }

        do {
            let coreDataManager = CoreDataManager(persistenceController: persistenceController)
            try coreDataManager.save(committing: effects)
            AppLog.shared.dataMigration(
                "Cleared all Core Data entries and staged \(recordings.count) recording deletion marker(s)"
            )
        } catch {
            AppLog.shared.dataMigration("Error clearing Core Data and staging cloud removals: \(error)", level: .error)
            return
        }

        // Every attachment folder is now unreachable; this also covers any
        // duplicate rows that were not represented by the recording relationship.
        SummaryAttachmentStore.shared.pruneOrphans(against: context)
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

}
