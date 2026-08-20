//
//  AudioRecorderViewModel+MacCaptureHealth.swift
//  BisonNotes AI
//
//  Confirms that Mac input buffers reach durable scratch media and rebuilds
//  the input engine when a present-but-silent device stalls.
//

#if os(macOS)

import Foundation

extension AudioRecorderViewModel {
    private static let firstMicrophoneBufferTimeout: TimeInterval = 5
    private static let microphoneStallTimeout: TimeInterval = 5
    private static let maximumAutomaticCaptureRecoveryAttempts = 2

    func startMacCaptureHealthMonitoring() {
        stopMacCaptureHealthMonitoring()
        // The run loop retains a scheduled timer until it is invalidated, so a
        // dropped property does not stop it. The nonisolated deinit cannot
        // invalidate it either (invalidate() must run on the installing thread),
        // so the block self-invalidates on its own run loop once the owner is gone.
        macCaptureHealthTimer = Timer.scheduledTimer(
            withTimeInterval: 1,
            repeats: true
        ) { [weak self] timer in
            guard self != nil else { timer.invalidate(); return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let isCapturing = self.isStartingRecording || self.isRecording
                guard isCapturing, !self.isPaused else { return }

                let assessment = self.macCaptureHealth.assessment(
                    firstBufferTimeout: Self.firstMicrophoneBufferTimeout,
                    stallTimeout: Self.microphoneStallTimeout
                )
                switch assessment {
                case .noInitialAudio, .stalled, .writeFailed:
                    self.macCaptureHealthTimer?.invalidate()
                    self.macCaptureHealthTimer = nil
                    await self.handleMacCaptureHealthFailure(assessment)
                case .inactive, .starting, .healthy:
                    break
                }
            }
        }
    }

    func stopMacCaptureHealthMonitoring() {
        macCaptureHealthTimer?.invalidate()
        macCaptureHealthTimer = nil
    }

    func handleMacFirstSuccessfulWrite() {
        let health = macCaptureHealth.snapshot()
        let inputName = enhancedAudioSessionManager.getActiveInput()?.portName ?? "system default"
        AppLog.shared.recording(
            "Mac microphone first buffer committed from \(inputName) " +
            "(segmentFrames=\(health.segmentFramesWritten), totalFrames=\(health.totalFramesWritten))"
        )
        if isStartingRecording {
            macSystemAudioCapture?.setPaused(false)
            markRecordingStarted()
            return
        }

        #if os(macOS)
        if let pendingRecovery = pendingMacInputRecovery {
            pendingMacInputRecovery = nil
            macAwaitingRecoveryBuffer = false
            Task { @MainActor [weak self] in
                await self?.finishNativeMacInputRecovery(
                    keepPaused: pendingRecovery.keepPaused,
                    notify: pendingRecovery.notify
                )
            }
            return
        }
        #endif

        if macAwaitingRecoveryBuffer {
            macAwaitingRecoveryBuffer = false
            macSystemAudioCapture?.setPaused(false)
            recordingState = .recording
            startRecordingTimer()
            errorMessage = "Recording continued after reconnecting the microphone."
        }
    }

    @MainActor
    private func handleMacCaptureHealthFailure(
        _ assessment: RecordingCaptureHealthAssessment
    ) async {
        guard isStartingRecording || isRecording else { return }
        let health = macCaptureHealth.snapshot()
        let inputName = enhancedAudioSessionManager.getActiveInput()?.portName ?? "system default"
        AppLog.shared.recording(
            "Mac microphone capture unhealthy on \(inputName): \(assessment) " +
            "(segmentFrames=\(health.segmentFramesWritten), totalFrames=\(health.totalFramesWritten))",
            level: .error
        )

        guard macAutomaticRecoveryAttempts < Self.maximumAutomaticCaptureRecoveryAttempts else {
            await stopAfterExhaustingCaptureRecovery(inputName: inputName)
            return
        }

        macAutomaticRecoveryAttempts += 1
        let attempt = macAutomaticRecoveryAttempts
        if isStartingRecording,
           assessment == .noInitialAudio,
           attempt == 1,
           enhancedAudioSessionManager.hasPreferredInput() {
            // Keep the persisted preference so the user's selected device is
            // restored for a later recording, but avoid retrying a present-but-
            // silent USB route indefinitely during this startup.
            try? await enhancedAudioSessionManager.clearPreferredInput()
            AppLog.shared.audioSession(
                "Preferred Mac input produced no initial audio; retrying startup with the system default",
                level: .error
            )
        }
        errorMessage = "\(inputName) stopped providing audio. Reconnecting (attempt \(attempt) of " +
            "\(Self.maximumAutomaticCaptureRecoveryAttempts))…"
        macSystemAudioCapture?.setPaused(true)
        stopRecordingTimer()

        if isStartingRecording {
            await restartMacCaptureDuringStartup()
            return
        }
        await restartActiveMacCapture()
    }

    @MainActor
    private func stopAfterExhaustingCaptureRecovery(inputName: String) async {
        if isStartingRecording {
            await abortMacRecordingStartup(
                reason: "The selected microphone did not provide any audio after automatic recovery."
            )
        } else {
            errorMessage = "Recording stopped because \(inputName) stopped providing audio. " +
                "Any audio captured before the failure will still be saved."
            stopRecording()
        }
    }

    @MainActor
    private func restartMacCaptureDuringStartup() async {
        sealMacScratchSegment()
        do {
            guard let finalURL = recordingURL else { throw CocoaError(.fileNoSuchFile) }
            try startMacContinuation(at: finalURL)
        } catch {
            await abortMacRecordingStartup(
                reason: "The microphone could not be restarted: \(error.localizedDescription)"
            )
        }
    }

    @MainActor
    private func restartActiveMacCapture() async {
        macAwaitingRecoveryBuffer = true
        recordingState = .waitingForMicrophone(disconnectedAt: Date())
        #if os(macOS)
        await recoverNativeMacInput(keepPaused: false, forceRestart: true)
        #else
        sealMacScratchSegment()
        do {
            guard let finalURL = recordingURL else { throw CocoaError(.fileNoSuchFile) }
            try startMacContinuation(at: finalURL)
        } catch {
            errorMessage = "Recording stopped because the microphone could not be restarted: " +
                "\(error.localizedDescription)"
            stopRecording()
        }
        #endif
    }

    @MainActor
    private func abortMacRecordingStartup(reason: String) async {
        sealMacScratchSegment()
        _ = await stopMacSystemAudioCapture()
        let scratchURLs = allMacScratchURLs()
        let recoveryURL = preserveMacRecoveryFiles(
            scratchURLs: scratchURLs,
            systemAudioURL: macSystemAudioURL,
            finalURL: recordingURL,
            reason: reason
        )

        finishRecordingStartup()
        isRecording = false
        recordingState = .idle
        macScratchRecordingURL = nil
        macScratchSegmentURLs = []
        macSystemAudioURL = nil
        macAwaitingRecoveryBuffer = false
        resetRecordingLocation()
        recordingStartedAt = nil
        errorMessage = reason + (recoveryURL == nil ? "" : " Diagnostic recovery files were preserved.")
    }
}

#endif
