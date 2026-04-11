//
//  DataMigrationManager.swift
//  Audio Journal
//
//  Created by Kiro on 8/1/25.
//

import Foundation
import CoreData
import AVFoundation
import UIKit

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
    private var unifiediCloudSyncManager: UnifiediCloudSyncManager?
    private var iCloudStorageManager: iCloudStorageManager?
    
    @Published var migrationProgress: Double = 0.0
    @Published var migrationStatus: String = ""
    @Published var isCompleted: Bool = false
    
    init(persistenceController: PersistenceController = PersistenceController.shared,
         unifiediCloudSyncManager: UnifiediCloudSyncManager? = nil,
         iCloudStorageManager: iCloudStorageManager? = nil) {
        self.persistenceController = persistenceController
        self.context = persistenceController.container.viewContext
        self.unifiediCloudSyncManager = unifiediCloudSyncManager
        self.iCloudStorageManager = iCloudStorageManager
    }
    
    func setCloudSyncManagers(unified: UnifiediCloudSyncManager? = nil, legacy: iCloudStorageManager? = nil) {
        if let unified = unified {
            self.unifiediCloudSyncManager = unified
        }
        if let legacy = legacy {
            self.iCloudStorageManager = legacy
        }
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
        
        // Try UnifiediCloudSyncManager first
        if let unifiedManager = unifiediCloudSyncManager {
            AppLog.shared.dataMigration("Using UnifiediCloudSyncManager for recovery")
            do {
                if !unifiedManager.isEnabled {
                    AppLog.shared.dataMigration("Unified iCloud sync is disabled", level: .error)
                    errors.append("Unified iCloud sync is disabled - enable it in Settings")
                } else {
                    AppLog.shared.dataMigration("Fetching data from unified iCloud sync")
                    try await unifiedManager.fetchAllDataFromCloud()
                    
                    // The unified manager updates the registry, but we need Core Data entries
                    // This would need integration with the registry to create Core Data entries
                    AppLog.shared.dataMigration("Unified iCloud recovery fetched data to registry, but Core Data integration needed", level: .error)
                    errors.append("Unified iCloud recovery needs Core Data integration")
                }
            } catch {
                AppLog.shared.dataMigration("Unified iCloud recovery failed: \(error)", level: .error)
                errors.append("Unified iCloud error: \(error.localizedDescription)")
            }
        }
        
        // Try legacy iCloudStorageManager if unified is not available
        else if let legacyManager = iCloudStorageManager {
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
            errors.append("No iCloud sync managers available - they need to be passed to DataMigrationManager")
        }
        
        AppLog.shared.dataMigration("Recovery results: \(transcriptCount) transcripts, \(summaryCount) summaries recovered")
        return (transcriptCount, summaryCount, errors)
    }
    
    // MARK: - Utility Methods
    
    func clearAllCoreData() async {
        let entities = ["RecordingEntry", "TranscriptEntry", "SummaryEntry"]
        
        for entityName in entities {
            let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
            
            do {
                try context.execute(deleteRequest)
                AppLog.shared.dataMigration("Cleared all \(entityName) entries")
            } catch {
                AppLog.shared.dataMigration("Error clearing \(entityName): \(error)", level: .error)
            }
        }
        
        do {
            try context.save()
            AppLog.shared.dataMigration("Core Data cleared successfully")
        } catch {
            AppLog.shared.dataMigration("Error saving after clearing Core Data: \(error)", level: .error)
        }
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
    
    // MARK: - Enhanced Data Validation and Repair
    
    /// Performs comprehensive validation and repair of data inconsistencies
    func performComprehensiveDataRepair() async -> DataRepairResults {
        AppLog.shared.dataMigration("Starting comprehensive data repair")
        migrationStatus = "Performing comprehensive data repair..."
        migrationProgress = 0.0
        
        var results = DataRepairResults()
        
        do {
            // Step 1: Fix relationship/ID mismatches
            migrationStatus = "Fixing relationship inconsistencies..."
            let relationshipFixes = await fixRelationshipInconsistencies()
            results.repairedRelationships += relationshipFixes
            migrationProgress = 0.2
            
            // Step 2: Sync recording names with transcript/summary titles
            migrationStatus = "Syncing recording names with generated titles..."
            let nameFixes = await syncRecordingNamesWithTitles()
            results.repairedOrphanedRecordings += nameFixes
            migrationProgress = 0.4
            
            // Step 3: Convert all URLs to relative paths
            migrationStatus = "Converting URLs to relative paths..."
            let urlFixes = await convertAllURLsToRelativePaths()
            migrationProgress = 0.6
            
            // Step 4: Remove duplicate entries by resolving conflicts intelligently
            migrationStatus = "Resolving duplicate entries..."
            let duplicateFixes = await performAdvancedDuplicateResolution()
            migrationProgress = 0.8
            
            // Step 5: Save all changes
            migrationStatus = "Saving comprehensive repairs..."
            try context.save()
            migrationProgress = 1.0
            
            migrationStatus = "Comprehensive data repair completed successfully!"
            AppLog.shared.dataMigration("Comprehensive data repair completed successfully")
            AppLog.shared.dataMigration("Repair summary - relationships: \(relationshipFixes), names: \(nameFixes), URLs: \(urlFixes), duplicates: \(duplicateFixes)", level: .debug)
            
        } catch {
            AppLog.shared.dataMigration("Comprehensive data repair failed: \(error)", level: .error)
            migrationStatus = "Comprehensive data repair failed: \(error.localizedDescription)"
        }
        
        return results
    }
    
    /// Fixes inconsistencies between Core Data relationships and stored UUID attributes
    private func fixRelationshipInconsistencies() async -> Int {
        var fixedCount = 0
        
        // Fix recordings with mismatched transcript relationships
        let recordingFetch: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        do {
            let recordings = try context.fetch(recordingFetch)
            
            for recording in recordings {
                var wasFixed = false
                
                // Fix transcript relationship mismatches
                if let transcriptId = recording.transcriptId {
                    if recording.transcript == nil {
                        // Has transcriptId but no relationship - find and link transcript
                        let transcriptFetch: NSFetchRequest<TranscriptEntry> = TranscriptEntry.fetchRequest()
                        transcriptFetch.predicate = NSPredicate(format: "id == %@", transcriptId as CVarArg)
                        
                        if let transcript = try context.fetch(transcriptFetch).first {
                            recording.transcript = transcript
                            transcript.recording = recording
                            wasFixed = true
                            AppLog.shared.dataMigration("Fixed transcript relationship for recording ID: \(recording.id?.uuidString ?? "nil")", level: .debug)
                        }
                    } else if recording.transcript?.id != transcriptId {
                        // Relationship exists but ID doesn't match - sync the ID
                        recording.transcriptId = recording.transcript?.id
                        wasFixed = true
                        AppLog.shared.dataMigration("Synced transcript ID for recording ID: \(recording.id?.uuidString ?? "nil")", level: .debug)
                    }
                } else if let transcript = recording.transcript {
                    // Has relationship but no ID - sync the ID
                    recording.transcriptId = transcript.id
                    wasFixed = true
                    AppLog.shared.dataMigration("Added missing transcript ID for recording ID: \(recording.id?.uuidString ?? "nil")", level: .debug)
                }
                
                // Fix summary relationship mismatches
                if let summaryId = recording.summaryId {
                    if recording.summary == nil {
                        // Has summaryId but no relationship - find and link summary
                        let summaryFetch: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
                        summaryFetch.predicate = NSPredicate(format: "id == %@", summaryId as CVarArg)
                        
                        if let summary = try context.fetch(summaryFetch).first {
                            recording.summary = summary
                            summary.recording = recording
                            wasFixed = true
                            AppLog.shared.dataMigration("Fixed summary relationship for recording ID: \(recording.id?.uuidString ?? "nil")", level: .debug)
                        }
                    } else if recording.summary?.id != summaryId {
                        // Relationship exists but ID doesn't match - sync the ID
                        recording.summaryId = recording.summary?.id
                        wasFixed = true
                        AppLog.shared.dataMigration("Synced summary ID for recording ID: \(recording.id?.uuidString ?? "nil")", level: .debug)
                    }
                } else if let summary = recording.summary {
                    // Has relationship but no ID - sync the ID
                    recording.summaryId = summary.id
                    wasFixed = true
                    AppLog.shared.dataMigration("Added missing summary ID for recording ID: \(recording.id?.uuidString ?? "nil")", level: .debug)
                }
                
                if wasFixed {
                    recording.lastModified = Date()
                    fixedCount += 1
                }
            }
        } catch {
            AppLog.shared.dataMigration("Error fixing relationship inconsistencies: \(error)", level: .error)
        }
        
        AppLog.shared.dataMigration("Fixed \(fixedCount) relationship inconsistencies")
        return fixedCount
    }
    
    /// Syncs recording names with AI-generated titles from transcripts and summaries
    private func syncRecordingNamesWithTitles() async -> Int {
        var syncedCount = 0
        
        let recordingFetch: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        do {
            let recordings = try context.fetch(recordingFetch)
            
            for recording in recordings {
                guard let currentName = recording.recordingName else { continue }
                
                // Check if this uses the new standardized naming conventions (these are already meaningful, skip them)
                let isStandardizedName = currentName.hasPrefix("apprecording-") || 
                                         currentName.hasPrefix("importedfile-")
                if isStandardizedName {
                    AppLog.shared.dataMigration("Skipping standardized name for recording ID: \(recording.id?.uuidString ?? "nil")", level: .debug)
                    continue
                }
                
                // Check if this is a generic filename pattern (comprehensive check)
                let isGenericName = currentName.hasPrefix("recording_") || 
                                   currentName.hasPrefix("V20210426-") ||
                                   currentName.hasPrefix("V20210427-") ||
                                   currentName.contains("2025-08-") ||
                                   currentName.contains("2024-08-") ||
                                   currentName.contains("Recording_") ||
                                   currentName.hasPrefix("Recording ") ||
                                   (currentName.count > 15 && (currentName.contains("1754") || currentName.contains("2025")))
                
                if !isGenericName {
                    AppLog.shared.dataMigration("Skipping non-generic name for recording ID: \(recording.id?.uuidString ?? "nil")", level: .debug)
                    continue
                }

                var bestTitle: String?

                // First, try to get a title from the summary
                if let summary = recording.summary,
                   let titlesString = summary.titles,
                   let titlesData = titlesString.data(using: .utf8),
                   let titles = try? JSONDecoder().decode([TitleItem].self, from: titlesData) {

                    // Find the best title (highest confidence)
                    if let bestTitleItem = titles.max(by: { $0.confidence < $1.confidence }) {
                        bestTitle = bestTitleItem.text
                        AppLog.shared.dataMigration("Found summary title for recording ID: \(recording.id?.uuidString ?? "nil") (confidence: \(bestTitleItem.confidence))", level: .debug)
                    }
                }
                
                // If no good summary title, generate one from transcript
                if bestTitle == nil, let transcript = recording.transcript,
                   let segmentsString = transcript.segments,
                   let segmentsData = segmentsString.data(using: .utf8),
                   let segments = try? JSONDecoder().decode([TranscriptSegment].self, from: segmentsData) {
                    
                    let fullText = segments.map { $0.text }.joined(separator: " ")
                    if !fullText.isEmpty && fullText.count > 50 {
                        // Use the RecordingNameGenerator to create a meaningful title
                        let generatedName = RecordingNameGenerator.generateRecordingNameFromTranscript(
                            fullText, 
                            contentType: .general, 
                            tasks: [], 
                            reminders: [], 
                            titles: []
                        )
                        if !generatedName.isEmpty && generatedName != "Untitled Conversation" {
                            bestTitle = generatedName
                            AppLog.shared.dataMigration("Generated title from transcript for recording ID: \(recording.id?.uuidString ?? "nil")", level: .debug)
                        }
                    }
                }

                // Update the recording name if we found a better title
                if let newTitle = bestTitle, newTitle != currentName {
                    let validatedTitle = RecordingNameGenerator.validateAndFixRecordingName(newTitle, originalName: currentName)
                    recording.recordingName = validatedTitle
                    recording.lastModified = Date()
                    syncedCount += 1
                    AppLog.shared.dataMigration("Updated recording name for ID: \(recording.id?.uuidString ?? "nil")")
                }
            }
        } catch {
            AppLog.shared.dataMigration("Error syncing recording names: \(error)", level: .error)
        }
        
        AppLog.shared.dataMigration("Synced \(syncedCount) recording names with titles")
        return syncedCount
    }
    
    /// Converts all URLs to relative paths for container resilience
    private func convertAllURLsToRelativePaths() async -> Int {
        var convertedCount = 0
        
        let recordingFetch: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        do {
            let recordings = try context.fetch(recordingFetch)
            
            for recording in recordings {
                guard let urlString = recording.recordingURL else { continue }
                
                // Check if it's already a relative path
                if let url = URL(string: urlString), url.scheme != nil {
                    // It's an absolute URL, convert to relative path
                    if let relativePath = urlToRelativePath(url) {
                        recording.recordingURL = relativePath
                        recording.lastModified = Date()
                        convertedCount += 1
                        AppLog.shared.dataMigration("Converted URL to relative path for recording ID: \(recording.id?.uuidString ?? "nil")", level: .debug)
                    }
                }
            }
        } catch {
            AppLog.shared.dataMigration("Error converting URLs to relative paths: \(error)", level: .error)
        }
        
        AppLog.shared.dataMigration("Converted \(convertedCount) URLs to relative paths")
        return convertedCount
    }
    
    /// Intelligently resolves duplicate entries by keeping the most complete one
    private func resolveDuplicateEntries() async -> Int {
        var resolvedCount = 0
        
        // Find and resolve duplicate recordings by name
        let recordingFetch: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        recordingFetch.sortDescriptors = [NSSortDescriptor(key: "recordingName", ascending: true)]
        
        do {
            let recordings = try context.fetch(recordingFetch)
            var nameGroups: [String: [RecordingEntry]] = [:]
            
            for recording in recordings {
                guard let name = recording.recordingName else { continue }
                nameGroups[name, default: []].append(recording)
            }
            
            for (_, group) in nameGroups where group.count > 1 {
                AppLog.shared.dataMigration("Resolving \(group.count) duplicates for a recording", level: .debug)
                
                // Find the most complete recording (has both transcript and summary)
                let scored = group.map { recording in
                    var score = 0
                    if recording.transcript != nil { score += 2 }
                    if recording.summary != nil { score += 2 }
                    if recording.duration > 0 { score += 1 }
                    if recording.fileSize > 0 { score += 1 }
                    if recording.locationLatitude != 0 || recording.locationLongitude != 0 { score += 1 }
                    return (recording: recording, score: score)
                }
                
                // Keep the highest scoring recording
                let keeper = scored.max(by: { $0.score < $1.score })!.recording
                
                // Delete the others
                for duplicate in group where duplicate != keeper {
                    AppLog.shared.dataMigration("Removing duplicate recording ID: \(duplicate.id?.uuidString ?? "nil")", level: .debug)
                    context.delete(duplicate)
                    resolvedCount += 1
                }
                
                AppLog.shared.dataMigration("Kept recording with ID: \(keeper.id?.uuidString ?? "nil")", level: .debug)
            }
        } catch {
            AppLog.shared.dataMigration("Error resolving duplicate entries: \(error)", level: .error)
        }
        
        AppLog.shared.dataMigration("Resolved \(resolvedCount) duplicate entries")
        return resolvedCount
    }
    
    // MARK: - Advanced Duplicate Detection and Merging
    
    /// Detects and resolves filename-based duplicates (generic names + AI-generated titles for same audio)
    func resolveFilenameTitleDuplicates() async -> Int {
        AppLog.shared.dataMigration("Detecting filename/title duplicate pairs")
        var resolvedCount = 0
        
        let recordingFetch: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        do {
            let recordings = try context.fetch(recordingFetch)
            
            // Group recordings by potential filename patterns
            var potentialDuplicates: [(generic: RecordingEntry, titled: RecordingEntry)] = []
            
            for recording in recordings {
                guard let name = recording.recordingName else { continue }
                
                // Check if this is a generic filename pattern (exclude standardized naming conventions)
                let isStandardizedName = name.hasPrefix("apprecording-") || name.hasPrefix("importedfile-")
                let isGenericPattern = !isStandardizedName && (
                    name.hasPrefix("recording_") || 
                    name.hasPrefix("V20210426-") ||
                    name.hasPrefix("V20210427-") ||
                    (name.contains("2025-08-") && name.count > 25)
                )
                
                if isGenericPattern && (recording.transcript == nil && recording.summary == nil) {
                    // This is a generic-named recording without content
                    // Look for a titled recording that might be its duplicate
                    
                    for otherRecording in recordings {
                        guard let otherName = otherRecording.recordingName,
                              otherRecording.id != recording.id else { continue }
                        
                        // Check if the other recording has a nice title and content (exclude standardized names from being considered "nice titles")
                        let isOtherStandardized = otherName.hasPrefix("apprecording-") || otherName.hasPrefix("importedfile-")
                        let hasNiceTitle = !isOtherStandardized &&
                                          !otherName.hasPrefix("recording_") && 
                                          !otherName.hasPrefix("V20210426-") && 
                                          !otherName.hasPrefix("V20210427-") &&
                                          !otherName.contains("2025-08-") &&
                                          otherName.count > 15
                        
                        if hasNiceTitle && (otherRecording.transcript != nil || otherRecording.summary != nil) {
                            // Check if they have similar timestamps or same location
                            let timeDifference = abs((recording.recordingDate ?? Date()).timeIntervalSince(otherRecording.recordingDate ?? Date()))
                            let sameLocation = (recording.locationLatitude == otherRecording.locationLatitude && 
                                              recording.locationLongitude == otherRecording.locationLongitude &&
                                              recording.locationLatitude != 0)
                            
                            // If recorded within 10 minutes or at same location, likely duplicates
                            if timeDifference < 600 || sameLocation {
                                potentialDuplicates.append((generic: recording, titled: otherRecording))
                                AppLog.shared.dataMigration("Potential duplicate pair found - generic ID: \(recording.id?.uuidString ?? "nil"), titled ID: \(otherRecording.id?.uuidString ?? "nil"), timeDiff: \(Int(timeDifference))s, sameLocation: \(sameLocation)", level: .debug)
                                break
                            }
                        }
                    }
                }
            }
            
            // Resolve the duplicates by merging data into titled recording and deleting generic one
            for pair in potentialDuplicates {
                let generic = pair.generic
                let titled = pair.titled
                
                AppLog.shared.dataMigration("Merging duplicate generic ID: \(generic.id?.uuidString ?? "nil") into titled ID: \(titled.id?.uuidString ?? "nil")", level: .debug)
                
                // Transfer any missing data from generic to titled recording
                if titled.duration == 0 && generic.duration > 0 {
                    titled.duration = generic.duration
                }
                if titled.fileSize == 0 && generic.fileSize > 0 {
                    titled.fileSize = generic.fileSize
                }
                if titled.audioQuality == nil && generic.audioQuality != nil {
                    titled.audioQuality = generic.audioQuality
                }
                if (titled.locationLatitude == 0 && titled.locationLongitude == 0) &&
                   (generic.locationLatitude != 0 || generic.locationLongitude != 0) {
                    titled.locationLatitude = generic.locationLatitude
                    titled.locationLongitude = generic.locationLongitude
                    titled.locationAccuracy = generic.locationAccuracy
                    titled.locationAddress = generic.locationAddress
                    titled.locationTimestamp = generic.locationTimestamp
                }
                
                // Always keep the titled recording's human-friendly name
                if let titledName = titled.recordingName, !titledName.isEmpty {
                    generic.recordingName = titledName
                }

                // Use the recording URL from whichever exists
                if titled.recordingURL == nil && generic.recordingURL != nil {
                    titled.recordingURL = generic.recordingURL
                } else if generic.recordingURL != nil && titled.recordingURL != nil {
                    // Keep the titled one's URL, but verify it exists
                    if let titledURL = getAbsoluteURLForRecording(titled),
                       !FileManager.default.fileExists(atPath: titledURL.path),
                       let genericURL = getAbsoluteURLForRecording(generic),
                       FileManager.default.fileExists(atPath: genericURL.path) {
                        // Generic URL is valid, titled URL is not - use generic URL
                        titled.recordingURL = generic.recordingURL
                    }
                }
                
                // Update modification time
                titled.lastModified = Date()
                
                // Before deleting generic, ensure all relationships point to the titled recording
                if let transcript = generic.transcript {
                    transcript.recording = titled
                    titled.transcript = transcript
                    titled.transcriptId = transcript.id
                }
                if let summary = generic.summary {
                    summary.recording = titled
                    titled.summary = summary
                    titled.summaryId = summary.id
                }

                // Delete the generic recording
                context.delete(generic)
                resolvedCount += 1
                
                AppLog.shared.dataMigration("Merged and deleted generic recording ID: \(generic.id?.uuidString ?? "nil")")
            }
            
        } catch {
            AppLog.shared.dataMigration("Error resolving filename/title duplicates: \(error)", level: .error)
        }
        
        AppLog.shared.dataMigration("Resolved \(resolvedCount) filename/title duplicate pairs")
        return resolvedCount
    }
    
    /// Helper to get absolute URL for a recording using same logic as CoreDataManager
    private func getAbsoluteURLForRecording(_ recording: RecordingEntry) -> URL? {
        guard let urlString = recording.recordingURL else { return nil }
        
        // Check if it's an absolute URL (legacy format)
        if let url = URL(string: urlString), url.scheme != nil {
            return url
        } else {
            // It's a relative path, convert to absolute URL
            return relativePathToURL(urlString)
        }
    }
    
    /// Cleans up orphaned transcript and summary entries that have no valid recording relationship
    func cleanupOrphanedTranscriptsAndSummaries() async -> Int {
        var cleanedCount = 0
        
        // Clean up orphaned transcripts
        let transcriptFetch: NSFetchRequest<TranscriptEntry> = TranscriptEntry.fetchRequest()
        do {
            let transcripts = try context.fetch(transcriptFetch)
            for transcript in transcripts {
                if transcript.recording == nil {
                    AppLog.shared.dataMigration("Removing orphaned transcript ID: \(transcript.id?.uuidString ?? "nil")", level: .debug)
                    context.delete(transcript)
                    cleanedCount += 1
                }
            }
        } catch {
            AppLog.shared.dataMigration("Error cleaning orphaned transcripts: \(error)", level: .error)
        }
        
        // Clean up orphaned summaries
        let summaryFetch: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
        do {
            let summaries = try context.fetch(summaryFetch)
            for summary in summaries {
                // Preserve summaries associated with recordings intentionally kept without audio
                // A preserved summary will have a recordingId set, even if the recording has no URL
                let hasAnchorRecordingId = (summary.recordingId != nil)
                let isFullyOrphaned = (summary.recording == nil && summary.recordingId == nil)
                if isFullyOrphaned {
                    AppLog.shared.dataMigration("Removing orphaned summary ID: \(summary.id?.uuidString ?? "nil")", level: .debug)
                    context.delete(summary)
                    cleanedCount += 1
                } else if summary.recording == nil && hasAnchorRecordingId {
                    // Keep: preserved summary; do not delete
                    AppLog.shared.dataMigration("Keeping preserved summary (anchor recordingId present) ID: \(summary.id?.uuidString ?? "nil")", level: .debug)
                }
            }
        } catch {
            AppLog.shared.dataMigration("Error cleaning orphaned summaries: \(error)", level: .error)
        }
        
        if cleanedCount > 0 {
            do {
                try context.save()
                AppLog.shared.dataMigration("Cleaned up \(cleanedCount) orphaned transcripts and summaries")
            } catch {
                AppLog.shared.dataMigration("Failed to save after cleaning orphaned entries: \(error)", level: .error)
            }
        }
        
        return cleanedCount
    }
    
    /// Comprehensive duplicate resolution including filename/title pairs
    func performAdvancedDuplicateResolution() async -> Int {
        AppLog.shared.dataMigration("Starting advanced duplicate resolution")
        var totalResolved = 0
        
        // Step 1: Resolve filename/title duplicate pairs
        let filenameDuplicates = await resolveFilenameTitleDuplicates()
        totalResolved += filenameDuplicates
        
        // Step 2: Clean up orphaned transcripts and summaries
        let orphanedCleaned = await cleanupOrphanedTranscriptsAndSummaries()
        totalResolved += orphanedCleaned
        
        // Step 3: Run the standard duplicate resolution
        let standardDuplicates = await resolveDuplicateEntries()
        totalResolved += standardDuplicates
        
        AppLog.shared.dataMigration("Advanced duplicate resolution completed: \(totalResolved) total items resolved")
        return totalResolved
    }
    
    /// Diagnostic function to debug the UI vs Database disconnect
    func diagnoseRecordingDisplayIssue() async {
        AppLog.shared.dataMigration("DIAGNOSTIC: Investigating recording display vs database issue")
        
        let recordingFetch: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        recordingFetch.sortDescriptors = [NSSortDescriptor(keyPath: \RecordingEntry.recordingDate, ascending: false)]
        
        do {
            let recordings = try context.fetch(recordingFetch)
            AppLog.shared.dataMigration("Found \(recordings.count) recordings in database", level: .debug)

            for (index, recording) in recordings.enumerated() {
                let id = recording.id?.uuidString ?? "NO-ID"
                let hasTranscript = recording.transcript != nil
                let hasTranscriptId = recording.transcriptId != nil
                let hasSummary = recording.summary != nil
                let hasSummaryId = recording.summaryId != nil
                let transcriptionStatus = recording.transcriptionStatus ?? "NO-STATUS"
                let summaryStatus = recording.summaryStatus ?? "NO-STATUS"

                AppLog.shared.dataMigration("Recording #\(index + 1): ID=\(id), hasTranscript=\(hasTranscript), hasTranscriptId=\(hasTranscriptId), hasSummary=\(hasSummary), hasSummaryId=\(hasSummaryId), transcriptionStatus=\(transcriptionStatus), summaryStatus=\(summaryStatus)", level: .debug)

                // Check if file exists
                let url = recording.recordingURL ?? "NO-URL"
                if let fileURL = relativePathToURL(url) {
                    let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
                    AppLog.shared.dataMigration("Recording #\(index + 1) file exists: \(fileExists)", level: .debug)
                } else {
                    AppLog.shared.dataMigration("Recording #\(index + 1) could not resolve path", level: .debug)
                }

                // Check first few generic-looking names
                let name = recording.recordingName ?? "NO-NAME"
                if index < 10 && (name.hasPrefix("recording_") || name.hasPrefix("V20210426-")) {
                    AppLog.shared.dataMigration("Recording #\(index + 1) has generic name pattern, ID: \(id)", level: .debug)
                }
            }
            
            // Check for orphaned transcripts and summaries
            let orphanedTranscriptFetch: NSFetchRequest<TranscriptEntry> = TranscriptEntry.fetchRequest()
            orphanedTranscriptFetch.predicate = NSPredicate(format: "recording == nil")
            let orphanedTranscripts = try context.fetch(orphanedTranscriptFetch)
            
            let orphanedSummaryFetch: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
            orphanedSummaryFetch.predicate = NSPredicate(format: "recording == nil")
            let orphanedSummaries = try context.fetch(orphanedSummaryFetch)
            
            AppLog.shared.dataMigration("Orphaned transcripts: \(orphanedTranscripts.count)", level: .debug)
            for transcript in orphanedTranscripts.prefix(5) {
                AppLog.shared.dataMigration("  Orphaned transcript ID: \(transcript.id?.uuidString ?? "nil"), recordingId: \(transcript.recordingId?.uuidString ?? "nil")", level: .debug)
            }

            AppLog.shared.dataMigration("Orphaned summaries: \(orphanedSummaries.count)", level: .debug)
            for summary in orphanedSummaries.prefix(5) {
                AppLog.shared.dataMigration("  Orphaned summary ID: \(summary.id?.uuidString ?? "nil"), recordingId: \(summary.recordingId?.uuidString ?? "nil")", level: .debug)
            }
            
        } catch {
            AppLog.shared.dataMigration("Error in diagnostic: \(error)", level: .error)
        }
    }
    
    /// Scans for orphaned audio files that exist on disk but aren't in the database
    func findAndImportOrphanedAudioFiles() async -> Int {
        AppLog.shared.dataMigration("Scanning for orphaned audio files")
        
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            AppLog.shared.dataMigration("Could not access documents directory", level: .error)
            return 0
        }

        var importedCount = 0
        let supportedExtensions = ["m4a", "mp3", "wav", "aac"]
        
        do {
            // Get all audio files in documents directory
            let allFiles = try FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: [.isRegularFileKey], options: [])
            let audioFiles = allFiles.filter { url in
                supportedExtensions.contains(url.pathExtension.lowercased())
            }
            
            AppLog.shared.dataMigration("Found \(audioFiles.count) audio files on disk", level: .debug)
            
            // Get all existing recording URLs from database
            let recordingFetch: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
            let existingRecordings = try context.fetch(recordingFetch)
            let existingURLs = Set(existingRecordings.compactMap { recording -> String? in
                guard let urlString = recording.recordingURL else { return nil }
                // Convert relative path back to absolute for comparison
                if let absoluteURL = relativePathToURL(urlString) {
                    return absoluteURL.lastPathComponent
                }
                // Also try treating it as an absolute URL
                if let url = URL(string: urlString) {
                    return url.lastPathComponent
                }
                // Fallback: if it's already just a filename
                if !urlString.contains("/") {
                    return urlString
                }
                return nil
            })
            
            AppLog.shared.dataMigration("Found \(existingURLs.count) recordings in database", level: .debug)
            
            // Find orphaned files
            AppLog.shared.dataMigration("Looking for orphaned files", level: .debug)
            for audioFile in audioFiles {
                let filename = audioFile.lastPathComponent
                
                if !existingURLs.contains(filename) {
                    AppLog.shared.dataMigration("Found orphaned audio file", level: .debug)
                    
                    // Import this file into the database
                    await importOrphanedAudioFile(audioFile)
                    importedCount += 1
                } else {
                    AppLog.shared.dataMigration("File already in database", level: .debug)
                }
            }
            
            AppLog.shared.dataMigration("Import summary - total files: \(audioFiles.count), already in DB: \(existingURLs.count), imported: \(importedCount)", level: .debug)
            
            if importedCount > 0 {
                try context.save()
                AppLog.shared.dataMigration("Successfully imported \(importedCount) orphaned audio files")
                
                // Refresh the UI
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: NSNotification.Name("RecordingRenamed"), object: nil)
                }
            } else {
                AppLog.shared.dataMigration("No orphaned audio files found")
            }
            
        } catch {
            AppLog.shared.dataMigration("Error scanning for orphaned files: \(error)", level: .error)
        }
        
        return importedCount
    }
    
    /// Imports a single orphaned audio file into the database
    private func importOrphanedAudioFile(_ fileURL: URL) async {
        AppLog.shared.dataMigration("Importing orphaned audio file")
        
        // Create new recording entry
        let recordingEntry = RecordingEntry(context: context)
        recordingEntry.id = UUID()
        
        // Use the standardized imported file naming convention
        let originalName = fileURL.deletingPathExtension().lastPathComponent
        recordingEntry.recordingName = AudioRecorderViewModel.generateImportedFileName(originalName: originalName)
        
        // Store relative path
        recordingEntry.recordingURL = urlToRelativePath(fileURL)
        
        // Get file metadata
        do {
            let resourceValues = try fileURL.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
            recordingEntry.recordingDate = resourceValues.creationDate ?? Date()
            recordingEntry.createdAt = resourceValues.creationDate ?? Date()
            recordingEntry.lastModified = Date()
            recordingEntry.fileSize = Int64(resourceValues.fileSize ?? 0)
            
            // Get duration
            let asset = AVURLAsset(url: fileURL)
            let duration = try await asset.load(.duration)
            recordingEntry.duration = CMTimeGetSeconds(duration)
            
        } catch {
            AppLog.shared.dataMigration("Could not get metadata for orphaned file: \(error)", level: .error)
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
        
        AppLog.shared.dataMigration("Imported orphaned audio file as recording ID: \(recordingEntry.id?.uuidString ?? "nil")")
    }
    
    /// Forces name synchronization for all recordings with generic names
    func forceNameSynchronization() async -> Int {
        AppLog.shared.dataMigration("Forcing name synchronization for all generic recording names")
        var renamedCount = 0
        
        let recordingFetch: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        do {
            let recordings = try context.fetch(recordingFetch)
            
            for recording in recordings {
                guard let currentName = recording.recordingName else { continue }
                
                // Check if this is a generic filename pattern (comprehensive check)
                let isGenericName = currentName.hasPrefix("recording_") || 
                                   currentName.hasPrefix("V20210426-") ||
                                   currentName.hasPrefix("V20210427-") ||
                                   currentName.contains("2025-08-") ||
                                   currentName.contains("2024-08-") ||
                                   currentName.contains("Recording_") ||
                                   currentName.hasPrefix("Recording ") ||
                                   (currentName.count > 15 && (currentName.contains("1754") || currentName.contains("2025")))
                
                if !isGenericName {
                    AppLog.shared.dataMigration("Skipping non-generic name for recording ID: \(recording.id?.uuidString ?? "nil")", level: .debug)
                    continue
                }

                AppLog.shared.dataMigration("Processing generic name for recording ID: \(recording.id?.uuidString ?? "nil")", level: .debug)
                var bestTitle: String?
                
                // First, try to get a title from the summary
                if let summary = recording.summary,
                   let titlesString = summary.titles,
                   let titlesData = titlesString.data(using: .utf8),
                   let titles = try? JSONDecoder().decode([TitleItem].self, from: titlesData) {
                    
                    // Find the best title (highest confidence)
                    if let bestTitleItem = titles.max(by: { $0.confidence < $1.confidence }) {
                        bestTitle = bestTitleItem.text
                        AppLog.shared.dataMigration("Found summary title for recording ID: \(recording.id?.uuidString ?? "nil") (confidence: \(bestTitleItem.confidence))", level: .debug)
                    }
                }
                
                // If no good summary title, check if the summary itself has a meaningful name
                if bestTitle == nil, let summary = recording.summary, 
                   let summaryName = getSummaryRecordingName(from: summary) {
                    bestTitle = summaryName
                    AppLog.shared.dataMigration("Using summary recording name for ID: \(recording.id?.uuidString ?? "nil")", level: .debug)
                }
                
                // If still no title, generate one from transcript
                if bestTitle == nil, let transcript = recording.transcript,
                   let segmentsString = transcript.segments,
                   let segmentsData = segmentsString.data(using: .utf8),
                   let segments = try? JSONDecoder().decode([TranscriptSegment].self, from: segmentsData) {
                    
                    let fullText = segments.map { $0.text }.joined(separator: " ")
                    if !fullText.isEmpty && fullText.count > 50 {
                        // Use the RecordingNameGenerator to create a meaningful title
                        let generatedName = RecordingNameGenerator.generateRecordingNameFromTranscript(
                            fullText, 
                            contentType: .general, 
                            tasks: [], 
                            reminders: [], 
                            titles: []
                        )
                        if !generatedName.isEmpty && generatedName != "Untitled Conversation" {
                            bestTitle = generatedName
                            AppLog.shared.dataMigration("Generated title from transcript for recording ID: \(recording.id?.uuidString ?? "nil")", level: .debug)
                        }
                    }
                }
                
                // Update the recording name if we found a better title
                if let newTitle = bestTitle, newTitle != currentName {
                    let validatedTitle = RecordingNameGenerator.validateAndFixRecordingName(newTitle, originalName: currentName)
                    if validatedTitle != currentName {
                        recording.recordingName = validatedTitle
                        recording.lastModified = Date()
                        renamedCount += 1
                        AppLog.shared.dataMigration("Renamed recording ID: \(recording.id?.uuidString ?? "nil")")
                    }
                } else {
                    AppLog.shared.dataMigration("No suitable title found for recording ID: \(recording.id?.uuidString ?? "nil")", level: .debug)
                }
            }
            
            if renamedCount > 0 {
                try context.save()
                AppLog.shared.dataMigration("Saved \(renamedCount) name updates")
                
                // Post notification to refresh UI
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: NSNotification.Name("RecordingRenamed"), object: nil)
                }
            }
            
        } catch {
            AppLog.shared.dataMigration("Error during force name synchronization: \(error)", level: .error)
        }
        
        AppLog.shared.dataMigration("Force name synchronization completed: \(renamedCount) recordings renamed")
        return renamedCount
    }
    
    /// Helper to extract meaningful name from summary entry
    private func getSummaryRecordingName(from summary: SummaryEntry) -> String? {
        // Try to get the recording name from the summary's metadata if it has a meaningful one
        if let recordingName = summary.recording?.recordingName,
           !recordingName.hasPrefix("recording_") && 
           !recordingName.hasPrefix("V20210426-") &&
           !recordingName.contains("2025-08-") &&
           recordingName.count > 15 {
            return recordingName
        }
        return nil
    }
    
    /// Validates and ensures all recordings appear in transcript listings
    func validateTranscriptListings() async -> Int {
        AppLog.shared.dataMigration("Validating transcript listings")
        var validatedCount = 0
        
        let recordingFetch: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        do {
            let recordings = try context.fetch(recordingFetch)
            
            for recording in recordings {
                // Ensure recording has proper IDs and status
                if recording.id == nil {
                    recording.id = UUID()
                    validatedCount += 1
                }
                
                // Ensure transcription status is set
                if recording.transcriptionStatus == nil {
                    recording.transcriptionStatus = recording.transcript != nil ? "Completed" : "Not Started"
                    validatedCount += 1
                }
                
                // Ensure summary status is set
                if recording.summaryStatus == nil {
                    recording.summaryStatus = recording.summary != nil ? "Completed" : "Not Started"
                    validatedCount += 1
                }
                
                // Ensure recording date is set
                if recording.recordingDate == nil {
                    recording.recordingDate = recording.createdAt ?? Date()
                    validatedCount += 1
                }
            }
            
            if validatedCount > 0 {
                try context.save()
                AppLog.shared.dataMigration("Validated \(validatedCount) recording fields")
            }
            
        } catch {
            AppLog.shared.dataMigration("Error validating transcript listings: \(error)", level: .error)
        }
        
        AppLog.shared.dataMigration("Transcript listing validation completed: \(validatedCount) fields updated")
        return validatedCount
    }
    
    /// Fix recordings with invalid URLs by matching them to existing audio files
    func fixInvalidURLs() async -> Int {
        AppLog.shared.dataMigration("Starting invalid URL repair")
        
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            AppLog.shared.dataMigration("Could not access documents directory", level: .error)
            return 0
        }
        
        // Get all audio files in documents directory
        var audioFiles: [URL] = []
        do {
            let allFiles = try FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: [.nameKey])
            audioFiles = allFiles.filter { url in
                let ext = url.pathExtension.lowercased()
                return ext == "m4a" || ext == "wav" || ext == "mp3" || ext == "aac"
            }
            AppLog.shared.dataMigration("Found \(audioFiles.count) audio files in documents directory", level: .debug)
        } catch {
            AppLog.shared.dataMigration("Error scanning documents directory: \(error)", level: .error)
            return 0
        }
        
        // Get all recordings
        let recordingFetch: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        var fixedCount = 0
        
        do {
            let recordings = try context.fetch(recordingFetch)
            
            for recording in recordings {
                guard let urlString = recording.recordingURL else { continue }
                
                // Check if URL is invalid (can't be resolved to an existing file)
                let currentURL: URL?
                if let url = URL(string: urlString), url.scheme != nil {
                    currentURL = url
                } else {
                    currentURL = relativePathToURL(urlString)
                }
                
                // If URL is invalid or file doesn't exist, try to fix it
                if currentURL == nil || !FileManager.default.fileExists(atPath: currentURL!.path) {
                    AppLog.shared.dataMigration("Recording has invalid URL, ID: \(recording.id?.uuidString ?? "nil")", level: .debug)
                    
                    // Try to match by recording name
                    if let recordingName = recording.recordingName {
                        let matchingFiles = audioFiles.filter { file in
                            let fileName = file.deletingPathExtension().lastPathComponent
                            // Try exact match first
                            if fileName == recordingName {
                                return true
                            }
                            // Try partial match (for files that might have been renamed)
                            if fileName.contains(recordingName) || recordingName.contains(fileName) {
                                return true
                            }
                            return false
                        }
                        
                        if let matchedFile = matchingFiles.first {
                            // Convert to relative path for storage
                            if let relativePath = urlToRelativePath(matchedFile) {
                                AppLog.shared.dataMigration("Fixed URL for recording ID: \(recording.id?.uuidString ?? "nil")")
                                recording.recordingURL = relativePath
                                recording.lastModified = Date()
                                fixedCount += 1
                            }
                        } else {
                            AppLog.shared.dataMigration("Could not find matching file for recording ID: \(recording.id?.uuidString ?? "nil")", level: .error)
                        }
                    }
                }
            }
            
            // Save changes
            if fixedCount > 0 {
                try context.save()
                AppLog.shared.dataMigration("Fixed \(fixedCount) invalid URLs")
            }
            
        } catch {
            AppLog.shared.dataMigration("Error fixing invalid URLs: \(error)", level: .error)
        }
        
        return fixedCount
    }
    
    /// Clean up recordings with missing audio files by setting their URLs to nil
    /// This is for recordings where we want to keep summaries/transcripts but acknowledge the audio is gone
    func cleanupMissingAudioReferences() async -> Int {
        AppLog.shared.dataMigration("Starting cleanup of missing audio file references")
        
        let recordingFetch: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        var cleanedCount = 0
        
        do {
            let recordings = try context.fetch(recordingFetch)
            AppLog.shared.dataMigration("Found \(recordings.count) recordings to check", level: .debug)
            
            for recording in recordings {
                guard let urlString = recording.recordingURL else { 
                    AppLog.shared.dataMigration("Recording has no URL, ID: \(recording.id?.uuidString ?? "nil")", level: .debug)
                    
                    // Clean up any remaining transcripts for recordings with no URL
                    if let transcript = recording.transcript {
                        AppLog.shared.dataMigration("Cleaning up orphaned transcript for URL-less recording ID: \(recording.id?.uuidString ?? "nil")", level: .debug)
                        recording.transcript = nil
                        recording.transcriptId = nil
                        context.delete(transcript)
                        cleanedCount += 1
                    }
                    continue 
                }
                
                AppLog.shared.dataMigration("Checking recording ID: \(recording.id?.uuidString ?? "nil")", level: .debug)
                
                // Check if URL is invalid or file doesn't exist
                var shouldCleanup = false
                var reason = ""
                
                // Try to resolve the URL using different methods
                // First try as absolute URL
                if let url = URL(string: urlString), url.scheme != nil {
                    let fileExists = FileManager.default.fileExists(atPath: url.path)
                    shouldCleanup = !fileExists
                    reason = fileExists ? "absolute URL file exists" : "absolute URL file missing"
                    AppLog.shared.dataMigration("Absolute URL check - exists: \(fileExists)", level: .debug)
                } else {
                    // Try as relative path
                    if let relativeURL = relativePathToURL(urlString) {
                        let fileExists = FileManager.default.fileExists(atPath: relativeURL.path)
                        shouldCleanup = !fileExists
                        reason = fileExists ? "relative URL file exists" : "relative URL file missing"
                        AppLog.shared.dataMigration("Relative URL check - exists: \(fileExists)", level: .debug)
                    } else {
                        // URL is completely invalid
                        shouldCleanup = true
                        reason = "invalid URL format"
                        AppLog.shared.dataMigration("Invalid URL format for recording ID: \(recording.id?.uuidString ?? "nil")", level: .debug)
                    }
                }
                
                AppLog.shared.dataMigration("Cleanup decision for recording ID \(recording.id?.uuidString ?? "nil"): shouldCleanup=\(shouldCleanup) (\(reason))", level: .debug)
                
                // If URL is invalid or file doesn't exist, clean it up
                if shouldCleanup {
                    AppLog.shared.dataMigration("Cleaning missing audio reference for recording ID: \(recording.id?.uuidString ?? "nil")")
                    
                    // Clear the invalid URL
                    recording.recordingURL = nil
                    recording.lastModified = Date()
                    
                    // Delete transcript since it's useless without audio
                    if let transcript = recording.transcript {
                        AppLog.shared.dataMigration("Deleting transcript for recording with no audio file, ID: \(recording.id?.uuidString ?? "nil")", level: .debug)
                        recording.transcript = nil
                        recording.transcriptId = nil
                        context.delete(transcript)
                    }
                    
                    // Keep summary - it's valuable without audio/transcript
                    
                    cleanedCount += 1
                }
            }
            
            // Save changes
            if cleanedCount > 0 {
                try context.save()
                AppLog.shared.dataMigration("Cleaned up \(cleanedCount) missing audio file references")
            }
            
        } catch {
            AppLog.shared.dataMigration("Error cleaning up missing audio references: \(error)", level: .error)
        }
        
        return cleanedCount
    }
    
    /// Comprehensive fix for current issues
    func fixCurrentIssues() async -> (renames: Int, validations: Int) {
        AppLog.shared.dataMigration("Starting comprehensive fix for current issues")
        
        // Step 1: Clean up orphaned recordings first
        let coreDataManager = CoreDataManager()
        let cleanedOrphans = coreDataManager.cleanupOrphanedRecordings()
        let fixedIncomplete = coreDataManager.fixIncompletelyDeletedRecordings()
        
        // Step 2: Force name synchronization
        let renames = await forceNameSynchronization()
        
        // Step 3: Validate transcript listings
        let validations = await validateTranscriptListings()
        
        // Step 4: Fix recordings with invalid URLs by trying to match them to existing files
        let urlFixes = await fixInvalidURLs()
        
        // Step 5: Fix the specific issue where recordings have generic names
        let specificFixes = await fixGenericNamedRecordingsIssue()
        
        AppLog.shared.dataMigration("Comprehensive fix completed - orphans: \(cleanedOrphans), incomplete: \(fixedIncomplete), URLs: \(urlFixes), renames: \(renames), validations: \(validations), specific: \(specificFixes)")
        
        return (renames: renames + specificFixes, validations: validations)
    }
    
    /// Specifically fixes recordings with generic names that should be in transcript listings
    private func fixGenericNamedRecordingsIssue() async -> Int {
        AppLog.shared.dataMigration("Fixing generic-named recordings issue")
        var fixedCount = 0
        
        let recordingFetch: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        do {
            let recordings = try context.fetch(recordingFetch)
            
            for recording in recordings {
                guard let currentName = recording.recordingName else { continue }
                
                var wasFixed = false
                
                // Check if this is a generic filename that needs fixing
                let isGenericName = currentName.hasPrefix("recording_") || 
                                   currentName.hasPrefix("V20210426-") ||
                                   currentName.hasPrefix("V20210427-") ||
                                   (currentName.count > 15 && (currentName.contains("1754") || currentName.contains("2025")))
                
                if isGenericName {
                    AppLog.shared.dataMigration("Found generic recording ID: \(recording.id?.uuidString ?? "nil")", level: .debug)
                    
                    // Ensure this recording has proper fields for transcript listing
                    if recording.id == nil {
                        recording.id = UUID()
                        wasFixed = true
                        AppLog.shared.dataMigration("Added missing ID", level: .debug)
                    }
                    
                    if recording.transcriptionStatus == nil {
                        recording.transcriptionStatus = "Not Started"
                        wasFixed = true
                        AppLog.shared.dataMigration("Set transcription status to Not Started", level: .debug)
                    }
                    
                    if recording.summaryStatus == nil {
                        recording.summaryStatus = "Not Started"  
                        wasFixed = true
                        AppLog.shared.dataMigration("Set summary status to Not Started", level: .debug)
                    }
                    
                    if recording.recordingDate == nil {
                        recording.recordingDate = recording.createdAt ?? Date()
                        wasFixed = true
                        AppLog.shared.dataMigration("Set recording date", level: .debug)
                    }
                    
                    if recording.createdAt == nil {
                        recording.createdAt = Date()
                        wasFixed = true
                        AppLog.shared.dataMigration("Set created date", level: .debug)
                    }
                    
                    // Look for orphaned summaries/transcripts that might belong to this recording
                    await linkOrphanedContentToRecording(recording)
                    
                    if wasFixed {
                        recording.lastModified = Date()
                        fixedCount += 1
                        AppLog.shared.dataMigration("Fixed recording ID: \(recording.id?.uuidString ?? "nil")", level: .debug)
                    }
                }
            }
            
            if fixedCount > 0 {
                try context.save()
                AppLog.shared.dataMigration("Saved \(fixedCount) recording fixes")
            }
            
        } catch {
            AppLog.shared.dataMigration("Error fixing generic recordings: \(error)", level: .error)
        }
        
        return fixedCount
    }
    
    /// Attempts to link orphaned transcripts/summaries to recordings based on ID matching
    private func linkOrphanedContentToRecording(_ recording: RecordingEntry) async {
        guard let recordingId = recording.id else { return }
        
        // Try to find orphaned transcripts that match this recording by recordingId
        let transcriptFetch: NSFetchRequest<TranscriptEntry> = TranscriptEntry.fetchRequest()
        transcriptFetch.predicate = NSPredicate(format: "recording == nil AND recordingId == %@", recordingId as CVarArg)
        
        do {
            let orphanedTranscripts = try context.fetch(transcriptFetch)
            for transcript in orphanedTranscripts {
                AppLog.shared.dataMigration("Linking orphaned transcript to recording ID: \(recordingId)", level: .debug)
                transcript.recording = recording
                recording.transcript = transcript
                recording.transcriptId = transcript.id
                
                // Try to extract a better name from the transcript content
                if let segmentsString = transcript.segments,
                   let segmentsData = segmentsString.data(using: .utf8),
                   let segments = try? JSONDecoder().decode([TranscriptSegment].self, from: segmentsData),
                   !segments.isEmpty {
                    
                    let fullText = segments.map { $0.text }.joined(separator: " ")
                    if fullText.count > 50 {
                        let generatedName = RecordingNameGenerator.generateRecordingNameFromTranscript(
                            fullText, 
                            contentType: .general, 
                            tasks: [], 
                            reminders: [], 
                            titles: []
                        )
                        if !generatedName.isEmpty && generatedName != "Untitled Conversation" {
                            recording.recordingName = generatedName
                            AppLog.shared.dataMigration("Updated recording name from transcript for ID: \(recordingId)", level: .debug)
                        }
                    }
                }
            }
        } catch {
            AppLog.shared.dataMigration("Error linking orphaned transcripts: \(error)", level: .error)
        }
        
        // Try to find orphaned summaries that match this recording by recordingId
        let summaryFetch: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
        summaryFetch.predicate = NSPredicate(format: "recording == nil AND recordingId == %@", recordingId as CVarArg)
        
        do {
            let orphanedSummaries = try context.fetch(summaryFetch)
            for summary in orphanedSummaries {
                AppLog.shared.dataMigration("Linking orphaned summary to recording ID: \(recordingId)", level: .debug)
                summary.recording = recording
                recording.summary = summary
                recording.summaryId = summary.id
                
                // Try to extract a better name from the summary titles
                if let titlesString = summary.titles,
                   let titlesData = titlesString.data(using: .utf8),
                   let titles = try? JSONDecoder().decode([TitleItem].self, from: titlesData),
                   let bestTitle = titles.max(by: { $0.confidence < $1.confidence }) {
                    
                    let cleanedTitle = RecordingNameGenerator.validateAndFixRecordingName(bestTitle.text, originalName: recording.recordingName ?? "")
                    if !cleanedTitle.isEmpty && cleanedTitle != recording.recordingName {
                        recording.recordingName = cleanedTitle
                        AppLog.shared.dataMigration("Updated recording name from summary for ID: \(recordingId)", level: .debug)
                    }
                }
            }
        } catch {
            AppLog.shared.dataMigration("Error linking orphaned summaries: \(error)", level: .error)
        }
    }
    
    /// Quick fix for the specific issues mentioned - can be called standalone
    func fixSpecificDataIssues() async -> (resolved: Int, saved: Bool) {
        AppLog.shared.dataMigration("Fixing specific data issues (filename/title duplicates and orphaned entries)")
        migrationStatus = "Fixing data issues..."
        migrationProgress = 0.0
        
        var totalResolved = 0
        
        do {
            // Step 1: Advanced duplicate resolution (handles filename/title pairs)
            migrationStatus = "Resolving filename/title duplicate pairs..."
            let resolved = await performAdvancedDuplicateResolution()
            totalResolved += resolved
            migrationProgress = 0.5
            
            // Step 2: Fix any remaining relationship inconsistencies
            migrationStatus = "Fixing relationship inconsistencies..."
            let relationshipFixes = await fixRelationshipInconsistencies()
            totalResolved += relationshipFixes
            migrationProgress = 0.8
            
            // Step 3: Save changes
            migrationStatus = "Saving fixes..."
            try context.save()
            migrationProgress = 1.0
            
            migrationStatus = "Data issues fixed successfully!"
            AppLog.shared.dataMigration("Fixed \(totalResolved) data issues successfully")
            return (resolved: totalResolved, saved: true)
            
        } catch {
            AppLog.shared.dataMigration("Error fixing data issues: \(error)", level: .error)
            migrationStatus = "Failed to fix data issues: \(error.localizedDescription)"
            return (resolved: totalResolved, saved: false)
        }
    }
}
