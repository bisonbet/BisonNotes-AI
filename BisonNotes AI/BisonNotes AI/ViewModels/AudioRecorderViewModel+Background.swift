//
//  AudioRecorderViewModel+Background.swift
//  BisonNotes AI
//
//  Phase 4: Background task management and time monitoring.
//

import Foundation
import UIKit

// MARK: - Phase 4: Background Task Management

extension AudioRecorderViewModel {

	func beginBackgroundTask() {
		guard backgroundTask == .invalid else { return }
		AppLog.shared.backgroundProcessing("Starting background task for recording")
		backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Recording") { [weak self] in
			AppLog.shared.backgroundProcessing("Recording background task expiring", level: .error)
			self?.endBackgroundTask()
		}
	}

	func endBackgroundTask() {
		guard backgroundTask != .invalid else { return }
		AppLog.shared.backgroundProcessing("Ending recording background task")
		UIApplication.shared.endBackgroundTask(backgroundTask)
		backgroundTask = .invalid
	}

	// MARK: - Background Time Monitoring

	func startBackgroundTimeMonitoring() {
		backgroundTimeMonitor?.invalidate()

		// Check remaining background time every 30 seconds
		backgroundTimeMonitor = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
			let remaining = UIApplication.shared.backgroundTimeRemaining

			// Only log/warn if actually limited (not infinite)
			if remaining < Double.greatestFiniteMagnitude {
				AppLog.shared.backgroundProcessing("Background time remaining: \(Int(remaining))s", level: .debug)

				// Warn user when less than 1 minute remains
				if remaining < 60 {
					Task { @MainActor in
						await self?.sendWarningNotification(
							title: "Limited Background Time",
							body: "iOS may stop background recording soon. Bring app to foreground to continue.",
							isCritical: true
						)
					}
				}
			}
		}
	}

	func stopBackgroundTimeMonitoring() {
		backgroundTimeMonitor?.invalidate()
		backgroundTimeMonitor = nil
	}
}
