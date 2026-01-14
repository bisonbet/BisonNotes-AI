//
//  WhisperService.swift
//  Audio Journal
//
//  Service for communicating with REST API-based Whisper service
//

import Foundation
import AVFoundation

// MARK: - Error Types

enum WhisperError: Error, LocalizedError {
    case notConnected
    case serverError(String)
    case audioProcessingFailed(String)
    case invalidResponse(String)
    
    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to Whisper service"
        case .serverError(let message):
            return "Server error: \(message)"
        case .audioProcessingFailed(let message):
            return "Audio processing failed: \(message)"
        case .invalidResponse(let message):
            return "Invalid response: \(message)"
        }
    }
}

// MARK: - Whisper Configuration

struct WhisperConfig {
    let serverURL: String
    let port: Int
    let whisperProtocol: WhisperProtocol
    
    var baseURL: String {
        return "\(serverURL):\(port)"
    }
    
    var restAPIBaseURL: String {
        // For REST API, always use HTTP and standard REST port
        var restServerURL = serverURL
        
        // Convert WebSocket URLs to HTTP URLs for REST API
        if restServerURL.hasPrefix("ws://") {
            restServerURL = restServerURL.replacingOccurrences(of: "ws://", with: "http://")
        } else if restServerURL.hasPrefix("wss://") {
            restServerURL = restServerURL.replacingOccurrences(of: "wss://", with: "https://")
        } else if !restServerURL.hasPrefix("http://") && !restServerURL.hasPrefix("https://") {
            // If no scheme, assume http
            restServerURL = "http://" + restServerURL
        }
        
        // Use appropriate port for REST API (9000 is typical for Whisper REST)
        let restPort = (whisperProtocol == .wyoming) ? 9000 : port
        return "\(restServerURL):\(restPort)"
    }
    
    static let `default` = WhisperConfig(
        serverURL: "http://localhost",
        port: 9000,
        whisperProtocol: .rest
    )
    
    static let wyomingDefault = WhisperConfig(
        serverURL: "ws://localhost",
        port: 10300,
        whisperProtocol: .wyoming
    )
}

// MARK: - REST API Models

struct WhisperTranscribeRequest {
    let audioFile: URL
    let output: String
    let task: String
    let language: String?
    let wordTimestamps: Bool?
    let vadFilter: Bool?
    let encode: Bool?
    let diarize: Bool?
    let minSpeakers: Int?
    let maxSpeakers: Int?
}

struct WhisperTranscribeResponse: Codable {
    let text: String
    let segments: [WhisperSegment]?
    let language: String?
}

struct WhisperSegment: Codable {
    let id: Int
    let start: Double
    let end: Double
    let text: String
    let avg_logprob: Double?
    let compression_ratio: Double?
    let no_speech_prob: Double?
    let speaker: String?
}

struct LanguageDetectionResponse: Codable {
    let detected_language: String
    let language_code: String
    let confidence: Double
}

// MARK: - Whisper Service

@MainActor
class WhisperService: ObservableObject {
    private let config: WhisperConfig
    private let session: URLSession
    private let chunkingService: AudioFileChunkingService
    
    // Protocol-specific clients
    private let wyomingClient: WyomingWhisperClient?
    
    @Published var isConnected: Bool = false
    @Published var connectionError: String?
    @Published var isTranscribing = false
    @Published var currentStatus = ""
    @Published var progress: Double = 0.0
    
    init(config: WhisperConfig = .default, chunkingService: AudioFileChunkingService) {
        print("🔧 WhisperService init - Config: URL='\(config.serverURL)', Port=\(config.port), Protocol=\(config.whisperProtocol.rawValue)")
        self.config = config
        
        // Create a custom URLSession with longer timeout for REST requests
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 1800.0  // 30 minutes
        sessionConfig.timeoutIntervalForResource = 1800.0 // 30 minutes
        sessionConfig.waitsForConnectivity = true
        sessionConfig.allowsConstrainedNetworkAccess = true
        sessionConfig.allowsExpensiveNetworkAccess = true
        self.session = URLSession(configuration: sessionConfig)
        self.chunkingService = chunkingService
        
        // Initialize Wyoming client if using Wyoming protocol
        if config.whisperProtocol == .wyoming {
            print("🔧 Initializing Wyoming client...")
            let client = WyomingWhisperClient(config: config)
            // Disable background task management since we're already in a background context
            client.disableBackgroundTaskManagement()
            self.wyomingClient = client
        } else {
            print("🔧 Using REST protocol, no Wyoming client needed")
            self.wyomingClient = nil
        }
    }
    
