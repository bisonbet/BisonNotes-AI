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

class AudioRecorderViewModel: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var recordingTime: TimeInterval = 0
    @Published var playingTime: TimeInterval = 0
    @Published var availableInputs: [AVAudioSessionPortDescription] = []
    @Published var selectedInput: AVAudioSessionPortDescription?
    @Published var recordingURL: URL?
    @Published var errorMessage: String?
    @Published var enhancedAudioSessionManager: EnhancedAudioSessionManager
    @Published var locationManager: LocationManager
    @Published var currentLocationData: LocationData?
    
    private var recordingStartLocationData: LocationData?
    @Published var isLocationTrackingEnabled: Bool = false
    
    // Reference to the app coordinator for adding recordings to registry
    private var appCoordinator: AppDataCoordinator?
    private var workflowManager: RecordingWorkflowManager?
    private var cancellables = Set<AnyCancellable>()

    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var recordingTimer: Timer?
    private var playingTimer: Timer?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var willEnterForegroundObserver: NSObjectProtocol?
    private let preferredInputDefaultsKey = "PreferredAudioInputUID"
    
    // Flag to prevent duplicate recording creation
    private var recordingBeingProcessed = false

    // Flag to track if app is backgrounding (to avoid false positive interruptions)
    private var appIsBackgrounding = false

    // Flag to track if we're currently in an interruption (e.g., incoming phone call)
    private var isInInterruption = false

    // Store the recording URL when interruption begins, in case we need to recover
    private var interruptionRecordingURL: URL?

    // Track when recorder stopped unexpectedly (to give interruption notifications time to arrive)
    private var recorderStoppedUnexpectedlyTime: Date?

    // Timestamp to track when last recovery was attempted (to prevent rapid duplicates)
    private var lastRecoveryAttempt: Date = Date.distantPast

    // Background task identifier for recording continuity
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    // Track last checkpoint time for periodic data flushing
    private var lastCheckpointTime: Date = Date.distantPast
    private let checkpointInterval: TimeInterval = 30.0 // Try to checkpoint every 30 seconds
    private let forceCheckpointInterval: TimeInterval = 90.0 // Force checkpoint after 90 seconds even without silence

    // Audio level monitoring for silence detection
    private let silenceThreshold: Float = -40.0 // dB threshold for silence (typical voice is -20 to -10 dB)

    // Recording segment management for handling interruptions
    private var recordingSegments: [URL] = [] // Track all segments of the current recording
    private var mainRecordingURL: URL? // The final merged recording URL
    private var currentSegmentIndex: Int = 0 // Track which segment we're on

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
    }
    
    /// Set the app coordinator reference
    func setAppCoordinator(_ coordinator: AppDataCoordinator) {
        self.appCoordinator = coordinator
        Task { @MainActor in
            let workflowManager = RecordingWorkflowManager()
            workflowManager.setAppCoordinator(coordinator)
            self.workflowManager = workflowManager
            
            // Set up watch sync handler now that we have app coordinator
            setupWatchSyncHandler()
        }
    }
    
    /// Set up watch sync recording handler
    @MainActor
    private func setupWatchSyncHandler() {
        let watchManager = WatchConnectivityManager.shared
        print("🔄 Setting up watch sync handler in AudioRecorderViewModel")
        
        watchManager.onWatchSyncRecordingReceived = { [weak self] audioData, syncRequest in
            print("📱 AudioRecorderViewModel received watch sync callback for: \(syncRequest.recordingId)")
            Task { @MainActor in
                self?.handleWatchSyncRecordingReceived(audioData, syncRequest: syncRequest)
            }
        }
        
        // Also set up the completion callback here since BisonNotesAIApp setup might not be working
        print("🔄 Also setting up onWatchRecordingSyncCompleted callback in AudioRecorderViewModel")
        watchManager.onWatchRecordingSyncCompleted = { recordingId, success in
            print("📱 onWatchRecordingSyncCompleted called for: \(recordingId), success: \(success)")
            
            if success {
                let coreDataId = "core_data_\(recordingId.uuidString)"
                print("📱 About to call confirmSyncComplete with success=true")
                watchManager.confirmSyncComplete(recordingId: recordingId, success: true, coreDataId: coreDataId)
                print("✅ Confirmed reliable watch transfer in Core Data: \(recordingId)")
            } else {
                print("📱 About to call confirmSyncComplete with success=false")
                watchManager.confirmSyncComplete(recordingId: recordingId, success: false)
                print("❌ Failed to confirm watch transfer: \(recordingId)")
            }
        }
        
        print("✅ AudioRecorderViewModel connected to WatchConnectivityManager sync handler")
        
        // Verify the callbacks were set
        if watchManager.onWatchSyncRecordingReceived != nil {
            print("✅ Callback verification: onWatchSyncRecordingReceived is set")
        } else {
            print("❌ Callback verification: onWatchSyncRecordingReceived is nil!")
        }
        
        if watchManager.onWatchRecordingSyncCompleted != nil {
            print("✅ Callback verification: onWatchRecordingSyncCompleted is set")
        } else {
            print("❌ Callback verification: onWatchRecordingSyncCompleted is nil!")
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
        print("✅ AudioRecorderViewModel initialized without configuring audio session")
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
    
    private func setupNotificationObservers() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Capture the notification data we need before entering Task
            let userInfo = notification.userInfo
            let interruptionType = userInfo?[AVAudioSessionInterruptionTypeKey] as? AVAudioSession.InterruptionType
            
            Task { @MainActor in
                guard let self = self else { return }
                // Create a new notification with only the data we need
                if let type = interruptionType {
                    let newUserInfo: [String: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
                    let newNotification = Notification(name: AVAudioSession.interruptionNotification, object: nil, userInfo: newUserInfo)
                    self.handleAudioInterruption(newNotification)
                }
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
        
        willEnterForegroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.appIsBackgrounding = false // App is coming back to foreground

                EnhancedLogger.shared.logAudioSession("App foregrounded, restoring audio session")

                // Restore audio session first
                // This will deactivate/reactivate the session, which stops the recorder
                try? await self.enhancedAudioSessionManager.restoreAudioSession()

                // CRITICAL: If recording was active, resume the recorder
                // The session restoration always stops the recorder, so we must restart it
                if self.isRecording, let recorder = self.audioRecorder {
                    if !recorder.isRecording {
                        print("🔄 Recorder stopped by session restoration, resuming immediately")
                        recorder.record()
                        // Clear any stale unexpected-stop tracking
                        self.recorderStoppedUnexpectedlyTime = nil
                    } else {
                        print("✅ Recorder still recording after session restoration")
                    }
                }
            }
        }
        
        // Add observer for app backgrounding
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.appIsBackgrounding = true
            // Don't send notification here - backgrounding is normal and recording continues
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
    
	private func removeNotificationObservers() {
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
    
    
    // MARK: - Watch Event Handlers
    
    // Legacy coordinated recording handlers removed - watch operates independently
    
    // Legacy audio streaming handler removed - now using file transfer on completion
    
    /// Handle synchronized recording received from watch
    private func handleWatchSyncRecordingReceived(_ audioData: Data, syncRequest: WatchSyncRequest) {
        print("⌚ Received synchronized recording from watch: \(syncRequest.filename)")
        
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
                
                print("✅ Created Core Data entry for watch recording: \(recordingId)")
                
                // Notify UI to refresh recordings list
                NotificationCenter.default.post(name: NSNotification.Name("RecordingAdded"), object: nil)
                
                // Recording sync completed successfully - notify the completion callback
                await MainActor.run {
                    let watchManager = WatchConnectivityManager.shared
                    print("🔍 About to call onWatchRecordingSyncCompleted - callback is nil: \(watchManager.onWatchRecordingSyncCompleted == nil)")
                    watchManager.onWatchRecordingSyncCompleted?(syncRequest.recordingId, true)
                    print("✅ Called completion callback for successful watch recording: \(syncRequest.recordingId)")
                }
                
            } catch {
                print("❌ Failed to create Core Data entry for watch recording: \(error)")
                
                // Recording sync failed - notify the completion callback
                await MainActor.run {
                    let watchManager = WatchConnectivityManager.shared
                    watchManager.onWatchRecordingSyncCompleted?(syncRequest.recordingId, false)
                    print("❌ Called completion callback for failed watch recording: \(syncRequest.recordingId)")
                }
            }
        }
    }
    
    private func createPlayableAudioFile(from pcmData: Data, sessionId: UUID) async throws -> URL {
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
    
    private func handleWatchError(_ error: WatchErrorMessage) {
        print("⌚ Watch error received: \(error.message)")
        
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
    
    // MARK: - Watch Communication Helpers
    
    private func notifyWatchOfRecordingStateChange() {
        // Watch communication removed - this is now a no-op
    }
    
	private func handleAudioInterruption(_ notification: Notification) {
		// Forward to session manager for logging and restoration
		enhancedAudioSessionManager.handleAudioInterruption(notification)
		
		// Also ensure our recording UI/state reflects actual recorder state
		guard let userInfo = notification.userInfo,
				let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
				let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
			return
		}
		
		switch type {
		case .began:
			if isRecording && !isInInterruption {
				print("🎙️ Audio interruption began (e.g., incoming call) - pausing timer, waiting to see if user answers")
				isInInterruption = true
				interruptionRecordingURL = recordingURL
				// Clear the recorder stopped tracking since we now know it's an interruption
				recorderStoppedUnexpectedlyTime = nil
				// Pause the timer but don't stop recording yet
				// The recorder may continue in the background, or iOS may pause it
				// We'll check the state when interruption ends
				stopRecordingTimer() // Pause timer during interruption
			}
		case .ended:
			// Check if we should resume recording after interruption ends
			// We check interruptionRecordingURL to know if we were recording before the interruption
			// This handles cases where recording was stopped during the interruption or took a long time
			guard isInInterruption, interruptionRecordingURL != nil else {
				// Not in an interruption state, or no recording URL to resume
				print("⚠️ Interruption ended but we weren't in an interruption state or have no recording URL")
				return
			}
			
			isInInterruption = false
			
			if let options = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
				let interruptionOptions = AVAudioSession.InterruptionOptions(rawValue: options)
				
				if interruptionOptions.contains(.shouldResume) {
					// User declined/ignored the call - definitely resume recording
					print("🔄 Interruption ended with shouldResume - user declined/ignored call, resuming recording")
					let urlToResume = interruptionRecordingURL // Capture before clearing
					interruptionRecordingURL = nil
					Task { @MainActor in
						await resumeRecordingAfterInterruption(url: urlToResume)
					}
				} else {
					// No .shouldResume flag - this could mean:
					// 1. Call was answered (should stop)
					// 2. Call was declined but iOS didn't set the flag (should resume)
					// 3. Call was answered then hung up (should resume)
					
					// Try to resume anyway - if it fails, we'll handle it
					print("🔄 Interruption ended without shouldResume - attempting to resume (may have been declined or hung up)")
					let urlToResume = interruptionRecordingURL // Capture before clearing
					interruptionRecordingURL = nil
					Task { @MainActor in
						await resumeRecordingAfterInterruption(url: urlToResume)
						// If resume fails, it will call handleInterruptedRecording internally
					}
				}
			} else {
				// No options provided - try to resume anyway (might be a declined call)
				// iOS sometimes doesn't set .shouldResume for declined calls, but we should try
				print("🔄 Interruption ended without options - attempting to resume (may have been declined call)")
				let urlToResume = interruptionRecordingURL // Capture before clearing
				interruptionRecordingURL = nil
				Task { @MainActor in
					await resumeRecordingAfterInterruption(url: urlToResume)
				}
			}
		@unknown default:
			break
		}
	}
	
	/// Attempt to resume recording after an unexpected stop (e.g., declined call without interruption notification)
	@MainActor
	private func attemptResumeAfterUnexpectedStop() async {
		print("🔄 Attempting to resume recording after unexpected stop (likely declined call)")

		// Use current recording URL
		guard let url = recordingURL else {
			print("❌ No recording URL available to resume")
			errorMessage = "Could not resume recording: no recording file found"
			isRecording = false
			return
		}

		// Check if the file still exists
		guard FileManager.default.fileExists(atPath: url.path) else {
			print("❌ Recording file no longer exists")
			errorMessage = "Could not resume recording: file was removed"
			isRecording = false
			return
		}

		// Get the current file size to preserve what was already recorded
		let fileSizeBeforeResume = getFileSize(url: url)
		print("📊 Current segment file size: \(fileSizeBeforeResume) bytes")

		// Step 1: Finalize the current segment (the recorder has already stopped)
		// Stop the recorder properly if it's still somehow active
		audioRecorder?.stop()
		audioRecorder = nil

		// Add this segment to our list if it's not already there
		if !recordingSegments.contains(url) {
			recordingSegments.append(url)
			print("✅ Saved segment \(recordingSegments.count): \(url.lastPathComponent)")
		}

		// Add a small delay to give iOS time to fully release the audio session after the call
		do {
			try await Task.sleep(nanoseconds: 500_000_000) // 0.5 second delay
		} catch {
			// Sleep was cancelled, but continue anyway
		}

		// Step 2: Create a new segment file for continuation
		currentSegmentIndex += 1
		let newSegmentURL = createSegmentURL(baseURL: mainRecordingURL ?? url, segmentIndex: currentSegmentIndex)
		print("📝 Creating new segment \(currentSegmentIndex + 1): \(newSegmentURL.lastPathComponent)")

		// Try to restore audio session and start recording to new segment
		do {
			try await enhancedAudioSessionManager.restoreAudioSession()

			// Create a new recorder for the new segment
			let selectedQuality = AudioQuality.whisperOptimized
			let settings = selectedQuality.settings

			audioRecorder = try AVAudioRecorder(url: newSegmentURL, settings: settings)
			audioRecorder?.delegate = self
			audioRecorder?.isMeteringEnabled = true // Enable metering for silence detection

			// Start recording
			audioRecorder?.record()

			// Verify it's actually recording
			if let recorder = audioRecorder, recorder.isRecording {
				print("✅ Recording resumed with new segment - previous audio preserved!")
				recordingSegments.append(newSegmentURL)
				recordingURL = newSegmentURL // Update to the new segment
				isRecording = true
				lastCheckpointTime = Date() // Reset checkpoint time on resume
				startRecordingTimer()
				errorMessage = nil
				recorderStoppedUnexpectedlyTime = nil
			} else {
				print("❌ Failed to resume recording - recorder not active, treating as real interruption")
				handleInterruptedRecording(reason: "Microphone became unavailable or recording was interrupted")
			}
		} catch {
			print("❌ Failed to resume recording: \(error.localizedDescription), treating as real interruption")
			handleInterruptedRecording(reason: "Microphone became unavailable: \(error.localizedDescription)")
		}
	}
	
	@MainActor
	private func resumeRecordingAfterInterruption(url: URL?) async {
		print("🔄 Attempting to resume recording after interruption")

		// Check if the recorder is still valid and recording
		// This is the best case - iOS didn't stop the recorder, just paused the session
		if let recorder = audioRecorder, recorder.isRecording {
			print("✅ Recorder is still active, resuming timer")
			// Recorder is still active, just resume the timer
			startRecordingTimer()
			errorMessage = nil
			isInInterruption = false
			return
		}

		// Recorder was stopped by iOS, need to restart it
		guard let url = url else {
			print("❌ No recording URL available to resume")
			errorMessage = "Could not resume recording: no recording file found"
			isRecording = false
			isInInterruption = false
			return
		}

		// Check if the file still exists
		guard FileManager.default.fileExists(atPath: url.path) else {
			print("❌ Recording file no longer exists")
			errorMessage = "Could not resume recording: file was removed"
			isRecording = false
			isInInterruption = false
			return
		}

		// Get the current file size before attempting to resume
		let fileSizeBeforeResume = getFileSize(url: url)
		print("📊 Current segment file size: \(fileSizeBeforeResume) bytes")

		// Step 1: Finalize the current segment (the recorder has already stopped)
		// Stop the recorder properly if it's still somehow active
		audioRecorder?.stop()
		audioRecorder = nil

		// Add this segment to our list if it's not already there
		if !recordingSegments.contains(url) {
			recordingSegments.append(url)
			print("✅ Saved segment \(recordingSegments.count): \(url.lastPathComponent)")
		}

		// Add a small delay to give iOS time to fully release the audio session after the interruption
		do {
			try await Task.sleep(nanoseconds: 500_000_000) // 0.5 second delay
		} catch {
			// Sleep was cancelled, but continue anyway
		}

		// Step 2: Create a new segment file for continuation
		currentSegmentIndex += 1
		let newSegmentURL = createSegmentURL(baseURL: mainRecordingURL ?? url, segmentIndex: currentSegmentIndex)
		print("📝 Creating new segment \(currentSegmentIndex + 1): \(newSegmentURL.lastPathComponent)")

		// Try to restore audio session and start recording to new segment
		do {
			try await enhancedAudioSessionManager.restoreAudioSession()

			// Create a new recorder for the new segment
			let selectedQuality = AudioQuality.whisperOptimized
			let settings = selectedQuality.settings

			audioRecorder = try AVAudioRecorder(url: newSegmentURL, settings: settings)
			audioRecorder?.delegate = self
			audioRecorder?.isMeteringEnabled = true // Enable metering for silence detection

			// Start recording
			audioRecorder?.record()

			// Verify it's actually recording
			if let recorder = audioRecorder, recorder.isRecording {
				print("✅ Recording resumed with new segment - previous audio preserved!")
				recordingSegments.append(newSegmentURL)
				recordingURL = newSegmentURL // Update to the new segment
				isRecording = true
				lastCheckpointTime = Date() // Reset checkpoint time on resume
				startRecordingTimer()
				errorMessage = nil
				isInInterruption = false
			} else {
				print("❌ Failed to resume recording - recorder not active")
				errorMessage = "Could not resume recording: recorder failed to start"
				isRecording = false
				audioRecorder = nil
				isInInterruption = false
			}
		} catch {
			print("❌ Failed to resume recording: \(error.localizedDescription)")
			errorMessage = "Could not resume recording: \(error.localizedDescription)"
			isRecording = false
			audioRecorder = nil
			isInInterruption = false
		}
	}

	private func handleRouteChange(_ notification: Notification) {
		guard let userInfo = notification.userInfo,
				let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
				let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
			return
		}
		
		switch reason {
		case .oldDeviceUnavailable:
			// Input device became unavailable (e.g., Bluetooth mic disconnected)
			if isRecording {
				print("🎙️ Audio route changed - microphone unavailable, switching to default microphone")
				Task { @MainActor in
					await handleMicrophoneUnavailableDuringRecording()
				}
			} else {
				// Not recording, just update the selected input
				Task { @MainActor in
					await applySelectedInputToSession()
				}
			}
		case .categoryChange:
			// Category changed, check if we need to recover
			if isRecording {
				print("🎙️ Audio route changed - category change detected during recording")
				Task { @MainActor in
					await handleMicrophoneUnavailableDuringRecording()
				}
			}
		default:
			break
		}
	}
	
	@MainActor
	private func handleMicrophoneUnavailableDuringRecording() async {
		guard isRecording, let currentURL = recordingURL else { return }
		
		// Check if the preferred input is still available
		let availableInputs = enhancedAudioSessionManager.getAvailableInputs()
		let preferredInputUID = UserDefaults.standard.string(forKey: preferredInputDefaultsKey)
		
		var preferredInputStillAvailable = false
		if let storedUID = preferredInputUID {
			preferredInputStillAvailable = availableInputs.contains(where: { $0.uid == storedUID })
		}
		
		if !preferredInputStillAvailable {
			print("⚠️ Preferred microphone is no longer available, switching to iOS default")
			
			// Switch to default microphone
			do {
				try await enhancedAudioSessionManager.clearPreferredInput()
				UserDefaults.standard.removeObject(forKey: preferredInputDefaultsKey)
				selectedInput = nil
				
				// Check if recording is still active
				if let recorder = audioRecorder, recorder.isRecording {
					// Recording is still active, it should automatically use the default mic
					print("✅ Recording continues with default microphone")
					errorMessage = "Microphone switched to default (previous device disconnected)"
				} else {
					// Recording stopped, need to restart
					print("⚠️ Recording stopped, restarting with default microphone")
					await restartRecordingWithDefaultMicrophone(currentURL: currentURL)
				}
			} catch {
				print("❌ Failed to switch to default microphone: \(error.localizedDescription)")
				// Try to continue anyway - iOS might have already switched
				if let recorder = audioRecorder, !recorder.isRecording {
					await restartRecordingWithDefaultMicrophone(currentURL: currentURL)
				}
			}
		}
	}
	
	@MainActor
	private func restartRecordingWithDefaultMicrophone(currentURL: URL) async {
		// Stop current recording
		audioRecorder?.stop()
		stopRecordingTimer()
		
		// Save the current recording segment
		if FileManager.default.fileExists(atPath: currentURL.path) {
			let fileSize = getFileSize(url: currentURL)
			if fileSize > 1024 { // At least 1KB
				print("💾 Saving current recording segment before switching microphones")
				saveLocationData(for: currentURL)
				
				// Process the current segment
				if let workflowManager = workflowManager {
					let quality = AudioRecorderViewModel.getCurrentAudioQuality()
					let originalFilename = currentURL.deletingPathExtension().lastPathComponent
					let duration = getRecordingDuration(url: currentURL)
					
					// Get file creation date, or use current date as fallback
					let recordingDate: Date
					do {
						let attributes = try FileManager.default.attributesOfItem(atPath: currentURL.path)
						if let creationDate = attributes[.creationDate] as? Date {
							recordingDate = creationDate
						} else {
							recordingDate = Date()
						}
					} catch {
						recordingDate = Date()
					}
					
					_ = workflowManager.createRecording(
						url: currentURL,
						name: originalFilename,
						date: recordingDate,
						fileSize: fileSize,
						duration: duration,
						quality: quality,
						locationData: recordingStartLocationData
					)
				}
			}
		}
		
		// Clear the recording URL so we can start fresh
		recordingURL = nil
		recordingTime = 0
		
		// Switch to default microphone
		do {
			try await enhancedAudioSessionManager.clearPreferredInput()
			UserDefaults.standard.removeObject(forKey: preferredInputDefaultsKey)
			selectedInput = nil
			
			// Ensure audio session is still configured
			try await enhancedAudioSessionManager.configureMixedAudioSession()
			
			// Start new recording with default microphone
			print("🎙️ Restarting recording with default microphone")
			setupRecording()
			
			// Update error message to inform user
			errorMessage = "Recording continued with default microphone (previous device disconnected)"
		} catch {
			print("❌ Failed to restart recording: \(error.localizedDescription)")
			errorMessage = "Recording stopped: Failed to switch to default microphone"
			isRecording = false
			audioRecorder = nil
		}
	}
	
	@MainActor
	private func handleInterruptedRecording(reason: String) {
		print("🚨 Handling interrupted recording: \(reason)")

		// Prevent duplicate processing
		guard !recordingBeingProcessed else {
			print("⚠️ Recording already being processed, skipping duplicate interruption handling")
			return
		}
		recordingBeingProcessed = true
		
		// Clear interruption state
		isInInterruption = false
		interruptionRecordingURL = nil
		recorderStoppedUnexpectedlyTime = nil
		
		// Stop the recorder and timer immediately
		audioRecorder?.stop()
		isRecording = false
		stopRecordingTimer()
		
		// Send immediate notification about the interruption (this is a real mic takeover)
		if let recordingURL = recordingURL {
			Task {
				await sendInterruptionNotificationImmediately(reason: reason, recordingURL: recordingURL)
				await recoverInterruptedRecording(url: recordingURL, reason: reason)
			}
		}
		
		// Update error message to inform user
		errorMessage = "Recording stopped: \(reason). The recording has been saved."
		
		// Deactivate audio session to restore high-quality music playback
		Task {
			try? await enhancedAudioSessionManager.deactivateSession()
		}

		// Clean up recorder
		audioRecorder = nil

		// Background task will be managed by recoverInterruptedRecording
	}
	
	private func recoverInterruptedRecording(url: URL, reason: String) async {
		print("💾 Attempting to recover interrupted recording at: \(url.path)")

		// Start background task to protect file recovery and Core Data save operations
		await MainActor.run {
			beginBackgroundTask()
		}

		// Check if the file exists and has meaningful content
		guard FileManager.default.fileExists(atPath: url.path) else {
			print("❌ No recording file found for recovery")
			await sendInterruptionNotification(success: false, reason: reason, filename: url.lastPathComponent)
			await MainActor.run {
				endBackgroundTask()
			}
			return
		}
		
		let fileSize = getFileSize(url: url)
		guard fileSize > 1024 else { // Must be at least 1KB to be meaningful
			print("❌ Recording file too small to recover (\(fileSize) bytes)")
			// Clean up the tiny file
			try? FileManager.default.removeItem(at: url)
			await sendInterruptionNotification(success: false, reason: reason, filename: url.lastPathComponent)
			await MainActor.run {
				endBackgroundTask()
			}
			return
		}

		let duration = getRecordingDuration(url: url)
		guard duration > 1.0 else { // Must be at least 1 second
			print("❌ Recording duration too short to recover (\(duration) seconds)")
			// Clean up the short recording
			try? FileManager.default.removeItem(at: url)
			await sendInterruptionNotification(success: false, reason: reason, filename: url.lastPathComponent)
			await MainActor.run {
				endBackgroundTask()
			}
			return
		}
		
		print("✅ Recording has meaningful content: \(fileSize) bytes, \(duration) seconds")
		
		// Save location data if available
		saveLocationData(for: url)
		
		// Add the recording using workflow manager for proper UUID consistency
		if let workflowManager = workflowManager {
			let quality = AudioRecorderViewModel.getCurrentAudioQuality()
			
			// Use original filename for recording name to maintain consistency
			let originalFilename = url.deletingPathExtension().lastPathComponent
			let displayName = "\(originalFilename) (interrupted)"
			
			// Core Data operations should happen on main thread
			await MainActor.run {
				// Create recording entry using original URL to maintain file consistency
					let recordingId = workflowManager.createRecording(
						url: url,
						name: displayName,
						date: Date(),
						fileSize: fileSize,
						duration: duration,
						quality: quality,
						locationData: recordingLocationSnapshot()
					)
				
					print("✅ Interrupted recording recovered with workflow manager, ID: \(recordingId)")

					// Post notification to refresh UI
					NotificationCenter.default.post(name: NSNotification.Name("RecordingAdded"), object: nil)

					// Reset processing flag
					recordingBeingProcessed = false
					resetRecordingLocation()

					// End background task after successful recovery and save
					endBackgroundTask()
				}

			// Don't send additional notification - already sent immediate notification

		} else {
			print("❌ WorkflowManager not set - interrupted recording not saved to database!")
			await sendInterruptionNotification(success: false, reason: reason, filename: url.lastPathComponent)

			// Reset processing flag even on failure
			await MainActor.run {
				recordingBeingProcessed = false
				// End background task even on failure
				endBackgroundTask()
			}
		}
	}
	
	private func sendInterruptionNotification(success: Bool, reason: String, filename: String) async {
		let title = success ? "Recording Saved" : "Recording Lost"
		let body = success 
			? "Your recording was interrupted but has been saved: \(filename.prefix(30))..."
			: "Recording was interrupted and could not be saved: \(reason)"
		
		// Send notification using UNUserNotificationCenter
		let center = UNUserNotificationCenter.current()
		
		// Check/request permission
		let settings = await center.notificationSettings()
		var hasPermission = settings.authorizationStatus == .authorized
		
		if settings.authorizationStatus == .notDetermined {
			do {
				hasPermission = try await center.requestAuthorization(options: [.alert, .badge, .sound])
			} catch {
				print("❌ Error requesting notification permission: \(error)")
				return
			}
		}
		
		guard hasPermission else {
			print("📱 Notification permission denied - cannot send interruption notification")
			return
		}
		
		// Create notification content
		let content = UNMutableNotificationContent()
		content.title = title
		content.body = body
		content.sound = .default
		content.userInfo = [
			"type": "recording_interruption",
			"success": success,
			"reason": reason,
			"filename": filename
		]
		
		// Create notification request
		let request = UNNotificationRequest(
			identifier: "recording_interruption_\(UUID().uuidString)",
			content: content,
			trigger: nil // Immediate delivery
		)
		
		do {
			try await center.add(request)
			print("📱 Sent interruption notification: \(title) - \(body)")
		} catch {
			print("❌ Failed to send interruption notification: \(error)")
		}
	}
	
	private func checkForUnprocessedRecording() async {
		print("🔍 checkForUnprocessedRecording called - recordingBeingProcessed: \(recordingBeingProcessed), isRecording: \(isRecording)")

		// CRITICAL: Never recover a recording that is still active
		if isRecording {
			print("🔍 Recording is still active, skipping recovery check")
			return
		}

		// Prevent duplicate recovery attempts (both flag and time-based)
		let now = Date()
		if recordingBeingProcessed || now.timeIntervalSince(lastRecoveryAttempt) < 2.0 {
			print("🔍 Recovery already in progress or attempted recently, skipping duplicate attempt")
			return
		}

		lastRecoveryAttempt = now
		
		// Check if there's a recording file that exists but wasn't processed
		guard let recordingURL = recordingURL else { 
			print("🔍 No recording URL to check")
			return 
		}
		
		print("🔍 Checking recording URL: \(recordingURL.path)")
		
		// Check if file exists on filesystem
		guard FileManager.default.fileExists(atPath: recordingURL.path) else {
			print("🔍 No unprocessed recording file found")
			return
		}
		
		let fileSize = getFileSize(url: recordingURL)
		guard fileSize > 1024 else { // Must be at least 1KB
			print("🔍 Found recording file but it's too small to process (\(fileSize) bytes)")
			return
		}
		
		// Check if this recording already exists in the database
		let existingRecordingName: String? = await MainActor.run { [appCoordinator, recordingURL] in
			guard
				let appCoordinator,
				let recording = appCoordinator.getRecording(url: recordingURL)
			else { return nil }
			return recording.recordingName ?? "unknown"
		}
		
		// Exit if recording already exists
		if let existingRecordingName = existingRecordingName {
			print("🔍 Recording already exists in database: \(existingRecordingName)")
			print("🔍 Recording already processed, clearing recording URL")
			await MainActor.run {
				self.recordingURL = nil // Clear so we don't keep checking
			}
			return
		}
		
		// Set flag to prevent duplicate processing
		recordingBeingProcessed = true
		
		print("🔄 Found unprocessed recording from backgrounding, recovering it now")
		
		// Process the unprocessed recording
		await recoverUnprocessedRecording(url: recordingURL)
	}
	
	private func recoverUnprocessedRecording(url: URL) async {
		print("💾 Recovering unprocessed recording at: \(url.path)")
		
		let fileSize = getFileSize(url: url)
		let duration = getRecordingDuration(url: url)
		
		print("✅ Unprocessed recording has content: \(fileSize) bytes, \(duration) seconds")
		
		// Save location data if available
		saveLocationData(for: url)
		
		// Add the recording using workflow manager
		if let workflowManager = workflowManager {
			let quality = AudioRecorderViewModel.getCurrentAudioQuality()
			
			// Use original filename for recording name
			let originalFilename = url.deletingPathExtension().lastPathComponent
			let displayName = "\(originalFilename) (recovered from background)"
			
			// Core Data operations should happen on main thread
			await MainActor.run {
				let recordingId = workflowManager.createRecording(
					url: url,
					name: displayName,
					date: Date(),
					fileSize: fileSize,
					duration: duration,
					quality: quality,
					locationData: recordingLocationSnapshot()
				)
				
					print("✅ Unprocessed recording recovered with workflow manager, ID: \(recordingId)")
					
					// Post notification to refresh UI
					NotificationCenter.default.post(name: NSNotification.Name("RecordingAdded"), object: nil)
					
					// Clear the recording URL since it's now processed
					self.recordingURL = nil
					self.recordingBeingProcessed = false
					self.resetRecordingLocation()
				}
			
			// Send notification to user about recovery (with slight delay to improve visibility)
			await sendRecoveryNotification(filename: displayName)
		} else {
			print("❌ WorkflowManager not set - cannot recover unprocessed recording!")
		}
	}
	
	private func sendRecoveryNotification(filename: String) async {
		let title = "Recording Recovered"
		let body = "Found and saved your recording from when the app was in background: \(filename.prefix(30))..."
		
		// Check app state for notification timing
		let appState = await MainActor.run { UIApplication.shared.applicationState }
		print("📱 App state when sending notification: \(appState.rawValue) (0=active, 1=inactive, 2=background)")
		
		// Use the proven BackgroundProcessingManager notification system
		_ = await MainActor.run {
			Task {
				// Add a small delay to increase chances of notification being visible
				try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
				
				let backgroundManager = BackgroundProcessingManager.shared
				await backgroundManager.sendNotification(
					title: title,
					body: body,
					identifier: "recording_recovery_\(UUID().uuidString)",
					userInfo: [
						"type": "recovery",
						"filename": filename
					]
				)
				
				print("📱 Sent recovery notification via BackgroundProcessingManager: \(title)")
			}
		}
	}
	
	private func sendInterruptionNotificationImmediately(reason: String, recordingURL: URL) async {
		print("📱 Sending immediate interruption notification for mic takeover")
		
		let title = "Recording Interrupted"
		let body = "Your recording was stopped by another app but has been saved: \(recordingURL.lastPathComponent)"
		
		_ = await MainActor.run {
			Task {
				let backgroundManager = BackgroundProcessingManager.shared
				await backgroundManager.sendNotification(
					title: title,
					body: body,
					identifier: "recording_interrupted_\(UUID().uuidString)",
					userInfo: [
						"type": "recording_interrupted",
						"reason": reason,
						"filename": recordingURL.lastPathComponent
					]
				)
				
				print("📱 Sent immediate interruption notification: \(title)")
			}
		}
	}
	
	private func scheduleRecordingInterruptedNotification(recordingURL: URL) async {
		print("📱 Scheduling notification for interrupted recording while app is backgrounded")
		
		// Send notification while we're still in background
		let title = "Recording Interrupted"
		let body = "Your recording was interrupted when the app went to background. Don't worry - it will be saved when you return to the app!"
		
		_ = await MainActor.run {
			Task {
				// Small delay to ensure we're fully backgrounded
				try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
				
				let backgroundManager = BackgroundProcessingManager.shared
				await backgroundManager.sendNotification(
					title: title,
					body: body,
					identifier: "recording_interrupted_\(UUID().uuidString)",
					userInfo: [
						"type": "recording_interrupted",
						"filename": recordingURL.lastPathComponent
					]
				)
				
				print("📱 Sent background interruption notification: \(title)")
			}
		}
	}
	
	private func generateInterruptedRecordingDisplayName(reason: String) -> String {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
		let timestamp = formatter.string(from: Date())
		
		// Create a descriptive name based on the interruption reason
		let reasonPrefix = if reason.contains("interrupted by another app") {
			"interrupted"
		} else if reason.contains("unavailable") || reason.contains("disconnected") {
			"device-lost"
		} else {
			"stopped"
		}
		
		return "apprecording-\(reasonPrefix)-\(timestamp)"
	}
    
    func fetchInputs() async {
        do {
            // Temporarily configure session to get accurate input list
            try await enhancedAudioSessionManager.configureMixedAudioSession()
            let inputs = enhancedAudioSessionManager.getAvailableInputs()
            let activeInput = enhancedAudioSessionManager.getActiveInput()
            let storedPreferredInputUID = UserDefaults.standard.string(
                forKey: preferredInputDefaultsKey
            )

            // Immediately deactivate to avoid interfering with other audio
            try await enhancedAudioSessionManager.deactivateSession()

            await MainActor.run {
                availableInputs = inputs
                selectedInput = {
                    if let storedUID = storedPreferredInputUID,
                       let storedInput = inputs.first(where: { $0.uid == storedUID }) {
                        return storedInput
                    }

                    if let activeInput,
                       let matchedInput = inputs.first(where: { $0.uid == activeInput.uid }) {
                        return matchedInput
                    }

                    return inputs.first
                }()
            }
        } catch {
            await MainActor.run {
                errorMessage = "Failed to fetch audio inputs: \(error.localizedDescription)"
            }
        }
    }

    func setPreferredInput() {
        guard let input = selectedInput else { return }

        Task {
            do {
                // Temporarily configure session to set preferred input
                try await enhancedAudioSessionManager.configureMixedAudioSession()
                try await enhancedAudioSessionManager.setPreferredInput(input)
                UserDefaults.standard.set(input.uid, forKey: preferredInputDefaultsKey)
                // Keep session active for now since user likely will record soon
            } catch {
                errorMessage = "Failed to set preferred input: \(error.localizedDescription)"
            }
        }
    }

    @MainActor
    private func applySelectedInputToSession() async {
        // Get all currently available inputs
        let availableInputs = enhancedAudioSessionManager.getAvailableInputs()
        
        // First, try to use the currently selected input
        var inputToUse = selectedInput
        
        // If no input is selected, try to load from UserDefaults
        if inputToUse == nil {
            let storedPreferredInputUID = UserDefaults.standard.string(forKey: preferredInputDefaultsKey)
            if let storedUID = storedPreferredInputUID {
                // Try to find the stored input in available inputs
                inputToUse = availableInputs.first(where: { $0.uid == storedUID })
                
                // Update selectedInput if we found it
                if let foundInput = inputToUse {
                    selectedInput = foundInput
                }
            }
        }
        
        // Check if the preferred input is still available
        if let preferredInput = inputToUse {
            let isStillAvailable = availableInputs.contains(where: { $0.uid == preferredInput.uid })
            
            if isStillAvailable {
                // Preferred input is available, use it
                do {
                    try await enhancedAudioSessionManager.setPreferredInput(preferredInput)
                    UserDefaults.standard.set(preferredInput.uid, forKey: preferredInputDefaultsKey)
                    print("✅ Using preferred input: \(preferredInput.portName)")
                } catch {
                    print("⚠️ Failed to set preferred input, falling back to default: \(error.localizedDescription)")
                    // Fall through to default behavior
                    inputToUse = nil
                }
            } else {
                // Preferred input is no longer available, fall back to default
                print("⚠️ Preferred input '\(preferredInput.portName)' is no longer available, falling back to iOS default")
                inputToUse = nil
            }
        }
        
        // If no preferred input or it's unavailable, let iOS use its default
        // iOS will automatically use the built-in microphone when no preferred input is set
        if inputToUse == nil {
            do {
                // Clear the preferred input to let iOS use its default
                try await enhancedAudioSessionManager.clearPreferredInput()
                // Clear the stored preference since the device is no longer available
                UserDefaults.standard.removeObject(forKey: preferredInputDefaultsKey)
                // Update selectedInput to nil so UI reflects the fallback
                selectedInput = nil
                print("✅ Using iOS default microphone (preferred input unavailable)")
            } catch {
                // If clearing fails, iOS will still use default, so just log it
                print("⚠️ Could not clear preferred input, iOS will use default: \(error.localizedDescription)")
                // Still clear the stored preference and update UI
                UserDefaults.standard.removeObject(forKey: preferredInputDefaultsKey)
                selectedInput = nil
            }
        }
    }

    func startRecording() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if granted {
                    Task {
                        do {
                            try await self.enhancedAudioSessionManager.configureMixedAudioSession()
                            await self.applySelectedInputToSession()
                        } catch {
                            print("Failed to configure enhanced audio session: \(error)")
                            return
                        }
                        
                        await MainActor.run {
                            self.setupRecording()
                        }
                    }
                } else {
                    self.errorMessage = "Microphone permission denied"
                }
            }
        }
    }
    
    func startBackgroundRecording() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if granted {
                    Task {
                        do {
                            try await self.enhancedAudioSessionManager.configureBackgroundRecording()
                            await self.applySelectedInputToSession()
                        } catch {
                            print("Failed to configure background recording session: \(error)")
                            return
                        }
                        
                        await MainActor.run {
                            self.setupRecording()
                        }
                    }
                } else {
                    self.errorMessage = "Microphone permission denied"
                }
            }
        }
    }
    
    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        print("🔄 Starting background task for recording")
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Recording") { [weak self] in
            print("⚠️ Recording background task expiring!")
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        print("⏹️ Ending recording background task")
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Create a URL for a new recording segment
    /// Segments are named by appending "_seg1", "_seg2", etc. to the base filename
    private func createSegmentURL(baseURL: URL, segmentIndex: Int) -> URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let baseFilename = baseURL.deletingPathExtension().lastPathComponent
        let fileExtension = baseURL.pathExtension
        let segmentFilename = "\(baseFilename)_seg\(segmentIndex).\(fileExtension)"
        return documentsPath.appendingPathComponent(segmentFilename)
    }

    private func setupRecording() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let audioFilename = documentsPath.appendingPathComponent(generateAppRecordingFilename())
        recordingURL = audioFilename

        // Initialize segment tracking for this new recording
        mainRecordingURL = audioFilename
        recordingSegments = [audioFilename] // Start with the first segment
        currentSegmentIndex = 0
        print("📝 Starting new recording with segment tracking: \(audioFilename.lastPathComponent)")

        // Capture current location before starting recording
        captureCurrentLocation()
        
        // Use Whisper-optimized quality for all recordings
        let selectedQuality = AudioQuality.whisperOptimized
        let settings = selectedQuality.settings
        
        do {
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.delegate = self

            // Enable metering for silence detection (used for smart checkpoints)
            audioRecorder?.isMeteringEnabled = true

            #if targetEnvironment(simulator)
            print("🤖 Running on iOS Simulator - audio recording may have limitations")
            print("💡 For best results, test on a physical device or ensure simulator microphone is enabled")
            #endif

            // No background task needed here - audio background mode keeps recording alive
            audioRecorder?.record()

            isRecording = true
            recordingTime = 0
            lastCheckpointTime = Date() // Initialize checkpoint time to now
            startRecordingTimer()
            
            // Notify watch of recording state change
            notifyWatchOfRecordingStateChange()
            
        } catch {
            #if targetEnvironment(simulator)
            errorMessage = "Recording failed on simulator. Enable Device → Microphone → Internal Microphone in simulator menu, or test on a physical device."
            print("🤖 Simulator audio error: \(error.localizedDescription)")
            #else
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
            #endif
        }
    }
    
    private func captureCurrentLocation() {
        guard isLocationTrackingEnabled else {
            currentLocationData = nil
            recordingStartLocationData = nil
            return
        }

        recordingStartLocationData = nil

        // Prefer the freshest location available right away
        if let location = locationManager.currentLocation {
            updateCurrentLocationData(with: location)
            if recordingStartLocationData == nil {
                recordingStartLocationData = currentLocationData
            }
        }

        // Always request a fresh location to capture the most accurate coordinate
        locationManager.requestCurrentLocation { [weak self] location in
            guard let self = self else { return }

            DispatchQueue.main.async {
                guard self.isLocationTrackingEnabled else { return }

                guard let location = location else {
                    print("⚠️ Failed to capture fresh location for recording start")
                    return
                }

                self.updateCurrentLocationData(with: location)
                if self.recordingStartLocationData == nil {
                    self.recordingStartLocationData = self.currentLocationData
                }
                print("📍 Location captured for recording: \(location.coordinate.latitude), \(location.coordinate.longitude)")
            }
        }
    }

    private func saveLocationData(for recordingURL: URL) {
        guard isLocationTrackingEnabled else {
            print("📍 Location tracking disabled or no location data available")
            return
        }

        // If we never received a location update yet, fall back to the current manager value
        if recordingLocationSnapshot() == nil, let latestLocation = locationManager.currentLocation {
            updateCurrentLocationData(with: latestLocation)
        }

        guard let locationData = recordingLocationSnapshot() else {
            print("📍 No location data available to save for \(recordingURL.lastPathComponent)")
            return
        }

        let locationURL = recordingURL.deletingPathExtension().appendingPathExtension("location")
        do {
            let data = try JSONEncoder().encode(locationData)
            try data.write(to: locationURL)
            print("📍 Location data saved for recording: \(recordingURL.lastPathComponent)")
        } catch {
            print("❌ Failed to save location data: \(error)")
        }
    }

    private func setupLocationObservers() {
        locationManager.$currentLocation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] location in
                guard
                    let self,
                    self.isLocationTrackingEnabled,
                    let location
                else { return }

                self.updateCurrentLocationData(with: location)
            }
            .store(in: &cancellables)
    }

    private func updateCurrentLocationData(with location: CLLocation) {
        guard location.horizontalAccuracy >= 0 else {
            print("⚠️ Ignoring location with invalid accuracy: \(location.horizontalAccuracy)")
            return
        }

        let newLocationData = LocationData(location: location)

        if let existing = currentLocationData {
            let existingAccuracy = existing.accuracy ?? .greatestFiniteMagnitude
            let newAccuracy = newLocationData.accuracy ?? .greatestFiniteMagnitude

            let isNewer = location.timestamp > existing.timestamp
            let isMoreAccurate = newAccuracy < existingAccuracy

            guard isNewer || isMoreAccurate else {
                return
            }
        }

        currentLocationData = newLocationData

        if isRecording && recordingStartLocationData == nil {
            recordingStartLocationData = newLocationData
        }
    }

    private func recordingLocationSnapshot() -> LocationData? {
        recordingStartLocationData ?? currentLocationData
    }

    private func resetRecordingLocation() {
        recordingStartLocationData = nil
    }
    
    func toggleLocationTracking(_ enabled: Bool) {
        isLocationTrackingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isLocationTrackingEnabled")
        
        if enabled {
            locationManager.requestLocationPermission()
        } else {
            locationManager.stopLocationUpdates()
            currentLocationData = nil
            resetRecordingLocation()
        }

        print("📍 Location tracking \(enabled ? "enabled" : "disabled")")
    }
    
    func stopRecording() {
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
            print("🔄 Recording has \(recordingSegments.count) segments, merging...")
            Task {
                await mergeRecordingSegments()
            }
        } else {
            print("✅ Recording has single segment, no merge needed")
        }

        // Deactivate audio session to restore high-quality music playback
        Task {
            try? await enhancedAudioSessionManager.deactivateSession()
        }

        // Notify watch of recording state change
        notifyWatchOfRecordingStateChange()

        // No background task to end here - data saving operations manage their own tasks
    }

    /// Merge multiple recording segments into a single file after interruptions
    @MainActor
    private func mergeRecordingSegments() async {
        guard recordingSegments.count > 1, let mainURL = mainRecordingURL else {
            print("⚠️ No segments to merge")
            return
        }

        print("🔄 Merging \(recordingSegments.count) segments into: \(mainURL.lastPathComponent)")
        print("🔄 Merging \(recordingSegments.count) segments into: \(mainURL.lastPathComponent)")

        // Start background task to protect file merging and Core Data save operations
        beginBackgroundTask()

        do {
            // Create AVAsset for each segment
            let composition = AVMutableComposition()

            // Create an audio track in the composition
            guard let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                print("❌ Failed to create composition audio track")
                return
            }

            var currentTime = CMTime.zero

            // Add each segment to the composition
            for (index, segmentURL) in recordingSegments.enumerated() {
                let asset = AVURLAsset(url: segmentURL)

                // Get the audio track from the segment
                guard let assetTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
                    print("⚠️ Segment \(index + 1) has no audio track, skipping")
                    continue
                }

                // Get the duration of this segment
                let duration = try await asset.load(.duration)

                // Insert the segment at the current time
                let timeRange = CMTimeRange(start: .zero, duration: duration)
                try compositionAudioTrack.insertTimeRange(timeRange, of: assetTrack, at: currentTime)

                print("✅ Added segment \(index + 1) at \(currentTime.seconds)s, duration: \(duration.seconds)s")

                // Move forward for the next segment
                currentTime = CMTimeAdd(currentTime, duration)
            }

            // Export the merged composition using iOS 18+ API
            guard let exportSession = AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetAppleM4A
            ) else {
                print("❌ Failed to create export session")
                return
            }

            // Export to a temporary file first (to avoid overwriting existing segments)
            let tempURL = mainURL.deletingLastPathComponent().appendingPathComponent("temp_merge_\(UUID().uuidString).m4a")

            // Use the modern export API (iOS 18+)
            try await exportSession.export(to: tempURL, as: .m4a)

            print("✅ Successfully merged all segments to temporary file")

            // Clean up individual segment files
            await cleanupSegmentFiles()

            // Move the merged file to the final location
            let fileManager = FileManager.default

            // Remove the final destination if it exists
            if fileManager.fileExists(atPath: mainURL.path) {
                try fileManager.removeItem(at: mainURL)
            }

            // Move temp file to final location
            try fileManager.moveItem(at: tempURL, to: mainURL)

            print("✅ Successfully merged all segments into: \(mainURL.lastPathComponent)")

            // Update the recordingURL to point to the merged file
            recordingURL = mainURL

            // Save the merged recording to the database
            saveLocationData(for: mainURL)

            print("✅ Merged recording saved in Whisper-optimized format")

            // Add recording using workflow manager
            if let workflowManager = workflowManager {
                let fileSize = getFileSize(url: mainURL)
                let duration = getRecordingDuration(url: mainURL)
                let quality = AudioRecorderViewModel.getCurrentAudioQuality()

                // Create display name for phone recording
                let displayName = generateAppRecordingDisplayName()

                // Create recording
                let recordingId = workflowManager.createRecording(
                    url: mainURL,
                    name: displayName,
                    date: Date(),
                    fileSize: fileSize,
                    duration: duration,
                    quality: quality,
                    locationData: recordingLocationSnapshot()
                )

                print("✅ Merged recording created with workflow manager, ID: \(recordingId)")

                self.resetRecordingLocation()
            } else {
                print("❌ WorkflowManager not set - merged recording not saved to database!")
            }

            // End background task after successful merge and save
            endBackgroundTask()

        } catch {
            print("❌ Error merging segments: \(error.localizedDescription)")
            // End background task even on error
            endBackgroundTask()
        }
    }

    /// Clean up individual segment files after successful merge
    @MainActor
    private func cleanupSegmentFiles() async {
        guard recordingSegments.count > 1 else { return }

        let fileManager = FileManager.default

        // Delete all segment files (including the first one, since we're merging to a temp file first)
        for segmentURL in recordingSegments {
            do {
                if fileManager.fileExists(atPath: segmentURL.path) {
                    try fileManager.removeItem(at: segmentURL)
                    print("🗑️ Deleted segment: \(segmentURL.lastPathComponent)")
                }
            } catch {
                print("⚠️ Failed to delete segment \(segmentURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // Clear the segment tracking
        recordingSegments = []
        mainRecordingURL = nil
        currentSegmentIndex = 0
    }

    /// Manually trigger a checkpoint to flush audio buffer to disk
    /// This ensures recorded audio is written to permanent storage
    /// Useful before potentially risky operations or to ensure data durability
    func forceCheckpoint() {
        guard isRecording, let recorder = audioRecorder, recorder.isRecording else {
            print("⚠️ Cannot checkpoint: not currently recording")
            return
        }

        recorder.pause()
        recorder.record()
        lastCheckpointTime = Date()
        print("💾 Manual checkpoint: Flushed recording buffer to disk")
    }

    /// Check if the current audio level indicates silence
    /// Returns true if the audio is below the silence threshold
    private func isCurrentlySilent() -> Bool {
        guard let recorder = audioRecorder, recorder.isRecording else {
            return false
        }

        // Update metering to get current levels
        recorder.updateMeters()

        // Get average power for channel 0 (mono recording)
        let averagePower = recorder.averagePower(forChannel: 0)

        // Check if below silence threshold
        let isSilent = averagePower < silenceThreshold

        return isSilent
    }

    /// Perform a smart checkpoint that waits for silence
    private func performSmartCheckpoint(force: Bool = false) {
        guard isRecording, let recorder = audioRecorder, recorder.isRecording else {
            return
        }

        let now = Date()
        let timeSinceLastCheckpoint = now.timeIntervalSince(lastCheckpointTime)

        // Check if we need to checkpoint
        let shouldAttemptCheckpoint = timeSinceLastCheckpoint >= checkpointInterval
        let shouldForceCheckpoint = force || timeSinceLastCheckpoint >= forceCheckpointInterval

        guard shouldAttemptCheckpoint || shouldForceCheckpoint else {
            return
        }

        // If forcing or if we detect silence, do the checkpoint
        if shouldForceCheckpoint {
            recorder.pause()
            recorder.record()
            lastCheckpointTime = now
            print("💾 Checkpoint: Forced buffer flush at \(Int(recordingTime))s (no silence detected for \(Int(timeSinceLastCheckpoint))s)")
        } else if isCurrentlySilent() {
            recorder.pause()
            recorder.record()
            lastCheckpointTime = now
            print("💾 Checkpoint: Flushed during silence at \(Int(recordingTime))s")
        } else {
            // Not silent and not forcing - skip this checkpoint attempt
            // We'll try again next second
            return
        }
    }
    
    func playRecording(url: URL) {
        Task {
            do {
                try await enhancedAudioSessionManager.configurePlaybackSession()
                
                // Store the current seek position before creating new player
                let seekPosition = await MainActor.run { playingTime }
                
                // Create player on current thread (where we can use try)
                let player = try AVAudioPlayer(contentsOf: url)
                
                await MainActor.run {
                    audioPlayer = player
                    audioPlayer?.delegate = self
                    
                    // If we had a seek position, restore it
                    if seekPosition > 0 {
                        audioPlayer?.currentTime = seekPosition
                        playingTime = seekPosition
                    } else {
                        playingTime = 0
                    }
                    
                    audioPlayer?.play()
                    isPlaying = true
                    startPlayingTimer()
                }
                
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to play recording: \(error.localizedDescription)"
                }
            }
        }
    }
    
    func stopPlaying() {
        audioPlayer?.stop()
        isPlaying = false
        stopPlayingTimer()
        
        // Deactivate audio session to restore other audio apps
        Task {
            try? await enhancedAudioSessionManager.deactivateSession()
        }
    }
    
    // MARK: - Public Watch Interface
    
    
    /// Seek to a specific time in the current audio playback
    func seekToTime(_ time: TimeInterval) {
        guard let player = audioPlayer else { return }
        player.currentTime = min(max(time, 0), player.duration)
        playingTime = player.currentTime
    }
    
    /// Get the current playback time
    func getCurrentTime() -> TimeInterval {
        return audioPlayer?.currentTime ?? 0
    }
    
    /// Get the total duration of the current audio
    func getDuration() -> TimeInterval {
        return audioPlayer?.duration ?? 0
    }
    
    /// Get the current playback progress as a percentage (0.0 to 1.0)
    func getPlaybackProgress() -> Double {
        guard let player = audioPlayer, player.duration > 0 else { return 0.0 }
        return player.currentTime / player.duration
    }
    
    private func startRecordingTimer() {
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Failsafe: if the underlying recorder stopped, try to resume before giving up
                // But DON'T trigger if app is backgrounding or in interruption - recording should continue
                // This is the only failsafe we need - if iOS actually stops the recorder, this will catch it
                // We don't check for stalled writes because silence is normal and doesn't mean the mic is unavailable
                // We add a grace period to allow interruption notifications to arrive first
                // If no notification arrives (e.g., Bluetooth disconnect), we try to resume recording automatically
                // For phone calls, iOS sends interruption notifications, so we wait longer (up to 180 seconds)
                // Note: If we're in an interruption state, we'll wait for the interruption to end
                if self.isRecording, let recorder = self.audioRecorder, !recorder.isRecording && !self.appIsBackgrounding {
                    if self.isInInterruption {
                        // We're in an interruption - wait for it to end rather than trying to resume now
                        // The interruption handler will take care of resuming when it ends
                        if self.recorderStoppedUnexpectedlyTime != nil {
                            self.recorderStoppedUnexpectedlyTime = nil // Clear since we're waiting for interruption to end
                        }
                    } else {
                        // Not in interruption - track when we first detected the recorder stopped
                        if self.recorderStoppedUnexpectedlyTime == nil {
                            self.recorderStoppedUnexpectedlyTime = Date()
                            print("⚠️ Detected recorder stopped - waiting for interruption notification (grace period: 5 seconds)")
                        } else if let stoppedTime = self.recorderStoppedUnexpectedlyTime, Date().timeIntervalSince(stoppedTime) >= 5.0 {
                            // After 5 second grace period, if no interruption notification arrived,
                            // try to resume recording (might be a Bluetooth disconnect or similar)
                            // Phone calls ALWAYS send interruption notifications, so if we're here it's not a phone call
                            print("🔄 No interruption notification received after 5 seconds - attempting to resume recording (likely hardware issue)")
                            self.recorderStoppedUnexpectedlyTime = nil
                            Task { @MainActor in
                                await self.attemptResumeAfterUnexpectedStop()
                            }
                            return
                        }
                        // Otherwise, continue waiting for interruption notification
                    }
                } else {
                    // Recorder is running or we're in a safe state, clear the stopped tracking
                    if self.recorderStoppedUnexpectedlyTime != nil {
                        self.recorderStoppedUnexpectedlyTime = nil
                    }

                    // Perform smart checkpoint that waits for silence
                    // This minimizes data loss while avoiding mid-word interruptions
                    self.performSmartCheckpoint()
                }
                self.recordingTime += 1
            }
        }
    }
    
    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }
    
    private func startPlayingTimer() {
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
    
    private func stopPlayingTimer() {
        playingTimer?.invalidate()
        playingTimer = nil
    }
    
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
    
    // MARK: - Helper Methods
    
    private func getFileSize(url: URL) -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.size] as? Int64 ?? 0
        } catch {
            return 0
        }
    }
    
    private func getRecordingDuration(url: URL) -> TimeInterval {
        // Prefer AVAudioPlayer's parsed duration (often more accurate/playable length)
        if let player = try? AVAudioPlayer(contentsOf: url) {
            let d = player.duration
            if d > 0 { return d }
        }
        // Fallback to AVURLAsset with precise timing
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let semaphore = DispatchSemaphore(value: 0)
        var loadedDuration: TimeInterval = 0
        Task {
            do {
                let loadedDurationValue = try await asset.load(.duration)
                loadedDuration = CMTimeGetSeconds(loadedDurationValue)
            } catch {
                print("⚠️ Failed to load duration for \(url.lastPathComponent): \(error.localizedDescription)")
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2.0)
        if loadedDuration > 0 { return loadedDuration }
        // Final fallback to the timer value we tracked during recording
        return recordingTime
    }
    
}

