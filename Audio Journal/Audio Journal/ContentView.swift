//
//  ContentView.swift
//  Audio Journal
//
//  Created by Tim Champ on 7/26/25.
//

import SwiftUI
import AVFoundation
import Speech // Added for speech recognition
import CoreLocation

enum AudioQuality: String, CaseIterable {
    case low = "Low Quality"
    case medium = "Medium Quality"
    case high = "High Quality"
    
    var settings: [String: Any] {
        switch self {
        case .low:
            return [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 22050,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
                AVEncoderBitRateKey: 64000
            ]
        case .medium:
            return [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                AVEncoderBitRateKey: 128000
            ]
        case .high:
            return [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                AVEncoderBitRateKey: 256000
            ]
        }
    }
    
    var description: String {
        switch self {
        case .low:
            return "64 kbps, 22.05 kHz - Good for voice, smaller files"
        case .medium:
            return "128 kbps, 44.1 kHz - Balanced quality and file size"
        case .high:
            return "256 kbps, 48 kHz - High fidelity, larger files"
        }
    }
}

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
        
        // Initialize location manager
        locationManager.requestLocationPermission()
        
        // Create test recordings if they don't exist
        createTestRecordingsIfNeeded()
    }
    
    private func createTestRecordingsIfNeeded() {
        let documentsPath = getDocumentsDirectory()
        let testRecording1URL = documentsPath.appendingPathComponent("John_Doe_NYC_Times_Square.m4a")
        let testRecording2URL = documentsPath.appendingPathComponent("John_Doe_NYC_Empire_State.m4a")
        
        // Check if test recordings already exist
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: testRecording1URL.path) {
            createTestRecording1(at: testRecording1URL)
        }
        if !fileManager.fileExists(atPath: testRecording2URL.path) {
            createTestRecording2(at: testRecording2URL)
        }
    }
    
    func recreateTestRecordings() {
        let documentsPath = getDocumentsDirectory()
        let testRecording1URL = documentsPath.appendingPathComponent("John_Doe_NYC_Times_Square.m4a")
        let testRecording2URL = documentsPath.appendingPathComponent("John_Doe_NYC_Empire_State.m4a")
        
        // Remove existing test recordings
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: testRecording1URL)
        try? fileManager.removeItem(at: testRecording2URL)
        
        // Also remove associated location files
        let location1URL = testRecording1URL.deletingPathExtension().appendingPathExtension("location")
        let location2URL = testRecording2URL.deletingPathExtension().appendingPathExtension("location")
        try? fileManager.removeItem(at: location1URL)
        try? fileManager.removeItem(at: location2URL)
        
        // Create new test recordings
        createTestRecording1(at: testRecording1URL)
        createTestRecording2(at: testRecording2URL)
    }
    
    private func createTestRecording1(at url: URL) {
        // Create a longer test audio file with speech-like content
        let sampleRate: Double = 44100
        let duration: Double = 8.0 // 8 seconds
        let frequency: Double = 220.0 // Lower frequency for more speech-like sound
        
        let audioFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let audioFile = try! AVAudioFile(forWriting: url, settings: audioFormat.settings)
        
        let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(sampleRate * duration))!
        
        // Generate a more complex waveform to simulate speech
        for frame in 0..<Int(sampleRate * duration) {
            let time = Double(frame) / sampleRate
            let baseFreq = frequency + 50.0 * sin(2.0 * Double.pi * 0.5 * time) // Varying frequency
            let sample = sin(2.0 * Double.pi * baseFreq * time) * 0.25 * (1.0 - 0.5 * sin(2.0 * Double.pi * 2.0 * time))
            buffer.floatChannelData![0][frame] = Float(sample)
        }
        
        buffer.frameLength = AVAudioFrameCount(sampleRate * duration)
        
        try! audioFile.write(from: buffer)
        
        // Create location data for downtown NYC
        let nycLocation = CLLocation(latitude: 40.7589, longitude: -73.9851) // Times Square area
        let locationData = LocationData(location: nycLocation)
        saveLocationDataForRecording(url: url, locationData: locationData)
    }
    
    private func createTestRecording2(at url: URL) {
        // Create another longer test audio file with different speech-like content
        let sampleRate: Double = 44100
        let duration: Double = 10.0 // 10 seconds
        let frequency: Double = 200.0 // Different base frequency
        
        let audioFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let audioFile = try! AVAudioFile(forWriting: url, settings: audioFormat.settings)
        
        let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(sampleRate * duration))!
        
        // Generate a more complex waveform with pauses to simulate speech
        for frame in 0..<Int(sampleRate * duration) {
            let time = Double(frame) / sampleRate
            let baseFreq = frequency + 60.0 * sin(2.0 * Double.pi * 0.3 * time) // Different variation
            let amplitude = 0.3 * (1.0 - 0.6 * sin(2.0 * Double.pi * 1.5 * time))
            let sample = sin(2.0 * Double.pi * baseFreq * time) * amplitude
            buffer.floatChannelData![0][frame] = Float(sample)
        }
        
        buffer.frameLength = AVAudioFrameCount(sampleRate * duration)
        
        try! audioFile.write(from: buffer)
        
        // Create location data for downtown NYC (different location)
        let nycLocation = CLLocation(latitude: 40.7484, longitude: -73.9857) // Empire State Building area
        let locationData = LocationData(location: nycLocation)
        saveLocationDataForRecording(url: url, locationData: locationData)
    }
    
    private func saveLocationDataForRecording(url: URL, locationData: LocationData) {
        let locationURL = url.deletingPathExtension().appendingPathExtension("location")
        
        do {
            let data = try JSONEncoder().encode(locationData)
            try data.write(to: locationURL)
            print("Test recording location data saved to: \(locationURL.path)")
        } catch {
            print("Failed to save test recording location data: \(error)")
        }
    }

    func fetchInputs() {
        do {
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
            availableInputs = session.availableInputs ?? []
        } catch {
            print("Failed to fetch audio inputs: \(error)")
        }
    }

    func setPreferredInput() {
        guard let uid = selectedInputUID,
              let input = availableInputs.first(where: { $0.uid == uid }) else { return }
        do {
            try session.setPreferredInput(input)
        } catch {
            print("Failed to set preferred input: \(error)")
        }
    }

    func startRecording() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if granted {
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
        // Start location updates if not already running
        if !locationManager.isLocationEnabled {
            locationManager.startLocationUpdates()
        }
        
        // Capture current location
        if let location = locationManager.getCurrentLocation() {
            recordingLocation = LocationData(location: location)
            print("Location captured for recording: \(recordingLocation?.coordinateString ?? "Unknown")")
        } else {
            print("No location available for recording")
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

struct ContentView: View {
    @StateObject private var recorderVM = AudioRecorderViewModel()
    var body: some View {
        TabView {
            RecordingsView()
                .environmentObject(recorderVM)
                .tabItem {
                    Image(systemName: "mic.fill")
                    Text("Record")
                }
            SummariesView()
                .tabItem {
                    Image(systemName: "doc.text.magnifyingglass")
                    Text("Summaries")
                }
            TranscriptsView()
                .environmentObject(recorderVM)
                .tabItem {
                    Image(systemName: "text.bubble.fill")
                    Text("Transcripts")
                }
            SettingsView()
                .environmentObject(recorderVM)
                .tabItem {
                    Image(systemName: "gearshape.fill")
                    Text("Settings")
                }
        }
        .preferredColorScheme(.dark)
    }
}

struct RecordingsView: View {
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @State private var showingRecordingsList = false
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 40) {
                VStack(spacing: 20) {
                    Image("AppLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: geometry.size.height * 0.33)
                        .frame(maxWidth: .infinity)
                        .shadow(color: .accentColor.opacity(0.3), radius: 8, x: 0, y: 4)
                    
                    Text("BisonNotes AI")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 0)
                
                VStack(spacing: 16) {
                    if recorderVM.isRecording {
                        Text(recorderVM.formatDuration(recorderVM.recordingDuration))
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundColor(.accentColor)
                            .monospacedDigit()
                    }
                    
                    Button(action: {
                        if recorderVM.isRecording {
                            recorderVM.stopRecording()
                        } else {
                            recorderVM.startRecording()
                        }
                    }) {
                        HStack {
                            Image(systemName: recorderVM.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                                .font(.title)
                            Text(recorderVM.isRecording ? "Stop Recording" : "Start Recording")
                                .font(.title2)
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(recorderVM.isRecording ? Color.red : Color.accentColor)
                                .shadow(color: recorderVM.isRecording ? .red.opacity(0.3) : .accentColor.opacity(0.3), radius: 8, x: 0, y: 4)
                        )
                        .padding(.horizontal, 40)
                    }
                    .scaleEffect(recorderVM.isRecording ? 1.05 : 1.0)
                    .animation(.easeInOut(duration: 0.2), value: recorderVM.isRecording)
                    
                    Button(action: {
                        showingRecordingsList = true
                    }) {
                        HStack {
                            Image(systemName: "list.bullet")
                                .font(.title3)
                            Text("View Recordings")
                                .font(.title3)
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.accentColor)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.accentColor, lineWidth: 2)
                                .background(Color.accentColor.opacity(0.1))
                        )
                        .padding(.horizontal, 40)
                    }
                    
                    if recorderVM.isRecording {
                        VStack(spacing: 8) {
                            HStack {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 12, height: 12)
                                    .scaleEffect(recorderVM.isRecording ? 1.2 : 1.0)
                                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: recorderVM.isRecording)
                                Text("Recording...")
                                    .foregroundColor(.secondary)
                                    .font(.subheadline)
                            }
                            
                            if let locationData = recorderVM.recordingLocation {
                                HStack {
                                    Image(systemName: "location.fill")
                                        .font(.caption)
                                        .foregroundColor(.accentColor)
                                    Text("Location captured: \(locationData.coordinateString)")
                                        .font(.caption)
                                        .foregroundColor(.accentColor)
                                }
                            } else if recorderVM.locationManager.locationError != nil {
                                HStack {
                                    Image(systemName: "location.slash")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                    Text("Location unavailable")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                    }
                }
                
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
        }
        .sheet(isPresented: $showingRecordingsList) {
            RecordingsListView()
        }
    }
}

struct RecordingsListView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @State private var recordings: [RecordingFile] = []
    @State private var selectedLocationData: LocationData?
    
    var body: some View {
        NavigationView {
            VStack {
                if recordings.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "waveform")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)
                        
                        Text("No Recordings")
                            .font(.title2)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        
                        Text("Start recording to see your audio files here")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(recordings) { recording in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(recording.name)
                                            .font(.headline)
                                            .foregroundColor(.primary)
                                        HStack {
                                            Text(recording.dateString)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            Text("•")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            Text(recording.durationString)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        if let locationData = recording.locationData {
                                            Button(action: {
                                                // Show location details
                                                showLocationDetails(locationData)
                                            }) {
                                                HStack {
                                                    Image(systemName: "location.fill")
                                                        .font(.caption2)
                                                        .foregroundColor(.accentColor)
                                                    Text(locationData.coordinateString)
                                                        .font(.caption2)
                                                        .foregroundColor(.accentColor)
                                                }
                                            }
                                            .buttonStyle(PlainButtonStyle())
                                        }
                                    }
                                    Spacer()
                                    HStack(spacing: 12) {
                                        Button(action: {
                                            if recorderVM.currentlyPlayingURL == recording.url && recorderVM.isPlaying {
                                                recorderVM.pausePlayback()
                                            } else if recorderVM.currentlyPlayingURL == recording.url {
                                                recorderVM.playRecording(url: recording.url)
                                            } else {
                                                recorderVM.playRecording(url: recording.url)
                                            }
                                        }) {
                                            Image(systemName: recorderVM.currentlyPlayingURL == recording.url ? (recorderVM.isPlaying ? "pause.circle.fill" : "play.circle.fill") : "play.circle.fill")
                                                .foregroundColor(recorderVM.currentlyPlayingURL == recording.url ? (recorderVM.isPlaying ? .red : .green) : .accentColor)
                                                .font(.title2)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        
                                        Button(action: {
                                            deleteRecording(recording)
                                        }) {
                                            Image(systemName: "trash")
                                                .foregroundColor(.red)
                                                .font(.title3)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Recordings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        recorderVM.stopPlayback()
                        dismiss()
                    }
                }
            }
            .sheet(item: $selectedLocationData) { locationData in
                LocationDetailView(locationData: locationData)
            }
        }
        .onAppear {
            loadRecordings()
        }
    }
    
    private func loadRecordings() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: [.creationDateKey], options: [])
            recordings = fileURLs
                .filter { $0.pathExtension == "m4a" }
                .compactMap { url -> RecordingFile? in
                    guard let creationDate = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate else { return nil }
                    let duration = recorderVM.getRecordingDuration(url: url)
                    let locationData = loadLocationDataForRecording(url: url)
                    return RecordingFile(url: url, name: url.deletingPathExtension().lastPathComponent, date: creationDate, duration: duration, locationData: locationData)
                }
                .sorted { $0.date > $1.date }
        } catch {
            print("Error loading recordings: \(error)")
        }
    }
    
    private func loadLocationDataForRecording(url: URL) -> LocationData? {
        let locationURL = url.deletingPathExtension().appendingPathExtension("location")
        guard let data = try? Data(contentsOf: locationURL),
              let locationData = try? JSONDecoder().decode(LocationData.self, from: data) else {
            return nil
        }
        return locationData
    }
    
    private func showLocationDetails(_ locationData: LocationData) {
        selectedLocationData = locationData
    }
    
    private func deleteRecording(_ recording: RecordingFile) {
        // Stop playback if this recording is currently playing
        if recorderVM.currentlyPlayingURL == recording.url {
            recorderVM.stopPlayback()
        }
        
        do {
            // Delete the audio file
            try FileManager.default.removeItem(at: recording.url)
            
            // Delete the associated location file if it exists
            let locationURL = recording.url.deletingPathExtension().appendingPathExtension("location")
            if FileManager.default.fileExists(atPath: locationURL.path) {
                try FileManager.default.removeItem(at: locationURL)
            }
            
            loadRecordings() // Reload the list
        } catch {
            print("Error deleting recording: \(error)")
        }
    }
}

