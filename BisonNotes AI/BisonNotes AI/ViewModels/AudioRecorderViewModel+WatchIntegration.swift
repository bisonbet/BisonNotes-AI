//
//  AudioRecorderViewModel+WatchIntegration.swift
//  BisonNotes AI
//
//  Apple Watch sync and audio integration.
//

import Foundation

private struct SQLiteWatchMediaMetadata: Codable, Sendable {
	static let currentSchemaVersion = 1

	let schemaVersion: Int
	let recordingId: UUID
	let filename: String
	let duration: TimeInterval
	let fileSize: Int64
	let createdAt: Date
	let checksumMD5: String
	let locationData: WatchLocationData?

	init(request: WatchSyncRequest) {
		self.schemaVersion = Self.currentSchemaVersion
		self.recordingId = request.recordingId
		self.filename = request.filename
		self.duration = request.duration
		self.fileSize = request.fileSize
		self.createdAt = request.createdAt
		self.checksumMD5 = request.checksumMD5
		self.locationData = request.locationData
	}

}

private enum SQLiteWatchMediaTransferError: LocalizedError {
	case persistenceUnavailable
	case invalidDescriptor
	case destinationUnavailable
	case sourceRetentionIncomplete

	var errorDescription: String? {
		switch self {
		case .persistenceUnavailable:
			return "Durable storage is unavailable for the Watch transfer."
		case .invalidDescriptor:
			return "The Watch transfer metadata descriptor is invalid."
		case .destinationUnavailable:
			return "The Watch transfer destination is unavailable."
		case .sourceRetentionIncomplete:
			return "The Watch transfer completed but its staged source was not removed."
		}
	}
}

// MARK: - Watch Integration

extension AudioRecorderViewModel {

