//
//  AudioRecorderViewModel+Utilities.swift
//  BisonNotes AI
//
//  Delegates, input selection, file operations, and naming helpers.
//

import Foundation
@preconcurrency import AVFoundation
import UserNotifications

private struct RecordingTimestampMetadata: Codable {
	let recordedAt: Date
}

// MARK: - AVAudioRecorderDelegate

extension AudioRecorderViewModel: AVAudioRecorderDelegate {
	nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
		let errorDescription = error?.localizedDescription
		Task { @MainActor [weak self] in
			guard let self else { return }
			if isRecording {
				audioRecorder?.stop()
				isRecording = false
				stopRecordingTimer()
			}
			errorMessage = "Recording stopped due to an encoding error\(errorDescription.map { ": \($0)" } ?? ".")"
		}
	}

	/// Whether a finished recording's completion may release the shared session.
	///
	/// Deactivate after either a successful save or a rejected current-attempt
	/// artifact — but never out from under a recording that started while this
	/// completion was being finalized. The UI flags alone are not enough: a newer
	/// session in coordinated recovery has both `isRecording` and
	/// `isStartingRecording` false while it finalizes and activates, and
	/// deactivating there fails its continuation.
	@MainActor
	func canDeactivateSession(afterFinalizing finalizationSessionID: UUID?) -> Bool {
		#if os(iOS)
		return recordingSessionID == finalizationSessionID && !recordingIntentActive
		#else
		return !isRecording && !isStartingRecording
		#endif
	}

	nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
		let finishedURL = recorder.url
		Task { @MainActor [weak self] in
			guard let self else { return }
			#if os(iOS)
			if isFinalizingRecoverySegment || recoveryFinalizedSegmentURLs.contains(finishedURL.standardizedFileURL) {
				AppLog.shared.recording(
					"Ignoring recorder completion owned by coordinated recovery",
					level: .debug
				)
				return
			}
			#endif
			// Check if we're still in recording mode - if so, this was an interruption, not a user stop
			// In this case, don't save as a finished recording - let the interruption handler deal with it
			if isRecording {
				AppLog.shared.recording("Recorder finished but still in recording mode - ignoring (interruption will be handled)", level: .debug)
				return
			}

			// Check if recording is already being processed by interruption handler
			// But allow processing if app is backgrounding (normal completion scenario)
			if recordingBeingProcessed && !appIsBackgrounding {
				AppLog.shared.recording("Recording already processed by interruption handler, skipping normal completion", level: .debug)
				recordingBeingProcessed = false // Reset flag
				return
			}

			// Check if we have multiple segments - if so, the merge will handle saving
			if recordingSegments.count > 1 {
				AppLog.shared.recording("Multiple segments detected - merge process will handle saving", level: .debug)
				return
			}

			// Start background task to protect file validation and Core Data save operations.
			beginBackgroundTask()
			// Never end the assertion out from under a recording that started
			// while this completion was being finalized.
			defer {
				if !self.isRecording, !self.isStartingRecording {
					self.endBackgroundTask()
				}
			}

			recordingBeingProcessed = true // Set flag to prevent duplicate processing

			// Inspecting the container suspends. Capture what this callback owns
			// so the work after the await can prove it still applies: without
			// this, a recording the user started during the inspection would be
			// torn down (or have its audio session deactivated) by the previous
			// recording's completion.
			#if os(iOS)
			let finalizationSessionID: UUID? = recordingSessionID
			#else
			let finalizationSessionID: UUID? = nil
			#endif
			let finalizationIsCurrent: @MainActor (URL) -> Bool = { url in
				#if os(iOS)
				guard self.recordingSessionID == finalizationSessionID else { return false }
				#endif
				return self.recordingURL?.standardizedFileURL == url.standardizedFileURL
			}

			guard let resolvedRecordingURL = recordingURL,
				  resolvedRecordingURL.standardizedFileURL == finishedURL.standardizedFileURL else {
				AppLog.shared.recording("Recorder finished for an unexpected recording URL; ignoring callback", level: .error)
				recordingBeingProcessed = false
				return
			}

			// Derived before the inspection suspends. This recording is finished;
			// persisting it must not depend on still being the current session, but
			// re-deriving its name, date and location afterwards would stamp it
			// with the next recording's.
			let capturedName = generateAppRecordingDisplayName()
			let capturedDate = currentRecordingDate(for: resolvedRecordingURL)
			let capturedLocation = recordingLocationSnapshot()

			if flag {
				if appIsBackgrounding {
					AppLog.shared.recording("Recording finished successfully during backgrounding - processing normally")
				} else {
					AppLog.shared.recording("Recording finished successfully")
				}
			} else {
				// The delegate's flag describes the encoder, not the container.
				// Discarding the file on it alone throws away however many
				// minutes actually reached disk, so let the finalization policy
				// judge what was captured.
				AppLog.shared.recording("Recording delegate reported an unsuccessful finalization; inspecting the captured file", level: .error)
			}

			let finalization = await RecordingFinalizationPolicy.inspect(
				url: resolvedRecordingURL,
				delegateSucceeded: true
			)
			// A newer session may own the live recording state by now. That gates
			// the state writes below — never the save: abandoning it here is what
			// would leave the finished audio on disk with no Core Data row and no
			// in-memory reference, since setupRecording has replaced them all.
			let stillCurrent = finalizationIsCurrent(resolvedRecordingURL)
			if !stillCurrent {
				AppLog.shared.recording(
					"A newer recording superseded this completion during finalization; persisting it without touching live state",
					level: .debug
				)
			}

			switch finalization {
			case .rejected(let rejection):
				AppLog.shared.recording(
					"Recording finalization rejected the captured file: \(rejection)",
					level: .error
				)
				if stillCurrent {
					rejectRecordingFinalization(at: resolvedRecordingURL, rejection: rejection)
				} else {
					AppLog.shared.recording(
						"Leaving the rejected artifact of a superseded session untouched",
						level: .debug
					)
				}
			case .usable(let fileSize, let duration):
				if stillCurrent {
					// Reads live location state, so it only applies while current.
					saveLocationData(for: resolvedRecordingURL)
				}

				// New recordings are already in Whisper-optimized format (16kHz, 64kbps AAC)
				AppLog.shared.recording("Recording saved in Whisper-optimized format")

				// Add recording using workflow manager for proper UUID consistency
				if let workflowManager = workflowManager {
					let quality = AudioRecorderViewModel.getCurrentAudioQuality()

					// Create recording
					let recordingId = workflowManager.createRecording(
						url: resolvedRecordingURL,
						name: capturedName,
						date: capturedDate,
						fileSize: fileSize,
						duration: duration,
						quality: quality,
						locationData: capturedLocation
					)

					AppLog.shared.recording("Recording created with workflow manager, ID: \(recordingId)")

					// The row exists; only now may a trail parking this file go.
					#if os(iOS)
					clearDeferredRecoverySnapshotEntries(containing: resolvedRecordingURL)
					#endif

					if stillCurrent {
						// Watch audio integration removed
						self.resetRecordingLocation()
						self.recordingStartedAt = nil
						self.resetRecordingAttemptArtifacts()

						if !flag {
							errorMessage = "Recording ended unexpectedly. The audio captured before it stopped was saved."
						}
					}
				} else {
					AppLog.shared.recording("WorkflowManager not set - recording not saved to database", level: .error)
				}
			}

			if stillCurrent {
				recordingBeingProcessed = false
			}

			guard canDeactivateSession(afterFinalizing: finalizationSessionID) else { return }
			try? await self.enhancedAudioSessionManager.deactivateSession()
		}
	}
}