    // MARK: - Background Task Management
    
    /// Disable background task management in Wyoming client when called from background processing manager
    func disableWyomingBackgroundTaskManagement() {
        wyomingClient?.disableBackgroundTaskManagement()
        print("🔧 WhisperService: Disabled Wyoming background task management for parent coordination")
    }
    
    /// Re-enable background task management in Wyoming client
    func enableWyomingBackgroundTaskManagement() {
        wyomingClient?.enableBackgroundTaskManagement()
        print("🔧 WhisperService: Enabled Wyoming background task management")
    }
    
    // MARK: - Connection Management
    
    func testConnection() async -> Bool {
        switch config.whisperProtocol {
        case .rest:
            return await testRESTConnection()
        case .wyoming:
            return await testWyomingConnection()
        }
    }
    
    private func testRESTConnection() async -> Bool {
        do {
            // For REST API, always use HTTP regardless of what user entered
            let restBaseURL = config.restAPIBaseURL
            let testURL = URL(string: "\(restBaseURL)/asr")!
            print("🔌 Testing REST API connection to: \(testURL)")
            
            let (_, response) = try await withTimeout(
                seconds: 10,
                timeoutError: WhisperError.serverError("REST API request timed out after 10 seconds")
            ) { [self] in
                try await session.data(from: testURL)
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📡 HTTP response status: \(httpResponse.statusCode)")
                // Even a 405 (Method Not Allowed) means the server is running
                let isAvailable = httpResponse.statusCode == 200 || httpResponse.statusCode == 405
                
                await MainActor.run {
                    self.isConnected = isAvailable
                    self.connectionError = isAvailable ? nil : "Server returned status \(httpResponse.statusCode)"
                }
                
                print("✅ REST API connection test successful")
                return isAvailable
            }
            
            await MainActor.run {
                self.isConnected = false
                self.connectionError = "Invalid response"
            }
            return false
            
        } catch {
            print("❌ REST API connection test failed: \(error)")
            await MainActor.run {
                self.isConnected = false
                self.connectionError = "Connection failed: \(error.localizedDescription)"
            }
            return false
        }
    }
    
    private func testWyomingConnection() async -> Bool {
        guard let wyomingClient = wyomingClient else {
            await MainActor.run {
                self.isConnected = false
                self.connectionError = "Wyoming client not initialized"
            }
            return false
        }
        
        print("🔌 Testing Wyoming connection to: \(config.baseURL)")
        
        let connected = await wyomingClient.testConnection()
        
        await MainActor.run {
            self.isConnected = connected
            self.connectionError = connected ? nil : wyomingClient.connectionError
        }
        
        return connected
    }
    
    // MARK: - Fallback for when Whisper is not available
    
    func isWhisperAvailable() async -> Bool {
        return await testConnection()
    }
    
    func getWhisperStatus() -> String {
        if isConnected {
            return "Connected to Whisper service"
        } else if let error = connectionError {
            return "Connection error: \(error)"
        } else {
            return "Not connected to Whisper service"
        }
    }
    
    // MARK: - Transcription
    
    func transcribeAudio(url: URL, recordingId: UUID? = nil) async throws -> TranscriptionResult {
        
        // Check if chunking is needed
        let needsChunking = try await chunkingService.shouldChunkFile(url, for: .whisper)
        
        if needsChunking {
                return try await transcribeWithChunking(url: url, recordingId: recordingId)
        } else {
            print("📄 WhisperService - Using single file transcription path")
            return try await performSingleTranscription(url: url)
        }
    }
    
