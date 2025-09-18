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
    // Failsafe tracking to detect stalled recordings when input disappears
    private var lastRecordedFileSize: Int64 = -1
    private var stalledTickCount: Int = 0
    
    // Flag to prevent duplicate recording creation
    private var recordingBeingProcessed = false
    
    // Flag to track if app is backgrounding (to avoid false positive interruptions)
    private var appIsBackgrounding = false
    
    // Timestamp to track when last recovery was attempted (to prevent rapid duplicates)
    private var lastRecoveryAttempt: Date = Date.distantPast
    
    override init() {
        // Initialize the managers first
        self.enhancedAudioSessionManager = EnhancedAudioSessionManager()
        self.locationManager = LocationManager()
        
        super.init()
        
        // Load location tracking setting from UserDefaults
        self.isLocationTrackingEnabled = UserDefaults.standard.bool(forKey: "isLocationTrackingEnabled")
        
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
                
                print("🔄 AudioRecorderViewModel: App foregrounded, restoring audio session...")
                
                // Only handle audio session restoration - let BackgroundProcessingManager handle recording recovery
                try? await self.enhancedAudioSessionManager.restoreAudioSession()
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
			if isRecording {
				print("🎙️ Audio interruption began - stopping recording and attempting recovery")
				handleInterruptedRecording(reason: "Audio session was interrupted by another app")
			}
		case .ended:
			// Check if we should resume recording after interruption ends
			if let options = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
				let interruptionOptions = AVAudioSession.InterruptionOptions(rawValue: options)
				if interruptionOptions.contains(.shouldResume) {
					print("🔄 Interruption ended - system suggests resuming")
					// Note: We don't auto-resume recording as the user should explicitly start again
					errorMessage = "Microphone is available again. Previous recording was saved."
				} else {
					print("⚠️ Interruption ended but resume not recommended")
					errorMessage = "Interruption ended. Previous recording was saved."
				}
			}
		@unknown default:
			break
		}
	}

	private func handleRouteChange(_ notification: Notification) {
		guard let userInfo = notification.userInfo,
				let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
				let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
			return
		}
		
		switch reason {
		case .oldDeviceUnavailable, .categoryChange:
			// Input likely lost (e.g., Bluetooth mic disconnected)
			if isRecording {
				print("🎙️ Audio route changed - microphone unavailable, attempting recording recovery")
				handleInterruptedRecording(reason: "Microphone became unavailable (device disconnected or changed)")
			}
		default:
			break
		}
	}
	
	private func handleInterruptedRecording(reason: String) {
		print("🚨 Handling interrupted recording: \(reason)")
		
		// Prevent duplicate processing
		guard !recordingBeingProcessed else {
			print("⚠️ Recording already being processed, skipping duplicate interruption handling")
			return
		}
		recordingBeingProcessed = true
		
		// Stop the recorder and timer immediately
		audioRecorder?.stop()
		isRecording = false
		stopRecordingTimer()
		
		// Clear failsafe tracking
		lastRecordedFileSize = -1
		stalledTickCount = 0
		
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
	}
	
	private func recoverInterruptedRecording(url: URL, reason: String) async {
		print("💾 Attempting to recover interrupted recording at: \(url.path)")
		
		// Check if the file exists and has meaningful content
		guard FileManager.default.fileExists(atPath: url.path) else {
			print("❌ No recording file found for recovery")
			await sendInterruptionNotification(success: false, reason: reason, filename: url.lastPathComponent)
			return
		}
		
		let fileSize = getFileSize(url: url)
		guard fileSize > 1024 else { // Must be at least 1KB to be meaningful
			print("❌ Recording file too small to recover (\(fileSize) bytes)")
			// Clean up the tiny file
			try? FileManager.default.removeItem(at: url)
			await sendInterruptionNotification(success: false, reason: reason, filename: url.lastPathComponent)
			return
		}
		
		let duration = getRecordingDuration(url: url)
		guard duration > 1.0 else { // Must be at least 1 second
			print("❌ Recording duration too short to recover (\(duration) seconds)")
			// Clean up the short recording
			try? FileManager.default.removeItem(at: url)
			await sendInterruptionNotification(success: false, reason: reason, filename: url.lastPathComponent)
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
					locationData: currentLocationData
				)
				
				print("✅ Interrupted recording recovered with workflow manager, ID: \(recordingId)")
				
				// Post notification to refresh UI
				NotificationCenter.default.post(name: NSNotification.Name("RecordingAdded"), object: nil)
				
				// Reset processing flag
				recordingBeingProcessed = false
			}
			
			// Don't send additional notification - already sent immediate notification
			
		} else {
			print("❌ WorkflowManager not set - interrupted recording not saved to database!")
			await sendInterruptionNotification(success: false, reason: reason, filename: url.lastPathComponent)
			
			// Reset processing flag even on failure
			await MainActor.run {
				recordingBeingProcessed = false
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
		print("🔍 checkForUnprocessedRecording called - recordingBeingProcessed: \(recordingBeingProcessed)")
		
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
					locationData: currentLocationData
				)
				
				print("✅ Unprocessed recording recovered with workflow manager, ID: \(recordingId)")
				
				// Post notification to refresh UI
				NotificationCenter.default.post(name: NSNotification.Name("RecordingAdded"), object: nil)
				
				// Clear the recording URL since it's now processed
				self.recordingURL = nil
				self.recordingBeingProcessed = false
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
            
            // Immediately deactivate to avoid interfering with other audio
            try await enhancedAudioSessionManager.deactivateSession()
            
            await MainActor.run {
                availableInputs = inputs
                if let firstInput = inputs.first {
                    selectedInput = firstInput
                }
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
                // Keep session active for now since user likely will record soon
            } catch {
                errorMessage = "Failed to set preferred input: \(error.localizedDescription)"
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
    
    private func setupRecording() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let audioFilename = documentsPath.appendingPathComponent(generateAppRecordingFilename())
        recordingURL = audioFilename
        
        // Capture current location before starting recording
        captureCurrentLocation()
        
        // Use Whisper-optimized quality for all recordings
        let selectedQuality = AudioQuality.whisperOptimized
        let settings = selectedQuality.settings
        
        do {
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.delegate = self
            
            #if targetEnvironment(simulator)
            print("🤖 Running on iOS Simulator - audio recording may have limitations")
            print("💡 For best results, test on a physical device or ensure simulator microphone is enabled")
            #endif
            audioRecorder?.record()
            
            isRecording = true
            recordingTime = 0
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
        // Only capture location if tracking is enabled
        guard isLocationTrackingEnabled else {
            currentLocationData = nil
            return
        }
        
        // Get current location and save it
        if let location = locationManager.currentLocation {
            currentLocationData = LocationData(location: location)
            print("📍 Location captured for recording: \(location.coordinate.latitude), \(location.coordinate.longitude)")
        } else {
            // Request a one-time location update if we don't have current location
            locationManager.requestOneTimeLocation()
            print("📍 Requesting location for recording...")
        }
    }
    
    private func saveLocationData(for recordingURL: URL) {
        // Only save location data if tracking is enabled and we have location data
        guard isLocationTrackingEnabled, let locationData = currentLocationData else { 
            print("📍 Location tracking disabled or no location data available")
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
    
    func toggleLocationTracking(_ enabled: Bool) {
        isLocationTrackingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isLocationTrackingEnabled")
        
        if enabled {
            locationManager.requestLocationPermission()
        } else {
            locationManager.stopLocationUpdates()
            currentLocationData = nil
        }
        
        print("📍 Location tracking \(enabled ? "enabled" : "disabled")")
    }
    
    func stopRecording() {
        audioRecorder?.stop()
        isRecording = false
        stopRecordingTimer()
        audioRecorder = nil
        lastRecordedFileSize = -1
        stalledTickCount = 0
        
        // Reset processing flag when manually stopping
        recordingBeingProcessed = false
        
        // Deactivate audio session to restore high-quality music playback
        Task {
            try? await enhancedAudioSessionManager.deactivateSession()
        }
        
        // Notify watch of recording state change
        notifyWatchOfRecordingStateChange()
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
        // Reset stall tracking at start
        lastRecordedFileSize = -1
        stalledTickCount = 0

        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Failsafe: if the underlying recorder stopped, handle interrupted recording
                // But DON'T trigger if app is backgrounding - recording should continue in background
                if self.isRecording, let recorder = self.audioRecorder, !recorder.isRecording && !self.appIsBackgrounding {
                    print("🚨 Failsafe: Detected recorder stopped unexpectedly (NOT due to backgrounding)")
                    self.handleInterruptedRecording(reason: "Microphone became unavailable or recording was interrupted")
                    return
                }
                // Failsafe: detect stalled writes (no bytes changing for several seconds)
                if self.isRecording, let url = self.recordingURL {
                    let currentSize = self.getFileSize(url: url)
                    if self.lastRecordedFileSize >= 0 && currentSize == self.lastRecordedFileSize {
                        self.stalledTickCount += 1
                    } else {
                        self.stalledTickCount = 0
                        self.lastRecordedFileSize = currentSize
                    }
                    if self.stalledTickCount >= 3 { // ~3 seconds of no data
                        print("🚨 Failsafe: Detected stalled recording (no new data for 3+ seconds)")
                        self.handleInterruptedRecording(reason: "No audio data being received (microphone may have been taken by another app)")
                        return
                    }
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
                // Check if recording is already being processed by interruption handler
                // But allow processing if app is backgrounding (normal completion scenario)
                if recordingBeingProcessed && !appIsBackgrounding {
                    print("⚠️ Recording already processed by interruption handler, skipping normal completion")
                    recordingBeingProcessed = false // Reset flag
                    return
                }
                
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
                                locationData: currentLocationData
                            )
                            
                            print("✅ Recording created with workflow manager, ID: \(recordingId)")
                            
                            // Watch audio integration removed
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