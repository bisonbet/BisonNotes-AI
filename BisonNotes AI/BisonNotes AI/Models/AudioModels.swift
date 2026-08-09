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
            // Used by AVAudioRecorder on iOS. Native Mac recording is
            // driven by AVAudioEngine + AVAudioFile (see
            // AudioRecorderViewModel+MacEngine.swift) which configures
            // its own AAC settings using the input node's native sample rate.
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

public enum ProcessingStatus: String, Codable, CaseIterable {
    case notStarted = "Not Started"
    case queued = "Queued"
    case processing = "Processing"
    case completed = "Completed"
    case failed = "Failed"
    case cancelled = "Cancelled"
    case interrupted = "Interrupted"

    public var description: String {
        return rawValue
    }

    public var isActive: Bool {
        return self == .queued || self == .processing
    }

    public var isComplete: Bool {
        return self == .completed
    }

    public var hasError: Bool {
        return self == .failed || self == .cancelled
    }

    public var isResumable: Bool {
        return self == .interrupted
    }
}

public enum TranscriptionEngine: String, CaseIterable, Codable {
    case notConfigured = "Not Configured"
    case fluidAudio = "On Device"
    case whisper = "Whisper (Local Server)"
    case mistralAI = "Mistral AI"

    /// Returns only engine types that are available on the current device and build.
    static var availableCases: [TranscriptionEngine] {
        return allCases.filter { $0.isAvailable }
    }

    var description: String {
        switch self {
        case .notConfigured:
            return "No transcription engine has been configured yet"
        case .fluidAudio:
            return "High-quality on-device transcription powered by NVIDIA Parakeet. Your audio never leaves your device, ensuring complete privacy."
        case .whisper:
            return "High-quality transcription using the Whisper model on your local server (REST API or Wyoming protocol)"
        case .mistralAI:
            return "High-quality transcription using Mistral's Voxtral Mini model with speaker diarization ($0.003/min)"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .notConfigured:
            return false
        case .fluidAudio:
            return DeviceCompatibility.isFluidAudioSupported && FluidAudioManager.isAvailableInCurrentBuild
        case .whisper, .mistralAI:
            return true
        }
    }

    var requiresConfiguration: Bool {
        switch self {
        case .notConfigured:
            return true
        case .fluidAudio:
            return true  // Requires model download
        case .whisper, .mistralAI:
            return true
        }
    }

    var usesWyomingProtocol: Bool {
        switch self {
        case .notConfigured, .fluidAudio:
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
