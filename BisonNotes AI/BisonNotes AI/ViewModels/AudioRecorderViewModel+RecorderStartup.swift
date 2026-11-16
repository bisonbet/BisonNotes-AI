import Foundation
@preconcurrency import AVFoundation

extension AudioRecorderViewModel {
    func beginAVAudioRecorderStartup(at url: URL) {
        let generation = recordingStartupGeneration
        let previousStartup = recorderStartupTask
        let interruptionEpoch = recorderStartupInterruptionEpoch
        let artifact = recordingAttemptArtifacts.first { $0.url == url.standardizedFileURL }
        recorderStartupTask = Task { @MainActor in
            defer {
                if recordingStartupGeneration == generation { recorderStartupTask = nil }
            }
            await previousStartup?.value
            guard wantsRecorderStartup(generation: generation, url: url) else { return }
            do {
                let recorder = try await makeStartedRecorder(at: url)
                guard wantsRecorderStartup(generation: generation, url: url) else {
                    recorder.stop()
                    await preserveOrRemoveStartupArtifact(artifact)
                    return
                }
                #if os(iOS)
                if isInInterruption || recorderStartupInterruptionEpoch != interruptionEpoch {
                    // Recovery waits for this worker before sealing its file.
                    recorder.stop()
                    finishRecordingStartup()
                    return
                }
                #endif
                guard recorder.isRecording else {
                    recorder.stop()
                    throw RecorderStartupError.didNotStart
                }
                recorder.delegate = self
                audioRecorder = recorder
                AppFileProtection.apply(to: url)
                markRecordingStarted()
            } catch {
                await preserveOrRemoveStartupArtifact(artifact)
                guard wantsRecorderStartup(generation: generation, url: url) else { return }
                #if os(iOS)
                if isInInterruption || recorderStartupInterruptionEpoch != interruptionEpoch {
                    finishRecordingStartup()
                    return
                }
                recordingIntentActive = false
                recoveryCoordinator.invalidateRecordingSession(reason: "recorder startup failed")
                #endif
                finishRecordingStartup()
                recordingState = .idle
                errorMessage = "Failed to start recording: \(error.localizedDescription)"
                AppLog.shared.logError(error, "Recorder startup failed", category: .recording)
                try? await enhancedAudioSessionManager.deactivateSession()
            }
        }
    }

    private func wantsRecorderStartup(generation: UInt64, url: URL) -> Bool {
        guard recordingStartupGeneration == generation, recordingURL == url, isStartingRecording else { return false }
        #if os(iOS)
        return recordingIntentActive
        #else
        return true
        #endif
    }

    private func makeStartedRecorder(at url: URL) async throws -> sending AVAudioRecorder {
        #if DEBUG
        if let recorderStartForTesting { return try await recorderStartForTesting(url) }
        #endif
        return try await RecorderStartup.start {
            let recorder = try AVAudioRecorder(url: url, settings: AudioQuality.whisperOptimized.settings)
            recorder.isMeteringEnabled = true
            AppFileProtection.apply(to: url)
            return recorder
        }
    }

    /// Use the captured ownership, not the possibly newer attempt's registry.
    /// A cancelled start can already have captured usable audio; retain that for
    /// the existing unprocessed-recording recovery, never discard a valid short note.
    private func preserveOrRemoveStartupArtifact(_ artifact: RecordingAttemptArtifact?) async {
        guard let artifact, !artifact.existedBeforeAttempt else { return }
        let result = await RecordingFinalizationPolicy.inspect(url: artifact.url, delegateSucceeded: true)
        guard !result.isUsable else {
            AppLog.shared.recording("Stopped startup retained usable audio for recovery")
            return
        }
        do {
            if FileManager.default.fileExists(atPath: artifact.url.path) {
                try FileManager.default.removeItem(at: artifact.url)
            }
        } catch {
            AppLog.shared.logError(error, "Could not remove unusable startup artifact", category: .recording)
        }
    }
}
