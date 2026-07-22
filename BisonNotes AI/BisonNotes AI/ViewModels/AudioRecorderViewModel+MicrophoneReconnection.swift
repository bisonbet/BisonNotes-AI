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

	#if os(macOS)
	func setupMacInputDeviceMonitoring() {
		enhancedAudioSessionManager.startInputDeviceMonitoring { [weak self] in
			self?.scheduleMacInputDeviceRefresh()
		}
		scheduleMacInputDeviceRefresh()
	}

	/// Core Audio may emit several device-list/default-input callbacks for one
	/// physical connect or disconnect. Coalescing avoids rebuilding the engine
	/// more than once for the same change.
	func scheduleMacInputDeviceRefresh() {
		macInputDeviceChangeTask?.cancel()
		macInputDeviceChangeTask = Task { @MainActor [weak self] in
			do {
				try await Task.sleep(for: .milliseconds(250))
			} catch {
				return
			}
			await self?.handleMacInputDevicesChanged()
		}
	}

	@MainActor
	func handleMacInputDevicesChanged() async {
		availableInputs = enhancedAudioSessionManager.getAvailableInputs()

		if let storedUID = UserDefaults.standard.string(forKey: preferredInputDefaultsKey) {
			if let preferredInput = availableInputs.first(where: { $0.uid == storedUID }) {
				selectedInput = preferredInput
			} else {
				AppLog.shared.audioSession("Preferred Mac microphone disconnected; falling back to the system default")
				try? await enhancedAudioSessionManager.clearPreferredInput()
				UserDefaults.standard.removeObject(forKey: preferredInputDefaultsKey)
				selectedInput = nil
			}
		}

		switch recordingState {
		case .recording, .paused:
			guard enhancedAudioSessionManager.recordingInputNeedsRecovery() else { return }
			await recoverNativeMacInput(keepPaused: isPaused)
		case .waitingForMicrophone:
			guard enhancedAudioSessionManager.resolvedInputDeviceID() != nil else { return }
			await recoverNativeMacInput(keepPaused: false)
		default:
			break
		}
	}

	@MainActor
	func recoverNativeMacInput(keepPaused: Bool, forceRestart: Bool = false) async {
		guard !isRecoveringMacInput, isRecording, let finalURL = recordingURL else { return }
		isRecoveringMacInput = true
		defer { isRecoveringMacInput = false }

		let disconnectedAt: Date
		let wasAlreadyWaiting: Bool
		if !forceRestart,
		   case .waitingForMicrophone(let existingDisconnectedAt) = recordingState {
			wasAlreadyWaiting = true
			disconnectedAt = existingDisconnectedAt
		} else {
			wasAlreadyWaiting = false
			disconnectedAt = Date()
		}

		if !wasAlreadyWaiting {
			AppLog.shared.audioSession("Mac recording input changed; sealing the current audio segment")
			catalystSystemAudioCapture?.setPaused(true)
			stopRecordingTimer()
			sealNativeMacScratchSegment()
		}

		guard enhancedAudioSessionManager.resolvedInputDeviceID() != nil else {
			await waitForNativeMacInput(disconnectedAt: disconnectedAt, notify: !wasAlreadyWaiting)
			return
		}

		do {
			try startNativeMacContinuation(at: finalURL)
			catalystAwaitingRecoveryBuffer = true
			pendingMacInputRecovery = (keepPaused: keepPaused, notify: wasAlreadyWaiting)
			recordingState = .waitingForMicrophone(disconnectedAt: disconnectedAt)
			errorMessage = "Microphone connected. Confirming that audio is being received…"
		} catch {
			discardFailedNativeMacContinuation()
			pendingMacInputRecovery = nil
			catalystAwaitingRecoveryBuffer = false
			AppLog.shared.audioSession("Mac input recovery failed: \(error.localizedDescription)", level: .error)
			recordingState = .waitingForMicrophone(disconnectedAt: disconnectedAt)
			errorMessage = "Could not use the available microphone: \(error.localizedDescription)"
			startNativeMacInputRecoveryMonitoring()
		}
	}

	@MainActor
	private func waitForNativeMacInput(disconnectedAt: Date, notify: Bool) async {
		recordingState = .waitingForMicrophone(disconnectedAt: disconnectedAt)
		errorMessage = "Microphone disconnected. Recording will resume when an input is available."
		if notify {
			await sendWarningNotification(
				title: "Microphone Disconnected",
				body: "Waiting for a microphone to reconnect...",
				isCritical: false
			)
		}
		startNativeMacInputRecoveryMonitoring()
	}

	@MainActor
	func finishNativeMacInputRecovery(keepPaused: Bool, notify: Bool) async {
		microphoneReconnectionTimer?.invalidate()
		microphoneReconnectionTimer = nil
		pendingMacInputRecovery = nil
		catalystAwaitingRecoveryBuffer = false
		if keepPaused {
			pauseCatalystEngineRecording()
			recordingState = .paused
		} else {
			catalystSystemAudioCapture?.setPaused(false)
			recordingState = .recording
			startRecordingTimer()
		}
		errorMessage = "Recording continued with the available microphone."
		AppLog.shared.audioSession("Mac recording resumed on the available input")
		if notify {
			await sendWarningNotification(
				title: "Recording Resumed",
				body: "A microphone is available and recording has resumed.",
				isCritical: false
			)
		}
	}

	private func discardFailedNativeMacContinuation() {
		let failedScratchURL = catalystScratchRecordingURL
		stopCatalystEngineRecording()
		if let failedScratchURL {
			try? FileManager.default.removeItem(at: failedScratchURL)
		}
		catalystScratchRecordingURL = nil
	}

	func startNativeMacInputRecoveryMonitoring() {
		guard microphoneReconnectionTimer == nil else { return }
		microphoneReconnectionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
			Task { @MainActor in
				guard let self else {
					timer.invalidate()
					return
				}
				guard case .waitingForMicrophone(let disconnectedAt) = self.recordingState else {
					timer.invalidate()
					self.microphoneReconnectionTimer = nil
					return
				}
				guard Date().timeIntervalSince(disconnectedAt) <= self.MICROPHONE_RECONNECTION_TIMEOUT else {
					timer.invalidate()
					self.microphoneReconnectionTimer = nil
					self.errorMessage = "Recording stopped because no microphone was available for 5 minutes."
					self.stopRecording()
					return
				}
				await self.handleMacInputDevicesChanged()
			}
		}
	}
	#endif

	@MainActor
	func handleMicrophoneDisconnected() async {
		guard case .recording = recordingState else {
			AppLog.shared.audioSession("Microphone disconnected but not in recording state", level: .debug)
			return
		}

		// Pause recording and enter waiting state
		audioRecorder?.pause()
		recordingState = .waitingForMicrophone(disconnectedAt: Date())

		// Save current segment if recording was active
		if let url = recordingURL {
			if !recordingSegments.contains(url) {
				recordingSegments.append(url)
				AppLog.shared.audioSession("Saved segment before microphone disconnect")
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
			AppLog.shared.audioSession("Microphone reconnected after \(Int(downtime))s")

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
			AppLog.shared.audioSession("No microphone available for reconnection", level: .error)
			recordingState = .error("No microphone available")
			return
		}

		do {
			try await enhancedAudioSessionManager.setPreferredInput(input)
			AppLog.shared.audioSession("Microphone reconnected: \(input.portName)")

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
			AppLog.shared.audioSession("Failed to reconnect microphone: \(error)", level: .error)
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
					AppLog.shared.audioSession("Microphone reconnection timeout (5 minutes)")
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
			AppFileProtection.apply(to: newSegmentURL)
			audioRecorder?.isMeteringEnabled = true

			if audioRecorder?.record() == true {
				AppFileProtection.apply(to: newSegmentURL)
				recordingSegments.append(newSegmentURL)
				recordingURL = newSegmentURL
				isRecording = true
				startRecordingTimer()
				AppLog.shared.audioSession("New segment created and recording resumed")
			} else {
				throw AudioProcessingError.recordingFailed("Failed to start new segment")
			}
		} catch {
			AppLog.shared.audioSession("Failed to create new segment: \(error)", level: .error)
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
