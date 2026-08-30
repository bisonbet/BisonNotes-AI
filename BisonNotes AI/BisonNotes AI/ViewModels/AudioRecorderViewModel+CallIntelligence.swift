//
//  AudioRecorderViewModel+CallIntelligence.swift
//  BisonNotes AI
//
//  Phase 1: CallKit integration for intelligent call-based interruption handling.
//

import Foundation
import UserNotifications

#if os(iOS)
#if canImport(CallKit) && os(iOS)
import CallKit
#endif

// MARK: - CallKit Observer Delegate (Phase 1)

extension AudioRecorderViewModel: CXCallObserverDelegate {
	private struct CallStateEvent: Sendable {
		let id: UUID
		let observedAt: Date
		let hasEnded: Bool
		let hasConnected: Bool
		let isOutgoing: Bool
	}

	nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
		let event = CallStateEvent(
			id: call.uuid,
			observedAt: Date(),
			hasEnded: call.hasEnded,
			hasConnected: call.hasConnected,
			isOutgoing: call.isOutgoing
		)
		Task { @MainActor [weak self] in
			await self?.handleCallStateChange(event)
		}
	}

	@MainActor
	private func handleCallStateChange(_ event: CallStateEvent) async {
		if event.hasEnded {
			// Remove the matching start before deciding whether this call affected
			// recording. An unrelated ended call must not leave stale timing state.
			let startedAt = callInterruptionTracker.observeEnd(id: event.id)
			await handleCallEnded(callStartedAt: startedAt, endedAt: event.observedAt)
		} else if event.hasConnected || event.isOutgoing {
			// Call started (either incoming call was answered or outgoing call connected)
			handleCallStarted(id: event.id, at: event.observedAt)
		}
	}

	@MainActor
	private func handleCallStarted(id: UUID, at date: Date) {
		callInterruptionTracker.observeStart(id: id, at: date)
		AppLog.shared.audioSession("Call started, tracking duration for auto-resume decision")
	}

	@MainActor
	private func handleCallEnded(callStartedAt: Date?, endedAt: Date) async {
		// Only process if we're currently in an interrupted state due to phone call
		guard !interruptionEndHandled,
			  case .interrupted(.phoneCall, let interruptionStartedAt) = recordingState else {
			AppLog.shared.audioSession("Call ended but not in phoneCall interrupted state, ignoring", level: .debug)
			return
		}

		// Calculate call duration
		let callDuration = CallInterruptionDuration.seconds(
			callStartedAt: callStartedAt,
			interruptionStartedAt: interruptionStartedAt,
			endedAt: endedAt
		)
		AppLog.shared.audioSession("Call ended after \(Int(callDuration))s")

		// Do not reacquire the microphone while another correlated CallKit call
		// still owns call audio. The remaining end event will provide its own
		// UUID-specific start time, or the AV interruption timestamp will be used.
		if callInterruptionTracker.hasActiveCalls {
			deferredCallDuration = callDuration
			AppLog.shared.audioSession(
				"Another CallKit call remains active; deferring interruption recovery",
				level: .debug
			)
			return
		}

		// Don't attempt to resume while the app is backgrounded — the audio session is
		// owned by the Phone app and any resume attempt will produce a bad segment.
		// The interruption .ended handler or foreground handler will do the actual resume.
		if appIsBackgrounding {
			AppLog.shared.audioSession(
				"App is backgrounded - deferring resume to interruption/foreground handler "
				+ "(duration: \(Int(callDuration))s)"
			)
			deferredCallDuration = callDuration
			return
		}
		deferredCallDuration = nil

		if callDuration < SHORT_CALL_THRESHOLD {
			// Short call (< 3 minutes) - auto resume
			AppLog.shared.audioSession("Short call detected (<3 min), auto-resuming recording")
			// The AVAudioSession .ended that arrived while this call was still
			// active returned without clearing this, and CallKit's end is the
			// correlated signal it was waiting for. Recovery refuses to run while
			// an interruption is live, so clear it before requesting — otherwise
			// the request cancels immediately and nothing retries until the
			// stall watchdog fires. interruptionRecordingURL still satisfies the
			// .ended handler's guard if this resume does not take effect.
			isInInterruption = false
			if let url = interruptionRecordingURL ?? recordingURL {
				await resumeRecordingAfterInterruption(url: url)
			}
			// Latch only once the resume actually left the interrupted state.
			// CallKit reports the call ended before AVAudioSession releases the
			// microphone, so a resume attempted here can be ignored or fail;
			// latching first would discard the system's own .ended/.shouldResume,
			// the event that actually authorizes reacquiring the microphone.
			if case .interrupted = recordingState {
				AppLog.shared.audioSession(
					"CallKit resume did not take effect; leaving the interruption-ended event usable",
					level: .debug
				)
			} else {
				interruptionEndHandled = true
				stopInterruptionWatchdog()
			}
		} else {
			// Long call (≥ 3 minutes) - ask user
			AppLog.shared.audioSession("Long call detected (>=3 min), asking user whether to resume")
			interruptionEndHandled = true
			stopInterruptionWatchdog()
			isInInterruption = false
			recordingState = .waitingForUserDecision(callDuration: callDuration)
			await promptUserForResumeDecision(callDuration: callDuration)
		}
	}

	@MainActor
	func promptUserForResumeDecision(callDuration: TimeInterval) async {
		guard let expectedSessionID = recordingSessionID,
			  let expectedRecordingURL = interruptionRecordingURL?.standardizedFileURL else {
			AppLog.shared.audioSession("Skipping resume prompt without a current recording session", level: .debug)
			return
		}

		func stillWaitingForExpectedRecording() -> Bool {
			guard recordingSessionID == expectedSessionID,
				  recordingURL?.standardizedFileURL == expectedRecordingURL else {
				return false
			}
			if case .waitingForUserDecision = recordingState {
				return true
			}
			return false
		}

		let request = makeResumeDecisionNotification(
			callDuration: callDuration,
			recordingURL: expectedRecordingURL
		)

		do {
			try await UNUserNotificationCenter.current().add(request)
			AppLog.shared.audioSession("Sent user notification for resume decision")

			// Set timeout: if user doesn't respond in 30 seconds, stop recording
			try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds

			if stillWaitingForExpectedRecording() {
				// User didn't respond, stop recording gracefully
				AppLog.shared.audioSession("User didn't respond to resume prompt, stopping recording")
				handleInterruptedRecording(reason: "Call exceeded 3 minutes, user did not resume")
			}
		} catch {
			AppLog.shared.audioSession("Failed to send resume notification: \(error)", level: .error)
			// Fallback: auto-resume after short delay
			try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
			if stillWaitingForExpectedRecording() {
				// Auto-resume as fallback
				await resumeRecordingAfterInterruption(url: expectedRecordingURL)
			}
		}
	}

	@MainActor
	private func makeResumeDecisionNotification(
		callDuration: TimeInterval,
		recordingURL: URL
	) -> UNNotificationRequest {
		let content = UNMutableNotificationContent()
		content.title = "Resume Recording?"
		content.body = "Your \(formatDuration(callDuration)) call has ended. Would you like to resume your recording?"
		content.categoryIdentifier = "RESUME_RECORDING"
		content.userInfo = ["recordingURL": recordingURL.absoluteString]
		content.sound = .default

		let resumeAction = UNNotificationAction(
			identifier: "RESUME_ACTION",
			title: "Resume",
			options: [.foreground]
		)
		let discardAction = UNNotificationAction(
			identifier: "DISCARD_ACTION",
			title: "Stop Recording",
			options: [.destructive]
		)
		let category = UNNotificationCategory(
			identifier: "RESUME_RECORDING",
			actions: [resumeAction, discardAction],
			intentIdentifiers: [],
			options: []
		)

		UNUserNotificationCenter.current().setNotificationCategories([category])
		return UNNotificationRequest(
			identifier: "resume_\(UUID().uuidString)",
			content: content,
			trigger: nil
		)
	}

	/// Format call duration for display (e.g., "5 min 23 sec")
	private func formatDuration(_ duration: TimeInterval) -> String {
		let minutes = Int(duration) / 60
		let seconds = Int(duration) % 60

		if minutes > 0 {
			return "\(minutes) min \(seconds) sec"
		} else {
			return "\(seconds) sec"
		}
	}
}
#endif
