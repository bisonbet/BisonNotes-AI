//
//  DataMigrationManager.swift
//  Audio Journal
//
//  Created by Kiro on 8/1/25.
//

import Foundation
import CoreData
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Data Integrity Structures

struct DataIntegrityReport {
    var orphanedRecordings: [OrphanedRecording] = []
    var orphanedFiles: [OrphanedFile] = []
    var brokenRelationships: [BrokenRelationship] = []
    var missingAudioFiles: [MissingAudioFile] = []
    var duplicateEntries: [DuplicateEntry] = []

    var hasIssues: Bool {
        return !orphanedRecordings.isEmpty || !orphanedFiles.isEmpty ||
               !brokenRelationships.isEmpty || !missingAudioFiles.isEmpty ||
               !duplicateEntries.isEmpty
    }

    var totalIssues: Int {
        return orphanedRecordings.count + orphanedFiles.count +
               brokenRelationships.count + missingAudioFiles.count +
               duplicateEntries.count
    }
}

struct DataRepairResults {
    var repairedOrphanedRecordings: Int = 0
    var importedOrphanedFiles: Int = 0
    var repairedRelationships: Int = 0
    var cleanedMissingFiles: Int = 0

    var totalRepairs: Int {
        return repairedOrphanedRecordings + importedOrphanedFiles +
               repairedRelationships + cleanedMissingFiles
    }
}

struct OrphanedRecording {
    let recording: RecordingEntry
    let issues: [String]
}

struct OrphanedFile {
    let fileURL: URL
    let type: OrphanedFileType
    let baseName: String
}

enum OrphanedFileType {
    case transcript
    case summary
}

struct BrokenRelationship {
    let type: BrokenRelationshipType
    let transcriptId: UUID?
    let summaryId: UUID?
    let recordingId: UUID?
}

enum BrokenRelationshipType {
    case transcriptMissingRecording
    case summaryMissingRecording
}

struct MissingAudioFile {
    let recording: RecordingEntry
    let expectedPath: String
}

struct DuplicateEntry {
    let type: DuplicateEntryType
    let name: String
    let count: Int
    let entries: [NSManagedObjectID]
}

enum DuplicateEntryType {
    case recording
}

@MainActor
class DataMigrationManager: ObservableObject {
    private let persistenceController: PersistenceController
    private let context: NSManagedObjectContext
    private var configurediCloudStorageManager: iCloudStorageManager?

    @Published var migrationProgress: Double = 0.0
    @Published var migrationStatus: String = ""
    @Published var isCompleted: Bool = false

    init(persistenceController: PersistenceController? = nil,
         iCloudStorageManager: iCloudStorageManager? = nil) {
        let resolvedPersistenceController = persistenceController ?? PersistenceController.shared
        self.persistenceController = resolvedPersistenceController
        self.context = resolvedPersistenceController.container.viewContext
        self.configurediCloudStorageManager = iCloudStorageManager
    }

    func setCloudSyncManagers(legacy: iCloudStorageManager? = nil) {
        if let legacy = legacy {
            self.configurediCloudStorageManager = legacy
        }
    }

    private var cloudDeletionManager: iCloudStorageManager {
        configurediCloudStorageManager ?? iCloudStorageManager.shared
    }

    // MARK: - Deletion Markers
    //
    // A deletion marker is durable and says the *user* deleted something, so it
    // travels to every device and outlives the row it describes. Only
    // clearAllCoreData raises one from this file: the user asked for the store to
    // be emptied, and without markers the next reconcile would restore it.
    //
    // Repair and de-duplication deliberately do not. A local file this device
    // cannot see is not a deletion, an orphaned row is a local inconsistency, and
    // CLAUDE.md is explicit that superseded duplicates are pruned "never with a
    // tombstone, because every device derives the same winner from the same
    // data". Publishing one from any of those would delete a healthy copy from
    // every other device over a problem local to this one.

