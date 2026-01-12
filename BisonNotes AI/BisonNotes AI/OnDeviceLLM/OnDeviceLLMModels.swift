//
//  OnDeviceLLMModels.swift
//  BisonNotes AI
//
//  Predefined on-device LLM models available for download
//

import Foundation

// MARK: - Model Template Type

/// Supported template types for different model architectures
public enum OnDeviceLLMTemplateType: String, Codable, CaseIterable {
    case chatML
    case phi3
    case llama
    case llama3
    case mistral
    case alpaca
    case olmoe
    case qwen
    case qwen3
    case gemma3
    case simple

    /// Get the LLMTemplate for this type
    public func template(systemPrompt: String?) -> LLMTemplate {
        switch self {
        case .chatML:
            return .chatML(systemPrompt)
        case .phi3:
            return .phi3(systemPrompt)
        case .llama:
            return .llama(systemPrompt)
        case .llama3:
            return .llama3(systemPrompt)
        case .mistral:
            return .mistral
        case .alpaca:
            return .alpaca(systemPrompt)
        case .olmoe:
            return .olmoe(systemPrompt)
        case .qwen:
            return .qwen(systemPrompt)
        case .qwen3:
            return .qwen3(systemPrompt)
        case .gemma3:
            return .gemma3(systemPrompt)
        case .simple:
            return .simple(systemPrompt)
        }
    }
}

// MARK: - Model Purpose

/// The intended use case for a model
public enum OnDeviceLLMModelPurpose: String, Codable {
    case summarization
    case transcriptProcessing
    case generalPurpose
}

// MARK: - Default Model Settings

/// Default sampling parameters for a model
public struct OnDeviceLLMDefaultSettings: Equatable, Codable {
    public let temperature: Float
    public let topK: Int32
    public let topP: Float
    public let minP: Float
    public let repeatPenalty: Float

    public init(
        temperature: Float = 0.7,
        topK: Int32 = 40,
        topP: Float = 0.95,
        minP: Float = 0.0,
        repeatPenalty: Float = 1.1
    ) {
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.minP = minP
        self.repeatPenalty = repeatPenalty
    }
}

// MARK: - Model Info Structure

/// Represents a downloadable on-device LLM model
public struct OnDeviceLLMModelInfo: Identifiable, Equatable, Codable {
    public let id: String
    public let displayName: String
    public let description: String
    public let filename: String
    public let downloadURL: String
    public let downloadSizeBytes: Int64
    public let requiredRAM: Double // Minimum RAM in GB required to run this model
    public let templateType: OnDeviceLLMTemplateType
    public let purpose: OnDeviceLLMModelPurpose
    public let contextWindow: Int
    public let defaultSettings: OnDeviceLLMDefaultSettings

    /// Human-readable download size
    public var downloadSize: String {
        let sizeInGB = Double(downloadSizeBytes) / 1_000_000_000.0
        if sizeInGB >= 1.0 {
            return String(format: "%.2f GB", sizeInGB)
        } else {
            let sizeInMB = Double(downloadSizeBytes) / 1_000_000.0
            return String(format: "%.0f MB", sizeInMB)
        }
    }

    /// URL where the model file is stored locally
    public var fileURL: URL {
        URL.onDeviceLLMModelsDirectory.appendingPathComponent(filename).appendingPathExtension("gguf")
    }

    /// Check if this model is already downloaded
    public var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Get the file size of the downloaded model (if available)
    public var downloadedFileSize: Int64? {
        guard isDownloaded else { return nil }
        return fileURL.fileSize
    }

    /// Validate that the downloaded file is complete
    public var isDownloadComplete: Bool {
        guard let actualSize = downloadedFileSize else { return false }
        // Allow 1% tolerance for file size differences
        let tolerance = Int64(Double(downloadSizeBytes) * 0.01)
        return abs(actualSize - downloadSizeBytes) <= tolerance
    }
}

// MARK: - Predefined Models

extension OnDeviceLLMModelInfo {

    // MARK: - Summarization Models

    /// Gemma 3n E4B - Google's efficient on-device model
    /// A compact 4-bit model optimized for edge devices
    public static let gemma3nE4B = OnDeviceLLMModelInfo(
        id: "gemma-3n-e4b",
        displayName: "Gemma",
        description: "from Google • Balanced quality and speed",
        filename: "gemma-3n-E4B-it-Q4_K_M",
        downloadURL: "https://huggingface.co/unsloth/gemma-3n-E4B-it-GGUF/resolve/main/gemma-3n-E4B-it-Q4_K_M.gguf?download=true",
        downloadSizeBytes: 3_090_000_000, // ~3.09 GB for Q4_K_M
        requiredRAM: 6.0,
        templateType: .gemma3,
        purpose: .summarization,
        contextWindow: 32768,
        defaultSettings: OnDeviceLLMDefaultSettings(
            temperature: 1.0,
            topK: 64,
            topP: 0.95,
            minP: 0.0,
            repeatPenalty: 1.1
        )
    )