// MARK: - Audio Input Selection

extension AudioRecorderViewModel {

	func fetchInputs() async {
		do {
			// Temporarily configure session to get accurate input list
			try await enhancedAudioSessionManager.configureMixedAudioSession()
			let inputs = enhancedAudioSessionManager.getAvailableInputs()
			let activeInput = enhancedAudioSessionManager.getActiveInput()
			let storedPreferredInputUID = UserDefaults.standard.string(
				forKey: preferredInputDefaultsKey
			)

			// Immediately deactivate to avoid interfering with other audio
			try await enhancedAudioSessionManager.deactivateSession()

			await MainActor.run {
				availableInputs = inputs
				selectedInput = {
					if let storedUID = storedPreferredInputUID,
					   let storedInput = inputs.first(where: { $0.uid == storedUID }) {
						return storedInput
					}

					if let activeInput,
					   let matchedInput = inputs.first(where: { $0.uid == activeInput.uid }) {
						return matchedInput
					}

					return inputs.first
				}()
			}
		} catch {
			await MainActor.run {
				errorMessage = "Failed to fetch audio inputs: \(error.localizedDescription)"
			}
		}
	}

	func setPreferredInput() {
		guard let input = selectedInput else { return }

		Task {
			do {
				// Temporarily configure session to set preferred input
				try await enhancedAudioSessionManager.configureMixedAudioSession()
				try await enhancedAudioSessionManager.setPreferredInput(input)
				UserDefaults.standard.set(input.uid, forKey: preferredInputDefaultsKey)
				try await enhancedAudioSessionManager.deactivateSession()
				#if os(macOS)
				await MainActor.run {
					self.scheduleMacInputDeviceRefresh()
				}
				#endif
			} catch {
				errorMessage = "Failed to set preferred input: \(error.localizedDescription)"
				try? await enhancedAudioSessionManager.deactivateSession()
			}
		}
	}

