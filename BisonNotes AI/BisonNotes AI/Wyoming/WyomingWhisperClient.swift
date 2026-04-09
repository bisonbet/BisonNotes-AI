//
//  WyomingWhisperClient.swift
//  Audio Journal
//
//  Wyoming protocol client specifically for Whisper transcription
//

import Foundation
import AVFoundation
import UIKit

@MainActor
class WyomingWhisperClient: ObservableObject {

    // MARK: - Properties

    @Published var isConnected = false
    @Published var connectionError: String?
    @Published var isTranscribing = false
    @Published var currentStatus = ""
    @Published var progress: Double = 0.0

    private let tcpClient: WyomingTCPClient
    private let config: WhisperConfig
    private var currentTranscription: CheckedContinuation<TranscriptionResult, Error>?
    private var transcriptionResult = ""
    private var serverInfo: WyomingInfoData?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var streamingTimeoutTask: Task<Void, Never>?
    private var isProcessingChunk = false
    private var shouldManageBackgroundTask = true // Can be disabled when called from another background context

    // MARK: - Initialization

    init(config: WhisperConfig) {
        self.config = config

        // Extract host from server URL
        let host = Self.extractHost(from: config.serverURL)
        AppLog.shared.transcription("Wyoming TCP connection: \(host):\(config.port)", level: .debug)

        self.tcpClient = WyomingTCPClient(host: host, port: config.port)
        setupMessageHandlers()
    }

    /// Disable background task management when called from another background context
    func disableBackgroundTaskManagement() {
        shouldManageBackgroundTask = false
    }

    /// Re-enable background task management
    func enableBackgroundTaskManagement() {
        shouldManageBackgroundTask = true
    }

    private static func extractHost(from serverURL: String) -> String {
        var url = serverURL

        // Remove any protocol scheme
        if let range = url.range(of: "://") {
            url = String(url[range.upperBound...])
        }

        // Remove any path
        if let range = url.range(of: "/") {
            url = String(url[..<range.lowerBound])
        }

        // Remove any port (we'll use the config port)
        if let range = url.range(of: ":") {
            url = String(url[..<range.lowerBound])
        }

        return url.isEmpty ? "localhost" : url
    }

    // MARK: - Message Handlers

    private func setupMessageHandlers() {
        // Handle server info responses
        tcpClient.registerHandler(for: .info) { [weak self] message in
            Task { @MainActor in
                await self?.handleInfoMessage(message)
            }
        }

        // Handle transcription results
        tcpClient.registerHandler(for: .transcript) { [weak self] message in
            Task { @MainActor in
                await self?.handleTranscriptMessage(message)
            }
        }

        // Handle errors
        tcpClient.registerHandler(for: .error) { [weak self] message in
            Task { @MainActor in
                await self?.handleErrorMessage(message)
            }
        }
    }

    private func handleInfoMessage(_ message: WyomingMessage) async {
        guard let infoData = message.parseData(as: WyomingInfoData.self) else {
            AppLog.shared.transcription("Failed to parse info message", level: .error)
            return
        }

        serverInfo = infoData
        AppLog.shared.transcription("Wyoming server info received")

        if let asrInfo = infoData.asr?.first {
            AppLog.shared.transcription("ASR: \(asrInfo.name), version: \(asrInfo.version ?? "unknown"), models: \(asrInfo.models?.count ?? 0)", level: .debug)
        }

        isConnected = true
        connectionError = nil
    }

