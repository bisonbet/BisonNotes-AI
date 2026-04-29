//
//  AudioRecorderViewModel.swift
//  Audio Journal
//
//  Created by Tim Champ on 7/28/25.
//

import Foundation
@preconcurrency import AVFoundation
import SwiftUI
import Combine
import CoreLocation
import UserNotifications
#if !targetEnvironment(macCatalyst)
import CallKit
#endif

class AudioRecorderViewModel: NSObject, ObservableObject {

	// MARK: - Published Properties

	@Published var isRecording = false
	@Published var isPlaying = false
	@Published var recordingTime: TimeInterval = 0
	@Published var playingTime: TimeInterval = 0
	@Published var liveTranscriptText: String = ""
	@Published var availableInputs: [AVAudioSessionPortDescription] = []
	@Published var selectedInput: AVAudioSessionPortDescription?
	@Published var recordingURL: URL?
	@Published var errorMessage: String?
	@Published var enhancedAudioSessionManager: EnhancedAudioSessionManager
	@Published var locationManager: LocationManager
	@Published var currentLocationData: LocationData?
	@Published var isLocationTrackingEnabled: Bool = false
	@Published var recordingState: RecordingState = .idle

	// MARK: - Internal Properties (accessed by extensions)

	var recordingStartLocationData: LocationData?

	// Reference to the app coordinator for adding recordings to registry
	var appCoordinator: AppDataCoordinator?
	var workflowManager: RecordingWorkflowManager?
	var cancellables = Set<AnyCancellable>()

	var audioRecorder: AVAudioRecorder?
	var audioPlayer: AVAudioPlayer?
	var recordingTimer: Timer?
	var playingTimer: Timer?
	var interruptionObserver: NSObjectProtocol?
	var routeChangeObserver: NSObjectProtocol?
	var willEnterForegroundObserver: NSObjectProtocol?
	let preferredInputDefaultsKey = "PreferredAudioInputUID"

	// Live transcription service (used when live transcription setting is enabled)
	var liveTranscriptionService: LiveTranscriptionService?
	var isUsingLiveTranscription = false

	// Flag to prevent duplicate recording creation
	var recordingBeingProcessed = false

	// Flag to track if app is backgrounding (to avoid false positive interruptions)
	var appIsBackgrounding = false

	// Flag to track if we're currently in an interruption (e.g., incoming phone call)
	var isInInterruption = false

	// Guard against concurrent resume attempts from CallKit / interruption handler / foreground handler
	var isResuming = false

	// Store the recording URL when interruption begins, in case we need to recover
	var interruptionRecordingURL: URL?

	// Track when recorder stopped unexpectedly (to give interruption notifications time to arrive)
	var recorderStoppedUnexpectedlyTime: Date?

	// Timestamp to track when last recovery was attempted (to prevent rapid duplicates)
	var lastRecoveryAttempt: Date = Date.distantPast

	// Background task identifier for recording continuity
	var backgroundTask: UIBackgroundTaskIdentifier = .invalid

	// Track last checkpoint time for periodic data flushing
	var lastCheckpointTime: Date = Date.distantPast
	var recordingStartedAt: (url: URL, date: Date)?
	let checkpointInterval: TimeInterval = 30.0 // Try to checkpoint every 30 seconds
	let forceCheckpointInterval: TimeInterval = 90.0 // Force checkpoint after 90 seconds even without silence

	// Audio level monitoring for silence detection
	let silenceThreshold: Float = -40.0 // dB threshold for silence (typical voice is -20 to -10 dB)

	// Recording segment management for handling interruptions
	var recordingSegments: [URL] = [] // Track all segments of the current recording
	var mainRecordingURL: URL? // The final merged recording URL
	var currentSegmentIndex: Int = 0 // Track which segment we're on

	// Call interruption intelligence (Phase 1)
	#if !targetEnvironment(macCatalyst)
	var callObserver: CXCallObserver?
	#endif
	var callInterruptionStartTime: Date?
	var deferredCallDuration: TimeInterval? // Set when CallKit defers during background
	let SHORT_CALL_THRESHOLD: TimeInterval = 180 // 3 minutes

