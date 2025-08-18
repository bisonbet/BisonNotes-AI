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
import WatchConnectivity

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
    
    // MARK: - Watch Connectivity Properties
    @Published var watchConnectionState: WatchConnectionState = .disconnected
    @Published var isWatchRecordingActive: Bool = false
    @Published var watchBatteryLevel: Float?
    @Published var isReceivingWatchAudio: Bool = false
    @Published var isWatchInitiatedRecording: Bool = false
    
    // Reference to the app coordinator for adding recordings to registry
    private var appCoordinator: AppDataCoordinator?
    private var workflowManager: RecordingWorkflowManager?
    
    // Watch connectivity manager
    private var watchConnectivityManager: WatchConnectivityManager?
    private var watchAudioData: Data?
    private var watchRecordingSessionId: UUID?
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
    
    override init() {
        // Initialize the managers first
        self.enhancedAudioSessionManager = EnhancedAudioSessionManager()
        self.locationManager = LocationManager()
        
        super.init()
        
        // Load location tracking setting from UserDefaults
        self.isLocationTrackingEnabled = UserDefaults.standard.bool(forKey: "isLocationTrackingEnabled")
        
        // Setup notification observers after super.init()
        setupNotificationObservers()
        
        // Setup watch connectivity
        setupWatchConnectivity()
    }
    
    /// Set the app coordinator reference
    func setAppCoordinator(_ coordinator: AppDataCoordinator) {
        self.appCoordinator = coordinator
        Task { @MainActor in
            let workflowManager = RecordingWorkflowManager()
            workflowManager.setAppCoordinator(coordinator)
            self.workflowManager = workflowManager
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
        // AudioRecorderViewModel initialized
    }
    
    /// Setup watch connectivity integration
    private func setupWatchConnectivity() {
        guard WCSession.isSupported() else {
            print("⌚ WatchConnectivity not supported on this device")
            return
        }
        
        Task { @MainActor in
            watchConnectivityManager = WatchConnectivityManager.shared
            
            // Set up callbacks from watch connectivity manager
            watchConnectivityManager?.onWatchRecordingStartRequested = { [weak self] in
                Task { @MainActor in
                    self?.handleWatchRecordingStartRequest()
                }
            }
            
            watchConnectivityManager?.onWatchRecordingStopRequested = { [weak self] in
                Task { @MainActor in
                    self?.handleWatchRecordingStopRequest()
                }
            }
            
            watchConnectivityManager?.onWatchAudioReceived = { [weak self] audioData, sessionId in
                Task { @MainActor in
                    self?.handleWatchAudioReceived(audioData, sessionId: sessionId)
                }
            }
            
            // Sync published properties with watch connectivity manager state
            syncWatchConnectivityState()
        }
    }
    
    /// Sync published properties with watch connectivity manager
    @MainActor
    private func syncWatchConnectivityState() {
        guard let manager = watchConnectivityManager else { return }
        
        // Observe watch connectivity manager state changes
        manager.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                self?.watchConnectionState = newState
            }
            .store(in: &cancellables)
            
        manager.$watchBatteryLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] batteryLevel in
                self?.watchBatteryLevel = batteryLevel
            }
            .store(in: &cancellables)
            
        manager.$isReceivingAudioChunks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isReceiving in
                self?.isReceivingWatchAudio = isReceiving
            }
            .store(in: &cancellables)
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
        
        // Clean up watch connectivity
        watchConnectivityManager = nil
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
                try? await self.enhancedAudioSessionManager.restoreAudioSession()
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
    
    private func handleWatchRecordingStartRequest() {
        print("⌚ Processing watch recording start request")
        isWatchInitiatedRecording = true
        watchRecordingSessionId = UUID()
        
        // Start recording through existing method but mark as watch-initiated
        if !isRecording {
            startRecording()
        }
    }
    
    private func handleWatchRecordingStopRequest() {
        print("⌚ Processing watch recording stop request")
        
        if isRecording {
            stopRecording()
        }
        
        // Reset watch recording state
        isWatchInitiatedRecording = false
        watchRecordingSessionId = nil
        isWatchRecordingActive = false
    }
    
    private func handleWatchRecordingPauseRequest() {
        print("⌚ Processing watch recording pause request")
        
        if isRecording {
            // AVAudioRecorder doesn't have pause, so we'll stop and prepare to resume
            audioRecorder?.stop()
            isRecording = false
            stopRecordingTimer()
            
            // Note: This is a simplified pause - true pause/resume would require
            // more complex audio session management to continue in the same file
            
            // Send status update to watch
            sendRecordingStatusToWatch(.paused)
        }
    }
    
    private func handleWatchRecordingResumeRequest() {
        print("⌚ Processing watch recording resume request")
        
        // Note: Since AVAudioRecorder doesn't support true pause/resume,
        // this would start a new recording. For now, we'll just restart.
        if !isRecording {
            startRecording()
            
            // Send status update to watch
            sendRecordingStatusToWatch(.recording)
        }
    }
    
    private func handleWatchAudioReceived(_ audioData: Data, sessionId: UUID) {
        print("⌚ Received \(audioData.count) bytes of audio from watch for session \(sessionId)")
        
        // Store watch audio data and session info for integration with phone recording
        watchAudioData = audioData
        watchRecordingSessionId = sessionId
        
        // Create a playable audio file from the watch PCM data
        Task {
            do {
                let audioFileURL = try await createPlayableAudioFile(from: audioData, sessionId: sessionId)
                print("✅ Created playable audio file at: \(audioFileURL)")
                
                // Update the current recording URL to point to the watch audio file
                await MainActor.run {
                    self.recordingURL = audioFileURL
                }
            } catch {
                print("❌ Failed to create playable audio file from watch data: \(error)")
                await MainActor.run {
                    self.errorMessage = "Failed to process watch audio: \(error.localizedDescription)"
                }
            }
        }
        
        print("✅ Watch audio data processing initiated")
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
            watchConnectionState = .disconnected
        case .batteryTooLow:
            errorMessage = "Watch battery too low for recording"
        case .audioRecordingFailed:
            if isWatchInitiatedRecording {
                // Fallback to phone-only recording
                errorMessage = "Watch recording failed, continuing with phone only"
            }
        default:
            break
        }
    }
    
    // MARK: - Watch Communication Helpers
    
    private func sendRecordingStatusToWatch(_ state: WatchRecordingState) {
        Task { @MainActor in
            watchConnectivityManager?.sendRecordingStatusToWatch(
                state,
                recordingTime: recordingTime,
                error: errorMessage
            )
        }
    }
    
    private func notifyWatchOfRecordingStateChange() {
        let watchState: WatchRecordingState = isRecording ? .recording : .idle
        sendRecordingStatusToWatch(watchState)
        isWatchRecordingActive = isRecording && isWatchInitiatedRecording
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
				audioRecorder?.stop()
				isRecording = false
				stopRecordingTimer()
				errorMessage = "Recording stopped due to audio interruption."
			}
		case .ended:
			break
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
				audioRecorder?.stop()
				isRecording = false
				stopRecordingTimer()
				errorMessage = "Recording stopped because the microphone became unavailable."
			}
		default:
			break
		}
	}
    
    func fetchInputs() async {
        do {
            try await enhancedAudioSessionManager.configureMixedAudioSession()
            let inputs = enhancedAudioSessionManager.getAvailableInputs()
            await MainActor.run {
                availableInputs = inputs
                if let firstInput = inputs.first {
                    selectedInput = firstInput
                }
            }
        } catch {
            await MainActor.run {
                errorMessage = "Failed to configure audio session: \(error.localizedDescription)"
            }
        }
    }
    
    func setPreferredInput() {
        guard let input = selectedInput else { return }
        
        Task {
            do {
                try await enhancedAudioSessionManager.setPreferredInput(input)
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
        
        // Notify watch of recording state change
        notifyWatchOfRecordingStateChange()
        
        // Reset watch recording state
        if isWatchInitiatedRecording {
            isWatchInitiatedRecording = false
            watchRecordingSessionId = nil
        }
    }
    
    func playRecording(url: URL) {
        Task {
            do {
                try await enhancedAudioSessionManager.configurePlaybackSession()
                audioPlayer = try AVAudioPlayer(contentsOf: url)
                audioPlayer?.delegate = self
                audioPlayer?.play()
                
                await MainActor.run {
                    isPlaying = true
                    playingTime = 0
                }
                startPlayingTimer()
                
            } catch {
                errorMessage = "Failed to play recording: \(error.localizedDescription)"
            }
        }
    }
    
    func stopPlaying() {
        audioPlayer?.stop()
        isPlaying = false
        stopPlayingTimer()
    }
    
    // MARK: - Public Watch Interface
    
    /// Request sync with connected watch
    func syncWithWatch() {
        Task { @MainActor in
            watchConnectivityManager?.requestSyncWithWatch()
        }
    }
    
    /// Get current watch connection status
    var isWatchConnected: Bool {
        return watchConnectionState == .connected
    }
    
    /// Get formatted watch battery level string
    var watchBatteryLevelString: String {
        guard let batteryLevel = watchBatteryLevel else { return "Unknown" }
        return "\(Int(batteryLevel * 100))%"
    }
    
    /// Check if current recording was initiated by watch
    var isCurrentRecordingFromWatch: Bool {
        return isWatchInitiatedRecording && isRecording
    }
    
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
                // Failsafe: if the underlying recorder stopped, sync UI state
                if self.isRecording, let recorder = self.audioRecorder, !recorder.isRecording {
                    self.isRecording = false
                    self.stopRecordingTimer()
                    self.errorMessage = "Recording stopped because the microphone became unavailable."
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
                        self.audioRecorder?.stop()
                        self.isRecording = false
                        self.stopRecordingTimer()
                        self.errorMessage = "Recording stopped due to no audio data being received."
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
        playingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, let player = self.audioPlayer else { return }
                self.playingTime = player.currentTime
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
                if flag {
                    print("Recording finished successfully")
                    if let recordingURL = recordingURL {
                        saveLocationData(for: recordingURL)
                        
                        // New recordings are already in Whisper-optimized format (16kHz, 64kbps AAC)
                        print("✅ Recording saved in Whisper-optimized format")
                        
                        // Add recording using workflow manager for proper UUID consistency
                        if let workflowManager = workflowManager {
                            let fileSize = getFileSize(url: recordingURL)
                            let duration = getRecordingDuration(url: recordingURL)
                            let quality = AudioRecorderViewModel.getCurrentAudioQuality()
                            
                            // Create display name with watch indication if applicable
                            let displayName = isWatchInitiatedRecording ? 
                                "⌚ \(generateAppRecordingDisplayName())" : 
                                generateAppRecordingDisplayName()
                            
                            let recordingId = if isWatchInitiatedRecording {
                                // Create watch recording with additional metadata
                                workflowManager.createWatchRecording(
                                    url: recordingURL,
                                    name: displayName.replacingOccurrences(of: "⌚ ", with: ""), // Remove watch emoji prefix
                                    date: Date(),
                                    fileSize: fileSize,
                                    duration: duration,
                                    quality: quality,
                                    watchSessionId: watchRecordingSessionId ?? UUID(),
                                    batteryLevel: watchBatteryLevel ?? 0.5,
                                    chunkCount: 0, // TODO: Track actual chunk count
                                    transferMethod: .realTime,
                                    locationData: currentLocationData
                                )
                            } else {
                                // Create regular phone recording
                                workflowManager.createRecording(
                                    url: recordingURL,
                                    name: displayName,
                                    date: Date(),
                                    fileSize: fileSize,
                                    duration: duration,
                                    quality: quality,
                                    locationData: currentLocationData,
                                    recordingSource: .phone
                                )
                            }
                            
                            print("✅ Recording created with workflow manager, ID: \(recordingId)")
                            
                            // If this was a watch recording, handle watch audio integration
                            if isWatchInitiatedRecording, let watchAudio = watchAudioData {
                                print("🎵 Integrating watch audio data (\(watchAudio.count) bytes)")
                                
                                Task {
                                    do {
                                        // Try to enhance the recording with watch audio
                                        let enhancedAudioURL = try await integrateWatchAudioWithRecording(
                                            phoneAudioURL: recordingURL,
                                            watchAudioData: watchAudio,
                                            recordingId: recordingId
                                        )
                                        
                                        await MainActor.run {
                                            self.recordingURL = enhancedAudioURL
                                            print("✅ Watch audio integrated successfully")
                                        }
                                    } catch {
                                        print("❌ Failed to integrate watch audio: \(error)")
                                        // Keep using phone audio as primary, watch audio as metadata
                                        await self.storeWatchAudioAsBackup(watchAudio, for: recordingId)
                                    }
                                }
                            }
                        } else {
                            print("❌ WorkflowManager not set - recording not saved to database!")
                        }
                    }
                } else {
                    errorMessage = "Recording failed"
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
            }
        }
    }
}