    private func transcribeWithChunking(url: URL, recordingId: UUID?) async throws -> TranscriptionResult {
        await MainActor.run {
            self.isTranscribing = true
            self.currentStatus = "Chunking audio file..."
            self.progress = 0.05
        }
        let chunkingResult = try await chunkingService.chunkAudioFile(url, for: .whisper)
        let chunks = chunkingResult.chunks
        var transcriptChunks: [TranscriptChunk] = []
        var chunkIndex = 0
        for audioChunk in chunks {
            await MainActor.run {
                self.currentStatus = "Transcribing chunk \(chunkIndex + 1) of \(chunks.count)..."
                self.progress = 0.05 + 0.85 * (Double(chunkIndex) / Double(chunks.count))
            }
            let result = try await performSingleTranscription(url: audioChunk.chunkURL)
            // Wrap result in TranscriptChunk
            let transcriptChunk = TranscriptChunk(
                chunkId: audioChunk.id,
                sequenceNumber: audioChunk.sequenceNumber,
                transcript: result.fullText,
                segments: result.segments,
                startTime: audioChunk.startTime,
                endTime: audioChunk.endTime,
                processingTime: result.processingTime
            )
            transcriptChunks.append(transcriptChunk)
            chunkIndex += 1
        }
        // Reassemble transcript
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let creationDate = (fileAttributes[.creationDate] as? Date) ?? Date()
        let reassembly = try await chunkingService.reassembleTranscript(
            from: transcriptChunks,
            originalURL: url,
            recordingName: url.deletingPathExtension().lastPathComponent,
            recordingDate: creationDate,
            recordingId: recordingId ?? UUID() // Use provided recordingId or fallback to new UUID
        )
        // Clean up chunk files
        try await chunkingService.cleanupChunks(chunks)
        await MainActor.run {
            self.currentStatus = "Transcription complete"
            self.progress = 1.0
            self.isTranscribing = false
        }
        // Return as TranscriptionResult (flattened)
        return TranscriptionResult(
            fullText: reassembly.transcriptData.plainText,
            segments: reassembly.transcriptData.segments,
            processingTime: reassembly.reassemblyTime,
            chunkCount: chunks.count,
            success: true,
            error: nil
        )
    }
    
    // MARK: - Single File Transcription
    
    private func performSingleTranscription(url: URL) async throws -> TranscriptionResult {
        print("🎯 Starting single file transcription for: \(url.lastPathComponent)")
        print("🔍 WhisperService - Full path: \(url.path)")
        print("🔧 WhisperService - Using protocol: \(config.whisperProtocol.rawValue)")
        
        // Route based on protocol
        switch config.whisperProtocol {
        case .rest:
            return try await performRESTTranscription(url: url)
        case .wyoming:
            return try await performWyomingTranscription(url: url)
        }
    }
    