    private func enqueueTranscriptDeletion(_ transcript: TranscriptEntry) {
        guard let transcriptId = transcript.id else { return }
        cloudDeletionManager.enqueueTranscriptRemovalFromiCloud(
            transcriptId: transcriptId,
            recordingId: transcript.recordingId ?? transcript.recording?.id
        )
    }

    private func enqueueSummaryDeletion(_ summary: SummaryEntry) {
        guard let summaryId = summary.id else { return }
        cloudDeletionManager.enqueueSummaryRemovalFromiCloud(
            summaryId: summaryId,
            recordingId: summary.recordingId ?? summary.recording?.id
        )
    }

    private func enqueueRecordingDeletion(_ recording: RecordingEntry, includingChildren: Bool = true) {
        guard let recordingId = recording.id else { return }
        cloudDeletionManager.enqueueRecordingDeletionForiCloud(
            recordingId: recordingId,
            transcriptIds: includingChildren ? [recording.transcriptId ?? recording.transcript?.id].compactMap { $0 } : [],
            summaryIds: includingChildren ? [recording.summaryId ?? recording.summary?.id].compactMap { $0 } : []
        )
    }

    func performDataMigration() async {
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

    // MARK: - Data Recovery Methods

    func recoverDataFromiCloud() async -> (transcripts: Int, summaries: Int, errors: [String]) {
        let transcriptCount = 0 // Transcript recovery not yet implemented
        var summaryCount = 0
        var errors: [String] = []

        AppLog.shared.dataMigration("Starting iCloud data recovery")

        if let legacyManager = configurediCloudStorageManager {
            AppLog.shared.dataMigration("Using legacy iCloudStorageManager for recovery")
            do {
                if !legacyManager.isEnabled {
                    AppLog.shared.dataMigration("Legacy iCloud sync is disabled", level: .error)
                    errors.append("Legacy iCloud sync is disabled - enable it in Settings")
                } else {
                    AppLog.shared.dataMigration("Fetching summaries from legacy iCloud")
                    let summaries = try await legacyManager.fetchSummariesFromiCloud()

                    if !summaries.isEmpty {
                        AppLog.shared.dataMigration("Found \(summaries.count) summaries in legacy iCloud", level: .debug)

                        // Create Core Data entries for recovered summaries
                        for summary in summaries {
                            // Check if we already have this summary
                            let summaryFetch: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
                            summaryFetch.predicate = NSPredicate(format: "id == %@", summary.id as CVarArg)

                            let existingSummaries = try context.fetch(summaryFetch)
                            if existingSummaries.isEmpty {
                                // Create new SummaryEntry
                                let summaryEntry = SummaryEntry(context: context)
                                summaryEntry.id = summary.id
                                summaryEntry.summary = summary.summary
                                summaryEntry.generatedAt = Date()

                                // Convert tasks, reminders, titles to JSON strings
                                if let tasksData = try? JSONEncoder().encode(summary.tasks),
                                   let tasksString = String(data: tasksData, encoding: .utf8) {
                                    summaryEntry.tasks = tasksString
                                }
                                if let remindersData = try? JSONEncoder().encode(summary.reminders),
                                   let remindersString = String(data: remindersData, encoding: .utf8) {
                                    summaryEntry.reminders = remindersString
                                }
                                if let titlesData = try? JSONEncoder().encode(summary.titles),
                                   let titlesString = String(data: titlesData, encoding: .utf8) {
                                    summaryEntry.titles = titlesString
                                }

                                summaryEntry.contentType = summary.contentType.rawValue
                                summaryEntry.aiMethod = SummaryMetadataCodec.encode(aiEngine: summary.aiEngine, aiModel: summary.aiModel)
                                summaryEntry.originalLength = Int32(summary.originalLength)
                                summaryEntry.processingTime = summary.processingTime
                                summaryEntry.recordingId = summary.recordingId
                                summaryEntry.transcriptId = summary.transcriptId

                                summaryCount += 1
                                AppLog.shared.dataMigration("Recovered summary for recording ID: \(summary.recordingId?.uuidString ?? "nil")")
                            } else {
                                AppLog.shared.dataMigration("Summary already exists for recording ID: \(summary.recordingId?.uuidString ?? "nil")", level: .debug)
                            }
                        }

                        // Save the context
                        try context.save()
                        AppLog.shared.dataMigration("Saved \(summaryCount) recovered summaries to Core Data")

                    } else {
                        AppLog.shared.dataMigration("No summaries found in legacy iCloud")
                    }
                }
            } catch {
                AppLog.shared.dataMigration("Legacy iCloud recovery failed: \(error)", level: .error)
                errors.append("Legacy iCloud error: \(error.localizedDescription)")
            }
        }

        // No iCloud managers available
        else {
            AppLog.shared.dataMigration("No iCloud sync managers available", level: .error)
            errors.append("No iCloud sync manager available - it needs to be passed to DataMigrationManager")
        }

        AppLog.shared.dataMigration("Recovery results: \(transcriptCount) transcripts, \(summaryCount) summaries recovered")
        return (transcriptCount, summaryCount, errors)
    }

    // MARK: - Utility Methods

    func clearAllCoreData() async {
        let recordings = (try? context.fetch(RecordingEntry.fetchRequest())) ?? []
        let transcripts = (try? context.fetch(TranscriptEntry.fetchRequest())) ?? []
        let summaries = (try? context.fetch(SummaryEntry.fetchRequest())) ?? []

        // Batch deletes bypass Core Data relationship callbacks, so the tombstones
        // are raised here rather than through the usual delete paths. They are
        // raised only once the store is actually empty: queueing first and then
        // failing the delete would wipe iCloud while the local rows survived.
        let entities = ["RecordingEntry", "TranscriptEntry", "SummaryEntry"]
        var clearedEveryEntity = true

        for entityName in entities {
            let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)

            do {
                try context.execute(deleteRequest)
                AppLog.shared.dataMigration("Cleared all \(entityName) entries")
            } catch {
                clearedEveryEntity = false
                AppLog.shared.dataMigration("Error clearing \(entityName): \(error)", level: .error)
            }
        }

        do {
            try context.save()
            AppLog.shared.dataMigration("Core Data cleared successfully")
        } catch {
            AppLog.shared.dataMigration("Error saving after clearing Core Data: \(error)", level: .error)
            context.rollback()
            return
        }

        guard clearedEveryEntity else {
            AppLog.shared.dataMigration(
                "Store only partly cleared; withholding iCloud tombstones so a retry is still possible",
                level: .error
            )
            return
        }

        recordings.forEach { enqueueRecordingDeletion($0) }
        transcripts.forEach { enqueueTranscriptDeletion($0) }
        summaries.forEach { enqueueSummaryDeletion($0) }

        // The batch delete bypassed relationship callbacks, so every attachment
        // folder is now unreachable.
        SummaryAttachmentStore.shared.pruneOrphans(against: context)
    }

