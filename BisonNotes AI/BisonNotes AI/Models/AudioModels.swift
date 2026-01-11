//
//  AudioModels.swift
//  Audio Journal
//
//  Created by Tim Champ on 7/28/25.
//

import Foundation
import AVFoundation

public enum AudioQuality: String, CaseIterable, Codable {
    case whisperOptimized = "Whisper Optimized"
    
    var settings: [String: Any] {
        switch self {
        case .whisperOptimized:
            return [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 22050,  // Good for Whisper, compatible with AAC
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
                AVEncoderBitRateKey: 64000  // Excellent quality for voice
            ]
        }
    }
    
    var description: String {
        switch self {
        case .whisperOptimized:
            return "22 kHz, 64 kbps AAC - Optimized for voice transcription"
        }
    }
}

public enum SummaryMethod: String, CaseIterable {
    case appleIntelligence = "Apple Intelligence (Basic)"
    case localServer = "Local Server (Ollama)"
    case openAI = "OpenAI (GPT-4.1)"
    case awsBedrock = "AWS Bedrock (Advanced)"
    
    var description: String {
        switch self {
        case .appleIntelligence:
            return "Uses Apple's built-in Natural Language framework for basic summarization"
        case .localServer:
            return "Connect to local Ollama server for enhanced AI processing"
        case .openAI:
            return "Advanced AI-powered summaries using OpenAI's GPT models"
        case .awsBedrock:
            return "Use AWS Bedrock for advanced AI-powered summaries (Coming Soon)"
        }
    }
    
    var isAvailable: Bool {
        switch self {
        case .appleIntelligence, .localServer, .openAI:
            return true
        case .awsBedrock:
            return false
        }
    }
}

public enum WhisperProtocol: String, CaseIterable, Codable {
    case rest = "REST API"
    case wyoming = "Wyoming"
    
    var description: String {
        switch self {
        case .rest:
            return "Traditional HTTP REST API with file uploads"
        case .wyoming:
            return "Modern streaming protocol with WebSocket connection"
        }
    }
    
    var shortName: String {
        switch self {
        case .rest:
            return "REST"
        case .wyoming:
            return "Wyoming"
        }
    }
}

public enum TranscriptionEngine: String, CaseIterable, Codable {
    case notConfigured = "Not Configured"
    case appleIntelligence = "Apple Transcription"
    case awsTranscribe = "AWS Transcribe"
    case whisper = "Whisper (Local Server)"
    case openAI = "OpenAI"
    case openAIAPICompatible = "OpenAI API Compatible"

    /// Returns all available engine types based on device capabilities
    static var availableCases: [TranscriptionEngine] {
        return allCases
    }

    var description: String {
        switch self {
        case .notConfigured:
            return "No transcription engine has been configured yet"
        case .appleIntelligence:
            return "Uses Apple's built-in Speech framework for local transcription with 1-minute limit per request"
        case .awsTranscribe:
            return "Cloud-based transcription service with support for long audio files"
        case .whisper:
            return "High-quality transcription using OpenAI's Whisper model on your local server (REST API or Wyoming protocol)"
        case .openAI:
            return "High-quality transcription using OpenAI's GPT-4o models and Whisper via API"
        case .openAIAPICompatible:
            return "Connect to OpenAI-compatible API endpoints for flexible transcription options (Coming Soon)"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .notConfigured:
            return false
        case .appleIntelligence, .awsTranscribe, .whisper, .openAI:
            return true
        case .openAIAPICompatible:
            return false
        }
    }
    
    var requiresConfiguration: Bool {
        switch self {
        case .notConfigured:
            return true
        case .appleIntelligence:
            return false
        case .awsTranscribe, .whisper, .openAI, .openAIAPICompatible:
            return true
        }
    }
    
    var usesWyomingProtocol: Bool {
        switch self {
        case .notConfigured:
            return false
        case .whisper:
            // For unified Whisper, check the user's protocol preference
            let protocolString = UserDefaults.standard.string(forKey: "whisperProtocol") ?? WhisperProtocol.rest.rawValue
            let selectedProtocol = WhisperProtocol(rawValue: protocolString) ?? .rest
            return selectedProtocol == .wyoming
        default:
            return false
        }
    }
}

// MARK: - Engine Validation Result

public enum EngineValidationResult {
    case available
    case unavailable(String)
    case requiresConfiguration(String)
    
    var isAvailable: Bool {
        switch self {
        case .available:
            return true
        case .unavailable, .requiresConfiguration:
            return false
        }
    }
    
    var message: String {
        switch self {
        case .available:
            return "Engine is available"
        case .unavailable(let reason):
            return "Engine unavailable: \(reason)"
        case .requiresConfiguration(let requirement):
            return "Configuration required: \(requirement)"
        }
    }
}