    private func performRESTTranscription(url: URL) async throws -> TranscriptionResult {
        print("🌐 Starting REST API transcription for: \(url.lastPathComponent)")
        
        // Check if this looks like a very short audio file that shouldn't complete in 2.5 seconds
        let asset = AVURLAsset(url: url)
        let duration: TimeInterval
        let fileSize: Int64
        
        do {
            duration = try await asset.load(.duration).seconds
            print("🔍 WhisperService - Audio duration: \(duration)s (\(duration/60) minutes)")
            
            if duration > 300 { // More than 5 minutes
                print("🚨 WhisperService - ALERT: Processing \(duration/60) minute file - this should take time!")
                print("🚨 WhisperService - Expected processing time: ~\(Int(duration/60)) minutes")
            }
            
            // Additional file validation
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
            fileSize = fileAttributes[.size] as? Int64 ?? 0
            print("🔍 WhisperService - File size: \(fileSize) bytes (\(fileSize/1024/1024) MB)")
            
            if fileSize == 0 {
                print("❌ WhisperService - CRITICAL: File size is 0 bytes!")
                throw WhisperError.audioProcessingFailed("Audio file is empty")
            }
            
            if duration == 0 {
                print("❌ WhisperService - CRITICAL: Duration is 0 seconds!")
                throw WhisperError.audioProcessingFailed("Audio file has no duration")
            }
            
            // Detailed audio format analysis
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            if let audioTrack = tracks.first {
                let formatDescriptions = try await audioTrack.load(.formatDescriptions)
                if let formatDescription = formatDescriptions.first {
                    let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
                    if let asbd = audioStreamBasicDescription?.pointee {
                        print("🎵 WhisperService - Audio Format Details:")
                        print("   - Format ID: \(asbd.mFormatID) (should be \(kAudioFormatMPEG4AAC))")
                        print("   - Sample Rate: \(asbd.mSampleRate) Hz")
                        print("   - Channels: \(asbd.mChannelsPerFrame)")
                        print("   - Bits per Channel: \(asbd.mBitsPerChannel)")
                        print("   - Bytes per Frame: \(asbd.mBytesPerFrame)")
                        print("   - Bytes per Packet: \(asbd.mBytesPerPacket)")
                        
                        // Check for problematic format settings
                        if asbd.mSampleRate < 16000 {
                            print("⚠️ WhisperService - LOW SAMPLE RATE: \(asbd.mSampleRate) Hz may cause issues")
                            print("   - Whisper works best with 16kHz+ sample rates")
                        }
                        
                        if asbd.mFormatID != kAudioFormatMPEG4AAC && asbd.mFormatID != kAudioFormatLinearPCM {
                            print("⚠️ WhisperService - UNCOMMON FORMAT: Format ID \(asbd.mFormatID)")
                            print("   - Whisper prefers AAC or PCM formats")
                        }
                    }
                }
            }
            
            // Check if this is a recorded file vs imported file
            let filename = url.lastPathComponent
            if filename.starts(with: "recording_") {
                print("📱 WhisperService - RECORDED FILE detected: \(filename)")
                print("   - This file was created by the app's audio recorder")
                print("   - Using app's AudioQuality settings (MPEG4AAC)")
                
                // Check if this is an original recording or imported copy
                if filename.contains("_20") { // Contains timestamp pattern from import
                    print("   - 🔄 This appears to be an IMPORTED COPY of a recording")
                } else {
                    print("   - 🎙️ This appears to be an ORIGINAL recording")
                }
            } else {
                print("📁 WhisperService - IMPORTED FILE detected: \(filename)")
                print("   - This file was imported from outside the app")
                print("   - May have different encoding parameters")
            }
            
            // Add detailed file system metadata analysis
            print("🗂️ WhisperService - File System Metadata:")
            if let creationDate = fileAttributes[FileAttributeKey.creationDate] as? Date {
                print("   - Creation Date: \(creationDate)")
            }
            if let modificationDate = fileAttributes[FileAttributeKey.modificationDate] as? Date {
                print("   - Modification Date: \(modificationDate)")
            }
            if let posixPermissions = fileAttributes[FileAttributeKey.posixPermissions] as? NSNumber {
                print("   - POSIX Permissions: \(String(posixPermissions.uint16Value, radix: 8))")
            }
            if let ownerAccountName = fileAttributes[FileAttributeKey.ownerAccountName] as? String {
                print("   - Owner: \(ownerAccountName)")
            }
            if let type = fileAttributes[FileAttributeKey.type] as? FileAttributeType {
                print("   - File Type: \(type)")
            }
            
        } catch {
            throw error
        }
        
        // First, ensure we have a valid connection
        if !isConnected {
            print("⚠️ Whisper service not connected, attempting to connect...")
            let connected = await testConnection()
            if !connected {
                print("❌ Failed to connect to Whisper service")
                throw WhisperError.notConnected
            }
            print("✅ Connection established")
        } else {
            print("✅ Whisper service already connected")
        }
        
        await MainActor.run {
            self.isTranscribing = true
            self.currentStatus = "Preparing audio for transcription..."
            self.progress = 0.0
        }
        
        print("🚀 Starting transcription for: \(url.lastPathComponent)")
        
        // Validate URL
        guard url.isFileURL else {
            await MainActor.run {
                self.isTranscribing = false
                self.currentStatus = "Invalid file URL"
            }
            throw WhisperError.audioProcessingFailed("Invalid file URL: \(url)")
        }
        
        // Add safety check for file existence
        guard FileManager.default.fileExists(atPath: url.path) else {
            await MainActor.run {
                self.isTranscribing = false
                self.currentStatus = "Audio file not found"
            }
            print("❌ Audio file not found at path: \(url.path)")
            throw WhisperError.audioProcessingFailed("Audio file does not exist at path: \(url.path)")
        }
        
        // Check file size and format
        do {
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = fileAttributes[.size] as? Int64 ?? 0
            
            if fileSize == 0 {
                await MainActor.run {
                    self.isTranscribing = false
                    self.currentStatus = "Audio file is empty"
                }
                print("❌ Audio file is empty: \(url.path)")
                throw WhisperError.audioProcessingFailed("Audio file is empty")
            }
            
            print("📁 Audio file validated: \(fileSize) bytes")
            
            // Basic audio format validation
            let fileExtension = url.pathExtension.lowercased()
            let supportedFormats = ["m4a", "mp3", "wav", "flac", "ogg", "webm", "mp4"]
            
            if !supportedFormats.contains(fileExtension) {
                print("⚠️ WARNING: Unsupported audio format: \(fileExtension)")
                print("   - Supported formats: \(supportedFormats.joined(separator: ", "))")
            } else {
                print("✅ Audio format supported: \(fileExtension)")
            }
            
        } catch {
            await MainActor.run {
                self.isTranscribing = false
                self.currentStatus = "Failed to validate audio file"
            }
            print("❌ Failed to validate audio file: \(error)")
            throw WhisperError.audioProcessingFailed("Failed to validate audio file: \(error.localizedDescription)")
        }
        
        await MainActor.run {
            self.currentStatus = "Sending audio to Whisper service..."
            self.progress = 0.2
        }
        
        // Create multipart form data request
        let boundary = UUID().uuidString
        let restBaseURL = config.restAPIBaseURL
        var request = URLRequest(url: URL(string: "\(restBaseURL)/asr")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        
        // Add query parameters
        var urlComponents = URLComponents(string: "\(restBaseURL)/asr")!
        urlComponents.queryItems = [
            URLQueryItem(name: "output", value: "json"),
            URLQueryItem(name: "task", value: "transcribe"),
            URLQueryItem(name: "word_timestamps", value: "false"),
            URLQueryItem(name: "vad_filter", value: "false"),
            URLQueryItem(name: "encode", value: "true"),
            URLQueryItem(name: "diarize", value: "false")
        ]
        request.url = urlComponents.url
        
        // Add file data
        let audioData = try Data(contentsOf: url)
        print("📁 Audio file size: \(audioData.count) bytes")
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio_file\"; filename=\"\(url.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        print("📊 Request body size: \(body.count) bytes")
        
        await MainActor.run {
            self.currentStatus = "Processing transcription..."
            self.progress = 0.5
        }
        
        // Send request with timeout and timing
        let requestStartTime = Date()
        
        let (data, response) = try await withTimeout(
            seconds: 1800,
            timeoutError: WhisperError.serverError("Transcription request timed out after 30 minutes")
        ) { [self] in
            let result = try await session.data(for: request)
            let requestDuration = Date().timeIntervalSince(requestStartTime)
            
            if requestDuration < 10 && duration > 300 {
                print("🚨 WhisperService - CRITICAL: Request completed too quickly!")
                print("🚨 Expected: ~\(Int(duration/60)) minutes, Actual: \(requestDuration)s")
                print("🚨 This indicates a server-side issue or file processing problem")
            }
            
            return result
        }
        
        
        guard let httpResponse = response as? HTTPURLResponse else {
            await MainActor.run {
                self.isTranscribing = false
                self.currentStatus = "Invalid response"
            }
            throw WhisperError.invalidResponse("Not an HTTP response")
        }
        
        print("📡 HTTP response status: \(httpResponse.statusCode)")
        
        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("❌ Server error: \(errorText)")
            await MainActor.run {
                self.isTranscribing = false
                self.currentStatus = "Server error: \(httpResponse.statusCode)"
            }
            throw WhisperError.serverError("HTTP \(httpResponse.statusCode): \(errorText)")
        }
        
        await MainActor.run {
            self.currentStatus = "Processing results..."
            self.progress = 0.8
        }
        
        // Parse JSON response
        print("🔍 Parsing server response...")
        print("📄 Response data length: \(data.count) bytes")
        
        let responseText = String(data: data, encoding: .utf8) ?? ""
        print("📋 Response text: \(responseText.prefix(500))...")
        
        let whisperResponse: WhisperTranscribeResponse
        do {
            whisperResponse = try JSONDecoder().decode(WhisperTranscribeResponse.self, from: data)
        } catch {
            print("❌ Failed to parse JSON response: \(error)")
            print("🔍 Raw response: \(responseText)")
            await MainActor.run {
                self.isTranscribing = false
                self.currentStatus = "Failed to parse response"
            }
            throw WhisperError.invalidResponse("Failed to parse server response: \(error.localizedDescription)")
        }
        
        print("✅ Successfully parsed response")
        print("📝 Transcript text length: \(whisperResponse.text.count) characters")
        
        // Check if the response is empty or contains only whitespace
        if whisperResponse.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("⚠️ WARNING: Whisper returned empty transcript!")
            print("   - Raw text: '\(whisperResponse.text)'")
            print("   - Segments count: \(whisperResponse.segments?.count ?? 0)")
            print("   - Language: \(whisperResponse.language ?? "unknown")")
            print("   - This typically indicates the audio contains no clear speech content")
            print("   - Consider checking audio quality, volume levels, or background noise")
        } else {
            print("📝 Transcript preview: \(whisperResponse.text.prefix(100))...")
        }
        
