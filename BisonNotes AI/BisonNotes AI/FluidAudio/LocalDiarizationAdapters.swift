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
            methodRawValue: method.rawValue,
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

#endif