    func debugCoreDataContents() async {
        // Check recordings
        let recordingFetch: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        do {
            let recordings = try context.fetch(recordingFetch)
            AppLog.shared.dataMigration("Core Data contains \(recordings.count) recordings", level: .debug)
            for recording in recordings {
                AppLog.shared.dataMigration("  Recording ID: \(recording.id?.uuidString ?? "nil") - hasTranscript: \(recording.transcript != nil), hasSummary: \(recording.summary != nil)", level: .debug)
            }
        } catch {
            AppLog.shared.dataMigration("Error fetching recordings: \(error)", level: .error)
        }

        // Check transcripts
        let transcriptFetch: NSFetchRequest<TranscriptEntry> = TranscriptEntry.fetchRequest()
        do {
            let transcripts = try context.fetch(transcriptFetch)
            AppLog.shared.dataMigration("Core Data contains \(transcripts.count) transcripts", level: .debug)
        } catch {
            AppLog.shared.dataMigration("Error fetching transcripts: \(error)", level: .error)
        }

        // Check summaries
        let summaryFetch: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
        do {
            let summaries = try context.fetch(summaryFetch)
            AppLog.shared.dataMigration("Core Data contains \(summaries.count) summaries", level: .debug)
        } catch {
            AppLog.shared.dataMigration("Error fetching summaries: \(error)", level: .error)
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

    // MARK: - Enhanced Data Repair Functionality

    func performDataIntegrityCheck() async -> DataIntegrityReport {
        AppLog.shared.dataMigration("Starting comprehensive data integrity check")
        migrationStatus = "Checking data integrity..."
        migrationProgress = 0.0

        var report = DataIntegrityReport()

        // Step 1: Check for orphaned recordings (missing transcript/summary files)
        migrationStatus = "Checking for orphaned recordings..."
        report.orphanedRecordings = await findOrphanedRecordings()
        migrationProgress = 0.2

        // Step 2: Check for orphaned transcript/summary files
        migrationStatus = "Checking for orphaned files..."
        report.orphanedFiles = await findOrphanedFiles()
        migrationProgress = 0.4

        // Step 3: Check for broken relationships
        migrationStatus = "Checking database relationships..."
        report.brokenRelationships = await findBrokenRelationships()
        migrationProgress = 0.6

        // Step 4: Check for missing audio files
        migrationStatus = "Checking for missing audio files..."
        report.missingAudioFiles = await findMissingAudioFiles()
        migrationProgress = 0.8

        // Step 5: Check for duplicate entries
        migrationStatus = "Checking for duplicates..."
        report.duplicateEntries = await findDuplicateEntries()
        migrationProgress = 1.0

        migrationStatus = "Integrity check completed"

        return report
    }

    func repairDataIntegrityIssues(report: DataIntegrityReport) async -> DataRepairResults {
        AppLog.shared.dataMigration("Starting data repair process")
        migrationStatus = "Repairing data integrity issues..."
        migrationProgress = 0.0

        var results = DataRepairResults()

        do {
            // Step 1: Repair orphaned recordings
            migrationStatus = "Repairing orphaned recordings..."
            results.repairedOrphanedRecordings = await repairOrphanedRecordings(report.orphanedRecordings)
            migrationProgress = 0.25

            // Step 2: Import orphaned files
            migrationStatus = "Importing orphaned files..."
            results.importedOrphanedFiles = await importOrphanedFiles(report.orphanedFiles)
            migrationProgress = 0.5

            // Step 3: Repair broken relationships
            migrationStatus = "Repairing broken relationships..."
            results.repairedRelationships = await repairBrokenRelationships(report.brokenRelationships)
            migrationProgress = 0.75

            // Step 4: Remove entries with missing audio files
            migrationStatus = "Cleaning up missing audio files..."
            results.cleanedMissingFiles = await cleanupMissingAudioFiles(report.missingAudioFiles)

        // One sweep after the repairs, rather than per delete site: cascade
        // deletes never run our code, so reconciling against the store is the
        // only way to catch every folder left behind.
        SummaryAttachmentStore.shared.pruneOrphans(against: context)
            migrationProgress = 0.9

            // Step 5: Save changes
            migrationStatus = "Saving repairs..."
            try context.save()
            migrationProgress = 1.0

            migrationStatus = "Data repair completed successfully!"
            AppLog.shared.dataMigration("Data repair completed successfully")

        } catch {
            AppLog.shared.dataMigration("Data repair failed: \(error)", level: .error)
            migrationStatus = "Data repair failed: \(error.localizedDescription)"
        }

        return results
    }

    private func findOrphanedRecordings() async -> [OrphanedRecording] {
        var orphaned: [OrphanedRecording] = []

        let recordingFetch: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        do {
            let recordings = try context.fetch(recordingFetch)
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

            for recording in recordings {
                guard let recordingName = recording.recordingName else { continue }

                var issues: [String] = []

                // Check if transcript file exists but no transcript relationship
                if recording.transcript == nil {
                    let transcriptFile = documentsPath.appendingPathComponent("\(recordingName).transcript")
                    if FileManager.default.fileExists(atPath: transcriptFile.path) {
                        issues.append("Has transcript file but no transcript relationship")
                    }
                }

                // Check if summary file exists but no summary relationship
                if recording.summary == nil {
                    let summaryFile = documentsPath.appendingPathComponent("\(recordingName).summary")
                    if FileManager.default.fileExists(atPath: summaryFile.path) {
                        issues.append("Has summary file but no summary relationship")
                    }
                }

                if !issues.isEmpty {
                    orphaned.append(OrphanedRecording(
                        recording: recording,
                        issues: issues
                    ))
                }
            }
        } catch {
            AppLog.shared.dataMigration("Error finding orphaned recordings: \(error)", level: .error)
        }

        AppLog.shared.dataMigration("Found \(orphaned.count) orphaned recordings", level: .debug)
        return orphaned
    }

    private func findOrphanedFiles() async -> [OrphanedFile] {
        var orphaned: [OrphanedFile] = []

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: nil, options: [])

            // Check transcript files
            let transcriptFiles = fileURLs.filter { $0.pathExtension.lowercased() == "transcript" }
            for transcriptFile in transcriptFiles {
                let baseName = transcriptFile.deletingPathExtension().lastPathComponent

                // Check if there's a corresponding recording
                let recordingFetch: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
                recordingFetch.predicate = NSPredicate(format: "recordingName == %@", baseName)

                let recordings = try context.fetch(recordingFetch)
                if recordings.isEmpty {
                    orphaned.append(OrphanedFile(
                        fileURL: transcriptFile,
                        type: .transcript,
                        baseName: baseName
                    ))
                }
            }

            // Check summary files
            let summaryFiles = fileURLs.filter { $0.pathExtension.lowercased() == "summary" }
            for summaryFile in summaryFiles {
                let baseName = summaryFile.deletingPathExtension().lastPathComponent

                // Check if there's a corresponding recording
                let recordingFetch: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
                recordingFetch.predicate = NSPredicate(format: "recordingName == %@", baseName)

                let recordings = try context.fetch(recordingFetch)
                if recordings.isEmpty {
                    orphaned.append(OrphanedFile(
                        fileURL: summaryFile,
                        type: .summary,
                        baseName: baseName
                    ))
                }
            }

        } catch {
            AppLog.shared.dataMigration("Error finding orphaned files: \(error)", level: .error)
        }

        AppLog.shared.dataMigration("Found \(orphaned.count) orphaned files", level: .debug)
        return orphaned
    }

