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
		#if targetEnvironment(macCatalyst)
		// Mac apps don't get suspended like iOS — recording stays alive while the
		// app process is running. Skip the iOS background-task lifecycle to avoid
		// the "Background Task ... was created over 30 seconds ago" warning.
		return
		#else
		guard backgroundTask == .invalid else { return }
		AppLog.shared.backgroundProcessing("Starting background task for recording")
		backgroundTask = PlatformBackgroundTask.begin(name: "Recording") { [weak self] in
			AppLog.shared.backgroundProcessing("Recording background task expiring", level: .error)
			self?.endBackgroundTask()
		}
		#endif
	}

	func endBackgroundTask() {
		#if targetEnvironment(macCatalyst)
		return
		#else
		guard backgroundTask != .invalid else { return }
		AppLog.shared.backgroundProcessing("Ending recording background task")
		PlatformBackgroundTask.end(backgroundTask)
		backgroundTask = .invalid
		#endif
	}

	// MARK: - Background Time Monitoring

	func startBackgroundTimeMonitoring() {
		#if targetEnvironment(macCatalyst) || os(macOS)
		// No iOS-style background time limit on Mac — skip polling.
		return
		#else
		backgroundTimeMonitor?.invalidate()

		// Check remaining background time every 30 seconds
		backgroundTimeMonitor = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
			let remaining = PlatformBackgroundTask.remainingTime

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
		#endif
	}

	func stopBackgroundTimeMonitoring() {
		backgroundTimeMonitor?.invalidate()
		backgroundTimeMonitor = nil
	}
}
