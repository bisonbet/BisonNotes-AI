//
//  AudioRecorderViewModel+Interruptions.swift
//  BisonNotes AI
//
//  Audio interruption handling, route changes, and recording recovery.
//

import Foundation
@preconcurrency import AVFoundation
import UIKit
import UserNotifications

extension AudioRecorderViewModel {

	// MARK: - Audio Interruption Handling

	func handleAudioInterruption(_ notification: Notification) {
		// Forward to session manager for logging and restoration
		enhancedAudioSessionManager.handleAudioInterruption(notification)

		// Also ensure our recording UI/state reflects actual recorder state
		guard let userInfo = notification.userInfo,
				let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
				let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
			return
		}

		switch type {
		case .began:
			if isRecording && !isInInterruption {
				print("🎙️ Audio interruption began (e.g., incoming call) - pausing timer, waiting for CallKit to determine action")
				isInInterruption = true
				interruptionRecordingURL = recordingURL

				// Update to new state system (Phase 1)
				recordingState = .interrupted(reason: .phoneCall, startedAt: Date())

				// Clear the recorder stopped tracking since we now know it's an interruption
				recorderStoppedUnexpectedlyTime = nil
				// Pause the timer but don't stop recording yet
				// The recorder may continue in the background, or iOS may pause it
				// CallKit observer will determine resume strategy based on call duration
				stopRecordingTimer() // Pause timer during interruption
			}
		case .ended:
			// Check if we should resume recording after interruption ends
			// We check interruptionRecordingURL to know if we were recording before the interruption
			// This handles cases where recording was stopped during the interruption or took a long time
			guard isInInterruption, interruptionRecordingURL != nil else {
				// Not in an interruption state, or no recording URL to resume
				print("⚠️ Interruption ended but we weren't in an interruption state or have no recording URL")
				return
			}

			isInInterruption = false

			// Check if CallKit deferred a long-call decision while we were backgrounded.
			// If so, prompt the user instead of auto-resuming.
			#if !targetEnvironment(macCatalyst)
			if let callDuration = deferredCallDuration, callDuration >= SHORT_CALL_THRESHOLD {
				print("📞 Deferred long call detected (\(callDuration)s ≥ \(SHORT_CALL_THRESHOLD)s threshold) — asking user whether to resume")
				deferredCallDuration = nil
				recordingState = .waitingForUserDecision(callDuration: callDuration)
				Task { @MainActor in
					await promptUserForResumeDecision(callDuration: callDuration)
				}
				return
			}
			deferredCallDuration = nil // Clear for short or no-duration calls
			#endif

			if let options = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
				let interruptionOptions = AVAudioSession.InterruptionOptions(rawValue: options)

				if interruptionOptions.contains(.shouldResume) {
					// User declined/ignored the call - definitely resume recording
					print("🔄 Interruption ended with shouldResume - user declined/ignored call, resuming recording")
					let urlToResume = interruptionRecordingURL // Capture before clearing
					interruptionRecordingURL = nil
					Task { @MainActor in
						await resumeRecordingAfterInterruption(url: urlToResume)
					}
				} else {
					// No .shouldResume flag - this could mean:
					// 1. Call was answered (should stop)
					// 2. Call was declined but iOS didn't set the flag (should resume)
					// 3. Call was answered then hung up (should resume)

					// Try to resume anyway - if it fails, we'll handle it
					print("🔄 Interruption ended without shouldResume - attempting to resume (may have been declined or hung up)")
					let urlToResume = interruptionRecordingURL // Capture before clearing
					interruptionRecordingURL = nil
					Task { @MainActor in
						await resumeRecordingAfterInterruption(url: urlToResume)
						// If resume fails, it will call handleInterruptedRecording internally
					}
				}
			} else {
				// No options provided - try to resume anyway (might be a declined call)
				// iOS sometimes doesn't set .shouldResume for declined calls, but we should try
				print("🔄 Interruption ended without options - attempting to resume (may have been declined call)")
				let urlToResume = interruptionRecordingURL // Capture before clearing
				interruptionRecordingURL = nil
				Task { @MainActor in
					await resumeRecordingAfterInterruption(url: urlToResume)
				}
			}
		@unknown default:
			break
		}
	}

	/// Attempt to resume recording after an unexpected stop (e.g., declined call without interruption notification)
	@MainActor
	func attemptResumeAfterUnexpectedStop() async {
		guard !isResuming else {
			print("⏳ Resume already in progress, skipping duplicate attemptResumeAfterUnexpectedStop")
			return
		}
		isResuming = true
		defer { isResuming = false }

		print("🔄 Attempting to resume recording after unexpected stop (likely declined call)")

		// Use current recording URL
		guard let url = recordingURL else {
			print("❌ No recording URL available to resume")
			errorMessage = "Could not resume recording: no recording file found"
			isRecording = false
			return
		}

		// Check if the file still exists
		guard FileManager.default.fileExists(atPath: url.path) else {
			print("❌ Recording file no longer exists")
			errorMessage = "Could not resume recording: file was removed"
			isRecording = false
			return
		}

		// Step 1: Finalize the current segment — stop the recorder to flush audio buffers to disk.
		// Must stop BEFORE reading file size, otherwise the file may appear nearly empty.
		audioRecorder?.stop()
		audioRecorder = nil

		let fileSizeAfterStop = getFileSize(url: url)
		print("📊 Current segment file size after finalization: \(fileSizeAfterStop) bytes")

		// Add this segment to our list if it's not already there
		if !recordingSegments.contains(url) {
			recordingSegments.append(url)
			print("✅ Saved segment \(recordingSegments.count): \(url.lastPathComponent)")
		}

		// Add a small delay to give iOS time to fully release the audio session after the call
		do {
			try await Task.sleep(nanoseconds: 500_000_000) // 0.5 second delay
		} catch {
			// Sleep was cancelled, but continue anyway
		}

		// Step 2: Create a new segment file for continuation
		currentSegmentIndex += 1
		let newSegmentURL = createSegmentURL(baseURL: mainRecordingURL ?? url, segmentIndex: currentSegmentIndex)
		print("📝 Creating new segment \(currentSegmentIndex + 1): \(newSegmentURL.lastPathComponent)")

		// Try to restore audio session and start recording to new segment
		do {
			try await enhancedAudioSessionManager.restoreAudioSession()

			// Create a new recorder for the new segment
			let selectedQuality = AudioQuality.whisperOptimized
			let settings = selectedQuality.settings

			audioRecorder = try AVAudioRecorder(url: newSegmentURL, settings: settings)
			audioRecorder?.delegate = self
			audioRecorder?.isMeteringEnabled = true // Enable metering for silence detection

			// Start recording
			audioRecorder?.record()

			// Brief delay to let the session stabilize before verifying
			try? await Task.sleep(nanoseconds: 150_000_000) // 150ms

			// Verify it's actually recording
			if let recorder = audioRecorder, recorder.isRecording {
				print("✅ Recording resumed with new segment - previous audio preserved!")
				recordingSegments.append(newSegmentURL)
				recordingURL = newSegmentURL // Update to the new segment
				isRecording = true
				recordingState = .recording
				lastCheckpointTime = Date() // Reset checkpoint time on resume
				startRecordingTimer()
				errorMessage = nil
				recorderStoppedUnexpectedlyTime = nil
			} else {
				print("❌ Failed to resume recording - recorder not active, treating as real interruption")
				handleInterruptedRecording(reason: "Microphone became unavailable or recording was interrupted")
			}
		} catch {
			print("❌ Failed to resume recording: \(error.localizedDescription), treating as real interruption")
			handleInterruptedRecording(reason: "Microphone became unavailable: \(error.localizedDescription)")
		}
	}

	@MainActor
	func resumeRecordingAfterInterruption(url: URL?) async {
		// Check if the recorder is still valid and recording (best case — iOS just paused the session)
		if let recorder = audioRecorder, recorder.isRecording {
			print("✅ Recorder is still active, resuming timer")
			startRecordingTimer()
			errorMessage = nil
			isInInterruption = false
			recordingState = .recording
			return
		}

		// From here we need to create a new segment — guard against concurrent attempts
		guard !isResuming else {
			print("⏳ Resume already in progress, skipping duplicate resumeRecordingAfterInterruption")
			return
		}
		isResuming = true
		defer { isResuming = false }

		print("🔄 Attempting to resume recording after interruption")

		// Recorder was stopped by iOS, need to restart it
		guard let url = url else {
			print("❌ No recording URL available to resume")
			errorMessage = "Could not resume recording: no recording file found"
			isRecording = false
			isInInterruption = false
			return
		}

		// Check if the file still exists
		guard FileManager.default.fileExists(atPath: url.path) else {
			print("❌ Recording file no longer exists")
			errorMessage = "Could not resume recording: file was removed"
			isRecording = false
			isInInterruption = false
			return
		}

		// Step 1: Finalize the current segment — stop the recorder to flush audio buffers to disk.
		// Must stop BEFORE reading file size, otherwise the file may appear nearly empty.
		audioRecorder?.stop()
		audioRecorder = nil

		let fileSizeAfterStop = getFileSize(url: url)
		print("📊 Current segment file size after finalization: \(fileSizeAfterStop) bytes")

		// Add this segment to our list if it's not already there
		if !recordingSegments.contains(url) {
			recordingSegments.append(url)
			print("✅ Saved segment \(recordingSegments.count): \(url.lastPathComponent)")
		}

		// Add a small delay to give iOS time to fully release the audio session after the interruption
		do {
			try await Task.sleep(nanoseconds: 500_000_000) // 0.5 second delay
		} catch {
			// Sleep was cancelled, but continue anyway
		}

		// Step 2: Create a new segment file for continuation
		currentSegmentIndex += 1
		let newSegmentURL = createSegmentURL(baseURL: mainRecordingURL ?? url, segmentIndex: currentSegmentIndex)
		print("📝 Creating new segment \(currentSegmentIndex + 1): \(newSegmentURL.lastPathComponent)")

		// Try to restore audio session and start recording to new segment
		do {
			try await enhancedAudioSessionManager.restoreAudioSession()

			// Create a new recorder for the new segment
			let selectedQuality = AudioQuality.whisperOptimized
			let settings = selectedQuality.settings

			audioRecorder = try AVAudioRecorder(url: newSegmentURL, settings: settings)
			audioRecorder?.delegate = self
			audioRecorder?.isMeteringEnabled = true // Enable metering for silence detection

			// Start recording
			audioRecorder?.record()

			// Brief delay to let the session stabilize before verifying
			try? await Task.sleep(nanoseconds: 150_000_000) // 150ms

			// Verify it's actually recording
			if let recorder = audioRecorder, recorder.isRecording {
				print("✅ Recording resumed with new segment - previous audio preserved!")
				recordingSegments.append(newSegmentURL)
				recordingURL = newSegmentURL // Update to the new segment
				isRecording = true
				recordingState = .recording
				lastCheckpointTime = Date() // Reset checkpoint time on resume
				startRecordingTimer()
				errorMessage = nil
				isInInterruption = false
			} else {
				print("❌ Failed to resume recording - recorder not active")
				errorMessage = "Could not resume recording: recorder failed to start"
				isRecording = false
				audioRecorder = nil
				isInInterruption = false
			}
		} catch {
			print("❌ Failed to resume recording: \(error.localizedDescription)")
			errorMessage = "Could not resume recording: \(error.localizedDescription)"
			isRecording = false
			audioRecorder = nil
			isInInterruption = false
		}
	}

	// MARK: - Route Change Handling

	func handleRouteChange(_ notification: Notification) {
		guard let userInfo = notification.userInfo,
				let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
				let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
			return
		}

		switch reason {
		case .oldDeviceUnavailable:
			// Input device became unavailable (e.g., Bluetooth mic disconnected)
			if isRecording {
				let previousRoute = userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
				let wasUsingMicrophone = previousRoute?.inputs.first != nil

				if wasUsingMicrophone {
					print("🎙️ Microphone disconnected during recording (Phase 2)")
					Task { @MainActor in
						await handleMicrophoneDisconnected()
					}
				}
			} else {
				// Not recording, just update the selected input
				Task { @MainActor in
					await applySelectedInputToSession()
				}
			}

		case .newDeviceAvailable:
			// New audio device connected (Phase 2)
			print("🎙️ New audio device available")
			Task { @MainActor in
				await handleNewAudioDeviceAvailable(notification: notification)
			}

		case .categoryChange:
			// Category changed, check if we need to recover
			if isRecording {
				print("🎙️ Audio route changed - category change detected during recording")
				Task { @MainActor in
					await handleMicrophoneDisconnected()
				}
			}
		default:
			break
		}
	}

	@MainActor
	func handleMicrophoneUnavailableDuringRecording() async {
		guard isRecording, let currentURL = recordingURL else { return }

		// Check if the preferred input is still available
		let availableInputs = enhancedAudioSessionManager.getAvailableInputs()
		let preferredInputUID = UserDefaults.standard.string(forKey: preferredInputDefaultsKey)

		var preferredInputStillAvailable = false
		if let storedUID = preferredInputUID {
			preferredInputStillAvailable = availableInputs.contains(where: { $0.uid == storedUID })
		}

		if !preferredInputStillAvailable {
			print("⚠️ Preferred microphone is no longer available, switching to iOS default")

			// Switch to default microphone
			do {
				try await enhancedAudioSessionManager.clearPreferredInput()
				UserDefaults.standard.removeObject(forKey: preferredInputDefaultsKey)
				selectedInput = nil

				// Check if recording is still active
				if let recorder = audioRecorder, recorder.isRecording {
					// Recording is still active, it should automatically use the default mic
					print("✅ Recording continues with default microphone")
					errorMessage = "Microphone switched to default (previous device disconnected)"
				} else {
					// Recording stopped, need to restart
					print("⚠️ Recording stopped, restarting with default microphone")
					await restartRecordingWithDefaultMicrophone(currentURL: currentURL)
				}
			} catch {
				print("❌ Failed to switch to default microphone: \(error.localizedDescription)")
				// Try to continue anyway - iOS might have already switched
				if let recorder = audioRecorder, !recorder.isRecording {
					await restartRecordingWithDefaultMicrophone(currentURL: currentURL)
				}
			}
		}
	}

	@MainActor
	func restartRecordingWithDefaultMicrophone(currentURL: URL) async {
		// Stop current recording
		audioRecorder?.stop()
		stopRecordingTimer()

		// Save the current recording segment
		if FileManager.default.fileExists(atPath: currentURL.path) {
			let fileSize = getFileSize(url: currentURL)
			if fileSize > 1024 { // At least 1KB
				print("💾 Saving current recording segment before switching microphones")
				saveLocationData(for: currentURL)

				// Process the current segment
				if let workflowManager = workflowManager {
					let quality = AudioRecorderViewModel.getCurrentAudioQuality()
					let originalFilename = currentURL.deletingPathExtension().lastPathComponent
					let duration = getRecordingDuration(url: currentURL)

					// Get file creation date, or use current date as fallback
					let recordingDate: Date
					do {
						let attributes = try FileManager.default.attributesOfItem(atPath: currentURL.path)
						if let creationDate = attributes[.creationDate] as? Date {
							recordingDate = creationDate
						} else {
							recordingDate = Date()
						}
					} catch {
						recordingDate = Date()
					}

					_ = workflowManager.createRecording(
						url: currentURL,
						name: originalFilename,
						date: recordingDate,
						fileSize: fileSize,
						duration: duration,
						quality: quality,
						locationData: recordingStartLocationData
					)
				}
			}
		}

		// Clear the recording URL so we can start fresh
		recordingURL = nil
		recordingTime = 0

		// Switch to default microphone
		do {
			try await enhancedAudioSessionManager.clearPreferredInput()
			UserDefaults.standard.removeObject(forKey: preferredInputDefaultsKey)
			selectedInput = nil

			// Ensure audio session is still configured
			try await enhancedAudioSessionManager.configureMixedAudioSession()

			// Start new recording with default microphone
			print("🎙️ Restarting recording with default microphone")
			setupRecording()

			// Update error message to inform user
			errorMessage = "Recording continued with default microphone (previous device disconnected)"
		} catch {
			print("❌ Failed to restart recording: \(error.localizedDescription)")
			errorMessage = "Recording stopped: Failed to switch to default microphone"
			isRecording = false
			audioRecorder = nil
		}
	}

	// MARK: - Interrupted Recording Recovery

	@MainActor
	func handleInterruptedRecording(reason: String) {
		print("🚨 Handling interrupted recording: \(reason)")

		// Prevent duplicate processing
		guard !recordingBeingProcessed else {
			print("⚠️ Recording already being processed, skipping duplicate interruption handling")
			return
		}
		recordingBeingProcessed = true

		// Clear interruption state
		isInInterruption = false
		interruptionRecordingURL = nil
		recorderStoppedUnexpectedlyTime = nil

		// Stop the recorder and timer immediately
		audioRecorder?.stop()
		isRecording = false
		stopRecordingTimer()

		// Send immediate notification about the interruption (this is a real mic takeover)
		if let recordingURL = recordingURL {
			Task {
				await sendInterruptionNotificationImmediately(reason: reason, recordingURL: recordingURL)
				await recoverInterruptedRecording(url: recordingURL, reason: reason)
			}
		}

		// Update error message to inform user
		errorMessage = "Recording stopped: \(reason). The recording has been saved."

		// Deactivate audio session to restore high-quality music playback
		Task {
			try? await enhancedAudioSessionManager.deactivateSession()
		}

		// Clean up recorder
		audioRecorder = nil

		// Background task will be managed by recoverInterruptedRecording
	}

	func recoverInterruptedRecording(url: URL, reason: String) async {
		print("💾 Attempting to recover interrupted recording at: \(url.path)")

		// Start background task to protect file recovery and Core Data save operations
		await MainActor.run {
			beginBackgroundTask()
		}

		// Check if the file exists and has meaningful content
		guard FileManager.default.fileExists(atPath: url.path) else {
			print("❌ No recording file found for recovery")
			await sendInterruptionNotification(success: false, reason: reason, filename: url.lastPathComponent)
			await MainActor.run {
				endBackgroundTask()
			}
			return
		}

		let fileSize = getFileSize(url: url)
		guard fileSize > 1024 else { // Must be at least 1KB to be meaningful
			print("❌ Recording file too small to recover (\(fileSize) bytes)")
			// Clean up the tiny file
			try? FileManager.default.removeItem(at: url)
			await sendInterruptionNotification(success: false, reason: reason, filename: url.lastPathComponent)
			await MainActor.run {
				endBackgroundTask()
			}
			return
		}

		let duration = getRecordingDuration(url: url)
		guard duration > 1.0 else { // Must be at least 1 second
			print("❌ Recording duration too short to recover (\(duration) seconds)")
			// Clean up the short recording
			try? FileManager.default.removeItem(at: url)
			await sendInterruptionNotification(success: false, reason: reason, filename: url.lastPathComponent)
			await MainActor.run {
				endBackgroundTask()
			}
			return
		}

		print("✅ Recording has meaningful content: \(fileSize) bytes, \(duration) seconds")

		// Save location data if available
		saveLocationData(for: url)

		// Add the recording using workflow manager for proper UUID consistency
		if let workflowManager = workflowManager {
			let quality = AudioRecorderViewModel.getCurrentAudioQuality()

			// Use original filename for recording name to maintain consistency
			let originalFilename = url.deletingPathExtension().lastPathComponent
			let displayName = "\(originalFilename) (interrupted)"

			// Core Data operations should happen on main thread
			await MainActor.run {
				// Create recording entry using original URL to maintain file consistency
					let recordingId = workflowManager.createRecording(
						url: url,
						name: displayName,
						date: Date(),
						fileSize: fileSize,
						duration: duration,
						quality: quality,
						locationData: recordingLocationSnapshot()
					)

					print("✅ Interrupted recording recovered with workflow manager, ID: \(recordingId)")

					// Post notification to refresh UI
					NotificationCenter.default.post(name: NSNotification.Name("RecordingAdded"), object: nil)

					// Reset processing flag
					recordingBeingProcessed = false
					resetRecordingLocation()

					// End background task after successful recovery and save
					endBackgroundTask()
				}

			// Don't send additional notification - already sent immediate notification

		} else {
			print("❌ WorkflowManager not set - interrupted recording not saved to database!")
			await sendInterruptionNotification(success: false, reason: reason, filename: url.lastPathComponent)

			// Reset processing flag even on failure
			await MainActor.run {
				recordingBeingProcessed = false
				// End background task even on failure
				endBackgroundTask()
			}
		}
	}

	func checkForUnprocessedRecording() async {
		print("🔍 checkForUnprocessedRecording called - recordingBeingProcessed: \(recordingBeingProcessed), isRecording: \(isRecording)")

		// CRITICAL: Never recover a recording that is still active
		if isRecording {
			print("🔍 Recording is still active, skipping recovery check")
			return
		}

		// Prevent duplicate recovery attempts (both flag and time-based)
		let now = Date()
		if recordingBeingProcessed || now.timeIntervalSince(lastRecoveryAttempt) < 2.0 {
			print("🔍 Recovery already in progress or attempted recently, skipping duplicate attempt")
			return
		}

		lastRecoveryAttempt = now

		// Check if there's a recording file that exists but wasn't processed
		guard let recordingURL = recordingURL else {
			print("🔍 No recording URL to check")
			return
		}

		print("🔍 Checking recording URL: \(recordingURL.path)")

		// Check if file exists on filesystem
		guard FileManager.default.fileExists(atPath: recordingURL.path) else {
			print("🔍 No unprocessed recording file found")
			return
		}

		let fileSize = getFileSize(url: recordingURL)
		guard fileSize > 1024 else { // Must be at least 1KB
			print("🔍 Found recording file but it's too small to process (\(fileSize) bytes)")
			return
		}

		// Check if this recording already exists in the database
		let existingRecordingName: String? = await MainActor.run { [appCoordinator, recordingURL] in
			guard
				let appCoordinator,
				let recording = appCoordinator.getRecording(url: recordingURL)
			else { return nil }
			return recording.recordingName ?? "unknown"
		}

		// Exit if recording already exists
		if let existingRecordingName = existingRecordingName {
			print("🔍 Recording already exists in database: \(existingRecordingName)")
			print("🔍 Recording already processed, clearing recording URL")
			await MainActor.run {
				self.recordingURL = nil // Clear so we don't keep checking
			}
			return
		}

		// Set flag to prevent duplicate processing
		recordingBeingProcessed = true

		print("🔄 Found unprocessed recording from backgrounding, recovering it now")

		// Process the unprocessed recording
		await recoverUnprocessedRecording(url: recordingURL)
	}

	func recoverUnprocessedRecording(url: URL) async {
		print("💾 Recovering unprocessed recording at: \(url.path)")

		let fileSize = getFileSize(url: url)
		let duration = getRecordingDuration(url: url)

		print("✅ Unprocessed recording has content: \(fileSize) bytes, \(duration) seconds")

		// Save location data if available
		saveLocationData(for: url)

		// Add the recording using workflow manager
		if let workflowManager = workflowManager {
			let quality = AudioRecorderViewModel.getCurrentAudioQuality()

			// Use original filename for recording name
			let originalFilename = url.deletingPathExtension().lastPathComponent
			let displayName = "\(originalFilename) (recovered from background)"

			// Core Data operations should happen on main thread
			await MainActor.run {
				let recordingId = workflowManager.createRecording(
					url: url,
					name: displayName,
					date: Date(),
					fileSize: fileSize,
					duration: duration,
					quality: quality,
					locationData: recordingLocationSnapshot()
				)

					print("✅ Unprocessed recording recovered with workflow manager, ID: \(recordingId)")

					// Post notification to refresh UI
					NotificationCenter.default.post(name: NSNotification.Name("RecordingAdded"), object: nil)

					// Clear the recording URL since it's now processed
					self.recordingURL = nil
					self.recordingBeingProcessed = false
					self.resetRecordingLocation()
				}

			// Send notification to user about recovery (with slight delay to improve visibility)
			await sendRecoveryNotification(filename: displayName)
		} else {
			print("❌ WorkflowManager not set - cannot recover unprocessed recording!")
		}
	}

	// MARK: - Notification Helpers

	func sendInterruptionNotification(success: Bool, reason: String, filename: String) async {
		let title = success ? "Recording Saved" : "Recording Lost"
		let body = success
			? "Your recording was interrupted but has been saved: \(filename.prefix(30))..."
			: "Recording was interrupted and could not be saved: \(reason)"

		// Send notification using UNUserNotificationCenter
		let center = UNUserNotificationCenter.current()

		// Check/request permission
		let settings = await center.notificationSettings()
		var hasPermission = settings.authorizationStatus == .authorized

		if settings.authorizationStatus == .notDetermined {
			do {
				hasPermission = try await center.requestAuthorization(options: [.alert, .badge, .sound])
			} catch {
				print("❌ Error requesting notification permission: \(error)")
				return
			}
		}

		guard hasPermission else {
			print("📱 Notification permission denied - cannot send interruption notification")
			return
		}

		// Create notification content
		let content = UNMutableNotificationContent()
		content.title = title
		content.body = body
		content.sound = .default
		content.userInfo = [
			"type": "recording_interruption",
			"success": success,
			"reason": reason,
			"filename": filename
		]

		// Create notification request
		let request = UNNotificationRequest(
			identifier: "recording_interruption_\(UUID().uuidString)",
			content: content,
			trigger: nil // Immediate delivery
		)

		do {
			try await center.add(request)
			print("📱 Sent interruption notification: \(title) - \(body)")
		} catch {
			print("❌ Failed to send interruption notification: \(error)")
		}
	}

	func sendRecoveryNotification(filename: String) async {
		let title = "Recording Recovered"
		let body = "Found and saved your recording from when the app was in background: \(filename.prefix(30))..."

		// Check app state for notification timing
		let appState = await MainActor.run { UIApplication.shared.applicationState }
		print("📱 App state when sending notification: \(appState.rawValue) (0=active, 1=inactive, 2=background)")

		// Use the proven BackgroundProcessingManager notification system
		_ = await MainActor.run {
			Task {
				// Add a small delay to increase chances of notification being visible
				try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

				let backgroundManager = BackgroundProcessingManager.shared
				await backgroundManager.sendNotification(
					title: title,
					body: body,
					identifier: "recording_recovery_\(UUID().uuidString)",
					userInfo: [
						"type": "recovery",
						"filename": filename
					]
				)

				print("📱 Sent recovery notification via BackgroundProcessingManager: \(title)")
			}
		}
	}

	func sendInterruptionNotificationImmediately(reason: String, recordingURL: URL) async {
		print("📱 Sending immediate interruption notification for mic takeover")

		let title = "Recording Interrupted"
		let body = "Your recording was stopped by another app but has been saved: \(recordingURL.lastPathComponent)"

		_ = await MainActor.run {
			Task {
				let backgroundManager = BackgroundProcessingManager.shared
				await backgroundManager.sendNotification(
					title: title,
					body: body,
					identifier: "recording_interrupted_\(UUID().uuidString)",
					userInfo: [
						"type": "recording_interrupted",
						"reason": reason,
						"filename": recordingURL.lastPathComponent
					]
				)

				print("📱 Sent immediate interruption notification: \(title)")
			}
		}
	}

	func scheduleRecordingInterruptedNotification(recordingURL: URL) async {
		print("📱 Scheduling notification for interrupted recording while app is backgrounded")

		// Send notification while we're still in background
		let title = "Recording Interrupted"
		let body = "Your recording was interrupted when the app went to background. Don't worry - it will be saved when you return to the app!"

		_ = await MainActor.run {
			Task {
				// Small delay to ensure we're fully backgrounded
				try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

				let backgroundManager = BackgroundProcessingManager.shared
				await backgroundManager.sendNotification(
					title: title,
					body: body,
					identifier: "recording_interrupted_\(UUID().uuidString)",
					userInfo: [
						"type": "recording_interrupted",
						"filename": recordingURL.lastPathComponent
					]
				)

				print("📱 Sent background interruption notification: \(title)")
			}
		}
	}

	func generateInterruptedRecordingDisplayName(reason: String) -> String {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
		let timestamp = formatter.string(from: Date())

		// Create a descriptive name based on the interruption reason
		let reasonPrefix = if reason.contains("interrupted by another app") {
			"interrupted"
		} else if reason.contains("unavailable") || reason.contains("disconnected") {
			"device-lost"
		} else {
			"stopped"
		}

		return "apprecording-\(reasonPrefix)-\(timestamp)"
	}
}
