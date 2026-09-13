//
//  AudioRecorderViewModel+RecoveryNotifications.swift
//  BisonNotes AI
//
//  Notifications for recording recovery and interruptions.
//

import Foundation
@preconcurrency import AVFoundation
#if canImport(UIKit)
import UIKit
#endif
import UserNotifications

extension AudioRecorderViewModel {
	func sendRecoveryNotification(filename: String) async {
		guard appCoordinator?.storageState.isOperational == true else {
			AppLog.shared.audioSession(
				"Recovery notification withheld because local storage is unavailable",
				level: .fault
			)
			return
		}
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
		guard appCoordinator?.storageState.isOperational == true else {
			AppLog.shared.audioSession(
				"Interruption notification withheld because local storage is unavailable",
				level: .fault
			)
			return
		}
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
		guard appCoordinator?.storageState.isOperational == true else {
			AppLog.shared.audioSession(
				"Background interruption notification withheld because local storage is unavailable",
				level: .fault
			)
			return
		}
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
