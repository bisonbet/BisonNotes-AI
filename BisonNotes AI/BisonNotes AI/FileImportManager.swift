//
//  FileImportManager.swift
//  Audio Journal
//
//  Handles importing audio files from the device
//

import Foundation
@preconcurrency import AVFoundation
import UIKit
import SwiftUI
import CoreData

// MARK: - File Import Manager

@MainActor
class FileImportManager: NSObject, ObservableObject {
    
    @Published var isImporting = false
    @Published var importProgress: Double = 0.0
    @Published var currentlyImporting: String = ""
    @Published var importResults: ImportResults?
    @Published var showingImportAlert = false
    
    private let supportedExtensions = ["m4a", "mp3", "wav"]
    private let persistenceController: PersistenceController
    private let context: NSManagedObjectContext
    
    override init() {
        self.persistenceController = PersistenceController.shared
        self.context = persistenceController.container.viewContext
        super.init()
    }
    
    // MARK: - Import Methods
    
    /// Transcodes existing recorded files to Whisper-compatible format
    func transcodeRecordedFilesToMP3() async {
        print("🔧 Starting Whisper-compatible transcoding for existing recorded files...")
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: nil)
            
            // Clean up any orphaned _whisper files from previous failed attempts
            let orphanedWhisperFiles = contents.filter { 
                $0.lastPathComponent.contains("_whisper") && 
                $0.pathExtension.lowercased() == "m4a"
            }
            
            for orphanedFile in orphanedWhisperFiles {
                // First, fix any Core Data entries that might be pointing to this orphaned file
                await fixCoreDataPointingToWhisperFile(orphanedFile)
                
                do {
                    try FileManager.default.removeItem(at: orphanedFile)
                    print("🧹 Cleaned up orphaned file: \(orphanedFile.lastPathComponent)")
                } catch {
                    print("⚠️ Failed to clean up \(orphanedFile.lastPathComponent): \(error)")
                }
            }
            
            let recordedFiles = contents.filter { 
                $0.lastPathComponent.starts(with: "recording_") && 
                $0.pathExtension.lowercased() == "m4a" &&
                !$0.lastPathComponent.contains("_whisper")  // Exclude already processed files
            }
            
            print("🔧 Found \(recordedFiles.count) M4A recorded files to transcode")
            
            var successCount = 0
            var failureCount = 0
            
            for file in recordedFiles {
                do {
                    // Check if file is already in optimal format
                    if await isAlreadyWhisperOptimized(file) {
                        print("⏭️ Skipping \(file.lastPathComponent) - already optimized")
                        continue
                    }
                    
                    try await transcodeFileToWhisperCompatibleFormat(originalURL: file)
                    successCount += 1
                    print("✅ Successfully transcoded: \(file.lastPathComponent)")
                } catch {
                    failureCount += 1
                    print("❌ Failed to transcode \(file.lastPathComponent): \(error)")
                }
            }
            