    private func findBrokenRelationships() async -> [BrokenRelationship] {
        var broken: [BrokenRelationship] = []

        // Check transcripts with missing recordings
        let transcriptFetch: NSFetchRequest<TranscriptEntry> = TranscriptEntry.fetchRequest()
        do {
            let transcripts = try context.fetch(transcriptFetch)
            for transcript in transcripts {
                if transcript.recording == nil {
                    broken.append(BrokenRelationship(
                        type: .transcriptMissingRecording,
                        transcriptId: transcript.id,
                        summaryId: nil,
                        recordingId: transcript.recordingId
                    ))
                }
            }
        } catch {
            AppLog.shared.dataMigration("Error checking transcript relationships: \(error)", level: .error)
        }

        // Check summaries with missing recordings
        let summaryFetch: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
        do {
            let summaries = try context.fetch(summaryFetch)
            for summary in summaries {
                if summary.recording == nil {
                    broken.append(BrokenRelationship(
                        type: .summaryMissingRecording,
                        transcriptId: summary.transcriptId,
                        summaryId: summary.id,
                        recordingId: summary.recordingId
                    ))
                }
            }
        } catch {
            AppLog.shared.dataMigration("Error checking summary relationships: \(error)", level: .error)
        }

        AppLog.shared.dataMigration("Found \(broken.count) broken relationships", level: .debug)
        return broken
    }