struct SummariesView: View {
    var body: some View {
        VStack {
            Text("Summaries")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundColor(.primary)
                .padding(.top, 100)
            
            VStack(spacing: 16) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 60))
                    .foregroundColor(.secondary)
                
                Text("Coming Soon")
                    .font(.title2)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                
                Text("AI-powered summaries of your recordings will appear here")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

struct SettingsView: View {
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                    .padding(.top, 20)
                    .padding(.horizontal, 24)
                
                VStack(alignment: .leading, spacing: 0) {
                    Text("Microphone Selection")
                        .font(.headline)
                        .foregroundColor(.primary)
                        .padding(.top, 40)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                    
                    if recorderVM.availableInputs.isEmpty {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                            Text("No microphones found.")
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 24)
                    } else {
                        ForEach(recorderVM.availableInputs, id: \.uid) { input in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(input.portName)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    Text(input.portType.rawValue)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if recorderVM.selectedInputUID == input.uid {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.accentColor)
                                        .font(.title2)
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(
                                Rectangle()
                                    .fill(Color(.systemGray6))
                                    .opacity(recorderVM.selectedInputUID == input.uid ? 0.3 : 0.1)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    recorderVM.selectedInputUID = input.uid
                                    recorderVM.setPreferredInput()
                                }
                            }
                        }
                    }
                    