	// Microphone reconnection monitoring (Phase 2)
	var microphoneReconnectionTimer: Timer?
	let MICROPHONE_RECONNECTION_TIMEOUT: TimeInterval = 300 // 5 minutes

	// Background time monitoring (Phase 4)
	var backgroundTimeMonitor: Timer?

	// Recording limits and warning thresholds (Phase 3)
	let MAX_RECORDING_DURATION: TimeInterval = 10800 // 3 hours
	let DURATION_WARNING_THRESHOLD: TimeInterval = 9900 // 2h 45m (15 min warning)
	let MIN_STORAGE_REQUIRED_MB: Int64 = 100 // Stop recording at 100 MB free
	let STORAGE_WARNING_THRESHOLD_MB: Int64 = 200 // Warn at 200 MB free
	let MIN_BATTERY_LEVEL: Float = 0.05 // Stop at 5%
	let BATTERY_WARNING_THRESHOLD: Float = 0.15 // Warn at 15%

	// Track if warnings already shown (prevent duplicates)
	var hasShownDurationWarning = false
	var hasShownStorageWarning = false
	var hasShownBatteryWarning = false

	// MARK: - Enhanced State Management (Phase 1)

	/// Granular recording states for precise interruption handling
	enum RecordingState: Equatable {
		case idle
		case recording
		case paused
		case interrupted(reason: InterruptionReason, startedAt: Date)
		case waitingForMicrophone(disconnectedAt: Date)
		case waitingForUserDecision(callDuration: TimeInterval)
		case merging
		case error(String)

		static func == (lhs: RecordingState, rhs: RecordingState) -> Bool {
			switch (lhs, rhs) {
			case (.idle, .idle),
				 (.recording, .recording),
				 (.paused, .paused),
				 (.merging, .merging):
				return true
			case (.interrupted(let lReason, _), .interrupted(let rReason, _)):
				return lReason == rReason
			case (.waitingForMicrophone, .waitingForMicrophone),
				 (.waitingForUserDecision, .waitingForUserDecision),
				 (.error, .error):
				return true
			default:
				return false
			}
		}
	}

	/// Reasons for recording interruption
	enum InterruptionReason: Equatable {
		case phoneCall
		case microphoneDisconnected
		case systemInterruption
		case backgroundTimeExpiring
	}

	// MARK: - Initialization

	override init() {
		// Initialize the managers first
		self.enhancedAudioSessionManager = EnhancedAudioSessionManager()
		self.locationManager = LocationManager()

		super.init()

		// Load location tracking setting from UserDefaults
		self.isLocationTrackingEnabled = UserDefaults.standard.bool(forKey: "isLocationTrackingEnabled")

		setupLocationObservers()

		// Setup notification observers after super.init()
		setupNotificationObservers()

		// Setup CallKit observer for intelligent call interruption handling (Phase 1)
		#if !targetEnvironment(macCatalyst)
		setupCallObserver()
		#endif
	}

	/// Set the app coordinator reference
	func setAppCoordinator(_ coordinator: AppDataCoordinator) {
		self.appCoordinator = coordinator
		Task { @MainActor in
			let workflowManager = RecordingWorkflowManager()
			workflowManager.setAppCoordinator(coordinator)
			self.workflowManager = workflowManager

			// Set up watch sync handler now that we have app coordinator
			#if !targetEnvironment(macCatalyst)
			setupWatchSyncHandler()
			#endif
		}
	}

	/// Initialize the view model asynchronously to ensure proper setup
	func initialize() async {
		// Ensure we're on the main actor for UI updates
		await MainActor.run {
			// Initialize any required components
			setupNotificationObservers()
		}

		// Initialize location manager only if tracking is enabled
		await MainActor.run {
			if isLocationTrackingEnabled {
				locationManager.requestLocationPermission()
			}
		}

		// Don't configure audio session immediately - wait until user starts recording
		// This prevents interference with other audio apps on app launch
		AppLog.shared.recording("AudioRecorderViewModel initialized without configuring audio session")
	}

