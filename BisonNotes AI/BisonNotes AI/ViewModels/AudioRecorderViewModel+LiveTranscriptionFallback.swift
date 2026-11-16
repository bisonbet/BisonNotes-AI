import Foundation
@preconcurrency import AVFoundation

extension AudioRecorderViewModel {
    enum LiveTranscriptionFallbackBackend: Equatable {
        case macAudioEngine
        case avAudioRecorder
    }

    nonisolated static var liveTranscriptionFallbackBackend: LiveTranscriptionFallbackBackend {
        #if os(macOS)
        return .macAudioEngine
        #else
        return .avAudioRecorder
        #endif
    }

    @MainActor
    func startFallbackRecordingAfterLiveTranscriptionFailure(
        at url: URL,
        backend: LiveTranscriptionFallbackBackend
    ) async {
        switch backend {
        case .macAudioEngine:
            #if os(macOS)
            await setupMacRecording(at: url)
            #else
            assertionFailure("The Mac recording fallback is unavailable on this platform")
            finishRecordingStartup()
            #endif
        case .avAudioRecorder:
            beginAVAudioRecorderStartup(at: url)
            await recorderStartupTask?.value
        }
    }
}