extension AudioRecorderViewModel: AVAudioRecorderDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            if isRecording {
                audioRecorder?.stop()
                isRecording = false
                stopRecordingTimer()
            }
            errorMessage = "Recording stopped due to an encoding error\(error.map { ": \($0.localizedDescription)" } ?? ".")"
        }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task {
            await MainActor.run {
                // Check if we're still in recording mode - if so, this was an interruption, not a user stop
                // In this case, don't save as a finished recording - let the interruption handler deal with it
                if isRecording {
                    print("⚠️ Recorder finished but still in recording mode - ignoring (interruption will be handled)")
                    return
                }

                // Check if recording is already being processed by interruption handler
                // But allow processing if app is backgrounding (normal completion scenario)
                if recordingBeingProcessed && !appIsBackgrounding {
                    print("⚠️ Recording already processed by interruption handler, skipping normal completion")
                    recordingBeingProcessed = false // Reset flag
                    return
                }

                // Check if we have multiple segments - if so, the merge will handle saving
                if recordingSegments.count > 1 {
                    print("⚠️ Multiple segments detected - merge process will handle saving")
                    return
                }

                // Start background task to protect Core Data save operations
                beginBackgroundTask()

                if flag {
                    if appIsBackgrounding {
                        print("Recording finished successfully during backgrounding - processing normally")
                    } else {
                        print("Recording finished successfully")
                    }
                    recordingBeingProcessed = true // Set flag to prevent duplicate processing

                    if let recordingURL = recordingURL {
                        saveLocationData(for: recordingURL)
                        
                        // New recordings are already in Whisper-optimized format (16kHz, 64kbps AAC)
                        print("✅ Recording saved in Whisper-optimized format")
                        
                        // Add recording using workflow manager for proper UUID consistency
                        if let workflowManager = workflowManager {
                            let fileSize = getFileSize(url: recordingURL)
                            let duration = getRecordingDuration(url: recordingURL)
                            let quality = AudioRecorderViewModel.getCurrentAudioQuality()
                            
                            // Create display name for phone recording
                            let displayName = generateAppRecordingDisplayName()
                            
                            // Create recording
                            let recordingId = workflowManager.createRecording(
                                url: recordingURL,
                                name: displayName,
                                date: Date(),
                                fileSize: fileSize,
                                duration: duration,
                                quality: quality,
                                locationData: recordingLocationSnapshot()
                            )
                            
                            print("✅ Recording created with workflow manager, ID: \(recordingId)")
                            
                            // Watch audio integration removed
                            self.resetRecordingLocation()
                        } else {
                            print("❌ WorkflowManager not set - recording not saved to database!")
                        }
                    }
                    
                    // Reset processing flag after successful completion
                    recordingBeingProcessed = false
                    
                    // Deactivate audio session to restore high-quality music playback
                    Task {
                        try? await enhancedAudioSessionManager.deactivateSession()
                    }
                } else {
                    errorMessage = "Recording failed"
                    recordingBeingProcessed = false // Reset flag on failure too
                    
                    // Also deactivate session on failure
                    Task {
                        try? await enhancedAudioSessionManager.deactivateSession()
                    }
                }

                // End background task that protected the Core Data save operation
                self.endBackgroundTask()
            }
        }
    }
    
    // MARK: - Watch Audio Integration
    
    /// Integrate watch audio with phone recording for enhanced quality
    private func integrateWatchAudioWithRecording(
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
                print("📱 Using phone audio as primary (\(phoneAudioSize) bytes), storing watch audio as backup")
                await storeWatchAudioAsBackup(watchAudioData, for: recordingId)
                return phoneAudioURL
            }
        }
        
        // Use watch audio as primary
        print("⌚ Using watch audio as primary (\(watchAudioData.count) bytes)")
        let watchAudioURL = try await createWatchAudioFile(from: watchAudioData, recordingId: recordingId)
        
        // Store phone audio as backup if it exists
        if phoneFileExists {
            await storePhoneAudioAsBackup(phoneAudioURL, for: recordingId)
        }
        
        return watchAudioURL
    }
    
    /// Create an audio file from watch PCM data
    private func createWatchAudioFile(from watchData: Data, recordingId: UUID) async throws -> URL {
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
            
            print("✅ Created watch audio file: \(watchAudioURL.lastPathComponent)")
            return watchAudioURL
            
        } catch {
            print("❌ Failed to create watch audio file: \(error)")
            throw AudioIntegrationError.fileCreationFailed(error.localizedDescription)
        }
    }
    
    /// Store watch audio as backup/supplementary data
    private func storeWatchAudioAsBackup(_ watchAudioData: Data, for recordingId: UUID) async {
        do {
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let backupURL = documentsURL.appendingPathComponent("watch_backup_\(recordingId).pcm")
            
            try watchAudioData.write(to: backupURL)
            print("✅ Stored watch audio backup: \(backupURL.lastPathComponent)")
            
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
            print("❌ Failed to store watch audio backup: \(error)")
        }
    }
    
    /// Store phone audio as backup when watch audio is primary
    private func storePhoneAudioAsBackup(_ phoneAudioURL: URL, for recordingId: UUID) async {
        do {
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let backupURL = documentsURL.appendingPathComponent("phone_backup_\(recordingId).m4a")
            
            try FileManager.default.copyItem(at: phoneAudioURL, to: backupURL)
            print("✅ Stored phone audio backup: \(backupURL.lastPathComponent)")
            
        } catch {
            print("❌ Failed to store phone audio backup: \(error)")
        }
    }
    
    // MARK: - Standardized Naming Convention
    
    /// Generates a standardized filename for app-created recordings
    private func generateAppRecordingFilename() -> String {
        let timestamp = Date().timeIntervalSince1970
        return "apprecording-\(Int(timestamp)).m4a"
    }
    
    /// Generates a standardized display name for app-created recordings
    private func generateAppRecordingDisplayName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        return "apprecording-\(timestamp)"
    }
    
    /// Creates a standardized name for imported files
    static func generateImportedFileName(originalName: String) -> String {
        // Remove file extension if present
        let nameWithoutExtension = (originalName as NSString).deletingPathExtension
        
        // Truncate to iOS standard title length (around 60 characters for display)
        let maxLength = 60
        let truncatedName = nameWithoutExtension.count > maxLength ? 
            String(nameWithoutExtension.prefix(maxLength)) : nameWithoutExtension
        
        return "importedfile-\(truncatedName)"
    }
}

// MARK: - Supporting Types

enum AudioIntegrationError: LocalizedError {
    case formatCreationFailed
    case bufferCreationFailed
    case fileCreationFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .formatCreationFailed:
            return "Failed to create audio format"
        case .bufferCreationFailed:
            return "Failed to create audio buffer"
        case .fileCreationFailed(let details):
            return "Failed to create audio file: \(details)"
        }
    }
}

extension AudioRecorderViewModel: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task {
            await MainActor.run {
                isPlaying = false
                stopPlayingTimer()
                
                // Deactivate audio session when playback finishes to restore other audio apps
                Task {
                    try? await enhancedAudioSessionManager.deactivateSession()
                }
            }
        }
    }
}