	@MainActor
	func applySelectedInputToSession() async {
		// Get all currently available inputs
		let availableInputs = enhancedAudioSessionManager.getAvailableInputs()

		// First, try to use the currently selected input
		var inputToUse = selectedInput

		// If no input is selected, try to load from UserDefaults
		if inputToUse == nil {
			let storedPreferredInputUID = UserDefaults.standard.string(forKey: preferredInputDefaultsKey)
			if let storedUID = storedPreferredInputUID {
				// Try to find the stored input in available inputs
				inputToUse = availableInputs.first(where: { $0.uid == storedUID })

				// Update selectedInput if we found it
				if let foundInput = inputToUse {
					selectedInput = foundInput
				}
			}
		}

		// Check if the preferred input is still available
		if let preferredInput = inputToUse {
			let isStillAvailable = availableInputs.contains(where: { $0.uid == preferredInput.uid })

			if isStillAvailable {
				// Preferred input is available, use it
				do {
					try await enhancedAudioSessionManager.setPreferredInput(preferredInput)
					UserDefaults.standard.set(preferredInput.uid, forKey: preferredInputDefaultsKey)
					AppLog.shared.recording("Using preferred input: \(preferredInput.portName)")
				} catch {
					AppLog.shared.recording("Failed to set preferred input, falling back to default: \(error.localizedDescription)", level: .error)
					// Fall through to default behavior
					inputToUse = nil
				}
			} else {
				// Preferred input is no longer available, fall back to default
				AppLog.shared.recording("Preferred input no longer available, falling back to the system default")
				inputToUse = nil
			}
		}

		// If no preferred input or it's unavailable, use the platform default.
		if inputToUse == nil {
			do {
				// Clear the preferred input to let the platform use its default.
				try await enhancedAudioSessionManager.clearPreferredInput()
				// Clear the stored preference since the device is no longer available
				UserDefaults.standard.removeObject(forKey: preferredInputDefaultsKey)
				// Update selectedInput to nil so UI reflects the fallback
				selectedInput = nil
				AppLog.shared.recording("Using the system default microphone (preferred input unavailable)")
			} catch {
				// If clearing fails, the platform still falls back to its default input.
				AppLog.shared.recording(
					"Could not clear preferred input; using the system default: \(error.localizedDescription)",
					level: .debug
				)
				// Still clear the stored preference and update UI
				UserDefaults.standard.removeObject(forKey: preferredInputDefaultsKey)
				selectedInput = nil
			}
		}
	}
}

// MARK: - File Operations

extension AudioRecorderViewModel {

	func registerRecordingAttemptArtifact(at url: URL) {
		let standardizedURL = url.standardizedFileURL
		guard !recordingAttemptArtifacts.contains(where: { $0.url == standardizedURL }) else { return }
		recordingAttemptArtifacts.append(
			RecordingAttemptArtifact(
				url: standardizedURL,
				existedBeforeAttempt: FileManager.default.fileExists(atPath: standardizedURL.path)
			)
		)
	}

	func resetRecordingAttemptArtifacts() {
		recordingAttemptArtifacts.removeAll()
	}

	func removeOwnedRecordingAttemptArtifact(at url: URL) {
		let standardizedURL = url.standardizedFileURL
		guard let artifact = recordingAttemptArtifacts.first(where: { $0.url == standardizedURL }) else {
			AppLog.shared.recording(
				"Not removing unregistered recording artifact \(url.lastPathComponent)",
				level: .debug
			)
			return
		}
		guard !artifact.existedBeforeAttempt else {
			AppLog.shared.recording(
				"Not removing pre-existing recording artifact \(url.lastPathComponent)",
				level: .debug
			)
			return
		}

		guard FileManager.default.fileExists(atPath: standardizedURL.path) else { return }
		do {
			try FileManager.default.removeItem(at: standardizedURL)
			AppLog.shared.recording("Removed unusable current-attempt recording artifact", level: .debug)
		} catch {
			AppLog.shared.recording(
				"Could not remove unusable recording artifact: \(error.localizedDescription)",
				level: .error
			)
		}
	}

