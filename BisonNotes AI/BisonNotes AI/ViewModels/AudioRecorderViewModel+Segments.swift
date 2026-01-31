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
	func mergeRecordingSegments() async {
		guard recordingSegments.count > 1, let mainURL = mainRecordingURL else {
			print("⚠️ No segments to merge")
			return
		}

		print("🔄 Merging \(recordingSegments.count) segments into: \(mainURL.lastPathComponent)")

		// Start background task to protect file merging and Core Data save operations
		beginBackgroundTask()

		do {
			// Create AVAsset for each segment
			let composition = AVMutableComposition()

			// Create an audio track in the composition
			guard let compositionAudioTrack = composition.addMutableTrack(
				withMediaType: .audio,
				preferredTrackID: kCMPersistentTrackID_Invalid
			) else {
				print("❌ Failed to create composition audio track")
				return
			}

			var currentTime = CMTime.zero

			// Add each segment to the composition
			for (index, segmentURL) in recordingSegments.enumerated() {
				let asset = AVURLAsset(url: segmentURL)

				// Get the audio track from the segment
				guard let assetTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
					print("⚠️ Segment \(index + 1) has no audio track, skipping")
					continue
				}

				// Get the duration of this segment
				let duration = try await asset.load(.duration)

				// Insert the segment at the current time
				let timeRange = CMTimeRange(start: .zero, duration: duration)
				try compositionAudioTrack.insertTimeRange(timeRange, of: assetTrack, at: currentTime)

				print("✅ Added segment \(index + 1) at \(currentTime.seconds)s, duration: \(duration.seconds)s")

				// Move forward for the next segment
				currentTime = CMTimeAdd(currentTime, duration)
			}

			// Export the merged composition using iOS 18+ API
			guard let exportSession = AVAssetExportSession(
				asset: composition,
				presetName: AVAssetExportPresetAppleM4A
			) else {
				print("❌ Failed to create export session")
				return
			}

			// Export to a temporary file first (to avoid overwriting existing segments)
			let tempURL = mainURL.deletingLastPathComponent().appendingPathComponent("temp_merge_\(UUID().uuidString).m4a")

			// Use the modern export API (iOS 18+)
			try await exportSession.export(to: tempURL, as: .m4a)

			print("✅ Successfully merged all segments to temporary file")

			// Clean up individual segment files
			await cleanupSegmentFiles()

			// Move the merged file to the final location
			let fileManager = FileManager.default

			// Remove the final destination if it exists
			if fileManager.fileExists(atPath: mainURL.path) {
				try fileManager.removeItem(at: mainURL)
			}

			// Move temp file to final location
			try fileManager.moveItem(at: tempURL, to: mainURL)

			print("✅ Successfully merged all segments into: \(mainURL.lastPathComponent)")

			// Update the recordingURL to point to the merged file
			recordingURL = mainURL

			// Save the merged recording to the database
			saveLocationData(for: mainURL)

			print("✅ Merged recording saved in Whisper-optimized format")

			// Add recording using workflow manager
			if let workflowManager = workflowManager {
				let fileSize = getFileSize(url: mainURL)
				let duration = getRecordingDuration(url: mainURL)
				let quality = AudioRecorderViewModel.getCurrentAudioQuality()

				// Create display name for phone recording
				let displayName = generateAppRecordingDisplayName()

				// Create recording
				let recordingId = workflowManager.createRecording(
					url: mainURL,
					name: displayName,
					date: Date(),
					fileSize: fileSize,
					duration: duration,
					quality: quality,
					locationData: recordingLocationSnapshot()
				)

				print("✅ Merged recording created with workflow manager, ID: \(recordingId)")

				self.resetRecordingLocation()
			} else {
				print("❌ WorkflowManager not set - merged recording not saved to database!")
			}

			// End background task after successful merge and save
			endBackgroundTask()

		} catch {
			print("❌ Error merging segments: \(error.localizedDescription)")
			// End background task even on error
			endBackgroundTask()
		}
	}

	/// Clean up individual segment files after successful merge
	@MainActor
	func cleanupSegmentFiles() async {
		guard recordingSegments.count > 1 else { return }

		let fileManager = FileManager.default

		// Delete all segment files (including the first one, since we're merging to a temp file first)
		for segmentURL in recordingSegments {
			do {
				if fileManager.fileExists(atPath: segmentURL.path) {
					try fileManager.removeItem(at: segmentURL)
					print("🗑️ Deleted segment: \(segmentURL.lastPathComponent)")
				}
			} catch {
				print("⚠️ Failed to delete segment \(segmentURL.lastPathComponent): \(error.localizedDescription)")
			}
		}

		// Clear the segment tracking
		recordingSegments = []
		mainRecordingURL = nil
		currentSegmentIndex = 0
	}

	// MARK: - Buffer Checkpointing

	/// Manually trigger a checkpoint to flush audio buffer to disk
	/// This ensures recorded audio is written to permanent storage
	/// Useful before potentially risky operations or to ensure data durability
	func forceCheckpoint() {
		guard isRecording, let recorder = audioRecorder, recorder.isRecording else {
			print("⚠️ Cannot checkpoint: not currently recording")
			return
		}

		recorder.pause()
		recorder.record()
		lastCheckpointTime = Date()
		print("💾 Manual checkpoint: Flushed recording buffer to disk")
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
			print("💾 Checkpoint: Forced buffer flush at \(Int(recordingTime))s (no silence detected for \(Int(timeSinceLastCheckpoint))s)")
		} else if isCurrentlySilent() {
			recorder.pause()
			recorder.record()
			lastCheckpointTime = now
			print("💾 Checkpoint: Flushed during silence at \(Int(recordingTime))s")
		} else {
			// Not silent and not forcing - skip this checkpoint attempt
			// We'll try again next second
			return
		}
	}
}
