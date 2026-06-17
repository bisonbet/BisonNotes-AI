import Foundation
@preconcurrency import AVFoundation
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
    private var networkMonitor: NWPathMonitor?

    #if canImport(FluidAudio)
    private var downloadTask: Task<AsrModels, Error>?
    private var asrManager: AsrManager?
    #else
    private var downloadTask: Task<Void, Error>?
    #endif

    private init() {
        let downloaded = UserDefaults.standard.bool(forKey: FluidAudioModelInfo.SettingsKeys.modelDownloaded)
        guard downloaded else {
            // UserDefaults says not downloaded — but check if files exist on disk anyway
            // (handles case where UserDefaults was reset but model files survived an update)
            if Self.modelFilesExistOnDisk(for: FluidAudioModelInfo.selectedModelVersion) {
                isModelReady = true
                UserDefaults.standard.set(true, forKey: FluidAudioModelInfo.SettingsKeys.modelDownloaded)
                let selectedVersion = FluidAudioModelInfo.selectedModelVersion.rawValue
                UserDefaults.standard.set(selectedVersion, forKey: FluidAudioModelInfo.SettingsKeys.downloadedModelVersion)
            }
            startNetworkMonitoring()
            return
        }

        let downloadedVersion = UserDefaults.standard.string(forKey: FluidAudioModelInfo.SettingsKeys.downloadedModelVersion)
        let selectedVersion = FluidAudioModelInfo.selectedModelVersion.rawValue

        if let dv = downloadedVersion {
            if dv == selectedVersion, Self.modelFilesExistOnDisk(for: FluidAudioModelInfo.selectedModelVersion) {
                isModelReady = true
            } else if let downloadedModelVersion = FluidAudioModelInfo.ModelVersion(rawValue: dv),
                      Self.modelFilesExistOnDisk(for: downloadedModelVersion) {
                // Selected version changed, but the downloaded version is valid on disk.
                // Keep the downloaded version available rather than forcing a re-download.
                UserDefaults.standard.set(dv, forKey: FluidAudioModelInfo.SettingsKeys.selectedModelVersion)
                isModelReady = true
                AppLog.shared.transcription("FluidAudio: kept downloaded \(dv) model (selected was \(selectedVersion))")
            } else {
                clearDownloadedModelDefaults()
            }
        } else if Self.modelFilesExistOnDisk(for: FluidAudioModelInfo.selectedModelVersion) {
            // Legacy install without version tracking: trust only verified files.
            isModelReady = true
            UserDefaults.standard.set(selectedVersion, forKey: FluidAudioModelInfo.SettingsKeys.downloadedModelVersion)
        } else if let availableVersion = Self.firstAvailableModelVersionOnDisk() {
            UserDefaults.standard.set(availableVersion.rawValue, forKey: FluidAudioModelInfo.SettingsKeys.selectedModelVersion)
            UserDefaults.standard.set(availableVersion.rawValue, forKey: FluidAudioModelInfo.SettingsKeys.downloadedModelVersion)
            isModelReady = true
        } else {
            clearDownloadedModelDefaults()
        }

        startNetworkMonitoring()
    }

    private static func fluidAudioDirectory() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport.appendingPathComponent("FluidAudio")
    }

    private static func firstAvailableModelVersionOnDisk() -> FluidAudioModelInfo.ModelVersion? {
        FluidAudioModelInfo.ModelVersion.allCases.first { modelFilesExistOnDisk(for: $0) }
    }

    /// Check if the selected FluidAudio model files exist on disk regardless of UserDefaults state.
    private static func modelFilesExistOnDisk(for version: FluidAudioModelInfo.ModelVersion) -> Bool {
        #if canImport(FluidAudio)
        let asrVersion = asrModelVersion(for: version)
        let cacheDir = AsrModels.defaultCacheDirectory(for: asrVersion)
        return AsrModels.modelsExist(at: cacheDir, version: asrVersion)
        #else
        guard let modelsDir = fluidAudioDirectory()?.appendingPathComponent("Models") else { return false }
        let modelDir = modelsDir.appendingPathComponent(version.modelFolderName)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: modelDir.path) else {
            return false
        }
        return !contents.isEmpty
        #endif
    }

    private static func deleteModelFiles(for version: FluidAudioModelInfo.ModelVersion) {
        #if canImport(FluidAudio)
        let modelDir = AsrModels.defaultCacheDirectory(for: asrModelVersion(for: version))
        try? FileManager.default.removeItem(at: modelDir)
        #else
        guard let modelsDir = fluidAudioDirectory()?.appendingPathComponent("Models") else { return }
        try? FileManager.default.removeItem(at: modelsDir.appendingPathComponent(version.modelFolderName))
        #endif
    }

    #if canImport(FluidAudio)
    private static func asrModelVersion(for version: FluidAudioModelInfo.ModelVersion) -> AsrModelVersion {
        switch version {
        case .v2:
            return .v2
        case .v3:
            return .v3
        }
    }

    private static var parakeetASRConfig: ASRConfig {
        ASRConfig(
            parallelChunkConcurrency: 1,
            streamingEnabled: true,
            streamingThreshold: 480_000
        )
    }

    nonisolated private static func makeDownloadProgressHandler() -> DownloadUtils.ProgressHandler {
        { progress in
            Task { @MainActor in
                let manager = FluidAudioManager.shared
                guard manager.isDownloading else { return }

                manager.downloadProgress = Float(progress.fractionCompleted)
                manager.currentStatus = downloadStatusMessage(for: progress)
            }
        }
    }

    private static func downloadStatusMessage(for progress: DownloadUtils.DownloadProgress) -> String {
        switch progress.phase {
        case .listing:
            return "Checking Parakeet model files..."
        case .downloading(let completedFiles, let totalFiles):
            if totalFiles > 0 {
                return "Downloading Parakeet model files... \(completedFiles)/\(totalFiles)"
            }
            return "Downloading Parakeet model files..."
        case .compiling(let modelName):
            if modelName.isEmpty {
                return "Preparing Parakeet model..."
            }
            return "Preparing \(modelName)..."
        }
    }
    #endif

    private func clearDownloadedModelDefaults() {
        UserDefaults.standard.set(false, forKey: FluidAudioModelInfo.SettingsKeys.modelDownloaded)
        UserDefaults.standard.removeObject(forKey: FluidAudioModelInfo.SettingsKeys.downloadedModelVersion)
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
        clearDownloadedModelDefaults()
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
        if !isModelReady {
            Self.deleteModelFiles(for: selectedVersion)
        }

        // Wrap in a Task so we can support cancellation
        let task = Task { () -> AsrModels in
            let progressHandler = Self.makeDownloadProgressHandler()
            let models: AsrModels
            switch selectedVersion {
            case .v2:
                models = try await AsrModels.downloadAndLoad(version: .v2, progressHandler: progressHandler)
            case .v3:
                models = try await AsrModels.downloadAndLoad(version: .v3, progressHandler: progressHandler)
            }
            try Task.checkCancellation()
            return models
        }
        downloadTask = task

        let models: AsrModels
        do {
            models = try await task.value
        } catch {
            downloadTask = nil
            downloadProgress = 0
            throw error
        }

        downloadTask = nil
        downloadProgress = 0.95
        currentStatus = "Initializing model..."

        let manager = AsrManager(config: Self.parakeetASRConfig, models: models)

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
        // FluidAudio SDK stores ASR models in Application Support, not Caches
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let fluidAudioDir = appSupport.appendingPathComponent("FluidAudio")
            try? FileManager.default.removeItem(at: fluidAudioDir)
        }
        #endif
        loadedModelVersion = nil
        isModelReady = false
        downloadProgress = 0
        currentStatus = "Model deleted"
        clearDownloadedModelDefaults()
    }

    /// Unload the model from memory without deleting files on disk
    func unloadModel() {
        #if canImport(FluidAudio)
        asrManager = nil
        #endif
        loadedModelVersion = nil
        AppLog.shared.transcription("FluidAudio model unloaded from memory")
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
                clearDownloadedModelDefaults()
                throw TranscriptionError.fluidAudioNotReady
            }
        }

        guard let asrManager else {
            throw TranscriptionError.fluidAudioNotReady
        }

        do {
            currentStatus = "Transcribing with Parakeet..."
            let start = Date()
            let originalDuration = await Self.audioDuration(for: audioURL)
            var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
            let result = try await asrManager.transcribe(audioURL, decoderState: &decoderState)

            let segment = TranscriptSegment(
                speaker: "",
                text: result.text,
                startTime: 0,
                endTime: originalDuration > 0 ? originalDuration : 0
            )

            return TranscriptionResult(
                fullText: result.text,
                segments: [segment],
                processingTime: Date().timeIntervalSince(start),
                chunkCount: 1,
                success: true,  // success reflects engine completion without error, not output length
                error: nil
            )
        } catch {
            let detailedError = Self.detailedFluidAudioError(
                error,
                originalURL: audioURL
            )
            AppLog.shared.transcription(
                "FluidAudio Parakeet transcription failed: \(detailedError.localizedDescription)",
                level: .error
            )
            throw TranscriptionError.fluidAudioTranscriptionFailed(detailedError)
        }
        #else
        throw TranscriptionError.fluidAudioNotAvailable
        #endif
    }

    private static func audioDuration(for url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration).seconds
            return duration.isFinite && duration > 0 ? duration : 0
        } catch {
            AppLog.shared.transcription("Could not read Parakeet input duration: \(error.localizedDescription)", level: .debug)
            return 0
        }
    }

    private static func detailedFluidAudioError(
        _ error: Error,
        originalURL: URL
    ) -> NSError {
        let nsError = error as NSError
        let message = "Parakeet SDK transcription failed for \(originalURL.lastPathComponent): \(nsError.domain) \(nsError.code) - \(nsError.localizedDescription)"
        return NSError(
            domain: "FluidAudioManager.Transcription",
            code: nsError.code,
            userInfo: [
                NSLocalizedDescriptionKey: message,
                NSUnderlyingErrorKey: nsError,
                "originalPath": originalURL.path
            ]
        )
    }
}
