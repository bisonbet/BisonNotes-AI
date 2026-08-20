//
//  LegacyLlamaMigration.swift
//  BisonNotes AI
//
//  Compatibility-only data for removing the legacy llama.cpp engine.
//

import Foundation

/// Compatibility rules used once when an installation still contains the
/// removed llama.cpp engine or one of its GGUF models. This type intentionally
/// has no dependency on the deleted engine implementation so the migration
/// remains available after the framework and legacy source are removed.
enum LegacyLlamaMigration {
    static let legacySelectedModelKey = "onDeviceLLMSelectedModel"

    static let legacySettingsKeys: Set<String> = [
        "enableOnDeviceLLM",
        legacySelectedModelKey,
        "onDeviceLLMEnableExperimentalModels",
        "onDeviceLLMTemperature",
        "onDeviceLLMMaxTokens",
        "onDeviceLLMTopK",
        "onDeviceLLMTopP",
        "onDeviceLLMMinP",
        "onDeviceLLMRepeatPenalty",
        "currentlyDownloadingModelId"
    ]

    private static let legacyMigrationKeys: Set<String> = [
        "onDeviceLLMNameMigration_v1.5",
        "legacyOnDeviceSubSixGBMigration_v2.0"
    ]

    private static let legacyMigrationKeyPrefixes = [
        "migrated_unavailable_"
    ]

    static let legacyModelDirectoryName = "OnDeviceLLMModels"

    /// Basenames used by the current v2.3 catalog and by earlier catalogs that
    /// shipped models later removed or renamed. The cleanup only removes these
    /// known model names; it never deletes arbitrary files from Application
    /// Support.
    static let legacyModelFileBaseNames: [String] = [
        "LFM2.5-1.2B-Instruct-Q4_K_M",
        "LFM2.5-1.2B-Thinking-Q4_K_M",
        "Qwen3-1.7B-Q4_K_M",
        "Qwen3-4B-Instruct-2507-Q4_K_M",
        "Phi-4-mini-instruct-Q4_K_M",
        "gemma-3n-E4B-it-Q4_K_M",
        "gemma-3n-E2B-it-Q4_K_M",
        "Ministral-3-3B-Instruct-2512-Q4_K_M",
        "granite-4.0-h-tiny-Q4_K_M",
        "Qwen3.5-2B-UD-Q4_K_XL",
        "Qwen3.5-4B-Q4_K_M",
        "granite-4.0-micro-Q4_K_M"
    ]

    static let legacyModelFileNames: Set<String> = Set(
        legacyModelFileBaseNames.flatMap { [$0, "\($0).gguf"] }
            + ["Ministral-3-3B-Instruct-2512-Q4_K_M.gguf.gguf"]
    )

    private enum DestinationTier {
        case small
        case medium
        case large
    }

    private static let legacyEngineIdentifiers: Set<String> = [
        "on-device ai",
        "on-device llm",
        "on device ai",
        "on device llm",
        "on-device ai (legacy)",
        "on device ai (legacy)",
        "on-device ai legacy",
        "on device ai legacy"
    ]

    /// Returns true for persisted engine names used by the removed llama.cpp
    /// engine, including the names written by older app versions.
    static func isLegacyEngineIdentifier(_ rawValue: String?) -> Bool {
        guard let rawValue else { return false }
        return legacyEngineIdentifiers.contains(rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Maps a legacy model to the closest MLX model and clamps the result to
    /// the device's supported RAM tier. Unknown or missing legacy IDs use the
    /// normal MLX default for the device.
    static func mlxModelID(forLegacyModelID legacyModelID: String?, ramGB: Double) -> String? {
        guard ramGB >= 4.0 else { return nil }

        let preferredTier = destinationTier(for: legacyModelID)
        switch preferredTier {
        case .small:
            return MLXSwiftSettingsKeys.smallModelId
        case .medium:
            return ramGB >= 6.0
                ? MLXSwiftSettingsKeys.defaultModelId
                : MLXSwiftSettingsKeys.smallModelId
        case .large:
            if ramGB >= 8.0 {
                return MLXSwiftSettingsKeys.largeModelId
            }
            if ramGB >= 6.0 {
                return MLXSwiftSettingsKeys.defaultModelId
            }
            return MLXSwiftSettingsKeys.smallModelId
        }
    }

    static func defaultMLXModelID(ramGB: Double) -> String? {
        mlxModelID(forLegacyModelID: nil, ramGB: ramGB)
    }

    @discardableResult
    static func clearLegacySettings(from defaults: UserDefaults = .standard) -> [String] {
        var removedKeys: [String] = []
        let obsoleteKeys = defaults.dictionaryRepresentation().keys.filter { key in
            legacySettingsKeys.contains(key)
                || legacyMigrationKeys.contains(key)
                || legacyMigrationKeyPrefixes.contains(where: key.hasPrefix)
        }
        for key in obsoleteKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
            removedKeys.append(key)
        }
        return removedKeys
    }

    /// Removes known llama.cpp model files without creating the old directory.
    /// The directory itself is removed only when it is empty afterward.
    @discardableResult
    static func removeDownloadedModels(
        from directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> [String] {
        let modelDirectory = directory ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent(legacyModelDirectoryName, isDirectory: true)

        guard let modelDirectory,
              fileManager.fileExists(atPath: modelDirectory.path) else {
            return []
        }

        var removedFiles: [String] = []
        for fileName in legacyModelFileNames {
            let fileURL = modelDirectory.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: fileURL.path) else { continue }
            do {
                try fileManager.removeItem(at: fileURL)
                removedFiles.append(fileName)
            } catch {
                AppLog.shared.summarization(
                    "[LegacyLlamaMigration] Could not remove \(fileName): \(error.localizedDescription)",
                    level: .error
                )
            }
        }

        if let remainingFiles = try? fileManager.contentsOfDirectory(
            at: modelDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ), remainingFiles.isEmpty {
            try? fileManager.removeItem(at: modelDirectory)
        }

        return removedFiles.sorted()
    }

    private static func destinationTier(for legacyModelID: String?) -> DestinationTier {
        guard let legacyModelID else { return .medium }

        let model = legacyModelID
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: ".gguf", with: "")

        if model.contains("granite-4.0-h-tiny") {
            return .large
        }

        if model.contains("lfm")
            || model.contains("qwen3-1.7b")
            || model.contains("qwen3.5-2b")
            || model.contains("qwen3-5-2b")
            || model.contains("gemma-3n-e2b") {
            return .small
        }

        if model.contains("ministral-3b")
            || model.contains("granite-4.0-micro")
            || model.contains("phi-4-mini")
            || model.contains("phi4-mini")
            || model.contains("qwen3-4b")
            || model.contains("qwen3.5-4b")
            || model.contains("qwen3-5-4b")
            || model.contains("gemma-3n-e4b") {
            return .medium
        }

        return .medium
    }
}
