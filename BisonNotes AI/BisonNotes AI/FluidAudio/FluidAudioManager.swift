import Foundation
@preconcurrency import AVFoundation
import Network

#if canImport(FluidAudio)
import FluidAudio
#endif

@MainActor
final class FluidAudioManager: ObservableObject {
    static let shared = FluidAudioManager()

    private static let targetSampleRate: Double = 16_000
    private static let targetChannelCount: AVAudioChannelCount = 1
    private static let minimumPreparedDuration: TimeInterval = 0.3

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
        guard downloaded else {
            // UserDefaults says not downloaded — but check if files exist on disk anyway
            // (handles case where UserDefaults was reset but model files survived an update)
            if Self.modelFilesExistOnDisk() {
                isModelReady = true
                UserDefaults.standard.set(true, forKey: FluidAudioModelInfo.SettingsKeys.modelDownloaded)
                // We don't know which version, so check both
                let selectedVersion = FluidAudioModelInfo.selectedModelVersion.rawValue
                UserDefaults.standard.set(selectedVersion, forKey: FluidAudioModelInfo.SettingsKeys.downloadedModelVersion)
                startNetworkMonitoring()
            }
            return
        }

        let downloadedVersion = UserDefaults.standard.string(forKey: FluidAudioModelInfo.SettingsKeys.downloadedModelVersion)
        let selectedVersion = FluidAudioModelInfo.selectedModelVersion.rawValue

        if let dv = downloadedVersion {
            if dv == selectedVersion {
                isModelReady = true
            } else {
                // Selected version changed — but the downloaded version's files may still be on disk.
                // Keep the downloaded version available rather than forcing a re-download.
                // Update the selected version to match what's actually on disk.
                UserDefaults.standard.set(dv, forKey: FluidAudioModelInfo.SettingsKeys.selectedModelVersion)
                isModelReady = true
                AppLog.shared.transcription("FluidAudio: kept downloaded \(dv) model (selected was \(selectedVersion))")
            }
        } else {
            // Legacy install without version tracking: trust the downloaded flag
            isModelReady = true
        }

