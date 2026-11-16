import Foundation
@preconcurrency import AVFoundation

/// A recorder is owned only by the worker until startup finishes. Transferring
/// that ownership back avoids sharing a live recorder across executors.
protocol RecorderStartable: AnyObject {
    func record() -> Bool
    func stop()
}

extension AVAudioRecorder: RecorderStartable {}

enum RecorderStartupError: LocalizedError {
    case didNotStart

    var errorDescription: String? { "The audio recorder could not start capturing audio." }
}

enum RecorderStartup {
    /// `record()` can synchronously activate AVAudioSession even when the app
    /// explicitly activated it already. Keep construction and that call off UI.
    @concurrent
    nonisolated static func start<Recorder: RecorderStartable>(
        makeRecorder: @Sendable () throws -> sending Recorder
    ) async throws -> sending Recorder {
        let recorder = try makeRecorder()
        guard recorder.record() else {
            recorder.stop()
            throw RecorderStartupError.didNotStart
        }
        return recorder
    }
}
