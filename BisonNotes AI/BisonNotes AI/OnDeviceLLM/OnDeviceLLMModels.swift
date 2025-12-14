//
//  OnDeviceLLMModels.swift
//  BisonNotes AI
//
//  On-device LLM model definitions for local inference using LocalLLMClient
//

import Foundation

// MARK: - Model Quantization

/// Available quantization levels for GGUF models
/// Lower quantization = smaller size but lower quality
/// Higher quantization = larger size but better quality
enum OnDeviceLLMQuantization: String, CaseIterable, Identifiable, Codable {
    case q4_K_M = "Q4_K_M"  // Recommended for iPhone - good balance
    case q5_K_M = "Q5_K_M"  // Higher quality, more RAM
    case q8_0 = "Q8_0"      // Best quality, most RAM

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .q4_K_M: return "Q4_K_M (Recommended)"
        case .q5_K_M: return "Q5_K_M (Higher Quality)"
        case .q8_0: return "Q8_0 (Best Quality)"
        }
    }

    var description: String {
        switch self {
        case .q4_K_M: return "Best balance of quality and performance for iPhone"
        case .q5_K_M: return "Better quality, requires more memory"
        case .q8_0: return "Highest quality, requires significant memory"
        }
    }
}

// MARK: - Model Definition

/// Represents an on-device LLM model available for download
struct OnDeviceLLMModel: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let displayName: String
    let description: String
    let huggingFaceRepo: String
    let parameters: String
    let contextWindow: Int
    let quantizations: [OnDeviceLLMQuantization]
    let defaultQuantization: OnDeviceLLMQuantization
    let specialization: ModelSpecialization
    let promptTemplate: PromptTemplate

    enum ModelSpecialization: String, Codable {
        case general
        case reasoning
        case coding
        case conversation
    }

    enum PromptTemplate: String, Codable {
        case mistral
        case granite
        case llama
        case chatml
    }

    /// Generate the filename for a specific quantization
    func filename(for quantization: OnDeviceLLMQuantization) -> String {
        return "\(id)-\(quantization.rawValue).gguf"
    }

    /// Generate the Hugging Face download URL for a specific quantization
    func downloadURL(for quantization: OnDeviceLLMQuantization) -> URL? {
        let filename = huggingFaceFilename(for: quantization)
        return URL(string: "https://huggingface.co/\(huggingFaceRepo)/resolve/main/\(filename)")
    }

    /// Get the correct filename format from the Hugging Face repo
    func huggingFaceFilename(for quantization: OnDeviceLLMQuantization) -> String {
        return "\(name)-\(quantization.rawValue).gguf"
    }
}

// MARK: - Available Models

extension OnDeviceLLMModel {
    /// Ministral 3B Reasoning - Mistral's reasoning-optimized model
    static let ministral3BReasoning = OnDeviceLLMModel(
        id: "ministral-3b-reasoning",
        name: "Ministral-3-3B-Reasoning-2512",
        displayName: "Ministral 3B Reasoning",
        description: "Mistral's reasoning-optimized 3B model with 256K context window. Excellent for complex analysis, summarization, and logical reasoning tasks.",
        huggingFaceRepo: "unsloth/Ministral-3-3B-Reasoning-2512-GGUF",
        parameters: "3B",
        contextWindow: 32768, // Using practical limit for mobile
        quantizations: [.q4_K_M, .q5_K_M, .q8_0],
        defaultQuantization: .q4_K_M,
        specialization: .reasoning,
        promptTemplate: .mistral
    )

    /// Granite 4.0 Hybrid Micro - IBM's efficient hybrid model
    static let granite4Micro = OnDeviceLLMModel(
        id: "granite-4-micro",
        name: "granite-4.0-h-micro",
        displayName: "Granite 4.0 Micro",
        description: "IBM's efficient hybrid transformer model with Mamba2 architecture. 128K context, optimized for fast inference on mobile devices.",
        huggingFaceRepo: "unsloth/granite-4.0-h-micro-GGUF",
        parameters: "3B",
        contextWindow: 32768, // Using practical limit for mobile
        quantizations: [.q4_K_M, .q5_K_M, .q8_0],
        defaultQuantization: .q4_K_M,
        specialization: .general,
        promptTemplate: .granite
    )

    /// All available models
    static let allModels: [OnDeviceLLMModel] = [
        .ministral3BReasoning,
        .granite4Micro
    ]

    /// Get model by ID
    static func model(byID id: String) -> OnDeviceLLMModel? {
        return allModels.first { $0.id == id }
    }

    /// Default model
    static let defaultModel = ministral3BReasoning
}

// MARK: - Downloaded Model Info

/// Represents a downloaded model stored on device
struct DownloadedModel: Identifiable, Codable {
    let id: String
    let modelID: String
    let quantization: OnDeviceLLMQuantization
    let filePath: String
    let fileSize: Int64
    let downloadedAt: Date

    var model: OnDeviceLLMModel? {
        OnDeviceLLMModel.model(byID: modelID)
    }

