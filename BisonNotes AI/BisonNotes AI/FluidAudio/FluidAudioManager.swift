import Foundation
import AVFoundation
import Network

#if canImport(FluidAudio)
import FluidAudio
#endif

@MainActor
final class FluidAudioManager: ObservableObject {
    static let shared = FluidAudioManager()

    @Published var isModelReady = false
    @Published var isDownloading = false
    @Published var downloadProgress: Float = 0
    @Published var currentStatus = ""

    private var loadedModelVersion: FluidAudioModelInfo.ModelVersion?
    private var downloadTask: Task<Void, Error>?
    private var networkMonitor: NWPathMonitor?

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

        startNetworkMonitoring()
    }

    /// Whether the FluidAudio SDK is linked in this build. Compile-time constant, safe to access from any isolation domain.
    nonisolated static var isAvailableInCurrentBuild: Bool {
        #if canImport(FluidAudio)
        return true
        #else
        return false
        #endif
    }

    /// Instance convenience accessor
    nonisolated var isAvailableInCurrentBuild: Bool {
        Self.isAvailableInCurrentBuild
    }

    // MARK: - Network Monitoring

    private func startNetworkMonitoring() {
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                if path.status == .unsatisfied && self?.isDownloading == true {
                    self?.currentStatus = "Network connection lost."
                    self?.cancelDownload()
                }
            }
        }
        let queue = DispatchQueue(label: "FluidAudioNetworkMonitor")
        networkMonitor?.start(queue: queue)
    }

    // MARK: - Model Version Management

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

    // MARK: - Download & Prepare

    func downloadAndPrepareModel() async throws {
        guard !isDownloading else { return }

        // Check network availability before starting download
        if networkMonitor?.currentPath.status == .unsatisfied {
            currentStatus = "No network connection. Please check your internet and try again."
            throw TranscriptionError.fluidAudioNotAvailable
        }

        #if canImport(FluidAudio)
        isDownloading = true
        downloadProgress = 0
        currentStatus = "Downloading Parakeet model..."
        defer {
            isDownloading = false
        }

        let selectedVersion = FluidAudioModelInfo.selectedModelVersion

        // Wrap in a Task so we can support cancellation
        let task = Task { () -> AsrModels in
            let models: AsrModels
            switch selectedVersion {
            case .v2:
                models = try await AsrModels.downloadAndLoad(version: .v2)
            case .v3:
                models = try await AsrModels.downloadAndLoad(version: .v3)
            }
            try Task.checkCancellation()
            return models
        }
        // Store an erased reference for cancellation
        let cancellationTask = Task<Void, Error> {
            _ = try await task.value
        }
        downloadTask = cancellationTask

        // Update progress while downloading (poll-based since FluidAudio SDK doesn't expose progress callbacks)
        let progressTask = Task {
            var tick: Float = 0
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                tick += 1
                // Indeterminate progress: pulse between 0 and 0.9 until done
                let pulse = min(0.9, tick * 0.02)
                await MainActor.run {
                    if self.isDownloading {
                        self.downloadProgress = pulse
                        self.currentStatus = "Downloading Parakeet model... (\(Int(pulse * 100))%)"
                    }
                }
            }
        }

        let models: AsrModels
        do {
            models = try await task.value
            progressTask.cancel()
        } catch {
            progressTask.cancel()
            downloadTask = nil
            downloadProgress = 0
            throw error
        }

        downloadTask = nil
        downloadProgress = 0.95
        currentStatus = "Initializing model..."

        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)

        asrManager = manager
        loadedModelVersion = selectedVersion
        isModelReady = true
        downloadProgress = 1.0
        currentStatus = "Parakeet model ready"
        UserDefaults.standard.set(true, forKey: FluidAudioModelInfo.SettingsKeys.modelDownloaded)
        UserDefaults.standard.set(selectedVersion.rawValue, forKey: FluidAudioModelInfo.SettingsKeys.downloadedModelVersion)
        #else
        throw TranscriptionError.fluidAudioNotAvailable
        #endif
    }

    /// Cancel the current download
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0
        currentStatus = "Download cancelled"
    }

    // MARK: - Model Management

    /// Delete the downloaded model and free storage
    func deleteModel() {
        #if canImport(FluidAudio)
        asrManager = nil
        // Clear cached model files if FluidAudio stores them in a known location
        if let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let fluidAudioCache = cacheDir.appendingPathComponent("FluidAudio")
            try? FileManager.default.removeItem(at: fluidAudioCache)
        }
        #endif
        loadedModelVersion = nil
        isModelReady = false
        downloadProgress = 0
        currentStatus = "Model deleted"
        UserDefaults.standard.set(false, forKey: FluidAudioModelInfo.SettingsKeys.modelDownloaded)
        UserDefaults.standard.removeObject(forKey: FluidAudioModelInfo.SettingsKeys.downloadedModelVersion)
    }

    /// Unload the model from memory without deleting files on disk
    func unloadModel() {
        #if canImport(FluidAudio)
        asrManager = nil
        #endif
        loadedModelVersion = nil
        print("[FluidAudio] Model unloaded from memory")
    }

    // MARK: - Transcription

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        #if canImport(FluidAudio)
        // Require explicit model download before transcription can proceed
        guard isModelReady else {
            throw TranscriptionError.fluidAudioNotReady
        }

        // Validate audio file exists
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw TranscriptionError.fluidAudioTranscriptionFailed(
                NSError(domain: "FluidAudioManager", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Audio file not found at \(audioURL.path)"])
            )
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
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        let segment = TranscriptSegment(
            speaker: "",
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
