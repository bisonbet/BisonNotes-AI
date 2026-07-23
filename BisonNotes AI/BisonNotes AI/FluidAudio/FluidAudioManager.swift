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

    /// Timestamp of the last download progress event. Used by the stall watchdog to
    /// detect a download that "gets to step N and never proceeds" and cancel it so a
    /// hung transfer can't wedge `isDownloading` forever and swallow every retry.
    private var lastProgressUpdate = Date()

    /// Diagnostic throttle state for download progress logging.
    private var downloadStartedAt = Date()
    private var lastProgressLogAt = Date.distantPast
    private var lastLoggedCompletedFiles = -1
    private var lastLoggedFraction: Double = -1

    /// Cancel an in-flight download only after this long with no progress event at all.
    /// Deliberately generous: the SDK reports bytes continuously, so a healthy (even slow)
    /// transfer keeps resetting this clock. Kept well above the SDK's own per-file retry
    /// budget so a brief network hiccup doesn't cancel — our cancellation makes the SDK
    /// delete the whole partial cache and restart from zero, so we only want to trip on a
    /// genuinely dead download, as a backstop against an indefinite hang.
    private static let downloadStallTimeoutSeconds: TimeInterval = 300

    #if canImport(FluidAudio)
    private var downloadTask: Task<AsrModels, Error>?
    private var asrManager: AsrManager?
    #else
    private var downloadTask: Task<Void, Error>?
    #endif

    private init() {
        #if canImport(FluidAudio)
        // Recover models downloaded by an older FluidAudio SDK. 0.15.x renamed the on-disk
        // cache folders to add a `-coreml` suffix (e.g. `parakeet-tdt-0.6b-v2` →
        // `parakeet-tdt-0.6b-v2-coreml`). Without this, an app update orphans a working
        // model and it reads as "not downloaded". Must run before the checks below.
        Self.migrateLegacyModelFoldersIfNeeded()
        #endif

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

    /// Move models downloaded by an older FluidAudio SDK into the folder the current SDK
    /// expects. Older SDKs stored ASR models under the raw HuggingFace repo name, which ends
    /// in `-coreml` (e.g. `parakeet-tdt-0.6b-v2-coreml`); the current SDK's `folderName`
    /// strips that suffix (→ `parakeet-tdt-0.6b-v2`), so an app update orphans a working model
    /// and it reads as "not downloaded". The files inside are identical, so a rename fully
    /// recovers it with no re-download. Safe to run every launch — no-ops once migrated.
    private static func migrateLegacyModelFoldersIfNeeded() {
        let fm = FileManager.default
        for version in FluidAudioModelInfo.ModelVersion.allCases {
            let asrVersion = asrModelVersion(for: version)
            let newDir = AsrModels.defaultCacheDirectory(for: asrVersion)

            // Already present at the SDK's current path — nothing to migrate.
            if AsrModels.modelsExist(at: newDir, version: asrVersion) { continue }

            let modelsParent = newDir.deletingLastPathComponent()
            // The old SDK's folder = current folder name with the `-coreml` suffix restored.
            let legacyDir = modelsParent.appendingPathComponent(newDir.lastPathComponent + "-coreml")

            // SDK folder name unchanged, or no legacy folder to adopt.
            guard legacyDir.path != newDir.path else { continue }
            guard fm.fileExists(atPath: legacyDir.path) else { continue }
            guard legacyFolderLooksValid(at: legacyDir) else { continue }

            do {
                // Clear an incomplete/empty destination so the move can land.
                if fm.fileExists(atPath: newDir.path) {
                    try fm.removeItem(at: newDir)
                }
                try fm.createDirectory(at: modelsParent, withIntermediateDirectories: true)
                try fm.moveItem(at: legacyDir, to: newDir)
                AppLog.shared.transcription(
                    "FluidAudio: migrated legacy model folder '\(version.modelFolderName)' → '\(newDir.lastPathComponent)'"
                )
            } catch {
                AppLog.shared.transcription(
                    "FluidAudio: legacy model migration failed for \(version.rawValue): \(error.localizedDescription)",
                    level: .error
                )
            }
        }
    }

    /// Lightweight sanity check that a legacy folder holds a real model before we move it.
    /// Kept version-agnostic (vocab + a few compiled model bundles) so it works for v2 and v3;
    /// the SDK's own `modelsExist` is the authoritative check once the folder is in place.
    private static func legacyFolderLooksValid(at dir: URL) -> Bool {
        let fm = FileManager.default
        let vocab = dir.appendingPathComponent(ModelNames.ASR.vocabularyFile)
        guard fm.fileExists(atPath: vocab.path) else { return false }
        guard let contents = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        return contents.filter { $0.hasSuffix(".mlmodelc") }.count >= 3
    }

    private static var parakeetASRConfig: ASRConfig {
        ASRConfig(
            parallelChunkConcurrency: 1,
            streamingEnabled: true,
            streamingThreshold: 480_000
        )
    }

    nonisolated private static func makeDownloadProgressHandler() -> ProgressHandler {
        { progress in
            Task { @MainActor in
                let manager = FluidAudioManager.shared
                guard manager.isDownloading else { return }

                manager.lastProgressUpdate = Date()
                manager.downloadProgress = Float(progress.fractionCompleted)
                manager.currentStatus = downloadStatusMessage(for: progress)
                manager.logDownloadProgress(progress)
            }
        }
    }

    private static func downloadStatusMessage(for progress: DownloadProgress) -> String {
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

    /// Throttled diagnostic logging of download progress. Logs on phase/file changes and at
    /// most every ~2s otherwise, so we can see exactly where a stall happens and whether bytes
    /// were still flowing (fraction advancing) right before the watchdog trips.
    private func logDownloadProgress(_ progress: DownloadProgress) {
        let now = Date()
        let elapsed = Int(now.timeIntervalSince(downloadStartedAt))
        switch progress.phase {
        case .listing:
            AppLog.shared.transcription("Parakeet download [\(elapsed)s]: listing files…", level: .debug)
        case .downloading(let completed, let total):
            let fileChanged = completed != lastLoggedCompletedFiles
            let throttleElapsed = now.timeIntervalSince(lastProgressLogAt) >= 2.0
            guard fileChanged || throttleElapsed else { return }
            let frac = String(format: "%.4f", progress.fractionCompleted)
            let delta = progress.fractionCompleted - lastLoggedFraction
            let moving = lastLoggedFraction < 0 || delta > 0 ? "advancing" : "FLAT"
            AppLog.shared.transcription(
                "Parakeet download [\(elapsed)s]: file \(completed)/\(total), fraction \(frac) (\(moving))",
                level: .debug
            )
            lastProgressLogAt = now
            lastLoggedCompletedFiles = completed
            lastLoggedFraction = progress.fractionCompleted
        case .compiling(let modelName):
            AppLog.shared.transcription(
                "Parakeet download [\(elapsed)s]: compiling \(modelName.isEmpty ? "models" : modelName)…",
                level: .debug
            )
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
        #if canImport(FluidAudio)
        // If a download is already running, await its real outcome instead of returning a
        // false success. Previously this returned immediately, so a concurrent/retry call
        // logged "download completed" while nothing happened and the model stayed absent.
        if isDownloading {
            if let existing = downloadTask {
                _ = try await existing.value
            }
            guard isModelReady else {
                throw TranscriptionError.fluidAudioNotReady
            }
            return
        }

        // Check network availability before starting download
        if networkMonitor?.currentPath.status == .unsatisfied {
            currentStatus = "No network connection. Please check your internet and try again."
            throw TranscriptionError.fluidAudioNotAvailable
        }

        isDownloading = true
        downloadProgress = 0
        let now = Date()
        lastProgressUpdate = now
        downloadStartedAt = now
        lastProgressLogAt = .distantPast
        lastLoggedCompletedFiles = -1
        lastLoggedFraction = -1
        currentStatus = "Downloading Parakeet model..."
        defer {
            isDownloading = false
        }

        let selectedVersion = FluidAudioModelInfo.selectedModelVersion
        AppLog.shared.transcription("Parakeet download starting for \(selectedVersion.rawValue) (stall timeout \(Int(Self.downloadStallTimeoutSeconds))s)")
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

        // Watchdog: cancel the download if it stalls (no progress event within the timeout),
        // so a hung transfer surfaces as an error instead of wedging `isDownloading` forever.
        let watchdog = Task { @MainActor [weak self] in
            while true {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, self.isDownloading else { return }
                let stalledFor = Date().timeIntervalSince(self.lastProgressUpdate)
                // Surface a building stall early so we can correlate it with app-background
                // events or connection resets, well before the watchdog actually cancels.
                if stalledFor >= 15 {
                    AppLog.shared.transcription(
                        "Parakeet download: no progress for \(Int(stalledFor))s (last fraction \(String(format: "%.4f", Double(self.downloadProgress))), cancels at \(Int(Self.downloadStallTimeoutSeconds))s)",
                        level: .debug
                    )
                }
                if stalledFor > Self.downloadStallTimeoutSeconds {
                    AppLog.shared.transcription(
                        "Parakeet download watchdog: canceling after \(Int(stalledFor))s with no progress (stuck at fraction \(String(format: "%.4f", Double(self.downloadProgress))))",
                        level: .error
                    )
                    self.currentStatus = "Download stalled. Please try again."
                    task.cancel()
                    return
                }
            }
        }

        let models: AsrModels
        do {
            models = try await task.value
            watchdog.cancel()
            AppLog.shared.transcription("Parakeet download finished transfer in \(Int(Date().timeIntervalSince(downloadStartedAt)))s; initializing…")
        } catch {
            watchdog.cancel()
            downloadTask = nil
            downloadProgress = 0
            let ns = error as NSError
            AppLog.shared.transcription(
                "Parakeet download failed after \(Int(Date().timeIntervalSince(downloadStartedAt)))s: \(ns.domain) code=\(ns.code) — \(ns.localizedDescription)",
                level: .error
            )
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
