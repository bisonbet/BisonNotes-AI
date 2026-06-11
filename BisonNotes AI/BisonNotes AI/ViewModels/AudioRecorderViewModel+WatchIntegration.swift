//
//  AudioRecorderViewModel+WatchIntegration.swift
//  BisonNotes AI
//
//  Apple Watch sync and audio integration.
//

import Foundation

// MARK: - Watch Integration

extension AudioRecorderViewModel {

	/// Set up watch sync recording handler
	@MainActor
	func setupWatchSyncHandler() {
		let watchManager = WatchConnectivityManager.shared
		AppLog.shared.watchConnectivity("Setting up watch sync handler in AudioRecorderViewModel")

		watchManager.onWatchSyncRecordingReceived = { [weak self] audioData, syncRequest in
			AppLog.shared.watchConnectivity("Received watch sync callback for recording: \(syncRequest.recordingId)")
			Task { @MainActor in
				self?.handleWatchSyncRecordingReceived(audioData, syncRequest: syncRequest)
			}
		}

		// Also set up the completion callback here since BisonNotesAIApp setup might not be working
		AppLog.shared.watchConnectivity("Setting up onWatchRecordingSyncCompleted callback")
		watchManager.onWatchRecordingSyncCompleted = { recordingId, success in
			AppLog.shared.watchConnectivity("onWatchRecordingSyncCompleted called for: \(recordingId), success: \(success)")

			if success {
				let coreDataId = "core_data_\(recordingId.uuidString)"
				AppLog.shared.watchConnectivity("Calling confirmSyncComplete with success=true", level: .debug)
				watchManager.confirmSyncComplete(recordingId: recordingId, success: true, coreDataId: coreDataId)
				AppLog.shared.watchConnectivity("Confirmed reliable watch transfer: \(recordingId)")
			} else {
				AppLog.shared.watchConnectivity("Calling confirmSyncComplete with success=false", level: .debug)
				watchManager.confirmSyncComplete(recordingId: recordingId, success: false)
				AppLog.shared.watchConnectivity("Failed to confirm watch transfer: \(recordingId)", level: .error)
			}
		}

		AppLog.shared.watchConnectivity("AudioRecorderViewModel connected to WatchConnectivityManager sync handler")

		// Verify the callbacks were set
		if watchManager.onWatchSyncRecordingReceived != nil {
			AppLog.shared.watchConnectivity("Callback verification: onWatchSyncRecordingReceived is set", level: .debug)
		} else {
			AppLog.shared.watchConnectivity("Callback verification: onWatchSyncRecordingReceived is nil", level: .error)
		}

		if watchManager.onWatchRecordingSyncCompleted != nil {
			AppLog.shared.watchConnectivity("Callback verification: onWatchRecordingSyncCompleted is set", level: .debug)
		} else {
			AppLog.shared.watchConnectivity("Callback verification: onWatchRecordingSyncCompleted is nil", level: .error)
		}
	}

	/// Handle synchronized recording received from watch
	func handleWatchSyncRecordingReceived(_ audioData: Data, syncRequest: WatchSyncRequest) {
		AppLog.shared.watchConnectivity("Received synchronized recording from watch: \(syncRequest.recordingId)")

		Task {
			do {
				// Create a permanent file in Documents directory with iPhone app naming pattern
				guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
					throw NSError(domain: "AudioRecorderViewModel", code: -2, userInfo: [NSLocalizedDescriptionKey: "Could not access Documents directory"])
				}

				// Generate iPhone-style filename but keep original filename for display name
				let timestamp = syncRequest.createdAt.timeIntervalSince1970
				let iPhoneStyleFilename = "apprecording-\(Int(timestamp)).m4a"
				let permanentURL = documentsURL.appendingPathComponent(iPhoneStyleFilename)

				try audioData.write(to: permanentURL)
				AppFileProtection.apply(to: permanentURL)

				// Create Core Data entry
				guard let appCoordinator = appCoordinator else {
					throw NSError(domain: "AudioRecorderViewModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "App coordinator not available"])
				}

				// Create display name by removing the technical filename prefix
				let displayName = syncRequest.filename
					.replacingOccurrences(of: "recording-", with: "")
					.replacingOccurrences(of: ".m4a", with: "")
				let cleanDisplayName = "Audio Recording \(displayName)"

				let recordingId = await appCoordinator.addWatchRecording(
					url: permanentURL,
					name: cleanDisplayName,
					date: syncRequest.createdAt,
					fileSize: syncRequest.fileSize,
					duration: syncRequest.duration,
					quality: .whisperOptimized,
					locationData: syncRequest.locationData?.toLocationData()
				)

				AppLog.shared.watchConnectivity("Created Core Data entry for watch recording: \(recordingId)")

				// Notify UI to refresh recordings list
				NotificationCenter.default.post(name: NSNotification.Name("RecordingAdded"), object: nil)

				// Recording sync completed successfully - notify the completion callback
				await MainActor.run {
					let watchManager = WatchConnectivityManager.shared
					AppLog.shared.watchConnectivity("Calling onWatchRecordingSyncCompleted - callback is nil: \(watchManager.onWatchRecordingSyncCompleted == nil)", level: .debug)
					watchManager.onWatchRecordingSyncCompleted?(syncRequest.recordingId, true)
					AppLog.shared.watchConnectivity("Called completion callback for successful watch recording: \(syncRequest.recordingId)")
				}

			} catch {
				AppLog.shared.watchConnectivity("Failed to create Core Data entry for watch recording: \(error)", level: .error)

				// Recording sync failed - notify the completion callback
				await MainActor.run {
					let watchManager = WatchConnectivityManager.shared
					watchManager.onWatchRecordingSyncCompleted?(syncRequest.recordingId, false)
					AppLog.shared.watchConnectivity("Called completion callback for failed watch recording: \(syncRequest.recordingId)", level: .error)
				}
			}
		}
	}

}
