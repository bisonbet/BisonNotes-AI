import Foundation

typealias LocalDiarizationProgressHandler = @Sendable (LocalDiarizationProgress) -> Void

/// Protocol-backed complete-file seam used by orchestration and lifecycle
/// tests. Implementations never perform a per-ASR-chunk pass.
protocol LocalDiarizationRunner: Sendable {
    func process(
        audioURL: URL,
        method: LocalDiarizationMethod,
        progressHandler: @escaping LocalDiarizationProgressHandler
    ) async throws -> LocalDiarizationResult

    func cleanup() async
}

/// Model/cache seam. Production uses the pinned FluidAudio SDK; tests inject
/// a fake provider rooted in a temporary directory and never touch the SDK.
protocol LocalDiarizationModelProvider: Sendable {
    func cacheDirectory(for method: LocalDiarizationMethod) async -> URL?
    func isReady(for method: LocalDiarizationMethod) async -> Bool

    func prepare(
        for method: LocalDiarizationMethod,
        forceRedownload: Bool,
        progressHandler: @escaping LocalDiarizationProgressHandler
    ) async throws

    func makeRunner(
        for method: LocalDiarizationMethod
    ) async throws -> any LocalDiarizationRunner

    func delete(for method: LocalDiarizationMethod) async throws
}

#if canImport(FluidAudio)
@preconcurrency import CoreML
import FluidAudio

