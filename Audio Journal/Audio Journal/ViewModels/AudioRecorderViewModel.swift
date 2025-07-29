//
//  AudioRecorderViewModel.swift
//  Audio Journal
//
//  Created by Tim Champ on 7/28/25.
//

import SwiftUI
import AVFoundation
import Speech
import CoreLocation

class AudioRecorderViewModel: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var availableInputs: [AVAudioSessionPortDescription] = []
    @Published var selectedInputUID: String? {
        didSet {
            if let uid = selectedInputUID {
                UserDefaults.standard.set(uid, forKey: "SelectedMicUID")
            }
        }
    }
    @Published var selectedQuality: AudioQuality = .medium {
        didSet {
            UserDefaults.standard.set(selectedQuality.rawValue, forKey: "SelectedAudioQuality")
        }
    }
    @Published var selectedSummaryMethod: SummaryMethod = .appleIntelligence {
        didSet {
            UserDefaults.standard.set(selectedSummaryMethod.rawValue, forKey: "SelectedSummaryMethod")
        }
    }
    @Published var isLocationTrackingEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isLocationTrackingEnabled, forKey: "LocationTrackingEnabled")
            if isLocationTrackingEnabled {
                locationManager.requestLocationPermission()
            } else {
                locationManager.stopLocationUpdates()
            }
        }
    }

    @Published var selectedAIEngine: String = "Enhanced Apple Intelligence" {
        didSet {
            UserDefaults.standard.set(selectedAIEngine, forKey: "SelectedAIEngine")
        }
    }
    @Published var selectedTranscriptionEngine: TranscriptionEngine = .appleIntelligence {
        didSet {
            UserDefaults.standard.set(selectedTranscriptionEngine.rawValue, forKey: "SelectedTranscriptionEngine")
        }
    }
    @Published var recordingDuration: TimeInterval = 0
    @Published var currentlyPlayingURL: URL?
    @Published var isPlaying = false
    @Published var playbackProgress: TimeInterval = 0
    
    // Location management
    @Published var locationManager = LocationManager()
    @Published var recordingLocation: LocationData?
    
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private let session = AVAudioSession.sharedInstance()
    private var recordingTimer: Timer?
    private var playbackTimer: Timer?
    private let maxRecordingDuration: TimeInterval = 2 * 60 * 60 // 2 hours in seconds

    override init() {
        super.init()
        fetchInputs()
        selectedInputUID = UserDefaults.standard.string(forKey: "SelectedMicUID")
        if let qualityString = UserDefaults.standard.string(forKey: "SelectedAudioQuality"),
           let quality = AudioQuality(rawValue: qualityString) {
            selectedQuality = quality
        }
        if let summaryMethodString = UserDefaults.standard.string(forKey: "SelectedSummaryMethod"),
           let summaryMethod = SummaryMethod(rawValue: summaryMethodString) {
            selectedSummaryMethod = summaryMethod
        }
        
        // Load location tracking preference (default to true)
        isLocationTrackingEnabled = UserDefaults.standard.object(forKey: "LocationTrackingEnabled") as? Bool ?? true
        
        // Load AI engine preference (default to Enhanced Apple Intelligence)
        selectedAIEngine = UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? "Enhanced Apple Intelligence"
        
        // Load transcription engine preference (default to Apple Intelligence)
        if let transcriptionEngineString = UserDefaults.standard.string(forKey: "SelectedTranscriptionEngine"),
           let transcriptionEngine = TranscriptionEngine(rawValue: transcriptionEngineString) {
            selectedTranscriptionEngine = transcriptionEngine
        }
        
        // Initialize location manager only if location tracking is enabled
        if isLocationTrackingEnabled {
            locationManager.requestLocationPermission()
        }
    }

    func fetchInputs() {
        do {
            // Configure session to detect all available inputs including Bluetooth
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .allowBluetoothA2DP])
            try session.setActive(true)
            
            // Get all available inputs
            let inputs = session.availableInputs ?? []
            
            // Filter and sort inputs to prioritize built-in mic and common types
            availableInputs = inputs.sorted { input1, input2 in
                let priority1 = inputPriority(for: input1.portType)
                let priority2 = inputPriority(for: input2.portType)
                return priority1 < priority2
            }
            
            // If no input is selected, default to the first available (usually built-in mic)
            if selectedInputUID == nil && !availableInputs.isEmpty {
                selectedInputUID = availableInputs.first?.uid
            }
            
            print("Available audio inputs:")
            for input in availableInputs {
                print("- \(input.portName) (\(input.portType.rawValue))")
            }
            
        } catch {
            print("Failed to fetch audio inputs: \(error)")
        }
    }
    
    private func inputPriority(for portType: AVAudioSession.Port) -> Int {
        switch portType {
        case .builtInMic:
            return 1 // Highest priority - built-in mic
        case .headsetMic:
            return 2 // Wired headset
        case .bluetoothHFP:
            return 3 // Bluetooth hands-free
        case .bluetoothA2DP:
            return 4 // Bluetooth audio
        case .bluetoothLE:
            return 5 // Bluetooth LE
        case .usbAudio:
            return 6 // USB audio
        case .carAudio:
            return 7 // Car audio
        case .airPlay:
            return 8 // AirPlay
        case .lineIn:
            return 9 // Line input
        default:
            return 10 // Other types
        }
    }

    func setPreferredInput() {
        guard let uid = selectedInputUID,
              let input = availableInputs.first(where: { $0.uid == uid }) else { 
            print("No valid input selected")
            return 
        }
        
        do {
            try session.setPreferredInput(input)
            print("Successfully set preferred input to: \(input.portName) (\(input.portType.rawValue))")
        } catch {
            print("Failed to set preferred input to \(input.portName): \(error)")
        }
    }
    
    private func configureAudioSessionForRecording() {
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            print("Failed to configure audio session for recording: \(error)")
        }
    }
    
    private func configureAudioSessionForPlayback() {
        do {
            try session.setCategory(.playback, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            print("Failed to configure audio session for playback: \(error)")
        }
    }

    func startRecording() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if granted {
                    // Configure audio session for recording with speaker
                    self.configureAudioSessionForRecording()
                    
                    // Capture current location before starting recording
                    self.captureLocationForRecording()
                    
                    self.setPreferredInput()
                    let filename = self.generateFileName()
                    let url = self.getDocumentsDirectory().appendingPathComponent(filename)
                    
                    do {
                        self.audioRecorder = try AVAudioRecorder(url: url, settings: self.selectedQuality.settings)
                        self.audioRecorder?.delegate = self
                        self.audioRecorder?.record()
                        self.isRecording = true
                        self.recordingDuration = 0
                        self.startRecordingTimer()
                    } catch {
                        print("Failed to start recording: \(error)")
                    }
                } else {
                    print("Microphone permission denied")
                }
            }
        }
    }

    func stopRecording() {
        audioRecorder?.stop()
        
        // Save location data if available
        if let locationData = recordingLocation {
            saveLocationDataForCurrentRecording(locationData: locationData)
        }
        
        isRecording = false
        recordingDuration = 0
        stopRecordingTimer()
        recordingLocation = nil
    }
    
    private func startRecordingTimer() {
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.recordingDuration += 1
                
                // Auto-stop at 2 hours
                if self.recordingDuration >= self.maxRecordingDuration {
                    self.stopRecording()
                }
            }
        }
    }
    
    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }
    
    func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        let seconds = Int(duration) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    private func generateFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dateString = formatter.string(from: Date())
        return "Recording_\(dateString).m4a"
    }

    private func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    private func captureLocationForRecording() {
        // Only capture location if user has enabled location tracking
        guard isLocationTrackingEnabled else {
            print("Location tracking is disabled by user")
            recordingLocation = nil
            return
        }
        
        // Request a fresh location for this recording
        locationManager.requestOneTimeLocation()
        
        // Also start continuous updates if not already running
        if !locationManager.isLocationEnabled {
            locationManager.startLocationUpdates()
        }
        
        // Capture current location if available
        if let location = locationManager.getCurrentLocation() {
            recordingLocation = LocationData(location: location)
            print("Location captured for recording: \(recordingLocation?.coordinateString ?? "Unknown")")
        } else {
            print("No location available for recording, will try to capture during recording")
            recordingLocation = nil
        }
    }
    
    private func saveLocationDataForCurrentRecording(locationData: LocationData) {
        guard let recorder = audioRecorder else { return }
        let locationURL = recorder.url.deletingPathExtension().appendingPathExtension("location")
        
        do {
            let data = try JSONEncoder().encode(locationData)
            try data.write(to: locationURL)
            print("Location data saved to: \(locationURL.path)")
        } catch {
            print("Failed to save location data: \(error)")
        }
    }

    func playRecording(url: URL) {
        // Stop any currently playing audio
        stopPlayback()
        
        // Configure audio session for playback with speaker
        configureAudioSessionForPlayback()
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.play()
            currentlyPlayingURL = url
            isPlaying = true
            startPlaybackTimer()
        } catch {
            print("Error playing recording: \(error)")
        }
    }
    
    func pausePlayback() {
        audioPlayer?.pause()
        isPlaying = false
        stopPlaybackTimer()
    }
    
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        currentlyPlayingURL = nil
        isPlaying = false
        playbackProgress = 0
        stopPlaybackTimer()
    }
    
    private func startPlaybackTimer() {
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, let player = self.audioPlayer else { return }
                self.playbackProgress = player.currentTime
                
                if !player.isPlaying {
                    self.stopPlayback()
                }
            }
        }
    }
    
    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }
    
    func getRecordingDuration(url: URL) -> TimeInterval {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            return player.duration
        } catch {
            print("Error getting duration: \(error)")
            return 0
        }
    }
}

extension AudioRecorderViewModel: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isRecording = false
            self.recordingDuration = 0
            self.stopRecordingTimer()
        }
    }
}

extension AudioRecorderViewModel: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.stopPlayback()
        }
    }
}