    var displayName: String {
        guard let model = model else { return modelID }
        return "\(model.displayName) (\(quantization.rawValue))"
    }

    var fileSizeFormatted: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }
}

// MARK: - Download State

/// Tracks the download state of a model
enum ModelDownloadState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded(model: DownloadedModel)
    case failed(error: String)
    case paused(progress: Double)

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    var isDownloaded: Bool {
        if case .downloaded = self { return true }
        return false
    }

    var progress: Double? {
        switch self {
        case .downloading(let progress), .paused(let progress):
            return progress
        default:
            return nil
        }
    }
}

// MARK: - Configuration

/// Configuration for on-device LLM inference
struct OnDeviceLLMConfig: Equatable {
    var modelID: String
    var quantization: OnDeviceLLMQuantization
    var temperature: Double
    var maxTokens: Int
    var contextWindow: Int
    var allowCellularDownload: Bool

    static let `default` = OnDeviceLLMConfig(
        modelID: OnDeviceLLMModel.defaultModel.id,
        quantization: .q4_K_M,
        temperature: 0.1,
        maxTokens: 2048,
        contextWindow: 32768,
        allowCellularDownload: false
    )

    /// Load configuration from UserDefaults
    static func load() -> OnDeviceLLMConfig {
        let defaults = UserDefaults.standard

        return OnDeviceLLMConfig(
            modelID: defaults.string(forKey: "onDeviceLLMModelID") ?? OnDeviceLLMModel.defaultModel.id,
            quantization: OnDeviceLLMQuantization(rawValue: defaults.string(forKey: "onDeviceLLMQuantization") ?? "Q4_K_M") ?? .q4_K_M,
            temperature: defaults.object(forKey: "onDeviceLLMTemperature") as? Double ?? 0.1,
            maxTokens: defaults.object(forKey: "onDeviceLLMMaxTokens") as? Int ?? 2048,
            contextWindow: defaults.object(forKey: "onDeviceLLMContextWindow") as? Int ?? 32768,
            allowCellularDownload: defaults.bool(forKey: "onDeviceLLMAllowCellular")
        )
    }

    /// Save configuration to UserDefaults
    func save() {
        let defaults = UserDefaults.standard
        defaults.set(modelID, forKey: "onDeviceLLMModelID")
        defaults.set(quantization.rawValue, forKey: "onDeviceLLMQuantization")
        defaults.set(temperature, forKey: "onDeviceLLMTemperature")
        defaults.set(maxTokens, forKey: "onDeviceLLMMaxTokens")
        defaults.set(contextWindow, forKey: "onDeviceLLMContextWindow")
        defaults.set(allowCellularDownload, forKey: "onDeviceLLMAllowCellular")
        defaults.synchronize()
    }
}

// MARK: - UserDefaults Keys

struct OnDeviceLLMSettingsKeys {
    static let enableOnDeviceLLM = "enableOnDeviceLLM"
    static let modelID = "onDeviceLLMModelID"
    static let quantization = "onDeviceLLMQuantization"
    static let temperature = "onDeviceLLMTemperature"
    static let maxTokens = "onDeviceLLMMaxTokens"
    static let contextWindow = "onDeviceLLMContextWindow"
    static let allowCellularDownload = "onDeviceLLMAllowCellular"
    static let downloadedModels = "onDeviceLLMDownloadedModels"

    struct Defaults {
        static let modelID = OnDeviceLLMModel.defaultModel.id
        static let quantization = OnDeviceLLMQuantization.q4_K_M
        static let temperature = 0.1
        static let maxTokens = 2048
        static let contextWindow = 32768
        static let allowCellularDownload = false
    }
}

// MARK: - Errors

enum OnDeviceLLMError: LocalizedError {
    case modelNotDownloaded
    case modelNotFound(String)
    case downloadFailed(String)
    case downloadCancelled
    case cellularNotAllowed
    case insufficientStorage(required: Int64, available: Int64)
    case inferenceError(String)
    case modelLoadFailed(String)
    case contextTooLong(Int, max: Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded:
            return "Model not downloaded. Please download a model first."
        case .modelNotFound(let id):
            return "Model '\(id)' not found."
        case .downloadFailed(let reason):
            return "Download failed: \(reason)"
        case .downloadCancelled:
            return "Download was cancelled."
        case .cellularNotAllowed:
            return "Cellular download not allowed. Connect to WiFi or enable cellular downloads in settings."
        case .insufficientStorage(let required, let available):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "Insufficient storage. Required: \(formatter.string(fromByteCount: required)), Available: \(formatter.string(fromByteCount: available))"
        case .inferenceError(let reason):
            return "Inference failed: \(reason)"
        case .modelLoadFailed(let reason):
            return "Failed to load model: \(reason)"
        case .contextTooLong(let length, let max):
            return "Input too long (\(length) tokens). Maximum is \(max) tokens."
        case .invalidResponse:
            return "Invalid response from model."
        }
    }
}
