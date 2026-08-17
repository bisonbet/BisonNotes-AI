//
//  WyomingProtocol.swift
//  Audio Journal
//
//  Wyoming protocol message definitions and utilities
//

import Foundation

// MARK: - Wyoming Protocol Constants

struct WyomingConstants {
    static let protocolVersion = "1.0"
    static let defaultPort = 10300
    static let audioSampleRate = 16000
    static let audioChannels = 1
    static let audioBitDepth = 16
}

// MARK: - Message Types

enum WyomingMessageType: String, Codable, Sendable {
    case info = "info"
    case transcript = "transcript"
    case transcribe = "transcribe"
    case audioChunk = "audio-chunk"
    case audioStart = "audio-start"
    case audioStop = "audio-stop"
    case error = "error"
    case describe = "describe"
}

// MARK: - Base Message Structure

struct WyomingMessage: Codable, Sendable {
    let type: WyomingMessageType
    let data: WyomingAnyCodable?
    let timestamp: Double?

    // Binary payload (not included in JSON)
    var payload: Data?

    init(type: WyomingMessageType, data: (any WyomingMessageData)? = nil, payload: Data? = nil, includeTimestamp: Bool = false) {
        self.type = type
        self.data = data.map { WyomingAnyCodable($0) }
        self.timestamp = includeTimestamp ? Date().timeIntervalSince1970 : nil
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey {
        case type, data, timestamp
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)

        // Only encode data if it exists
        if let data = data {
            try container.encode(data, forKey: .data)
        }

        // Only encode timestamp if it exists
        if let timestamp = timestamp {
            try container.encode(timestamp, forKey: .timestamp)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(WyomingMessageType.self, forKey: .type)
        data = try container.decodeIfPresent(WyomingAnyCodable.self, forKey: .data)
        timestamp = try container.decodeIfPresent(Double.self, forKey: .timestamp)
    }
}

// MARK: - Message Data Protocol

protocol WyomingMessageData: Codable, Sendable {}

// MARK: - Type-erased Codable wrapper

/// A JSON value that can safely cross the asynchronous TCP/WebSocket boundaries.
///
/// The previous implementation stored `Any`, which made every Wyoming message
/// non-Sendable even though the wire format is restricted to JSON values. Keeping
/// the type-erased representation recursive preserves the existing JSON shape
/// without requiring an unsafe Sendable escape.
enum WyomingJSONValue: Codable, Sendable {
    case null
    case bool(Bool)
    case integer(Int)
    case double(Double)
    case string(String)
    case array([WyomingJSONValue])
    case object([String: WyomingJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
        } else if let intValue = try? container.decode(Int.self) {
            self = .integer(intValue)
        } else if let doubleValue = try? container.decode(Double.self) {
            self = .double(doubleValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let arrayValue = try? container.decode([WyomingJSONValue].self) {
            self = .array(arrayValue)
        } else {
            self = .object(try container.decode([String: WyomingJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

struct WyomingAnyCodable: Codable, Sendable {
    let value: WyomingJSONValue

    init<T: Codable>(_ value: T) {
        // WyomingMessageData is Codable and the protocol only sends JSON. The
        // fallback keeps this non-throwing initializer compatible with the
        // existing message factories; all production message payloads encode
        // successfully and therefore retain their exact wire representation.
        if let data = try? JSONEncoder().encode(value),
           let jsonValue = try? JSONDecoder().decode(WyomingJSONValue.self, from: data) {
            self.value = jsonValue
        } else {
            self.value = .null
        }
    }

    init(from decoder: Decoder) throws {
        value = try WyomingJSONValue(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}

// MARK: - Info Messages

struct WyomingInfoData: WyomingMessageData {
    let asr: [WyomingASRInfo]?
    let attribution: WyomingAttribution?
}

struct WyomingASRInfo: Codable, Sendable {
    let name: String
    let description: String?
    let attribution: WyomingAttribution?
    let installed: Bool
    let version: String?
    let models: [WyomingASRModel]?
    let supports_transcript_streaming: Bool?
}

struct WyomingASRModel: Codable, Sendable {
    let name: String
    let description: String?
    let attribution: WyomingAttribution?
    let installed: Bool
    let version: String?
    let languages: [String]?
}

struct WyomingAttribution: Codable, Sendable {
    let name: String
    let url: String?
}

// MARK: - Transcription Messages

/// Transcription request payload for Wyoming-compatible ASR servers.
///
/// Notes on language handling:
/// - `language == nil` means \"let the server auto-detect the language\".
/// - Call sites in the app intentionally pass `nil` by default to support
///   multilingual recordings without an extra setting.
struct WyomingTranscribeData: WyomingMessageData {
    let language: String?
    let model: String?
}

struct WyomingTranscriptData: WyomingMessageData {
    let text: String
    let language: String?
    let confidence: Double?

    init(text: String, language: String? = nil, confidence: Double? = nil) {
        self.text = text
        self.language = language
        self.confidence = confidence
    }
}

// MARK: - Audio Messages

struct WyomingAudioStartData: WyomingMessageData {
    let rate: Int
    let width: Int
    let channels: Int
    let timestamp: Double?

    init(rate: Int = WyomingConstants.audioSampleRate,
         width: Int = WyomingConstants.audioBitDepth,
         channels: Int = WyomingConstants.audioChannels) {
        self.rate = rate
        self.width = width / 8  // Convert bits to bytes (16 bits = 2 bytes)
        self.channels = channels
        self.timestamp = Date().timeIntervalSince1970
    }
}

struct WyomingAudioStopData: WyomingMessageData {
    let timestamp: Double?

    init() {
        self.timestamp = Date().timeIntervalSince1970
    }
}

struct WyomingAudioChunkData: WyomingMessageData {
    let rate: Int
    let width: Int
    let channels: Int
    let timestamp: Double?

    init(rate: Int = WyomingConstants.audioSampleRate, width: Int = WyomingConstants.audioBitDepth, channels: Int = WyomingConstants.audioChannels) {
        self.rate = rate
        self.width = width / 8  // Convert bits to bytes (16 bits = 2 bytes)
        self.channels = channels
        self.timestamp = Date().timeIntervalSince1970
    }
}

// MARK: - Error Messages

struct WyomingErrorData: WyomingMessageData {
    let code: String
    let message: String
    let details: String?
}

// MARK: - Message Factory

struct WyomingMessageFactory {

    static func createDescribeMessage() -> WyomingMessage {
        return WyomingMessage(type: .describe)
    }

    static func createTranscribeMessage(language: String? = nil, model: String? = nil) -> WyomingMessage {
        let data = WyomingTranscribeData(language: language, model: model)
        return WyomingMessage(type: .transcribe, data: data)
    }

    static func createAudioStartMessage() -> WyomingMessage {
        let data = WyomingAudioStartData()
        return WyomingMessage(type: .audioStart, data: data)
    }

    static func createAudioStopMessage() -> WyomingMessage {
        let data = WyomingAudioStopData()
        return WyomingMessage(type: .audioStop, data: data)
    }

    static func createAudioChunkMessage(audioData: Data, rate: Int = WyomingConstants.audioSampleRate, width: Int = WyomingConstants.audioBitDepth, channels: Int = WyomingConstants.audioChannels) -> WyomingMessage {
        let data = WyomingAudioChunkData(rate: rate, width: width, channels: channels)
        return WyomingMessage(type: .audioChunk, data: data, payload: audioData)
    }

    static func createErrorMessage(code: String, message: String, details: String? = nil) -> WyomingMessage {
        let data = WyomingErrorData(code: code, message: message, details: details)
        return WyomingMessage(type: .error, data: data)
    }
}

// MARK: - Message Parsing

extension WyomingMessage {

    func parseData<T: WyomingMessageData>(as type: T.Type) -> T? {
        guard let anyCodableData = self.data else { return nil }

        // Decode the Sendable JSON representation into the requested payload.
        do {
            let jsonData = try JSONEncoder().encode(anyCodableData)
            return try JSONDecoder().decode(type, from: jsonData)
        } catch {
            AppLog.shared.transcription("Failed to parse Wyoming message data as \(type): \(error)", level: .error)
            return nil
        }
    }
}

// MARK: - JSON Encoding/Decoding

extension WyomingMessage {

    func toJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        // Create a reference for adding payload_length
        let mutableSelf = self

        // Add payload_length to the JSON if we have a payload
        if let payload = self.payload, !payload.isEmpty {
            // We need to manually create the dictionary to add payload_length
            var eventDict: [String: Any] = [:]

            eventDict["type"] = self.type.rawValue

            if let data = self.data {
                let dataJSON = try JSONEncoder().encode(data)
                let dataDict = try JSONSerialization.jsonObject(with: dataJSON) as? [String: Any]
                eventDict["data"] = dataDict
            }

            if let timestamp = self.timestamp {
                eventDict["timestamp"] = timestamp
            }

            eventDict["payload_length"] = payload.count

            return try JSONSerialization.data(withJSONObject: eventDict)
        }

        return try encoder.encode(mutableSelf)
    }

    func toJSONString() throws -> String {
        let data = try toJSON()
        guard let string = String(data: data, encoding: .utf8) else {
            throw WyomingError.encodingFailed
        }
        return string
    }

    static func fromJSON(_ data: Data) throws -> WyomingMessage {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(WyomingMessage.self, from: data)
    }

    static func fromJSONString(_ string: String) throws -> WyomingMessage {
        guard let data = string.data(using: .utf8) else {
            throw WyomingError.decodingFailed
        }
        return try fromJSON(data)
    }
}

// MARK: - Wyoming Errors

enum WyomingError: Error, LocalizedError, Sendable {
    case connectionFailed
    case encodingFailed
    case decodingFailed
    case invalidMessage
    case serverError(String)
    case timeout
    case recordingIdentityRequired

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Failed to connect to Wyoming server"
        case .encodingFailed:
            return "Failed to encode Wyoming message"
        case .decodingFailed:
            return "Failed to decode Wyoming message"
        case .invalidMessage:
            return "Invalid Wyoming message format"
        case .serverError(let message):
            return "Wyoming server error: \(message)"
        case .timeout:
            return "Wyoming operation timed out"
        case .recordingIdentityRequired:
            return "A recording ID is required for chunked transcription."
        }
    }
}