    private func findMissingAudioFiles() async -> [MissingAudioFile] {
        var missing: [MissingAudioFile] = []

        let recordingFetch: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        do {
            let recordings = try context.fetch(recordingFetch)

            for recording in recordings {
                guard let urlString = recording.recordingURL else { continue }

                // Properly resolve the file path using the same logic as CoreDataManager
                let fileURL: URL?

                // Check if it's an absolute URL (legacy format)
                if let url = URL(string: urlString), url.scheme != nil {
                    fileURL = url
                } else {
                    // It's a relative path, convert to absolute URL
                    fileURL = relativePathToURL(urlString)
                }

                guard let resolvedURL = fileURL else {
                    AppLog.shared.dataMigration("Could not resolve URL for recording ID: \(recording.id?.uuidString ?? "nil")", level: .error)
                    missing.append(MissingAudioFile(
                        recording: recording,
                        expectedPath: urlString
                    ))
                    continue
                }

                if !FileManager.default.fileExists(atPath: resolvedURL.path) {
                    missing.append(MissingAudioFile(
                        recording: recording,
                        expectedPath: resolvedURL.path
                    ))
                }
            }
        } catch {
            AppLog.shared.dataMigration("Error checking for missing audio files: \(error)", level: .error)
        }

        AppLog.shared.dataMigration("Found \(missing.count) recordings with missing audio files", level: .debug)
        return missing
    }

