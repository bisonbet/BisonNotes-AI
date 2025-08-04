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
    private let performanceOptimizer = PerformanceOptimizer.shared
    
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
        case .combined(let maxBytes, let maxSeconds):
            return fileInfo.fileSize > maxBytes || fileInfo.duration > maxSeconds
        }
    }
    
    /// Chunks an audio file based on the transcription service requirements with streaming optimization
    func chunkAudioFile(_ url: URL, for engine: TranscriptionEngine) async throws -> ChunkingResult {
        guard fileManager.fileExists(atPath: url.path) else {
            throw AudioChunkingError.fileNotFound
        }
        
        // Prevent recursive chunking - if this is already a chunk file, don't chunk it again
        if url.lastPathComponent.contains("chunk_") {
            print("⚠️ Skipping chunking for already chunked file: \(url.lastPathComponent)")
            let fileInfo = try await AudioFileInfo.create(from: url)
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
                chunkingTime: 0.0
            )
            
            return result
        }
        
        isChunking = true
        currentStatus = "Analyzing audio file..."
        progress = 0.0
        
        let startTime = Date()
        
        do {
            let config = ChunkingConfig.config(for: engine)
            let fileInfo = try await AudioFileInfo.create(from: url)
            
            EnhancedLogger.shared.logChunkingStart(url, strategy: config.strategy)
            EnhancedLogger.shared.logChunking("Duration: \(fileInfo.duration)s, Size: \(fileInfo.fileSize) bytes", level: .debug)
            
            currentStatus = "Checking if chunking is needed..."
            progress = 0.1
            
            // Check if chunking is needed
            let needsChunking = try await shouldChunkFile(url, for: engine)
            
            if !needsChunking {
                EnhancedLogger.shared.logChunking("File doesn't need chunking", level: .info)
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
            
            EnhancedLogger.shared.logChunking("File needs chunking for \(engine.rawValue)", level: .info)
            
            // Create temp directory
            try createTempDirectory(config.tempDirectory)
            
            currentStatus = "Preparing to chunk file with streaming optimization..."
            progress = 0.2
            
            let chunks: [AudioChunk]
            
            switch config.strategy {
            case .fileSize(let maxBytes):
                chunks = try await chunkByFileSizeWithStreaming(url, maxBytes: maxBytes, config: config, fileInfo: fileInfo)
            case .duration(let maxSeconds):
                chunks = try await chunkByDurationWithStreaming(url, maxSeconds: maxSeconds, config: config, fileInfo: fileInfo)
            case .combined(let maxBytes, let maxSeconds):
                chunks = try await chunkByCombinedStrategy(url, maxBytes: maxBytes, maxSeconds: maxSeconds, config: config, fileInfo: fileInfo)
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
    func reassembleTranscript(from chunks: [TranscriptChunk], originalURL: URL, recordingName: String, recordingDate: Date, recordingId: UUID) async throws -> ReassemblyResult {
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
        
        // Create the complete transcript with recording ID
        let transcriptData = TranscriptData(
            recordingId: recordingId,
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
            print("❌ Failed to create export session for output: \(outputURL)")
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
            print("❌ Export failed for output: \(outputURL)")
            throw AudioChunkingError.chunkingFailed("Export failed: \(error.localizedDescription)")
        }
        
        // Verify the exported file exists and has content
        guard fileManager.fileExists(atPath: outputURL.path) else {
            print("❌ Exported chunk file not found at: \(outputURL)")
            throw AudioChunkingError.fileWriteFailed("Exported chunk file not found")
        }
        
        let attributes = try fileManager.attributesOfItem(atPath: outputURL.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        if fileSize == 0 {
            print("❌ Exported chunk file is empty at: \(outputURL)")
            print("File attributes: \(attributes)")
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
    
    // MARK: - Streaming Chunking Methods
    
    private func chunkByFileSizeWithStreaming(_ url: URL, maxBytes: Int64, config: ChunkingConfig, fileInfo: AudioFileInfo) async throws -> [AudioChunk] {
        currentStatus = "Chunking by file size with streaming..."
        progress = 0.3
        
        let asset = AVURLAsset(url: url)
        let duration = fileInfo.duration
        let totalSize = fileInfo.fileSize
        
        // Calculate bytes per second to estimate duration limits
        let bytesPerSecond = Double(totalSize) / duration
        
        // Use a very conservative approach: target 60% of maxBytes to ensure we stay under limit
        let targetBytesPerChunk = Int64(Double(maxBytes) * 0.6)
        let maxDurationPerChunk = Double(targetBytesPerChunk) / bytesPerSecond
        
        print("📊 File analysis: \(bytesPerSecond) bytes/second, targeting \(targetBytesPerChunk / 1024 / 1024)MB chunks")
        print("📏 Max duration per chunk: \(maxDurationPerChunk)s")
        
        var chunks: [AudioChunk] = []
        var currentTime: TimeInterval = 0
        var sequenceNumber = 0
        var adaptiveDuration = maxDurationPerChunk
        
        while currentTime < duration {
            let chunkStartTime = currentTime
            let chunkEndTime = min(currentTime + adaptiveDuration, duration)
            
            currentStatus = "Creating chunk \(sequenceNumber + 1)..."
            progress = 0.3 + (0.6 * (currentTime / duration))
            
            let chunkURL = config.tempDirectory.appendingPathComponent("chunk_\(sequenceNumber).m4a")
            
            // Use streaming export for memory efficiency
            try await exportAudioChunkWithStreaming(from: asset, startTime: chunkStartTime, endTime: chunkEndTime, outputURL: chunkURL)
            
            // Get actual chunk size
            let chunkAttributes = try fileManager.attributesOfItem(atPath: chunkURL.path)
            let chunkSize = chunkAttributes[.size] as? Int64 ?? 0
            
            // Verify chunk size is under limit and adjust if needed
            if chunkSize > maxBytes {
                print("⚠️ Chunk \(sequenceNumber) is too large (\(chunkSize) bytes > \(maxBytes) bytes)")
                print("📏 Chunk duration was \(chunkEndTime - chunkStartTime)s")
                
                // Reduce duration for future chunks by 40% (more aggressive)
                adaptiveDuration = adaptiveDuration * 0.6
                print("🔄 Adjusting chunk duration to \(adaptiveDuration)s for future chunks")
                
                // If this is the first chunk and it's too large, we need to be very aggressive
                if sequenceNumber == 0 {
                    adaptiveDuration = adaptiveDuration * 0.3 // Reduce by 70% for first chunk
                    print("🔄 First chunk too large, reducing duration to \(adaptiveDuration)s")
                }
            } else if chunkSize < Int64(Double(targetBytesPerChunk) * 0.5) {
                // If chunk is much smaller than target, we can increase duration slightly
                adaptiveDuration = min(adaptiveDuration * 1.1, maxDurationPerChunk)
                print("🔄 Chunk smaller than expected, increasing duration to \(adaptiveDuration)s")
            }
            
            let chunk = AudioChunk(
                originalURL: url,
                chunkURL: chunkURL,
                sequenceNumber: sequenceNumber,
                startTime: chunkStartTime,
                endTime: chunkEndTime,
                fileSize: chunkSize
            )
            
            chunks.append(chunk)
            
            print("✅ Chunk \(sequenceNumber) created: \(chunkSize) bytes, \(chunkEndTime - chunkStartTime)s duration")
            
            currentTime = chunkEndTime
            sequenceNumber += 1
            
            // Battery-aware processing delay
            if performanceOptimizer.batteryInfo.shouldOptimizeForBattery {
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms delay
            }
        }
        
        return chunks
    }
    
    private func chunkByDurationWithStreaming(_ url: URL, maxSeconds: TimeInterval, config: ChunkingConfig, fileInfo: AudioFileInfo) async throws -> [AudioChunk] {
        currentStatus = "Chunking by duration with streaming..."
        progress = 0.3
        
        let asset = AVURLAsset(url: url)
        let duration = fileInfo.duration
        
        var chunks: [AudioChunk] = []
        var currentTime: TimeInterval = 0
        var sequenceNumber = 0
        
        while currentTime < duration {
            let chunkStartTime = currentTime
            let chunkEndTime = min(currentTime + maxSeconds, duration)
            
            currentStatus = "Creating chunk \(sequenceNumber + 1)..."
            progress = 0.3 + (0.6 * (currentTime / duration))
            
            let chunkURL = config.tempDirectory.appendingPathComponent("chunk_\(sequenceNumber).m4a")
            
            // Use streaming export for memory efficiency
            try await exportAudioChunkWithStreaming(from: asset, startTime: chunkStartTime, endTime: chunkEndTime, outputURL: chunkURL)
            
            // Get actual chunk size and duration
            let chunkAttributes = try fileManager.attributesOfItem(atPath: chunkURL.path)
            let chunkSize = chunkAttributes[.size] as? Int64 ?? 0
            let actualEndTime = chunkEndTime
            
            let chunk = AudioChunk(
                originalURL: url,
                chunkURL: chunkURL,
                sequenceNumber: sequenceNumber,
                startTime: chunkStartTime,
                endTime: actualEndTime,
                fileSize: chunkSize
            )
            
            chunks.append(chunk)
            
            print("✅ Chunk \(sequenceNumber) created: \(chunkSize) bytes, \(actualEndTime - chunkStartTime)s duration")
            
            currentTime = chunkEndTime
            sequenceNumber += 1
            
            // Battery-aware processing delay
            if performanceOptimizer.batteryInfo.shouldOptimizeForBattery {
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms delay
            }
        }
        
        return chunks
    }
    
    private func exportAudioChunkWithStreaming(from asset: AVAsset, startTime: TimeInterval, endTime: TimeInterval, outputURL: URL) async throws {
        // Remove existing file if it exists
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        
        // Create export session with optimized settings
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            print("❌ Failed to create export session for output: \(outputURL)")
            throw AudioChunkingError.chunkingFailed("Failed to create export session")
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        
        // Set time range with high precision
        let start = CMTime(seconds: startTime, preferredTimescale: 600)
        let duration = CMTime(seconds: endTime - startTime, preferredTimescale: 600)
        exportSession.timeRange = CMTimeRange(start: start, duration: duration)
        
        // Optimize for streaming
        exportSession.shouldOptimizeForNetworkUse = true
        exportSession.canPerformMultiplePassesOverSourceMediaData = false
        
        // Export the chunk using modern iOS 18 API with streaming
        do {
            try await exportSession.export(to: outputURL, as: .m4a)
        } catch {
            print("❌ Export failed for output: \(outputURL)")
            throw AudioChunkingError.chunkingFailed("Export failed: \(error.localizedDescription)")
        }
        
        // Verify the exported file exists and has content
        guard fileManager.fileExists(atPath: outputURL.path) else {
            print("❌ Exported file not found at: \(outputURL)")
            throw AudioChunkingError.chunkingFailed("Exported file not found")
        }
        let attributes = try fileManager.attributesOfItem(atPath: outputURL.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        if fileSize == 0 {
            print("❌ Exported file is empty at: \(outputURL)")
            print("File attributes: \(attributes)")
            throw AudioChunkingError.chunkingFailed("Exported file is empty")
        }
    }
    
    private func chunkByCombinedStrategy(_ url: URL, maxBytes: Int64, maxSeconds: TimeInterval, config: ChunkingConfig, fileInfo: AudioFileInfo) async throws -> [AudioChunk] {
        currentStatus = "Chunking with combined size and duration limits..."
        progress = 0.3
        
        let asset = AVURLAsset(url: url)
        let duration = fileInfo.duration
        let totalSize = fileInfo.fileSize
        
        // Calculate bytes per second to estimate chunk sizes
        let bytesPerSecond = Double(totalSize) / duration
        
        // Determine the more restrictive limit
        let maxDurationFromSize = Double(maxBytes) / bytesPerSecond
        let effectiveMaxSeconds = min(maxSeconds, maxDurationFromSize)
        
        print("📊 Combined strategy: Duration limit \(maxSeconds)s, Size-based duration limit \(maxDurationFromSize)s")
        print("📏 Using effective limit: \(effectiveMaxSeconds)s")
        
        var chunks: [AudioChunk] = []
        var currentTime: TimeInterval = 0
        var sequenceNumber = 0
        var adaptiveDuration = effectiveMaxSeconds
        
        while currentTime < duration {
            let chunkStartTime = currentTime
            let chunkEndTime = min(currentTime + adaptiveDuration, duration)
            
            currentStatus = "Creating chunk \(sequenceNumber + 1) with combined limits..."
            progress = 0.3 + (0.6 * (currentTime / duration))
            
            let chunkURL = config.tempDirectory.appendingPathComponent("chunk_\(sequenceNumber).m4a")
            
            // Export chunk with streaming
            try await exportAudioChunkWithStreaming(from: asset, startTime: chunkStartTime, endTime: chunkEndTime, outputURL: chunkURL)
            
            // Get actual chunk size and validate against both limits
            let chunkAttributes = try fileManager.attributesOfItem(atPath: chunkURL.path)
            let chunkSize = chunkAttributes[.size] as? Int64 ?? 0
            let chunkDuration = chunkEndTime - chunkStartTime
            
            // Check if chunk violates either limit
            if chunkSize > maxBytes {
                print("⚠️ Chunk \(sequenceNumber) exceeds size limit (\(chunkSize) bytes > \(maxBytes) bytes)")
                adaptiveDuration = adaptiveDuration * 0.7 // Reduce by 30%
                print("🔄 Reducing chunk duration to \(adaptiveDuration)s")
                
                // Remove the oversized chunk and try again
                try? fileManager.removeItem(at: chunkURL)
                continue
                
            } else if chunkDuration > maxSeconds {
                print("⚠️ Chunk \(sequenceNumber) exceeds duration limit (\(chunkDuration)s > \(maxSeconds)s)")
                adaptiveDuration = min(adaptiveDuration * 0.8, maxSeconds) // Reduce but cap at maxSeconds
                print("🔄 Reducing chunk duration to \(adaptiveDuration)s")
                
                // Remove the oversized chunk and try again
                try? fileManager.removeItem(at: chunkURL)
                continue
            }
            
            // Chunk is within both limits
            let chunk = AudioChunk(
                originalURL: url,
                chunkURL: chunkURL,
                sequenceNumber: sequenceNumber,
                startTime: chunkStartTime,
                endTime: chunkEndTime,
                fileSize: chunkSize
            )
            
            chunks.append(chunk)
            
            print("✅ Chunk \(sequenceNumber) created: \(chunkSize) bytes, \(chunkDuration)s duration")
            
            currentTime = chunkEndTime
            sequenceNumber += 1
            
            // Optimize chunk size for next iteration
            let sizeUtilization = Double(chunkSize) / Double(maxBytes)
            let durationUtilization = chunkDuration / maxSeconds
            
            if sizeUtilization < 0.6 && durationUtilization < 0.6 {
                // Chunk is much smaller than limits, can increase slightly
                adaptiveDuration = min(adaptiveDuration * 1.1, effectiveMaxSeconds)
            }
            
            // Battery-aware processing delay
            if performanceOptimizer.batteryInfo.shouldOptimizeForBattery {
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms delay
            }
        }
        
        return chunks
    }
}