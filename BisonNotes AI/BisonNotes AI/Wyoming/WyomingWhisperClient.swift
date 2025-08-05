//
//  WyomingWhisperClient.swift
//  Audio Journal
//
//  Wyoming protocol client specifically for Whisper transcription
//

import Foundation
import AVFoundation

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
    
    // MARK: - Initialization
    
    init(config: WhisperConfig) {
        self.config = config
        
        // Extract host from server URL
        let host = Self.extractHost(from: config.serverURL)
        print("🔗 Wyoming TCP connection: \(host):\(config.port)")
        
        self.tcpClient = WyomingTCPClient(host: host, port: config.port)
        setupMessageHandlers()
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
            print("⚠️ Failed to parse info message")
            return
        }
        
        serverInfo = infoData
        print("ℹ️ Wyoming server info received:")
        
        if let asrInfo = infoData.asr?.first {
            print("   - ASR: \(asrInfo.name)")
            print("   - Version: \(asrInfo.version ?? "unknown")")
            print("   - Models: \(asrInfo.models?.count ?? 0)")
        }
        
        isConnected = true
        connectionError = nil
    }
    
    private func handleTranscriptMessage(_ message: WyomingMessage) async {
        guard let transcriptData = message.parseData(as: WyomingTranscriptData.self) else {
            print("⚠️ Failed to parse transcript message")
            return
        }
        
        print("📝 Received transcription: \(transcriptData.text)")
        transcriptionResult = transcriptData.text
        
        // Complete the transcription
        if let continuation = currentTranscription {
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
            
            continuation.resume(returning: result)
            currentTranscription = nil
            
            isTranscribing = false
            currentStatus = "Transcription completed"
            progress = 1.0
        }
    }
    
    private func handleErrorMessage(_ message: WyomingMessage) async {
        guard let errorData = message.parseData(as: WyomingErrorData.self) else {
            print("⚠️ Failed to parse error message")
            return
        }
        
        print("❌ Wyoming server error: \(errorData.code) - \(errorData.message)")
        
        if let continuation = currentTranscription {
            let error = WyomingError.serverError("\(errorData.code): \(errorData.message)")
            continuation.resume(throwing: error)
            currentTranscription = nil
        }
        
        isTranscribing = false
        currentStatus = "Error: \(errorData.message)"
        connectionError = errorData.message
    }
    
    // MARK: - Connection Management
    
    func testConnection() async -> Bool {
        do {
            print("🔌 Wyoming client testing TCP connection...")
            try await tcpClient.connect()
            print("✅ Wyoming TCP connected, sending describe message...")
            
            // Send describe message to get server info
            try await tcpClient.sendDescribe()
            
            // Wait a bit for the info response
            try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            
            await MainActor.run {
                self.isConnected = true
                self.connectionError = nil
            }
            
            print("✅ Wyoming connection test passed")
            return true
            
        } catch {
            print("❌ Wyoming connection test failed: \(error)")
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
        print("🎤 WyomingWhisperClient.transcribeAudio called for: \(url.lastPathComponent)")
        
        // Ensure we're connected
        if !isConnected {
            let connected = await testConnection()
            if !connected {
                throw WyomingError.connectionFailed
            }
        }
        
        isTranscribing = true
        currentStatus = "Starting transcription..."
        progress = 0.0
        transcriptionResult = ""
        
        return try await withCheckedThrowingContinuation { continuation in
            currentTranscription = continuation
            
            Task {
                do {
                    try await performWyomingTranscription(url: url)
                } catch {
                    await MainActor.run {
                        self.isTranscribing = false
                        self.currentStatus = "Transcription failed"
                        self.currentTranscription = nil
                    }
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func performWyomingTranscription(url: URL) async throws {
        // Step 1: Send transcribe command
        currentStatus = "Sending transcription request..."
        progress = 0.1
        
        try await tcpClient.sendTranscribe(language: "en")
        
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
    }
    
    private func streamAudioFile(url: URL) async throws {
        // Convert audio file to PCM data for Wyoming
        let audioData = try await convertToPCMData(url: url)
        
        // Stream in optimal chunks for Wyoming protocol
        let chunkSize = 32768 // 32KB chunks (good balance of speed vs memory)
        let totalChunks = (audioData.count + chunkSize - 1) / chunkSize
        
        print("🔄 Streaming \(audioData.count) bytes in \(totalChunks) chunks of \(chunkSize) bytes each")
        
        let startTime = Date()
        
        for chunkIndex in 0..<totalChunks {
            let startIndex = chunkIndex * chunkSize
            let endIndex = min(startIndex + chunkSize, audioData.count)
            let chunk = audioData.subdata(in: startIndex..<endIndex)
            
            try await tcpClient.sendAudioData(chunk)
            
            // Update progress
            let chunkProgress = Double(chunkIndex + 1) / Double(totalChunks)
            progress = 0.3 + (chunkProgress * 0.6) // Use 30%-90% for streaming
            
            // No delay for faster streaming (Wyoming should handle flow control)
            
            // Log progress every 10% 
            if chunkIndex % (totalChunks / 10 + 1) == 0 {
                let elapsed = Date().timeIntervalSince(startTime)
                let rate = Double(chunkIndex + 1) / elapsed
                print("📤 Streaming progress: \(Int(chunkProgress * 100))% (\(chunkIndex + 1)/\(totalChunks) chunks) - \(Int(rate)) chunks/sec")
            }
        }
        
        let totalTime = Date().timeIntervalSince(startTime)
        let avgRate = Double(totalChunks) / totalTime
        
        print("✅ Streamed \(totalChunks) audio chunks (\(audioData.count) bytes total) in \(String(format: "%.2f", totalTime))s at \(Int(avgRate)) chunks/sec")
    }
    
    private func convertToPCMData(url: URL) async throws -> Data {
        print("🔄 Converting audio to PCM for Wyoming...")
        
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
                        print("⚠️ Warning: CMBlockBufferCopyDataBytes returned error: \(result)")
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
        
        print("✅ Converted to PCM: \(pcmData.count) bytes at \(WyomingConstants.audioSampleRate)Hz")
        return pcmData
    }
    
    // MARK: - Status Properties
    
    var connectionStatus: String {
        return tcpClient.connectionStatus
    }
    
    var availableModels: [String] {
        return serverInfo?.asr?.first?.models?.map { $0.name } ?? []
    }
}