    /// Converts a relative path back to an absolute URL (matching CoreDataManager logic)
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

    private func findDuplicateEntries() async -> [DuplicateEntry] {
        var duplicates: [DuplicateEntry] = []

        // Check for duplicate recordings by name
        let recordingFetch: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        recordingFetch.sortDescriptors = [NSSortDescriptor(key: "recordingName", ascending: true)]

        do {
            let recordings = try context.fetch(recordingFetch)
            var nameGroups: [String: [RecordingEntry]] = [:]

            for recording in recordings {
                guard let name = recording.recordingName else { continue }
                nameGroups[name, default: []].append(recording)
            }

            for (name, group) in nameGroups where group.count > 1 {
                duplicates.append(DuplicateEntry(
                    type: .recording,
                    name: name,
                    count: group.count,
                    entries: group.map { $0.objectID }
                ))
            }
        } catch {
            AppLog.shared.dataMigration("Error checking for duplicate recordings: \(error)", level: .error)
        }

        AppLog.shared.dataMigration("Found \(duplicates.count) sets of duplicate entries", level: .debug)
        return duplicates
    }

    private func repairOrphanedRecordings(_ orphaned: [OrphanedRecording]) async -> Int {
        var repaired = 0

        for orphanedItem in orphaned {
            let recording = orphanedItem.recording
            guard let recordingName = recording.recordingName else { continue }

            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

            // Try to link transcript
            if recording.transcript == nil {
                let transcriptFile = documentsPath.appendingPathComponent("\(recordingName).transcript")
                if FileManager.default.fileExists(atPath: transcriptFile.path) {
                    await createTranscriptEntry(transcriptFile: transcriptFile, recordingEntry: recording)
                    repaired += 1
                }
            }

            // Try to link summary
            if recording.summary == nil {
                let summaryFile = documentsPath.appendingPathComponent("\(recordingName).summary")
                if FileManager.default.fileExists(atPath: summaryFile.path) {
                    await createSummaryEntry(summaryFile: summaryFile, recordingEntry: recording)
                    repaired += 1
                }
            }
        }

        AppLog.shared.dataMigration("Repaired \(repaired) orphaned recording relationships")
        return repaired
    }