                    Text("Audio Quality")
                        .font(.headline)
                        .foregroundColor(.primary)
                        .padding(.top, 40)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                    
                    ForEach(AudioQuality.allCases, id: \.self) { quality in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(quality.rawValue)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    Text(quality.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if recorderVM.selectedQuality == quality {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.accentColor)
                                        .font(.title2)
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(
                            Rectangle()
                                .fill(Color(.systemGray6))
                                .opacity(recorderVM.selectedQuality == quality ? 0.3 : 0.1)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                recorderVM.selectedQuality = quality
                            }
                        }
                    }
                    
                    Text("Location Services")
                        .font(.headline)
                        .foregroundColor(.primary)
                        .padding(.top, 40)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Location Access")
                                    .font(.body)
                                    .foregroundColor(.primary)
                                Text("Capture location when recording")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if recorderVM.locationManager.isLocationEnabled {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.title2)
                            } else {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                                    .font(.title2)
                            }
                        }
                        
                        if let error = recorderVM.locationManager.locationError {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                                .padding(.top, 4)
                        }
                        
                        if recorderVM.locationManager.locationStatus == .denied || recorderVM.locationManager.locationStatus == .restricted {
                            Button(action: {
                                if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(settingsUrl)
                                }
                            }) {
                                Text("Open Settings")
                                    .font(.caption)
                                    .foregroundColor(.accentColor)
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(
                        Rectangle()
                            .fill(Color(.systemGray6))
                            .opacity(0.3)
                    )
                    
                    Text("Test Recordings")
                        .font(.headline)
                        .foregroundColor(.primary)
                        .padding(.top, 40)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                    
                    Button(action: {
                        recorderVM.recreateTestRecordings()
                    }) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                                .font(.body)
                            Text("Recreate Test Recordings")
                                .font(.body)
                                .foregroundColor(.primary)
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(
                            Rectangle()
                                .fill(Color(.systemGray6))
                                .opacity(0.3)
                        )
                        .contentShape(Rectangle())
                    }
                }
                
                Spacer()
            }
            .background(Color(.systemBackground))
        }
        .onAppear {
            recorderVM.fetchInputs()
        }
    }
}

