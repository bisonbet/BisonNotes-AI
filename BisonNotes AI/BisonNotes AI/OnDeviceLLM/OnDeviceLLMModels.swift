//
//  OnDeviceLLMModels.swift
//  BisonNotes AI
//
//  On-device LLM model definitions for local inference using LocalLLMClient
//

import Foundation

// MARK: - Model Quantization

/// Available quantization levels for GGUF models
/// BisonNotes AI only supports Q4_K_M for optimal balance of quality and memory usage
enum OnDeviceLLMQuantization: String, CaseIterable, Identifiable, Codable {
    case q4_K_M = "Q4_K_M"  // Only supported quantization - good balance of quality and memory

    var id: String { rawValue }

    var displayName: String {
        return "Q4_K_M (Standard)"
    }

    var description: String {
        return "Optimized for devices with 6GB+ RAM"
    }

    /// Estimated download size in gigabytes
    /// Q4_K_M models range from 1-2GB depending on parameter count
    var estimatedSizeGB: Double {
        return 1.5  // ~2 GB for 3B models, ~1 GB for 1.7B models
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

    /// SHA256 checksums for integrity verification
    /// Note: These should be obtained from the official model repository
    /// Currently placeholder values - update with actual checksums before production
    let checksums: [OnDeviceLLMQuantization: String]?

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

    /// Estimated model file size in GB (Q4_K_M quantization)
    var estimatedSizeGB: Double {
        switch id {
        case "qwen3-1.7b": return 1.0
        case "ministral-3b-reasoning", "granite-4-micro": return 2.0
        default: return 1.5
        }
    }

    /// Inference speed rating (1-5, higher is faster)
    var speedRating: Int {
        switch id {
        case "qwen3-1.7b": return 5  // Fastest - smallest model
        case "granite-4-micro": return 3  // Medium - hybrid architecture
        case "ministral-3b-reasoning": return 3  // Medium - standard 3B
        default: return 3
        }
    }

    /// Accuracy/Quality rating (1-5, higher is better)
    var qualityRating: Int {
        switch id {
        case "ministral-3b-reasoning": return 5  // Highest - reasoning optimized
        case "granite-4-micro": return 4  // High - hybrid architecture
        case "qwen3-1.7b": return 3  // Good - compact model
        default: return 3
        }
    }

    /// Memory usage during inference (approximate)
    var memoryUsageGB: Double {
        return estimatedSizeGB * 1.5  // Model file + overhead
    }

    /// Get pros for this model
    var pros: [String] {
        switch id {
        case "ministral-3b-reasoning":
            return [
                "Best quality and reasoning",
                "256K context window",
                "Excellent for complex analysis"
            ]
        case "granite-4-micro":
            return [
                "Hybrid Mamba2 architecture",
                "Fast inference speed",
                "Good balance of quality/speed"
            ]
        case "qwen3-1.7b":
            return [
                "Smallest size (~1GB)",
                "Fastest inference",
                "Lower memory usage"
            ]
        default:
            return []
        }
    }

    /// Get cons for this model
    var cons: [String] {
        switch id {
        case "ministral-3b-reasoning":
            return [
                "Larger size (~2GB)",
                "Slower inference",
                "Higher memory usage"
            ]
        case "granite-4-micro":
            return [
                "Larger size (~2GB)",
                "Medium quality vs Ministral"
            ]
        case "qwen3-1.7b":
            return [
                "Lower quality than 3B models",
                "32K context (vs 128K-256K)"
            ]
        default:
            return []
        }
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
        quantizations: [.q4_K_M],
        defaultQuantization: .q4_K_M,
        specialization: .reasoning,
        promptTemplate: .mistral,
        checksums: nil // TODO: Add actual SHA256 checksums from Hugging Face
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
        quantizations: [.q4_K_M],
        defaultQuantization: .q4_K_M,
        specialization: .general,
        promptTemplate: .granite,
        checksums: nil // TODO: Add actual SHA256 checksums from Hugging Face
    )

    /// Qwen3-1.7B - Compact and efficient model
    /// Smaller 1.7B model optimized for devices with 6GB RAM
    static let qwen3_1_7B = OnDeviceLLMModel(
        id: "qwen3-1.7b",
        name: "Qwen3-1.7B",
        displayName: "Qwen3 1.7B",
        description: "Compact and efficient 1.7B model. Smaller footprint (~1GB), faster inference, ideal for devices with 6GB RAM. Good for quick summaries and general tasks.",
        huggingFaceRepo: "unsloth/Qwen3-1.7B-GGUF",
        parameters: "1.7B",
        contextWindow: 32768,
        quantizations: [.q4_K_M],
        defaultQuantization: .q4_K_M,
        specialization: .general,
        promptTemplate: .chatml,
        checksums: nil // TODO: Add actual SHA256 checksums from Hugging Face
    )

    /// All available models
    static let allModels: [OnDeviceLLMModel] = [
        .ministral3BReasoning,
        .granite4Micro,
        .qwen3_1_7B
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
    case insufficientMemory(required: Int64, available: Int64)
    case inferenceError(String)
    case modelLoadFailed(String)
    case contextTooLong(Int, max: Int)
    case invalidResponse
    case checksumMismatch
    case modelTooLarge(Int64)

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
        case .insufficientMemory(let required, let available):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "Insufficient device memory. Your device has \(formatter.string(fromByteCount: available)) RAM. On-device LLM requires at least 6GB RAM. Please use a newer device."
        case .inferenceError:
            return "Model inference failed. Please try again."
        case .modelLoadFailed:
            return "Failed to load model. Please try again or select a different model."
        case .contextTooLong(let length, let max):
            return "Input too long (\(length) tokens). Maximum is \(max) tokens."
        case .invalidResponse:
            return "Invalid response from model."
        case .checksumMismatch:
            return "Model file integrity check failed. Please delete and re-download the model."
        case .modelTooLarge(let size):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "Model file too large (\(formatter.string(fromByteCount: size))). Maximum supported size is 5GB."
        }
    }
}
