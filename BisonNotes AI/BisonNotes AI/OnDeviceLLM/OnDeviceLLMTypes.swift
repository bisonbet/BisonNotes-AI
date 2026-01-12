//
//  OnDeviceLLMTypes.swift
//  BisonNotes AI
//
//  Core types for on-device LLM inference
//  Adapted from OLMoE.swift project
//

import Foundation
import llama

// MARK: - Type Aliases

public typealias Token = llama_token
public typealias LLMModel = OpaquePointer

// MARK: - Chat Structure (for internal use)

public struct LLMChat: Identifiable, Equatable {
    public var id: UUID?
    public var role: LLMRole
    public var content: String

    public init(id: UUID? = UUID(), role: LLMRole, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}

// MARK: - Role Enum

public enum LLMRole {
    case user
    case bot
}

// MARK: - Inference Actor for Thread Safety

@globalActor public actor InferenceActor {
    static public let shared = InferenceActor()
}

// MARK: - Inference Metrics

public struct InferenceMetrics {
    var inferenceTokenCount: Int32 = 0
    var inputTokenCount: Int32 = 0
    var totalTokens: Int32 = 0

    var startTime: TimeInterval = 0
    var endTime: TimeInterval = 0

    var inferenceTokensPerSecond: Double {
        self.tokensPerSecond(count: inferenceTokenCount)
    }

    func tokensPerSecond(count: Int32) -> Double {
        guard endTime > startTime else { return 0 }
        let duration = endTime - startTime
        return Double(count) / duration
    }

    mutating func start() {
        startTime = ProcessInfo.processInfo.systemUptime
        totalTokens = 0
        inferenceTokenCount = 0
    }

    mutating func recordToken() {
        inferenceTokenCount += 1
    }

    mutating func stop() {
        endTime = ProcessInfo.processInfo.systemUptime
        totalTokens = inputTokenCount + inferenceTokenCount
    }

    mutating func reset() {
        inferenceTokenCount = 0
        inputTokenCount = 0
        totalTokens = 0
        startTime = 0
        endTime = 0
    }
}

// MARK: - Errors

public enum OnDeviceLLMError: Error, LocalizedError {
    case modelNotLoaded
    case modelNotDownloaded
    case downloadFailed(String)
    case inferenceFailed(String)
    case networkUnavailable
    case insufficientDiskSpace(required: Int64)
    case configurationError(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "On-Device AI model is not loaded"
        case .modelNotDownloaded:
            return "Model file has not been downloaded yet"
        case .downloadFailed(let message):
            return "Model download failed: \(message)"
        case .inferenceFailed(let message):
            return "Inference failed: \(message)"
        case .networkUnavailable:
            return "Network connection is not available"
        case .insufficientDiskSpace(let required):
            return "Insufficient disk space. Need \(formatSize(required)) free."
        case .configurationError(let message):
            return "Configuration error: \(message)"
        }
    }
}

// MARK: - Feature Flags

enum OnDeviceLLMFeatureFlags {
    /// Whether to cache LLM state between calls (improves performance for conversation)
    /// For single-shot summarization, this can be false
    static let useLLMCaching = false

    /// Enable verbose logging for debugging
    static let verboseLogging = false
}

// MARK: - Helper Functions

private func formatSize(_ size: Int64) -> String {
    let sizeInGB = Double(size) / 1_000_000_000.0
    return String(format: "%.2f GB", sizeInGB)
}
