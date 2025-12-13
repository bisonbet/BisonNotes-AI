//
//  MistralAIModels.swift
//  Audio Journal
//
//  Mistral AI models and configuration for AI summarization
//

import Foundation

// MARK: - Mistral AI Models

/// Available Mistral AI models for summarization
///
/// **Model Selection Guide:**
/// - **Large (25.12)**: Best for complex reasoning, long transcripts (128K context), highest quality
/// - **Medium (25.08)**: Balanced choice for most use cases, good quality at standard pricing
/// - **Magistral (25.09)**: Budget-friendly option for simple summaries and task extraction
///
/// All models support chunked processing for transcripts exceeding their context windows.
enum MistralAIModel: String, CaseIterable {
    case mistralLarge2512 = "mistral-large-2512"
    case mistralMedium2508 = "mistral-medium-2508"
    case magistralMedium2509 = "magistral-medium-2509"

    var displayName: String {
        switch self {
        case .mistralLarge2512:
            return "Mistral Large (25.12)"
        case .mistralMedium2508:
            return "Mistral Medium (25.08)"
        case .magistralMedium2509:
            return "Magistral Medium (25.09)"
        }
    }

    var description: String {
        switch self {
        case .mistralLarge2512:
            return "Flagship large-context model tuned for high-quality reasoning and summarization"
        case .mistralMedium2508:
            return "Balanced model for fast, cost-effective summarization and task extraction"
        case .magistralMedium2509:
            return "Instruction-tuned medium model optimized for structured outputs"
        }
    }

    var maxTokens: Int {
        switch self {
        case .mistralLarge2512:
            return 8192
        case .mistralMedium2508, .magistralMedium2509:
            return 4096
        }
    }

    var contextWindow: Int {
        switch self {
        case .mistralLarge2512:
            return 128_000
        case .mistralMedium2508, .magistralMedium2509:
            return 32_000
        }
    }

    var costTier: String {
        switch self {
        case .mistralLarge2512:
            return "Premium"
        case .mistralMedium2508:
            return "Standard"
        case .magistralMedium2509:
            return "Economy"
        }
    }

    var provider: String {
        return "Mistral AI"
    }

    /// Rate limit delay in nanoseconds between chunk processing requests
    var rateLimitDelay: UInt64 {
        switch self {
        case .mistralLarge2512:
            return 500_000_000 // 500ms for premium model (more conservative)
        case .mistralMedium2508:
            return 300_000_000 // 300ms for standard model
        case .magistralMedium2509:
            return 200_000_000 // 200ms for economy model (faster processing)
        }
    }
}

// MARK: - Mistral AI Configuration

/// Configuration for Mistral AI summarization service
///
/// Note: Uses default Equatable implementation. TimeInterval (Double) uses exact equality,
/// which is appropriate here since timeout values are constants, not computed values.
struct MistralAIConfig: Equatable {
    let apiKey: String
    let model: MistralAIModel
    let baseURL: String
    let temperature: Double
    let maxTokens: Int
    let timeout: TimeInterval
    let supportsJsonResponseFormat: Bool

    static let `default` = MistralAIConfig(
        apiKey: "",
        model: .mistralMedium2508,
        baseURL: "https://api.mistral.ai/v1",
        temperature: 0.1,
        maxTokens: 4096,
        timeout: 45.0,
        supportsJsonResponseFormat: true
    )

    /// Check if the base URL is the official Mistral API
    var isOfficialMistralAPI: Bool {
        return baseURL.contains("api.mistral.ai")
    }
}