	/// Set up watch sync recording handler
	@MainActor
	func setupWatchSyncHandler() {
		let watchManager = WatchConnectivityManager.shared

		// The file callback keeps the audio in the persistent staging area while
		// the media journal copies it in the background. The old Data callback is
		// intentionally disabled for production setup so a Watch recording is not
		// duplicated in memory before it reaches Documents.
		watchManager.onWatchSyncRecordingReceived = nil
		watchManager.onWatchSyncFileReceived = { [weak self] fileURL, syncRequest in
			AppLog.shared.watchConnectivity("Received watch file callback for recording: \(syncRequest.recordingId)")
			Task { @MainActor in
				await self?.handleWatchSyncFileReceived(fileURL, syncRequest: syncRequest)
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

		retryPendingWatchTransfers()
	}

	/// Re-runs the bounded Watch journal pass after foreground activation. A
	/// prior pass may have been interrupted by background expiration or an app
	/// kill, so activation is an explicit retry opportunity rather than a
	/// one-shot launch assumption.
	func retryPendingWatchTransfers() {
		watchMediaTransferRetryTask?.cancel()
		watchMediaTransferRetryTask = Task { @MainActor [weak self] in
			await self?.reconcilePendingWatchTransfers()
		}
	}

	/// Moves one Watch delivery through the journaled media boundary. Core Data
	/// remains the metadata authority until cutover, while the staged source and
	/// copy receipt are durable across an app kill.
	private func handleWatchSyncFileReceived(
		_ stagedURL: URL,
		syncRequest: WatchSyncRequest
	) async {
		let watchManager = WatchConnectivityManager.shared
		do {
			guard let appCoordinator,
				  appCoordinator.storageStatus.isDurable else {
				throw SQLiteWatchMediaTransferError.persistenceUnavailable
			}

			guard let dependencies = try watchMediaTransferDependencies(
				createIfMissing: true
			) else {
				throw SQLiteWatchMediaTransferError.persistenceUnavailable
			}
			let metadata = SQLiteWatchMediaMetadata(request: syncRequest)
			let metadataPayload = try JSONEncoder().encode(metadata)
			let recordingKey = syncRequest.recordingId.uuidString.lowercased()
			let request = SQLiteMediaTransferRequest(
				sourceTransferID: "watch-transfer-\(recordingKey)",
				operationID: "watch-media-\(recordingKey)",
				assetID: "watch-asset-\(recordingKey)",
				ownerStorageID: "core-data-recording-\(recordingKey)",
				ownerRevision: nil,
				sourceURL: stagedURL,
				destinationRootID: SQLiteApplicationMediaRootID.documents.rawValue,
				destinationRelativePath: "apprecording-watch-\(recordingKey).m4a",
				metadataPayload: metadataPayload
			)
			NotificationCenter.default.post(
				name: SQLiteApplicationMediaTransferLifecycle.retryRequested,
				object: nil
			)
			let metadataCommit = makeWatchMetadataCommit(
				appCoordinator: appCoordinator,
				mapping: dependencies.mapping
			)

			let result = try await dependencies.runtime.transfer(
				request,
				metadataCommit: metadataCommit
			)
			guard result.sourceRetention == .eligibleForRemoval else {
				throw SQLiteWatchMediaTransferError.sourceRetentionIncomplete
			}
			_ = try await dependencies.runtime.removeSourceIfEligible(
				sourceTransferID: request.sourceTransferID,
				operationID: request.operationID
			)

			AppLog.shared.watchConnectivity(
				"Journaled Watch recording and removed its staged source: \(syncRequest.recordingId)",
				level: .debug
			)
			watchManager.onWatchRecordingSyncCompleted?(syncRequest.recordingId, true)
		} catch is CancellationError {
			AppLog.shared.watchConnectivity(
				"Watch transfer was cancelled; staged source remains for retry: \(syncRequest.recordingId)",
				level: .error
			)
			watchManager.onWatchRecordingSyncCompleted?(syncRequest.recordingId, false)
		} catch {
			AppLog.shared.watchConnectivity(
				"Failed to journal Watch recording; staged source remains for retry: \(error)",
				level: .error
			)
			watchManager.onWatchRecordingSyncCompleted?(syncRequest.recordingId, false)
		}
	}

	/// Retries media operations left by a prior launch. Opening the journal is
	/// read-only with respect to ordinary launches: a new journal is created
	/// only when a Watch delivery actually arrives.
	private func reconcilePendingWatchTransfers() async {
		guard let appCoordinator,
			  appCoordinator.storageStatus.isDurable else {
			return
		}

		do {
			guard let dependencies = try watchMediaTransferDependencies(
				createIfMissing: false
			) else {
				return
			}
			let metadataCommit = makeWatchMetadataCommit(
				appCoordinator: appCoordinator,
				mapping: dependencies.mapping
			)
			let report = try await dependencies.runtime.reconcilePending(
				maxOperations: 8,
				metadataCommit: metadataCommit
			)
			let removedCount = try await dependencies.runtime.removeEligibleSources(
				sourceRoot: SQLiteApplicationMediaRootID.watchTransferStaging.rawValue,
				maxOperations: 8
			)
			if report.selectedOperationCount > 0 || removedCount > 0 {
				AppLog.shared.watchConnectivity(
					"Watch transfer retry pass: selected=\(report.selectedOperationCount), "
						+ "completed=\(report.completedOperationCount), "
						+ "failed=\(report.failedOperationCount), "
						+ "sourcesRemoved=\(removedCount)",
					level: .debug
				)
			}
		} catch is CancellationError {
			return
		} catch {
			AppLog.shared.watchConnectivity(
				"Watch transfer retry pass failed; journal remains for a later retry: \(error)",
				level: .error
			)
		}
	}

	private func watchMediaTransferDependencies(
		createIfMissing: Bool
	) throws -> (
		runtime: SQLiteApplicationMediaTransferRuntime,
		mapping: SQLiteApplicationMediaRootMapping
	)? {
		if let watchMediaTransferRuntime,
		   let watchMediaTransferMapping {
			return (
				runtime: watchMediaTransferRuntime,
				mapping: watchMediaTransferMapping
			)
		}

		let fileManager = FileManager.default
		guard let applicationSupportURL = fileManager.urls(
			for: .applicationSupportDirectory,
			in: .userDomainMask
		).first else {
			throw SQLiteWatchMediaTransferError.persistenceUnavailable
		}
		let journalDirectory = applicationSupportURL.appendingPathComponent(
			"SQLiteMigration",
			isDirectory: true
		)
		let databaseURL = journalDirectory.appendingPathComponent(
			"watch-media-transfer-journal.sqlite",
			isDirectory: false
		)
		if !createIfMissing,
		   !fileManager.fileExists(atPath: databaseURL.path) {
			return nil
		}

		try fileManager.createDirectory(
			at: journalDirectory,
			withIntermediateDirectories: true
		)
		AppFileProtection.apply(to: journalDirectory)
		let mapping = try SQLiteApplicationMediaRootMapping(
			fileManager: fileManager
		)
		let store = try SQLiteLibraryStore(databaseURL: databaseURL)
		AppFileProtection.apply(to: databaseURL)
		let runtime = SQLiteApplicationMediaTransferRuntime(
			coordinator: SQLiteApplicationMediaTransferCoordinator(
				store: store,
				mapping: mapping
			)
		)
		watchMediaTransferMapping = mapping
		watchMediaTransferRuntime = runtime
		return (runtime: runtime, mapping: mapping)
	}

	private func makeWatchMetadataCommit(
		appCoordinator: AppDataCoordinator,
		mapping: SQLiteApplicationMediaRootMapping
	) -> SQLiteMediaMetadataCommit {
		{ operation in
			guard let payload = operation.metadataPayload,
				  let metadata = try? JSONDecoder().decode(
					SQLiteWatchMediaMetadata.self,
					from: payload
				  ),
				  metadata.schemaVersion == SQLiteWatchMediaMetadata.currentSchemaVersion,
				  let destinationRoot = operation.destinationRoot,
				  let destinationRelativePath = operation.destinationRelativePath else {
				throw SQLiteWatchMediaTransferError.invalidDescriptor
			}

			let destinationURL: URL
			do {
				destinationURL = try mapping.registry.destinationURL(
					root: destinationRoot,
					relativePath: destinationRelativePath
				)
			} catch {
				throw SQLiteWatchMediaTransferError.destinationUnavailable
			}
			guard FileManager.default.fileExists(atPath: destinationURL.path),
				  operation.expectedByteLength == metadata.fileSize else {
				throw SQLiteWatchMediaTransferError.destinationUnavailable
			}

			AppFileProtection.apply(to: destinationURL)
			_ = try await appCoordinator.createOrValidateWatchRecordingUsingRepository(
				id: metadata.recordingId,
				url: destinationURL,
				name: Self.watchDisplayName(for: metadata.filename),
				date: metadata.createdAt,
				fileSize: metadata.fileSize,
				duration: metadata.duration,
				quality: .whisperOptimized,
				locationData: metadata.locationData?.toLocationData()
			)
			NotificationCenter.default.post(
				name: NSNotification.Name("RecordingAdded"),
				object: nil
			)
		}
	}

	private static func watchDisplayName(for filename: String) -> String {
		let displayName = filename
			.replacingOccurrences(of: "recording-", with: "")
			.replacingOccurrences(of: ".m4a", with: "")
		return "Audio Recording \(displayName)"
	}

	/// Handle synchronized recording received from watch
	func handleWatchSyncRecordingReceived(_ audioData: Data, syncRequest: WatchSyncRequest) {
		AppLog.shared.watchConnectivity("Received synchronized recording from watch: \(syncRequest.recordingId)")

		Task {
			var permanentURL: URL?
			do {
				// Create a permanent file in Documents directory with iPhone app naming pattern
				guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
					throw NSError(domain: "AudioRecorderViewModel", code: -2, userInfo: [NSLocalizedDescriptionKey: "Could not access Documents directory"])
				}

				// Generate iPhone-style filename but keep original filename for display name
				let timestamp = syncRequest.createdAt.timeIntervalSince1970
				let iPhoneStyleFilename = "apprecording-\(Int(timestamp)).m4a"
				let destinationURL = documentsURL.appendingPathComponent(iPhoneStyleFilename)
				permanentURL = destinationURL

				try audioData.write(to: destinationURL)
				AppFileProtection.apply(to: destinationURL)

				// Create the repository metadata entry
				guard let appCoordinator = appCoordinator else {
					throw NSError(domain: "AudioRecorderViewModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "App coordinator not available"])
				}

				// Create display name by removing the technical filename prefix
				let displayName = syncRequest.filename
					.replacingOccurrences(of: "recording-", with: "")
					.replacingOccurrences(of: ".m4a", with: "")
				let cleanDisplayName = "Audio Recording \(displayName)"

				let recordingID = try await appCoordinator.createRecordingUsingRepository(
					url: destinationURL,
					name: cleanDisplayName,
					date: syncRequest.createdAt,
					fileSize: syncRequest.fileSize,
					duration: syncRequest.duration,
					quality: .whisperOptimized,
					locationData: syncRequest.locationData?.toLocationData()
				)

				AppLog.shared.watchConnectivity("Created repository entry for watch recording: \(recordingID)")

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
				if let permanentURL, FileManager.default.fileExists(atPath: permanentURL.path) {
					try? FileManager.default.removeItem(at: permanentURL)
				}
				AppLog.shared.watchConnectivity("Failed to persist repository entry for watch recording; destination was removed for retry: \(error)", level: .error)

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
