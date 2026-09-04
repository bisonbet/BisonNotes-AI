//
//  AudioRecorderViewModel+Recovery.swift
//  BisonNotes AI
//
//  Coordinated iOS interruption and background recorder recovery.
//

import Foundation
@preconcurrency import AVFoundation

#if os(iOS)
private enum AudioRecoveryActivationOutcome {
	case activated
	case deferred
	case stopped
	case cancelled
}

private enum AudioActivationFailureHandlingOutcome {
	case retry
	case deferred
	case stopped
	case cancelled
}
#endif

extension AudioRecorderViewModel {

	#if os(iOS)
	@MainActor
	func requestAudioRecovery(
		trigger: AudioRecoveryTrigger,
		recordingURL: URL
	) async {
		guard recordingIntentActive, let recordingSessionID else {
			AppLog.shared.audioSession(
				"Ignoring \(trigger.rawValue) recovery without current recording intent",
				level: .debug
			)
			return
		}

		// This pipeline owns the AVAudioRecorder backend only. A live
		// transcription session has no AVAudioRecorder and writes its .m4a at
		// stop(), so every branch below would misread it as a missing segment
		// and terminate the session while LiveTranscriptionService kept its
		// AVAudioEngine tap — and the microphone — running.
		guard !isUsingLiveTranscription else {
			AppLog.shared.audioSession(
				"Ignoring \(trigger.rawValue) recovery for a live transcription session",
				level: .debug
			)
			return
		}

		let standardizedRecordingURL = recordingURL.standardizedFileURL
		guard let currentRecordingURL = self.recordingURL,
			  currentRecordingURL.standardizedFileURL == standardizedRecordingURL else {
			AppLog.shared.audioSession(
				"Ignoring stale \(trigger.rawValue) recovery request for a previous recording",
				level: .debug
			)
			return
		}

		let request = AudioRecoveryRequest(
			recordingSessionID: recordingSessionID,
			trigger: trigger,
			recordingURL: standardizedRecordingURL
		)
		let requestResult = recoveryCoordinator.request(request) { [weak self] request in
			guard let self else { return .cancelled }
			return await self.executeAudioRecovery(request)
		}

		switch requestResult {
		case .started(let requestID):
			AppLog.shared.audioSession(
				"Started audio recovery \(requestID.uuidString) (trigger: \(trigger.rawValue))"
			)
		case .coalesced(let requestID):
			AppLog.shared.audioSession(
				"Coalesced \(trigger.rawValue) into audio recovery \(requestID.uuidString)",
				level: .debug
			)
		case .ignored:
			return
		}

		await recoveryCoordinator.waitForCompletion()
	}

	@MainActor
	private func executeAudioRecovery(
		_ request: AudioRecoveryRequest
	) async -> AudioRecoveryExecutionResult {
		guard isCurrentAudioRecovery(request) else {
			AppLog.shared.audioSession(
				"Cancelled stale audio recovery \(request.id.uuidString)",
				level: .debug
			)
			return .cancelled
		}

		if let recorder = audioRecorder, recorder.isRecording {
			resumeActiveRecorderAfterRecovery(request: request)
			return .recovered
		}

		guard FileManager.default.fileExists(atPath: request.recordingURL.path) else {
			return await terminateAudioRecovery(
				request,
				reason: "Current recording segment is missing",
				notify: false
			)
		}

		guard let finalization = await finalizeCurrentSegmentForRecovery(request) else {
			return .cancelled
		}

		guard isCurrentAudioRecovery(request) else {
			return .cancelled
		}

		guard finalization.isUsable else {
			return await terminateForFailedFinalization(finalization, request: request)
		}

		// iOS ended the interruption without `.shouldResume`, so it has not
		// authorized this app to take the microphone back. Preserve the
		// finalized segment and wait for an event that does, rather than
		// activating against an owner the system never released to us.
		if request.trigger == .interruptionEndedWithoutResume {
			return await deferAudioRecovery(
				request,
				reason: "The interruption ended without authorizing resumption"
			)
		}

		// An unexplained recorder stop while backgrounded is intentionally a
		// preservation/defer event. Known interruption-ended events may attempt
		// activation, which will be classified below if iOS still owns the mic.
		if request.trigger == .unexpectedBackgroundStop, appIsBackgrounding {
			return await deferAudioRecovery(
				request,
				reason: "Recorder stopped in the background without an interruption-ended event"
			)
		}

		return await continueAudioRecovery(request)
	}

