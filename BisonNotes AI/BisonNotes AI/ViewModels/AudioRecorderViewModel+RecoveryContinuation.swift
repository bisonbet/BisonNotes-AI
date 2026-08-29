//
//  AudioRecorderViewModel+RecoveryContinuation.swift
//  BisonNotes AI
//
//  Continuation, deferral, and terminal persistence for iOS recovery.
//

import Foundation
@preconcurrency import AVFoundation

#if os(iOS)
extension AudioRecorderViewModel {

	@MainActor
	func startContinuationRecording(
		for request: AudioRecoveryRequest
	) async -> AudioRecoveryExecutionResult {
		guard recoveryCoordinator.accepts(request), recordingIntentActive else {
			return .cancelled
		}

		recoveryCoordinator.updatePhase(.startingContinuation, for: request.id)
		let nextSegmentIndex = currentSegmentIndex + 1
		let newSegmentURL = createSegmentURL(
			baseURL: mainRecordingURL ?? request.recordingURL,
			segmentIndex: nextSegmentIndex
		)
		registerRecordingAttemptArtifact(at: newSegmentURL)
		AppLog.shared.audioSession(
			"Recovery \(request.id.uuidString) creating continuation segment \(nextSegmentIndex) after activation"
		)

		var continuationRecorder: AVAudioRecorder?
		do {
			let recorder = try makeRecoveryContinuationRecorder(at: newSegmentURL)
			continuationRecorder = recorder
			audioRecorder = recorder
			try await recoverySleeper.sleep(for: 0.15)

			guard recoveryCoordinator.accepts(request), recordingIntentActive else {
				stopAndReleaseRecoveryRecorder(continuationRecorder, at: newSegmentURL)
				return .cancelled
			}
			guard recorder.isRecording else {
				throw AudioSessionRecoveryError.recorderDidNotStart
			}

			markContinuationRecordingStarted(
				url: newSegmentURL,
				segmentIndex: nextSegmentIndex
			)
			AppLog.shared.audioSession(
				"Recovery \(request.id.uuidString) started one continuation segment"
			)
			return .recovered
		} catch is CancellationError {
			stopAndReleaseRecoveryRecorder(continuationRecorder, at: newSegmentURL)
			return .cancelled
		} catch {
			stopAndReleaseRecoveryRecorder(continuationRecorder, at: newSegmentURL)
			return await terminateAudioRecovery(
				request,
				reason: "Continuation recorder failed to start: \(error.localizedDescription)",
				notify: true
			)
		}
	}

	@MainActor
	private func makeRecoveryContinuationRecorder(at url: URL) throws -> AVAudioRecorder {
		let recorder = try AVAudioRecorder(
			url: url,
			settings: AudioQuality.whisperOptimized.settings
		)
		recorder.delegate = self
		recorder.isMeteringEnabled = true
		AppFileProtection.apply(to: url)
		guard recorder.record() else {
			throw AudioSessionRecoveryError.recorderDidNotStart
		}
		return recorder
	}

	@MainActor
	private func markContinuationRecordingStarted(
		url: URL,
		segmentIndex: Int
	) {
		currentSegmentIndex = segmentIndex
		recordingSegments.append(url)
		recordingURL = url
		isRecording = true
		recordingState = .recording
		isInInterruption = false
		interruptionRecordingURL = nil
		recorderStoppedUnexpectedlyTime = nil
		lastCheckpointTime = Date()
		errorMessage = nil
		startRecordingTimer()
	}

	@MainActor
	private func stopAndReleaseRecoveryRecorder(
		_ recorder: AVAudioRecorder?,
		at url: URL
	) {
		isFinalizingRecoverySegment = true
		recorder?.stop()
		isFinalizingRecoverySegment = false
		if audioRecorder === recorder {
			audioRecorder = nil
		}
		removeOwnedRecordingAttemptArtifact(at: url)
	}

	@MainActor
	func deferAudioRecovery(
		_ request: AudioRecoveryRequest,
		reason: String
	) async -> AudioRecoveryExecutionResult {
		guard recoveryCoordinator.accepts(request),
			  recordingSessionID == request.recordingSessionID else {
			return .cancelled
		}

		recoveryCoordinator.updatePhase(.deferredUntilForeground, for: request.id)
		interruptionEndHandled = true
		isRecording = false
		stopRecordingTimer()
		audioRecorder = nil
		isInInterruption = false
		interruptionRecordingURL = request.recordingURL
		recorderStoppedUnexpectedlyTime = nil
		recordingState = .interrupted(reason: .systemInterruption, startedAt: Date())
		errorMessage = "Recording paused. Bring BisonNotes AI to the foreground to continue."
		AppLog.shared.audioSession(
			"Deferred audio recovery \(request.id.uuidString) until foreground: \(reason)"
		)
		await scheduleRecordingInterruptedNotification(recordingURL: request.recordingURL)
		return .deferredUntilForeground
	}

	@MainActor
	func terminateAudioRecovery(
		_ request: AudioRecoveryRequest,
		reason: String,
		notify: Bool
	) async -> AudioRecoveryExecutionResult {
		guard recoveryCoordinator.accepts(request),
			  recordingSessionID == request.recordingSessionID else {
			return .cancelled
		}

		recoveryCoordinator.updatePhase(.stoppedOrRecovered, for: request.id)
		resetRecordingStateAfterRecoveryFailure(reason: reason)

		recordingSegments = existingRecordingSegments()
		recordingURL = recordingSegments.last
		let hasPreservedAudio = !recordingSegments.isEmpty
		await persistTerminatedRecoverySegments(for: request, reason: reason)
		guard recoveryCoordinator.accepts(request),
			  recordingSessionID == request.recordingSessionID else {
			return .cancelled
		}

		if notify {
			await sendInterruptionNotification(
				success: hasPreservedAudio,
				reason: reason,
				filename: request.recordingURL.lastPathComponent
			)
			guard recoveryCoordinator.accepts(request),
				  recordingSessionID == request.recordingSessionID else {
				return .cancelled
			}
		}
		AppLog.shared.audioSession(
			"Terminated audio recovery \(request.id.uuidString); preservedSegments=\(recordingSegments.count)"
		)
		return .stopped
	}

	@MainActor
	private func resetRecordingStateAfterRecoveryFailure(reason: String) {
		recordingIntentActive = false
		isRecording = false
		isStartingRecording = false
		stopRecordingTimer()
		stopBackgroundTimeMonitoring()
		audioRecorder = nil
		isInInterruption = false
		interruptionRecordingURL = nil
		recorderStoppedUnexpectedlyTime = nil
		recordingState = .idle
		errorMessage = "Recording stopped: \(reason)"
	}

	@MainActor
	private func persistTerminatedRecoverySegments(
		for request: AudioRecoveryRequest,
		reason: String
	) async {
		if recordingSegments.count > 1 {
			await mergeRecordingSegments(
				expectedRecordingSessionID: request.recordingSessionID,
				expectedRecoveryRequestID: request.id
			)
		} else if let savedURL = recordingSegments.first {
			await recoverInterruptedRecording(
				url: savedURL,
				reason: reason,
				expectedRecordingSessionID: request.recordingSessionID,
				expectedRecoveryRequestID: request.id
			)
		}
	}

	@MainActor
	private func existingRecordingSegments() -> [URL] {
		var validSegments: [URL] = []
		for segment in recordingSegments where FileManager.default.fileExists(atPath: segment.path) {
			let standardizedSegment = segment.standardizedFileURL
			if !validSegments.contains(where: { $0.standardizedFileURL == standardizedSegment }) {
				validSegments.append(segment)
			}
		}
		return validSegments
	}
}
#endif