    private func handleTranscriptMessage(_ message: WyomingMessage) async {
        guard let transcriptData = message.parseData(as: WyomingTranscriptData.self) else {
            AppLog.shared.transcription("Failed to parse transcript message", level: .error)
            return
        }

        AppLog.shared.transcription("Received transcription result: \(transcriptData.text.count) chars")
        transcriptionResult = transcriptData.text

        // Complete the transcription
        if let activeContinuation = currentTranscription {
            let result = TranscriptionResult(
                fullText: transcriptData.text,
                segments: [TranscriptSegment(
                    speaker: "Speaker",
                    text: transcriptData.text,
                    startTime: 0.0,
                    endTime: 0.0
                )],
                processingTime: 0.0,
                chunkCount: 1,
                success: true,
                error: nil
            )

            currentTranscription = nil

            isTranscribing = false
            currentStatus = "Transcription completed"
            progress = 1.0

            // Clean up background task and timeout (only for standalone transcriptions)
            self.cancelStreamingTimeout()
            if !self.isProcessingChunk && self.shouldManageBackgroundTask {
                self.endBackgroundTask()
            }

            // For standalone transcriptions (not chunks), disconnect to clean up
            if !self.isProcessingChunk {
                AppLog.shared.transcription("Disconnecting after standalone transcription completion", level: .debug)
                self.tcpClient.disconnect()
            }

            activeContinuation.resume(returning: result)
        }
    }

    private func handleErrorMessage(_ message: WyomingMessage) async {
        guard let errorData = message.parseData(as: WyomingErrorData.self) else {
            AppLog.shared.transcription("Failed to parse error message", level: .error)
            return
        }

        AppLog.shared.transcription("Wyoming server error: \(errorData.code) - \(errorData.message)", level: .error)

        // Thread-safe continuation handling for server errors
        if let activeContinuation = currentTranscription {
            currentTranscription = nil
            isTranscribing = false
            currentStatus = "Error: \(errorData.message)"
            self.cancelStreamingTimeout()
            if !self.isProcessingChunk && self.shouldManageBackgroundTask {
                self.endBackgroundTask()
            }

            // For standalone transcriptions (not chunks), disconnect on error
            if !self.isProcessingChunk {
                AppLog.shared.transcription("Disconnecting after standalone transcription error", level: .debug)
                self.tcpClient.disconnect()
            }

            let error = WyomingError.serverError("\(errorData.code): \(errorData.message)")
            activeContinuation.resume(throwing: error)
        } else {
            isTranscribing = false
            currentStatus = "Error: \(errorData.message)"
            connectionError = errorData.message

            // Clean up background task and timeout on error
            cancelStreamingTimeout()
            if shouldManageBackgroundTask {
                endBackgroundTask()
            }

            // Disconnect connection on error
            AppLog.shared.transcription("Disconnecting after error without active transcription", level: .debug)
            tcpClient.disconnect()
        }
    }

    // MARK: - Connection Management

    func testConnection() async -> Bool {
        do {
            AppLog.shared.transcription("Wyoming client testing TCP connection", level: .debug)
            try await tcpClient.connect()
            AppLog.shared.transcription("Wyoming TCP connected, sending describe message", level: .debug)

            // Send describe message to get server info
            try await tcpClient.sendDescribe()

            // Wait a bit for the info response
            try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

            await MainActor.run {
                self.isConnected = true
                self.connectionError = nil
            }

            AppLog.shared.transcription("Wyoming connection test passed")
            return true

        } catch {
            AppLog.shared.transcription("Wyoming connection test failed: \(error)", level: .error)
            await MainActor.run {
                connectionError = error.localizedDescription
                isConnected = false
            }
            return false
        }
    }

    func disconnect() {
        tcpClient.disconnect()
        isConnected = false
        connectionError = nil
    }

    // MARK: - Transcription

    func transcribeAudio(url: URL, recordingId: UUID? = nil) async throws -> TranscriptionResult {
        AppLog.shared.transcription("WyomingWhisperClient.transcribeAudio called for: \(url.lastPathComponent)")

        // Check if file is longer than 5 minutes and needs chunking
        let duration = try await getAudioDuration(url: url)
        let maxChunkDuration: TimeInterval = 300 // 5 minutes

        if duration > maxChunkDuration {
            AppLog.shared.transcription("Audio duration (\(Int(duration))s) exceeds \(Int(maxChunkDuration))s, using chunked transcription")
            return try await transcribeAudioWithChunking(url: url, recordingId: recordingId, maxChunkDuration: maxChunkDuration)
        } else {
            AppLog.shared.transcription("Audio duration (\(Int(duration))s) is within limits, using standard transcription")
            return try await transcribeAudioStandard(url: url, recordingId: recordingId)
        }
    }

