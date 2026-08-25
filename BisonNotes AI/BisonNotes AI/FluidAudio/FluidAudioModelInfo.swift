import Foundation

struct FluidAudioModelInfo {
    /// Persistent choices for the opt-in post-recording local speaker-label feature.
    ///
    /// The selected method is intentionally stored as a raw value here. The shared
    /// app-owned method type lives in LocalDiarizationTypes.swift (Package A), while
    /// this file remains the single source for UserDefaults keys and cache layout.
    enum LocalSpeakerLabels {
        static let defaultEnabled = false
        static let defaultMethodRawValue = "offlineVBx"
        static let recommendedMethodRawValue = "offlineVBx"
        static let experimentalMethodRawValue = "experimentalLSEEND"
        static let maximumExperimentalDuration: TimeInterval = 60 * 60

        static func normalizedMethodRawValue(_ rawValue: String?) -> String {
            switch rawValue {
            case let value? where value == recommendedMethodRawValue || value == experimentalMethodRawValue:
                return value
            default:
                return defaultMethodRawValue
            }
        }
    }

    enum ModelVersion: String, CaseIterable, Sendable {
        case v2
        case v3

        var displayName: String {
            switch self {
            case .v2:
                return "Parakeet v2 (English)"
            case .v3:
                return "Parakeet v3 (Multilingual)"
            }
        }

        var description: String {
            switch self {
            case .v2:
                return "English-only model with stronger long-form English recall"
            case .v3:
                return "Multilingual model for 25 European languages"
            }
        }

        /// Estimated download size in bytes
        var downloadSizeBytes: Int64 {
            switch self {
            case .v2:
                return 250_000_000 // ~250 MB
            case .v3:
                return 350_000_000 // ~350 MB
            }
        }

        var modelFolderName: String {
            switch self {
            case .v2:
                return "parakeet-tdt-0.6b-v2"
            case .v3:
                return "parakeet-tdt-0.6b-v3"
            }
        }
    }

    enum SettingsKeys {
        static let enableFluidAudio = "enableFluidAudio"
        static let selectedModelVersion = "fluidAudioSelectedModelVersion"
        static let modelDownloaded = "fluidAudioModelDownloaded"
        static let downloadedModelVersion = "fluidAudioDownloadedModelVersion"
        static let localSpeakerLabelsEnabled = "fluidAudioLocalSpeakerLabelsEnabled"
        static let selectedLocalSpeakerLabelMethod = "fluidAudioSelectedLocalSpeakerLabelMethod"
    }

    static var selectedModelVersion: ModelVersion {
        let raw = UserDefaults.standard.string(forKey: SettingsKeys.selectedModelVersion) ?? ModelVersion.v2.rawValue
        return ModelVersion(rawValue: raw) ?? .v2
    }

    static var localSpeakerLabelsEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKeys.localSpeakerLabelsEnabled) as? Bool
            ?? LocalSpeakerLabels.defaultEnabled
    }

    static var selectedLocalSpeakerLabelMethodRawValue: String {
        LocalSpeakerLabels.normalizedMethodRawValue(
            UserDefaults.standard.string(forKey: SettingsKeys.selectedLocalSpeakerLabelMethod)
        )
    }

    static func localSpeakerLabelsRoot(
        appSupportDirectory: URL? = nil
    ) -> URL? {
        let base = appSupportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return base?.appendingPathComponent("FluidAudio/Models/LocalSpeakerLabels", isDirectory: true)
    }

    static func localSpeakerModelCacheDirectory(
        methodRawValue: String,
        appSupportDirectory: URL? = nil
    ) -> URL? {
        guard let root = localSpeakerLabelsRoot(appSupportDirectory: appSupportDirectory) else {
            return nil
        }

        switch LocalSpeakerLabels.normalizedMethodRawValue(methodRawValue) {
        case LocalSpeakerLabels.recommendedMethodRawValue:
            return root.appendingPathComponent("offline-vbx", isDirectory: true)
        case LocalSpeakerLabels.experimentalMethodRawValue:
            return root.appendingPathComponent("ls-eend-dihard3-500ms", isDirectory: true)
        default:
            return nil
        }
    }

    static func deleteCacheDirectory(
        at directory: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }
}
