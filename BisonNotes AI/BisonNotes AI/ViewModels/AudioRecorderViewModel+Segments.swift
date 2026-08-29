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

		guard recoveryIsCurrent(), recordingSegments.count > 1, let mainURL = mainRecordingURL else {
			AppLog.shared.recording("No segments to merge", level: .debug)
			return
		}
		let segments = recordingSegments

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
				guard recoveryIsCurrent() else { return }
				let asset = AVURLAsset(url: segmentURL)

				// Get the audio track from the segment
				guard let assetTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
					AppLog.shared.recording("Segment \(index + 1) has no audio track, skipping")
					continue
				}
				guard recoveryIsCurrent() else { return }

				// Get the duration of this segment
				let duration = try await asset.load(.duration)
				guard recoveryIsCurrent() else { return }

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
			guard recoveryIsCurrent() else { return }
			AppFileProtection.apply(to: tempURL)

			AppLog.shared.recording("Successfully merged all segments to temporary file", level: .debug)

			let finalization = await RecordingFinalizationPolicy.inspect(url: tempURL, delegateSucceeded: true)
			guard recoveryIsCurrent() else { return }
			guard case .usable(let fileSize, let duration) = finalization else {
				if case .rejected(let rejection) = finalization {
					AppLog.shared.recording(
						"Merged recording was not usable: \(rejection)",
						level: .error
					)
					removeOwnedRecordingAttemptArtifact(at: tempURL)
					errorMessage = rejection.userMessage
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
			guard recoveryIsCurrent() else { return }
			let obsoleteSegments = segments.filter {
				$0.standardizedFileURL != mainURL.standardizedFileURL
			}
			deleteSegmentFiles(obsoleteSegments)
			guard recoveryIsCurrent() else { return }
			if segmentURLTrackingMatches(segments) {
				recordingSegments = []
				mainRecordingURL = nil
				currentSegmentIndex = 0
			}

			AppLog.shared.recording("Successfully merged all segments")

			// Update the recordingURL to point to the merged file
			recordingURL = mainURL

			// Save the merged recording to the database
			saveLocationData(for: mainURL)

			AppLog.shared.recording("Merged recording saved in Whisper-optimized format")

			// Add recording using workflow manager
			if let workflowManager = workflowManager {
				let quality = AudioRecorderViewModel.getCurrentAudioQuality()

				// Create display name for phone recording
				let displayName = generateAppRecordingDisplayName()

				// Create recording
				let recordingId = workflowManager.createRecording(
					url: mainURL,
					name: displayName,
					date: currentRecordingDate(for: mainURL),
					fileSize: fileSize,
					duration: duration,
					quality: quality,
					locationData: recordingLocationSnapshot()
				)

				AppLog.shared.recording("Merged recording created with workflow manager, ID: \(recordingId)")

				self.resetRecordingLocation()
				self.recordingStartedAt = nil
				self.resetRecordingAttemptArtifacts()
			} else {
				AppLog.shared.recording("WorkflowManager not set - merged recording not saved to database", level: .error)
			}

		} catch {
			AppLog.shared.recording("Error merging segments: \(error.localizedDescription)", level: .error)
		}
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
