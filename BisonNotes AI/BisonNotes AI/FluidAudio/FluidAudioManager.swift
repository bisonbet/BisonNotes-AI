import Foundation
import Combine

#if canImport(FluidAudio)
import FluidAudio
#endif

@MainActor
final class FluidAudioManager: ObservableObject {
    static let shared = FluidAudioManager()

    @Published var isModelReady = false
    @Published var isDownloading = false
    @Published var currentStatus = ""

    #if canImport(FluidAudio)
    private var asrManager: AsrManager?
    #endif

    private init() {
        isModelReady = UserDefaults.standard.bool(forKey: FluidAudioModelInfo.SettingsKeys.modelDownloaded)
    }

    var isAvailableInCurrentBuild: Bool {
        #if canImport(FluidAudio)
        return true
        #else
        return false
        #endif
    }

    func downloadAndPrepareModel() async throws {
        guard !isDownloading else { return }

        #if canImport(FluidAudio)
        isDownloading = true
        currentStatus = "Downloading Parakeet model..."
        defer { isDownloading = false }

        let models: AsrModels
        switch FluidAudioModelInfo.selectedModelVersion {
        case .v2:
            models = try await AsrModels.downloadAndLoad(version: .v2)
        case .v3:
            models = try await AsrModels.downloadAndLoad(version: .v3)
        }

        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)

        asrManager = manager
        isModelReady = true
        currentStatus = "Parakeet model ready"
        UserDefaults.standard.set(true, forKey: FluidAudioModelInfo.SettingsKeys.modelDownloaded)
        #else
        throw TranscriptionError.fluidAudioNotAvailable
        #endif
    }

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        #if canImport(FluidAudio)
        if asrManager == nil {
            try await downloadAndPrepareModel()
        }

        guard let asrManager else {
            throw TranscriptionError.fluidAudioNotReady
        }

        currentStatus = "Transcribing with Parakeet..."
        let start = Date()
        let result = try await asrManager.transcribe(audioURL, source: .system)

        let segment = TranscriptSegment(
            speaker: "Speaker 1",
            text: result.text,
            startTime: 0,
            endTime: 0
        )

        return TranscriptionResult(
            fullText: result.text,
            segments: [segment],
            processingTime: Date().timeIntervalSince(start),
            chunkCount: 1,
            success: !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            error: nil
        )
        #else
        throw TranscriptionError.fluidAudioNotAvailable
        #endif
    }
}