	@MainActor
	func isCurrentAudioRecovery(_ request: AudioRecoveryRequest) -> Bool {
		recoveryCoordinator.accepts(request)
			&& recordingIntentActive
			// A fresh interruption that began while this recovery was in flight
			// means iOS has handed the microphone to someone else. Yield instead
			// of burning the activation budget against an owner we cannot
			// preempt; the new interruption's ended event starts a new recovery.
			&& !isInInterruption
			&& recordingSessionID == request.recordingSessionID
			&& recordingURL?.standardizedFileURL == request.recordingURL.standardizedFileURL
	}

	@MainActor
	private func resumeActiveRecorderAfterRecovery(
		request: AudioRecoveryRequest
	) {
		isRecording = true
		isInInterruption = false
		interruptionRecordingURL = nil
		recorderStoppedUnexpectedlyTime = nil
		recordingState = .recording
		startRecordingTimer()
		AppLog.shared.audioSession(
			"Recovery \(request.id.uuidString) found recorder still active; resumed normal state"
		)
	}

	@MainActor
	private func continueAudioRecovery(
		_ request: AudioRecoveryRequest
	) async -> AudioRecoveryExecutionResult {
		switch await activateAudioSessionForRecovery(request) {
		case .activated:
			return await startContinuationRecording(for: request)
		case .deferred:
			return await deferAudioRecovery(
				request,
				reason: "iOS denied microphone activation with insufficient priority"
			)
		case .stopped:
			return .stopped
		case .cancelled:
			return .cancelled
		}
	}

	@MainActor
	private func terminateForFailedFinalization(
		_ finalization: RecordingFinalizationResult,
		request: AudioRecoveryRequest
	) async -> AudioRecoveryExecutionResult {
		if case .rejected(let rejection) = finalization {
			removeOwnedRecordingAttemptArtifact(at: request.recordingURL)
			recordingSegments.removeAll {
				$0.standardizedFileURL == request.recordingURL.standardizedFileURL
			}
			return await terminateAudioRecovery(
				request,
				reason: rejection.userMessage,
				notify: false
			)
		}

		return await terminateAudioRecovery(
			request,
			reason: "Current recording segment could not be finalized",
			notify: false
		)
	}

	@MainActor
	private func activateAudioSessionForRecovery(
		_ request: AudioRecoveryRequest
	) async -> AudioRecoveryActivationOutcome {
		let hadConfiguration = enhancedAudioSessionManager.currentConfiguration != nil
		let requestedConfiguration = EnhancedAudioSessionManager.AudioSessionConfig.backgroundRecording
		let requestedConfigurationEvidence = [
			"category=\(requestedConfiguration.category.rawValue)",
			"mode=\(requestedConfiguration.mode.rawValue)",
			"options=\(requestedConfiguration.options.rawValue)"
		].joined(separator: ",")
		var attempt = 1

		while true {
			guard isCurrentAudioRecovery(request) else {
				return .cancelled
			}

			recoveryCoordinator.updatePhase(.activating, for: request.id)
			do {
				let activated = try await attemptAudioSessionActivation(for: request)
				guard activated else { return .cancelled }
				AppLog.shared.audioSession(
					"Recovery \(request.id.uuidString) activated recording session on attempt \(attempt)"
				)
				return .activated
			} catch {
				let failure = AudioActivationFailure(
					error: error,
					attempt: attempt,
					appIsBackgrounding: appIsBackgrounding
				)
				logAudioActivationFailure(
					failure,
					request: request,
					hadConfiguration: hadConfiguration,
					requestedConfiguration: requestedConfigurationEvidence
				)

				switch await handleAudioActivationFailure(failure, request: request) {
				case .retry:
					attempt += 1
				case .deferred:
					return .deferred
				case .stopped:
					return .stopped
				case .cancelled:
					return .cancelled
				}
			}
		}
	}

