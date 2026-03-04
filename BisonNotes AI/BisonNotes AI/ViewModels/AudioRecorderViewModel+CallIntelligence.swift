//
//  AudioRecorderViewModel+CallIntelligence.swift
//  BisonNotes AI
//
//  Phase 1: CallKit integration for intelligent call-based interruption handling.
//

import Foundation
import UserNotifications

#if !targetEnvironment(macCatalyst)
import CallKit

// MARK: - CallKit Observer Delegate (Phase 1)

extension AudioRecorderViewModel: CXCallObserverDelegate {
	nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
		Task { @MainActor in
			await handleCallStateChange(call)
		}
	}

	@MainActor
	private func handleCallStateChange(_ call: CXCall) async {
		if call.hasEnded {
			// Call has ended
			await handleCallEnded(call: call)
		} else if call.hasConnected || call.isOutgoing {
			// Call started (either incoming call was answered or outgoing call connected)
			handleCallStarted()
		}
	}

	@MainActor
	private func handleCallStarted() {
		callInterruptionStartTime = Date()
		print("📞 Call started, tracking duration for auto-resume decision")
	}

	@MainActor
	private func handleCallEnded(call: CXCall) async {
		// Only process if we're currently in an interrupted state due to phone call
		guard case .interrupted(.phoneCall, let startedAt) = recordingState else {
			print("📞 Call ended but not in phoneCall interrupted state, ignoring")
			return
		}

		// Calculate call duration
		let callDuration = Date().timeIntervalSince(callInterruptionStartTime ?? startedAt)
		print("📞 Call ended after \(callDuration) seconds")

		// Don't attempt to resume while the app is backgrounded — the audio session is
		// owned by the Phone app and any resume attempt will produce a bad segment.
		// The interruption .ended handler or foreground handler will do the actual resume.
		if appIsBackgrounding {
			print("📞 App is backgrounded — deferring resume to interruption/foreground handler (duration: \(callDuration)s)")
			deferredCallDuration = callDuration
			callInterruptionStartTime = nil
			return
		}

		if callDuration < SHORT_CALL_THRESHOLD {
			// Short call (< 3 minutes) - auto resume
			print("✅ Short call detected (<3 min), auto-resuming recording")
			recordingState = .recording
			if let url = interruptionRecordingURL {
				await resumeRecordingAfterInterruption(url: url)
			}
		} else {
			// Long call (≥ 3 minutes) - ask user
			print("⏱️ Long call detected (≥3 min), asking user whether to resume")
			recordingState = .waitingForUserDecision(callDuration: callDuration)
			await promptUserForResumeDecision(callDuration: callDuration)
		}

		callInterruptionStartTime = nil
	}

	@MainActor
	func promptUserForResumeDecision(callDuration: TimeInterval) async {
		// Create notification content
		let content = UNMutableNotificationContent()
		content.title = "Resume Recording?"
		content.body = "Your \(formatDuration(callDuration)) call has ended. Would you like to resume your recording?"
		content.categoryIdentifier = "RESUME_RECORDING"
		content.userInfo = ["recordingURL": interruptionRecordingURL?.absoluteString ?? ""]
		content.sound = .default

		// Register notification category with actions
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

		// Send notification
		let request = UNNotificationRequest(
			identifier: "resume_\(UUID().uuidString)",
			content: content,
			trigger: nil
		)

		do {
			try await UNUserNotificationCenter.current().add(request)
			print("✅ Sent user notification for resume decision")

			// Set timeout: if user doesn't respond in 30 seconds, stop recording
			try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds

			if case .waitingForUserDecision = recordingState {
				// User didn't respond, stop recording gracefully
				print("⏱️ User didn't respond to resume prompt, stopping recording")
				handleInterruptedRecording(reason: "Call exceeded 3 minutes, user did not resume")
			}
		} catch {
			print("❌ Failed to send resume notification: \(error)")
			// Fallback: auto-resume after short delay
			try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
			if case .waitingForUserDecision = recordingState {
				// Auto-resume as fallback
				recordingState = .recording
				if let url = interruptionRecordingURL {
					await resumeRecordingAfterInterruption(url: url)
				}
			}
		}
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
