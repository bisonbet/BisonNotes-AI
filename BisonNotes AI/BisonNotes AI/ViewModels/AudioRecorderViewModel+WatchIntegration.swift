//
//  AudioRecorderViewModel+WatchIntegration.swift
//  BisonNotes AI
//
//  Apple Watch sync and audio integration.
//

import Foundation
@preconcurrency import AVFoundation

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
					quality: .whisperOptimized
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

	func createPlayableAudioFile(from pcmData: Data, sessionId: UUID) async throws -> URL {
		// Create a temporary file URL for the audio
		let tempDir = FileManager.default.temporaryDirectory
		let audioFileName = "watch_recording_\(sessionId.uuidString).wav"
		let audioFileURL = tempDir.appendingPathComponent(audioFileName)

		// Configure audio format (matching watch recording settings)
		let sampleRate = 16000.0 // From WatchAudioFormat
		let channels: UInt32 = 1
		let bitDepth: UInt32 = 16

		// Create WAV file with PCM data
		let audioFormat = AVAudioFormat(
			commonFormat: .pcmFormatInt16,
			sampleRate: sampleRate,
			channels: channels,
			interleaved: false
		)

		guard let format = audioFormat else {
			throw NSError(domain: "AudioConversion", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio format"])
		}

		// Create the audio file
		let audioFile = try AVAudioFile(forWriting: audioFileURL, settings: format.settings)

		// Calculate frame count from PCM data
		let bytesPerFrame = Int(channels * bitDepth / 8)
		let frameCount = AVAudioFrameCount(pcmData.count / bytesPerFrame)

		// Create audio buffer
		guard let audioBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
			throw NSError(domain: "AudioConversion", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer"])
		}

		// Copy PCM data to buffer
		audioBuffer.frameLength = frameCount
		let channelData = audioBuffer.int16ChannelData![0]
		pcmData.withUnsafeBytes { bytes in
			let int16Ptr = bytes.bindMemory(to: Int16.self)
			channelData.update(from: int16Ptr.baseAddress!, count: Int(frameCount))
		}

		// Write buffer to file
		try audioFile.write(from: audioBuffer)

		return audioFileURL
	}

	func handleWatchError(_ error: WatchErrorMessage) {
		AppLog.shared.watchConnectivity("Watch error received: \(error.message)", level: .error)

		// Display error to user
		errorMessage = "Watch: \(error.message)"

		// Handle specific error types
		switch error.errorType {
		case .connectionLost:
			// Watch disconnected
			break
		case .batteryTooLow:
			errorMessage = "Watch battery too low for recording"
		case .audioRecordingFailed:
			errorMessage = "Watch recording failed, continuing with phone only"
		default:
			break
		}
	}

	func notifyWatchOfRecordingStateChange() {
		// Watch communication removed - this is now a no-op
	}

	// MARK: - Watch Audio Integration

	/// Integrate watch audio with phone recording for enhanced quality
	func integrateWatchAudioWithRecording(
		phoneAudioURL: URL,
		watchAudioData: Data,
		recordingId: UUID
	) async throws -> URL {
		// For now, implement a simple strategy:
		// 1. If phone audio exists and is good quality, use it as primary
		// 2. If phone audio is poor or missing, use watch audio
		// 3. Store both for future advanced mixing capabilities

		let phoneFileExists = FileManager.default.fileExists(atPath: phoneAudioURL.path)

		if phoneFileExists {
			// Check phone audio quality/size
			let phoneAudioSize = try FileManager.default.attributesOfItem(atPath: phoneAudioURL.path)[.size] as? Int64 ?? 0

			// If phone audio is substantial (> 10KB), keep it as primary
			if phoneAudioSize > 10000 {
				AppLog.shared.watchConnectivity("Using phone audio as primary (\(phoneAudioSize) bytes), storing watch audio as backup")
				await storeWatchAudioAsBackup(watchAudioData, for: recordingId)
				return phoneAudioURL
			}
		}

		// Use watch audio as primary
		AppLog.shared.watchConnectivity("Using watch audio as primary (\(watchAudioData.count) bytes)")
		let watchAudioURL = try await createWatchAudioFile(from: watchAudioData, recordingId: recordingId)

		// Store phone audio as backup if it exists
		if phoneFileExists {
			await storePhoneAudioAsBackup(phoneAudioURL, for: recordingId)
		}

		return watchAudioURL
	}

	/// Create an audio file from watch PCM data
	func createWatchAudioFile(from watchData: Data, recordingId: UUID) async throws -> URL {
		let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
		let watchAudioURL = documentsURL.appendingPathComponent("watch_\(recordingId).wav")

		// Configure audio format to match watch recording
		let sampleRate = 16000.0
		let channels: UInt32 = 1
		let bitDepth: UInt32 = 16

		guard let audioFormat = AVAudioFormat(
			commonFormat: .pcmFormatInt16,
			sampleRate: sampleRate,
			channels: channels,
			interleaved: false
		) else {
			throw AudioIntegrationError.formatCreationFailed
		}

		// Create audio file
		do {
			let audioFile = try AVAudioFile(forWriting: watchAudioURL, settings: audioFormat.settings)

			// Calculate frame count
			let bytesPerFrame = Int(channels * bitDepth / 8)
			let frameCount = AVAudioFrameCount(watchData.count / bytesPerFrame)

			// Create audio buffer
			guard let audioBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else {
				throw AudioIntegrationError.bufferCreationFailed
			}

			audioBuffer.frameLength = frameCount

			// Copy PCM data to buffer
			let audioBytes = watchData.withUnsafeBytes { bytes in
				return bytes.bindMemory(to: Int16.self)
			}

			if let channelData = audioBuffer.int16ChannelData {
				channelData[0].update(from: audioBytes.baseAddress!, count: Int(frameCount))
			}

			// Write to file
			try audioFile.write(from: audioBuffer)

			AppLog.shared.watchConnectivity("Created watch audio file")
			return watchAudioURL

		} catch {
			AppLog.shared.watchConnectivity("Failed to create watch audio file: \(error)", level: .error)
			throw AudioIntegrationError.fileCreationFailed(error.localizedDescription)
		}
	}

	/// Store watch audio as backup/supplementary data
	func storeWatchAudioAsBackup(_ watchAudioData: Data, for recordingId: UUID) async {
		do {
			let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
			let backupURL = documentsURL.appendingPathComponent("watch_backup_\(recordingId).pcm")

			try watchAudioData.write(to: backupURL)
			AppLog.shared.watchConnectivity("Stored watch audio backup")

			// Optionally store metadata about the backup
			let metadataURL = documentsURL.appendingPathComponent("watch_backup_\(recordingId).json")
			let metadata: [String: Any] = [
				"recordingId": recordingId,
				"dataSize": watchAudioData.count,
				"sampleRate": 16000,
				"channels": 1,
				"bitDepth": 16,
				"timestamp": Date().timeIntervalSince1970,
				"source": "appleWatch"
			]

			let metadataData = try JSONSerialization.data(withJSONObject: metadata)
			try metadataData.write(to: metadataURL)

		} catch {
			AppLog.shared.watchConnectivity("Failed to store watch audio backup: \(error)", level: .error)
		}
	}

	/// Store phone audio as backup when watch audio is primary
	func storePhoneAudioAsBackup(_ phoneAudioURL: URL, for recordingId: UUID) async {
		do {
			let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
			let backupURL = documentsURL.appendingPathComponent("phone_backup_\(recordingId).m4a")

			try FileManager.default.copyItem(at: phoneAudioURL, to: backupURL)
			AppLog.shared.watchConnectivity("Stored phone audio backup")

		} catch {
			AppLog.shared.watchConnectivity("Failed to store phone audio backup: \(error)", level: .error)
		}
	}
}