            print("🎵 Transcoding complete: \(successCount) successful, \(failureCount) failed")
            
        } catch {
            print("❌ Failed to scan documents directory: \(error)")
        }
    }
    
    func importAudioFiles(from urls: [URL]) async {
        guard !isImporting else { return }
        
        isImporting = true
        importProgress = 0.0
        currentlyImporting = "Preparing..."
        
        let totalCount = urls.count
        guard totalCount > 0 else {
            completeImport(with: ImportResults(total: 0, successful: 0, failed: 0, errors: []))
            return
        }
        
        var successful = 0
        var failed = 0
        var errors: [String] = []
        
        for (index, sourceURL) in urls.enumerated() {
            currentlyImporting = "Importing \(sourceURL.lastPathComponent)..."
            importProgress = Double(index) / Double(totalCount)
            
            do {
                try await importAudioFile(from: sourceURL)
                successful += 1
            } catch {
                failed += 1
                errors.append("\(sourceURL.lastPathComponent): \(error.localizedDescription)")
            }
            
            // Small delay to show progress
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
        
        importProgress = 1.0
        currentlyImporting = "Complete"
        
        let results = ImportResults(
            total: totalCount,
            successful: successful,
            failed: failed,
            errors: errors
        )
        
        completeImport(with: results)
    }
    
    private func importAudioFile(from sourceURL: URL) async throws {
        // Validate file extension
        let fileExtension = sourceURL.pathExtension.lowercased()
        guard supportedExtensions.contains(fileExtension) else {
            throw ImportError.unsupportedFormat(fileExtension)
        }
        
        // Get documents directory
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        // Generate unique filename
        let filename = generateUniqueFilename(for: sourceURL)
        let destinationURL = documentsPath.appendingPathComponent(filename)
        
        // Check if file already exists
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            throw ImportError.fileAlreadyExists(filename)
        }
        
        // Copy file to documents directory with comprehensive error handling for thumbnail issues
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            
        } catch {
            // Check if this is a thumbnail-related error that we can ignore
            if error.isThumbnailGenerationError {
                print("⚠️ Thumbnail generation warning (can be ignored): \(error.localizedDescription)")
                // Continue with import even if thumbnail generation fails
                // The file copy operation itself succeeded, only thumbnail generation failed
            } else {
                throw ImportError.copyFailed(error.localizedDescription)
            }
        }
        
        // Validate the copied file
        try validateAudioFile(at: destinationURL)
        
        // Create Core Data entry for the imported file
        try await createRecordingEntryForImportedFile(at: destinationURL)
        
        print("✅ Successfully imported: \(filename)")
    }
    
    private func generateUniqueFilename(for sourceURL: URL) -> String {
        let originalName = sourceURL.deletingPathExtension().lastPathComponent
        let fileExtension = sourceURL.pathExtension
        
        // Generate timestamp
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        
        // Create base filename
        let baseFilename = "\(originalName)_\(timestamp).\(fileExtension)"
        
        // Check if file exists and append number if needed
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destinationURL = documentsPath.appendingPathComponent(baseFilename)
        
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            var counter = 1
            var newFilename = baseFilename
            
            repeat {
                let nameWithoutExt = originalName
                newFilename = "\(nameWithoutExt)_\(timestamp)_\(counter).\(fileExtension)"
                let newURL = documentsPath.appendingPathComponent(newFilename)
                
                if !FileManager.default.fileExists(atPath: newURL.path) {
                    break
                }
                counter += 1
            } while true
            
            return newFilename
        }
        
        return baseFilename
    }
    
    private func validateAudioFile(at url: URL) throws {
        // Try to create an AVAudioPlayer to validate the file
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            if player.duration <= 0 {
                throw ImportError.invalidAudioFile("File has no audio content")
            }
        } catch {
            throw ImportError.invalidAudioFile("Unable to read audio file: \(error.localizedDescription)")
        }
    }
    
    private func transcodeFileToWhisperCompatibleFormat(originalURL: URL) async throws {
        // Create output URL with _whisper suffix to avoid conflicts
        let fileName = originalURL.deletingPathExtension().lastPathComponent
        let whisperURL = originalURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileName)_whisper.m4a")
        
        // Convert to Whisper-compatible M4A using AVAssetReader/AVAssetWriter
        let asset = AVURLAsset(url: originalURL)
        try await convertToWhisperCompatibleFormat(asset: asset, outputURL: whisperURL)
        
        // Update Core Data to point to the new Whisper-compatible file
        let recordingName = originalURL.deletingPathExtension().lastPathComponent
        
        // Find the recording entry
        let fetchRequest: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "recordingName == %@", recordingName)
        
        do {
            let recordings = try context.fetch(fetchRequest)
            if let recording = recordings.first {
                // Update the recording URL to point to the Whisper-compatible file
                recording.recordingURL = whisperURL.absoluteString
                recording.lastModified = Date()
                
                try context.save()
                print("✅ Updated Core Data entry to point to Whisper-compatible file")
            } else {
                print("⚠️ No Core Data entry found for recording: \(recordingName)")
            }
        } catch {
            print("❌ Failed to update Core Data entry: \(error)")
            throw ImportError.copyFailed("Failed to update database: \(error.localizedDescription)")
        }
        
        // Replace the original file with the Whisper-compatible version
        try await replaceOriginalWithWhisperCompatible(originalURL: originalURL, whisperURL: whisperURL)
    }
    
    private func convertToWhisperCompatibleFormat(asset: AVURLAsset, outputURL: URL) async throws {
        // Remove existing file if it exists
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        
        // Create asset reader
        let assetReader = try AVAssetReader(asset: asset)
        
        // Get audio track
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ImportError.invalidAudioFile("No audio track found")
        }
        
        // Create reader output
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 22050,  // Match writer sample rate
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        
        assetReader.add(readerOutput)
        
        // Create asset writer with M4A format (supported)
        let assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        
        // Create writer input with Whisper-compatible settings
        // Use 22kHz instead of 16kHz for better AAC compatibility, still good for Whisper
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 22050,  // Slightly higher for AAC compatibility
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,  // More compatible
            AVEncoderBitRateKey: 64000
        ])
        
        assetWriter.add(writerInput)
        
        // Start reading and writing
        assetReader.startReading()
        assetWriter.startWriting()
        assetWriter.startSession(atSourceTime: .zero)
        
        // Process audio data
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "whisper-conversion", qos: .userInitiated)
            writerInput.requestMediaDataWhenReady(on: queue) { [writerInput, readerOutput, assetWriter] in
                while writerInput.isReadyForMoreMediaData {
                    if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                        writerInput.append(sampleBuffer)
                    } else {
                        writerInput.markAsFinished()
                        
                        assetWriter.finishWriting { [assetWriter] in
                            switch assetWriter.status {
                            case .completed:
                                continuation.resume()
                            case .failed:
                                let error = assetWriter.error ?? ImportError.copyFailed("Whisper-compatible format export failed")
                                continuation.resume(throwing: error)
                            default:
                                let error = ImportError.copyFailed("Whisper-compatible format export failed with status: \(assetWriter.status)")
                                continuation.resume(throwing: error)
                            }
                        }
                        break
                    }
                }
            }
        }
    }
    
    private func replaceOriginalWithWhisperCompatible(originalURL: URL, whisperURL: URL) async throws {
        print("🔄 Replacing original M4A with Whisper-compatible version...")
        
        // Create backup of original (just in case)
        let backupURL = originalURL.appendingPathExtension("bak")
        try FileManager.default.moveItem(at: originalURL, to: backupURL)
        
        // Move Whisper-compatible file to original location (to maintain compatibility with existing code)
        let finalURL = originalURL // Keep the same name/extension for compatibility
        try FileManager.default.moveItem(at: whisperURL, to: finalURL)
        
        // Verify the file exists and has content
        let attributes = try FileManager.default.attributesOfItem(atPath: finalURL.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        
        if fileSize > 0 {
            print("✅ Successfully replaced with Whisper-compatible format (\(fileSize) bytes)")
            // Remove backup
            try? FileManager.default.removeItem(at: backupURL)
        } else {
            print("❌ Whisper-compatible file is empty, restoring original")
            // Restore original
            try FileManager.default.moveItem(at: backupURL, to: originalURL)
            throw ImportError.copyFailed("Whisper-compatible file is empty")
        }
    }
    
    private func completeImport(with results: ImportResults) {
        importResults = results
        isImporting = false
        showingImportAlert = true
    }
    
    // MARK: - Progress Tracking
    
    var progressText: String {
        if isImporting {
            return "\(Int(importProgress * 100))% - \(currentlyImporting)"
        }
        return ""
    }
    
    var canImport: Bool {
        return !isImporting
    }
    
    // MARK: - Core Data Integration
    
    private func createRecordingEntryForImportedFile(at fileURL: URL) async throws {
        let recordingName = fileURL.deletingPathExtension().lastPathComponent
        
        // Check if recording already exists
        let fetchRequest: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "recordingName == %@", recordingName)
        
        do {
            let existingRecordings = try context.fetch(fetchRequest)
            if !existingRecordings.isEmpty {
                print("⏭️ Recording entry already exists: \(recordingName)")
                return
            }
        } catch {
            print("❌ Error checking for existing recording: \(error)")
            throw ImportError.copyFailed("Failed to check existing recordings: \(error.localizedDescription)")
        }
        
        // Create new recording entry
        let recordingEntry = RecordingEntry(context: context)
        recordingEntry.id = UUID()
        recordingEntry.recordingName = recordingName
        recordingEntry.recordingURL = fileURL.absoluteString
        
        // Get file metadata
        do {
            let resourceValues = try fileURL.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
            recordingEntry.recordingDate = resourceValues.creationDate ?? Date()
            recordingEntry.createdAt = resourceValues.creationDate ?? Date()
            recordingEntry.lastModified = Date()
            recordingEntry.fileSize = Int64(resourceValues.fileSize ?? 0)
            
            // Get duration
            let duration = await getAudioDuration(url: fileURL)
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
        
        // Save the context
        do {
            try context.save()
            print("✅ Created Core Data entry for imported file: \(recordingName)")
        } catch {
            print("❌ Failed to save Core Data entry: \(error)")
            throw ImportError.copyFailed("Failed to save to database: \(error.localizedDescription)")
        }
    }
    
    private func getAudioDuration(url: URL) async -> TimeInterval {
        do {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            return CMTimeGetSeconds(duration)
        } catch {
            print("❌ Error getting audio duration: \(error)")
            return 0
        }
    }
    
    private func isAlreadyWhisperOptimized(_ url: URL) async -> Bool {
        do {
            let asset = AVURLAsset(url: url)
            guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
                return false
            }
            
            let formatDescriptions = try await audioTrack.load(.formatDescriptions)
            guard let formatDescription = formatDescriptions.first else {
                return false
            }
            
            let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
            guard let asbd = audioStreamBasicDescription?.pointee else {
                return false
            }
            
            // Check if it's already optimal - either 22kHz or 44.1kHz AAC mono
            let isOptimal = (asbd.mSampleRate == 22050.0 || asbd.mSampleRate == 44100.0) && 
                           asbd.mChannelsPerFrame == 1 && 
                           asbd.mFormatID == kAudioFormatMPEG4AAC
            
            if isOptimal {
                print("📋 File \(url.lastPathComponent) is already optimized (\(asbd.mSampleRate)Hz AAC mono)")
            }
            
            return isOptimal
            
        } catch {
            print("⚠️ Error checking audio format for \(url.lastPathComponent): \(error)")
            return false
        }
    }
    
    private func fixCoreDataPointingToWhisperFile(_ whisperFileURL: URL) async {
        // Extract the original recording name from the _whisper filename
        let whisperFileName = whisperFileURL.lastPathComponent
        guard let originalName = extractOriginalRecordingName(from: whisperFileName) else {
            print("⚠️ Could not extract original name from: \(whisperFileName)")
            return
        }
        
        // Look for the original file (without _whisper)
        let documentsPath = whisperFileURL.deletingLastPathComponent()
        let originalFileURL = documentsPath.appendingPathComponent("\(originalName).m4a")
        
        // Check if the original file exists
        guard FileManager.default.fileExists(atPath: originalFileURL.path) else {
            print("⚠️ Original file not found for \(whisperFileName)")
            return
        }
        
        // Find Core Data entry and update it
        let fetchRequest: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "recordingURL == %@", whisperFileURL.absoluteString)
        
        do {
            let recordings = try context.fetch(fetchRequest)
            for recording in recordings {
                recording.recordingURL = originalFileURL.absoluteString
                recording.lastModified = Date()
                print("🔄 Fixed Core Data entry: \(originalName) now points to original file")
            }
            
            if !recordings.isEmpty {
                try context.save()
                print("✅ Updated \(recordings.count) Core Data entries")
            }
        } catch {
            print("❌ Failed to fix Core Data entries: \(error)")
        }
    }
    
    private func extractOriginalRecordingName(from whisperFileName: String) -> String? {
        // Remove the .m4a extension first
        let nameWithoutExtension = whisperFileName.replacingOccurrences(of: ".m4a", with: "")
        
        // Look for _whisper and remove everything from that point
        if let whisperRange = nameWithoutExtension.range(of: "_whisper") {
            return String(nameWithoutExtension[..<whisperRange.lowerBound])
        }
        
        return nil
    }
}

// MARK: - Import Errors

enum ImportError: LocalizedError {
    case unsupportedFormat(String)
    case fileAlreadyExists(String)
    case invalidAudioFile(String)
    case copyFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            return "Unsupported audio format: \(format). Supported formats: m4a, mp3, wav"
        case .fileAlreadyExists(let filename):
            return "File already exists: \(filename)"
        case .invalidAudioFile(let reason):
            return "Invalid audio file: \(reason)"
        case .copyFailed(let reason):
            return "Failed to copy file: \(reason)"
        }
    }
}



// MARK: - Supporting Structures

struct ImportResults {
    let total: Int
    let successful: Int
    let failed: Int
    let errors: [String]
    
    var successRate: Double {
        return total > 0 ? Double(successful) / Double(total) : 0.0
    }
    
    var formattedSuccessRate: String {
        return String(format: "%.1f%%", successRate * 100)
    }
    
    var summary: String {
        if total == 0 {
            return "No files selected for import"
        } else if failed == 0 {
            return "Successfully imported all \(successful) files"
        } else {
            return "Imported \(successful) of \(total) files successfully"
        }
    }
} 