private let itemFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter
}()

#Preview {
    ContentView()
}

struct TranscriptsView: View {
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @State private var recordings: [RecordingFile] = []
    @State private var selectedRecording: RecordingFile?
    @State private var isGeneratingTranscript = false
    @State private var transcriptText = ""
    @State private var selectedLocationData: LocationData?
    @State private var locationAddresses: [URL: String] = [:]
    
    var body: some View {
        NavigationView {
            VStack {
                if recordings.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)
                        
                        Text("No Recordings Found")
                            .font(.title2)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        
                        Text("Record some audio first to generate transcripts")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(recordings, id: \.url) { recording in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(recording.name)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Text(recording.dateString)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    if let locationData = recording.locationData {
                                        Button(action: {
                                            selectedLocationData = locationData
                                        }) {
                                            HStack {
                                                Image(systemName: "location.fill")
                                                    .font(.caption2)
                                                    .foregroundColor(.accentColor)
                                                Text(locationAddresses[recording.url] ?? locationData.coordinateString)
                                                    .font(.caption2)
                                                    .foregroundColor(.accentColor)
                                            }
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                    }
                                }
                                Spacer()
                                Button(action: {
                                    selectedRecording = recording
                                    generateTranscript(for: recording)
                                }) {
                                    HStack {
                                        if isGeneratingTranscript && selectedRecording?.url == recording.url {
                                            ProgressView()
                                                .scaleEffect(0.8)
                                        } else {
                                            Image(systemName: "text.bubble")
                                        }
                                        Text("Transcript")
                                    }
                                    .font(.caption)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.accentColor)
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                                }
                                .disabled(isGeneratingTranscript)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Transcripts")
            .onAppear {
                loadRecordings()
            }
        }
        .sheet(item: $selectedRecording) { recording in
            TranscriptDetailView(recording: recording, transcriptText: transcriptText)
        }
        .sheet(item: $selectedLocationData) { locationData in
            LocationDetailView(locationData: locationData)
        }
    }
    
