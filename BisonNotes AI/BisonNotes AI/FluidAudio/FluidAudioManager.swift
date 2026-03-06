import Foundation
import Combine
import AVFoundation

#if canImport(FluidAudio)
import FluidAudio
#endif

@MainActor
final class FluidAudioManager: ObservableObject {
    static let shared = FluidAudioManager()

    @Published var isModelReady = false
    @Published var isDownloading = false
    @Published var currentStatus = ""

    private var loadedModelVersion: FluidAudioModelInfo.ModelVersion?

    #if canImport(FluidAudio)
    private var asrManager: AsrManager?
    #endif

    private init() {
        let downloaded = UserDefaults.standard.bool(forKey: FluidAudioModelInfo.SettingsKeys.modelDownloaded)
        guard downloaded else { return }

        let downloadedVersion = UserDefaults.standard.string(forKey: FluidAudioModelInfo.SettingsKeys.downloadedModelVersion)
        let selectedVersion = FluidAudioModelInfo.selectedModelVersion.rawValue

        if let dv = downloadedVersion {
            // Version tracking present: only mark ready if versions match
            if dv == selectedVersion {
                isModelReady = true
            } else {
                // Selected version changed since last download — clear stale state
                UserDefaults.standard.set(false, forKey: FluidAudioModelInfo.SettingsKeys.modelDownloaded)
                UserDefaults.standard.removeObject(forKey: FluidAudioModelInfo.SettingsKeys.downloadedModelVersion)
            }
        } else {
            // Legacy install without version tracking: trust the downloaded flag
            isModelReady = true
        }
    }

    var isAvailableInCurrentBuild: Bool {
        #if canImport(FluidAudio)
        return true
        #else
        return false
        #endif
    }

    /// Resets the loaded model state when the user selects a different model version.
    /// Must be called from `FluidAudioSettingsView` when the version picker changes.
    func invalidateForVersionChange() {
        #if canImport(FluidAudio)
        asrManager = nil
        #endif
        loadedModelVersion = nil
        isModelReady = false
        currentStatus = "Model version changed. Please re-download."
        UserDefaults.standard.set(false, forKey: FluidAudioModelInfo.SettingsKeys.modelDownloaded)
        UserDefaults.standard.removeObject(forKey: FluidAudioModelInfo.SettingsKeys.downloadedModelVersion)
    }

    func downloadAndPrepareModel() async throws {
        guard !isDownloading else { return }

        #if canImport(FluidAudio)
        isDownloading = true
        currentStatus = "Downloading Parakeet model..."
        defer { isDownloading = false }

        let selectedVersion = FluidAudioModelInfo.selectedModelVersion
        let models: AsrModels
        switch selectedVersion {
        case .v2:
            models = try await AsrModels.downloadAndLoad(version: .v2)
        case .v3:
            models = try await AsrModels.downloadAndLoad(version: .v3)
        }

        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)

        asrManager = manager
        loadedModelVersion = selectedVersion
        isModelReady = true
        currentStatus = "Parakeet model ready"
        UserDefaults.standard.set(true, forKey: FluidAudioModelInfo.SettingsKeys.modelDownloaded)
        UserDefaults.standard.set(selectedVersion.rawValue, forKey: FluidAudioModelInfo.SettingsKeys.downloadedModelVersion)
        #else
        throw TranscriptionError.fluidAudioNotAvailable
        #endif
    }

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        #if canImport(FluidAudio)
        // Require explicit model download before transcription can proceed
        guard isModelReady else {
            throw TranscriptionError.fluidAudioNotReady
        }

        // Guard against a version switch that wasn't flushed via invalidateForVersionChange()
        if let loaded = loadedModelVersion, loaded != FluidAudioModelInfo.selectedModelVersion {
            invalidateForVersionChange()
            throw TranscriptionError.fluidAudioNotReady
        }

        // Re-initialize from cached model on fresh app launch (asrManager is nil until first use)
        if asrManager == nil {
            do {
                try await downloadAndPrepareModel()
            } catch {
                // Cached model files are gone; clear stale state so the UI reflects this
                isModelReady = false
                UserDefaults.standard.set(false, forKey: FluidAudioModelInfo.SettingsKeys.modelDownloaded)
                UserDefaults.standard.removeObject(forKey: FluidAudioModelInfo.SettingsKeys.downloadedModelVersion)
                throw TranscriptionError.fluidAudioNotReady
            }
        }

        guard let asrManager else {
            throw TranscriptionError.fluidAudioNotReady
        }

        currentStatus = "Transcribing with Parakeet..."
        let start = Date()
        let result = try await asrManager.transcribe(audioURL, source: .system)

        // Determine audio duration for accurate segment end time
        let asset = AVURLAsset(url: audioURL)
        let durationSeconds = CMTimeGetSeconds(asset.duration)

        let segment = TranscriptSegment(
            speaker: "Speaker 1",
            text: result.text,
            startTime: 0,
            endTime: durationSeconds > 0 ? durationSeconds : 0
        )

        return TranscriptionResult(
            fullText: result.text,
            segments: [segment],
            processingTime: Date().timeIntervalSince(start),
            chunkCount: 1,
            success: true,  // success reflects engine completion without error, not output length
            error: nil
        )
        #else
        throw TranscriptionError.fluidAudioNotAvailable
        #endif
    }
}
