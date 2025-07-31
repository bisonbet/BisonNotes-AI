//
//  AudioRecorderViewModel.swift
//  Audio Journal
//
//  Created by Tim Champ on 7/28/25.
//

import Foundation
import AVFoundation
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
        
        // Get selected audio quality from UserDefaults
        let selectedQuality: AudioQuality
        if let savedQuality = UserDefaults.standard.string(forKey: "SelectedAudioQuality"),
           let quality = AudioQuality(rawValue: savedQuality) {
            selectedQuality = quality
        } else {
            selectedQuality = .high // Default to high quality (128 kbps)
        }
        
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
                
                isPlaying = true
                playingTime = 0
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
        playingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.playingTime += 1
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
        if let savedQuality = UserDefaults.standard.string(forKey: "SelectedAudioQuality"),
           let quality = AudioQuality(rawValue: savedQuality) {
            return quality
        }
        return .high // Default to high quality (128 kbps)
    }
    
    static func getCurrentAudioSettings() -> [String: Any] {
        return getCurrentAudioQuality().settings
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