	func rejectRecordingFinalization(at url: URL?, rejection: RecordingFinalizationRejection) {
		#if os(iOS)
		recordingIntentActive = false
		callInterruptionTracker.removeAll()
		#endif
		if let url {
			removeOwnedRecordingAttemptArtifact(at: url)
		}

		// Only the rejected segment is discarded. Earlier segments of a
		// multi-segment recording already passed the finalization policy, so
		// wiping the whole segment list here would strand minutes of usable
		// audio on disk with nothing pointing at it.
		let rejectedURL = url?.standardizedFileURL
		let survivingSegments = recordingSegments.filter { segment in
			segment.standardizedFileURL != rejectedURL
				&& FileManager.default.fileExists(atPath: segment.path)
		}

		isRecording = false
		isStartingRecording = false
		stopBackgroundTimeMonitoring()
		recordingState = .idle
		recordingTime = 0
		stopRecordingTimer()
		audioRecorder = nil
		liveTranscriptText = ""
		recordingSegments = survivingSegments
		recordingURL = survivingSegments.last
		mainRecordingURL = survivingSegments.first
		currentSegmentIndex = max(survivingSegments.count - 1, 0)
		isInInterruption = false
		interruptionRecordingURL = nil
		recorderStoppedUnexpectedlyTime = nil
		recordingBeingProcessed = false
		resetRecordingLocation()
		errorMessage = rejection.userMessage
		if survivingSegments.isEmpty {
			recordingStartedAt = nil
			resetRecordingAttemptArtifacts()
		}
	}

	func getFileSize(url: URL) -> Int64 {
		do {
			let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
			return attributes[.size] as? Int64 ?? 0
		} catch {
			return 0
		}
	}

	func getRecordingDuration(url: URL) -> TimeInterval {
		// Prefer AVAudioPlayer's parsed duration (often more accurate/playable length)
		if let player = try? AVAudioPlayer(contentsOf: url) {
			let d = player.duration
			if d > 0 { return d }
		}
		// Fallback to AVURLAsset with precise timing
		let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
		let semaphore = DispatchSemaphore(value: 0)
		var loadedDuration: TimeInterval = 0
		Task {
			do {
				let loadedDurationValue = try await asset.load(.duration)
				loadedDuration = CMTimeGetSeconds(loadedDurationValue)
			} catch {
				AppLog.shared.recording("Failed to load duration: \(error.localizedDescription)", level: .error)
			}
			semaphore.signal()
		}
		_ = semaphore.wait(timeout: .now() + 2.0)
		if loadedDuration > 0 { return loadedDuration }
		// Final fallback to the timer value we tracked during recording
		return recordingTime
	}

	func currentRecordingDate(for url: URL?) -> Date {
		if let entry = recordingStartedAt, let url, entry.url == url {
			return entry.date
		}

		if let url,
		   let data = try? Data(contentsOf: recordingTimestampMetadataURL(for: url)),
		   let metadata = try? JSONDecoder().decode(RecordingTimestampMetadata.self, from: data) {
			return metadata.recordedAt
		}

		return Date()
	}

	func persistRecordingCapturedAt(_ date: Date, for url: URL) {
		let metadata = RecordingTimestampMetadata(recordedAt: date)
		guard let data = try? JSONEncoder().encode(metadata) else {
			return
		}

		do {
			let metadataURL = recordingTimestampMetadataURL(for: url)
			try data.write(to: metadataURL, options: .atomic)
			AppFileProtection.apply(to: metadataURL)
		} catch {
			AppLog.shared.recording("Failed to write recording timestamp metadata: \(error.localizedDescription)", level: .error)
		}
	}

	private func recordingTimestampMetadataURL(for recordingURL: URL) -> URL {
		recordingURL.deletingPathExtension().appendingPathExtension("recordingmeta")
	}
}

// MARK: - Naming Convention

extension AudioRecorderViewModel {

	/// Generates a standardized filename for app-created recordings.
	/// Includes a UUID so two recordings started within the same second cannot
	/// collide on the same URL (which would let a later start delete an earlier
	/// recording's finalized file). The `apprecording-` prefix is preserved for
	/// the various `hasPrefix("apprecording-")` checks across the app.
	func generateAppRecordingFilename() -> String {
		let timestamp = Int(Date().timeIntervalSince1970)
		return "apprecording-\(timestamp)-\(UUID().uuidString).m4a"
	}

	/// Generates a standardized display name for app-created recordings
	func generateAppRecordingDisplayName() -> String {
		Self.appRecordingDisplayName(capturedAt: recordingStartedAt?.date ?? Date())
	}

	/// The same display name for a recording whose own capture date is known.
	///
	/// A reclaimed recording is persisted while a newer session owns
	/// `recordingStartedAt`, so it must be named from its own timestamp rather
	/// than from whatever live state happens to be current.
	static func appRecordingDisplayName(capturedAt date: Date) -> String {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
		return "apprecording-\(formatter.string(from: date))"
	}

	/// Creates a standardized name for imported files
	nonisolated static func generateImportedFileName(originalName: String) -> String {
		// Remove file extension if present
		let nameWithoutExtension = (originalName as NSString).deletingPathExtension

		// Truncate to iOS standard title length (around 60 characters for display)
		let maxLength = 60
		let truncatedName = nameWithoutExtension.count > maxLength ?
			String(nameWithoutExtension.prefix(maxLength)) : nameWithoutExtension

		return "importedfile-\(truncatedName)"
	}
}