        startNetworkMonitoring()
    }

    /// Check if FluidAudio model files exist on disk regardless of UserDefaults state.
    private static func modelFilesExistOnDisk() -> Bool {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return false
        }
        let modelsDir = appSupport.appendingPathComponent("FluidAudio").appendingPathComponent("Models")
        // Check for any version subdirectory with contents
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: modelsDir.path) else {
            return false
        }
        return !contents.isEmpty
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
        // Uses asymptotic formula that never reaches 100% until download completes:
        // progress = 0.95 * (1 - e^(-tick/40)) approaches 95% smoothly over time
        let progressTask = Task {
            var tick: Float = 0
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                tick += 1
                // Asymptotic progress: smoothly approaches 95% without stalling
                // At tick 20 (10s): ~39%, tick 40 (20s): ~63%, tick 80 (40s): ~86%, tick 120 (60s): ~95%
                let progress = 0.95 * (1.0 - exp(-tick / 40.0))
                await MainActor.run {
                    if self.isDownloading {
                        self.downloadProgress = progress
                        self.currentStatus = "Downloading Parakeet model... (\(Int(progress * 100))%)"
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

        let manager = AsrManager(config: .default, models: models)

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
        UserDefaults.standard.set(false, forKey: FluidAudioModelInfo.SettingsKeys.modelDownloaded)
        UserDefaults.standard.removeObject(forKey: FluidAudioModelInfo.SettingsKeys.downloadedModelVersion)
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
                UserDefaults.standard.set(false, forKey: FluidAudioModelInfo.SettingsKeys.modelDownloaded)
                UserDefaults.standard.removeObject(forKey: FluidAudioModelInfo.SettingsKeys.downloadedModelVersion)
                throw TranscriptionError.fluidAudioNotReady
            }
        }

        guard let asrManager else {
            throw TranscriptionError.fluidAudioNotReady
        }

        currentStatus = "Preparing audio for Parakeet..."
        let start = Date()
        let preparedInput = try prepareAudioForParakeet(audioURL)
        defer {
            if preparedInput.shouldDelete {
                try? FileManager.default.removeItem(at: preparedInput.url)
            }
        }

        currentStatus = "Transcribing with Parakeet..."
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        do {
            let result = try await asrManager.transcribe(preparedInput.url, decoderState: &decoderState)

            let segment = TranscriptSegment(
                speaker: "",
                text: result.text,
                startTime: 0,
                endTime: preparedInput.originalDuration > 0 ? preparedInput.originalDuration : 0
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
            throw TranscriptionError.fluidAudioTranscriptionFailed(error)
        }
        #else
        throw TranscriptionError.fluidAudioNotAvailable
        #endif
    }

    private struct PreparedAudioInput {
        let url: URL
        let shouldDelete: Bool
        let originalDuration: TimeInterval
        let preparedDuration: TimeInterval
    }

    /// FluidAudio validates decoded 16 kHz PCM, not just the source container.
    /// Convert app/imported audio first so playable AAC/M4A files do not fail
    /// ASR with a misleading "under 300ms" decoded-buffer error.
    private func prepareAudioForParakeet(_ sourceURL: URL) throws -> PreparedAudioInput {
        let sourceFile: AVAudioFile
        do {
            sourceFile = try AVAudioFile(forReading: sourceURL)
        } catch {
            throw TranscriptionError.fluidAudioTranscriptionFailed(error)
        }

        let sourceFormat = sourceFile.processingFormat
        let originalDuration = sourceFormat.sampleRate > 0
            ? Double(sourceFile.length) / sourceFormat.sampleRate
            : 0

        guard originalDuration >= Self.minimumPreparedDuration else {
            throw TranscriptionError.fluidAudioTranscriptionFailed(Self.audioPreparationError(
                "Audio file decodes to only \(String(format: "%.2f", originalDuration))s. At least 0.30s is required."
            ))
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: Self.targetChannelCount,
            interleaved: false
        ) else {
            throw TranscriptionError.fluidAudioTranscriptionFailed(Self.audioPreparationError(
                "Could not create 16 kHz mono PCM format."
            ))
        }

        let preparedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fluidaudio_input_\(UUID().uuidString)")
            .appendingPathExtension("caf")

        do {
            try convert(sourceFile: sourceFile, to: preparedURL, targetFormat: targetFormat)

            let preparedFile = try AVAudioFile(forReading: preparedURL)
            let preparedFormat = preparedFile.processingFormat
            let preparedDuration = preparedFormat.sampleRate > 0
                ? Double(preparedFile.length) / preparedFormat.sampleRate
                : 0

            guard preparedDuration >= Self.minimumPreparedDuration else {
                try? FileManager.default.removeItem(at: preparedURL)
                throw TranscriptionError.fluidAudioTranscriptionFailed(Self.audioPreparationError(
                    "Prepared Parakeet input decodes to only \(String(format: "%.2f", preparedDuration))s. The source may be damaged or unsupported."
                ))
            }

            AppLog.shared.transcription(
                "Prepared Parakeet input: source=\(String(format: "%.2f", originalDuration))s @ \(Int(sourceFormat.sampleRate))Hz/\(sourceFormat.channelCount)ch, prepared=\(String(format: "%.2f", preparedDuration))s @ \(Int(preparedFormat.sampleRate))Hz/\(preparedFormat.channelCount)ch",
                level: .debug
            )

            return PreparedAudioInput(
                url: preparedURL,
                shouldDelete: true,
                originalDuration: originalDuration,
                preparedDuration: preparedDuration
            )
        } catch let error as TranscriptionError {
            throw error
        } catch {
            try? FileManager.default.removeItem(at: preparedURL)
            throw TranscriptionError.fluidAudioTranscriptionFailed(error)
        }
    }

    private func convert(sourceFile: AVAudioFile, to outputURL: URL, targetFormat: AVAudioFormat) throws {
        let sourceFormat = sourceFile.processingFormat
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw Self.audioPreparationError("Could not create audio converter for Parakeet input.")
        }

        try? FileManager.default.removeItem(at: outputURL)
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: targetFormat.settings,
            commonFormat: targetFormat.commonFormat,
            interleaved: targetFormat.isInterleaved
        )

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: 4_096
        ) else {
            throw Self.audioPreparationError("Could not allocate source audio buffer.")
        }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: 4_096
        ) else {
            throw Self.audioPreparationError("Could not allocate prepared audio buffer.")
        }

        var reachedEndOfSource = false
        var readError: Error?

        while true {
            outputBuffer.frameLength = 0

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if reachedEndOfSource {
                    outStatus.pointee = .endOfStream
                    return nil
                }

                do {
                    try sourceFile.read(into: inputBuffer, frameCount: inputBuffer.frameCapacity)
                    if inputBuffer.frameLength == 0 {
                        reachedEndOfSource = true
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    outStatus.pointee = .haveData
                    return inputBuffer
                } catch {
                    readError = error
                    outStatus.pointee = .noDataNow
                    return nil
                }
            }

            if let readError {
                throw readError
            }

            if let conversionError {
                throw conversionError
            }

            if outputBuffer.frameLength > 0 {
                try outputFile.write(from: outputBuffer)
            }

            switch status {
            case .haveData, .inputRanDry:
                continue
            case .endOfStream:
                return
            case .error:
                throw Self.audioPreparationError("Audio conversion failed for Parakeet input.")
            @unknown default:
                throw Self.audioPreparationError("Audio conversion ended with an unknown status.")
            }
        }
    }

    private static func audioPreparationError(_ message: String) -> NSError {
        NSError(
            domain: "FluidAudioManager.AudioPreparation",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
