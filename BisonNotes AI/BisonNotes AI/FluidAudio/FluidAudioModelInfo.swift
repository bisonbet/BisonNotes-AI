import Foundation

struct FluidAudioModelInfo {
    enum ModelVersion: String, CaseIterable {
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
    }

    enum SettingsKeys {
        static let enableFluidAudio = "enableFluidAudio"
        static let selectedModelVersion = "fluidAudioSelectedModelVersion"
        static let modelDownloaded = "fluidAudioModelDownloaded"
        static let downloadedModelVersion = "fluidAudioDownloadedModelVersion"
    }

    static var selectedModelVersion: ModelVersion {
        let raw = UserDefaults.standard.string(forKey: SettingsKeys.selectedModelVersion) ?? ModelVersion.v2.rawValue
        return ModelVersion(rawValue: raw) ?? .v2
    }
}