	deinit {
		// Remove observers synchronously since deinit cannot be async
		if let observer = interruptionObserver {
			NotificationCenter.default.removeObserver(observer)
		}
		if let observer = routeChangeObserver {
			NotificationCenter.default.removeObserver(observer)
		}
		if let observer = willEnterForegroundObserver {
			NotificationCenter.default.removeObserver(observer)
		}
	}

	// MARK: - Notification Observers

	func setupNotificationObservers() {
		#if !targetEnvironment(macCatalyst)
		// AVAudioSession interruption/route notifications use Mach ports that don't
		// exist on Mac — registering for them floods the log with "cannot add handler".
		// Phone-call interruptions and Bluetooth routing don't apply on Mac anyway.
		interruptionObserver = NotificationCenter.default.addObserver(
			forName: AVAudioSession.interruptionNotification,
			object: nil,
			queue: .main
		) { [weak self] notification in
			// Capture ALL userInfo before entering Task - including InterruptionOptionKey
			// which contains .shouldResume (critical for declined call detection)
			var capturedUserInfo: [String: Any] = [:]
			if let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt {
				capturedUserInfo[AVAudioSessionInterruptionTypeKey] = typeValue
			}
			if let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt {
				capturedUserInfo[AVAudioSessionInterruptionOptionKey] = optionsValue
			}

			Task { @MainActor in
				guard let self = self, !capturedUserInfo.isEmpty else { return }
				let newNotification = Notification(name: AVAudioSession.interruptionNotification, object: nil, userInfo: capturedUserInfo)
				self.handleAudioInterruption(newNotification)
			}
		}

		// Route change observer (e.g., Bluetooth mic disconnects)
		routeChangeObserver = NotificationCenter.default.addObserver(
			forName: AVAudioSession.routeChangeNotification,
			object: nil,
			queue: .main
		) { [weak self] notification in
			let userInfo = notification.userInfo
			let routeChangeReason = userInfo?[AVAudioSessionRouteChangeReasonKey] as? AVAudioSession.RouteChangeReason

			Task { @MainActor in
				guard let self = self else { return }
				if let reason = routeChangeReason {
					let newUserInfo: [String: Any] = [AVAudioSessionRouteChangeReasonKey: reason.rawValue]
					let newNotification = Notification(name: AVAudioSession.routeChangeNotification, object: nil, userInfo: newUserInfo)
					self.handleRouteChange(newNotification)
				}
			}
		}
		#endif

		willEnterForegroundObserver = NotificationCenter.default.addObserver(
			forName: UIApplication.willEnterForegroundNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor in
				guard let self = self else { return }
				self.appIsBackgrounding = false // App is coming back to foreground

				EnhancedLogger.shared.logAudioSession("App foregrounded, checking audio session state")

				// If actively recording and the recorder is still running, don't touch the session.
				// Deactivating/reactivating would kill a perfectly good background recording.
				// Stop background monitoring now that we're in the foreground
				self.stopBackgroundTimeMonitoring()

				if self.isRecording, let recorder = self.audioRecorder, recorder.isRecording {
					AppLog.shared.recording("Recorder still active after backgrounding - no session restoration needed")
					self.recorderStoppedUnexpectedlyTime = nil
					self.endBackgroundTask()
					return
				}

				// If we're in a phone call interruption, the Phone app owns the audio session.
				// Don't try to restore — it will fail repeatedly and waste time.
				// The interruption .ended notification will fire when the call ends and handle resume.
				if self.isInInterruption {
					if case .interrupted(.phoneCall, _) = self.recordingState {
						AppLog.shared.recording("Phone call still active - skipping session restoration, will resume when call ends")
					} else {
						AppLog.shared.recording("In interruption - skipping session restoration, will resume when interruption ends")
					}
					return
				}

				// Recorder is NOT active — but if another handler is already resuming, let it finish
				if self.isResuming {
					AppLog.shared.recording("Resume already in progress from another handler, skipping foreground restore", level: .debug)
					self.endBackgroundTask()
					return
				}

				// Restore the session and try to resume
				EnhancedLogger.shared.logAudioSession("Recorder stopped during background, restoring audio session")
				try? await self.enhancedAudioSessionManager.restoreAudioSession()

				if self.isRecording, let recorder = self.audioRecorder {
					if !recorder.isRecording {
						AppLog.shared.recording("Recorder stopped during background, resuming after session restore")
						recorder.record()

						// Verify it actually started
						try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
						if let r = self.audioRecorder, r.isRecording {
							AppLog.shared.recording("Recorder successfully resumed after foreground restore")
							self.recordingState = .recording
						} else {
							AppLog.shared.recording("Recorder.record() didn't start, attempting full resume")
							await self.attemptResumeAfterUnexpectedStop()
						}
						self.recorderStoppedUnexpectedlyTime = nil
					}
				}

				self.endBackgroundTask()
			}
		}

