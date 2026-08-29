//
//  AudioRecorderViewModel+Interruptions.swift
//  BisonNotes AI
//
//  Audio interruption handling, route changes, and recording recovery.
//

import Foundation
@preconcurrency import AVFoundation
#if canImport(UIKit)
import UIKit
#endif
import UserNotifications

extension AudioRecorderViewModel {

	// MARK: - Audio Interruption Handling

	#if os(iOS)
	func handleAudioInterruption(_ notification: Notification) {
		guard let userInfo = notification.userInfo,
				let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
				let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
			return
		}
		let shouldResume = (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt)
			.map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) }
			?? false
		handleAudioInterruption(type: type, shouldResume: shouldResume)
	}

	func handleAudioInterruption(
		type: AVAudioSession.InterruptionType,
		shouldResume: Bool
	) {
		switch type {
		case .began:
			handleAudioInterruptionBegan()
		case .ended:
			handleAudioInterruptionEnded(shouldResume: shouldResume)
		@unknown default:
			break
		}
	}

	private func handleAudioInterruptionBegan() {
		guard recordingIntentActive || isRecording else {
			AppLog.shared.audioSession("Ignoring interruption begin without active recording intent", level: .debug)
			return
		}
		guard !isInInterruption else {
			AppLog.shared.audioSession("Ignoring duplicate interruption begin", level: .debug)
			return
		}

		let interruptionDate = Date()
		interruptionEndHandled = false
		isInInterruption = true
		deferredCallDuration = nil
		interruptionRecordingURL = recordingURL
		recordingState = .interrupted(reason: .phoneCall, startedAt: interruptionDate)
		recorderStoppedUnexpectedlyTime = nil
		stopRecordingTimer()
		recordInterruptionTransition()
		if let recordingSessionID {
			recoveryCoordinator.markInterrupted(for: recordingSessionID)
		}
		AppLog.shared.audioSession(
			"Audio interruption began; waiting for one coordinated recovery request"
		)
	}

	private func handleAudioInterruptionEnded(shouldResume: Bool) {
		guard !interruptionEndHandled else {
			AppLog.shared.audioSession("Ignoring duplicate interruption ended event", level: .debug)
			return
		}
		guard case .interrupted = recordingState,
			  isInInterruption || interruptionRecordingURL != nil,
			  recordingIntentActive,
			  let url = interruptionRecordingURL ?? recordingURL else {
			AppLog.shared.audioSession("Ignoring interruption ended without a matching active interruption", level: .debug)
			return
		}
		if callInterruptionTracker.hasActiveCalls {
			AppLog.shared.audioSession(
				"Audio interruption ended while a CallKit call is still active; waiting for its correlated end event",
				level: .debug
			)
			return
		}

		if let callDuration = deferredCallDuration, callDuration >= SHORT_CALL_THRESHOLD {
			AppLog.shared.audioSession("Deferred long call detected (\(callDuration)s >= \(SHORT_CALL_THRESHOLD)s threshold) - asking user whether to resume")
			interruptionEndHandled = true
			isInInterruption = false
			deferredCallDuration = nil
			recordingState = .waitingForUserDecision(callDuration: callDuration)
			Task { @MainActor in
				await promptUserForResumeDecision(callDuration: callDuration)
			}
			return
		}
		deferredCallDuration = nil
		isInInterruption = false
		interruptionEndHandled = true
		AppLog.shared.audioSession(
			"Audio interruption ended (shouldResume: \(shouldResume)); requesting coordinated recovery"
		)
		Task { @MainActor [weak self] in
			await self?.requestAudioRecovery(
				trigger: .interruptionEnded,
				recordingURL: url
			)
		}
	}
	#else
	// macOS: AVAudioSession interruptions do not exist. Device-change handling
	// arrives with Core Audio listeners in Phase 2.3.
	func handleAudioInterruption(_ notification: Notification) {}
	#endif

	/// Attempt to resume recording after an unexpected stop (e.g., declined call without interruption notification)
	@MainActor
	func attemptResumeAfterUnexpectedStop() async {
		#if os(iOS)
		guard let url = recordingURL else {
			AppLog.shared.audioSession("Unexpected recorder stop had no current segment", level: .error)
			return
		}
		let trigger: AudioRecoveryTrigger = appIsBackgrounding
			? .unexpectedBackgroundStop
			: .foregroundReconciliation
		await requestAudioRecovery(trigger: trigger, recordingURL: url)
		#endif
	}

	@MainActor
	func resumeRecordingAfterInterruption(url: URL?) async {
		#if os(iOS)
		guard let url = url ?? recordingURL else {
			AppLog.shared.audioSession("Interruption recovery had no current segment", level: .error)
			return
		}
		await requestAudioRecovery(trigger: .interruptionEnded, recordingURL: url)
		#endif
	}

	// MARK: - Route Change Handling

	#if os(iOS)
	func handleRouteChange(_ notification: Notification) {
		guard let userInfo = notification.userInfo,
				let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
				let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
			return
		}
		let wasUsingMicrophone = (userInfo[AVAudioSessionRouteChangePreviousRouteKey]
			as? AVAudioSessionRouteDescription)?.inputs.isEmpty == false
		handleRouteChange(reason: reason, wasUsingMicrophone: wasUsingMicrophone)
	}

	func handleRouteChange(
		reason: AVAudioSession.RouteChangeReason,
		wasUsingMicrophone: Bool
	) {
		lastRouteChangeReason = "\(String(describing: reason)) (raw: \(reason.rawValue))"
		switch reason {
		case .oldDeviceUnavailable:
			// Input device became unavailable (e.g., Bluetooth mic disconnected)
			if isRecording {
				if wasUsingMicrophone {
					AppLog.shared.audioSession("Microphone disconnected during recording")
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
			AppLog.shared.audioSession("New audio device available")
			let routeChangeNotification = Notification(
				name: AVAudioSession.routeChangeNotification,
				object: nil,
				userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue]
			)
			Task { @MainActor in
				await handleNewAudioDeviceAvailable(notification: routeChangeNotification)
			}

		case .categoryChange:
			// Category changed, check if we need to recover
			if isRecording {
				AppLog.shared.audioSession("Audio route changed - category change detected during recording")
				Task { @MainActor in
					await handleMicrophoneDisconnected()
				}
			}
		default:
			break
		}
	}
	#else
	func handleRouteChange(_ notification: Notification) {}
	#endif

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
			AppLog.shared.audioSession("Preferred microphone no longer available, switching to iOS default")

			// Switch to default microphone
			do {
				try await enhancedAudioSessionManager.clearPreferredInput()
				UserDefaults.standard.removeObject(forKey: preferredInputDefaultsKey)
				selectedInput = nil

				// Check if recording is still active
				if let recorder = audioRecorder, recorder.isRecording {
					// Recording is still active, it should automatically use the default mic
					AppLog.shared.audioSession("Recording continues with default microphone")
					errorMessage = "Microphone switched to default (previous device disconnected)"
				} else {
					// Recording stopped, need to restart
					AppLog.shared.audioSession("Recording stopped, restarting with default microphone")
					await restartRecordingWithDefaultMicrophone(currentURL: currentURL)
				}
			} catch {
				AppLog.shared.audioSession("Failed to switch to default microphone: \(error.localizedDescription)", level: .error)
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
			switch await RecordingFinalizationPolicy.inspect(url: currentURL, delegateSucceeded: true) {
			case .rejected(let rejection):
				AppLog.shared.audioSession(
					"Current segment was not usable before microphone switch: \(rejection)",
					level: .error
				)
				removeOwnedRecordingAttemptArtifact(at: currentURL)
			case .usable(let fileSize, let duration):
				AppLog.shared.audioSession("Saving current recording segment before switching microphones")
				saveLocationData(for: currentURL)

				// Process the current segment
				if let workflowManager = workflowManager {
					let quality = AudioRecorderViewModel.getCurrentAudioQuality()
					let originalFilename = currentURL.deletingPathExtension().lastPathComponent
					let recordingDate = currentRecordingDate(for: currentURL)

					_ = workflowManager.createRecording(
						url: currentURL,
						name: originalFilename,
						date: recordingDate,
						fileSize: fileSize,
						duration: duration,
						quality: quality,
						locationData: recordingStartLocationData
					)
					recordingStartedAt = nil
					resetRecordingAttemptArtifacts()
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

			// Ensure recording resumes with exclusive audio so device playback
			// does not bleed into the new segment.
			try await enhancedAudioSessionManager.configureBackgroundRecording()

			// Start new recording with default microphone
			AppLog.shared.audioSession("Restarting recording with default microphone")
			setupRecording()

			// Update error message to inform user
			errorMessage = "Recording continued with default microphone (previous device disconnected)"
		} catch {
			AppLog.shared.audioSession("Failed to restart recording: \(error.localizedDescription)", level: .error)
			errorMessage = "Recording stopped: Failed to switch to default microphone"
			isRecording = false
			audioRecorder = nil
		}
	}

	// MARK: - Interrupted Recording Recovery

	@MainActor
	func handleInterruptedRecording(reason: String) {
		AppLog.shared.audioSession("Handling interrupted recording: \(reason)")
		#if os(iOS)
		let terminalRecordingSessionID = recordingSessionID
		recordingIntentActive = false
		recoveryCoordinator.invalidateRecordingSession(reason: "terminal interruption: \(reason)")
		callInterruptionTracker.removeAll()
		#endif

		// Prevent duplicate processing
		guard !recordingBeingProcessed else {
			AppLog.shared.audioSession("Recording already being processed, skipping duplicate interruption handling", level: .debug)
			return
		}
		recordingBeingProcessed = true

		// Clear interruption state
		isInInterruption = false
		interruptionRecordingURL = nil
		recorderStoppedUnexpectedlyTime = nil

		// Stop the recorder and timer immediately
		#if os(iOS)
		if let recordingURL {
			recoveryFinalizedSegmentURLs.insert(recordingURL.standardizedFileURL)
		}
		#endif
		audioRecorder?.stop()
		isRecording = false
		stopRecordingTimer()

		// Send immediate notification about the interruption (this is a real mic takeover)
		if let recordingURL = recordingURL {
			Task {
				await sendInterruptionNotificationImmediately(reason: reason, recordingURL: recordingURL)
				#if os(iOS)
				await recoverInterruptedRecording(
					url: recordingURL,
					reason: reason,
					expectedRecordingSessionID: terminalRecordingSessionID
				)
				#else
				await recoverInterruptedRecording(url: recordingURL, reason: reason)
				#endif
			}
		}

		// Validation happens asynchronously before persistence, so do not report a
		// save until the recovered file has passed the finalization policy.
		errorMessage = "Recording stopped: \(reason). Checking captured audio..."

		// Deactivate audio session to restore high-quality music playback
		#if os(iOS)
		Task { @MainActor [weak self] in
			guard let self,
				  self.recordingSessionID == terminalRecordingSessionID,
				  !self.recordingIntentActive else { return }
			try? await self.enhancedAudioSessionManager.deactivateSession()
		}
		#else
		Task {
			try? await enhancedAudioSessionManager.deactivateSession()
		}
		#endif

		// Clean up recorder
		audioRecorder = nil

		// Background task will be managed by recoverInterruptedRecording
	}

	func recoverInterruptedRecording(
		url: URL,
		reason: String,
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

		guard recoveryIsCurrent() else { return }
		AppLog.shared.audioSession("Attempting to recover interrupted recording")

		// Start background task to protect file recovery and Core Data save operations
		beginBackgroundTask()
		defer { endBackgroundTask() }

		let finalization = await RecordingFinalizationPolicy.inspect(url: url, delegateSucceeded: true)
		guard recoveryIsCurrent() else { return }
		guard case .usable(let fileSize, let duration) = finalization else {
			let rejection: RecordingFinalizationRejection
			if case .rejected(let value) = finalization {
				rejection = value
			} else {
				rejection = .invalidContainer
			}
			AppLog.shared.audioSession(
				"Interrupted recording was not usable: \(rejection)",
				level: .error
			)
			rejectRecordingFinalization(at: url, rejection: rejection)
			await sendInterruptionNotification(success: false, reason: reason, filename: url.lastPathComponent)
			return
		}

		AppLog.shared.audioSession("Recording has meaningful content: \(fileSize) bytes, \(duration)s")

		// Save location data if available
		guard recoveryIsCurrent() else { return }
		saveLocationData(for: url)

		// Add the recording using workflow manager for proper UUID consistency
		if let workflowManager = workflowManager {
			guard recoveryIsCurrent() else { return }
			let quality = AudioRecorderViewModel.getCurrentAudioQuality()

			// Use original filename for recording name to maintain consistency
			let originalFilename = url.deletingPathExtension().lastPathComponent
			let displayName = "\(originalFilename) (interrupted)"

			// Core Data operations should happen on main thread
			await MainActor.run {
				guard recoveryIsCurrent() else { return }
				// Create recording entry using original URL to maintain file consistency
					let recordingId = workflowManager.createRecording(
						url: url,
						name: displayName,
						date: currentRecordingDate(for: url),
						fileSize: fileSize,
						duration: duration,
						quality: quality,
						locationData: recordingLocationSnapshot()
					)

					AppLog.shared.audioSession("Interrupted recording recovered with workflow manager, ID: \(recordingId)")

					// Post notification to refresh UI
					NotificationCenter.default.post(name: NSNotification.Name("RecordingAdded"), object: nil)

					// Reset processing flag
					recordingBeingProcessed = false
					resetRecordingLocation()
					recordingStartedAt = nil
					resetRecordingAttemptArtifacts()

				}

			// Don't send additional notification - already sent immediate notification

		} else {
			AppLog.shared.audioSession("WorkflowManager not set - interrupted recording not saved to database", level: .error)
			await sendInterruptionNotification(success: false, reason: reason, filename: url.lastPathComponent)

			// Reset processing flag even on failure
			await MainActor.run {
				recordingBeingProcessed = false
			}
		}
	}

	func checkForUnprocessedRecording() async {
		AppLog.shared.audioSession("checkForUnprocessedRecording called - recordingBeingProcessed: \(recordingBeingProcessed), isRecording: \(isRecording)", level: .debug)

		// CRITICAL: Never recover a recording that is still active
		if isRecording {
			AppLog.shared.audioSession("Recording is still active, skipping recovery check", level: .debug)
			return
		}

		// Prevent duplicate recovery attempts (both flag and time-based)
		let now = Date()
		if recordingBeingProcessed || now.timeIntervalSince(lastRecoveryAttempt) < 2.0 {
			AppLog.shared.audioSession("Recovery already in progress or attempted recently, skipping", level: .debug)
			return
		}

		lastRecoveryAttempt = now

		// Check if there's a recording file that exists but wasn't processed
		guard let recordingURL = recordingURL else {
			AppLog.shared.audioSession("No recording URL to check", level: .debug)
			return
		}

		AppLog.shared.audioSession("Checking for unprocessed recording", level: .debug)

		// Validate the complete container before considering this file for
		// recovery. Unknown/imported URLs are never deleted by this check.
		let finalization = await RecordingFinalizationPolicy.inspect(
			url: recordingURL,
			delegateSucceeded: true
		)
		guard case .usable = finalization else {
			AppLog.shared.audioSession("Found an unprocessed but unusable recording; leaving the artifact untouched", level: .debug)
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
			AppLog.shared.audioSession("Recording already exists in database: \(existingRecordingName)", level: .debug)
			AppLog.shared.audioSession("Recording already processed, clearing recording URL", level: .debug)
			await MainActor.run {
				self.recordingURL = nil // Clear so we don't keep checking
			}
			return
		}

		// Set flag to prevent duplicate processing
		recordingBeingProcessed = true

		AppLog.shared.audioSession("Found unprocessed recording from backgrounding, recovering it now")

		// Process the unprocessed recording
		await recoverUnprocessedRecording(url: recordingURL)
	}

	func recoverUnprocessedRecording(url: URL) async {
		AppLog.shared.audioSession("Recovering unprocessed recording")

		let finalization = await RecordingFinalizationPolicy.inspect(url: url, delegateSucceeded: true)
		guard case .usable(let fileSize, let duration) = finalization else {
			if case .rejected(let rejection) = finalization {
				AppLog.shared.audioSession("Unprocessed recording rejected: \(rejection)", level: .error)
				errorMessage = rejection.userMessage
			}
			recordingBeingProcessed = false
			return
		}

		AppLog.shared.audioSession("Unprocessed recording has content: \(fileSize) bytes, \(duration)s")

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
					date: currentRecordingDate(for: url),
					fileSize: fileSize,
					duration: duration,
					quality: quality,
					locationData: recordingLocationSnapshot()
				)

					AppLog.shared.audioSession("Unprocessed recording recovered with workflow manager, ID: \(recordingId)")

					// Post notification to refresh UI
					NotificationCenter.default.post(name: NSNotification.Name("RecordingAdded"), object: nil)

					// Clear the recording URL since it's now processed
					self.recordingURL = nil
					self.recordingBeingProcessed = false
					self.resetRecordingLocation()
					self.recordingStartedAt = nil
					self.resetRecordingAttemptArtifacts()
				}

			// Send notification to user about recovery (with slight delay to improve visibility)
			await sendRecoveryNotification(filename: displayName)
		} else {
			AppLog.shared.audioSession("WorkflowManager not set - cannot recover unprocessed recording", level: .error)
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
				AppLog.shared.audioSession("Error requesting notification permission: \(error)", level: .error)
				return
			}
		}

		guard hasPermission else {
			AppLog.shared.audioSession("Notification permission denied - cannot send interruption notification", level: .debug)
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
			AppLog.shared.audioSession("Sent interruption notification: \(title)")
		} catch {
			AppLog.shared.audioSession("Failed to send interruption notification: \(error)", level: .error)
		}
	}

	func sendRecoveryNotification(filename: String) async {
		let title = "Recording Recovered"
		let body = "Found and saved your recording from when the app was in background: \(filename.prefix(30))..."

		// Check app state for notification timing
		let appIsActive = await MainActor.run { PlatformApp.isActive }
		AppLog.shared.audioSession("App active when sending recovery notification: \(appIsActive)", level: .debug)

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

				AppLog.shared.audioSession("Sent recovery notification via BackgroundProcessingManager")
			}
		}
	}

	func sendInterruptionNotificationImmediately(reason: String, recordingURL: URL) async {
		AppLog.shared.audioSession("Sending immediate interruption notification for mic takeover")

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

				AppLog.shared.audioSession("Sent immediate interruption notification")
			}
		}
	}

	func scheduleRecordingInterruptedNotification(recordingURL: URL) async {
		AppLog.shared.audioSession("Scheduling notification for interrupted recording while app is backgrounded")

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

				AppLog.shared.audioSession("Sent background interruption notification")
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
