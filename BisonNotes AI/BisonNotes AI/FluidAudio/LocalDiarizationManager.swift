import Foundation

#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif

enum LocalDiarizationError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedMethod(LocalDiarizationMethod)
    case downloadRequired(LocalDiarizationMethod)
    case modelPreparationFailed(LocalDiarizationMethod)
    case runnerUnavailable
    case fluidAudioUnavailable
    case audioFileNotFound
    case experimentalDurationLimit
    case unsupportedSpeakerCount(method: LocalDiarizationMethod, maximum: Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedMethod:
            return "Speaker labeling method is not supported."
        case .downloadRequired:
            return "Download Required: prepare the selected speaker model before labeling audio."
        case .modelPreparationFailed:
            return "The selected speaker model could not be verified after preparation."
        case .runnerUnavailable:
            return "The selected speaker labeling runner is unavailable."
        case .fluidAudioUnavailable:
            return "Local speaker labeling is unavailable in this build."
        case .audioFileNotFound:
            return "The source audio is no longer available for speaker labeling."
        case .experimentalDurationLimit:
            return "LS-EEND speaker labeling is limited to complete files up to one hour."
        case let .unsupportedSpeakerCount(method, maximum):
            return "\(method.displayName) supports up to \(maximum) speakers."
        }
    }
}

/// Coordinates independent Offline VBx and LS-EEND model caches/runners.
///
/// This actor is deliberately not MainActor-isolated. Its runners perform
/// complete-file inference on their own actor executors, and every lifecycle
/// path checks cancellation and releases the runner before returning.
actor LocalDiarizationManager: LocalDiarizationModelManaging, LocalDiarizing {
    static let shared = LocalDiarizationManager()

    private let provider: any LocalDiarizationModelProvider
    private let maximumExperimentalDuration: TimeInterval
    private var preparationTasks: [String: Task<Void, Error>] = [:]
    private var statuses: [String: LocalDiarizationModelStatus] = [:]

    init(
        provider: any LocalDiarizationModelProvider = LocalDiarizationModelProviderFactory.makeDefault(),
        maximumExperimentalDuration: TimeInterval =
            LocalDiarizationMethod.experimentalLSEEND.maximumSupportedDuration ?? 3_600
    ) {
        self.provider = provider
        self.maximumExperimentalDuration = maximumExperimentalDuration
    }

    func modelStatus(for method: LocalDiarizationMethod) async -> LocalDiarizationModelStatus {
        let ready = await provider.isReady(for: method)
        if let status = statuses[method.rawValue], status.state == .preparing {
            return status
        }

        let state: LocalDiarizationModelState = ready ? .ready : .downloadRequired
        let status = LocalDiarizationModelStatus(method: method, state: state, fractionCompleted: ready ? 1 : nil)
        statuses[method.rawValue] = status
        return status
    }

    func prepareModel(
        for method: LocalDiarizationMethod,
        progress: @escaping @Sendable (LocalDiarizationProgress) -> Void
    ) async throws {
        if let existingTask = preparationTasks[method.rawValue] {
            try await existingTask.value
            return
        }

        statuses[method.rawValue] = LocalDiarizationModelStatus(
            method: method,
            state: .preparing,
            fractionCompleted: nil
        )

        let task = Task { [provider] in
            try await provider.prepare(
                for: method,
                forceRedownload: false,
                progressHandler: { progressValue in
                    progress(progressValue)
                }
            )
        }
        preparationTasks[method.rawValue] = task
        defer { preparationTasks[method.rawValue] = nil }

        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()

            guard await provider.isReady(for: method) else {
                statuses[method.rawValue] = LocalDiarizationModelStatus(
                    method: method,
                    state: .failed,
                    fractionCompleted: nil
                )
                throw LocalDiarizationError.modelPreparationFailed(method)
            }

            statuses[method.rawValue] = LocalDiarizationModelStatus(
                method: method,
                state: .ready,
                fractionCompleted: 1
            )
        } catch {
            let state: LocalDiarizationModelState = error is CancellationError ? .cancelled : .failed
            statuses[method.rawValue] = LocalDiarizationModelStatus(
                method: method,
                state: state,
                fractionCompleted: nil
            )
            throw error
        }
    }

    func cancelModelPreparation(for method: LocalDiarizationMethod) async {
        preparationTasks[method.rawValue]?.cancel()
        if preparationTasks[method.rawValue] != nil {
            statuses[method.rawValue] = LocalDiarizationModelStatus(
                method: method,
                state: .cancelled,
                fractionCompleted: nil
            )
        }
    }

    /// Inference runners are created per complete-file call and cleaned up in
    /// `diarize`; unloading here intentionally preserves verified disk caches.
    func unloadModel(for method: LocalDiarizationMethod) async {
        // There is no retained SDK runner to unload at this boundary.
    }

    func deleteModel(for method: LocalDiarizationMethod) async throws {
        preparationTasks[method.rawValue]?.cancel()
        preparationTasks[method.rawValue] = nil
        try await provider.delete(for: method)
        statuses[method.rawValue] = LocalDiarizationModelStatus(
            method: method,
            state: .downloadRequired,
            fractionCompleted: nil
        )
    }

    func diarize(
        audioURL: URL,
        method: LocalDiarizationMethod,
        audioDuration: TimeInterval?,
        progress: @escaping @Sendable (LocalDiarizationProgress) -> Void
    ) async throws -> LocalDiarizationResult {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw LocalDiarizationError.audioFileNotFound
        }
        try Task.checkCancellation()

        guard await provider.isReady(for: method) else {
            statuses[method.rawValue] = LocalDiarizationModelStatus(
                method: method,
                state: .downloadRequired,
                fractionCompleted: nil
            )
            throw LocalDiarizationError.downloadRequired(method)
        }

        let resolvedDuration: TimeInterval
        if let audioDuration {
            resolvedDuration = audioDuration
        } else {
            resolvedDuration = await Self.audioDuration(for: audioURL)
        }
        if method == .experimentalLSEEND,
           resolvedDuration > maximumExperimentalDuration {
            throw LocalDiarizationError.experimentalDurationLimit
        }

        let runner = try await provider.makeRunner(for: method)
        do {
            try Task.checkCancellation()
            let result = try await runner.process(
                audioURL: audioURL,
                method: method,
                progressHandler: progress
            )
            try Task.checkCancellation()
            await runner.cleanup()

            if result.audioDuration == nil, resolvedDuration > 0 {
                return LocalDiarizationResult(
                    intervals: result.intervals,
                    audioDuration: resolvedDuration
                )
            }
            return result
        } catch {
            await runner.cleanup()
            throw error
        }
    }

    private static func audioDuration(for url: URL) async -> TimeInterval {
        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: url)
        return (try? await asset.load(.duration).seconds).flatMap { value in
            value.isFinite && value > 0 ? value : nil
        } ?? 0
        #else
        return 0
        #endif
    }
}
