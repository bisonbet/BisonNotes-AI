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
		clearDeferredRecoverySnapshotForCurrentRecording()
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
		resetRecordingStateAfterRecoveryFailure(reason: reason)

		recordingSegments = existingRecordingSegments()
		recordingURL = recordingSegments.last
		let hasPreservedAudio = !recordingSegments.isEmpty
		// Captured before persistence, which clears both on a successful merge.
		// This recording may have been parked by an earlier deferral, making its
		// snapshot the only durable index of these segments, so the entry is
		// retired below on the database row rather than up front.
		let preservedSegments = recordingSegments
		let preservedMainURL = mainRecordingURL ?? preservedSegments.first
		let persistedURL = preservedSegments.count > 1
			? preservedMainURL
			: preservedSegments.first
		await persistTerminatedRecoverySegments(for: request, reason: reason)
		releaseTerminatedRecoverySnapshot(
			segments: preservedSegments,
			mainURL: preservedMainURL,
			persistedURL: persistedURL
		)
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

	/// Retire this recording's parked entry only once its audio is saved.
	///
	/// A terminal recovery can be the end of a session that was deferred earlier,
	/// so its snapshot may be the only durable index of these segments. The merge
	/// swallows export failures and the app can be killed mid-save, so the entry
	/// is dropped on the database row and rewritten on anything else.
	@MainActor
	private func releaseTerminatedRecoverySnapshot(
		segments: [URL],
		mainURL: URL?,
		persistedURL: URL?
	) {
		let key = mainURL?.lastPathComponent ?? segments.first?.lastPathComponent
		if let persistedURL,
		   let appCoordinator,
		   appCoordinator.getRecording(url: persistedURL) != nil {
			clearDeferredRecoverySnapshot(forKey: key)
			return
		}

		let survivors = segments.filter { FileManager.default.fileExists(atPath: $0.path) }
		guard let mainURL, !survivors.isEmpty else {
			clearDeferredRecoverySnapshot(forKey: key)
			return
		}
		AppLog.shared.audioSession(
			"Terminated recovery did not persist; keeping \(survivors.count) segment(s) for the next pass",
			level: .error
		)
		persistRecoverySnapshot(
			segments: survivors,
			mainRecordingURL: mainURL,
			currentSegmentIndex: max(survivors.count - 1, 0)
		)
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

	/// One recording parked by `deferAudioRecovery`, or by a merge that a newer
	/// session superseded.
	///
	/// Only file names are stored: the Documents container is relocated between
	/// launches, so an absolute URL captured today does not resolve tomorrow.
	private struct DeferredRecoverySnapshot: Codable {
		let mainRecordingFilename: String?
		let segmentFilenames: [String]
		let currentSegmentIndex: Int
		let deferredAt: Date

		/// Identity of the recording this entry parks.
		var key: String? {
			mainRecordingFilename ?? segmentFilenames.first
		}
	}

	/// Every parked recording, one entry each.
	///
	/// More than one can be parked at a time — a deferred session the user
	/// superseded, and then the superseding session deferring in turn — so a
	/// single-entry file let whichever wrote last erase the other's only durable
	/// pointer. Builds that wrote one bare snapshot still decode.
	private struct DeferredRecoveryStore: Codable {
		var entries: [DeferredRecoverySnapshot]
	}

	private static var deferredRecoverySnapshotURL: URL? {
		FileManager.default
			.urls(for: .documentDirectory, in: .userDomainMask)
			.first?
			.appendingPathComponent("deferred-recovery.json")
	}

	@MainActor
	private func loadDeferredRecoveryEntries() -> [DeferredRecoverySnapshot] {
		guard let snapshotURL = Self.deferredRecoverySnapshotURL,
			  let data = try? Data(contentsOf: snapshotURL) else {
			return []
		}
		let decoder = JSONDecoder()
		if let store = try? decoder.decode(DeferredRecoveryStore.self, from: data) {
			return store.entries
		}
		if let legacy = try? decoder.decode(DeferredRecoverySnapshot.self, from: data) {
			return [legacy]
		}
		return []
	}

	@MainActor
	private func writeDeferredRecoveryEntries(_ entries: [DeferredRecoverySnapshot]) {
		guard let snapshotURL = Self.deferredRecoverySnapshotURL else { return }
		guard !entries.isEmpty else {
			try? FileManager.default.removeItem(at: snapshotURL)
			return
		}
		do {
			let data = try JSONEncoder().encode(DeferredRecoveryStore(entries: entries))
			try data.write(to: snapshotURL, options: .atomic)
			AppFileProtection.apply(to: snapshotURL)
		} catch {
			AppLog.shared.audioSession(
				"Could not persist deferred recovery snapshot: \(error.localizedDescription)",
				level: .error
			)
		}
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
	/// more, so without this they are untracked files on disk. Only this
	/// recording's own entry is replaced; every other parked recording stays.
	@MainActor
	func persistRecoverySnapshot(
		segments: [URL],
		mainRecordingURL: URL?,
		currentSegmentIndex: Int
	) {
		let snapshot = DeferredRecoverySnapshot(
			mainRecordingFilename: mainRecordingURL?.lastPathComponent,
			segmentFilenames: segments.map { $0.lastPathComponent },
			currentSegmentIndex: currentSegmentIndex,
			deferredAt: Date()
		)
		guard !segments.isEmpty, let key = snapshot.key else {
			clearDeferredRecoverySnapshot(forKey: mainRecordingURL?.lastPathComponent)
			return
		}

		var entries = loadDeferredRecoveryEntries().filter { $0.key != key }
		entries.append(snapshot)
		writeDeferredRecoveryEntries(entries)
		AppLog.shared.audioSession(
			"Persisted deferred recovery snapshot for \(segments.count) segment(s)",
			level: .debug
		)
	}

	/// Drop the entry for the recording this session owns.
	///
	/// Never a blanket clear: another recording may be parked at the same time,
	/// and its trail is the only thing that can still find its audio.
	@MainActor
	func clearDeferredRecoverySnapshotForCurrentRecording() {
		var ownedFilenames = Set(recordingSegments.map { $0.lastPathComponent })
		if let mainRecordingURL {
			ownedFilenames.insert(mainRecordingURL.lastPathComponent)
		}
		guard !ownedFilenames.isEmpty else { return }

		let entries = loadDeferredRecoveryEntries()
		let survivors = entries.filter { entry in
			guard let key = entry.key else { return false }
			return !ownedFilenames.contains(key)
		}
		guard survivors.count != entries.count else { return }
		writeDeferredRecoveryEntries(survivors)
	}

	@MainActor
	func clearDeferredRecoverySnapshot(forKey key: String?) {
		guard let key else { return }
		let entries = loadDeferredRecoveryEntries()
		let survivors = entries.filter { $0.key != key }
		guard survivors.count != entries.count else { return }
		writeDeferredRecoveryEntries(survivors)
	}

	/// Drop any entry that parks `url`, once that file is in the database.
	@MainActor
	func clearDeferredRecoverySnapshotEntries(containing url: URL) {
		let filename = url.lastPathComponent
		let entries = loadDeferredRecoveryEntries()
		let survivors = entries.filter { entry in
			entry.mainRecordingFilename != filename
				&& !entry.segmentFilenames.contains(filename)
		}
		guard survivors.count != entries.count else { return }
		writeDeferredRecoveryEntries(survivors)
	}

	/// One recording parked on disk, resolved against the current container.
	private struct ParkedRecovery {
		let key: String
		let segments: [URL]
		let mainURL: URL
	}

	/// Every parked recording whose audio is still on disk, oldest first.
	///
	/// Entries whose files have all gone are pruned as they are read.
	@MainActor
	private func parkedDeferredRecoveries() -> [ParkedRecovery] {
		guard let documentsPath = FileManager.default
			.urls(for: .documentDirectory, in: .userDomainMask).first else {
			return []
		}

		let entries = loadDeferredRecoveryEntries()
		var survivingEntries: [DeferredRecoverySnapshot] = []
		var parked: [ParkedRecovery] = []
		for entry in entries.sorted(by: { $0.deferredAt < $1.deferredAt }) {
			let segments = entry.segmentFilenames
				.map { documentsPath.appendingPathComponent($0) }
				.filter { FileManager.default.fileExists(atPath: $0.path) }
			guard let firstSegment = segments.first, let key = entry.key else { continue }
			survivingEntries.append(entry)
			let mainURL = entry.mainRecordingFilename
				.map { documentsPath.appendingPathComponent($0) } ?? firstSegment
			parked.append(ParkedRecovery(key: key, segments: segments, mainURL: mainURL))
		}
		if survivingEntries.count != entries.count {
			writeDeferredRecoveryEntries(survivingEntries)
		}
		return parked
	}

	/// Persist the audio deferred recoveries parked, before a new session
	/// replaces the state that still points at it.
	///
	/// `deferAudioRecovery` sets `isRecording = false`, so the user can start
	/// another capture long before foreground reconciliation runs, and
	/// `setupRecording()` is about to overwrite `recordingSegments` and
	/// `mainRecordingURL`. The reclaim never owns live recording state: the
	/// session starting now does.
	///
	/// Each entry is kept until its save lands. Persistence below is
	/// asynchronous, so clearing up front would strand the segments if iOS
	/// suspends the app before the task runs or a multi-segment export fails —
	/// with nothing on disk left for a later unprocessed-recording pass to find.
	@MainActor
	func reclaimDeferredRecoverySegmentsForSupersededSession() {
		let parkedRecordings = parkedDeferredRecoveries()
		guard !parkedRecordings.isEmpty else { return }

		for parked in parkedRecordings {
			AppLog.shared.audioSession(
				"A new recording superseded a deferred recovery; persisting its \(parked.segments.count) segment(s)"
			)
			Task { @MainActor [weak self] in
				guard let self else { return }
				// The merge writes its output over mainURL and creates the row for
				// it; a single segment is saved under its own URL.
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
	}

	/// Drop a reclaimed entry only once its audio is in the database.
	///
	/// The database row is the success signal: a merge swallows export failures
	/// and both persistence helpers can be superseded. When the save did not
	/// land, the surviving segments are written back so the next pass can retry.
	@MainActor
	private func releaseReclaimedRecoverySnapshot(
		for parked: ParkedRecovery,
		persistedURL: URL
	) {
		if let appCoordinator, appCoordinator.getRecording(url: persistedURL) != nil {
			clearDeferredRecoverySnapshot(forKey: parked.key)
			return
		}

		let survivors = parked.segments.filter { FileManager.default.fileExists(atPath: $0.path) }
		guard !survivors.isEmpty else {
			clearDeferredRecoverySnapshot(forKey: parked.key)
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
		guard let parked = parkedDeferredRecoveries().first else {
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
			// Deliberately keep the entry: the caller's unprocessed-recording pass
			// still has to validate and save this file, and it clears the entry
			// once the database row exists. Dropping the only durable pointer
			// first would lose the audio if that work never completed.
			return true
		}

		// The merge persists the combined recording itself, but it swallows an
		// export failure and returns; `recordingURL` is then the last segment
		// alone. Keep the trail until the merge has actually cleared the segment
		// list, so a failed pass cannot lose everything captured before it.
		await mergeRecordingSegments()
		if recordingSegments.isEmpty {
			clearDeferredRecoverySnapshot(forKey: parked.key)
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
