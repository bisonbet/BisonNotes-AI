//
//  MistralTranscribeService.swift
//  Audio Journal
//
//  Mistral AI transcription service using Voxtral Mini for audio-to-text
//

import Foundation
import AVFoundation

// MARK: - Mistral Transcribe Configuration

struct MistralTranscribeConfig {
    let apiKey: String
    let model: MistralTranscribeModel
    let baseURL: String
    let diarize: Bool
    let language: String? // nil = auto-detect

    static let `default` = MistralTranscribeConfig(
        apiKey: "",
        model: .voxtralMiniLatest,
        baseURL: "https://api.mistral.ai/v1",
        diarize: false,
        language: nil
    )
}

// MARK: - Mistral Transcribe Models

enum MistralTranscribeModel: String, CaseIterable {
    case voxtralMiniLatest = "voxtral-mini-latest"

    var displayName: String {
        switch self {
        case .voxtralMiniLatest:
            return "Voxtral Mini Transcribe"
        }
    }

    var description: String {
        switch self {
        case .voxtralMiniLatest:
            return "Fast, cost-effective speech-to-text ($0.003/min) with diarization support"
        }
    }
}

// MARK: - Mistral Transcribe Response Models

struct MistralTranscribeResponse: Codable {
    let text: String
}

struct MistralTranscribeVerboseResponse: Codable {
    let text: String
    let segments: [MistralSegment]?
    let words: [MistralWord]?
}

struct MistralSegment: Codable {
    let text: String
    let start: Double?
    let end: Double?
    let speakerId: String?
    let score: Double?

    enum CodingKeys: String, CodingKey {
        case text, start, end, score
        case speakerId = "speaker_id"
    }
}

struct MistralWord: Codable {
    let text: String
    let start: Double?
    let end: Double?
    let speakerId: String?

    enum CodingKeys: String, CodingKey {
        case text, start, end
        case speakerId = "speaker_id"
    }
}

// MARK: - Mistral Transcribe Result

struct MistralTranscribeResult {
    let transcriptText: String
    let segments: [TranscriptSegment]
    let processingTime: TimeInterval
    let success: Bool
    let error: Error?
}

// MARK: - Mistral Transcribe Service

@MainActor
class MistralTranscribeService: NSObject, ObservableObject {

    // MARK: - Published Properties

    @Published var isTranscribing = false
    @Published var currentStatus = ""
    @Published var progress: Double = 0.0

    // MARK: - Private Properties

    private let config: MistralTranscribeConfig
    private let session: URLSession
    private let chunkingService: AudioFileChunkingService

    // MARK: - Initialization

    init(config: MistralTranscribeConfig = .default, chunkingService: AudioFileChunkingService) {
        self.config = config

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 1800.0 // 30 minutes
        sessionConfig.timeoutIntervalForResource = 1800.0
        self.session = URLSession(configuration: sessionConfig)
        self.chunkingService = chunkingService

        super.init()
    }

    // MARK: - Public Methods