		// Add observer for app backgrounding
		NotificationCenter.default.addObserver(
			forName: UIApplication.didEnterBackgroundNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			guard let self = self else { return }
			self.appIsBackgrounding = true
			// Start a background task as a safety net while recording in the background.
			// UIBackgroundModes:audio keeps the app alive for active audio, but this gives
			// extra time for recovery if the recorder is interrupted (e.g., declined call).
			if self.isRecording {
				self.beginBackgroundTask()
				self.startBackgroundTimeMonitoring()
			}
		}

		// Listen for BackgroundProcessingManager's request to check for unprocessed recordings
		NotificationCenter.default.addObserver(
			forName: NSNotification.Name("CheckForUnprocessedRecordings"),
			object: nil,
			queue: .main
		) { [weak self] _ in
			guard let self = self else { return }
			Task {
				await self.checkForUnprocessedRecording()
			}
		}
	}

	func removeNotificationObservers() {
		if let observer = interruptionObserver {
			NotificationCenter.default.removeObserver(observer)
		}
		if let observer = routeChangeObserver {
			NotificationCenter.default.removeObserver(observer)
		}
		if let observer = willEnterForegroundObserver {
			NotificationCenter.default.removeObserver(observer)
		}
	}

	// MARK: - Call Observer Setup (Phase 1)

	#if !targetEnvironment(macCatalyst)
	/// Setup CallKit observer for intelligent call interruption handling
	func setupCallObserver() {
		callObserver = CXCallObserver()
		callObserver?.setDelegate(self, queue: DispatchQueue.main)
		AppLog.shared.recording("CallKit observer setup complete")
	}
	#endif

	// MARK: - Core Recording

	func startRecording() {
		AppLog.shared.recording("startRecording: requesting microphone permission")
		#if targetEnvironment(macCatalyst)
		Task { @MainActor [weak self] in self?.requestMicPermissionAndRecord() }
		#else
		AVAudioApplication.requestRecordPermission { [weak self] granted in
			DispatchQueue.main.async {
				guard let self = self else { return }
				if granted {
					AppLog.shared.recording("startRecording: microphone permission granted")
					Task {
						do {
							try await self.enhancedAudioSessionManager.configureBackgroundRecording()
							AppLog.shared.recording("Background recording session configured")
							await self.applySelectedInputToSession()
						} catch {
							AppLog.shared.recording("Failed to configure audio session: \(error)", level: .error)
							await MainActor.run {
								self.errorMessage = "Failed to set up audio: \(error.localizedDescription)"
							}
							return
						}
						await MainActor.run {
							self.setupRecording()
						}
					}
				} else {
					AppLog.shared.recording("startRecording: microphone permission denied", level: .error)
					self.errorMessage = "Microphone permission denied"
				}
			}
		}
		#endif
	}

	#if targetEnvironment(macCatalyst)
	@MainActor
	private func requestMicPermissionAndRecord() {
		let status = AVCaptureDevice.authorizationStatus(for: .audio)
		AppLog.shared.recording("Mac mic auth status: \(status.rawValue)")
		switch status {
		case .authorized:
			didReceiveMicrophonePermission(granted: true)
		case .notDetermined:
			AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
				Task { @MainActor [weak self] in
					AppLog.shared.recording("Mac mic permission result: \(granted)")
					self?.didReceiveMicrophonePermission(granted: granted)
				}
			}
		case .denied, .restricted:
			AppLog.shared.recording("Mac mic permission denied/restricted", level: .error)
			errorMessage = "Microphone access is denied. Open System Settings → Privacy & Security → Microphone and enable BisonNotes AI, then try again."
		@unknown default:
			didReceiveMicrophonePermission(granted: false)
		}
	}

	@MainActor
	private func didReceiveMicrophonePermission(granted: Bool) {
		guard granted else {
			errorMessage = "Microphone permission denied"
			return
		}
		AppLog.shared.recording("startRecording: microphone permission granted")
		Task {
			do {
				try await enhancedAudioSessionManager.configureMixedAudioSession()
				AppLog.shared.recording("Mac: mixed audio session configured")
				await applySelectedInputToSession()
			} catch {
				AppLog.shared.recording("Failed to configure audio session: \(error)", level: .error)
				errorMessage = "Failed to set up audio: \(error.localizedDescription)"
				return
			}
			setupRecording()
		}
	}
	#endif

	func startBackgroundRecording() {
		AppLog.shared.recording("startBackgroundRecording: requesting microphone permission")
		#if targetEnvironment(macCatalyst)
		Task { @MainActor [weak self] in self?.requestMicPermissionAndRecord() }
		#else
		AVAudioApplication.requestRecordPermission { [weak self] granted in
			DispatchQueue.main.async {
				guard let self = self else { return }
				if granted {
					AppLog.shared.recording("startBackgroundRecording: microphone permission granted")
					Task {
						do {
							try await self.enhancedAudioSessionManager.configureBackgroundRecording()
							await self.applySelectedInputToSession()
						} catch {
							AppLog.shared.recording("Failed to configure audio session: \(error)", level: .error)
							return
						}
						await MainActor.run {
							self.setupRecording()
						}
					}
				} else {
					AppLog.shared.recording("startBackgroundRecording: microphone permission denied", level: .error)
					self.errorMessage = "Microphone permission denied"
				}
			}
		}
		#endif
	}

	func setupRecording() {
		let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
		let audioFilename = documentsPath.appendingPathComponent(generateAppRecordingFilename())
		let recordingStartDate = Date()
		recordingURL = audioFilename
		recordingStartedAt = (url: audioFilename, date: recordingStartDate)
		persistRecordingCapturedAt(recordingStartDate, for: audioFilename)

		// Initialize segment tracking for this new recording
		mainRecordingURL = audioFilename
		recordingSegments = [audioFilename] // Start with the first segment
		currentSegmentIndex = 0
		AppLog.shared.recording("Starting new recording with segment tracking")

		// Capture current location before starting recording
		captureCurrentLocation()

		// Check if live transcription mode is enabled
		let useLiveTranscription = UserDefaults.standard.bool(forKey: "enableLiveTranscription")

		if useLiveTranscription {
			setupLiveTranscriptionRecording(url: audioFilename)
			return
		}

		// Use Whisper-optimized quality for all recordings
		let selectedQuality = AudioQuality.whisperOptimized
		let settings = selectedQuality.settings

		do {
			audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
			audioRecorder?.delegate = self

			// Enable metering for silence detection (used for smart checkpoints)
			audioRecorder?.isMeteringEnabled = true

			#if targetEnvironment(simulator)
			AppLog.shared.recording("Running on iOS Simulator - audio recording may have limitations", level: .debug)
			#endif

			// No background task needed here - audio background mode keeps recording alive
			audioRecorder?.record()

			isRecording = true
			recordingTime = 0
			lastCheckpointTime = Date() // Initialize checkpoint time to now

			// Phase 3: Reset warning flags for new recording session
			hasShownDurationWarning = false
			hasShownStorageWarning = false
			hasShownBatteryWarning = false

			// Phase 4: Background task is started when the app enters background
			// (see didEnterBackgroundNotification observer), not at recording start.
			// Starting it here would trigger iOS warnings about long-lived background tasks.

			startRecordingTimer()

			// Notify watch of recording state change
			notifyWatchOfRecordingStateChange()

		} catch {
			#if targetEnvironment(simulator)
			errorMessage = "Recording failed on simulator. Enable Device → Microphone → Internal Microphone in simulator menu, or test on a physical device."
			AppLog.shared.recording("Simulator audio error: \(error.localizedDescription)", level: .error)
			#else
			errorMessage = "Failed to start recording: \(error.localizedDescription)"
			#endif
		}
	}

	func stopRecording() {
		// Handle live transcription path
		if isUsingLiveTranscription, let service = liveTranscriptionService {
			isUsingLiveTranscription = false
			liveTranscriptionService = nil
			isRecording = false
			stopRecordingTimer()
			liveTranscriptText = ""

			Task {
				let (url, transcript) = await service.stop()
				if let savedURL = url {
					await MainActor.run { self.recordingURL = savedURL }
					await saveLiveTranscriptionRecording(url: savedURL, transcript: transcript)
				}
				try? await enhancedAudioSessionManager.deactivateSession()
			}

			stopBackgroundTimeMonitoring()
			endBackgroundTask()
			notifyWatchOfRecordingStateChange()
			return
		}

		audioRecorder?.stop()
		isRecording = false
		stopRecordingTimer()
		audioRecorder = nil

		// Clear interruption state
		isInInterruption = false
		interruptionRecordingURL = nil
		recorderStoppedUnexpectedlyTime = nil

		// Reset processing flag when manually stopping
		recordingBeingProcessed = false

		// Reset checkpoint tracking
		lastCheckpointTime = Date.distantPast

		// Merge segments if there were interruptions
		if recordingSegments.count > 1 {
			AppLog.shared.recording("Recording has \(recordingSegments.count) segments, merging")
			Task {
				await mergeRecordingSegments()
			}
		} else {
			AppLog.shared.recording("Recording has single segment, no merge needed", level: .debug)
		}

		// Deactivate audio session to restore high-quality music playback
		Task {
			try? await enhancedAudioSessionManager.deactivateSession()
		}

		// Phase 4: Stop background monitoring and task
		stopBackgroundTimeMonitoring()
		endBackgroundTask()

		// Notify watch of recording state change
		notifyWatchOfRecordingStateChange()
	}

	/// Saves a recording and optional transcript created via live transcription mode.
	@MainActor
	private func saveLiveTranscriptionRecording(url: URL, transcript: String) async {
		saveLocationData(for: url)

		guard let workflowManager = workflowManager else {
			AppLog.shared.recording("WorkflowManager not set - live transcription recording not saved", level: .error)
			return
		}

		let fileSize = getFileSize(url: url)
		let duration = getRecordingDuration(url: url)
		let quality = AudioRecorderViewModel.getCurrentAudioQuality()
		let displayName = generateAppRecordingDisplayName()

		let recordingId = workflowManager.createRecording(
			url: url,
			name: displayName,
			date: currentRecordingDate(for: url),
			fileSize: fileSize,
			duration: duration,
			quality: quality,
			locationData: recordingLocationSnapshot()
		)

		AppLog.shared.recording("Live transcription recording saved, ID: \(recordingId)")

		// Save the live transcript if we have content
		if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
		   let coordinator = appCoordinator {
			let segment = TranscriptSegment(
				speaker: "Speaker 1",
				text: transcript,
				startTime: 0,
				endTime: duration
			)
			_ = coordinator.addTranscript(
				for: recordingId,
				segments: [segment],
				speakerMappings: [:],
				engine: .fluidAudio,
				processingTime: duration,
				confidence: 0.9
			)
			AppLog.shared.recording("Live transcript saved for recording \(recordingId)")
		}

		resetRecordingLocation()
		recordingStartedAt = nil
		endBackgroundTask()
	}

	// MARK: - Live Transcription Recording

	func setupLiveTranscriptionRecording(url: URL) {
		Task { @MainActor in
			let service = LiveTranscriptionService()
			self.liveTranscriptionService = service
			self.isUsingLiveTranscription = true

			do {
				try service.start(finalURL: url)
				self.isRecording = true
				self.recordingTime = 0
				self.lastCheckpointTime = Date()
				self.startRecordingTimer()
				self.notifyWatchOfRecordingStateChange()
				AppLog.shared.recording("Live transcription recording started")
			} catch {
				self.isUsingLiveTranscription = false
				self.liveTranscriptionService = nil
				self.errorMessage = "Live transcription unavailable: \(error.localizedDescription). Starting standard recording."
				// Fall back to standard recording
				let selectedQuality = AudioQuality.whisperOptimized
				let settings = selectedQuality.settings
				do {
					self.audioRecorder = try AVAudioRecorder(url: url, settings: settings)
					self.audioRecorder?.delegate = self
					self.audioRecorder?.isMeteringEnabled = true
					self.audioRecorder?.record()
					self.isRecording = true
					self.recordingTime = 0
					self.lastCheckpointTime = Date()
					self.startRecordingTimer()
					self.notifyWatchOfRecordingStateChange()
				} catch {
					self.errorMessage = "Failed to start recording: \(error.localizedDescription)"
				}
			}
		}
	}

	// MARK: - Timer Management

	func startRecordingTimer() {
		recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
			DispatchQueue.main.async {
				guard let self = self else { return }
				// Failsafe: if the underlying AVAudioRecorder stopped, try to resume before giving up.
				// This also runs during backgrounding — a declined call can stop the recorder
				// while the app is in the background, and we need to detect that.
				// NOTE: In live transcription mode, audioRecorder is nil so this block is
				// safely skipped — LiveTranscriptionService manages its own AVAudioEngine.
				if self.isRecording, let recorder = self.audioRecorder, !recorder.isRecording {
					if self.isInInterruption {
						// We're in an interruption - wait for it to end rather than trying to resume now
						if self.recorderStoppedUnexpectedlyTime != nil {
							self.recorderStoppedUnexpectedlyTime = nil
						}
					} else {
						// Not in interruption - track when we first detected the recorder stopped
						if self.recorderStoppedUnexpectedlyTime == nil {
							self.recorderStoppedUnexpectedlyTime = Date()
							AppLog.shared.recording("Detected recorder stopped - waiting for interruption notification (grace period: 5s)", level: .debug)
						} else if let stoppedTime = self.recorderStoppedUnexpectedlyTime, Date().timeIntervalSince(stoppedTime) >= 5.0 {
							AppLog.shared.recording("No interruption notification received after 5s - attempting to resume recording")
							self.recorderStoppedUnexpectedlyTime = nil
							Task { @MainActor in
								await self.attemptResumeAfterUnexpectedStop()
							}
							return
						}
					}
				} else {
					// Recorder is running or we're in a safe state, clear the stopped tracking
					if self.recorderStoppedUnexpectedlyTime != nil {
						self.recorderStoppedUnexpectedlyTime = nil
					}

					// Perform smart checkpoint that waits for silence
					self.performSmartCheckpoint()
				}
				self.recordingTime += 1

				// Sync live transcript text when live transcription is active
				if self.isUsingLiveTranscription, let service = self.liveTranscriptionService {
					self.liveTranscriptText = service.liveTranscript
				}

				// Phase 3: Check recording limits every 10 seconds (reduces overhead)
				if Int(self.recordingTime) % 10 == 0 {
					Task { @MainActor in
						await self.checkRecordingLimitsAndWarnings()
					}
				}
			}
		}
	}

	func stopRecordingTimer() {
		recordingTimer?.invalidate()
		recordingTimer = nil
	}

	func startPlayingTimer() {
		stopPlayingTimer() // Ensure no duplicate timers

		playingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
			DispatchQueue.main.async {
				guard let self = self, let player = self.audioPlayer, self.isPlaying else {
					return
				}
				let newTime = player.currentTime
				if newTime != self.playingTime {
					self.playingTime = newTime
				}
			}
		}
	}

	func stopPlayingTimer() {
		playingTimer?.invalidate()
		playingTimer = nil
	}

	// MARK: - Utilities

	func formatTime(_ timeInterval: TimeInterval) -> String {
		let minutes = Int(timeInterval) / 60
		let seconds = Int(timeInterval) % 60
		return String(format: "%02d:%02d", minutes, seconds)
	}

	// MARK: - Audio Quality Helper

	static func getCurrentAudioQuality() -> AudioQuality {
		// Always use Whisper-optimized quality for voice transcription
		return .whisperOptimized
	}

	static func getCurrentAudioSettings() -> [String: Any] {
		return getCurrentAudioQuality().settings
	}
}
