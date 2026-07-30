import Foundation
@preconcurrency import AVFoundation

extension AudioRecorderViewModel {
    enum LiveTranscriptionFallbackBackend: Equatable {
        case macAudioEngine
        case avAudioRecorder
    }

    static var liveTranscriptionFallbackBackend: LiveTranscriptionFallbackBackend {
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
            let selectedQuality = AudioQuality.whisperOptimized
            let settings = selectedQuality.settings
            do {
                audioRecorder = try AVAudioRecorder(url: url, settings: settings)
                audioRecorder?.delegate = self
                audioRecorder?.isMeteringEnabled = true
                audioRecorder?.record()
                markRecordingStarted()
            } catch {
                finishRecordingStartup()
                errorMessage = "Failed to start recording: \(error.localizedDescription)"
            }
        }
    }
}
