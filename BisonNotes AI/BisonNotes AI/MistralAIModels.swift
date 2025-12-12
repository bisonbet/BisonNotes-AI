//
//  MistralAIModels.swift
//  Audio Journal
//
//  Mistral AI models and configuration for AI summarization
//

import Foundation

// MARK: - Mistral AI Models

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
}

// MARK: - Mistral AI Configuration

struct MistralAIConfig: Equatable {
    let apiKey: String
    let model: MistralAIModel
    let baseURL: String
    let temperature: Double
    let maxTokens: Int
    let timeout: TimeInterval

    static let `default` = MistralAIConfig(
        apiKey: "",
        model: .mistralMedium2508,
        baseURL: "https://api.mistral.ai/v1",
        temperature: 0.1,
        maxTokens: 4096,
        timeout: 45.0
    )
}
