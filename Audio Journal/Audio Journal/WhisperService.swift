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

// MARK: - Helper Functions

func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw WhisperError.serverError("Operation timed out after \(seconds) seconds")
        }
        
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

// MARK: - Whisper Configuration

struct WhisperConfig {
    let serverURL: String
    let port: Int
    
    var baseURL: String {
        return "\(serverURL):\(port)"
    }
    
    static let `default` = WhisperConfig(
        serverURL: "http://localhost",
        port: 9000
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
    // Add chunking service
    private let chunkingService: AudioFileChunkingService
    
    @Published var isConnected: Bool = false
    @Published var connectionError: String?
    @Published var isTranscribing = false
    @Published var currentStatus = ""
    @Published var progress: Double = 0.0
    
    init(config: WhisperConfig = .default, chunkingService: AudioFileChunkingService) {
        self.config = config
        
        // Create a custom URLSession with longer timeout for Whisper requests
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 1800.0  // 30 minutes
        sessionConfig.timeoutIntervalForResource = 1800.0 // 30 minutes
        self.session = URLSession(configuration: sessionConfig)
        self.chunkingService = chunkingService
    }
    
    // MARK: - Connection Management
    
    func testConnection() async -> Bool {
        do {
            // Test the /asr endpoint with a simple GET request
            let testURL = URL(string: "\(config.baseURL)/asr")!
            print("🔌 Testing REST API connection to: \(testURL)")
            
            let (_, response) = try await withTimeout(seconds: 10) { [self] in
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
    
    func transcribeAudio(url: URL) async throws -> TranscriptionResult {
        // First, ensure we have a valid connection
        if !isConnected {
            print("⚠️ Whisper service not connected, attempting to connect...")
            let connected = await testConnection()
            if !connected {
                throw WhisperError.notConnected
            }
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
            throw WhisperError.audioProcessingFailed("Audio file does not exist at path: \(url.path)")
        }
        
        await MainActor.run {
            self.currentStatus = "Sending audio to Whisper service..."
            self.progress = 0.2
        }
        
        // Create multipart form data request
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "\(config.baseURL)/asr")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        
        // Add query parameters
        var urlComponents = URLComponents(string: "\(config.baseURL)/asr")!
        urlComponents.queryItems = [
            URLQueryItem(name: "output", value: "json"),
            URLQueryItem(name: "task", value: "transcribe"),
            URLQueryItem(name: "language", value: "en"),
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
        
        print("📤 Sending REST API request to: \(request.url?.absoluteString ?? "unknown")")
        print("📊 Request body size: \(body.count) bytes")
        
        await MainActor.run {
            self.currentStatus = "Processing transcription..."
            self.progress = 0.5
        }
        
        // Send request with timeout
        let (data, response) = try await withTimeout(seconds: 1800) { [self] in
            try await session.data(for: request)
        }
        
        print("📥 Received response from server")
        
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
        print("📝 Transcript text: \(whisperResponse.text.prefix(100))...")
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
    
    // MARK: - Chunked Transcription (for large files)
    
    func transcribeAudioInChunks(url: URL, chunkDuration: TimeInterval = 3600) async throws -> TranscriptionResult {
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
                let result = try await transcribeAudio(url: audioChunk.chunkURL)
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
                recordingDate: creationDate
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
            // No chunking needed, use single file method
            return try await transcribeAudio(url: url)
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
        var request = URLRequest(url: URL(string: "\(config.baseURL)/detect-language")!)
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
        
        print("📤 Sending language detection request...")
        
        // Send request with timeout
        let (data, response) = try await withTimeout(seconds: 60) { [self] in
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