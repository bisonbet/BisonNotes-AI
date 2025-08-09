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
        print("🔄 Starting data migration...")
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
            print("✅ Data migration completed successfully")
            
        } catch {
            print("❌ Data migration failed: \(error)")
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
            
            print("📁 Found \(audioFiles.count) audio files")
            return audioFiles
            
        } catch {
            print("❌ Error scanning for audio files: \(error)")
            return []
        }
    }
    
    private func scanForTranscriptFiles() async -> [URL] {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: nil, options: [])
            let transcriptFiles = fileURLs.filter { $0.pathExtension.lowercased() == "transcript" }
            
            print("📄 Found \(transcriptFiles.count) transcript files")
            return transcriptFiles
            
        } catch {
            print("❌ Error scanning for transcript files: \(error)")
            return []
        }
    }
    
    private func scanForSummaryFiles() async -> [URL] {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: nil, options: [])
            let summaryFiles = fileURLs.filter { $0.pathExtension.lowercased() == "summary" }
            
            print("📝 Found \(summaryFiles.count) summary files")
            return summaryFiles
            
        } catch {
            print("❌ Error scanning for summary files: \(error)")
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
                print("⏭️ Recording already exists: \(recordingName)")
                return
            }
        } catch {
            print("❌ Error checking for existing recording: \(error)")
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
            print("❌ Error getting file metadata: \(error)")
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
                
                print("📍 Location data migrated for: \(recordingName)")
            } catch {
                print("❌ Error migrating location data: \(error)")
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
        
        print("✅ Created recording entry: \(recordingName)")
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
            
            print("✅ Created transcript entry for: \(recordingEntry.recordingName ?? "unknown")")
            
        } catch {
            print("❌ Error creating transcript entry: \(error)")
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
            summaryEntry.aiMethod = summary.aiMethod
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
            
            print("✅ Created summary entry for: \(recordingEntry.recordingName ?? "unknown")")
            
        } catch {
            print("❌ Error creating summary entry: \(error)")
        }
    }
    
    private func getAudioDuration(url: URL) async -> TimeInterval {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            return player.duration
        } catch {
            print("❌ Error getting audio duration for \(url.lastPathComponent): \(error)")
            return 0.0
        }
    }
    
    // MARK: - Data Recovery Methods
    
    func recoverDataFromiCloud() async -> (transcripts: Int, summaries: Int, errors: [String]) {
        let transcriptCount = 0 // Transcript recovery not yet implemented
        var summaryCount = 0
        var errors: [String] = []
        
        print("📥 Starting iCloud data recovery...")
        
        // Try UnifiediCloudSyncManager first
        if let unifiedManager = unifiediCloudSyncManager {
            print("🔍 Using UnifiediCloudSyncManager for recovery...")
            do {
                if !unifiedManager.isEnabled {
                    print("⚠️ Unified iCloud sync is disabled")
                    errors.append("Unified iCloud sync is disabled - enable it in Settings")
                } else {
                    print("🔄 Fetching data from unified iCloud sync...")
                    try await unifiedManager.fetchAllDataFromCloud()
                    
                    // The unified manager updates the registry, but we need Core Data entries
                    // This would need integration with the registry to create Core Data entries
                    print("⚠️ Unified iCloud recovery fetched data to registry, but Core Data integration needed")
                    errors.append("Unified iCloud recovery needs Core Data integration")
                }
            } catch {
                print("❌ Unified iCloud recovery failed: \(error)")
                errors.append("Unified iCloud error: \(error.localizedDescription)")
            }
        }
        
        // Try legacy iCloudStorageManager if unified is not available
        else if let legacyManager = iCloudStorageManager {
            print("🔍 Using legacy iCloudStorageManager for recovery...")
            do {
                if !legacyManager.isEnabled {
                    print("⚠️ Legacy iCloud sync is disabled")
                    errors.append("Legacy iCloud sync is disabled - enable it in Settings")
                } else {
                    print("📥 Fetching summaries from legacy iCloud...")
                    let summaries = try await legacyManager.fetchSummariesFromiCloud()
                    
                    if !summaries.isEmpty {
                        print("📊 Found \(summaries.count) summaries in legacy iCloud")
                        
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
                                summaryEntry.aiMethod = summary.aiMethod
                                summaryEntry.originalLength = Int32(summary.originalLength)
                                summaryEntry.processingTime = summary.processingTime
                                summaryEntry.recordingId = summary.recordingId
                                summaryEntry.transcriptId = summary.transcriptId
                                
                                summaryCount += 1
                                print("✅ Recovered summary: \(summary.recordingName)")
                            } else {
                                print("⚠️ Summary already exists: \(summary.recordingName)")
                            }
                        }
                        
                        // Save the context
                        try context.save()
                        print("✅ Saved \(summaryCount) recovered summaries to Core Data")
                        
                    } else {
                        print("📋 No summaries found in legacy iCloud")
                    }
                }
            } catch {
                print("❌ Legacy iCloud recovery failed: \(error)")
                errors.append("Legacy iCloud error: \(error.localizedDescription)")
            }
        }
        
        // No iCloud managers available
        else {
            print("⚠️ No iCloud sync managers available")
            errors.append("No iCloud sync managers available - they need to be passed to DataMigrationManager")
        }
        
        print("📊 Recovery results: \(transcriptCount) transcripts, \(summaryCount) summaries recovered")
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
                print("🗑️ Cleared all \(entityName) entries")
            } catch {
                print("❌ Error clearing \(entityName): \(error)")
            }
        }
        
        do {
            try context.save()
            print("✅ Core Data cleared successfully")
        } catch {
            print("❌ Error saving after clearing Core Data: \(error)")
        }
    }
    
    func debugCoreDataContents() async {
        // Check recordings
        let recordingFetch: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        do {
            let recordings = try context.fetch(recordingFetch)
            print("📊 Core Data contains \(recordings.count) recordings:")
            for recording in recordings {
                print("  - \(recording.recordingName ?? "unknown") (ID: \(recording.id?.uuidString ?? "nil"))")
                print("    Has transcript: \(recording.transcript != nil)")
                print("    Has summary: \(recording.summary != nil)")
            }
        } catch {
            print("❌ Error fetching recordings: \(error)")
        }
        
        // Check transcripts
        let transcriptFetch: NSFetchRequest<TranscriptEntry> = TranscriptEntry.fetchRequest()
        do {
            let transcripts = try context.fetch(transcriptFetch)
            print("📊 Core Data contains \(transcripts.count) transcripts")
        } catch {
            print("❌ Error fetching transcripts: \(error)")
        }
        
        // Check summaries
        let summaryFetch: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
        do {
            let summaries = try context.fetch(summaryFetch)
            print("📊 Core Data contains \(summaries.count) summaries")
        } catch {
            print("❌ Error fetching summaries: \(error)")
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
        print("🔍 Starting comprehensive data integrity check...")
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
        print("🔧 Starting data repair process...")
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
            print("✅ Data repair completed successfully")
            
        } catch {
            print("❌ Data repair failed: \(error)")
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
            print("❌ Error finding orphaned recordings: \(error)")
        }
        
        print("🔍 Found \(orphaned.count) orphaned recordings")
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
            print("❌ Error finding orphaned files: \(error)")
        }
        
        print("🔍 Found \(orphaned.count) orphaned files")
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
            print("❌ Error checking transcript relationships: \(error)")
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
            print("❌ Error checking summary relationships: \(error)")
        }
        
        print("🔍 Found \(broken.count) broken relationships")
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
                    print("⚠️ Could not resolve URL for recording: \(recording.recordingName ?? "unknown")")
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
            print("❌ Error checking for missing audio files: \(error)")
        }
        
        print("🔍 Found \(missing.count) recordings with missing audio files")
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
            print("❌ Error checking for duplicate recordings: \(error)")
        }
        
        print("🔍 Found \(duplicates.count) sets of duplicate entries")
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
        
        print("🔧 Repaired \(repaired) orphaned recording relationships")
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
                print("❌ Error importing orphaned file \(orphanedFile.fileURL.lastPathComponent): \(error)")
            }
        }
        
        print("🔧 Imported \(imported) orphaned files")
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
                        print("❌ Error repairing transcript relationship: \(error)")
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
                        print("❌ Error repairing summary relationship: \(error)")
                    }
                }
            }
        }
        
        print("🔧 Repaired \(repaired) broken relationships")
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
        
        print("🗑️ Cleaned up \(cleaned) recordings with missing audio files")
        return cleaned
    }
    
    // MARK: - Enhanced Data Validation and Repair
    
    /// Performs comprehensive validation and repair of data inconsistencies
    func performComprehensiveDataRepair() async -> DataRepairResults {
        print("🔧 Starting comprehensive data repair...")
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
            print("✅ Comprehensive data repair completed successfully")
            print("📊 Repair summary:")
            print("   - Relationship fixes: \(relationshipFixes)")
            print("   - Name synchronizations: \(nameFixes)")
            print("   - URL conversions: \(urlFixes)")
            print("   - Duplicate resolutions: \(duplicateFixes)")
            
        } catch {
            print("❌ Comprehensive data repair failed: \(error)")
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
                            print("🔗 Fixed transcript relationship for: \(recording.recordingName ?? "unknown")")
                        }
                    } else if recording.transcript?.id != transcriptId {
                        // Relationship exists but ID doesn't match - sync the ID
                        recording.transcriptId = recording.transcript?.id
                        wasFixed = true
                        print("🔄 Synced transcript ID for: \(recording.recordingName ?? "unknown")")
                    }
                } else if let transcript = recording.transcript {
                    // Has relationship but no ID - sync the ID
                    recording.transcriptId = transcript.id
                    wasFixed = true
                    print("🆔 Added missing transcript ID for: \(recording.recordingName ?? "unknown")")
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
                            print("🔗 Fixed summary relationship for: \(recording.recordingName ?? "unknown")")
                        }
                    } else if recording.summary?.id != summaryId {
                        // Relationship exists but ID doesn't match - sync the ID
                        recording.summaryId = recording.summary?.id
                        wasFixed = true
                        print("🔄 Synced summary ID for: \(recording.recordingName ?? "unknown")")
                    }
                } else if let summary = recording.summary {
                    // Has relationship but no ID - sync the ID
                    recording.summaryId = summary.id
                    wasFixed = true
                    print("🆔 Added missing summary ID for: \(recording.recordingName ?? "unknown")")
                }
                
                if wasFixed {
                    recording.lastModified = Date()
                    fixedCount += 1
                }
            }
        } catch {
            print("❌ Error fixing relationship inconsistencies: \(error)")
        }
        
        print("🔧 Fixed \(fixedCount) relationship inconsistencies")
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
                    print("⏭️ Skipping standardized name: '\(currentName)'")
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
                    print("⏭️ Skipping non-generic name: '\(currentName)'")
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
                        print("📝 Found summary title for \(currentName): '\(bestTitleItem.text)' (confidence: \(bestTitleItem.confidence))")
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
                            print("🎯 Generated title from transcript for \(currentName): '\(generatedName)'")
                        }
                    }
                }
                
                // Update the recording name if we found a better title
                if let newTitle = bestTitle, newTitle != currentName {
                    let validatedTitle = RecordingNameGenerator.validateAndFixRecordingName(newTitle, originalName: currentName)
                    recording.recordingName = validatedTitle
                    recording.lastModified = Date()
                    syncedCount += 1
                    print("✅ Updated recording name: '\(currentName)' → '\(validatedTitle)'")
                }
            }
        } catch {
            print("❌ Error syncing recording names: \(error)")
        }
        
        print("🏷️ Synced \(syncedCount) recording names with titles")
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
                        print("🔄 Converted to relative path: \(url.lastPathComponent)")
                    }
                }
            }
        } catch {
            print("❌ Error converting URLs to relative paths: \(error)")
        }
        
        print("📁 Converted \(convertedCount) URLs to relative paths")
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
            
            for (name, group) in nameGroups where group.count > 1 {
                print("🔍 Resolving \(group.count) duplicates for: \(name)")
                
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
                    print("🗑️ Removing duplicate: \(duplicate.id?.uuidString ?? "unknown")")
                    context.delete(duplicate)
                    resolvedCount += 1
                }
                
                print("✅ Kept recording with ID: \(keeper.id?.uuidString ?? "unknown")")
            }
        } catch {
            print("❌ Error resolving duplicate entries: \(error)")
        }
        
        print("🧹 Resolved \(resolvedCount) duplicate entries")
        return resolvedCount
    }
    
    // MARK: - Advanced Duplicate Detection and Merging
    
    /// Detects and resolves filename-based duplicates (generic names + AI-generated titles for same audio)
    func resolveFilenameTitleDuplicates() async -> Int {
        print("🔍 Detecting filename/title duplicate pairs...")
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
                                print("🔗 Potential duplicate pair found:")
                                print("   Generic: '\(name)' (ID: \(recording.id?.uuidString ?? "nil"))")
                                print("   Titled: '\(otherName)' (ID: \(otherRecording.id?.uuidString ?? "nil"))")
                                print("   Time diff: \(Int(timeDifference))s, Same location: \(sameLocation)")
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
                
                print("🔄 Merging duplicate: '\(generic.recordingName ?? "unknown")' -> '\(titled.recordingName ?? "unknown")'")
                
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
                
                // Delete the generic recording
                context.delete(generic)
                resolvedCount += 1
                
                print("✅ Merged and deleted generic recording: '\(generic.recordingName ?? "unknown")'")
            }
            
        } catch {
            print("❌ Error resolving filename/title duplicates: \(error)")
        }
        
        print("🧹 Resolved \(resolvedCount) filename/title duplicate pairs")
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
                    print("🗑️ Removing orphaned transcript: \(transcript.id?.uuidString ?? "unknown")")
                    context.delete(transcript)
                    cleanedCount += 1
                }
            }
        } catch {
            print("❌ Error cleaning orphaned transcripts: \(error)")
        }
        
        // Clean up orphaned summaries
        let summaryFetch: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
        do {
            let summaries = try context.fetch(summaryFetch)
            for summary in summaries {
                if summary.recording == nil {
                    print("🗑️ Removing orphaned summary: \(summary.id?.uuidString ?? "unknown")")
                    context.delete(summary)
                    cleanedCount += 1
                }
            }
        } catch {
            print("❌ Error cleaning orphaned summaries: \(error)")
        }
        
        if cleanedCount > 0 {
            do {
                try context.save()
                print("✅ Cleaned up \(cleanedCount) orphaned transcripts and summaries")
            } catch {
                print("❌ Failed to save after cleaning orphaned entries: \(error)")
            }
        }
        
        return cleanedCount
    }
    
    /// Comprehensive duplicate resolution including filename/title pairs
    func performAdvancedDuplicateResolution() async -> Int {
        print("🧹 Starting advanced duplicate resolution...")
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
        
        print("🎯 Advanced duplicate resolution completed: \(totalResolved) total items resolved")
        return totalResolved
    }
    
    /// Diagnostic function to debug the UI vs Database disconnect
    func diagnoseRecordingDisplayIssue() async {
        print("🔍 DIAGNOSTIC: Investigating recording display vs database issue...")
        
        let recordingFetch: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        recordingFetch.sortDescriptors = [NSSortDescriptor(keyPath: \RecordingEntry.recordingDate, ascending: false)]
        
        do {
            let recordings = try context.fetch(recordingFetch)
            print("📊 Found \(recordings.count) recordings in database:")
            
            for (index, recording) in recordings.enumerated() {
                let id = recording.id?.uuidString ?? "NO-ID"
                let name = recording.recordingName ?? "NO-NAME"
                let url = recording.recordingURL ?? "NO-URL"
                let hasTranscript = recording.transcript != nil
                let hasTranscriptId = recording.transcriptId != nil
                let hasSummary = recording.summary != nil
                let hasSummaryId = recording.summaryId != nil
                let transcriptionStatus = recording.transcriptionStatus ?? "NO-STATUS"
                let summaryStatus = recording.summaryStatus ?? "NO-STATUS"
                
                print("\n📝 Recording #\(index + 1):")
                print("   ID: \(id)")
                print("   Name: '\(name)'")
                print("   URL: \(url)")
                print("   Has Transcript: \(hasTranscript) | TranscriptId: \(hasTranscriptId)")
                print("   Has Summary: \(hasSummary) | SummaryId: \(hasSummaryId)")
                print("   Transcription Status: '\(transcriptionStatus)'")
                print("   Summary Status: '\(summaryStatus)'")
                
                // Check if file exists
                if let fileURL = relativePathToURL(url) {
                    let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
                    print("   File Exists: \(fileExists) at \(fileURL.path)")
                } else {
                    print("   File: Could not resolve path")
                }
                
                // Show first few generic-looking names in detail
                if index < 10 && (name.hasPrefix("recording_") || name.hasPrefix("V20210426-")) {
                    print("   🚨 FOUND GENERIC NAME IN DATABASE: '\(name)'")
                    print("   🔍 This contradicts the log output - investigating further...")
                }
            }
            
            // Check for orphaned transcripts and summaries
            let orphanedTranscriptFetch: NSFetchRequest<TranscriptEntry> = TranscriptEntry.fetchRequest()
            orphanedTranscriptFetch.predicate = NSPredicate(format: "recording == nil")
            let orphanedTranscripts = try context.fetch(orphanedTranscriptFetch)
            
            let orphanedSummaryFetch: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
            orphanedSummaryFetch.predicate = NSPredicate(format: "recording == nil")
            let orphanedSummaries = try context.fetch(orphanedSummaryFetch)
            
            print("\n🔍 Orphaned Content:")
            print("   Orphaned Transcripts: \(orphanedTranscripts.count)")
            for transcript in orphanedTranscripts.prefix(5) {
                print("     - TranscriptID: \(transcript.id?.uuidString ?? "NO-ID"), RecordingID: \(transcript.recordingId?.uuidString ?? "NO-RECORDING-ID")")
            }
            
            print("   Orphaned Summaries: \(orphanedSummaries.count)")
            for summary in orphanedSummaries.prefix(5) {
                print("     - SummaryID: \(summary.id?.uuidString ?? "NO-ID"), RecordingID: \(summary.recordingId?.uuidString ?? "NO-RECORDING-ID")")
                if let titlesString = summary.titles,
                   let titlesData = titlesString.data(using: .utf8),
                   let titles = try? JSONDecoder().decode([TitleItem].self, from: titlesData),
                   let firstTitle = titles.first {
                    print("       Title: '\(firstTitle.text)'")
                }
            }
            
        } catch {
            print("❌ Error in diagnostic: \(error)")
        }
    }
    
    /// Scans for orphaned audio files that exist on disk but aren't in the database
    func findAndImportOrphanedAudioFiles() async -> Int {
        print("🔍 Scanning for orphaned audio files...")
        
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("❌ Could not access documents directory")
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
            
            print("📁 Found \(audioFiles.count) audio files on disk")
            
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
            
            print("💾 Found \(existingURLs.count) recordings in database")
            print("🔍 Existing filenames in DB: \(existingURLs.prefix(5).joined(separator: ", "))")
            
            // Find orphaned files
            print("🔍 Looking for orphaned files...")
            for audioFile in audioFiles {
                let filename = audioFile.lastPathComponent
                
                if !existingURLs.contains(filename) {
                    print("🆕 Found orphaned audio file: \(filename)")
                    
                    // Import this file into the database
                    await importOrphanedAudioFile(audioFile)
                    importedCount += 1
                } else {
                    print("✅ File already in database: \(filename)")
                }
            }
            
            print("📊 Import summary:")
            print("   - Total audio files found: \(audioFiles.count)")
            print("   - Files already in database: \(existingURLs.count)")
            print("   - Orphaned files imported: \(importedCount)")
            
            if importedCount > 0 {
                try context.save()
                print("✅ Successfully imported \(importedCount) orphaned audio files")
                
                // Refresh the UI
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: NSNotification.Name("RecordingRenamed"), object: nil)
                }
            } else {
                print("ℹ️ No orphaned audio files found")
            }
            
        } catch {
            print("❌ Error scanning for orphaned files: \(error)")
        }
        
        return importedCount
    }
    
    /// Imports a single orphaned audio file into the database
    private func importOrphanedAudioFile(_ fileURL: URL) async {
        print("📥 Importing orphaned file: \(fileURL.lastPathComponent)")
        
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
            print("⚠️ Could not get metadata for \(fileURL.lastPathComponent): \(error)")
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
        
        print("✅ Imported: '\(recordingEntry.recordingName ?? "unknown")' from \(fileURL.lastPathComponent)")
    }
    
    /// Forces name synchronization for all recordings with generic names
    func forceNameSynchronization() async -> Int {
        print("🏷️ Forcing name synchronization for all generic recording names...")
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
                    print("⏭️ Skipping non-generic name: '\(currentName)'")
                    continue 
                }
                
                print("🔍 Processing generic name: '\(currentName)'")
                var bestTitle: String?
                
                // First, try to get a title from the summary
                if let summary = recording.summary,
                   let titlesString = summary.titles,
                   let titlesData = titlesString.data(using: .utf8),
                   let titles = try? JSONDecoder().decode([TitleItem].self, from: titlesData) {
                    
                    // Find the best title (highest confidence)
                    if let bestTitleItem = titles.max(by: { $0.confidence < $1.confidence }) {
                        bestTitle = bestTitleItem.text
                        print("📝 Found summary title: '\(bestTitleItem.text)' (confidence: \(bestTitleItem.confidence))")
                    }
                }
                
                // If no good summary title, check if the summary itself has a meaningful name
                if bestTitle == nil, let summary = recording.summary, 
                   let summaryName = getSummaryRecordingName(from: summary) {
                    bestTitle = summaryName
                    print("📋 Using summary recording name: '\(summaryName)'")
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
                            print("🎯 Generated title from transcript: '\(generatedName)'")
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
                        print("✅ Renamed: '\(currentName)' → '\(validatedTitle)'")
                    }
                } else {
                    print("⚠️ No suitable title found for: '\(currentName)'")
                }
            }
            
            if renamedCount > 0 {
                try context.save()
                print("✅ Saved \(renamedCount) name updates")
                
                // Post notification to refresh UI
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: NSNotification.Name("RecordingRenamed"), object: nil)
                }
            }
            
        } catch {
            print("❌ Error during force name synchronization: \(error)")
        }
        
        print("🏷️ Force name synchronization completed: \(renamedCount) recordings renamed")
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
        print("📋 Validating transcript listings...")
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
                print("✅ Validated \(validatedCount) recording fields")
            }
            
        } catch {
            print("❌ Error validating transcript listings: \(error)")
        }
        
        print("📋 Transcript listing validation completed: \(validatedCount) fields updated")
        return validatedCount
    }
    
    /// Comprehensive fix for current issues
    func fixCurrentIssues() async -> (renames: Int, validations: Int) {
        print("🎯 Starting comprehensive fix for current issues...")
        
        // Step 1: Force name synchronization
        let renames = await forceNameSynchronization()
        
        // Step 2: Validate transcript listings
        let validations = await validateTranscriptListings()
        
        // Step 3: Fix the specific issue where recordings have generic names
        let specificFixes = await fixGenericNamedRecordingsIssue()
        
        print("✅ Comprehensive fix completed: \(renames) renames, \(validations) validations, \(specificFixes) specific fixes")
        return (renames: renames + specificFixes, validations: validations)
    }
    
    /// Specifically fixes recordings with generic names that should be in transcript listings
    private func fixGenericNamedRecordingsIssue() async -> Int {
        print("🔧 Fixing generic-named recordings issue...")
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
                    print("🔍 Found generic recording: '\(currentName)'")
                    
                    // Ensure this recording has proper fields for transcript listing
                    if recording.id == nil {
                        recording.id = UUID()
                        wasFixed = true
                        print("   ➕ Added missing ID")
                    }
                    
                    if recording.transcriptionStatus == nil {
                        recording.transcriptionStatus = "Not Started"
                        wasFixed = true
                        print("   ➕ Set transcription status to 'Not Started'")
                    }
                    
                    if recording.summaryStatus == nil {
                        recording.summaryStatus = "Not Started"  
                        wasFixed = true
                        print("   ➕ Set summary status to 'Not Started'")
                    }
                    
                    if recording.recordingDate == nil {
                        recording.recordingDate = recording.createdAt ?? Date()
                        wasFixed = true
                        print("   ➕ Set recording date")
                    }
                    
                    if recording.createdAt == nil {
                        recording.createdAt = Date()
                        wasFixed = true
                        print("   ➕ Set created date")
                    }
                    
                    // Look for orphaned summaries/transcripts that might belong to this recording
                    await linkOrphanedContentToRecording(recording)
                    
                    if wasFixed {
                        recording.lastModified = Date()
                        fixedCount += 1
                        print("   ✅ Fixed recording: '\(currentName)'")
                    }
                }
            }
            
            if fixedCount > 0 {
                try context.save()
                print("✅ Saved \(fixedCount) recording fixes")
            }
            
        } catch {
            print("❌ Error fixing generic recordings: \(error)")
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
                print("   🔗 Linking orphaned transcript to recording by ID: \(recordingId)")
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
                            print("   🏷️ Updated recording name from transcript to: '\(generatedName)'")
                        }
                    }
                }
            }
        } catch {
            print("❌ Error linking orphaned transcripts: \(error)")
        }
        
        // Try to find orphaned summaries that match this recording by recordingId
        let summaryFetch: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
        summaryFetch.predicate = NSPredicate(format: "recording == nil AND recordingId == %@", recordingId as CVarArg)
        
        do {
            let orphanedSummaries = try context.fetch(summaryFetch)
            for summary in orphanedSummaries {
                print("   🔗 Linking orphaned summary to recording by ID: \(recordingId)")
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
                        print("   🏷️ Updated recording name from summary to: '\(cleanedTitle)'")
                    }
                }
            }
        } catch {
            print("❌ Error linking orphaned summaries: \(error)")
        }
    }
    
    /// Quick fix for the specific issues mentioned - can be called standalone
    func fixSpecificDataIssues() async -> (resolved: Int, saved: Bool) {
        print("🎯 Fixing specific data issues (filename/title duplicates and orphaned entries)...")
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
            print("✅ Fixed \(totalResolved) data issues successfully")
            return (resolved: totalResolved, saved: true)
            
        } catch {
            print("❌ Error fixing data issues: \(error)")
            migrationStatus = "Failed to fix data issues: \(error.localizedDescription)"
            return (resolved: totalResolved, saved: false)
        }
    }
}