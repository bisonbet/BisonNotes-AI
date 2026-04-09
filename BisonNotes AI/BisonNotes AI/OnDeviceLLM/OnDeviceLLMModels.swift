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
    case qwen35
    case gemma3
    case lfm
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
        case .qwen35:
            return .qwen35(systemPrompt)
        case .gemma3:
            return .gemma3(systemPrompt)
        case .lfm:
            return .lfm(systemPrompt)
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
    public let penaltyLastN: Int32
    public let frequencyPenalty: Float
    public let presencePenalty: Float

    public init(
        temperature: Float = 0.7,
        topK: Int32 = 40,
        topP: Float = 0.95,
        minP: Float = 0.0,
        repeatPenalty: Float = 1.1,
        penaltyLastN: Int32 = 64,
        frequencyPenalty: Float = 0.0,
        presencePenalty: Float = 0.0
    ) {
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.minP = minP
        self.repeatPenalty = repeatPenalty
        self.penaltyLastN = penaltyLastN
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
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
    public let isRecommended: Bool // Whether this model is recommended for its RAM tier
    public let maker: String // The company/organization that created the model (e.g., "Google", "Mistral AI", "IBM")

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
        description: "Best overall quality • 4.5GB",
        filename: "gemma-3n-E4B-it-Q4_K_M",
        downloadURL: "https://huggingface.co/unsloth/gemma-3n-E4B-it-GGUF/resolve/main/gemma-3n-E4B-it-Q4_K_M.gguf?download=true",
        downloadSizeBytes: 4_540_000_000, // ~4.54 GB for Q4_K_M
        requiredRAM: 8.0,
        templateType: .gemma3,
        purpose: .summarization,
        contextWindow: 16384,
        defaultSettings: OnDeviceLLMDefaultSettings(
            temperature: 1.0,
            topK: 64,
            topP: 0.95,
            minP: 0.0,
            repeatPenalty: 1.1
        ),
        isRecommended: true,
        maker: "Google"
    )

    /// Gemma 3n E2B - Google's smaller efficient on-device model
    /// A compact 4-bit model optimized for devices with limited storage
    public static let gemma3nE2B = OnDeviceLLMModelInfo(
        id: "gemma-3n-e2b",
        displayName: "Gemma (Small)",
        description: "Good quality, smaller size • 3GB",
        filename: "gemma-3n-E2B-it-Q4_K_M",
        downloadURL: "https://huggingface.co/unsloth/gemma-3n-E2B-it-GGUF/resolve/main/gemma-3n-E2B-it-Q4_K_M.gguf?download=true",
        downloadSizeBytes: 3_030_000_000, // ~3.03 GB for Q4_K_M
        requiredRAM: 6.0,
        templateType: .gemma3,
        purpose: .summarization,
        contextWindow: 16384,
        defaultSettings: OnDeviceLLMDefaultSettings(
            temperature: 1.0,
            topK: 64,
            topP: 0.95,
            minP: 0.0,
            repeatPenalty: 1.1
        ),
        isRecommended: true,
        maker: "Google"
    )

    // MARK: - Experimental Models

    /// Ministral-3-3B-Instruct - Mistral AI's latest edge model
    /// A highly capable 3B model optimized for on-device use
    public static let ministral3B = OnDeviceLLMModelInfo(
        id: "ministral-3b",
        displayName: "Ministral",
        description: "Best for tasks and reminders • 2.1GB",
        filename: "Ministral-3-3B-Instruct-2512-Q4_K_M.gguf",
        downloadURL: "https://huggingface.co/unsloth/Ministral-3-3B-Instruct-2512-GGUF/resolve/main/Ministral-3-3B-Instruct-2512-Q4_K_M.gguf?download=true",
        downloadSizeBytes: 2_146_497_824, // Exact size for Q4_K_M
        requiredRAM: 6.0,
        templateType: .mistral,
        purpose: .summarization,
        contextWindow: 16384,
        defaultSettings: OnDeviceLLMDefaultSettings(
            temperature: 0.1,  // Low temp for non-reasoning tasks
            topK: 40,
            topP: 0.95,
            minP: 0.0,
            repeatPenalty: 1.1
        ),
        isRecommended: false,
        maker: "Mistral AI"
    )

    /// Granite 4.0 H Tiny - IBM's efficient on-device model
    /// A compact model optimized for edge devices with strong instruction following
    /// EXPERIMENTAL: Only available for 8GB+ devices when experimental models are enabled
    public static let granite4H = OnDeviceLLMModelInfo(
        id: "granite-4.0-h-tiny",
        displayName: "Granite",
        description: "Experimental • Reliable and accurate • 4.3GB",
        filename: "granite-4.0-h-tiny-Q4_K_M",
        downloadURL: "https://huggingface.co/unsloth/granite-4.0-h-tiny-GGUF/resolve/main/granite-4.0-h-tiny-Q4_K_M.gguf?download=true",
        downloadSizeBytes: 4_250_000_000, // ~4.25 GB for Q4_K_M
        requiredRAM: 8.0,
        templateType: .chatML,
        purpose: .summarization,
        contextWindow: 16384,
        defaultSettings: OnDeviceLLMDefaultSettings(
            temperature: 0.7,
            topK: 40,
            topP: 0.95,
            minP: 0.0,
            repeatPenalty: 1.1
        ),
        isRecommended: false,
        maker: "IBM"
    )

    /// LFM 2.5 1.2B Thinking - Liquid AI's ultra-compact edge model with chain-of-thought
    /// A highly efficient 1.2B model with thinking/reasoning for agentic tasks and data extraction
    /// EXPERIMENTAL: Only available for devices with 4-6GB RAM
    public static let lfm25 = OnDeviceLLMModelInfo(
        id: "lfm-2.5-1.2b",
        displayName: "LFM 2.5 Thinking",
        description: "Experimental • Thinking model, minimal summaries • 731MB • Summary only",
        filename: "LFM2.5-1.2B-Thinking-Q4_K_M",
        downloadURL: "https://huggingface.co/unsloth/LFM2.5-1.2B-Thinking-GGUF/resolve/main/LFM2.5-1.2B-Thinking-Q4_K_M.gguf?download=true",
        downloadSizeBytes: 731_000_000, // ~731 MB for Q4_K_M
        requiredRAM: 4.0,
        templateType: .lfm,
        purpose: .summarization,
        contextWindow: 16384,
        defaultSettings: OnDeviceLLMDefaultSettings(
            temperature: 0.5,
            topK: 50,
            topP: 0.85,
            minP: 0.0,
            repeatPenalty: 1.25,
            penaltyLastN: 256,  // Aggressive: look back 256 tokens for repetition
            frequencyPenalty: 0.15,  // Aggressive: penalize frequently appearing tokens
            presencePenalty: 0.05  // Aggressive: penalize tokens that have appeared
        ),
        isRecommended: false,
        maker: "Liquid AI"
    )

    /// Qwen3.5-2B - Alibaba's latest multimodal Qwen3.5 model (text-only mode)
    /// A 2B parameter model with strong summarization and instruction following
    /// Small models (0.8B-9B) have thinking mode DISABLED by default
    /// EXPERIMENTAL: Available for devices with 6GB+ RAM when experimental models are enabled
    public static let qwen3_5_2B = OnDeviceLLMModelInfo(
        id: "qwen3.5-2b",
        displayName: "Qwen3.5 2B",
        description: "Experimental • Latest Qwen3.5 model • 1.3GB • Summary only",
        filename: "Qwen3.5-2B-UD-Q4_K_XL",
        downloadURL: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-UD-Q4_K_XL.gguf?download=true",
        downloadSizeBytes: 1_340_000_000, // ~1.34 GB for UD-Q4_K_XL
        requiredRAM: 6.0,
        templateType: .qwen35,
        purpose: .summarization,
        contextWindow: 16384,
        defaultSettings: OnDeviceLLMDefaultSettings(
            // Qwen3.5 small models (0.8B-9B) Instruct Mode settings (thinking disabled by default):
            // temperature=0.7, top_p=0.8, top_k=20, presence_penalty=1.5, repetition_penalty=1.0
            temperature: 0.7,
            topK: 20,
            topP: 0.8,
            minP: 0.0,
            repeatPenalty: 1.0,
            penaltyLastN: 64,
            frequencyPenalty: 0.0,
            presencePenalty: 1.5
        ),
        isRecommended: false,
        maker: "Alibaba"
    )

    /// Qwen3.5-4B - Alibaba's larger multimodal Qwen3.5 model (text-only mode)
    /// A 4B parameter model with excellent detail extraction and summarization
    /// Small models (0.8B-9B) have thinking mode DISABLED by default
    /// EXPERIMENTAL: Only available for 8GB+ devices when experimental models are enabled
    public static let qwen3_5_4B = OnDeviceLLMModelInfo(
        id: "qwen3.5-4b",
        displayName: "Qwen3.5 4B",
        description: "Experimental • Excellent detail extraction • 2.7GB",
        filename: "Qwen3.5-4B-Q4_K_M",
        downloadURL: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf?download=true",
        downloadSizeBytes: 2_740_000_000, // ~2.74 GB for Q4_K_M
        requiredRAM: 8.0,
        templateType: .qwen35,
        purpose: .summarization,
        contextWindow: 16384,
        defaultSettings: OnDeviceLLMDefaultSettings(
            // Qwen3.5 small models (0.8B-9B) Instruct Mode settings (thinking disabled by default):
            // temperature=0.7, top_p=0.8, top_k=20, presence_penalty=1.5, repetition_penalty=1.0
            temperature: 0.7,
            topK: 20,
            topP: 0.8,
            minP: 0.0,
            repeatPenalty: 1.0,
            penaltyLastN: 64,
            frequencyPenalty: 0.0,
            presencePenalty: 1.5
        ),
        isRecommended: false,
        maker: "Alibaba"
    )

    /// Granite 4.0 Micro - IBM's compact 3B model with extended context
    /// A versatile 3B model with 128K context window for complex tasks
    /// Recommended for 6GB+ devices
    public static let granite4Micro = OnDeviceLLMModelInfo(
        id: "granite-4.0-micro",
        displayName: "Granite Micro",
        description: "Very fast processing speed • 2.1GB",
        filename: "granite-4.0-micro-Q4_K_M",
        downloadURL: "https://huggingface.co/unsloth/granite-4.0-micro-GGUF/resolve/main/granite-4.0-micro-Q4_K_M.gguf?download=true",
        downloadSizeBytes: 2_100_000_000, // ~2.1 GB for Q4_K_M
        requiredRAM: 6.0,
        templateType: .chatML,
        purpose: .summarization,
        contextWindow: 16384,
        defaultSettings: OnDeviceLLMDefaultSettings(
            temperature: 0.7,
            topK: 40,
            topP: 0.95,
            minP: 0.0,
            repeatPenalty: 1.1
        ),
        isRecommended: true,
        maker: "IBM"
    )

    // MARK: - All Available Models

    /// All models available for download
    /// Note: Qwen3.5 models are experimental
    public static let allModels: [OnDeviceLLMModelInfo] = [
        gemma3nE4B,
        gemma3nE2B,
        granite4H,
        granite4Micro,
        ministral3B,
        lfm25,
        qwen3_5_2B,
        qwen3_5_4B
    ]

    /// Models available for the current device based on RAM requirements
    /// RAM-based model availability:
    /// - 6GB+ but <8GB: Gemma Small (E2B, recommended), Ministral, Granite Micro (recommended)
    /// - 8GB+: Full Gemma (E4B, recommended), Granite Micro (recommended), Ministral
    /// NOTE: Experimental models are excluded unless explicitly enabled:
    ///   - Small experimental (LFM 2.5): Available for 4GB+ devices when enabled
    ///   - Medium experimental (Qwen3.5 2B): Available for 6GB+ devices when enabled
    ///   - Large experimental (Qwen3.5 4B, Granite H Tiny): Only available for 8GB+ devices when enabled
    /// For devices with <6GB RAM, only small experimental models are shown if enabled
    /// Models are sorted with recommended ones first
    public static var availableModels: [OnDeviceLLMModelInfo] {
        let deviceRAM = DeviceCapabilities.totalRAMInGB
        let experimentalEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.enableExperimentalModels)
        let smallExperimentalModels = ["lfm-2.5-1.2b"] // 4GB+
        let mediumExperimentalModels = ["qwen3.5-2b"] // 6GB+
        let largeExperimentalModels = ["qwen3.5-4b", "granite-4.0-h-tiny"] // 8GB+ only

        let filtered = allModels.filter { model in
            // Check basic RAM requirement
            guard deviceRAM >= model.requiredRAM else { return false }

            // For devices with <6GB RAM, only show small experimental models if enabled
            if deviceRAM < 6.0 {
                return smallExperimentalModels.contains(model.id) && experimentalEnabled
            }

            // For devices with 6GB+ but <8GB RAM:
            // Show: Gemma Small (E2B), Ministral, Granite Micro
            if deviceRAM >= 6.0 && deviceRAM < 8.0 {
                let allowedModels = ["gemma-3n-e2b", "ministral-3b", "granite-4.0-micro"]
                // Exclude experimental models unless enabled
                if smallExperimentalModels.contains(model.id) || mediumExperimentalModels.contains(model.id) {
                    return experimentalEnabled
                }
                // Large experimental models not available for <8GB
                if largeExperimentalModels.contains(model.id) {
                    return false
                }
                return allowedModels.contains(model.id)
            }

            // For devices with 8GB+ RAM:
            // Show: Full Gemma (E4B), Granite Micro, Ministral
            // Plus experimental models (Qwen 2B, Qwen 4B, Granite H Tiny) if enabled
            if deviceRAM >= 8.0 {
                let allowedModels = ["gemma-3n-e4b", "granite-4.0-micro", "ministral-3b"]
                // Check experimental models
                if smallExperimentalModels.contains(model.id) || mediumExperimentalModels.contains(model.id) {
                    return experimentalEnabled
                }
                if largeExperimentalModels.contains(model.id) {
                    return experimentalEnabled
                }
                return allowedModels.contains(model.id)
            }

            return false
        }
        
        // Sort: recommended models first, then by display name
        return filtered.sorted { first, second in
            if first.isRecommended != second.isRecommended {
                return first.isRecommended
            }
            return first.displayName < second.displayName
        }
    }
    
    /// Check if experimental models are enabled
    public static var experimentalModelsEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKeys.enableExperimentalModels)
    }

    /// Models optimized for summarization
    public static var summarizationModels: [OnDeviceLLMModelInfo] {
        allModels.filter { $0.purpose == .summarization }
    }

    /// Available summarization models for the current device
    public static var availableSummarizationModels: [OnDeviceLLMModelInfo] {
        availableModels.filter { $0.purpose == .summarization }
    }

    /// Default model for summarization tasks
    /// Returns the recommended model based on RAM:
    /// - 8GB+: Gemma (E4B) - recommended
    /// - 6GB+ but <8GB: Gemma Small (E2B) - recommended
    /// Never returns experimental models due to reliability issues
    public static var defaultSummarizationModel: OnDeviceLLMModelInfo {
        let deviceRAM = DeviceCapabilities.totalRAMInGB

        // For devices with 8GB+ RAM: default to Gemma (E4B) (recommended)
        if deviceRAM >= 8.0 {
            if deviceRAM >= gemma3nE4B.requiredRAM {
                return gemma3nE4B
            }
        }

        // For devices with 6GB+ but <8GB: default to Gemma Small (E2B) (recommended)
        if deviceRAM >= 6.0 {
            if deviceRAM >= gemma3nE2B.requiredRAM {
                return gemma3nE2B
            }
        }

        // Fallback to first available model (which excludes experimental models)
        return availableModels.first ?? gemma3nE2B
    }

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
        static let enableExperimentalModels = "onDeviceLLMEnableExperimentalModels"
    }

    /// Get the currently selected model from UserDefaults
    /// Automatically migrates users away from unavailable models
    /// Note: Qwen3.5 models (2B, 4B) are experimental
    public static var selectedModel: OnDeviceLLMModelInfo {
        let modelId = UserDefaults.standard.string(forKey: SettingsKeys.selectedModelId) ?? defaultSummarizationModel.id
        
        // If the selected model is not in availableModels, migrate to default
        if let selected = model(withId: modelId) {
            if !availableModels.contains(where: { $0.id == selected.id }) {
                // Only log migration once per model to prevent spam
                let migrationKey = "migrated_unavailable_\(modelId)"
                if !UserDefaults.standard.bool(forKey: migrationKey) {
                    AppLog.shared.summarization("[OnDeviceLLMModelInfo] Selected model '\(modelId)' is not available, migrating to default")
                    UserDefaults.standard.set(true, forKey: migrationKey)
                }
                let betterModel = defaultSummarizationModel
                UserDefaults.standard.set(betterModel.id, forKey: SettingsKeys.selectedModelId)
                return betterModel
            }
            return selected
        }
        
        return defaultSummarizationModel
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
    /// Note: Context size is automatically determined by device RAM (8k for <8GB, 16k for >=8GB)
    /// This setting is kept for backward compatibility but is not used for context size configuration
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
