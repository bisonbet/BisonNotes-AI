//
//  AudioModels.swift
//  Audio Journal
//
//  Created by Tim Champ on 7/28/25.
//

import Foundation
import AVFoundation

enum AudioQuality: String, CaseIterable {
    case low = "Low Quality"
    case medium = "Medium Quality"
    case high = "High Quality"
    
    var settings: [String: Any] {
        switch self {
        case .low:
            return [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 22050,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
                AVEncoderBitRateKey: 64000
            ]
        case .medium:
            return [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                AVEncoderBitRateKey: 128000
            ]
        case .high:
            return [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                AVEncoderBitRateKey: 256000
            ]
        }
    }
    
    var description: String {
        switch self {
        case .low:
            return "64 kbps, 22.05 kHz - Good for voice, smaller files"
        case .medium:
            return "128 kbps, 44.1 kHz - Balanced quality and file size"
        case .high:
            return "256 kbps, 48 kHz - High fidelity, larger files"
        }
    }
}

enum SummaryMethod: String, CaseIterable {
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

enum TranscriptionEngine: String, CaseIterable {
    case appleIntelligence = "Apple Intelligence (Limited)"
    case awsTranscribe = "AWS Transcribe"
    case whisper = "Whisper (Local Server)"
    case openAI = "OpenAI"
    case openAIAPICompatible = "OpenAI API Compatible"
    
    var description: String {
        switch self {
        case .appleIntelligence:
            return "Uses Apple's built-in Speech framework for local transcription with 1-minute limit per request"
        case .awsTranscribe:
            return "Cloud-based transcription service with support for long audio files"
        case .whisper:
            return "High-quality transcription using OpenAI's Whisper model via REST API on your local server"
        case .openAI:
            return "High-quality transcription using OpenAI's GPT-4o and Whisper models via API"
        case .openAIAPICompatible:
            return "Connect to OpenAI-compatible API endpoints for flexible transcription options (Coming Soon)"
        }
    }
    
    var isAvailable: Bool {
        switch self {
        case .appleIntelligence, .awsTranscribe, .whisper, .openAI:
            return true
        case .openAIAPICompatible:
            return false
        }
    }
    
    var requiresConfiguration: Bool {
        switch self {
        case .appleIntelligence:
            return false
        case .awsTranscribe, .whisper, .openAI, .openAIAPICompatible:
            return true
        }
    }
}