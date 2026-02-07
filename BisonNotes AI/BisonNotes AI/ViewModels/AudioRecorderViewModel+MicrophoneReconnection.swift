//
//  AudioRecorderViewModel+MicrophoneReconnection.swift
//  BisonNotes AI
//
//  Phase 2: Microphone disconnect detection, polling, and reconnection.
//

import Foundation
@preconcurrency import AVFoundation

// MARK: - Phase 2: Intelligent Microphone Reconnection

extension AudioRecorderViewModel {

	@MainActor
	func handleMicrophoneDisconnected() async {
		guard case .recording = recordingState else {
			print("⚠️ Microphone disconnected but not in recording state")
			return
		}

		// Pause recording and enter waiting state
		audioRecorder?.pause()
		recordingState = .waitingForMicrophone(disconnectedAt: Date())

		// Save current segment if recording was active
		if let url = recordingURL {
			if !recordingSegments.contains(url) {
				recordingSegments.append(url)
				print("✅ Saved segment before microphone disconnect: \(url.lastPathComponent)")
			}
		}

		// Send notification to user
		await sendWarningNotification(
			title: "Microphone Disconnected",
			body: "Waiting for microphone to reconnect...",
			isCritical: false
		)

		// Start polling for microphone reconnection
		startMicrophoneReconnectionMonitoring()
	}

	@MainActor
	func handleNewAudioDeviceAvailable(notification: Notification) async {
		// Check if we're waiting for a microphone
		guard case .waitingForMicrophone(let disconnectedAt) = recordingState else {
			// Not waiting, just update available inputs
			await applySelectedInputToSession()
			return
		}

		// Check if a microphone is now available
		let availableInputs = enhancedAudioSessionManager.getAvailableInputs()
		let hasMicrophone = availableInputs.contains(where: { input in
			let portType = input.portType
			return portType == .bluetoothHFP ||
				   portType == .builtInMic ||
				   portType == .headsetMic
		})

		if hasMicrophone {
			let downtime = Date().timeIntervalSince(disconnectedAt)
			print("✅ Microphone reconnected after \(downtime) seconds")

			// Stop monitoring timer
			microphoneReconnectionTimer?.invalidate()
			microphoneReconnectionTimer = nil

			// Auto-reconnect and resume
			await reconnectMicrophoneAndResume()
		}
	}

	@MainActor
	func reconnectMicrophoneAndResume() async {
		// Select best available input
		let availableInputs = enhancedAudioSessionManager.getAvailableInputs()

		// Prefer previously selected input, then Bluetooth, then built-in
		let preferredInputUID = UserDefaults.standard.string(forKey: preferredInputDefaultsKey)
		var inputToUse: AVAudioSessionPortDescription?

		// Try preferred input first
		if let uid = preferredInputUID {
			inputToUse = availableInputs.first { $0.uid == uid }
		}

		// Fallback to Bluetooth
		if inputToUse == nil {
			inputToUse = availableInputs.first { $0.portType == .bluetoothHFP }
		}

		// Fallback to built-in mic
		if inputToUse == nil {
			inputToUse = availableInputs.first { $0.portType == .builtInMic }
		}

		guard let input = inputToUse else {
			print("❌ No microphone available for reconnection")
			recordingState = .error("No microphone available")
			return
		}

		do {
			try await enhancedAudioSessionManager.setPreferredInput(input)
			print("✅ Microphone reconnected: \(input.portName)")

			// Resume recording with new segment
			recordingState = .recording
			await createNewSegmentAndResume()

			// Send success notification
			await sendWarningNotification(
				title: "Recording Resumed",
				body: "Microphone reconnected, recording continues",
				isCritical: false
			)

		} catch {
			print("❌ Failed to reconnect microphone: \(error)")
			recordingState = .error("Failed to reconnect microphone")
			await sendWarningNotification(
				title: "Microphone Error",
				body: "Failed to reconnect microphone: \(error.localizedDescription)",
				isCritical: true
			)
		}
	}

	func startMicrophoneReconnectionMonitoring() {
		microphoneReconnectionTimer?.invalidate()

		microphoneReconnectionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
			Task { @MainActor in
				guard let self = self else {
					timer.invalidate()
					return
				}

				// Check if we're still waiting for microphone
				guard case .waitingForMicrophone(let disconnectedAt) = self.recordingState else {
					// State changed, stop monitoring
					timer.invalidate()
					self.microphoneReconnectionTimer = nil
					return
				}

				// Check timeout (5 minutes)
				let elapsed = Date().timeIntervalSince(disconnectedAt)
				if elapsed > self.MICROPHONE_RECONNECTION_TIMEOUT {
					timer.invalidate()
					self.microphoneReconnectionTimer = nil
					print("⏱️ Microphone reconnection timeout (5 minutes)")
					self.handleInterruptedRecording(reason: "Microphone not reconnected within 5 minutes")
					return
				}

				// Manually check for microphone availability
				let availableInputs = self.enhancedAudioSessionManager.getAvailableInputs()
				let hasMicrophone = availableInputs.contains(where: { input in
					let portType = input.portType
					return portType == .bluetoothHFP ||
						   portType == .builtInMic ||
						   portType == .headsetMic
				})

				if hasMicrophone {
					timer.invalidate()
					self.microphoneReconnectionTimer = nil
					await self.reconnectMicrophoneAndResume()
				}
			}
		}
	}

	@MainActor
	func createNewSegmentAndResume() async {
		let newSegmentURL = createNewSegmentURL()

		do {
			// Use Whisper-optimized quality for new segment
			let selectedQuality = AudioQuality.whisperOptimized
			let settings = selectedQuality.settings

			audioRecorder = try AVAudioRecorder(url: newSegmentURL, settings: settings)
			audioRecorder?.delegate = self
			audioRecorder?.isMeteringEnabled = true

			if audioRecorder?.record() == true {
				recordingSegments.append(newSegmentURL)
				recordingURL = newSegmentURL
				isRecording = true
				startRecordingTimer()
				print("✅ New segment created and recording resumed")
			} else {
				throw AudioProcessingError.recordingFailed("Failed to start new segment")
			}
		} catch {
			print("❌ Failed to create new segment: \(error)")
			recordingState = .error("Failed to resume recording")
			errorMessage = "Failed to resume recording: \(error.localizedDescription)"
		}
	}

	func createNewSegmentURL() -> URL {
		let timestamp = ISO8601DateFormatter().string(from: Date())
		let filename = "segment_\(timestamp).m4a"
		let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
		return documentsPath.appendingPathComponent(filename)
	}
}