    private func transcribeAudioStandard(url: URL, recordingId: UUID? = nil) async throws -> TranscriptionResult {
        AppLog.shared.transcription("WyomingWhisperClient.transcribeAudioStandard called for: \(url.lastPathComponent)")

        // Only start background task if this is not a chunk (chunks are managed by parent method)
        isProcessingChunk = url.lastPathComponent.contains("chunk_")
        if !isProcessingChunk && shouldManageBackgroundTask {
            beginBackgroundTask()
        }

        // CRITICAL: If we're being called from BackgroundProcessingManager, don't manage our own background task
        if !shouldManageBackgroundTask {
            AppLog.shared.transcription("Wyoming client background task management disabled - parent is handling background tasks", level: .debug)
        }

        // Ensure we're connected (but only test if this is not a chunk)
        if !isConnected {
            if isProcessingChunk {
                // For chunks, assume connection was already tested by parent
                AppLog.shared.transcription("Connection lost during chunked processing", level: .error)
                throw WyomingError.connectionFailed
            } else {
                // For standalone files, test connection
                let connected = await testConnection()
                if !connected {
                    if !isProcessingChunk && shouldManageBackgroundTask {
                        endBackgroundTask()
                    }
                    throw WyomingError.connectionFailed
                }
            }
        }

        isTranscribing = true
        currentStatus = "Starting transcription..."
        progress = 0.0
        transcriptionResult = ""

        // Start timeout for large files (estimate 1 minute per 5MB of audio)
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        AppLog.shared.transcription("File size: \(fileSize) bytes (\(String(format: "%.1f", Double(fileSize) / (1024 * 1024)))MB)", level: .debug)

        // Safely calculate timeout with bounds checking
        let fileSizeMB = Double(fileSize) / (1024.0 * 1024.0)
        let estimatedMinutes = max(5.0, fileSizeMB / 5.0) // Minimum 5 min, 1 min per 5MB
        let estimatedSeconds = min(estimatedMinutes * 60.0, 3600.0) // Cap at 1 hour

        // Ensure the value is within Int range before converting
        let safeEstimatedSeconds = min(estimatedSeconds, Double(Int.max - 1))
        let timeoutSeconds: Int

        if safeEstimatedSeconds.isFinite && safeEstimatedSeconds >= 0 {
            timeoutSeconds = Int(safeEstimatedSeconds)
        } else {
            // Fallback to default timeout if calculation failed
            AppLog.shared.transcription("Timeout calculation failed, using default 300 seconds", level: .error)
            timeoutSeconds = 300
        }

        AppLog.shared.transcription("Setting Wyoming timeout: \(timeoutSeconds)s (\(timeoutSeconds/60) minutes)", level: .debug)

        startStreamingTimeout(seconds: timeoutSeconds)

        do {
            return try await withCheckedThrowingContinuation { continuation in
                currentTranscription = continuation

                Task {
                    do {
                        try await performWyomingTranscription(url: url)
                    } catch {
                        await MainActor.run {
                            // Thread-safe continuation handling
                            if let activeContinuation = self.currentTranscription {
                                self.currentTranscription = nil
                                self.isTranscribing = false
                                self.currentStatus = "Transcription failed"
                                self.cancelStreamingTimeout()
                                if !self.isProcessingChunk {
                                    self.endBackgroundTask()
                                }
                                // Disconnect on error
                                if !self.isProcessingChunk {
                                    AppLog.shared.transcription("Disconnecting after transcription error", level: .debug)
                                    self.tcpClient.disconnect()
                                }
                                activeContinuation.resume(throwing: error)
                            }
                        }
                    }
                }
            }
        } catch {
            self.cancelStreamingTimeout()
            if !self.isProcessingChunk && self.shouldManageBackgroundTask {
                self.endBackgroundTask()
            }
            throw error
        }
    }