    private func loadRecordings() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: [.creationDateKey], options: [])
            recordings = fileURLs
                .filter { $0.pathExtension == "m4a" }
                .compactMap { url -> RecordingFile? in
                    guard let creationDate = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate else { return nil }
                    let duration = getRecordingDuration(url: url)
                    let locationData = loadLocationDataForRecording(url: url)
                    return RecordingFile(url: url, name: url.deletingPathExtension().lastPathComponent, date: creationDate, duration: duration, locationData: locationData)
                }
                .sorted { $0.date > $1.date }
            
            // Geocode locations for all recordings
            for recording in recordings {
                geocodeLocationForRecording(recording)
            }
        } catch {
            print("Error loading recordings: \(error)")
        }
    }
    
    private func loadLocationDataForRecording(url: URL) -> LocationData? {
        let locationURL = url.deletingPathExtension().appendingPathExtension("location")
        guard let data = try? Data(contentsOf: locationURL),
              let locationData = try? JSONDecoder().decode(LocationData.self, from: data) else {
            return nil
        }
        return locationData
    }
    
    private func geocodeLocationForRecording(_ recording: RecordingFile) {
        guard let locationData = recording.locationData else { return }
        
        let location = CLLocation(latitude: locationData.latitude, longitude: locationData.longitude)
        recorderVM.locationManager.reverseGeocodeLocation(location) { address in
            if let address = address {
                locationAddresses[recording.url] = address
            }
        }
    }
    
    private func getRecordingDuration(url: URL) -> TimeInterval {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            return player.duration
        } catch {
            print("Error getting duration: \(error)")
            return 0
        }
    }
    
    private func generateTranscript(for recording: RecordingFile) {
        isGeneratingTranscript = true
        transcriptText = ""
        
        // First request speech recognition permission
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                switch authStatus {
                case .authorized:
                    self.performSpeechRecognition(for: recording)
                case .denied, .restricted:
                    self.transcriptText = "Speech recognition permission denied. Please enable it in Settings."
                    self.isGeneratingTranscript = false
                case .notDetermined:
                    self.transcriptText = "Speech recognition permission not determined."
                    self.isGeneratingTranscript = false
                @unknown default:
                    self.transcriptText = "Speech recognition permission unknown."
                    self.isGeneratingTranscript = false
                }
            }
        }
    }
    
    private func performSpeechRecognition(for recording: RecordingFile) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            transcriptText = "Speech recognition not available for this locale."
            isGeneratingTranscript = false
            return
        }
        
        // Ensure the file is accessible
        guard FileManager.default.fileExists(atPath: recording.url.path) else {
            transcriptText = "Audio file not found."
            isGeneratingTranscript = false
            return
        }
        
        let request = SFSpeechURLRecognitionRequest(url: recording.url)
        request.shouldReportPartialResults = false
        
        recognizer.recognitionTask(with: request) { result, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("Speech recognition error: \(error)")
                    let errorMessage: String
                    
                    if let nsError = error as NSError? {
                        switch nsError.code {
                        case 203: // Audio engine error
                            errorMessage = "Audio engine error. Please try again."
                        case 201: // Invalid audio format
                            errorMessage = "Invalid audio format. Please try a different recording."
                        case 202: // Not available for current locale
                            errorMessage = "Speech recognition not available for current locale."
                        case 204: // Server connection error
                            errorMessage = "Server connection error. Please check your internet connection."
                        default:
                            errorMessage = "Speech recognition error: \(error.localizedDescription)"
                        }
                    } else {
                        errorMessage = "Error generating transcript: \(error.localizedDescription)"
                    }
                    
                    self.transcriptText = errorMessage
                } else if let result = result {
                    if result.isFinal {
                        self.transcriptText = result.bestTranscription.formattedString
                        if self.transcriptText.isEmpty {
                            self.transcriptText = "No speech detected in this recording."
                        }
                    }
                }
                self.isGeneratingTranscript = false
            }
        }
    }
}

struct RecordingFile: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let date: Date
    let duration: TimeInterval
    let locationData: LocationData?
    
    var dateString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    var durationString: String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        let seconds = Int(duration) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

struct TranscriptDetailView: View {
    let recording: RecordingFile
    let transcriptText: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack {
                if transcriptText.isEmpty {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Generating transcript...")
                            .font(.headline)
                            .foregroundColor(.primary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(recording.name)
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.primary)
                            
                            Text(recording.dateString)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            if let locationData = recording.locationData {
                                HStack {
                                    Image(systemName: "location.fill")
                                        .font(.caption)
                                        .foregroundColor(.accentColor)
                                    Text(locationData.coordinateString)
                                        .font(.caption)
                                        .foregroundColor(.accentColor)
                                }
                            }
                            
                            Divider()
                            
                            Text(transcriptText)
                                .font(.body)
                                .foregroundColor(.primary)
                                .lineSpacing(4)
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Transcript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
