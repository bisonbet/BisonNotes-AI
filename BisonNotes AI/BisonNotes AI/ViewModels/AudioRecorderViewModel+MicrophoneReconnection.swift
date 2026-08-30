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
			Task { @MainActor [weak self] in
				self?.scheduleMacInputDeviceRefresh()
			}
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
				// Keep the persisted preference so the chosen mic is re-selected
				// automatically when it reconnects. Only drop the active selection and
				// fall back to the system default while the device is absent — do NOT
				// erase the stored UID, or a transient unplug would forget the setting.
				AppLog.shared.audioSession("Preferred Mac microphone unavailable; using the system default until it reconnects")
				try? await enhancedAudioSessionManager.clearPreferredInput()
				selectedInput = nil
			}
		}

		switch recordingState {
		case .recording, .paused:
			guard enhancedAudioSessionManager.recordingInputNeedsRecovery() else { return }
			await recoverNativeMacInput(keepPaused: isPaused)
		case .waitingForMicrophone:
			guard !macAwaitingRecoveryBuffer else { return }
			guard enhancedAudioSessionManager.resolvedInputDeviceID() != nil else { return }
			// A device became available while we were waiting, so the input we were
			// last bound to is no longer evidence of a bad device — Core Audio may
			// have handed the reconnected microphone the same ID. See
			// `MacRecordingInputSelection.excludedDeviceID`.
			await recoverNativeMacInput(keepPaused: false, trigger: .deviceBecameAvailable)
		default:
			break
		}
	}

	@MainActor
	func recoverNativeMacInput(
		keepPaused: Bool,
		forceRestart: Bool = false,
		trigger: MacInputRecoveryTrigger = .currentInputFailed
	) async {
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
			if !macSystemAudioContinuesWithoutMicrophone {
				macSystemAudioCapture?.setPaused(true)
				stopRecordingTimer()
			}
			sealNativeMacScratchSegment()
		}

		do {
			try startMacContinuationWithAutomaticInputFallback(
				at: finalURL,
				excluding: MacRecordingInputSelection.excludedDeviceID(
					currentInputDeviceID: macInputDeviceID,
					trigger: trigger
				)
			)
			macAwaitingRecoveryBuffer = true
			pendingMacInputRecovery = PendingMacInputRecovery(
				keepPaused: keepPaused,
				notify: wasAlreadyWaiting,
				systemAudioContinued: macSystemAudioContinuesWithoutMicrophone
			)
			recordingState = .waitingForMicrophone(disconnectedAt: disconnectedAt)
			errorMessage = "Microphone connected. Confirming that audio is being received…"
		} catch {
			pendingMacInputRecovery = nil
			macAwaitingRecoveryBuffer = false
			AppLog.shared.audioSession("Mac input recovery failed: \(error.localizedDescription)", level: .error)
			if !keepPaused, continueMacSystemAudioWithoutMicrophone(after: error) {
				return
			}
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
	func finishNativeMacInputRecovery(
		keepPaused: Bool,
		notify: Bool,
		systemAudioContinued: Bool
	) async {
		microphoneReconnectionTimer?.invalidate()
		microphoneReconnectionTimer = nil
		pendingMacInputRecovery = nil
		macAwaitingRecoveryBuffer = false
		if keepPaused {
			pauseMacEngineRecording()
			recordingState = .paused
		} else {
			macSystemAudioCapture?.setPaused(false)
			recordingState = .recording
			if !systemAudioContinued {
				startRecordingTimer()
			}
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

	func startNativeMacInputRecoveryMonitoring() {
		guard microphoneReconnectionTimer == nil else { return }
		// The run loop retains a scheduled timer until it is invalidated, so a
		// dropped property does not stop it. The nonisolated deinit cannot
		// invalidate it either (invalidate() must run on the installing thread),
		// so the block self-invalidates on its own run loop once the owner is gone.
		microphoneReconnectionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
			guard self != nil else { timer.invalidate(); return }
			Task { @MainActor [weak self] in
				guard let self else {
					return
				}
				guard case .waitingForMicrophone(let disconnectedAt) = self.recordingState else {
					self.microphoneReconnectionTimer?.invalidate()
					self.microphoneReconnectionTimer = nil
					return
				}
				guard Date().timeIntervalSince(disconnectedAt) <= self.MICROPHONE_RECONNECTION_TIMEOUT else {
					self.microphoneReconnectionTimer?.invalidate()
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

		// The run loop retains a scheduled timer until it is invalidated, so a
		// dropped property does not stop it. The nonisolated deinit cannot
		// invalidate it either (invalidate() must run on the installing thread),
		// so the block self-invalidates on its own run loop once the owner is gone.
		microphoneReconnectionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
			guard self != nil else { timer.invalidate(); return }
			Task { @MainActor [weak self] in
				guard let self else {
					return
				}

				// Check if we're still waiting for microphone
				guard case .waitingForMicrophone(let disconnectedAt) = self.recordingState else {
					// State changed, stop monitoring
					self.microphoneReconnectionTimer?.invalidate()
					self.microphoneReconnectionTimer = nil
					return
				}

				// Check timeout (5 minutes)
				let elapsed = Date().timeIntervalSince(disconnectedAt)
				if elapsed > self.MICROPHONE_RECONNECTION_TIMEOUT {
					self.microphoneReconnectionTimer?.invalidate()
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
					self.microphoneReconnectionTimer?.invalidate()
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