    private func performWyomingTranscription(url: URL) async throws {
        do {
            // Step 1: Send transcribe command.
            // We pass `language: nil` so the Wyoming server can auto-detect
            // the language from audio instead of forcing a specific locale.
            currentStatus = "Sending transcription request..."
            progress = 0.1

            try await tcpClient.sendTranscribe(language: nil)

            // Step 2: Send audio start
            currentStatus = "Starting audio stream..."
            progress = 0.2

            try await tcpClient.sendAudioStart()

            // Step 3: Stream audio data
            currentStatus = "Streaming audio data..."
            progress = 0.3

            try await streamAudioFile(url: url)

            // Step 4: Send audio stop
            currentStatus = "Finishing audio stream..."
            progress = 0.9

            try await tcpClient.sendAudioStop()

            currentStatus = "Waiting for transcription..."
            // The completion will be handled by handleTranscriptMessage

        } catch {
            AppLog.shared.transcription("Wyoming transcription error: \(error)", level: .error)

            // Attempt recovery for network errors
            if let wyomingError = error as? WyomingError,
               case .connectionFailed = wyomingError {
                AppLog.shared.transcription("Attempting Wyoming connection recovery")

                do {
                    // Disconnect and reconnect
                    tcpClient.disconnect()
                    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

                    let reconnected = await testConnection()
                    if reconnected {
                        AppLog.shared.transcription("Wyoming connection recovered, retrying transcription")
                        currentStatus = "Connection recovered, retrying..."

                        // Retry the transcription once
                        try await performWyomingTranscription(url: url)
                        return
                    }
                } catch {
                    AppLog.shared.transcription("Wyoming connection recovery failed: \(error)", level: .error)
                }
            }

            // If we get here, the original error couldn't be recovered
            throw error
        }
    }

    private func streamAudioFile(url: URL) async throws {
        // Convert audio file to PCM data for Wyoming
        let audioData = try await convertToPCMData(url: url)

        // Optimize chunk size based on file size
        let chunkSize: Int
        if audioData.count > 50_000_000 { // > 50MB
            chunkSize = 65536 // 64KB chunks for large files
        } else if audioData.count > 10_000_000 { // > 10MB
            chunkSize = 32768 // 32KB chunks for medium files
        } else {
            chunkSize = 16384 // 16KB chunks for small files
        }

        let totalChunks = (audioData.count + chunkSize - 1) / chunkSize

        AppLog.shared.transcription("Streaming audio (\(String(format: "%.1f", Double(audioData.count)/1024/1024))MB, \(totalChunks) chunks)", level: .debug)

        let startTime = Date()

        // Prepare chunks array for batch processing
        var chunks: [Data] = []
        chunks.reserveCapacity(totalChunks)

        for chunkIndex in 0..<totalChunks {
            let startIndex = chunkIndex * chunkSize
            let endIndex = min(startIndex + chunkSize, audioData.count)
            let chunk = audioData.subdata(in: startIndex..<endIndex)
            chunks.append(chunk)
        }

        // Send audio chunks using Wyoming protocol messages
        for (chunkIndex, chunk) in chunks.enumerated() {
            try await tcpClient.sendAudioChunk(chunk)

            let chunkProgress = Double(chunkIndex + 1) / Double(totalChunks)
            progress = 0.3 + (chunkProgress * 0.6) // Use 30%-90% for streaming
        }

        let totalTime = Date().timeIntervalSince(startTime)
        let avgRate = totalTime > 0 ? Double(totalChunks) / totalTime : 0
        let _ = min(avgRate, Double(Int.max - 1))

        AppLog.shared.transcription("Audio streamed in \(String(format: "%.1f", totalTime))s")
    }

    private func convertToPCMData(url: URL) async throws -> Data {
        // Converting audio to PCM for Wyoming

        let asset = AVURLAsset(url: url)

        // Get audio track
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw WyomingError.serverError("No audio track found")
        }

