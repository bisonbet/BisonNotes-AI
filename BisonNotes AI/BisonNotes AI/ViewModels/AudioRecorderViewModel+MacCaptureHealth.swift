//
//  AudioRecorderViewModel+MacCaptureHealth.swift
//  BisonNotes AI
//
//  Confirms that Mac input buffers reach durable scratch media and rebuilds
//  the input engine when a present-but-silent device stalls.
//

#if targetEnvironment(macCatalyst) || os(macOS)

import Foundation

extension AudioRecorderViewModel {
    private static let firstMicrophoneBufferTimeout: TimeInterval = 5
    private static let microphoneStallTimeout: TimeInterval = 5
    private static let maximumAutomaticCaptureRecoveryAttempts = 2

    func startCatalystCaptureHealthMonitoring() {
        stopCatalystCaptureHealthMonitoring()
        catalystCaptureHealthTimer = Timer.scheduledTimer(
            withTimeInterval: 1,
            repeats: true
        ) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let isCapturing = self.isStartingRecording || self.isRecording
            guard isCapturing, !self.isPaused else { return }

            let assessment = self.catalystCaptureHealth.assessment(
                firstBufferTimeout: Self.firstMicrophoneBufferTimeout,
                stallTimeout: Self.microphoneStallTimeout
            )
            switch assessment {
            case .noInitialAudio, .stalled, .writeFailed:
                timer.invalidate()
                self.catalystCaptureHealthTimer = nil
                Task { @MainActor [weak self] in
                    await self?.handleCatalystCaptureHealthFailure(assessment)
                }
            case .inactive, .starting, .healthy:
                break
            }
        }
    }

    func stopCatalystCaptureHealthMonitoring() {
        catalystCaptureHealthTimer?.invalidate()
        catalystCaptureHealthTimer = nil
    }

    func handleCatalystFirstSuccessfulWrite() {
        let health = catalystCaptureHealth.snapshot()
        let inputName = enhancedAudioSessionManager.getActiveInput()?.portName ?? "system default"
        AppLog.shared.recording(
            "Mac microphone first buffer committed from \(inputName) " +
            "(segmentFrames=\(health.segmentFramesWritten), totalFrames=\(health.totalFramesWritten))"
        )
        if isStartingRecording {
            catalystSystemAudioCapture?.setPaused(false)
            markRecordingStarted()
            return
        }

        #if os(macOS)
        if let pendingRecovery = pendingMacInputRecovery {
            pendingMacInputRecovery = nil
            catalystAwaitingRecoveryBuffer = false
            Task { @MainActor [weak self] in
                await self?.finishNativeMacInputRecovery(
                    keepPaused: pendingRecovery.keepPaused,
                    notify: pendingRecovery.notify
                )
            }
            return
        }
        #endif

        if catalystAwaitingRecoveryBuffer {
            catalystAwaitingRecoveryBuffer = false
            catalystSystemAudioCapture?.setPaused(false)
            recordingState = .recording
            startRecordingTimer()
            errorMessage = "Recording continued after reconnecting the microphone."
        }
    }

    @MainActor
    private func handleCatalystCaptureHealthFailure(
        _ assessment: RecordingCaptureHealthAssessment
    ) async {
        guard isStartingRecording || isRecording else { return }
        let health = catalystCaptureHealth.snapshot()
        let inputName = enhancedAudioSessionManager.getActiveInput()?.portName ?? "system default"
        AppLog.shared.recording(
            "Mac microphone capture unhealthy on \(inputName): \(assessment) " +
            "(segmentFrames=\(health.segmentFramesWritten), totalFrames=\(health.totalFramesWritten))",
            level: .error
        )

        guard catalystAutomaticRecoveryAttempts < Self.maximumAutomaticCaptureRecoveryAttempts else {
            await stopAfterExhaustingCaptureRecovery(inputName: inputName)
            return
        }

        catalystAutomaticRecoveryAttempts += 1
        let attempt = catalystAutomaticRecoveryAttempts
        errorMessage = "\(inputName) stopped providing audio. Reconnecting (attempt \(attempt) of " +
            "\(Self.maximumAutomaticCaptureRecoveryAttempts))…"
        catalystSystemAudioCapture?.setPaused(true)
        stopRecordingTimer()

        if isStartingRecording {
            await restartCatalystCaptureDuringStartup()
            return
        }
        await restartActiveCatalystCapture()
    }

    @MainActor
    private func stopAfterExhaustingCaptureRecovery(inputName: String) async {
        if isStartingRecording {
            await abortCatalystRecordingStartup(
                reason: "The selected microphone did not provide any audio after automatic recovery."
            )
        } else {
            errorMessage = "Recording stopped because \(inputName) stopped providing audio. " +
                "Any audio captured before the failure will still be saved."
            stopRecording()
        }
    }

    @MainActor
    private func restartCatalystCaptureDuringStartup() async {
        sealCatalystScratchSegment()
        do {
            guard let finalURL = recordingURL else { throw CocoaError(.fileNoSuchFile) }
            try startCatalystContinuation(at: finalURL)
        } catch {
            await abortCatalystRecordingStartup(
                reason: "The microphone could not be restarted: \(error.localizedDescription)"
            )
        }
    }

    @MainActor
    private func restartActiveCatalystCapture() async {
        catalystAwaitingRecoveryBuffer = true
        recordingState = .waitingForMicrophone(disconnectedAt: Date())
        #if os(macOS)
        await recoverNativeMacInput(keepPaused: false, forceRestart: true)
        #else
        sealCatalystScratchSegment()
        do {
            guard let finalURL = recordingURL else { throw CocoaError(.fileNoSuchFile) }
            try startCatalystContinuation(at: finalURL)
        } catch {
            errorMessage = "Recording stopped because the microphone could not be restarted: " +
                "\(error.localizedDescription)"
            stopRecording()
        }
        #endif
    }

    @MainActor
    private func abortCatalystRecordingStartup(reason: String) async {
        sealCatalystScratchSegment()
        _ = await stopCatalystSystemAudioCapture()
        let scratchURLs = allCatalystScratchURLs()
        let recoveryURL = preserveCatalystRecoveryFiles(
            scratchURLs: scratchURLs,
            systemAudioURL: catalystSystemAudioURL,
            finalURL: recordingURL,
            reason: reason
        )

        finishRecordingStartup()
        isRecording = false
        recordingState = .idle
        catalystScratchRecordingURL = nil
        catalystScratchSegmentURLs = []
        catalystSystemAudioURL = nil
        catalystAwaitingRecoveryBuffer = false
        resetRecordingLocation()
        recordingStartedAt = nil
        errorMessage = reason + (recoveryURL == nil ? "" : " Diagnostic recovery files were preserved.")
    }
}

#endif
