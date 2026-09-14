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

		watchManager.onWatchSyncRecordingReceived = { [weak self] audioData, syncRequest in
			AppLog.shared.watchConnectivity("Received watch sync callback for recording: \(syncRequest.recordingId)")
			Task { @MainActor in
				self?.handleWatchSyncRecordingReceived(audioData, syncRequest: syncRequest)
			}
		}

		watchManager.onWatchSyncRecordingArtifactReceived = { [weak self] operation, syncRequest in
			AppLog.shared.watchConnectivity("Received durable watch staging for recording: \(syncRequest.recordingId)")
			Task { @MainActor in
				self?.handleWatchSyncRecordingReceived(operation, syncRequest: syncRequest)
			}
		}

		// Also set up the completion callback here since BisonNotesAIApp setup might not be working.
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

		AppLog.shared.watchConnectivity("Watch sync handlers configured", level: .debug)
	}

	/// Publish a Watch artifact only after it has been staged and recorded by the
	/// media recovery store. The sender is acknowledged by the existing callback
	/// only after the Core Data save succeeds.
	func handleWatchSyncRecordingReceived(_ operation: MediaOperation, syncRequest: WatchSyncRequest) {
		guard let coordinator = appCoordinator,
			  coordinator.storageState.isOperational,
			  let mediaRecoveryStore = MediaOperationRecoveryStore.live() else {
			AppLog.shared.watchConnectivity(
				"Watch recording retained by sender/staging because local storage is unavailable",
				level: .fault
			)
			WatchConnectivityManager.shared.onWatchRecordingSyncCompleted?(syncRequest.recordingId, false)
			return
		}

        Task {
            do {
                var pending: MediaOperation
                switch operation.receipt.phase {
                case .staged:
                    if FileManager.default.fileExists(atPath: operation.publishedURL.path) {
                        pending = operation
                    } else {
                        pending = try mediaRecoveryStore.publish(operation)
                    }
                    pending = try mediaRecoveryStore.markMetadataPending(pending)
                case .published:
                    pending = try mediaRecoveryStore.markMetadataPending(operation)
                case .metadataPending:
                    pending = try mediaRecoveryStore.markMetadataPending(operation)
                case .metadataCommitted:
                    pending = operation
                case .prepared:
                    throw MediaOperationRecoveryError.unavailable
                }

                let displayName = syncRequest.filename
                    .replacingOccurrences(of: "recording-", with: "")
                    .replacingOccurrences(of: ".m4a", with: "")
                let cleanDisplayName = "Audio Recording \(displayName)"

                let recordingId: UUID
                if let existing = try coordinator.coreDataManager.fetchRecording(url: pending.publishedURL) {
                    guard let existingID = existing.id else {
                        throw MediaOperationRecoveryError.receiptReadFailed(
                            "The existing Watch recording has no stable identity."
                        )
                    }
                    recordingId = existingID
                    AppLog.shared.watchConnectivity(
                        "Reused existing Core Data entry for retried Watch recording: \(existingID)",
                        level: .debug
                    )
                } else {
                    guard operation.receipt.phase != .metadataCommitted else {
                        throw MediaOperationRecoveryError.receiptReadFailed(
                            "A committed Watch operation has no matching recording."
                        )
                    }
                    recordingId = try coordinator.addWatchRecording(
                        url: pending.publishedURL,
                        name: cleanDisplayName,
                        date: syncRequest.createdAt,
                        fileSize: syncRequest.fileSize,
                        duration: syncRequest.duration,
                        quality: .whisperOptimized,
                        locationData: syncRequest.locationData?.toLocationData()
                    )
                }

                AppLog.shared.watchConnectivity("Created Core Data entry for watch recording: \(recordingId)")
                finishWatchReceipt(pending, senderID: syncRequest.recordingId, store: mediaRecoveryStore)

				NotificationCenter.default.post(name: NSNotification.Name("RecordingAdded"), object: nil)
				await MainActor.run {
					let watchManager = WatchConnectivityManager.shared
					watchManager.onWatchRecordingSyncCompleted?(syncRequest.recordingId, true)
				}
			} catch {
				if FileManager.default.fileExists(atPath: operation.publishedURL.path) {
					AppLog.shared.watchConnectivity(
						"Watch recording retained after a failed publication or metadata save: \(error.localizedDescription)",
						level: .error
					)
				} else {
					do {
						try mediaRecoveryStore.abortBeforePublish(operation)
					} catch {
						AppLog.shared.watchConnectivity(
							"Could not remove failed Watch staging state: \(error.localizedDescription)",
							level: .error
						)
					}
				}
				AppLog.shared.watchConnectivity(
					"Failed to create Core Data entry for watch recording: \(error.localizedDescription)",
					level: .error
				)
				await MainActor.run {
					WatchConnectivityManager.shared.onWatchRecordingSyncCompleted?(syncRequest.recordingId, false)
				}
			}
		}
	}

    private func finishWatchReceipt(_ pending: MediaOperation, senderID: UUID, store: MediaOperationRecoveryStore) {
                var receiptCommitted = false
                do {
                    let committed = try store.markMetadataCommitted(
                        pending,
                        recordingID: senderID
                    )
                    receiptCommitted = true
                    try store.finish(committed)
                } catch {
                    AppLog.shared.watchConnectivity(
                        "Watch receipt cleanup deferred after durable save: \(error.localizedDescription)",
                        level: .error
                    )
                }
                if receiptCommitted {
                    do {
                        try store.finishOperations(for: senderID)
                    } catch {
                        AppLog.shared.watchConnectivity(
                            "Duplicate Watch receipts remain for later cleanup: \(error.localizedDescription)",
                            level: .error
                        )
                    }
                }
    }

	/// Handle synchronized recording received from watch
	func handleWatchSyncRecordingReceived(_ audioData: Data, syncRequest: WatchSyncRequest) {
		guard let coordinator = appCoordinator,
			  coordinator.storageState.isOperational else {
			AppLog.shared.watchConnectivity(
				"Watch recording retained by sender: local storage is unavailable",
				level: .fault
			)
			return
		}
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

				// Create display name by removing the technical filename prefix
				let displayName = syncRequest.filename
					.replacingOccurrences(of: "recording-", with: "")
					.replacingOccurrences(of: ".m4a", with: "")
				let cleanDisplayName = "Audio Recording \(displayName)"

					let recordingId = try coordinator.addWatchRecording(
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
                    // Failure clears receiver in-flight state without acknowledging success.
                    WatchConnectivityManager.shared.onWatchRecordingSyncCompleted?(syncRequest.recordingId, false)
				}
		}
	}

}
