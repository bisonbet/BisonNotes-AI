import Foundation

struct FluidAudioModelInfo {
    /// Persistent choices for the opt-in post-recording local speaker-label feature.
    ///
    /// The selected method is stored in UserDefaults as a raw value. Which raw
    /// values are valid, and each method's cache folder, come from
    /// `LocalDiarizationMethod` itself, so adding a case cannot leave a hand-kept
    /// list behind that silently reverts the setting or orphans its cache.
    enum LocalSpeakerLabels {
        static let defaultEnabled = false
        static let defaultMethodRawValue = LocalDiarizationMethod.defaultMethod.rawValue
        static let maximumExperimentalDuration: TimeInterval = 60 * 60

        static func normalizedMethodRawValue(_ rawValue: String?) -> String {
            rawValue.flatMap(LocalDiarizationMethod.init(rawValue:))?.rawValue ?? defaultMethodRawValue
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

    /// Takes the method itself, not a raw string, so an unknown value cannot
    /// reach a cache path. nil only when Application Support is unavailable.
    static func localSpeakerModelCacheDirectory(
        for method: LocalDiarizationMethod,
        appSupportDirectory: URL? = nil
    ) -> URL? {
        localSpeakerLabelsRoot(appSupportDirectory: appSupportDirectory)?
            .appendingPathComponent(method.cacheFolderName, isDirectory: true)
    }

    static func deleteCacheDirectory(
        at directory: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }
}
