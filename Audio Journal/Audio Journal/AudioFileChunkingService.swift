//
//  AudioFileChunkingService.swift
//  Audio Journal
//
//  Service for chunking large audio files based on transcription service limits
//

import Foundation
import AVFoundation

@MainActor
class AudioFileChunkingService: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var isChunking = false
    @Published var currentStatus = ""
    @Published var progress: Double = 0.0
    
    // MARK: - Private Properties
    
    private let fileManager = FileManager.default
    
    // MARK: - Public Methods
    
    /// Determines if a file needs chunking based on the transcription service
    func shouldChunkFile(_ url: URL, for engine: TranscriptionEngine) async throws -> Bool {
        guard fileManager.fileExists(atPath: url.path) else {
            throw AudioChunkingError.fileNotFound
        }
        
        let config = ChunkingConfig.config(for: engine)
        let fileInfo = try await AudioFileInfo.create(from: url)
        
        switch config.strategy {
        case .fileSize(let maxBytes):
            return fileInfo.fileSize > maxBytes
        case .duration(let maxSeconds):
            return fileInfo.duration > maxSeconds
        }
    }
    
    /// Chunks an audio file based on the transcription service requirements
    func chunkAudioFile(_ url: URL, for engine: TranscriptionEngine) async throws -> ChunkingResult {
        guard fileManager.fileExists(atPath: url.path) else {
            throw AudioChunkingError.fileNotFound
        }
        
        isChunking = true
        currentStatus = "Analyzing audio file..."
        progress = 0.0
        
        let startTime = Date()
        
        do {
            let config = ChunkingConfig.config(for: engine)
            let fileInfo = try await AudioFileInfo.create(from: url)
            
            print("🔍 Analyzing file: \(url.lastPathComponent)")
            print("📊 Duration: \(fileInfo.duration)s, Size: \(fileInfo.fileSize) bytes")
            
            currentStatus = "Checking if chunking is needed..."
            progress = 0.1
            
            // Check if chunking is needed
            let needsChunking = try await shouldChunkFile(url, for: engine)
            
            if !needsChunking {
                print("✅ File doesn't need chunking")
                // Create a single "chunk" representing the whole file
                let singleChunk = AudioChunk(
                    originalURL: url,
                    chunkURL: url,
                    sequenceNumber: 0,
                    startTime: 0,
                    endTime: fileInfo.duration,
                    fileSize: fileInfo.fileSize
                )
                
                let result = ChunkingResult(
                    chunks: [singleChunk],
                    totalDuration: fileInfo.duration,
                    totalSize: fileInfo.fileSize,
                    chunkingTime: Date().timeIntervalSince(startTime)
                )
                
                isChunking = false
                currentStatus = "No chunking needed"
                progress = 1.0
                
                return result
            }
            
            print("⚡ File needs chunking for \(engine.rawValue)")
            
            // Create temp directory
            try createTempDirectory(config.tempDirectory)
            
            currentStatus = "Preparing to chunk file..."
            progress = 0.2
            
            let chunks: [AudioChunk]
            
            switch config.strategy {
            case .fileSize(let maxBytes):
                chunks = try await chunkByFileSize(url, maxBytes: maxBytes, config: config, fileInfo: fileInfo)
            case .duration(let maxSeconds):
                chunks = try await chunkByDuration(url, maxSeconds: maxSeconds, config: config, fileInfo: fileInfo)
            }
            
            let chunkingTime = Date().timeIntervalSince(startTime)
            
            print("✅ Chunking complete: \(chunks.count) chunks created in \(chunkingTime)s")
            
            let result = ChunkingResult(
                chunks: chunks,
                totalDuration: fileInfo.duration,
                totalSize: fileInfo.fileSize,
                chunkingTime: chunkingTime
            )
            
            isChunking = false
            currentStatus = "Chunking complete"
            progress = 1.0
            
            return result
            
        } catch {
            isChunking = false
            currentStatus = "Chunking failed"
            progress = 0.0
            throw error
        }
    }
    
    /// Reassembles transcript chunks into a complete TranscriptData object
    func reassembleTranscript(from chunks: [TranscriptChunk], originalURL: URL, recordingName: String, recordingDate: Date) async throws -> ReassemblyResult {
        let startTime = Date()
        
        print("🔧 Reassembling transcript from \(chunks.count) chunks")
        
        guard !chunks.isEmpty else {
            throw AudioChunkingError.reassemblyFailed("No transcript chunks provided")
        }
        
        // Sort chunks by sequence number
        let sortedChunks = chunks.sorted { $0.sequenceNumber < $1.sequenceNumber }
        
        // Validate sequence numbers are continuous
        for (index, chunk) in sortedChunks.enumerated() {
            guard chunk.sequenceNumber == index else {
                throw AudioChunkingError.reassemblyFailed("Missing chunk sequence number \(index)")
            }
        }
        
        // Combine all segments with time offset adjustments
        var allSegments: [TranscriptSegment] = []
        var speakerMappings: [String: String] = [:]
        
        for chunk in sortedChunks {
            for segment in chunk.segments {
                // Adjust segment times based on chunk start time
                let adjustedSegment = TranscriptSegment(
                    speaker: segment.speaker,
                    text: segment.text,
                    startTime: segment.startTime + chunk.startTime,
                    endTime: segment.endTime + chunk.startTime
                )
                allSegments.append(adjustedSegment)
                
                // Merge speaker mappings (preserve existing mappings)
                if speakerMappings[segment.speaker] == nil {
                    speakerMappings[segment.speaker] = segment.speaker
                }
            }
        }
        
        // Remove duplicate segments that might occur due to overlap
        allSegments = removeDuplicateSegments(allSegments)
        
        // Create the complete transcript
        let transcriptData = TranscriptData(
            recordingURL: originalURL,
            recordingName: recordingName,
            recordingDate: recordingDate,
            segments: allSegments,
            speakerMappings: speakerMappings
        )
        
        let reassemblyTime = Date().timeIntervalSince(startTime)
        
        print("✅ Transcript reassembly complete: \(allSegments.count) segments in \(reassemblyTime)s")
        
        return ReassemblyResult(
            transcriptData: transcriptData,
            totalSegments: allSegments.count,
            reassemblyTime: reassemblyTime,
            chunks: sortedChunks
        )
    }
    
    /// Creates transcript chunks from transcription results
    func createTranscriptChunk(from transcriptText: String, audioChunk: AudioChunk, segments: [TranscriptSegment] = []) -> TranscriptChunk {
        // If no segments provided, create a single segment from the transcript text
        let chunkSegments = segments.isEmpty ? [
            TranscriptSegment(
                speaker: "Speaker",
                text: transcriptText,
                startTime: 0.0,
                endTime: audioChunk.duration
            )
        ] : segments
        
        return TranscriptChunk(
            chunkId: audioChunk.id,
            sequenceNumber: audioChunk.sequenceNumber,
            transcript: transcriptText,
            segments: chunkSegments,
            startTime: audioChunk.startTime,
            endTime: audioChunk.endTime
        )
    }
    
    /// Cleans up temporary chunk files
    func cleanupChunks(_ chunks: [AudioChunk]) async throws {
        print("🧹 Cleaning up \(chunks.count) chunk files")
        
        var errors: [Error] = []
        var deletedCount = 0
        
        for chunk in chunks {
            // Don't delete the original file
            if chunk.chunkURL != chunk.originalURL {
                do {
                    if fileManager.fileExists(atPath: chunk.chunkURL.path) {
                        try fileManager.removeItem(at: chunk.chunkURL)
                        print("🗑️ Deleted chunk: \(chunk.chunkURL.lastPathComponent)")
                        deletedCount += 1
                    }
                } catch {
                    print("⚠️ Failed to delete chunk \(chunk.chunkURL.lastPathComponent): \(error)")
                    errors.append(error)
                }
            }
        }
        
        // Also try to clean up the temp directory if it's empty
        if deletedCount > 0 {
            let tempDir = chunks.first?.chunkURL.deletingLastPathComponent()
            if let tempDir = tempDir {
                try? cleanupTempDirectory(tempDir)
            }
        }
        
        if !errors.isEmpty {
            let errorMessages = errors.map { $0.localizedDescription }.joined(separator: ", ")
            throw AudioChunkingError.cleanupFailed(errorMessages)
        }
        
        print("✅ Chunk cleanup complete: \(deletedCount) files deleted")
    }
    
    /// Gets information about an audio file without chunking
    func getAudioFileInfo(_ url: URL) async throws -> AudioFileInfo {
        guard fileManager.fileExists(atPath: url.path) else {
            throw AudioChunkingError.fileNotFound
        }
        
        return try await AudioFileInfo.create(from: url)
    }
    
    /// Validates that all chunks exist and are accessible
    func validateChunks(_ chunks: [AudioChunk]) async throws -> Bool {
        for chunk in chunks {
            guard fileManager.fileExists(atPath: chunk.chunkURL.path) else {
                throw AudioChunkingError.chunkingFailed("Chunk file not found: \(chunk.chunkURL.lastPathComponent)")
            }
            
            // Verify chunk is readable
            do {
                let _ = try Data(contentsOf: chunk.chunkURL)
            } catch {
                throw AudioChunkingError.chunkingFailed("Chunk file not readable: \(chunk.chunkURL.lastPathComponent)")
            }
        }
        
        return true
    }
    
    // MARK: - Private Methods
    
    private func createTempDirectory(_ url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                print("📁 Created temp directory: \(url.path)")
            } catch {
                print("❌ Failed to create temp directory: \(error)")
                throw AudioChunkingError.tempDirectoryCreationFailed
            }
        }
    }
    
    private func chunkByFileSize(_ url: URL, maxBytes: Int64, config: ChunkingConfig, fileInfo: AudioFileInfo) async throws -> [AudioChunk] {
        print("📏 Chunking by file size: max \(maxBytes / 1024 / 1024)MB per chunk")
        
        // For file size chunking, we need to estimate duration per chunk based on file size ratio
        // This is an approximation since we can't easily split audio files by exact byte count
        // We'll split by duration but ensure each chunk is under the size limit
        
        let bytesPerSecond = Double(fileInfo.fileSize) / fileInfo.duration
        let maxDurationPerChunk = Double(maxBytes) / bytesPerSecond
        
        print("📊 Estimated \(bytesPerSecond) bytes/second, max duration per chunk: \(maxDurationPerChunk)s")
        
        return try await chunkByDuration(url, maxSeconds: maxDurationPerChunk, config: config, fileInfo: fileInfo)
    }
    
    private func chunkByDuration(_ url: URL, maxSeconds: TimeInterval, config: ChunkingConfig, fileInfo: AudioFileInfo) async throws -> [AudioChunk] {
        print("⏱️ Chunking by duration: max \(maxSeconds)s per chunk")
        
        let asset = AVURLAsset(url: url)
        let totalDuration = fileInfo.duration
        
        // Calculate number of chunks needed
        let chunkCount = Int(ceil(totalDuration / maxSeconds))
        print("📊 Will create \(chunkCount) chunks")
        
        var chunks: [AudioChunk] = []
        
        for i in 0..<chunkCount {
            let startTime = Double(i) * maxSeconds
            let endTime = min(startTime + maxSeconds, totalDuration)
            
            // Add overlap for continuity (except for the last chunk)
            let actualEndTime = (i < chunkCount - 1) ? min(endTime + config.overlapSeconds, totalDuration) : endTime
            
            currentStatus = "Creating chunk \(i + 1) of \(chunkCount)..."
            progress = 0.3 + (0.6 * Double(i) / Double(chunkCount))
            
            print("🔧 Creating chunk \(i): \(startTime)s - \(actualEndTime)s")
            
            let chunkURL = config.tempDirectory.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)_chunk_\(i).\(url.pathExtension)")
            
            // Export the chunk
            try await exportAudioChunk(
                from: asset,
                startTime: startTime,
                endTime: actualEndTime,
                outputURL: chunkURL
            )
            
            // Get chunk file size
            let chunkAttributes = try fileManager.attributesOfItem(atPath: chunkURL.path)
            let chunkSize = chunkAttributes[.size] as? Int64 ?? 0
            
            let chunk = AudioChunk(
                originalURL: url,
                chunkURL: chunkURL,
                sequenceNumber: i,
                startTime: startTime,
                endTime: actualEndTime,
                fileSize: chunkSize
            )
            
            chunks.append(chunk)
            
            print("✅ Chunk \(i) created: \(chunkSize) bytes, \(actualEndTime - startTime)s duration")
        }
        
        return chunks
    }
    
    private func exportAudioChunk(from asset: AVAsset, startTime: TimeInterval, endTime: TimeInterval, outputURL: URL) async throws {
        // Remove existing file if it exists
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        
        // Create export session
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioChunkingError.chunkingFailed("Failed to create export session")
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        
        // Set time range with high precision
        let start = CMTime(seconds: startTime, preferredTimescale: 600)
        let duration = CMTime(seconds: endTime - startTime, preferredTimescale: 600)
        exportSession.timeRange = CMTimeRange(start: start, duration: duration)
        
        // Optimize for quality and speed
        exportSession.shouldOptimizeForNetworkUse = false
        exportSession.canPerformMultiplePassesOverSourceMediaData = false
        
        // Export the chunk using modern iOS 18 API
        do {
            try await exportSession.export(to: outputURL, as: .m4a)
        } catch {
            throw AudioChunkingError.chunkingFailed("Export failed: \(error.localizedDescription)")
        }
        
        // Verify the exported file exists and has content
        guard fileManager.fileExists(atPath: outputURL.path) else {
            throw AudioChunkingError.fileWriteFailed("Exported chunk file not found")
        }
        
        let attributes = try fileManager.attributesOfItem(atPath: outputURL.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        
        guard fileSize > 0 else {
            throw AudioChunkingError.fileWriteFailed("Exported chunk file is empty")
        }
    }
    
    private func cleanupTempDirectory(_ tempDir: URL) throws {
        // Only delete if directory is empty or only contains our chunk files
        let contents = try fileManager.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        
        // Check if all files are chunk files (contain "_chunk_" in name)
        let allChunkFiles = contents.allSatisfy { url in
            url.lastPathComponent.contains("_chunk_")
        }
        
        if contents.isEmpty || allChunkFiles {
            try fileManager.removeItem(at: tempDir)
            print("🗑️ Cleaned up temp directory: \(tempDir.lastPathComponent)")
        }
    }
    
    private func removeDuplicateSegments(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var uniqueSegments: [TranscriptSegment] = []
        var seenTexts: Set<String> = []
        
        for segment in segments {
            // Use a combination of text and approximate time to identify duplicates
            let key = "\(segment.text.prefix(50))_\(Int(segment.startTime))"
            
            if !seenTexts.contains(key) {
                seenTexts.insert(key)
                uniqueSegments.append(segment)
            } else {
                print("🔄 Removed duplicate segment: \(segment.text.prefix(30))...")
            }
        }
        
        return uniqueSegments
    }
}