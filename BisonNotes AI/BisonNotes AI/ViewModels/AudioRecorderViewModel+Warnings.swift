//
//  AudioRecorderViewModel+Warnings.swift
//  BisonNotes AI
//
//  Phase 3: Recording limits monitoring and warning notifications.
//

import Foundation
import UIKit
import UserNotifications

// MARK: - Phase 3: Comprehensive Warning System

extension AudioRecorderViewModel {

	/// Send a warning notification to the user
	@MainActor
	func sendWarningNotification(title: String, body: String, isCritical: Bool) async {
		let content = UNMutableNotificationContent()
		content.title = title
		content.body = body
		content.sound = isCritical ? .defaultCritical : .default

		// iOS 15+ feature: set interruption level
		if #available(iOS 15.0, *) {
			content.interruptionLevel = isCritical ? .critical : .active
		}

		let request = UNNotificationRequest(
			identifier: "recording_warning_\(UUID().uuidString)",
			content: content,
			trigger: nil // Immediate delivery
		)

		do {
			try await UNUserNotificationCenter.current().add(request)
			print("✅ Sent warning notification: \(title)")
		} catch {
			print("❌ Failed to send warning notification: \(error)")
		}
	}

	/// Check recording limits and send warnings as needed
	@MainActor
	func checkRecordingLimitsAndWarnings() async {
		// 1. DURATION CHECK
		if recordingTime >= MAX_RECORDING_DURATION {
			print("⏱️ Maximum recording duration (3 hours) reached")
			await sendWarningNotification(
				title: "Recording Limit Reached",
				body: "Maximum recording duration (3 hours) reached. Stopping recording.",
				isCritical: true
			)
			stopRecording()
			return
		}

		// 2. DURATION WARNING (15 minutes before limit)
		if recordingTime >= DURATION_WARNING_THRESHOLD && !hasShownDurationWarning {
			hasShownDurationWarning = true
			let remainingMinutes = Int((MAX_RECORDING_DURATION - recordingTime) / 60)
			await sendWarningNotification(
				title: "Recording Time Warning",
				body: "Your recording will stop in \(remainingMinutes) minutes when the 4-hour limit is reached.",
				isCritical: false
			)
		}

		// 3. STORAGE CHECK
		if let freeStorage = getAvailableStorage() {
			let freeStorageMB = freeStorage / (1024 * 1024)

			if freeStorageMB < MIN_STORAGE_REQUIRED_MB {
				print("💾 Critical storage: Only \(freeStorageMB) MB remaining")
				await sendWarningNotification(
					title: "Storage Full",
					body: "Less than 100 MB remaining. Stopping recording to prevent data loss.",
					isCritical: true
				)
				stopRecording()
				return
			}

			if freeStorageMB < STORAGE_WARNING_THRESHOLD_MB && !hasShownStorageWarning {
				hasShownStorageWarning = true
				await sendWarningNotification(
					title: "Low Storage Warning",
					body: "Only \(freeStorageMB) MB remaining. Consider stopping recording soon.",
					isCritical: false
				)
			}
		}

		// 4. BATTERY CHECK
		UIDevice.current.isBatteryMonitoringEnabled = true
		let batteryLevel = UIDevice.current.batteryLevel

		if batteryLevel >= 0 && batteryLevel < MIN_BATTERY_LEVEL {
			print("🔋 Critical battery: \(Int(batteryLevel * 100))%")
			await sendWarningNotification(
				title: "Critical Battery",
				body: "Battery at \(Int(batteryLevel * 100))%. Stopping recording to preserve battery.",
				isCritical: true
			)
			stopRecording()
			return
		}

		if batteryLevel >= 0 && batteryLevel < BATTERY_WARNING_THRESHOLD && !hasShownBatteryWarning {
			hasShownBatteryWarning = true
			await sendWarningNotification(
				title: "Low Battery Warning",
				body: "Battery at \(Int(batteryLevel * 100))%. Consider stopping recording soon.",
				isCritical: false
			)
		}
	}

	/// Get available storage on device
	func getAvailableStorage() -> Int64? {
		do {
			let fileURL = URL(fileURLWithPath: NSHomeDirectory())
			let values = try fileURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
			return values.volumeAvailableCapacityForImportantUsage
		} catch {
			print("❌ Failed to get available storage: \(error)")
			return nil
		}
	}
}
