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
		clearDeferredRecoverySnapshot()
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
		// Deliberately do NOT latch interruptionEndHandled here. A deferral is
		// waiting for exactly the event that latch would discard: the system's
		// own .ended/.shouldResume is what authorizes reacquiring the
		// microphone, and swallowing it strands the recording until the user
		// happens to foreground the app.
		interruptionEndHandled = false
		isRecording = false
		stopRecordingTimer()
		audioRecorder = nil
		isInInterruption = false
		interruptionRecordingURL = request.recordingURL
		recorderStoppedUnexpectedlyTime = nil
		recordingState = .interrupted(reason: .systemInterruption, startedAt: Date())
		errorMessage = "Recording paused. Bring BisonNotes AI to the foreground to continue."
		// A deferred recording holds no audio session, so iOS may terminate the
		// app before it is ever resumed. Persist the segment bookkeeping so the
		// next launch can reclaim the captured audio instead of orphaning it.
		persistDeferredRecoverySnapshot()
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
		clearDeferredRecoverySnapshot()
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

	// MARK: - Deferred Recovery Persistence

	/// The on-disk record of a recording parked by `deferAudioRecovery`.
	///
	/// Only file names are stored: the Documents container is relocated between
	/// launches, so an absolute URL captured today does not resolve tomorrow.
	private struct DeferredRecoverySnapshot: Codable {
		let mainRecordingFilename: String?
		let segmentFilenames: [String]
		let currentSegmentIndex: Int
		let deferredAt: Date
	}

	private static var deferredRecoverySnapshotURL: URL? {
		FileManager.default
			.urls(for: .documentDirectory, in: .userDomainMask)
			.first?
			.appendingPathComponent("deferred-recovery.json")
	}

	@MainActor
	func persistDeferredRecoverySnapshot() {
		persistRecoverySnapshot(
			segments: existingRecordingSegments(),
			mainRecordingURL: mainRecordingURL,
			currentSegmentIndex: currentSegmentIndex
		)
	}

	/// Write the trail that lets a later pass reclaim these segments.
	///
	/// Used both when a recovery is deferred and when an in-flight merge is
	/// superseded: in either case nothing in memory points at the segments any
	/// more, so without this they are untracked files on disk.
	@MainActor
	func persistRecoverySnapshot(
		segments: [URL],
		mainRecordingURL: URL?,
		currentSegmentIndex: Int
	) {
		guard let snapshotURL = Self.deferredRecoverySnapshotURL else { return }
		guard !segments.isEmpty else {
			clearDeferredRecoverySnapshot()
			return
		}

		let snapshot = DeferredRecoverySnapshot(
			mainRecordingFilename: mainRecordingURL?.lastPathComponent,
			segmentFilenames: segments.map { $0.lastPathComponent },
			currentSegmentIndex: currentSegmentIndex,
			deferredAt: Date()
		)
		do {
			let data = try JSONEncoder().encode(snapshot)
			try data.write(to: snapshotURL, options: .atomic)
			AppFileProtection.apply(to: snapshotURL)
			AppLog.shared.audioSession(
				"Persisted deferred recovery snapshot for \(segments.count) segment(s)",
				level: .debug
			)
		} catch {
			AppLog.shared.audioSession(
				"Could not persist deferred recovery snapshot: \(error.localizedDescription)",
				level: .error
			)
		}
	}

	@MainActor
	func clearDeferredRecoverySnapshot() {
		guard let snapshotURL = Self.deferredRecoverySnapshotURL,
			  FileManager.default.fileExists(atPath: snapshotURL.path) else {
			return
		}
		try? FileManager.default.removeItem(at: snapshotURL)
	}

	/// Restore the segments of a deferred recording that never resumed, so the
	/// normal unprocessed-recording path can persist them.
	///
	/// Returns `true` when in-memory state was restored and the caller should
	/// continue with its recovery check.
	@MainActor
	func reclaimDeferredRecoverySegmentsIfNeeded() async -> Bool {
		guard recordingURL == nil,
			  !recordingIntentActive,
			  !recordingBeingProcessed,
			  let snapshotURL = Self.deferredRecoverySnapshotURL,
			  let data = try? Data(contentsOf: snapshotURL),
			  let snapshot = try? JSONDecoder().decode(DeferredRecoverySnapshot.self, from: data),
			  let documentsPath = FileManager.default
				.urls(for: .documentDirectory, in: .userDomainMask).first else {
			return false
		}

		let segments = snapshot.segmentFilenames
			.map { documentsPath.appendingPathComponent($0) }
			.filter { FileManager.default.fileExists(atPath: $0.path) }
		guard !segments.isEmpty else {
			clearDeferredRecoverySnapshot()
			return false
		}

		AppLog.shared.audioSession(
			"Reclaiming \(segments.count) segment(s) from a deferred recovery that never resumed"
		)
		recordingSegments = segments
		mainRecordingURL = snapshot.mainRecordingFilename
			.map { documentsPath.appendingPathComponent($0) } ?? segments.first
		currentSegmentIndex = max(segments.count - 1, 0)
		recordingURL = segments.last
		clearDeferredRecoverySnapshot()

		if segments.count > 1 {
			// The merge persists the combined recording itself.
			await mergeRecordingSegments()
			return false
		}
		return true
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