    private func importOrphanedFiles(_ orphaned: [OrphanedFile]) async -> Int {
        var imported = 0

        for orphanedFile in orphaned {
            // Try to find a matching audio file for this orphaned transcript/summary
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

            do {
                let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: nil, options: [])
                let audioFiles = fileURLs.filter { url in
                    ["m4a", "mp3", "wav", "aac"].contains(url.pathExtension.lowercased())
                }

                // Look for audio file with matching base name
                if let matchingAudio = audioFiles.first(where: { $0.deletingPathExtension().lastPathComponent == orphanedFile.baseName }) {
                    // Create recording entry for this audio file
                    await createRecordingEntry(audioFile: matchingAudio, transcriptFiles: orphanedFile.type == .transcript ? [orphanedFile.fileURL] : [], summaryFiles: orphanedFile.type == .summary ? [orphanedFile.fileURL] : [])
                    imported += 1
                }
            } catch {
                AppLog.shared.dataMigration("Error importing orphaned file: \(error)", level: .error)
            }
        }

        AppLog.shared.dataMigration("Imported \(imported) orphaned files")
        return imported
    }

    private func repairBrokenRelationships(_ broken: [BrokenRelationship]) async -> Int {
        var repaired = 0

        for relationship in broken {
            switch relationship.type {
            case .transcriptMissingRecording:
                if let transcriptId = relationship.transcriptId,
                   let recordingId = relationship.recordingId {

                    // Find the transcript
                    let transcriptFetch: NSFetchRequest<TranscriptEntry> = TranscriptEntry.fetchRequest()
                    transcriptFetch.predicate = NSPredicate(format: "id == %@", transcriptId as CVarArg)

                    // Find the recording
                    let recordingFetch: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
                    recordingFetch.predicate = NSPredicate(format: "id == %@", recordingId as CVarArg)

                    do {
                        let transcripts = try context.fetch(transcriptFetch)
                        let recordings = try context.fetch(recordingFetch)

                        if let transcript = transcripts.first, let recording = recordings.first {
                            transcript.recording = recording
                            recording.transcript = transcript
                            recording.transcriptId = transcriptId
                            recording.transcriptionStatus = "Completed"
                            repaired += 1
                        }
                    } catch {
                        AppLog.shared.dataMigration("Error repairing transcript relationship: \(error)", level: .error)
                    }
                }

            case .summaryMissingRecording:
                if let summaryId = relationship.summaryId,
                   let recordingId = relationship.recordingId {

                    // Find the summary
                    let summaryFetch: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
                    summaryFetch.predicate = NSPredicate(format: "id == %@", summaryId as CVarArg)

                    // Find the recording
                    let recordingFetch: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
                    recordingFetch.predicate = NSPredicate(format: "id == %@", recordingId as CVarArg)

                    do {
                        let summaries = try context.fetch(summaryFetch)
                        let recordings = try context.fetch(recordingFetch)

                        if let summary = summaries.first, let recording = recordings.first {
                            summary.recording = recording
                            recording.summary = summary
                            recording.summaryId = summaryId
                            recording.summaryStatus = "Completed"

                            // Also link to transcript if available
                            if let transcriptId = relationship.transcriptId {
                                let transcriptFetch: NSFetchRequest<TranscriptEntry> = TranscriptEntry.fetchRequest()
                                transcriptFetch.predicate = NSPredicate(format: "id == %@", transcriptId as CVarArg)

                                if let transcript = try context.fetch(transcriptFetch).first {
                                    summary.transcript = transcript
                                }
                            }

                            repaired += 1
                        }
                    } catch {
                        AppLog.shared.dataMigration("Error repairing summary relationship: \(error)", level: .error)
                    }
                }
            }
        }

        AppLog.shared.dataMigration("Repaired \(repaired) broken relationships")
        return repaired
    }

    private func cleanupMissingAudioFiles(_ missing: [MissingAudioFile]) async -> Int {
        var cleaned = 0

        for missingFile in missing {
            // Remove the recording entry and its associated transcript/summary
            if let transcript = missingFile.recording.transcript {
                context.delete(transcript)
            }
            if let summary = missingFile.recording.summary {
                context.delete(summary)
            }
            context.delete(missingFile.recording)
            cleaned += 1
        }

        AppLog.shared.dataMigration("Cleaned up \(cleaned) recordings with missing audio files")
        return cleaned
    }

}
