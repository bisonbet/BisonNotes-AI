//
//  AudioRecorderViewModel+Utilities.swift
//  BisonNotes AI
//
//  Delegates, input selection, file operations, and naming helpers.
//

import Foundation
@preconcurrency import AVFoundation
import UserNotifications

// MARK: - AVAudioRecorderDelegate

extension AudioRecorderViewModel: AVAudioRecorderDelegate {
	nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
		Task { @MainActor in
			if isRecording {
				audioRecorder?.stop()
				isRecording = false
				stopRecordingTimer()
			}
			errorMessage = "Recording stopped due to an encoding error\(error.map { ": \($0.localizedDescription)" } ?? ".")"
		}
	}

	nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
		Task {
			await MainActor.run {
				// Check if we're still in recording mode - if so, this was an interruption, not a user stop
				// In this case, don't save as a finished recording - let the interruption handler deal with it
				if isRecording {
					print("⚠️ Recorder finished but still in recording mode - ignoring (interruption will be handled)")
					return
				}

				// Check if recording is already being processed by interruption handler
				// But allow processing if app is backgrounding (normal completion scenario)
				if recordingBeingProcessed && !appIsBackgrounding {
					print("⚠️ Recording already processed by interruption handler, skipping normal completion")
					recordingBeingProcessed = false // Reset flag
					return
				}

				// Check if we have multiple segments - if so, the merge will handle saving
				if recordingSegments.count > 1 {
					print("⚠️ Multiple segments detected - merge process will handle saving")
					return
				}

				// Start background task to protect Core Data save operations
				beginBackgroundTask()

				if flag {
					if appIsBackgrounding {
						print("Recording finished successfully during backgrounding - processing normally")
					} else {
						print("Recording finished successfully")
					}
					recordingBeingProcessed = true // Set flag to prevent duplicate processing

					if let recordingURL = recordingURL {
						saveLocationData(for: recordingURL)

						// New recordings are already in Whisper-optimized format (16kHz, 64kbps AAC)
						print("✅ Recording saved in Whisper-optimized format")

						// Add recording using workflow manager for proper UUID consistency
						if let workflowManager = workflowManager {
							let fileSize = getFileSize(url: recordingURL)
							let duration = getRecordingDuration(url: recordingURL)
							let quality = AudioRecorderViewModel.getCurrentAudioQuality()

							// Create display name for phone recording
							let displayName = generateAppRecordingDisplayName()

							// Create recording
							let recordingId = workflowManager.createRecording(
								url: recordingURL,
								name: displayName,
								date: Date(),
								fileSize: fileSize,
								duration: duration,
								quality: quality,
								locationData: recordingLocationSnapshot()
							)

							print("✅ Recording created with workflow manager, ID: \(recordingId)")

							// Watch audio integration removed
							self.resetRecordingLocation()
						} else {
							print("❌ WorkflowManager not set - recording not saved to database!")
						}
					}

					// Reset processing flag after successful completion
					recordingBeingProcessed = false

					// Deactivate audio session to restore high-quality music playback
					Task {
						try? await enhancedAudioSessionManager.deactivateSession()
					}
				} else {
					errorMessage = "Recording failed"
					recordingBeingProcessed = false // Reset flag on failure too

					// Also deactivate session on failure
					Task {
						try? await enhancedAudioSessionManager.deactivateSession()
					}
				}

				// End background task that protected the Core Data save operation
				self.endBackgroundTask()
			}
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
				// Keep session active for now since user likely will record soon
			} catch {
				errorMessage = "Failed to set preferred input: \(error.localizedDescription)"
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
					print("✅ Using preferred input: \(preferredInput.portName)")
				} catch {
					print("⚠️ Failed to set preferred input, falling back to default: \(error.localizedDescription)")
					// Fall through to default behavior
					inputToUse = nil
				}
			} else {
				// Preferred input is no longer available, fall back to default
				print("⚠️ Preferred input '\(preferredInput.portName)' is no longer available, falling back to iOS default")
				inputToUse = nil
			}
		}

		// If no preferred input or it's unavailable, let iOS use its default
		// iOS will automatically use the built-in microphone when no preferred input is set
		if inputToUse == nil {
			do {
				// Clear the preferred input to let iOS use its default
				try await enhancedAudioSessionManager.clearPreferredInput()
				// Clear the stored preference since the device is no longer available
				UserDefaults.standard.removeObject(forKey: preferredInputDefaultsKey)
				// Update selectedInput to nil so UI reflects the fallback
				selectedInput = nil
				print("✅ Using iOS default microphone (preferred input unavailable)")
			} catch {
				// If clearing fails, iOS will still use default, so just log it
				print("⚠️ Could not clear preferred input, iOS will use default: \(error.localizedDescription)")
				// Still clear the stored preference and update UI
				UserDefaults.standard.removeObject(forKey: preferredInputDefaultsKey)
				selectedInput = nil
			}
		}
	}
}

// MARK: - File Operations

extension AudioRecorderViewModel {

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
				print("⚠️ Failed to load duration for \(url.lastPathComponent): \(error.localizedDescription)")
			}
			semaphore.signal()
		}
		_ = semaphore.wait(timeout: .now() + 2.0)
		if loadedDuration > 0 { return loadedDuration }
		// Final fallback to the timer value we tracked during recording
		return recordingTime
	}
}

// MARK: - Naming Convention

extension AudioRecorderViewModel {

	/// Generates a standardized filename for app-created recordings
	func generateAppRecordingFilename() -> String {
		let timestamp = Date().timeIntervalSince1970
		return "apprecording-\(Int(timestamp)).m4a"
	}

	/// Generates a standardized display name for app-created recordings
	func generateAppRecordingDisplayName() -> String {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
		let timestamp = formatter.string(from: Date())
		return "apprecording-\(timestamp)"
	}

	/// Creates a standardized name for imported files
	static func generateImportedFileName(originalName: String) -> String {
		// Remove file extension if present
		let nameWithoutExtension = (originalName as NSString).deletingPathExtension

		// Truncate to iOS standard title length (around 60 characters for display)
		let maxLength = 60
		let truncatedName = nameWithoutExtension.count > maxLength ?
			String(nameWithoutExtension.prefix(maxLength)) : nameWithoutExtension

		return "importedfile-\(truncatedName)"
	}
}

// MARK: - Supporting Types

enum AudioIntegrationError: LocalizedError {
	case formatCreationFailed
	case bufferCreationFailed
	case fileCreationFailed(String)

	var errorDescription: String? {
		switch self {
		case .formatCreationFailed:
			return "Failed to create audio format"
		case .bufferCreationFailed:
			return "Failed to create audio buffer"
		case .fileCreationFailed(let details):
			return "Failed to create audio file: \(details)"
		}
	}
}