        // Create asset reader
        let assetReader = try AVAssetReader(asset: asset)

        // Configure reader for PCM output (Wyoming format)
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: WyomingConstants.audioSampleRate,  // 16kHz
            AVNumberOfChannelsKey: WyomingConstants.audioChannels,  // Mono
            AVLinearPCMBitDepthKey: WyomingConstants.audioBitDepth,  // 16-bit
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])

        assetReader.add(readerOutput)
        assetReader.startReading()

        var pcmData = Data()

        while assetReader.status == .reading {
            if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                    let length = CMBlockBufferGetDataLength(blockBuffer)
                    var data = Data(count: length)

                    let result = data.withUnsafeMutableBytes { bytes in
                        CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
                    }

                    if result != noErr {
                        AppLog.shared.transcription("CMBlockBufferCopyDataBytes returned error: \(result)", level: .error)
                    }

                    pcmData.append(data)
                }
            } else {
                break
            }
        }

        if assetReader.status == .failed {
            if let error = assetReader.error {
                throw error
            } else {
                throw WyomingError.serverError("Audio conversion failed")
            }
        }

        return pcmData
    }

    // MARK: - Audio Duration and Chunking

    private func getAudioDuration(url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        return CMTimeGetSeconds(duration)
    }

    private func transcribeAudioWithChunking(url: URL, recordingId: UUID?, maxChunkDuration: TimeInterval) async throws -> TranscriptionResult {
        AppLog.shared.transcription("Starting chunked Wyoming transcription for: \(url.lastPathComponent)")

        // Start background task for long-running transcription (only if we should manage background tasks)
        if shouldManageBackgroundTask {
            beginBackgroundTask()
            AppLog.shared.transcription("Wyoming client managing its own background task for chunked transcription", level: .debug)
        } else {
            AppLog.shared.transcription("Wyoming client background task management disabled - parent is handling chunked transcription", level: .debug)
        }

        // Test connection once at the beginning
        if !isConnected {
            AppLog.shared.transcription("Testing Wyoming connection before chunked transcription", level: .debug)
            let connected = await testConnection()
            if !connected {
                if shouldManageBackgroundTask {
                    endBackgroundTask()
                }
                throw WyomingError.connectionFailed
            }
            AppLog.shared.transcription("Wyoming connection verified for chunked transcription")
        }

        // Get audio duration and calculate chunks
        let totalDuration = try await getAudioDuration(url: url)
        let numberOfChunks = Int(ceil(totalDuration / maxChunkDuration))

        AppLog.shared.transcription("Audio duration: \(Int(totalDuration))s, splitting into \(numberOfChunks) chunks of \(Int(maxChunkDuration))s each")

        // Create temporary directory for chunks
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            // Clean up temporary files
            try? FileManager.default.removeItem(at: tempDir)
        }

        var allSegments: [TranscriptSegment] = []
        var totalProcessingTime: TimeInterval = 0
        let startTime = Date()

        // Process each chunk
        for chunkIndex in 0..<numberOfChunks {
            let chunkStartTime = TimeInterval(chunkIndex) * maxChunkDuration
            let chunkEndTime = min(chunkStartTime + maxChunkDuration, totalDuration)
            let chunkDuration = chunkEndTime - chunkStartTime

            AppLog.shared.transcription("Processing chunk \(chunkIndex + 1)/\(numberOfChunks): \(Int(chunkStartTime))s - \(Int(chunkEndTime))s (\(Int(chunkDuration))s)", level: .debug)

            // Update progress
            currentStatus = "Processing chunk \(chunkIndex + 1) of \(numberOfChunks)..."
            progress = Double(chunkIndex) / Double(numberOfChunks)

            // Create audio chunk file
            let chunkURL = tempDir.appendingPathComponent("chunk_\(chunkIndex).m4a")
            try await createAudioChunk(sourceURL: url, outputURL: chunkURL, startTime: chunkStartTime, duration: chunkDuration)

            // Transcribe the chunk - disconnect and reconnect for each chunk
            do {
                // For all chunks after the first, always disconnect and reconnect
                // Wyoming servers typically expect fresh connections for each transcription
                if chunkIndex > 0 {
                    AppLog.shared.transcription("Disconnecting and reconnecting for chunk \(chunkIndex + 1)", level: .debug)
                    tcpClient.disconnect()
                    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay for server cleanup

                    // Re-register message handlers after disconnect (they get cleared)
                    setupMessageHandlers()

                    // Establish fresh connection for this chunk
                    let connected = await testConnection()
                    if !connected {
                        AppLog.shared.transcription("Failed to establish fresh connection for chunk \(chunkIndex + 1)", level: .error)
                        continue
                    }
                    AppLog.shared.transcription("Fresh connection established for chunk \(chunkIndex + 1)", level: .debug)
                }

                let chunkResult = try await transcribeAudioStandard(url: chunkURL, recordingId: recordingId)

                // Adjust timestamps to account for chunk offset
                let adjustedSegments = chunkResult.segments.map { segment in
                    TranscriptSegment(
                        speaker: segment.speaker,
                        text: segment.text,
                        startTime: segment.startTime + chunkStartTime,
                        endTime: segment.endTime + chunkStartTime
                    )
                }

                allSegments.append(contentsOf: adjustedSegments)
                totalProcessingTime += chunkResult.processingTime

                AppLog.shared.transcription("Chunk \(chunkIndex + 1) completed: \(adjustedSegments.count) segments")

            } catch {
                AppLog.shared.transcription("Failed to transcribe chunk \(chunkIndex + 1): \(error)", level: .error)

                // Check if this is a connection error that we can retry
                let shouldRetry = if let wyomingError = error as? WyomingError {
                    switch wyomingError {
                    case .connectionFailed, .timeout:
                        true
                    default:
                        false
                    }
                } else if error.localizedDescription.contains("Connection reset") ||
                         error.localizedDescription.contains("connection lost") ||
                         error.localizedDescription.contains("network") {
                    true
                } else {
                    false
                }

                if shouldRetry {
                    AppLog.shared.transcription("Connection error detected for chunk \(chunkIndex + 1), establishing fresh connection")
                    tcpClient.disconnect()

                    // Longer delay for connection reset issues and server cleanup
                    try await Task.sleep(nanoseconds: 2_000_000_000) // 2 second delay

                    // Re-register message handlers after disconnect (they get cleared)
                    setupMessageHandlers()

                    let reconnected = await testConnection()
                    if reconnected {
                        AppLog.shared.transcription("Fresh connection established for chunk \(chunkIndex + 1) retry")
                        do {
                            let retryResult = try await transcribeAudioStandard(url: chunkURL, recordingId: recordingId)

                            let adjustedSegments = retryResult.segments.map { segment in
                                TranscriptSegment(
                                    speaker: segment.speaker,
                                    text: segment.text,
                                    startTime: segment.startTime + chunkStartTime,
                                    endTime: segment.endTime + chunkStartTime
                                )
                            }

                            allSegments.append(contentsOf: adjustedSegments)
                            totalProcessingTime += retryResult.processingTime

                            AppLog.shared.transcription("Chunk \(chunkIndex + 1) completed on retry: \(adjustedSegments.count) segments")
                        } catch {
                            AppLog.shared.transcription("Retry also failed for chunk \(chunkIndex + 1): \(error)", level: .error)
                            // Continue with next chunk - don't fail entire transcription for one chunk
                            continue
                        }
                    } else {
                        AppLog.shared.transcription("Could not reconnect for chunk \(chunkIndex + 1) retry", level: .error)
                        continue
                    }
                } else {
                    AppLog.shared.transcription("Non-connection error for chunk \(chunkIndex + 1), skipping retry: \(error)", level: .error)
                    continue
                }
            }

            // Clean up chunk file immediately to save disk space
            try? FileManager.default.removeItem(at: chunkURL)
        }

        if shouldManageBackgroundTask {
            endBackgroundTask()
        } else {
            AppLog.shared.transcription("Wyoming client not ending background task - parent is managing it", level: .debug)
        }

        // Clean up connection after all chunks are processed
        AppLog.shared.transcription("Disconnecting after chunked transcription completion", level: .debug)
        tcpClient.disconnect()

        // Merge segments and create final result
        let mergedSegments = mergeAdjacentSegments(allSegments)
        let fullText = mergedSegments.map { $0.text }.joined(separator: " ")
        let finalProcessingTime = Date().timeIntervalSince(startTime)

        AppLog.shared.transcription("Chunked transcription completed: \(mergedSegments.count) segments, \(fullText.count) chars, \(Int(finalProcessingTime))s")

        // Final progress update
        currentStatus = "Transcription completed"
        progress = 1.0
        isTranscribing = false

        return TranscriptionResult(
            fullText: fullText,
            segments: mergedSegments,
            processingTime: finalProcessingTime,
            chunkCount: numberOfChunks,
            success: true,
            error: nil
        )
    }

    private func createAudioChunk(sourceURL: URL, outputURL: URL, startTime: TimeInterval, duration: TimeInterval) async throws {
        AppLog.shared.transcription("Creating audio chunk: \(Int(startTime))s - \(Int(startTime + duration))s", level: .debug)

        let asset = AVURLAsset(url: sourceURL)

        // Use modern iOS 18+ API with fallback for older versions
        if #available(iOS 18.0, *) {
            // Create export session with modern API
            guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw WyomingError.serverError("Failed to create export session")
            }

            exportSession.outputFileType = .m4a
            exportSession.timeRange = CMTimeRangeMake(
                start: CMTime(seconds: startTime, preferredTimescale: 1000),
                duration: CMTime(seconds: duration, preferredTimescale: 1000)
            )

            // Use modern async throws export method
            try await exportSession.export(to: outputURL, as: .m4a)

        } else {
            // Fallback for iOS < 18.0
            guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw WyomingError.serverError("Failed to create export session")
            }

            exportSession.outputURL = outputURL
            exportSession.outputFileType = .m4a
            exportSession.timeRange = CMTimeRangeMake(
                start: CMTime(seconds: startTime, preferredTimescale: 1000),
                duration: CMTime(seconds: duration, preferredTimescale: 1000)
            )

            await exportSession.export()

            if exportSession.status != .completed {
                if let error = exportSession.error {
                    throw error
                } else {
                    throw WyomingError.serverError("Audio chunk export failed")
                }
            }
        }

        AppLog.shared.transcription("Audio chunk created: \(outputURL.lastPathComponent)", level: .debug)
    }

    private func mergeAdjacentSegments(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard !segments.isEmpty else { return [] }

        // Sort segments by start time
        let sortedSegments = segments.sorted { $0.startTime < $1.startTime }
        var mergedSegments: [TranscriptSegment] = []
        var currentSegment = sortedSegments[0]

        for nextSegment in sortedSegments.dropFirst() {
            let timeDifference = nextSegment.startTime - currentSegment.endTime
            let isSameSpeaker = currentSegment.speaker == nextSegment.speaker

            // Merge if segments are close together (< 2 seconds) and same speaker
            if timeDifference < 2.0 && isSameSpeaker && !currentSegment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                currentSegment = TranscriptSegment(
                    speaker: currentSegment.speaker,
                    text: currentSegment.text + " " + nextSegment.text,
                    startTime: currentSegment.startTime,
                    endTime: nextSegment.endTime
                )
            } else {
                mergedSegments.append(currentSegment)
                currentSegment = nextSegment
            }
        }

        mergedSegments.append(currentSegment)

        AppLog.shared.transcription("Merged \(segments.count) segments into \(mergedSegments.count) segments", level: .debug)
        return mergedSegments
    }

    // MARK: - Status Properties

    var connectionStatus: String {
        return tcpClient.connectionStatus
    }

    var availableModels: [String] {
        return serverInfo?.asr?.first?.models?.map { $0.name } ?? []
    }

    // MARK: - Background Task Management

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else {
            return
        }

        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "WyomingTranscription") { [weak self] in
            AppLog.shared.transcription("Wyoming background task is about to expire", level: .error)
            Task { @MainActor in
                await self?.handleBackgroundTaskExpiration()
            }
        }

        if backgroundTaskID == .invalid {
            AppLog.shared.transcription("Failed to start Wyoming background task", level: .error)
        } else {
            let remainingTime = UIApplication.shared.backgroundTimeRemaining
            if remainingTime.isFinite {
                AppLog.shared.transcription("Started Wyoming background task with \(String(format: "%.0f", remainingTime))s remaining", level: .debug)
            } else {
                AppLog.shared.transcription("Started Wyoming background task with unlimited time remaining", level: .debug)
            }
        }
    }

    private func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            AppLog.shared.transcription("Ending Wyoming background task: \(backgroundTaskID.rawValue)", level: .debug)
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    private func handleBackgroundTaskExpiration() async {
        AppLog.shared.transcription("Wyoming background task expired, attempting graceful cleanup", level: .error)

        // Cancel any ongoing streaming timeout task
        streamingTimeoutTask?.cancel()
        streamingTimeoutTask = nil

        // Cancel TCP connection to prevent hanging operations
        tcpClient.disconnect()

        // Thread-safe continuation handling for background task expiration
        if let activeContinuation = currentTranscription {
            currentTranscription = nil
            isTranscribing = false
            currentStatus = "Background task expired"
            connectionError = "Processing was interrupted when app went to background"
            cancelStreamingTimeout()
            if shouldManageBackgroundTask {
                endBackgroundTask()
            }

            // Disconnect on background task expiration
            AppLog.shared.transcription("Disconnecting after background task expiration", level: .debug)
            tcpClient.disconnect()

            activeContinuation.resume(throwing: WyomingError.timeout)
        } else {
            // No active transcription, just clean up
            isTranscribing = false
            currentStatus = "Background task expired"
            if shouldManageBackgroundTask {
                endBackgroundTask()
            }
        }
    }

    // MARK: - Timeout Management

    private func startStreamingTimeout(seconds: Int = 300) { // 5 minutes default
        streamingTimeoutTask?.cancel()

        // Ensure we don't overflow when converting to nanoseconds
        let clampedSeconds = max(1, min(seconds, 3600)) // Between 1 second and 1 hour
        let nanoseconds = UInt64(clampedSeconds) * 1_000_000_000

        AppLog.shared.transcription("Starting Wyoming timeout: \(clampedSeconds)s", level: .debug)

        streamingTimeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
                await handleStreamingTimeout()
            } catch {
                // Task was cancelled, which is expected
            }
        }
    }

    private func cancelStreamingTimeout() {
        streamingTimeoutTask?.cancel()
        streamingTimeoutTask = nil
    }

    private func handleStreamingTimeout() async {
        AppLog.shared.transcription("Wyoming streaming timeout after extended period", level: .error)

        // Thread-safe continuation handling for streaming timeout
        if let activeContinuation = currentTranscription {
            currentTranscription = nil
            isTranscribing = false
            currentStatus = "Streaming timeout"
            if shouldManageBackgroundTask {
                endBackgroundTask()
            }

            // Disconnect on streaming timeout
            AppLog.shared.transcription("Disconnecting after streaming timeout", level: .debug)
            tcpClient.disconnect()

            activeContinuation.resume(throwing: WyomingError.timeout)
        } else {
            // No active transcription, just clean up
            isTranscribing = false
            currentStatus = "Streaming timeout"
            connectionError = "Transcription timed out during streaming"

            // Disconnect on timeout cleanup
            AppLog.shared.transcription("Disconnecting after streaming timeout (no active transcription)", level: .debug)
            tcpClient.disconnect()

            if shouldManageBackgroundTask {
                endBackgroundTask()
            }
        }
    }
}
