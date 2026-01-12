//
//  WhisperKitModelInfo.swift
//  BisonNotes AI
//
//  WhisperKit model definitions for on-device transcription
//

import Foundation

// MARK: - WhisperKit Model Info

/// Represents a WhisperKit model available for download
public struct WhisperKitModelInfo: Identifiable, Equatable, Codable {
    public let id: String
    public let displayName: String
    public let description: String
    public let modelName: String  // WhisperKit model identifier
    public let downloadSizeBytes: Int64
    public let requiredRAM: Double // Minimum RAM in GB

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
}

// MARK: - Predefined Models

extension WhisperKitModelInfo {

    /// Medium model - higher quality transcription
    public static let medium = WhisperKitModelInfo(
        id: "medium",
        displayName: "Higher Quality",
        description: "Best accuracy and quality. Takes longer to process but produces more accurate transcriptions.",
        modelName: "medium",
        downloadSizeBytes: 520_000_000, // ~520 MB
        requiredRAM: 2.0
    )

    /// Small model - faster processing
    public static let small = WhisperKitModelInfo(
        id: "small",
        displayName: "Faster Processing",
        description: "Faster transcription with good quality. Ideal for quick transcriptions with slightly lower accuracy.",
        modelName: "small",
        downloadSizeBytes: 150_000_000, // ~150 MB
        requiredRAM: 1.0
    )

    /// Default model for transcription
    public static let defaultModel = small

    /// All available models
    public static let allModels: [WhisperKitModelInfo] = [
        medium,
        small
    ]

    /// Find a model by its ID
    public static func model(withId id: String) -> WhisperKitModelInfo? {
        allModels.first { $0.id == id }
    }
}

// MARK: - UserDefaults Keys

extension WhisperKitModelInfo {

    public struct SettingsKeys {
        public static let enableWhisperKit = "enableWhisperKit"
        public static let selectedModelId = "whisperKitSelectedModel"
        public static let modelDownloaded = "whisperKitModelDownloaded"
        public static let modelPath = "whisperKitModelPath"
    }

    /// Get the currently selected model from UserDefaults
    public static var selectedModel: WhisperKitModelInfo {
        let modelId = UserDefaults.standard.string(forKey: SettingsKeys.selectedModelId) ?? defaultModel.id
        return model(withId: modelId) ?? defaultModel
    }

    /// Check if WhisperKit is enabled
    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKeys.enableWhisperKit)
    }

    /// Check if the model has been downloaded
    public static var isModelDownloaded: Bool {
        UserDefaults.standard.bool(forKey: SettingsKeys.modelDownloaded)
    }
}

// MARK: - WhisperKit Models Directory

extension URL {

    /// Directory where WhisperKit models are stored
    /// WhisperKit manages its own model storage, but we track status
    public static var whisperKitModelsDirectory: URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let url = paths[0].appendingPathComponent("WhisperKitModels")

        // Create directory if it doesn't exist
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        // Exclude from iCloud backup
        var mutableURL = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(resourceValues)

        return url
    }
}
