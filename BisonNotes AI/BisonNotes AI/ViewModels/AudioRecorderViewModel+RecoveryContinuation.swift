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
		guard isCurrentAudioRecovery(request) else {
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

			// The full recovery fence, not just request/session intent: a new
			// interruption can arrive during the wait above, and marking the
			// continuation started would clear that interruption's state while
			// the higher-priority session still owns the microphone.
			guard isCurrentAudioRecovery(request) else {
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

	/// The still-present segments a deferred recovery parked, resolved against
	/// the current Documents container.
	@MainActor
	private func parkedDeferredRecoverySegments() -> (segments: [URL], mainURL: URL)? {
		guard let snapshotURL = Self.deferredRecoverySnapshotURL,
			  let data = try? Data(contentsOf: snapshotURL),
			  let snapshot = try? JSONDecoder().decode(DeferredRecoverySnapshot.self, from: data),
			  let documentsPath = FileManager.default
				.urls(for: .documentDirectory, in: .userDomainMask).first else {
			return nil
		}

		let segments = snapshot.segmentFilenames
			.map { documentsPath.appendingPathComponent($0) }
			.filter { FileManager.default.fileExists(atPath: $0.path) }
		guard let firstSegment = segments.first else { return nil }
		let mainURL = snapshot.mainRecordingFilename
			.map { documentsPath.appendingPathComponent($0) } ?? firstSegment
		return (segments, mainURL)
	}

	/// Persist the audio a deferred recovery parked, before a new session
	/// replaces the state that still points at it.
	///
	/// `deferAudioRecovery` sets `isRecording = false`, so the user can start
	/// another capture long before foreground reconciliation runs. The snapshot
	/// is the only durable pointer to those segments and `setupRecording()` is
	/// about to overwrite `recordingSegments` and `mainRecordingURL`, so the
	/// deferred audio is reclaimed here instead of dropped. The reclaim never
	/// owns live recording state: the session starting now does.
	///
	/// The snapshot is deliberately kept until the save lands. Persistence below
	/// is asynchronous, so clearing it up front would strand the segments if iOS
	/// suspends the app before the task runs or a multi-segment export fails —
	/// with nothing on disk left for a later unprocessed-recording pass to find.
	@MainActor
	func reclaimDeferredRecoverySegmentsForSupersededSession() {
		guard let parked = parkedDeferredRecoverySegments() else {
			clearDeferredRecoverySnapshot()
			return
		}

		AppLog.shared.audioSession(
			"A new recording superseded a deferred recovery; persisting its \(parked.segments.count) segment(s)"
		)
		Task { @MainActor [weak self] in
			guard let self else { return }
			// The merge writes its output over mainURL and creates the row for it;
			// a single segment is saved under its own URL.
			let persistedURL: URL
			if parked.segments.count > 1 {
				persistedURL = parked.mainURL
				await self.mergeRecordingSegments(
					segments: parked.segments,
					mainURL: parked.mainURL,
					ownsLiveRecordingState: false
				)
			} else {
				persistedURL = parked.segments[0]
				await self.recoverInterruptedRecording(
					url: persistedURL,
					reason: "A new recording started before the deferred recovery resumed",
					ownsLiveRecordingState: false
				)
			}
			self.releaseReclaimedRecoverySnapshot(for: parked, persistedURL: persistedURL)
		}
	}

	/// Drop the reclaimed snapshot only once its audio is in the database.
	///
	/// The database row is the success signal: a merge swallows export failures
	/// and both persistence helpers can be superseded. When the save did not
	/// land, the trail is rewritten so the next pass can retry — but never over a
	/// snapshot a newer session has parked in the meantime.
	@MainActor
	private func releaseReclaimedRecoverySnapshot(
		for parked: (segments: [URL], mainURL: URL),
		persistedURL: URL
	) {
		if let appCoordinator, appCoordinator.getRecording(url: persistedURL) != nil {
			// Clear this reclaim's own trail only. The session that superseded it
			// may have deferred and parked a snapshot of its own by now.
			if let current = parkedDeferredRecoverySegments(),
			   current.mainURL.standardizedFileURL != parked.mainURL.standardizedFileURL {
				return
			}
			clearDeferredRecoverySnapshot()
			return
		}

		let survivors = parked.segments.filter { FileManager.default.fileExists(atPath: $0.path) }
		guard !survivors.isEmpty, parkedDeferredRecoverySegments() == nil else {
			return
		}
		AppLog.shared.audioSession(
			"Reclaimed recovery did not persist; keeping \(survivors.count) segment(s) for the next pass",
			level: .error
		)
		persistRecoverySnapshot(
			segments: survivors,
			mainRecordingURL: parked.mainURL,
			currentSegmentIndex: max(survivors.count - 1, 0)
		)
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
			  !recordingBeingProcessed else {
			return false
		}
		guard let parked = parkedDeferredRecoverySegments() else {
			clearDeferredRecoverySnapshot()
			return false
		}

		let segments = parked.segments
		AppLog.shared.audioSession(
			"Reclaiming \(segments.count) segment(s) from a deferred recovery that never resumed"
		)
		recordingSegments = segments
		mainRecordingURL = parked.mainURL
		currentSegmentIndex = max(segments.count - 1, 0)
		recordingURL = segments.last

		guard segments.count > 1 else {
			clearDeferredRecoverySnapshot()
			return true
		}

		// The merge persists the combined recording itself, but it swallows an
		// export failure and returns; `recordingURL` is then the last segment
		// alone. Keep the trail until the merge has actually cleared the segment
		// list, so a failed pass cannot lose everything captured before it.
		await mergeRecordingSegments()
		if recordingSegments.isEmpty {
			clearDeferredRecoverySnapshot()
		} else {
			persistRecoverySnapshot(
				segments: existingRecordingSegments(),
				mainRecordingURL: mainRecordingURL,
				currentSegmentIndex: currentSegmentIndex
			)
		}
		return false
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