    /// Qwen3 4B Instruct - Alibaba's instruction-tuned model
    /// A capable 4B parameter model with strong summarization abilities
    public static let qwen3_4B = OnDeviceLLMModelInfo(
        id: "qwen3-4b",
        displayName: "Qwen",
        description: "from Alibaba • Excellent for detailed summaries",
        filename: "Qwen3-4B-Instruct-2507-Q4_K_M",
        downloadURL: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf?download=true",
        downloadSizeBytes: 2_720_000_000, // ~2.72 GB for Q4_K_M
        requiredRAM: 6.0,
        templateType: .qwen3,
        purpose: .summarization,
        contextWindow: 32768,
        defaultSettings: OnDeviceLLMDefaultSettings(
            temperature: 0.7,
            topK: 20,
            topP: 0.80,
            minP: 0.0,
            repeatPenalty: 1.1
        )
    )

    /// Ministral-3-3B-Instruct - Mistral AI's latest edge model
    /// A highly capable 3B model optimized for on-device use
    public static let ministral3B = OnDeviceLLMModelInfo(
        id: "ministral-3b",
        displayName: "Ministral",
        description: "from Mistral AI • Superior task extraction",
        filename: "Ministral-3-3B-Instruct-2512-Q4_K_M.gguf",
        downloadURL: "https://huggingface.co/unsloth/Ministral-3-3B-Instruct-2512-GGUF/resolve/main/Ministral-3-3B-Instruct-2512-Q4_K_M.gguf?download=true",
        downloadSizeBytes: 2_146_497_824, // Exact size for Q4_K_M
        requiredRAM: 6.0,
        templateType: .mistral,
        purpose: .summarization,
        contextWindow: 32768,
        defaultSettings: OnDeviceLLMDefaultSettings(
            temperature: 0.7,
            topK: 40,
            topP: 0.95,
            minP: 0.0,
            repeatPenalty: 1.1
        )
    )

    // MARK: - All Available Models

    /// All models available for download
    public static let allModels: [OnDeviceLLMModelInfo] = [
        gemma3nE4B,
        qwen3_4B,
        ministral3B
    ]

    /// Models optimized for summarization
    public static var summarizationModels: [OnDeviceLLMModelInfo] {
        allModels.filter { $0.purpose == .summarization }
    }

    /// Default model for summarization tasks
    public static let defaultSummarizationModel = gemma3nE4B

    /// Find a model by its ID
    public static func model(withId id: String) -> OnDeviceLLMModelInfo? {
        allModels.first { $0.id == id }
    }
}

// MARK: - UserDefaults Keys

extension OnDeviceLLMModelInfo {

    struct SettingsKeys {
        static let enableOnDeviceLLM = "enableOnDeviceLLM"
        static let selectedModelId = "onDeviceLLMSelectedModel"
        static let temperature = "onDeviceLLMTemperature"
        static let maxTokens = "onDeviceLLMMaxTokens"
        static let topK = "onDeviceLLMTopK"
        static let topP = "onDeviceLLMTopP"
        static let minP = "onDeviceLLMMinP"
        static let repeatPenalty = "onDeviceLLMRepeatPenalty"
    }

    /// Get the currently selected model from UserDefaults
    public static var selectedModel: OnDeviceLLMModelInfo {
        let modelId = UserDefaults.standard.string(forKey: SettingsKeys.selectedModelId) ?? defaultSummarizationModel.id
        return model(withId: modelId) ?? defaultSummarizationModel
    }

    /// Check if on-device LLM is enabled
    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKeys.enableOnDeviceLLM)
    }

    /// Get the configured temperature (or use model default)
    public static var configuredTemperature: Float {
        let temp = UserDefaults.standard.float(forKey: SettingsKeys.temperature)
        return temp > 0 ? temp : selectedModel.defaultSettings.temperature
    }

    /// Get the configured max tokens
    /// Default to 16K to allow processing longer transcripts while reserving space for output
    public static var configuredMaxTokens: Int {
        let tokens = UserDefaults.standard.integer(forKey: SettingsKeys.maxTokens)
        return tokens > 0 ? tokens : 16384
    }

    /// Get sampling parameters
    public static var configuredTopK: Int32 {
        let topK = UserDefaults.standard.integer(forKey: SettingsKeys.topK)
        return topK > 0 ? Int32(topK) : selectedModel.defaultSettings.topK
    }

    public static var configuredTopP: Float {
        let topP = UserDefaults.standard.float(forKey: SettingsKeys.topP)
        return topP > 0 ? topP : selectedModel.defaultSettings.topP
    }

    public static var configuredMinP: Float {
        // minP can legitimately be 0, so we use a sentinel value
        let minP = UserDefaults.standard.object(forKey: SettingsKeys.minP) as? Float
        return minP ?? selectedModel.defaultSettings.minP
    }

    public static var configuredRepeatPenalty: Float {
        let penalty = UserDefaults.standard.float(forKey: SettingsKeys.repeatPenalty)
        return penalty > 0 ? penalty : selectedModel.defaultSettings.repeatPenalty
    }

    /// Apply default settings for a model to UserDefaults
    public static func applyDefaultSettings(for model: OnDeviceLLMModelInfo) {
        let defaults = model.defaultSettings
        UserDefaults.standard.set(defaults.temperature, forKey: SettingsKeys.temperature)
        UserDefaults.standard.set(Int(defaults.topK), forKey: SettingsKeys.topK)
        UserDefaults.standard.set(defaults.topP, forKey: SettingsKeys.topP)
        UserDefaults.standard.set(defaults.minP, forKey: SettingsKeys.minP)
        UserDefaults.standard.set(defaults.repeatPenalty, forKey: SettingsKeys.repeatPenalty)
    }
}
