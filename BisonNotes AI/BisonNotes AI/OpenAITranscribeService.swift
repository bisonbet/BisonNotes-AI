//
//  OpenAITranscribeService.swift
//  Audio Journal
//
//  OpenAI transcription service for handling audio files with GPT-4o and Whisper models
//

import Foundation
import AVFoundation

// MARK: - OpenAI Configuration

struct OpenAITranscribeConfig {
    let apiKey: String
    let model: OpenAITranscribeModel
    let baseURL: String
    
    static let `default` = OpenAITranscribeConfig(
        apiKey: "",
        model: .gpt4oMiniTranscribe,
        baseURL: "https://api.openai.com/v1"
    )
}

// MARK: - OpenAI Models

enum OpenAITranscribeModel: String, CaseIterable {
    case gpt4oTranscribe = "gpt-4o-transcribe"
    case gpt4oMiniTranscribe = "gpt-4o-mini-transcribe"
    case whisper1 = "whisper-1"
    
    var displayName: String {
        switch self {
        case .gpt4oTranscribe:
            return "GPT-4o Transcribe"
        case .gpt4oMiniTranscribe:
            return "GPT-4o Mini Transcribe"
        case .whisper1:
            return "Whisper-1"
        }
    }
    
    var description: String {
        switch self {
        case .gpt4oTranscribe:
            return "Most robust transcription with GPT-4o model"
        case .gpt4oMiniTranscribe:
            return "Cheapest and fastest transcription with GPT-4o Mini model"
        case .whisper1:
            return "Legacy transcription with Whisper V2 model"
        }
    }
    
    var supportsStreaming: Bool {
        switch self {
        case .gpt4oTranscribe, .gpt4oMiniTranscribe:
            return true
        case .whisper1:
            return false
        }
    }
}

// MARK: - OpenAI Request/Response Models

/// Request parameters for an OpenAI transcription call.
/// Language is optional; when `nil` we rely on OpenAI's auto-detection.
/// Request parameters for an OpenAI transcription call.
///
/// Notes on language handling:
/// - `language` is optional; when `nil` we rely on OpenAI's built-in
///   auto-detection to infer the spoken language from audio.
struct OpenAITranscribeRequest {
    let file: Data
    let fileName: String
    let model: OpenAITranscribeModel
    let language: String?
    let prompt: String?
    let responseFormat: String
    let temperature: Double
}

struct OpenAITranscribeResponse: Codable {
    let text: String
    let usage: OpenAIUsage?
}

struct OpenAIUsage: Codable {
    let type: String?
    let inputTokens: Int?
    let inputTokenDetails: OpenAIInputTokenDetails?
    let outputTokens: Int?
    let totalTokens: Int?
    
    enum CodingKeys: String, CodingKey {
        case type
        case inputTokens = "input_tokens"
        case inputTokenDetails = "input_token_details"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
    }
}

struct OpenAIInputTokenDetails: Codable {
    let textTokens: Int?
    let audioTokens: Int?
    
    enum CodingKeys: String, CodingKey {
        case textTokens = "text_tokens"
        case audioTokens = "audio_tokens"
    }
}

struct OpenAIErrorResponse: Codable {
    let error: OpenAIError
}

struct OpenAIError: Codable {
    let message: String
    let type: String?
    let code: String?
}

// MARK: - OpenAI Transcribe Result

struct OpenAITranscribeResult {
    let transcriptText: String
    let segments: [TranscriptSegment]
    let processingTime: TimeInterval
    let usage: OpenAIUsage?
    let success: Bool
    let error: Error?
}

// MARK: - OpenAI Transcribe Service