        print("🌍 Detected language: \(whisperResponse.language ?? "unknown")")
        print("📊 Number of segments: \(whisperResponse.segments?.count ?? 0)")
        
        // Convert segments to TranscriptSegment format
        let segments = whisperResponse.segments?.map { segment in
            TranscriptSegment(
                speaker: segment.speaker ?? "Speaker",
                text: segment.text,
                startTime: segment.start,
                endTime: segment.end
            )
        } ?? []
        
        // Consolidate segments into a single segment to prevent UI fragmentation
        let finalSegments: [TranscriptSegment]
        if segments.count > 1 {
            // If we have multiple segments, consolidate them into one
            let firstSegment = segments.first!
            let lastSegment = segments.last!
            let consolidatedText = segments.map { $0.text }.joined(separator: " ")
            
            finalSegments = [
                TranscriptSegment(
                    speaker: "Speaker",
                    text: consolidatedText,
                    startTime: firstSegment.startTime,
                    endTime: lastSegment.endTime
                )
            ]
            print("🔗 Consolidated \(segments.count) segments into 1 segment")
        } else if segments.count == 1 {
            finalSegments = segments
        } else {
            // If no segments, create a single segment with the full text
            finalSegments = [
                TranscriptSegment(
                    speaker: "Speaker",
                    text: whisperResponse.text,
                    startTime: 0.0,
                    endTime: 0.0
                )
            ]
        }
        
