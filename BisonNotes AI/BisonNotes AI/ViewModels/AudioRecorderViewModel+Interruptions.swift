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
		// An interruption is terminal for a live transcription session: it has no
		// AVAudioRecorder for recovery to continue and nothing restarts its
		// AVAudioEngine, so entering .interrupted would wedge the recording with
		// its audio unsaved. Finalize the capture instead.
		if isUsingLiveTranscription {
			AppLog.shared.audioSession(
				"Audio interruption began during live transcription; finalizing the capture"
			)
			finalizeLiveTranscriptionRecording(reason: "An interruption took the microphone")
			return
		}
		// A user-paused recording has already yielded the microphone on purpose.
		// Overwriting .paused with .interrupted would make recovery seal the
		// segment and start a new one, silently resuming capture the user asked
		// to stop. Leave the pause intact; resumeRecording() is the only way out.
		guard !isPaused else {
			AppLog.shared.audioSession(
				"Ignoring interruption begin for a user-paused recording",
				level: .debug
			)
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
		// Stopping the recording timer removes the only failsafe that notices a
		// dead recorder, and iOS never delivers .ended to an app it suspended
		// during the interruption. Arm a bounded watchdog so a missing .ended
		// cannot wedge the recording in .interrupted forever.
		startInterruptionWatchdog(for: interruptionDate)
		recordInterruptionTransition()
		if let recordingSessionID {
			recoveryCoordinator.markInterrupted(for: recordingSessionID)
		}
		AppLog.shared.audioSession(
			"Audio interruption began; waiting for one coordinated recovery request"
		)
	}

	/// How long a `.began` may sit without a matching `.ended` before the app
	/// reconciles the recording itself.
	static let interruptionStallTimeout: TimeInterval = 180

	@MainActor
	func startInterruptionWatchdog(for startedAt: Date) {
		stopInterruptionWatchdog()
		interruptionWatchdogTimer = Timer.scheduledTimer(
			withTimeInterval: Self.interruptionStallTimeout,
			repeats: false
		) { [weak self] timer in
			timer.invalidate()
			Task { @MainActor [weak self] in
				await self?.reconcileStalledInterruption(startedAt: startedAt)
			}
		}
	}

	@MainActor
	func stopInterruptionWatchdog() {
		interruptionWatchdogTimer?.invalidate()
		interruptionWatchdogTimer = nil
	}

	/// Drive one recovery for an interruption whose `.ended` never arrived.
	///
	/// Re-validates every piece of state it acts on, so a watchdog left over
	/// from a resolved interruption is a no-op rather than a second owner.
	@MainActor
	func reconcileStalledInterruption(startedAt: Date) async {
		guard isInInterruption,
			  !interruptionEndHandled,
			  recordingIntentActive,
			  case .interrupted(_, let currentStartedAt) = recordingState,
			  currentStartedAt == startedAt,
			  let url = interruptionRecordingURL ?? recordingURL else {
			return
		}

		// A call that outlasts the timeout has not ended: CallKit still reports
		// it active, so the Phone app still owns the microphone and the long-call
		// resume prompt has not been offered yet. Reconciling here would clear the
		// tracker and burn the activation budget against an ongoing call, then
		// terminate the recording before it. Stay interrupted and re-arm instead.
		guard !callInterruptionTracker.hasActiveCalls else {
			AppLog.shared.audioSession(
				"Interruption watchdog fired while a CallKit call is still active; staying interrupted",
				level: .debug
			)
			startInterruptionWatchdog(for: startedAt)
			return
		}

		AppLog.shared.audioSession(
			"Interruption produced no ended event after \(Int(Self.interruptionStallTimeout))s; reconciling the recording",
			level: .error
		)
		isInInterruption = false
		interruptionEndHandled = true
		deferredCallDuration = nil
		callInterruptionTracker.removeAll()
		await requestAudioRecovery(trigger: .foregroundReconciliation, recordingURL: url)
	}

	/// The recovery an `.ended` interruption authorizes.
	///
	/// Without `.shouldResume` iOS has not authorized this app to take the
	/// microphone back, so the recovery preserves the finalized segment and
	/// waits for an event that does, instead of reacquiring the input.
	static func recoveryTrigger(
		forInterruptionEndedWithResumeOption shouldResume: Bool
	) -> AudioRecoveryTrigger {
		shouldResume ? .interruptionEnded : .interruptionEndedWithoutResume
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
			stopInterruptionWatchdog()
			interruptionEndHandled = true
			isInInterruption = false
			deferredCallDuration = nil
			recordingState = .waitingForUserDecision(callDuration: callDuration)
			Task { @MainActor in
				await promptUserForResumeDecision(callDuration: callDuration)
			}
			return
		}
		stopInterruptionWatchdog()
		deferredCallDuration = nil
		isInInterruption = false
		interruptionEndHandled = true
		let trigger = Self.recoveryTrigger(forInterruptionEndedWithResumeOption: shouldResume)
		AppLog.shared.audioSession(
			"Audio interruption ended (shouldResume: \(shouldResume)); requesting \(trigger.rawValue) recovery"
		)
		Task { @MainActor [weak self] in
			await self?.requestAudioRecovery(
				trigger: trigger,
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
			// iOS can fall back from a disconnected Bluetooth/headset input to the
			// built-in microphone without stopping AVAudioRecorder. Reconcile the
			// selected input first and only recover when the recorder actually stopped.
			if isRecording, wasUsingMicrophone {
				AppLog.shared.audioSession("A recording input became unavailable; checking the active route")
				Task { @MainActor in
					await handleMicrophoneUnavailableDuringRecording()
				}
			} else {
				// Not recording, just update the selected input
				Task { @MainActor in
					await applySelectedInputToSession()
				}
			}

		case .newDeviceAvailable:
			// Refresh the selected input. A continuation, if one is needed, is owned
			// by the coordinated recovery path rather than a second polling loop.
			AppLog.shared.audioSession("New audio device available")
			Task { @MainActor in
				await applySelectedInputToSession()
			}

		case .categoryChange:
			// Setting the app's own playAndRecord category emits this reason. The
			// notification can be delivered after setup marks the recorder active,
			// but it is not evidence that any input disappeared.
			let activeInput = enhancedAudioSessionManager.getActiveInput()
			let inputDescription = activeInput.map {
				"\($0.portName) (\($0.portType.rawValue))"
			} ?? "none"
			AppLog.shared.audioSession(
				"Audio session category changed; keeping the current recording route (input: \(inputDescription))",
				level: .debug
			)
		default:
			break
		}
	}
	#else
	func handleRouteChange(_ notification: Notification) {}
	#endif

	#if os(iOS)
	@MainActor
	func handleMicrophoneUnavailableDuringRecording() async {
		guard isRecording, case .recording = recordingState, let currentURL = recordingURL else {
			return
		}

		await applySelectedInputToSession()
		let activeInput = enhancedAudioSessionManager.getActiveInput()
		let availableInputs = enhancedAudioSessionManager.getAvailableInputs()
		let availableDescription = availableInputs
			.map { "\($0.portName) (\($0.portType.rawValue))" }
			.joined(separator: ", ")

		if let recorder = audioRecorder, recorder.isRecording {
			let activeDescription = activeInput.map {
				"\($0.portName) (\($0.portType.rawValue))"
			} ?? "system default"
			AppLog.shared.audioSession(
				"Recorder remained active after the route change; continuing on \(activeDescription)"
			)
			return
		}

		let activeName = activeInput?.portName ?? "none"
		let availableNames = availableDescription.isEmpty ? "none" : availableDescription
		AppLog.shared.audioSession(
			"Recorder stopped after input loss; requesting coordinated recovery "
				+ "(active: \(activeName), available: \(availableNames))",
			level: .error
		)
		await requestAudioRecovery(trigger: .routeChange, recordingURL: currentURL)
	}
	#endif

	// MARK: - Interrupted Recording Recovery

	@MainActor
	func handleInterruptedRecording(reason: String) {
		AppLog.shared.audioSession("Handling interrupted recording: \(reason)")

		// Prevent duplicate processing. This runs before any state is torn down:
		// clearing the recording intent first would leave a still-running
		// recorder with recovery permanently disabled on the bail-out path.
		guard !recordingBeingProcessed else {
			AppLog.shared.audioSession("Recording already being processed, skipping duplicate interruption handling", level: .debug)
			return
		}

		#if os(iOS)
		let terminalRecordingSessionID = recordingSessionID
		let terminalMainRecordingURL = mainRecordingURL
		recordingIntentActive = false
		recoveryCoordinator.invalidateRecordingSession(reason: "terminal interruption: \(reason)")
		callInterruptionTracker.removeAll()
		stopInterruptionWatchdog()
		#endif
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
			// A recording that already survived one interruption has earlier
			// continuation segments. Persisting only the current URL would leave
			// everything captured before that interruption orphaned on disk, so
			// take the same merge path the coordinated terminal handler uses.
			let segmentsToPersist = recordingSegments.filter {
				FileManager.default.fileExists(atPath: $0.path)
			}
			Task {
				await sendInterruptionNotificationImmediately(reason: reason, recordingURL: recordingURL)
				#if os(iOS)
				if segmentsToPersist.count > 1 {
					await mergeRecordingSegments(
						segments: segmentsToPersist,
						mainURL: terminalMainRecordingURL,
						expectedRecordingSessionID: terminalRecordingSessionID
					)
					await MainActor.run { self.recordingBeingProcessed = false }
				} else {
					await recoverInterruptedRecording(
						url: recordingURL,
						reason: reason,
						expectedRecordingSessionID: terminalRecordingSessionID
					)
				}
				#else
				if segmentsToPersist.count > 1 {
					await mergeRecordingSegments()
					await MainActor.run { self.recordingBeingProcessed = false }
				} else {
					await recoverInterruptedRecording(url: recordingURL, reason: reason)
				}
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

	/// Persist one finalized recording segment.
	///
	/// Every caller reaches this after its recording is over — a terminal
	/// interruption, a user stop during recovery, a deferral superseded by a new
	/// capture — so the save is unconditional: a recording that finished is not
	/// less finished because the user started another one while its container
	/// was being inspected. `setupRecording()` replaces `recordingSessionID`, so
	/// gating the save on session identity is what orphaned finalized audio on
	/// disk. Only writes to live recording state are gated here.
	func recoverInterruptedRecording(
		url: URL,
		reason: String,
		ownsLiveRecordingState: Bool = true,
		expectedRecordingSessionID: UUID? = nil,
		expectedRecoveryRequestID: UUID? = nil
	) async {
		let ownsLiveState: @MainActor () -> Bool = {
			guard ownsLiveRecordingState, !Task.isCancelled else { return false }
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
		// The caller set `recordingBeingProcessed` before spawning this work and
		// nothing else clears it, so every exit releases it — but only while this
		// session still owns the flag; a newer recording owns its own.
		let releaseProcessingFlag: @MainActor () -> Void = {
			if ownsLiveState() {
				self.recordingBeingProcessed = false
			}
		}

		AppLog.shared.audioSession("Attempting to recover interrupted recording")

		// Reads live location state, so it is only this recording's while this
		// session is still the current one; the row below uses the snapshot.
		let capturedLocation = ownsLiveState() ? recordingLocationSnapshot() : nil

		// Start background task to protect file recovery and Core Data save operations
		beginBackgroundTask()
		defer {
			if ownsLiveState() { endBackgroundTask() }
		}

		let finalization = await RecordingFinalizationPolicy.inspect(url: url, delegateSucceeded: true)
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
			if ownsLiveState() {
				rejectRecordingFinalization(at: url, rejection: rejection)
			}
			// Rejecting the current segment must not discard the earlier ones it
			// continued from; those already passed the finalization policy. They
			// are only reachable through live state, so a superseded pass has
			// nothing left to fall back to.
			let survivingSegments = ownsLiveState() ? recordingSegments : []
			if survivingSegments.count > 1 {
				await mergeRecordingSegments(
					expectedRecordingSessionID: expectedRecordingSessionID,
					expectedRecoveryRequestID: expectedRecoveryRequestID
				)
				releaseProcessingFlag()
			} else if let survivor = survivingSegments.first {
				await recoverInterruptedRecording(
					url: survivor,
					reason: reason,
					ownsLiveRecordingState: ownsLiveRecordingState,
					expectedRecordingSessionID: expectedRecordingSessionID,
					expectedRecoveryRequestID: expectedRecoveryRequestID
				)
			} else {
				await sendInterruptionNotification(success: false, reason: reason, filename: url.lastPathComponent)
				releaseProcessingFlag()
			}
			return
		}

		AppLog.shared.audioSession("Recording has meaningful content: \(fileSize) bytes, \(duration)s")

		if ownsLiveState() {
			saveLocationData(for: url)
		}

		guard let workflowManager = workflowManager else {
			AppLog.shared.audioSession("WorkflowManager not set - interrupted recording not saved to database", level: .error)
			await sendInterruptionNotification(success: false, reason: reason, filename: url.lastPathComponent)
			releaseProcessingFlag()
			return
		}

		let quality = AudioRecorderViewModel.getCurrentAudioQuality()

		// Use original filename for recording name to maintain consistency
		let originalFilename = url.deletingPathExtension().lastPathComponent
		let displayName = "\(originalFilename) (interrupted)"

		// An unconditional save has to be an idempotent one: a superseded pass and
		// the unprocessed-recording check can both reach the same finalized file.
		// Either way the row exists once this block is done, which is the only
		// point at which a trail parking this file can safely be retired.
		defer {
			#if os(iOS)
			clearDeferredRecoverySnapshotEntries(containing: url)
			#endif
		}
		if let appCoordinator, appCoordinator.getRecording(url: url) != nil {
			AppLog.shared.audioSession(
				"Interrupted recording is already in the database; not creating a second row",
				level: .debug
			)
		} else {
			let recordingId = workflowManager.createRecording(
				url: url,
				name: displayName,
				date: currentRecordingDate(for: url),
				fileSize: fileSize,
				duration: duration,
				quality: quality,
				locationData: capturedLocation
			)

			AppLog.shared.audioSession("Interrupted recording recovered with workflow manager, ID: \(recordingId)")

			// Post notification to refresh UI
			NotificationCenter.default.post(name: NSNotification.Name("RecordingAdded"), object: nil)
		}

		// Don't send additional notification - already sent immediate notification

		guard ownsLiveState() else {
			AppLog.shared.audioSession(
				"A newer recording superseded this recovery; saved its audio without touching live state",
				level: .debug
			)
			return
		}
		recordingBeingProcessed = false
		resetRecordingLocation()
		recordingStartedAt = nil
		resetRecordingAttemptArtifacts()
	}

	func checkForUnprocessedRecording() async {
		AppLog.shared.audioSession("checkForUnprocessedRecording called - recordingBeingProcessed: \(recordingBeingProcessed), isRecording: \(isRecording)", level: .debug)

		// CRITICAL: Never recover a recording that is still active
		if isRecording {
			AppLog.shared.audioSession("Recording is still active, skipping recovery check", level: .debug)
			return
		}

		#if os(iOS)
		// A reclaim below may hand this pass the reservation for the parked entry
		// it restored. It is held for the whole of this function — the container
		// inspection and the database lookup included, which is where a recording
		// started in the meantime used to be able to claim the same segments —
		// and released however this exits.
		defer { releaseHandedOverReclaim() }

		// isRecording alone is no longer enough: a coordinated recovery clears it
		// for the whole finalize/activate/continue sequence. Persisting the
		// segment it is mid-flight on would nil out recordingURL underneath it
		// and wedge the session. Recovery owns any still-intended recording.
		if recordingIntentActive {
			AppLog.shared.audioSession(
				"A recording session is still active; leaving its segments to the recovery coordinator",
				level: .debug
			)
			return
		}

		guard await prepareCompleteRecordingForUnprocessedRecovery() else { return }
		#endif

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
				#if os(iOS)
				self.clearDeferredRecoverySnapshotEntries(containing: recordingURL)
				#endif
				self.recordingURL = nil // Clear so we don't keep checking
			}
			return
		}

		// Set flag to prevent duplicate processing
		recordingBeingProcessed = true

		AppLog.shared.audioSession("Found an unprocessed recording, recovering it now")

		// Process the unprocessed recording
		await recoverUnprocessedRecording(url: recordingURL)
	}

	#if os(iOS)
	@MainActor
	private func prepareCompleteRecordingForUnprocessedRecovery() async -> Bool {
		// Retry an in-memory merge that failed at stop before considering any one
		// continuation on its own. Saving only recordingURL here would lose every
		// earlier usable segment.
		if recordingSegments.count > 1, mainRecordingURL != nil {
			AppLog.shared.audioSession("Retrying a preserved multi-segment recording before single-file recovery")
			await mergeRecordingSegments()
			guard recordingSegments.count <= 1 else {
				AppLog.shared.audioSession(
					"The complete segment merge is still pending; skipping partial recovery",
					level: .error
				)
				return false
			}
		}

		// Reclaim a recording that was deferred and then terminated before it
		// could resume; the merge path persists multi-segment reclaims itself.
		let reclaimedDeferredRecording = await reclaimDeferredRecoverySegmentsIfNeeded()
		guard recordingSegments.count <= 1 else {
			AppLog.shared.audioSession(
				"A reclaimed multi-segment recording is still pending; skipping partial recovery",
				level: .error
			)
			return false
		}
		if !reclaimedDeferredRecording, recordingURL == nil {
			AppLog.shared.audioSession("No recording URL to check", level: .debug)
			return false
		}
		return true
	}
	#endif

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
			let displayName = "\(originalFilename) (recovered)"

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

					// Clear the recording URL since it's now processed, along with
					// any deferred-recovery trail this file was parked under.
					#if os(iOS)
					self.clearDeferredRecoverySnapshotEntries(containing: url)
					#endif
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