/// Pinned FluidAudio implementation of the local speaker-model provider.
///
/// Hub-backed operations additionally pass through `FluidAudioModelHubGate`
/// because `ModelHub.offlineMode` is process-global across all providers.
actor FluidAudioLocalDiarizationModelProvider: LocalDiarizationModelProvider {
    private let appSupportDirectory: URL?

    init(appSupportDirectory: URL? = nil) {
        self.appSupportDirectory = appSupportDirectory
    }

    func cacheDirectory(for method: LocalDiarizationMethod) async -> URL? {
        FluidAudioModelInfo.localSpeakerModelCacheDirectory(
            for: method,
            appSupportDirectory: appSupportDirectory
        )
    }

    func isReady(for method: LocalDiarizationMethod) async -> Bool {
        guard let directory = await cacheDirectory(for: method) else { return false }
        let fileManager = FileManager.default

        switch method {
        case .offlineVBx:
            return Self.offlineVBxAssetsExist(at: directory, fileManager: fileManager)
        case .experimentalLSEEND:
            return Self.lseendAssetsExist(at: directory, fileManager: fileManager)
        case .betaNemotron3:
            guard let config = Self.nemotron3Config else { return false }
            return LocalDiarizationAssetValidator.nemotron3AssetsAreValid(
                Self.nemotron3Layout(at: directory, config: config),
                fileManager: fileManager
            )
        }
    }

    func prepare(
        for method: LocalDiarizationMethod,
        forceRedownload: Bool,
        progressHandler: @escaping LocalDiarizationProgressHandler
    ) async throws {
        guard let directory = await cacheDirectory(for: method) else {
            throw LocalDiarizationError.unsupportedMethod(method)
        }
        try Task.checkCancellation()

        try await FluidAudioModelHubGate.shared.withExclusiveAccess(mode: .online) { [self] in
            switch method {
            case .offlineVBx:
                try await prepareOfflineVBx(
                    at: directory,
                    forceRedownload: forceRedownload,
                    progressHandler: progressHandler
                )
            case .experimentalLSEEND:
                try await prepareLSEEND(
                    at: directory,
                    forceRedownload: forceRedownload,
                    progressHandler: progressHandler
                )
            case .betaNemotron3:
                try await prepareNemotron3(
                    at: directory,
                    forceRedownload: forceRedownload,
                    progressHandler: progressHandler
                )
            }
        }

        try Task.checkCancellation()
        guard await isReady(for: method) else {
            throw LocalDiarizationError.modelPreparationFailed(method)
        }
    }

    func makeRunner(
        for method: LocalDiarizationMethod
    ) async throws -> any LocalDiarizationRunner {
        guard let directory = await cacheDirectory(for: method),
            await isReady(for: method)
        else {
            throw LocalDiarizationError.downloadRequired(method)
        }

        // Nemotron 3 is built from the verified cache by hand and never touches
        // `ModelHub`, so it does not take the process-wide hub gate. A Neural
        // Engine recompile after an OS update can take several seconds, and
        // holding the gate through it stalled every Parakeet, VBx and LS-EEND
        // prepare or load queued behind it.
        if method == .betaNemotron3 {
            guard let config = Self.nemotron3Config else {
                throw LocalDiarizationError.unsupportedMethod(.betaNemotron3)
            }
            return try await Self.makeNemotron3Runner(
                layout: Self.nemotron3Layout(at: directory, config: config),
                config: config
            )
        }

        return try await FluidAudioModelHubGate.shared.withExclusiveAccess(mode: .offline) {
            switch method {
            case .offlineVBx:
                // Load the models here, under the gate, with offline mode forced.
                // `OfflineDiarizerManager.prepareModels` purges its cache and
                // re-downloads on any load failure, so it must never run outside
                // this gate — models are downloaded explicitly, never implicitly
                // when a transcription starts. `OfflineDiarizerModels` is Sendable,
                // so it crosses back out safely; the non-Sendable manager is then
                // built from it inside the runner actor.
                let models = try await Self.loadOfflineVBxModelsFromCache(from: directory)
                return OfflineVBxRunner(models: models)
            case .experimentalLSEEND:
                let modelURL = Self.lseendModelURL(at: directory)
                let model = try LSEENDModel(modelURL: modelURL, computeUnits: .cpuOnly)
                let diarizer = try LSEENDDiarizer(model: model)
                return LSEENDRunner(diarizer: diarizer)
            case .betaNemotron3:
                // Handled above, outside the gate.
                throw LocalDiarizationError.unsupportedMethod(.betaNemotron3)
            }
        }
    }

    func delete(for method: LocalDiarizationMethod) async throws {
        guard let directory = await cacheDirectory(for: method) else {
            throw LocalDiarizationError.unsupportedMethod(method)
        }
        try FluidAudioModelInfo.deleteCacheDirectory(at: directory)
    }

    private func prepareOfflineVBx(
        at directory: URL,
        forceRedownload: Bool,
        progressHandler: @escaping LocalDiarizationProgressHandler
    ) async throws {
        if forceRedownload {
            try FluidAudioModelInfo.deleteCacheDirectory(at: directory)
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        _ = try await OfflineDiarizerModels.load(
            from: directory,
            configuration: configuration,
            progressHandler: { progress in
                progressHandler(Self.localProgress(from: progress, method: .offlineVBx))
            }
        )
    }

    private func prepareLSEEND(
        at directory: URL,
        forceRedownload: Bool,
        progressHandler: @escaping LocalDiarizationProgressHandler
    ) async throws {
        if forceRedownload {
            try FluidAudioModelInfo.deleteCacheDirectory(at: directory)
        }

        // The pinned LS-EEND loader accepts a progress handler but does not
        // forward determinate events through ModelHub. Report honest indeterminate
        // preparation rather than manufacturing a percentage.
        progressHandler(
            LocalDiarizationProgress(method: .experimentalLSEEND, phase: .preparing)
        )
        _ = try await LSEENDModel.loadFromHuggingFace(
            variant: .dihard3,
            stepSize: .step500ms,
            cacheDirectory: directory,
            computeUnits: .cpuOnly,
            progressHandler: { _ in }
        )
        try Task.checkCancellation()
    }

    private func prepareNemotron3(
        at directory: URL,
        forceRedownload: Bool,
        progressHandler: @escaping LocalDiarizationProgressHandler
    ) async throws {
        guard let config = Self.nemotron3Config else {
            throw LocalDiarizationError.unsupportedMethod(.betaNemotron3)
        }
        if forceRedownload {
            try FluidAudioModelInfo.deleteCacheDirectory(at: directory)
        }

        // Loads with the same compute units inference uses, so the one-time
        // Neural Engine compile happens during the explicit download rather
        // than at the start of someone's first labeled transcription.
        _ = try await Nemotron3Models.loadFromHuggingFace(
            config: config,
            cacheDirectory: directory,
            computeUnits: Self.nemotron3ComputeUnits,
            progressHandler: { progress in
                progressHandler(Self.localProgress(from: progress, method: .betaNemotron3))
            }
        )
        try Task.checkCancellation()
        try Self.ensureNemotron3WeightsMarker(Self.nemotron3Layout(at: directory, config: config))
    }

    /// The SDK writes its weights marker with `try?`, so a failed write (most
    /// likely a full disk) is invisible: the files load, readiness then fails on
    /// the missing marker, and the retry's stale-cache check deletes the whole
    /// ~95 MB download. The SDK has just loaded these files at the version it
    /// expects, so writing the marker here is truthful — and a failure now
    /// surfaces as the real file-system error instead of a generic one.
    private static func ensureNemotron3WeightsMarker(_ layout: Nemotron3AssetLayout) throws {
        let current = try? String(contentsOf: layout.weightsVersionMarker, encoding: .utf8)
        guard current?.trimmingCharacters(in: .whitespacesAndNewlines) != layout.expectedWeightsVersion else {
            return
        }
        try Data((layout.expectedWeightsVersion + "\n").utf8)
            .write(to: layout.weightsVersionMarker, options: .atomic)
    }

    /// The 10.24 s-chunk, W8A8, split-graph preset: 95 MB, fully Neural
    /// Engine-resident, and the best speaker counting in FluidInference's AMI
    /// runs. The monolithic `offline` preset cannot compile for the Neural
    /// Engine and falls back to the GPU, which iOS denies to background work.
    private static let nemotron3PresetName = "c128-split-w8a8"
    private static let nemotron3ComputeUnits: MLComputeUnits = .cpuAndNeuralEngine

    private static var nemotron3Config: Nemotron3Config? {
        Nemotron3Config.preset(named: nemotron3PresetName)
    }

    /// Mirrors the layout `Nemotron3Models.loadFromHuggingFace` writes under
    /// its `cacheDirectory`.
    private static func nemotron3Layout(
        at directory: URL,
        config: Nemotron3Config
    ) -> Nemotron3AssetLayout {
        let repoDirectory = directory.appendingPathComponent(
            Repo.nemotron3Diarization.folderName,
            isDirectory: true
        )
        return Nemotron3AssetLayout(
            repoDirectory: repoDirectory,
            modelBundle: repoDirectory
                .appendingPathComponent(config.hubSubdirectory, isDirectory: true)
                .appendingPathComponent(config.modelFileName, isDirectory: true),
            silenceEmbedding: repoDirectory.appendingPathComponent(
                ModelNames.Nemotron3.silenceEmbeddingFile
            ),
            preEncodeProjection: repoDirectory.appendingPathComponent(
                ModelNames.Nemotron3.preEncodeProjectionFile
            ),
            weightsVersionMarker: repoDirectory.appendingPathComponent(
                ModelNames.Nemotron3.weightsVersionFile
            ),
            expectedWeightsVersion: ModelNames.Nemotron3.weightsVersion,
            // The same sizes `Nemotron3Models` checks when it loads: one
            // `preEncoderDims` embedding, and for split-graph presets the
            // stacked-mel (melFeatures × subsampling) → preEncoderDims projection.
            silenceEmbeddingByteCount: config.preEncoderDims * MemoryLayout<Float>.size,
            preEncodeProjectionByteCount: config.splitGraph
                ? config.melFeatures * config.subsamplingFactor * config.preEncoderDims
                    * MemoryLayout<Float>.size
                : nil
        )
    }

    /// Built from the verified cache by hand rather than through
    /// `Nemotron3Models.loadFromHuggingFace`, which deletes and re-downloads a
    /// cache whose weights marker has changed. That is right for the explicit
    /// download, never for a transcription.
    ///
    /// Everything a cache can do wrong — an asset that cannot be read, has the
    /// wrong size, or a compiled bundle Core ML rejects — is reported as
    /// Download Required, the one condition the user can act on. The underlying
    /// error is logged rather than shown.
    private nonisolated static func makeNemotron3Runner(
        layout: Nemotron3AssetLayout,
        config: Nemotron3Config
    ) async throws -> Nemotron3Runner {
        let silenceEmbedding = try LocalDiarizationAssetValidator.readFloatAsset(
            at: layout.silenceEmbedding,
            byteCount: layout.silenceEmbeddingByteCount,
            method: .betaNemotron3
        )
        let preEncodeProjection = try layout.preEncodeProjectionByteCount.map {
            try LocalDiarizationAssetValidator.readFloatAsset(
                at: layout.preEncodeProjection,
                byteCount: $0,
                method: .betaNemotron3
            )
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = nemotron3ComputeUnits
        let model: MLModel
        do {
            // Async so a Neural Engine recompile does not block a cooperative thread.
            model = try await MLModel.load(contentsOf: layout.modelBundle, configuration: configuration)
        } catch {
            try Task.checkCancellation()
            AppLog.shared.transcription(
                "Nemotron 3 model bundle failed to load: \(error.localizedDescription)",
                level: .error
            )
            throw LocalDiarizationError.downloadRequired(.betaNemotron3)
        }

        let models = try Nemotron3Models(
            config: config,
            model: model,
            silenceEmbedding: silenceEmbedding,
            preEncodeProjection: preEncodeProjection
        )
        return Nemotron3Runner(diarizer: Nemotron3Diarizer(config: config, models: models))
    }

    private nonisolated static func loadOfflineVBxModelsFromCache(
        from directory: URL
    ) async throws -> OfflineDiarizerModels {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        return try await OfflineDiarizerModels.load(
            from: directory,
            configuration: configuration,
            progressHandler: nil
        )
    }

    private static func localProgress(
        from progress: DownloadProgress,
        method: LocalDiarizationMethod
    ) -> LocalDiarizationProgress {
        switch progress.phase {
        case .listing:
            return LocalDiarizationProgress(method: method, phase: .preparing)
        case .downloading:
            return LocalDiarizationProgress(
                method: method,
                phase: .downloading,
                fractionCompleted: progress.fractionCompleted
            )
        case .compiling:
            return LocalDiarizationProgress(
                method: method,
                phase: .loading,
                fractionCompleted: progress.fractionCompleted
            )
        }
    }

    private static func offlineVBxAssetsExist(
        at directory: URL,
        fileManager: FileManager
    ) -> Bool {
        let repoDirectory = directory.appendingPathComponent(
            Repo.diarizer.folderName,
            isDirectory: true
        )
        let requiredModelFiles = [
            ModelNames.OfflineDiarizer.segmentationFile,
            ModelNames.OfflineDiarizer.fbankFile,
            ModelNames.OfflineDiarizer.embeddingFile,
            ModelNames.OfflineDiarizer.pldaRhoFile
        ]
        guard requiredModelFiles.allSatisfy({ modelFile in
            LocalDiarizationAssetValidator.compiledModelBundleIsValid(
                at: repoDirectory.appendingPathComponent(modelFile),
                fileManager: fileManager
            )
        }) else {
            return false
        }

        let parameterLocations = [
            directory.appendingPathComponent(ModelNames.OfflineDiarizer.pldaParameters),
            repoDirectory.appendingPathComponent(ModelNames.OfflineDiarizer.pldaParameters)
        ]
        return parameterLocations.contains {
            LocalDiarizationAssetValidator.pldaParametersAreValid(at: $0)
        }
    }

    private static func lseendModelURL(at directory: URL) -> URL {
        let variant = LSEENDVariant.dihard3
        let modelRelativePath = variant.fileName(forStep: .step500ms)
        let fullRelativePath = variant.repo.subPath.map {
            "\($0)/\(modelRelativePath)"
        } ?? modelRelativePath
        return directory
            .appendingPathComponent(variant.repo.folderName, isDirectory: true)
            .appendingPathComponent(fullRelativePath, isDirectory: false)
    }

    private static func lseendAssetsExist(
        at directory: URL,
        fileManager: FileManager
    ) -> Bool {
        LocalDiarizationAssetValidator.compiledModelBundleIsValid(
            at: lseendModelURL(at: directory),
            fileManager: fileManager
        )
    }
}

private actor OfflineVBxRunner: LocalDiarizationRunner {
    /// The models are loaded once, under the model-hub gate, before this runner
    /// is constructed. `OfflineDiarizerManager` itself is not Sendable, so it is
    /// built here — inside the actor — from those already-loaded models rather
    /// than being passed across an isolation boundary.
    private var models: OfflineDiarizerModels?

    init(models: OfflineDiarizerModels) {
        self.models = models
    }

    func process(
        audioURL: URL,
        method: LocalDiarizationMethod,
        progressHandler: @escaping LocalDiarizationProgressHandler
    ) async throws -> LocalDiarizationResult {
        try Task.checkCancellation()
        guard let models else { throw LocalDiarizationError.runnerUnavailable }
        let result = try await Self.process(
            models: models,
            audioURL: audioURL,
            progressHandler: progressHandler
        )
        try Task.checkCancellation()

        let intervals = result.segments.map { segment in
            LocalDiarizationInterval(
                speakerID: segment.speakerId,
                startTime: TimeInterval(segment.startTimeSeconds),
                endTime: TimeInterval(segment.endTimeSeconds),
                confidence: Self.finiteDouble(segment.qualityScore)
            )
        }
        return LocalDiarizationResult(intervals: intervals)
    }

    func cleanup() async {
        models = nil
    }

    /// `OfflineDiarizerManager` is not Sendable, so it is created and consumed
    /// entirely inside this nonisolated call rather than stored on the actor.
    /// Construction is cheap — `initialize(models:)` just retains the already
    /// loaded models — so the expensive, network-capable load still happens
    /// exactly once, inside `FluidAudioModelHubGate` at `makeRunner` time.
    private nonisolated static func process(
        models: OfflineDiarizerModels,
        audioURL: URL,
        progressHandler: @escaping LocalDiarizationProgressHandler
    ) async throws -> DiarizationResult {
        let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
        manager.initialize(models: models)
        return try await manager.process(audioURL) { processed, total in
            let fraction = total > 0 ? Double(processed) / Double(total) : nil
            progressHandler(
                LocalDiarizationProgress(
                    method: .offlineVBx,
                    phase: .processing,
                    fractionCompleted: fraction
                )
            )
        }
    }

    private static func finiteDouble(_ value: Float) -> Double? {
        let result = Double(value)
        return result.isFinite ? result : nil
    }
}

private actor LSEENDRunner: LocalDiarizationRunner {
    private var diarizer: LSEENDDiarizer?

    init(diarizer: LSEENDDiarizer) {
        self.diarizer = diarizer
    }

    func process(
        audioURL: URL,
        method: LocalDiarizationMethod,
        progressHandler: @escaping LocalDiarizationProgressHandler
    ) async throws -> LocalDiarizationResult {
        try Task.checkCancellation()
        guard let diarizer else { throw LocalDiarizationError.runnerUnavailable }
        let timeline = try diarizer.processComplete(
            audioFileURL: audioURL,
            keepingEnrolledSpeakers: false,
            finalizeOnCompletion: true,
            progressCallback: { processed, total, _ in
                let fraction = total > 0 ? Double(processed) / Double(total) : nil
                progressHandler(
                    LocalDiarizationProgress(
                        method: .experimentalLSEEND,
                        phase: .processing,
                        fractionCompleted: fraction
                    )
                )
            }
        )
        try Task.checkCancellation()

        let segments = timeline.speakers.values.flatMap { speaker in
            speaker.finalizedSegments + speaker.tentativeSegments
        }
        if let maximumSpeakerCount = method.maximumSupportedSpeakerCount {
            let speakerCount = Set(segments.map(\.speakerIndex)).count
            guard speakerCount <= maximumSpeakerCount else {
                throw LocalDiarizationError.unsupportedSpeakerCount(
                    method: method,
                    maximum: maximumSpeakerCount
                )
            }
        }

        let intervals = segments.map { segment in
            LocalDiarizationInterval(
                speakerID: "speaker_\(segment.speakerIndex)",
                startTime: TimeInterval(segment.startTime),
                endTime: TimeInterval(segment.endTime)
            )
        }.sorted {
            if $0.startTime == $1.startTime {
                return $0.speakerID < $1.speakerID
            }
            return $0.startTime < $1.startTime
        }
        return LocalDiarizationResult(intervals: intervals)
    }

    func cleanup() async {
        diarizer?.cleanup()
        diarizer = nil
    }
}

private actor Nemotron3Runner: LocalDiarizationRunner {
    /// `Nemotron3Diarizer` is not thread-safe; this actor is its only owner.
    private var diarizer: Nemotron3Diarizer?
    /// The yield between blocks is an actor reentrancy point. A second
    /// `process` arriving there would `reset()` the diarizer under the first
    /// stream and quietly corrupt its speaker timeline, so it is refused.
    private var isProcessing = false

    init(diarizer: Nemotron3Diarizer) {
        self.diarizer = diarizer
    }

    func process(
        audioURL: URL,
        method: LocalDiarizationMethod,
        progressHandler: @escaping LocalDiarizationProgressHandler
    ) async throws -> LocalDiarizationResult {
        try Task.checkCancellation()
        guard let diarizer, !isProcessing else { throw LocalDiarizationError.runnerUnavailable }
        isProcessing = true
        defer { isProcessing = false }
        diarizer.reset()

        // Stream from disk rather than `processComplete`, which needs the whole
        // recording and its spectrogram in memory at once. The SDK documents
        // the two paths as frame-exact. Segments are built as chunks arrive for
        // the same reason: holding every probability grows without bound.
        let reader = try LocalDiarizationAudioReader(url: audioURL)
        var segmenter = StreamingSpeakerActivitySegmenter(numSpeakers: diarizer.config.numSpeakers)
        func collect(_ chunks: [Nemotron3ChunkResult]) {
            for chunk in chunks {
                segmenter.append(probabilities: chunk.probabilities, frameCount: chunk.frameCount)
            }
        }
        // Progress follows audio the model has finished, not audio decoded:
        // decoding runs up to a chunk plus right context ahead of inference,
        // so the read position reaches the end while work remains. Held below
        // 1 until the tail is flushed.
        func reportProgress() {
            let fraction = reader.sourceDuration.map { duration in
                min(segmenter.processedSeconds / duration, 0.99)
            }
            progressHandler(
                LocalDiarizationProgress(method: method, phase: .processing, fractionCompleted: fraction)
            )
        }

        while let samples = try reader.nextBlock() {
            try Task.checkCancellation()
            diarizer.appendAudio(samples)
            collect(try diarizer.processBufferedAudio())
            reportProgress()
            // Inference is synchronous; let cancellation and other work on
            // this executor through between blocks.
            await Task.yield()
            // `cleanup()` may have run during the yield.
            guard self.diarizer != nil else { throw LocalDiarizationError.runnerUnavailable }
        }
        collect(try diarizer.finishStream())
        try Task.checkCancellation()

        let intervals = segmenter.finish()
        progressHandler(
            LocalDiarizationProgress(method: method, phase: .processing, fractionCompleted: 1)
        )
        return LocalDiarizationResult(intervals: intervals)
    }

    func cleanup() async {
        diarizer = nil
    }
}

#endif