        let result = TranscriptionResult(
            fullText: whisperResponse.text,
            segments: finalSegments,
            processingTime: 0.0, // We don't track this in the current implementation
            chunkCount: 1, // Single request for now
            success: true,
            error: nil
        )
        
        await MainActor.run {
            self.currentStatus = "Transcription completed"
            self.progress = 1.0
            self.isTranscribing = false
        }
        
        print("✅ Transcription completed successfully")
        return result
    }
    
    private func performWyomingTranscription(url: URL) async throws -> TranscriptionResult {
        print("🔮 Starting Wyoming protocol transcription for: \(url.lastPathComponent)")
        
        guard let wyomingClient = wyomingClient else {
            throw WhisperError.serverError("Wyoming client not initialized")
        }
        
        // Delegate to Wyoming client
        return try await wyomingClient.transcribeAudio(url: url)
    }
    
    // MARK: - Chunked Transcription (for large files)
    
    func transcribeAudioInChunks(url: URL, chunkDuration: TimeInterval = 3600, recordingId: UUID? = nil) async throws -> TranscriptionResult {
        // Check if chunking is needed for Whisper (2 hour limit)
        let needsChunking = try await chunkingService.shouldChunkFile(url, for: .whisper)
        if needsChunking {
            await MainActor.run {
                self.isTranscribing = true
                self.currentStatus = "Chunking audio file..."
                self.progress = 0.05
            }
            let chunkingResult = try await chunkingService.chunkAudioFile(url, for: .whisper)
            let chunks = chunkingResult.chunks
            var transcriptChunks: [TranscriptChunk] = []
            var chunkIndex = 0
            for audioChunk in chunks {
                await MainActor.run {
                    self.currentStatus = "Transcribing chunk \(chunkIndex + 1) of \(chunks.count)..."
                    self.progress = 0.05 + 0.85 * (Double(chunkIndex) / Double(chunks.count))
                }
                let result = try await performSingleTranscription(url: audioChunk.chunkURL)
                // Wrap result in TranscriptChunk
                let transcriptChunk = TranscriptChunk(
                    chunkId: audioChunk.id,
                    sequenceNumber: audioChunk.sequenceNumber,
                    transcript: result.fullText,
                    segments: result.segments,
                    startTime: audioChunk.startTime,
                    endTime: audioChunk.endTime,
                    processingTime: result.processingTime
                )
                transcriptChunks.append(transcriptChunk)
                chunkIndex += 1
            }
            // Reassemble transcript
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let creationDate = (fileAttributes[.creationDate] as? Date) ?? Date()
            let reassembly = try await chunkingService.reassembleTranscript(
                from: transcriptChunks,
                originalURL: url,
                recordingName: url.deletingPathExtension().lastPathComponent,
                recordingDate: creationDate,
                recordingId: recordingId ?? UUID() // TODO: Get actual recording ID from Core Data
            )
            // Clean up chunk files
            try await chunkingService.cleanupChunks(chunks)
            await MainActor.run {
                self.currentStatus = "Transcription complete"
                self.progress = 1.0
                self.isTranscribing = false
            }
            // Return as TranscriptionResult (flattened)
            return TranscriptionResult(
                fullText: reassembly.transcriptData.plainText,
                segments: reassembly.transcriptData.segments,
                processingTime: reassembly.reassemblyTime,
                chunkCount: chunks.count,
                success: true,
                error: nil
            )
        } else {
            // No chunking needed, use single file transcription directly
            print("📄 Single file transcription (no chunking needed)")
            return try await performSingleTranscription(url: url)
        }
    }
    
    // MARK: - Language Detection
    
    func detectLanguage(url: URL) async throws -> LanguageDetectionResponse {
        // First, ensure we have a valid connection
        if !isConnected {
            print("⚠️ Whisper service not connected, attempting to connect...")
            let connected = await testConnection()
            if !connected {
                throw WhisperError.notConnected
            }
        }
        
        print("🔍 Detecting language for: \(url.lastPathComponent)")
        
        // Create multipart form data request for language detection
        let boundary = UUID().uuidString
        let restBaseURL = config.restAPIBaseURL
        var request = URLRequest(url: URL(string: "\(restBaseURL)/detect-language")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        
        // Add file data
        let audioData = try Data(contentsOf: url)
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio_file\"; filename=\"\(url.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        
        // Send request with timeout
        let (data, response) = try await withTimeout(
            seconds: 60,
            timeoutError: WhisperError.serverError("Language detection timed out after 60 seconds")
        ) { [self] in
            try await session.data(for: request)
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WhisperError.invalidResponse("Not an HTTP response")
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw WhisperError.serverError("HTTP \(httpResponse.statusCode): \(errorText)")
        }
        
        // Parse JSON response
        let languageResponse: LanguageDetectionResponse
        do {
            languageResponse = try JSONDecoder().decode(LanguageDetectionResponse.self, from: data)
        } catch {
            throw WhisperError.invalidResponse("Failed to parse language detection response: \(error.localizedDescription)")
        }
        
        print("✅ Language detection completed: \(languageResponse.detected_language) (\(languageResponse.language_code)) - confidence: \(languageResponse.confidence)")
        
        return languageResponse
    }
    
} 
