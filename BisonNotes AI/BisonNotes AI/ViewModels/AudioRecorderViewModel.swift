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
    
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var recordingTimer: Timer?
    private var playingTimer: Timer?
    private var interruptionObserver: NSObjectProtocol?
    private var willEnterForegroundObserver: NSObjectProtocol?
    
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
        print("✅ AudioRecorderViewModel initialized successfully")
    }
    
    deinit {
        // Remove observers synchronously since deinit cannot be async
        if let observer = interruptionObserver {
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
        if let observer = willEnterForegroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func handleAudioInterruption(_ notification: Notification) {
        enhancedAudioSessionManager.handleAudioInterruption(notification)
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
        let audioFilename = documentsPath.appendingPathComponent("recording_\(Date().timeIntervalSince1970).m4a")
        recordingURL = audioFilename
        
        // Capture current location before starting recording
        captureCurrentLocation()
        
        // Use Whisper-optimized quality for all recordings
        let selectedQuality = AudioQuality.whisperOptimized
        let settings = selectedQuality.settings
        
        do {
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.record()
            
            isRecording = true
            recordingTime = 0
            startRecordingTimer()
            
        } catch {
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
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
                self?.recordingTime += 1
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
        let asset = AVURLAsset(url: url)
        
        // Use async loading for duration (required for iOS 16+)
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
        
        // Wait for the async loading to complete (with timeout)
        _ = semaphore.wait(timeout: .now() + 2.0)
        
        return loadedDuration
    }
    
}

extension AudioRecorderViewModel: AVAudioRecorderDelegate {
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
                            
                            let recordingId = workflowManager.createRecording(
                                url: recordingURL,
                                name: recordingURL.deletingPathExtension().lastPathComponent,
                                date: Date(),
                                fileSize: fileSize,
                                duration: duration,
                                quality: quality,
                                locationData: currentLocationData
                            )
                            
                            print("✅ Recording created with workflow manager, ID: \(recordingId)")
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