    func testConnection() async throws {
        guard !config.apiKey.isEmpty else {
            throw MistralTranscribeError.configurationMissing
        }

        guard let testURL = URL(string: "\(config.baseURL)/models") else {
            throw MistralTranscribeError.invalidResponse("Invalid base URL: \(config.baseURL)")
        }
        var request = URLRequest(url: testURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("BisonNotes AI iOS App", forHTTPHeaderField: "User-Agent")

        print("🔌 Testing Mistral API connection")

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MistralTranscribeError.invalidResponse("Not an HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            throw MistralTranscribeError.authenticationFailed("HTTP \(httpResponse.statusCode)")
        }
    }

    func transcribeAudioFile(at url: URL, recordingId: UUID? = nil) async throws -> MistralTranscribeResult {
        guard !config.apiKey.isEmpty else {
            throw MistralTranscribeError.configurationMissing
        }

        isTranscribing = true
        currentStatus = "Preparing audio file..."
        progress = 0.0

        print("🚀 Starting Mistral transcription for: \(url.lastPathComponent)")

        do {
            guard url.isFileURL && FileManager.default.fileExists(atPath: url.path) else {
                throw MistralTranscribeError.fileNotFound
            }

            // Check if chunking is needed
            let needsChunking = try await chunkingService.shouldChunkFile(url, for: .mistralAI)
            if needsChunking {
                currentStatus = "Chunking audio file..."
                progress = 0.05
                let chunkingResult = try await chunkingService.chunkAudioFile(url, for: .mistralAI)
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
                    recordingId: recordingId ?? UUID()
                )
                // Clean up chunk files
                try await chunkingService.cleanupChunks(chunks)
                currentStatus = "Transcription complete"
                progress = 1.0
                isTranscribing = false
                return MistralTranscribeResult(
                    transcriptText: reassembly.transcriptData.plainText,
                    segments: reassembly.transcriptData.segments,
                    processingTime: reassembly.reassemblyTime,
                    success: true,
                    error: nil
                )
            } else {
                currentStatus = "Reading audio file..."
                progress = 0.1

                let audioData = try Data(contentsOf: url)

                currentStatus = "Sending to Mistral AI..."
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

    private func performTranscription(audioData: Data, fileName: String) async throws -> MistralTranscribeResult {
        let startTime = Date()

        let boundary = UUID().uuidString
        guard let url = URL(string: "\(config.baseURL)/audio/transcriptions") else {
            throw MistralTranscribeError.invalidResponse("Invalid base URL: \(config.baseURL)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("BisonNotes AI iOS App", forHTTPHeaderField: "User-Agent")

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

        // Add response_format for timestamps
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("verbose_json".data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)

        // Add timestamp_granularities for segment-level timestamps
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"timestamp_granularities[]\"\r\n\r\n".data(using: .utf8)!)
        body.append("segment".data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)

        // Add diarize if enabled
        if config.diarize {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"diarize\"\r\n\r\n".data(using: .utf8)!)
            body.append("true".data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }

        // Add language if specified (otherwise Mistral auto-detects)
        if let language = config.language, !language.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
            body.append(language.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }

        // Close boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        print("🎙️ Mistral transcription: model=\(config.model.rawValue), diarize=\(config.diarize), size=\(body.count) bytes")

        currentStatus = "Processing with \(config.model.displayName)..."
        progress = 0.5

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MistralTranscribeError.invalidResponse("Not an HTTP response")
        }

        // Handle rate limiting
        if httpResponse.statusCode == 429 {
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After") ?? "unknown"
            var errorMessage = "Mistral API rate limit exceeded."
            if let retrySeconds = Int(retryAfter) {
                errorMessage += " Please retry after \(retrySeconds) seconds."
            }
            throw MistralTranscribeError.apiError(errorMessage)
        }

        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("❌ Mistral API error: \(errorText)")

            if let errorResponse = try? JSONDecoder().decode(MistralErrorResponse.self, from: data) {
                let message = errorResponse.message ?? errorResponse.detail?.message ?? errorText
                throw MistralTranscribeError.apiError(message)
            } else {
                throw MistralTranscribeError.apiError("HTTP \(httpResponse.statusCode): \(errorText)")
            }
        }

        currentStatus = "Processing results..."
        progress = 0.8

        // Try verbose response first (with segments/speakers), fall back to simple
        let transcriptText: String
        var segments: [TranscriptSegment] = []

        if let verboseResponse = try? JSONDecoder().decode(MistralTranscribeVerboseResponse.self, from: data),
           let mistralSegments = verboseResponse.segments, !mistralSegments.isEmpty {
            transcriptText = verboseResponse.text
            let speakerCount = Set(mistralSegments.compactMap { $0.speakerId }).count
            print("📝 Parsed \(mistralSegments.count) segments with \(speakerCount) unique speakers")
            segments = mistralSegments.map { seg in
                TranscriptSegment(
                    speaker: seg.speakerId ?? "Speaker",
                    text: seg.text,
                    startTime: seg.start ?? 0.0,
                    endTime: seg.end ?? 0.0
                )
            }
        } else if let simpleResponse = try? JSONDecoder().decode(MistralTranscribeResponse.self, from: data) {
            transcriptText = simpleResponse.text
            segments = [TranscriptSegment(
                speaker: "Speaker",
                text: simpleResponse.text,
                startTime: 0.0,
                endTime: 0.0
            )]
        } else {
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "undecodable"
            throw MistralTranscribeError.invalidResponse("Failed to parse response: \(preview)")
        }

        let processingTime = Date().timeIntervalSince(startTime)

        print("📝 Mistral transcription complete: \(transcriptText.count) chars, \(segments.count) segments, \(String(format: "%.1f", processingTime))s")

        return MistralTranscribeResult(
            transcriptText: transcriptText,
            segments: segments,
            processingTime: processingTime,
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
            return "audio/mp4"
        }
    }
}

// MARK: - Mistral Error Response

struct MistralErrorResponse: Codable {
    let message: String?
    let detail: MistralErrorDetail?
}

struct MistralErrorDetail: Codable {
    let message: String?
}

// MARK: - Mistral Transcribe Errors

enum MistralTranscribeError: LocalizedError {
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
            return "Mistral API key is missing. Please configure your API key in Mistral AI settings."
        case .fileNotFound:
            return "Audio file not found or inaccessible."
        case .fileTooLarge(let message):
            return "File too large: \(message)"
        case .authenticationFailed(let message):
            return "Authentication failed: \(message). Please check your Mistral API key."
        case .apiError(let message):
            return "Mistral API error: \(message)"
        case .invalidResponse(let message):
            return "Invalid response from Mistral: \(message)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}
