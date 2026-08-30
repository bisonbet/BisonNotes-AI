//
//  AudioRecorderViewModel+Segments.swift
//  BisonNotes AI
//
//  Recording segment creation, merging, and checkpointing.
//

import Foundation
@preconcurrency import AVFoundation

// MARK: - Segment Management

extension AudioRecorderViewModel {

	/// Create a URL for a new recording segment
	/// Segments are named by appending "_seg1", "_seg2", etc. to the base filename
	func createSegmentURL(baseURL: URL, segmentIndex: Int) -> URL {
		let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
		let baseFilename = baseURL.deletingPathExtension().lastPathComponent
		let fileExtension = baseURL.pathExtension
		let segmentFilename = "\(baseFilename)_seg\(segmentIndex).\(fileExtension)"
		return documentsPath.appendingPathComponent(segmentFilename)
	}

	/// Merge multiple recording segments into a single file after interruptions
	@MainActor
	func mergeRecordingSegments(
		segments capturedSegments: [URL]? = nil,
		mainURL capturedMainURL: URL? = nil,
		ownsLiveRecordingState: Bool = true,
		expectedRecordingSessionID: UUID? = nil,
		expectedRecoveryRequestID: UUID? = nil
	) async {
		let recoveryIsCurrent: () -> Bool = {
			guard !Task.isCancelled else { return false }
			#if os(iOS)
			if let expectedRecordingSessionID,
			   self.recordingSessionID != expectedRecordingSessionID {
				return false
			}
			if let expectedRecoveryRequestID {
				guard let expectedRecordingSessionID else { return false }
				return self.recoveryCoordinator.accepts(
					requestID: expectedRecoveryRequestID,
					recordingSessionID: expectedRecordingSessionID
				)
			}
			return true
			#else
			return true
			#endif
		}

		// A caller that handed over its own segment list is persisting a
		// recording that is already over, so abandoning the merge would only
		// strand its audio; the live properties belong to whoever owns them now
		// and are gated separately below.
		let mergeShouldContinue: () -> Bool = {
			ownsLiveRecordingState ? recoveryIsCurrent() : !Task.isCancelled
		}

		// Read before the fence, never after it. A user stop schedules this
		// merge asynchronously, so a recording started in between has already
		// replaced `recordingSegments` and `mainRecordingURL` — returning first
		// would leave the stopped recording's segments with nothing pointing at
		// them at all.
		let segments = capturedSegments ?? recordingSegments
		guard segments.count > 1, let mainURL = capturedMainURL ?? mainRecordingURL else {
			AppLog.shared.recording("No segments to merge", level: .debug)
			return
		}
		guard mergeShouldContinue() else {
			preserveSupersededMergeSegments(segments, mainURL: mainURL)
			return
		}

		// Derived before the asset loads and export suspend. This recording is
		// already stopped; re-deriving its name, date and location after those
		// awaits would stamp it with whatever session is current by then.
		//
		// A reclaim runs after the successor session has replaced that state
		// outright, so it takes its date from the recording's own sidecar and its
		// name from that date, and carries no location rather than the new
		// session's.
		let capturedDate = currentRecordingDate(for: mainURL)
		let capturedName = ownsLiveRecordingState
			? generateAppRecordingDisplayName()
			: Self.appRecordingDisplayName(capturedAt: capturedDate)
		let capturedLocation = ownsLiveRecordingState ? recordingLocationSnapshot() : nil

		AppLog.shared.recording("Merging \(segments.count) segments")

		// Start background task to protect file merging and Core Data save operations
		beginBackgroundTask()
		var temporaryURL: URL?
		var mergeCompleted = false
		defer {
			if !mergeCompleted, let temporaryURL,
			   FileManager.default.fileExists(atPath: temporaryURL.path) {
				try? FileManager.default.removeItem(at: temporaryURL)
			}
			endBackgroundTask()
		}

		do {
			// Create AVAsset for each segment
			let composition = AVMutableComposition()

			// Create an audio track in the composition
			guard let compositionAudioTrack = composition.addMutableTrack(
				withMediaType: .audio,
				preferredTrackID: kCMPersistentTrackID_Invalid
			) else {
				AppLog.shared.recording("Failed to create composition audio track", level: .error)
				return
			}

			var currentTime = CMTime.zero

			// Add each segment to the composition
			for (index, segmentURL) in segments.enumerated() {
				guard mergeShouldContinue() else {
					preserveSupersededMergeSegments(segments, mainURL: mainURL)
					return
				}
				let asset = AVURLAsset(url: segmentURL)

				// Get the audio track from the segment
				guard let assetTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
					AppLog.shared.recording("Segment \(index + 1) has no audio track, skipping")
					continue
				}
				guard mergeShouldContinue() else {
					preserveSupersededMergeSegments(segments, mainURL: mainURL)
					return
				}

				// Get the duration of this segment
				let duration = try await asset.load(.duration)
				guard mergeShouldContinue() else {
					preserveSupersededMergeSegments(segments, mainURL: mainURL)
					return
				}

				// Insert the segment at the current time
				let timeRange = CMTimeRange(start: .zero, duration: duration)
				try compositionAudioTrack.insertTimeRange(timeRange, of: assetTrack, at: currentTime)

				AppLog.shared.recording("Added segment \(index + 1) at \(currentTime.seconds)s, duration: \(duration.seconds)s", level: .debug)

				// Move forward for the next segment
				currentTime = CMTimeAdd(currentTime, duration)
			}

			// Export the merged composition using iOS 18+ API
			guard let exportSession = AVAssetExportSession(
				asset: composition,
				presetName: AVAssetExportPresetAppleM4A
			) else {
				AppLog.shared.recording("Failed to create export session", level: .error)
				return
			}

			// Export to a temporary file first (to avoid overwriting existing segments)
			let tempURL = mainURL.deletingLastPathComponent().appendingPathComponent("temp_merge_\(UUID().uuidString).m4a")
			temporaryURL = tempURL
			registerRecordingAttemptArtifact(at: tempURL)

			// Use the modern export API (iOS 18+)
			try await exportSession.export(to: tempURL, as: .m4a)
			guard mergeShouldContinue() else {
				preserveSupersededMergeSegments(segments, mainURL: mainURL)
				return
			}
			AppFileProtection.apply(to: tempURL)

			AppLog.shared.recording("Successfully merged all segments to temporary file", level: .debug)

			let finalization = await RecordingFinalizationPolicy.inspect(url: tempURL, delegateSucceeded: true)
			guard mergeShouldContinue() else {
				preserveSupersededMergeSegments(segments, mainURL: mainURL)
				return
			}
			guard case .usable(let fileSize, let duration) = finalization else {
				if case .rejected(let rejection) = finalization {
					AppLog.shared.recording(
						"Merged recording was not usable: \(rejection)",
						level: .error
					)
					removeOwnedRecordingAttemptArtifact(at: tempURL)
					if ownsLiveRecordingState {
						errorMessage = rejection.userMessage
					}
				}
				return
			}

			// Replace the original main segment only after the merged file has been
			// exported and validated. Keep a recoverable backup until the move is
			// complete so a filesystem error cannot discard the last valid segment.
			let fileManager = FileManager.default
			let backupURL = mainURL.deletingLastPathComponent()
				.appendingPathComponent("merge_backup_\(UUID().uuidString).m4a")
			registerRecordingAttemptArtifact(at: backupURL)
			var originalMovedToBackup = false
			do {
				if fileManager.fileExists(atPath: mainURL.path) {
					try fileManager.moveItem(at: mainURL, to: backupURL)
					originalMovedToBackup = true
				}
				try fileManager.moveItem(at: tempURL, to: mainURL)
			} catch {
				if originalMovedToBackup,
				   !fileManager.fileExists(atPath: mainURL.path),
				   fileManager.fileExists(atPath: backupURL.path) {
					try? fileManager.moveItem(at: backupURL, to: mainURL)
				}
				throw error
			}
			mergeCompleted = true
			removeOwnedRecordingAttemptArtifact(at: backupURL)
			AppFileProtection.apply(to: mainURL)

			// The merged output is now safe. Remove only the superseded segments;
			// never delete the new file at mainURL.
			let obsoleteSegments = segments.filter {
				$0.standardizedFileURL != mainURL.standardizedFileURL
			}
			deleteSegmentFiles(obsoleteSegments)

			// A newer session may own the live recording state by now. That gates
			// the state writes below — never the save. The merged file exists and
			// its sources are gone, so returning here would leave the whole
			// recording on disk with no Core Data row.
			let stillCurrent = ownsLiveRecordingState && recoveryIsCurrent()
			if !stillCurrent {
				AppLog.shared.recording(
					"A newer recording superseded this merge; persisting the merged file without touching live state",
					level: .debug
				)
			}
			if stillCurrent, segmentURLTrackingMatches(segments) {
				recordingSegments = []
				mainRecordingURL = nil
				currentSegmentIndex = 0
			}

			AppLog.shared.recording("Successfully merged all segments")

			if stillCurrent {
				// Update the recordingURL to point to the merged file
				recordingURL = mainURL

				// Reads live location state, so it only applies while current.
				saveLocationData(for: mainURL)
			}

			AppLog.shared.recording("Merged recording saved in Whisper-optimized format")

			// Add recording using workflow manager
			if let workflowManager = workflowManager {
				let quality = AudioRecorderViewModel.getCurrentAudioQuality()

				// Create recording
				let recordingId = workflowManager.createRecording(
					url: mainURL,
					name: capturedName,
					date: capturedDate,
					fileSize: fileSize,
					duration: duration,
					quality: quality,
					locationData: capturedLocation
				)

				AppLog.shared.recording("Merged recording created with workflow manager, ID: \(recordingId)")

				// The row exists, so any trail parking these segments has done its
				// job. Retiring it earlier is what strands audio when an export
				// fails or the app dies mid-save.
				#if os(iOS)
				clearDeferredRecoverySnapshotEntries(containing: mainURL)
				#endif

				if stillCurrent {
					self.resetRecordingLocation()
					self.recordingStartedAt = nil
					self.resetRecordingAttemptArtifacts()
				}
			} else {
				AppLog.shared.recording("WorkflowManager not set - merged recording not saved to database", level: .error)
			}

		} catch {
			AppLog.shared.recording("Error merging segments: \(error.localizedDescription)", level: .error)
		}
	}

	/// Keep a superseded merge's segments reachable.
	///
	/// A merge abandoned mid-flight has not produced its output yet, and
	/// `setupRecording()` has already replaced `recordingSegments` and
	/// `mainRecordingURL` — so without a trail on disk the stopped recording's
	/// segments become untracked files that nothing ever persists. Writing the
	/// recovery snapshot lets the next unprocessed-recording pass reclaim and
	/// merge them.
	@MainActor
	func preserveSupersededMergeSegments(_ segments: [URL], mainURL: URL) {
		#if os(iOS)
		let survivors = segments.filter { FileManager.default.fileExists(atPath: $0.path) }
		guard !survivors.isEmpty else { return }
		persistRecoverySnapshot(
			segments: survivors,
			mainRecordingURL: mainURL,
			currentSegmentIndex: max(survivors.count - 1, 0)
		)
		AppLog.shared.recording(
			"Merge superseded by a newer session; preserved \(survivors.count) segment(s) for reclamation",
			level: .error
		)
		#endif
	}

	/// Clean up individual segment files after successful merge
	@MainActor
	func cleanupSegmentFiles(segmentURLs: [URL]? = nil) async {
		let segmentsToDelete = segmentURLs ?? recordingSegments
		guard segmentsToDelete.count > 1 else { return }

		// Delete all segment files (including the first one for a complete merge).
		deleteSegmentFiles(segmentsToDelete)

		// Clear the segment tracking only when this operation still owns the same
		// set of segments. A stale merge must not clear a newer recording session.
		if segmentURLTrackingMatches(segmentsToDelete) {
			recordingSegments = []
			mainRecordingURL = nil
			currentSegmentIndex = 0
		}
	}

	@MainActor
	private func deleteSegmentFiles(_ segments: [URL]) {
		let fileManager = FileManager.default
		for segmentURL in segments {
			do {
				if fileManager.fileExists(atPath: segmentURL.path) {
					try fileManager.removeItem(at: segmentURL)
					AppLog.shared.recording("Deleted segment", level: .debug)
				}
			} catch {
				AppLog.shared.recording("Failed to delete segment: \(error.localizedDescription)", level: .error)
			}
		}
	}

	@MainActor
	private func segmentURLTrackingMatches(_ segments: [URL]) -> Bool {
		recordingSegments == segments
	}

	// MARK: - Buffer Checkpointing

	/// Manually trigger a checkpoint to flush audio buffer to disk
	/// This ensures recorded audio is written to permanent storage
	/// Useful before potentially risky operations or to ensure data durability
	func forceCheckpoint() {
		guard isRecording, let recorder = audioRecorder, recorder.isRecording else {
			AppLog.shared.recording("Cannot checkpoint: not currently recording", level: .debug)
			return
		}

		recorder.pause()
		recorder.record()
		lastCheckpointTime = Date()
		AppLog.shared.recording("Manual checkpoint: Flushed recording buffer to disk", level: .debug)
	}

	/// Check if the current audio level indicates silence
	/// Returns true if the audio is below the silence threshold
	func isCurrentlySilent() -> Bool {
		guard let recorder = audioRecorder, recorder.isRecording else {
			return false
		}

		// Update metering to get current levels
		recorder.updateMeters()

		// Get average power for channel 0 (mono recording)
		let averagePower = recorder.averagePower(forChannel: 0)

		// Check if below silence threshold
		let isSilent = averagePower < silenceThreshold

		return isSilent
	}

	/// Perform a smart checkpoint that waits for silence
	func performSmartCheckpoint(force: Bool = false) {
		guard isRecording, let recorder = audioRecorder, recorder.isRecording else {
			return
		}

		let now = Date()
		let timeSinceLastCheckpoint = now.timeIntervalSince(lastCheckpointTime)

		// Check if we need to checkpoint
		let shouldAttemptCheckpoint = timeSinceLastCheckpoint >= checkpointInterval
		let shouldForceCheckpoint = force || timeSinceLastCheckpoint >= forceCheckpointInterval

		guard shouldAttemptCheckpoint || shouldForceCheckpoint else {
			return
		}

		// If forcing or if we detect silence, do the checkpoint
		if shouldForceCheckpoint {
			recorder.pause()
			recorder.record()
			lastCheckpointTime = now
			AppLog.shared.recording("Checkpoint: Forced buffer flush at \(Int(recordingTime))s (no silence for \(Int(timeSinceLastCheckpoint))s)", level: .debug)
		} else if isCurrentlySilent() {
			recorder.pause()
			recorder.record()
			lastCheckpointTime = now
			AppLog.shared.recording("Checkpoint: Flushed during silence at \(Int(recordingTime))s", level: .debug)
		} else {
			// Not silent and not forcing - skip this checkpoint attempt
			// We'll try again next second
			return
		}
	}
}
