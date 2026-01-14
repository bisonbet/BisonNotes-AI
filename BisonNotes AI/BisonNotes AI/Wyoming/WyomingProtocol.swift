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

enum WyomingMessageType: String, Codable {
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

struct WyomingMessage: Codable {
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

protocol WyomingMessageData: Codable {}

// MARK: - Type-erased Codable wrapper

struct WyomingAnyCodable: Codable {
    let value: Any
    
    init<T: Codable>(_ value: T) {
        self.value = value
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
        } else if let stringValue = try? container.decode(String.self) {
            value = stringValue
        } else if let boolValue = try? container.decode(Bool.self) {
            value = boolValue
        } else {
            // Try to decode as a dictionary for complex objects
            let dictValue = try container.decode([String: WyomingAnyCodable].self)
            value = dictValue
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case let intValue as Int:
            try container.encode(intValue)
        case let doubleValue as Double:
            try container.encode(doubleValue)
        case let stringValue as String:
            try container.encode(stringValue)
        case let boolValue as Bool:
            try container.encode(boolValue)
        case let codableValue as Codable:
            try container.encode(WyomingAnyEncodable(codableValue))
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: [], debugDescription: "Cannot encode value"))
        }
    }
}

private struct WyomingAnyEncodable: Encodable {
    let value: Encodable
    
    init(_ value: Encodable) {
        self.value = value
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

struct WyomingASRInfo: Codable {
    let name: String
    let description: String?
    let attribution: WyomingAttribution?
    let installed: Bool
    let version: String?
    let models: [WyomingASRModel]?
    let supports_transcript_streaming: Bool?
}

struct WyomingASRModel: Codable {
    let name: String
    let description: String?
    let attribution: WyomingAttribution?
    let installed: Bool
    let version: String?
    let languages: [String]?
}

struct WyomingAttribution: Codable {
    let name: String
    let url: String?
}

// MARK: - Transcription Messages

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
        
        // Try to decode the WyomingAnyCodable value as the requested type
        if let codableValue = anyCodableData.value as? T {
            return codableValue
        }
        
        // If direct casting fails, try JSON round-trip decoding
        do {
            let jsonData = try JSONEncoder().encode(anyCodableData)
            return try JSONDecoder().decode(type, from: jsonData)
        } catch {
            print("⚠️ Failed to parse Wyoming message data as \(type): \(error)")
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

enum WyomingError: Error, LocalizedError {
    case connectionFailed
    case encodingFailed
    case decodingFailed
    case invalidMessage
    case serverError(String)
    case timeout
    
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
        }
    }
}
