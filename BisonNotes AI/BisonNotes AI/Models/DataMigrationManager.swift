//
//  DataMigrationManager.swift
//  Audio Journal
//
//  Created by Kiro on 8/1/25.
//

import Foundation
import CoreData
import AVFoundation

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
    
    @Published var migrationProgress: Double = 0.0
    @Published var migrationStatus: String = ""
    @Published var isCompleted: Bool = false
    
    init(persistenceController: PersistenceController = PersistenceController.shared) {
        self.persistenceController = persistenceController
        self.context = persistenceController.container.viewContext
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
        recordingEntry.recordingName = recordingName
        recordingEntry.recordingURL = audioFile.absoluteString
        
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
                guard let urlString = recording.recordingURL,
                      let url = URL(string: urlString) else { continue }
                
                if !FileManager.default.fileExists(atPath: url.path) {
                    missing.append(MissingAudioFile(
                        recording: recording,
                        expectedPath: url.path
                    ))
                }
            }
        } catch {
            print("❌ Error checking for missing audio files: \(error)")
        }
        
        print("🔍 Found \(missing.count) recordings with missing audio files")
        return missing
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
}