@MainActor
class OpenAITranscribeService: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var isTranscribing = false
    @Published var currentStatus = ""
    @Published var progress: Double = 0.0
    
    // MARK: - Private Properties
    
    private let config: OpenAITranscribeConfig
    private let session: URLSession
    // Add chunking service
    private let chunkingService: AudioFileChunkingService
    
    // MARK: - Initialization
    
    init(config: OpenAITranscribeConfig = .default, chunkingService: AudioFileChunkingService) {
        self.config = config
        
        // Create a custom URLSession with longer timeout for transcription requests
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 1800.0  // 30 minutes
        sessionConfig.timeoutIntervalForResource = 1800.0 // 30 minutes
        self.session = URLSession(configuration: sessionConfig)
        self.chunkingService = chunkingService
        
        super.init()
    }
    
    // MARK: - Public Methods
    
    func testConnection() async throws {
        guard !config.apiKey.isEmpty else {
            throw OpenAITranscribeError.configurationMissing
        }
        
        // Test the API key by making a simple request to the models endpoint
        let testURL = URL(string: "\(config.baseURL)/models")!
        var request = URLRequest(url: testURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        print("🔌 Testing OpenAI API connection...")
        
        let (_, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAITranscribeError.invalidResponse("Not an HTTP response")
        }
        
        guard httpResponse.statusCode == 200 else {
            throw OpenAITranscribeError.authenticationFailed("HTTP \(httpResponse.statusCode)")
        }
        
    }
    
    func transcribeAudioFile(at url: URL, recordingId: UUID? = nil) async throws -> OpenAITranscribeResult {
        guard !config.apiKey.isEmpty else {
            throw OpenAITranscribeError.configurationMissing
        }
        
        isTranscribing = true
        currentStatus = "Preparing audio file..."
        progress = 0.0
        
        print("🚀 Starting OpenAI transcription for: \(url.lastPathComponent)")
        
        do {
            // Validate file
            guard url.isFileURL && FileManager.default.fileExists(atPath: url.path) else {
                throw OpenAITranscribeError.fileNotFound
            }
            
            // Use chunking service to check if chunking is needed
            let needsChunking = try await chunkingService.shouldChunkFile(url, for: .openAI)
            if needsChunking {
                currentStatus = "Chunking audio file..."
                progress = 0.05
                let chunkingResult = try await chunkingService.chunkAudioFile(url, for: .openAI)
                let chunks = chunkingResult.chunks
                var transcriptChunks: [TranscriptChunk] = []
                var chunkIndex = 0
                for audioChunk in chunks {
                    currentStatus = "Transcribing chunk \(chunkIndex + 1) of \(chunks.count)..."
                    progress = 0.05 + 0.85 * (Double(chunkIndex) / Double(chunks.count))
                    let audioData = try Data(contentsOf: audioChunk.chunkURL)
                    let startTime = Date()
                    let result = try await performTranscription(audioData: audioData, fileName: audioChunk.chunkURL.lastPathComponent)
                    let processingTime = Date().timeIntervalSince(startTime)
                    // Wrap result in TranscriptChunk
                    let transcriptChunk = TranscriptChunk(
                        chunkId: audioChunk.id,
                        sequenceNumber: audioChunk.sequenceNumber,
                        transcript: result.transcriptText,
                        segments: result.segments,
                        startTime: audioChunk.startTime,
                        endTime: audioChunk.endTime,
                        processingTime: processingTime
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
                currentStatus = "Transcription complete"
                progress = 1.0
                isTranscribing = false
                // Return as OpenAITranscribeResult (flattened)
                return OpenAITranscribeResult(
                    transcriptText: reassembly.transcriptData.plainText,
                    segments: reassembly.transcriptData.segments,
                    processingTime: reassembly.reassemblyTime,
                    usage: nil, // Usage is not aggregated for chunked
                    success: true,
                    error: nil
                )
            } else {
                // Check file size (OpenAI has a 25MB limit)
                let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let fileSize = fileAttributes[.size] as? Int64 ?? 0
                let maxSize: Int64 = 25 * 1024 * 1024 // 25MB
                
                guard fileSize <= maxSize else {
                    throw OpenAITranscribeError.fileTooLarge("File size \(fileSize / 1024 / 1024)MB exceeds 25MB limit")
                }
                
                currentStatus = "Reading audio file..."
                progress = 0.1
                
                let audioData = try Data(contentsOf: url)
                print("📁 Audio file size: \(audioData.count) bytes")
                
                currentStatus = "Sending to OpenAI..."
                progress = 0.2
                
                let result = try await performTranscription(audioData: audioData, fileName: url.lastPathComponent)
                
                currentStatus = "Transcription complete"
                progress = 1.0
                isTranscribing = false
                
                return result
            }
            
        } catch {
            isTranscribing = false
            currentStatus = "Transcription failed"
            progress = 0.0
            throw error
        }
    }
    
    // MARK: - Private Methods
    
    private func performTranscription(audioData: Data, fileName: String) async throws -> OpenAITranscribeResult {
        let startTime = Date()
        
        // Create multipart form data
        let boundary = UUID().uuidString
        let url = URL(string: "\(config.baseURL)/audio/transcriptions")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        
        // Add file data
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(getContentType(for: fileName))\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        
        // Add model
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append(config.model.rawValue.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
        
        // Add response format (JSON for all models, but GPT models only support JSON anyway)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("json".data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
        
        // Note: we intentionally do NOT send a `language` field here so that
        // OpenAI can auto-detect the spoken language from the audio input.
        
        // Add temperature (0 for most deterministic results)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"temperature\"\r\n\r\n".data(using: .utf8)!)
        body.append("0".data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
        
        // Close boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        print("🔧 Using model: \(config.model.displayName)")
        print("📊 Request body size: \(body.count) bytes")
        
        currentStatus = "Processing with \(config.model.displayName)..."
        progress = 0.5
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAITranscribeError.invalidResponse("Not an HTTP response")
        }
        
        print("📡 HTTP response status: \(httpResponse.statusCode)")
        
        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("❌ OpenAI API error: \(errorText)")
            
            // Try to parse error response
            if let errorResponse = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
                throw OpenAITranscribeError.apiError(errorResponse.error.message)
            } else {
                throw OpenAITranscribeError.apiError("HTTP \(httpResponse.statusCode): \(errorText)")
            }
        }
        
        currentStatus = "Processing results..."
        progress = 0.8
        
        // Parse response
        let responseText = String(data: data, encoding: .utf8) ?? ""
        print("📄 Response data length: \(data.count) bytes")
        print("📋 Response preview: \(responseText.prefix(200))...")
        
        let transcribeResponse: OpenAITranscribeResponse
        do {
            transcribeResponse = try JSONDecoder().decode(OpenAITranscribeResponse.self, from: data)
        } catch {
            print("❌ Failed to parse JSON response: \(error)")
            print("🔍 Raw response: \(responseText)")
            throw OpenAITranscribeError.invalidResponse("Failed to parse response: \(error.localizedDescription)")
        }
        
        let processingTime = Date().timeIntervalSince(startTime)
        
        print("📝 Transcript length: \(transcribeResponse.text.count) characters")
        print("⏱️ Processing time: \(processingTime) seconds")
        
        if let usage = transcribeResponse.usage {
            print("💰 Token usage - Input: \(usage.inputTokens ?? 0), Output: \(usage.outputTokens ?? 0), Total: \(usage.totalTokens ?? 0)")
        }
        
        // Create segments (OpenAI doesn't provide timestamps in basic response, so create one segment)
        let segments = [TranscriptSegment(
            speaker: "Speaker",
            text: transcribeResponse.text,
            startTime: 0.0,
            endTime: 0.0
        )]
        
        return OpenAITranscribeResult(
            transcriptText: transcribeResponse.text,
            segments: segments,
            processingTime: processingTime,
            usage: transcribeResponse.usage,
            success: true,
            error: nil
        )
    }
    
    private func getContentType(for fileName: String) -> String {
        let fileExtension = fileName.lowercased().components(separatedBy: ".").last ?? ""
        
        switch fileExtension {
        case "mp3":
            return "audio/mpeg"
        case "mp4", "m4a":
            return "audio/mp4"
        case "wav":
            return "audio/wav"
        case "flac":
            return "audio/flac"
        case "ogg":
            return "audio/ogg"
        case "webm":
            return "audio/webm"
        default:
            return "audio/mp4" // Default fallback
        }
    }
}

// MARK: - OpenAI Transcribe Errors

enum OpenAITranscribeError: LocalizedError {
    case configurationMissing
    case fileNotFound
    case fileTooLarge(String)
    case authenticationFailed(String)
    case apiError(String)
    case invalidResponse(String)
    case networkError(Error)
    
    var errorDescription: String? {
        switch self {
        case .configurationMissing:
            return "OpenAI API key is missing. Please configure your API key in settings."
        case .fileNotFound:
            return "Audio file not found or inaccessible."
        case .fileTooLarge(let message):
            return "File too large: \(message)"
        case .authenticationFailed(let message):
            return "Authentication failed: \(message). Please check your API key."
        case .apiError(let message):
            return "OpenAI API error: \(message)"
        case .invalidResponse(let message):
            return "Invalid response from OpenAI: \(message)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}