	@MainActor
	private func handleAudioActivationFailure(
		_ failure: AudioActivationFailure,
		request: AudioRecoveryRequest
	) async -> AudioActivationFailureHandlingOutcome {
		switch failure.disposition {
		case .deferUntilForeground:
			return .deferred
		case .fail:
			_ = await terminateAudioRecovery(
				request,
				reason: failure.errorDescription ?? "Audio session activation failed",
				notify: true
			)
			return .stopped
		case .retry:
			if failure.category == .mediaServicesReset {
				enhancedAudioSessionManager.resetPreparedSessionAfterMediaServicesReset()
			}
			// No budget check here: `AudioActivationFailure.disposition` is the
			// single owner of the bound and only answers `.retry` while the
			// attempt is under it — an exhausted budget arrives as `.fail`.
			do {
				try await recoverySleeper.sleep(for: min(Double(failure.attempt) * 0.5, 2.0))
				return .retry
			} catch {
				return .cancelled
			}
		}
	}

	@MainActor
	private func attemptAudioSessionActivation(
		for request: AudioRecoveryRequest
	) async throws -> Bool {
		try await enhancedAudioSessionManager.prepareBackgroundRecordingForRecovery()
		guard recoveryCoordinator.accepts(request), recordingIntentActive else {
			return false
		}
		try enhancedAudioSessionManager.activatePreparedSession()
		return true
	}

	@MainActor
	private func logAudioActivationFailure(
		_ failure: AudioActivationFailure,
		request: AudioRecoveryRequest,
		hadConfiguration: Bool,
		requestedConfiguration: String
	) {
		let configuration = enhancedAudioSessionManager.currentConfiguration
		let configurationEvidence = configuration.map {
			"category=\($0.category.rawValue),mode=\($0.mode.rawValue),options=\($0.options.rawValue)"
		} ?? "none"
		AppLog.shared.audioSession(
			"Audio recovery \(request.id.uuidString) activation failure: "
			+ "trigger=\(request.trigger.rawValue), attempt=\(failure.attempt), "
			+ "disposition=\(failure.disposition.rawValue), category=\(failure.category.rawValue), "
			+ "domain=\(failure.domain), code=\(failure.code), "
			+ "background=\(appIsBackgrounding), recorderPresent=\(audioRecorder != nil), "
			+ "recorderActive=\(audioRecorder?.isRecording == true), recoveryPhase=\(recoveryCoordinator.phase.rawValue), "
			+ "configurationPresentBefore=\(hadConfiguration), configuration=\(configurationEvidence), "
			+ "requestedConfiguration=\(requestedConfiguration), "
			+ "routeChange=\(lastRouteChangeReason), "
			+ "routeInput=\(enhancedAudioSessionManager.getActiveInput()?.portType.rawValue ?? "none")"
			+ ", routeOutputs=\(enhancedAudioSessionManager.currentOutputTypesForDiagnostics().joined(separator: ","))",
			level: .error
		)
	}

	@MainActor
	private func finalizeCurrentSegmentForRecovery(
		_ request: AudioRecoveryRequest
	) async -> RecordingFinalizationResult? {
		recoveryCoordinator.updatePhase(.finalizing, for: request.id)
		isRecording = false
		stopRecordingTimer()

		let recorder = audioRecorder
		audioRecorder = nil
		isFinalizingRecoverySegment = true
		recoveryFinalizedSegmentURLs.insert(request.recordingURL.standardizedFileURL)
		if recorder != nil {
			recorder?.stop()
		}
		defer { isFinalizingRecoverySegment = false }

		guard recoveryCoordinator.accepts(request) else { return nil }
		let result = await RecordingFinalizationPolicy.inspect(
			url: request.recordingURL,
			delegateSucceeded: true
		)
		if case .usable(let fileSize, let duration) = result {
			if !recordingSegments.contains(where: {
				$0.standardizedFileURL == request.recordingURL.standardizedFileURL
			}) {
				recordingSegments.append(request.recordingURL)
			}
			AppLog.shared.audioSession(
				"Recovery \(request.id.uuidString) finalized segment: \(fileSize) bytes, \(duration)s"
			)
		}
		return result
	}

	#endif
}
