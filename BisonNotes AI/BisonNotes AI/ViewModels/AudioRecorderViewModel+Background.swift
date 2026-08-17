//
//  AudioRecorderViewModel+Background.swift
//  BisonNotes AI
//
//  Phase 4: Background task management and time monitoring.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Phase 4: Background Task Management

extension AudioRecorderViewModel {

	func beginBackgroundTask() {
		guard backgroundTask == .invalid else { return }
		AppLog.shared.backgroundProcessing("Starting background task for recording")
		backgroundTask = PlatformBackgroundTask.begin(name: "Recording") { [weak self] in
			AppLog.shared.backgroundProcessing("Recording background task expiring", level: .error)
			Task { @MainActor [weak self] in
				self?.endBackgroundTask()
			}
		}
	}

	func endBackgroundTask() {
		guard backgroundTask != .invalid else { return }
		AppLog.shared.backgroundProcessing("Ending recording background task")
		PlatformBackgroundTask.end(backgroundTask)
		backgroundTask = .invalid
	}

	// MARK: - Background Time Monitoring

	func startBackgroundTimeMonitoring() {
		#if os(macOS)
		// No iOS-style background time limit on Mac — skip polling.
		return
		#else
		backgroundTimeMonitor?.invalidate()

		// Check remaining background time every 30 seconds
		backgroundTimeMonitor = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
			Task { @MainActor [weak self] in
				let remaining = PlatformBackgroundTask.remainingTime

				// Only log/warn if actually limited (not infinite)
				if remaining < Double.greatestFiniteMagnitude {
					AppLog.shared.backgroundProcessing("Background time remaining: \(Int(remaining))s", level: .debug)

					// Warn user when less than 1 minute remains
					if remaining < 60 {
						await self?.sendWarningNotification(
							title: "Limited Background Time",
							body: "iOS may stop background recording soon. Bring app to foreground to continue.",
							isCritical: true
						)
				}
			}
			}
		}
		#endif
	}

	func stopBackgroundTimeMonitoring() {
		backgroundTimeMonitor?.invalidate()
		backgroundTimeMonitor = nil
	}
}
