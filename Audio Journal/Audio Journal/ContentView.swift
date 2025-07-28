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
import MapKit
import NaturalLanguage

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

enum SummaryMethod: String, CaseIterable {
    case appleIntelligence = "Apple Intelligence (Basic)"
    case localServer = "Local Server (Ollama)"
    case awsBedrock = "AWS Bedrock (Advanced)"
    
    var description: String {
        switch self {
        case .appleIntelligence:
            return "Uses Apple's built-in Natural Language framework for basic summarization"
        case .localServer:
            return "Connect to local Ollama server for enhanced AI processing"
        case .awsBedrock:
            return "Use AWS Bedrock for advanced AI-powered summaries (Coming Soon)"
        }
    }
    
    var isAvailable: Bool {
        switch self {
        case .appleIntelligence, .localServer:
            return true
        case .awsBedrock:
            return false
        }
    }
}



enum TranscriptionEngine: String, CaseIterable {
    case appleIntelligence = "Apple Intelligence (Limited)"
    case awsTranscribe = "AWS Transcribe"
    case whisper = "Whisper (Local Server)"
    case openAIChatGPT = "OpenAI (ChatGPT)"
    case openAIAPICompatible = "OpenAI API Compatible"
    
    var description: String {
        switch self {
        case .appleIntelligence:
            return "Uses Apple's built-in Speech framework for local transcription with 1-minute limit per request"
        case .awsTranscribe:
            return "Cloud-based transcription service with support for long audio files"
        case .whisper:
            return "High-quality transcription using OpenAI's Whisper model via REST API on your local server"
        case .openAIChatGPT:
            return "Advanced AI transcription using OpenAI's Whisper model via ChatGPT API (Coming Soon)"
        case .openAIAPICompatible:
            return "Connect to OpenAI-compatible API endpoints for flexible transcription options (Coming Soon)"
        }
    }
    
    var isAvailable: Bool {
        switch self {
        case .appleIntelligence, .awsTranscribe, .whisper:
            return true
        case .openAIChatGPT, .openAIAPICompatible:
            return false
        }
    }
    
    var requiresConfiguration: Bool {
        switch self {
        case .appleIntelligence:
            return false
        case .awsTranscribe, .whisper, .openAIChatGPT, .openAIAPICompatible:
            return true
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
                .environmentObject(recorderVM)
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
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}

struct RecordingsView: View {
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @StateObject private var importManager = FileImportManager()
    @StateObject private var documentPickerCoordinator = DocumentPickerCoordinator()
    @State private var showingRecordingsList = false
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Spacer()
                
                VStack(spacing: 40) {
                    VStack(spacing: 20) {
                        Image("AppLogo")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: min(geometry.size.height * 0.25, 200))
                            .frame(maxWidth: .infinity)
                            .shadow(color: .accentColor.opacity(0.3), radius: 8, x: 0, y: 4)
                        
                        Text("BisonNotes AI")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                    }
                    .frame(maxWidth: .infinity)
                    
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
                        
                        Button(action: {
                            // Directly trigger document picker for audio files
                            documentPickerCoordinator.selectAudioFiles { urls in
                                if !urls.isEmpty {
                                    Task {
                                        await importManager.importAudioFiles(from: urls)
                                    }
                                }
                            }
                        }) {
                            HStack {
                                Image(systemName: "plus.circle")
                                    .font(.title3)
                                Text("Import Audio Files")
                                    .font(.title3)
                                    .fontWeight(.semibold)
                            }
                            .foregroundColor(.green)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.green, lineWidth: 2)
                                    .background(Color.green.opacity(0.1))
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
                    .environmentObject(recorderVM)
            }
            .sheet(isPresented: $documentPickerCoordinator.isShowingPicker) {
                AudioDocumentPicker(isPresented: $documentPickerCoordinator.isShowingPicker, coordinator: documentPickerCoordinator)
            }
        }
    }
    
    struct RecordingsListView: View {
        @Environment(\.dismiss) private var dismiss
        @EnvironmentObject var recorderVM: AudioRecorderViewModel
        @StateObject private var importManager = FileImportManager()
        @StateObject private var documentPickerCoordinator = DocumentPickerCoordinator()
        @State private var recordings: [RecordingFile] = []
        @State private var selectedLocationData: LocationData?
        @State private var locationAddresses: [URL: String] = [:]
        @State private var showingDocumentPicker = false
        
        var body: some View {
            NavigationView {
                VStack {
                    // Import button
                    HStack {
                        Spacer()
                        Button(action: {
                            documentPickerCoordinator.selectAudioFiles { urls in
                                if !urls.isEmpty {
                                    Task {
                                        await importManager.importAudioFiles(from: urls)
                                        loadRecordings() // Reload recordings after import
                                    }
                                }
                            }
                        }) {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                Text("Import Audio Files")
                            }
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.accentColor)
                            .cornerRadius(8)
                        }
                        .disabled(importManager.isImporting)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    
                    // Import progress
                    if importManager.isImporting {
                        VStack(spacing: 8) {
                            ProgressView(value: importManager.importProgress)
                                .progressViewStyle(LinearProgressViewStyle())
                                .padding(.horizontal, 20)
                            
                            Text(importManager.progressText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 10)
                    }
                    
                    if recordings.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "waveform")
                                .font(.system(size: 60))
                                .foregroundColor(.secondary)
                            
                            Text("No Recordings")
                                .font(.title2)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                            
                            Text("Start recording or import audio files to see them here")
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
                                                        Text(locationAddresses[recording.url] ?? locationData.coordinateString)
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
                .sheet(isPresented: $documentPickerCoordinator.isShowingPicker) {
                    AudioDocumentPicker(isPresented: $documentPickerCoordinator.isShowingPicker, coordinator: documentPickerCoordinator)
                }
                .alert("Import Complete", isPresented: $importManager.showingImportAlert) {
                    Button("OK") {
                        importManager.importResults = nil
                    }
                } message: {
                    if let results = importManager.importResults {
                        Text(results.summary)
                    }
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
                    .filter { ["m4a", "mp3", "wav"].contains($0.pathExtension.lowercased()) }
                    .compactMap { url -> RecordingFile? in
                        guard let creationDate = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate else { return nil }
                        let duration = recorderVM.getRecordingDuration(url: url)
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
        
        private func showLocationDetails(_ locationData: LocationData) {
            selectedLocationData = locationData
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
}

struct SettingsView: View {
        @EnvironmentObject var recorderVM: AudioRecorderViewModel
        @StateObject private var summaryManager = SummaryManager()
        @StateObject private var transcriptManager = TranscriptManager.shared
        @StateObject private var regenerationManager: SummaryRegenerationManager
        @State private var showingEngineChangePrompt = false
        @State private var previousEngine = ""
        @State private var showingTranscriptionSettings = false
        @State private var showingAISettings = false
        @State private var showingClearSummariesAlert = false
        
        init() {
            let summaryMgr = SummaryManager()
            let transcriptMgr = TranscriptManager.shared
            self._summaryManager = StateObject(wrappedValue: summaryMgr)
            self._transcriptManager = StateObject(wrappedValue: transcriptMgr)
            self._regenerationManager = StateObject(wrappedValue: SummaryRegenerationManager(summaryManager: summaryMgr, transcriptManager: transcriptMgr))
        }
        
        private func microphoneTypeDescription(for portType: AVAudioSession.Port) -> String {
            switch portType {
            case .builtInMic:
                return "Built-in Microphone"
            case .headsetMic:
                return "Headset Microphone"
            case .bluetoothHFP:
                return "Bluetooth Hands-Free"
            case .bluetoothA2DP:
                return "Bluetooth Audio"
            case .bluetoothLE:
                return "Bluetooth Low Energy"
            case .usbAudio:
                return "USB Audio Device"
            case .carAudio:
                return "Car Audio System"
            case .airPlay:
                return "AirPlay Device"
            case .lineIn:
                return "Line Input"
            default:
                return portType.rawValue.capitalized
            }
        }
        
        private func locationStatusDescription() -> String {
            switch recorderVM.locationManager.locationStatus {
            case .notDetermined:
                return "Permission not requested"
            case .denied:
                return "Permission denied"
            case .restricted:
                return "Location restricted"
            case .authorizedWhenInUse:
                return "Authorized when app is in use"
            case .authorizedAlways:
                return "Always authorized"
            @unknown default:
                return "Unknown status"
            }
        }
        
        private func locationStatusIcon() -> some View {
            switch recorderVM.locationManager.locationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                return Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title2)
            case .denied, .restricted:
                return Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.title2)
            case .notDetermined:
                return Image(systemName: "questionmark.circle.fill")
                    .foregroundColor(.orange)
                    .font(.title2)
            @unknown default:
                return Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.orange)
                    .font(.title2)
            }
        }
        
        var body: some View {
            NavigationView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Settings")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                            .padding(.top, 20)
                            .padding(.horizontal, 24)
                        
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Text("Microphone Selection")
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Spacer()
                                Button(action: {
                                    recorderVM.fetchInputs()
                                }) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.title3)
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .padding(.top, 40)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 16)
                            
                            VStack(alignment: .leading, spacing: 8) {
                                if recorderVM.availableInputs.isEmpty {
                                    HStack {
                                        Image(systemName: "exclamationmark.triangle")
                                            .foregroundColor(.orange)
                                        Text("No microphones found.")
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 24)
                                } else {
                                    Picker("Select Microphone", selection: Binding(
                                        get: { recorderVM.selectedInputUID ?? "" },
                                        set: { newValue in
                                            recorderVM.selectedInputUID = newValue.isEmpty ? nil : newValue
                                            recorderVM.setPreferredInput()
                                        }
                                    )) {
                                        ForEach(recorderVM.availableInputs, id: \.uid) { input in
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(input.portName)
                                                    .font(.body)
                                                Text(microphoneTypeDescription(for: input.portType))
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                            .tag(input.uid)
                                        }
                                    }
                                    .pickerStyle(MenuPickerStyle())
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color(.systemGray6))
                                    )
                                    .padding(.horizontal, 24)
                                    
                                    // Show current selection details
                                    if let selectedUID = recorderVM.selectedInputUID,
                                       let selectedInput = recorderVM.availableInputs.first(where: { $0.uid == selectedUID }) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Current: \(selectedInput.portName)")
                                                .font(.caption)
                                                .foregroundColor(.primary)
                                            Text("Type: \(microphoneTypeDescription(for: selectedInput.portType))")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        .padding(.horizontal, 24)
                                        .padding(.top, 8)
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
                                // Location tracking toggle
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Enable Location Tracking")
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        Text("Capture location data with recordings")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Toggle("", isOn: $recorderVM.isLocationTrackingEnabled)
                                        .labelsHidden()
                                }
                                .padding(.horizontal, 24)
                                .padding(.vertical, 12)
                                .background(
                                    Rectangle()
                                        .fill(Color(.systemGray6))
                                        .opacity(0.3)
                                )
                                
                                // Location permission status (only show if location tracking is enabled)
                                if recorderVM.isLocationTrackingEnabled {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text("Location Permission")
                                                    .font(.body)
                                                    .foregroundColor(.primary)
                                                Text(locationStatusDescription())
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                            Spacer()
                                            locationStatusIcon()
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
                                            .opacity(0.2)
                                    )
                                }
                            }
                            
                            // AI Summarization Settings
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    Text("AI Summarization Engine")
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Spacer()
                                }
                                .padding(.top, 40)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 16)
                                
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Image(systemName: "brain.head.profile")
                                            .foregroundColor(.blue)
                                        Text("Configure AI engines for generating summaries, extracting tasks, and identifying reminders")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 24)
                                    
                                    // Show current AI engine
                                    HStack {
                                        Text("Engine:")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Text(recorderVM.selectedAIEngine)
                                            .font(.caption)
                                            .fontWeight(.medium)
                                            .foregroundColor(.primary)
                                        
                                        if AIEngineType.allCases.first(where: { $0.rawValue == recorderVM.selectedAIEngine })?.isComingSoon == true {
                                            Text("(Coming Soon)")
                                                .font(.caption)
                                                .foregroundColor(.orange)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Color.orange.opacity(0.2))
                                                .cornerRadius(3)
                                        }
                                    }
                                    .padding(.horizontal, 24)
                                    
                                    // Show summary count
                                    if summaryManager.enhancedSummaries.count > 0 {
                                        HStack {
                                            Text("Summaries:")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            Text("\(summaryManager.enhancedSummaries.count)")
                                                .font(.caption)
                                                .fontWeight(.medium)
                                                .foregroundColor(.primary)
                                        }
                                        .padding(.horizontal, 24)
                                    }
                                    
                                    Button(action: {
                                        showingAISettings = true
                                    }) {
                                        HStack {
                                            Text("Configure AI Engine")
                                            Spacer()
                                            Image(systemName: "arrow.right")
                                        }
                                        .padding(.horizontal, 24)
                                        .padding(.vertical, 12)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color.blue.opacity(0.1))
                                        )
                                        .foregroundColor(.blue)
                                    }
                                    .padding(.horizontal, 24)
                                }
                            }
                            
                            // Summary Management
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    Text("Summary Management")
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Spacer()
                                }
                                .padding(.top, 40)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 16)
                                
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Image(systemName: "doc.text.magnifyingglass")
                                            .foregroundColor(.green)
                                        Text("Manage your existing summaries, transcripts, and extracted tasks/reminders")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 24)
                                    
                                    // Show current summary count
                                    HStack {
                                        Text("Summaries:")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Text("\(summaryManager.enhancedSummaries.count)")
                                            .font(.caption)
                                            .fontWeight(.medium)
                                            .foregroundColor(.primary)
                                    }
                                    .padding(.horizontal, 24)
                                    
                                    // Show legacy summary count if any
                                    if summaryManager.summaries.count > 0 {
                                        HStack {
                                            Text("Legacy Summaries:")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            Text("\(summaryManager.summaries.count)")
                                                .font(.caption)
                                                .fontWeight(.medium)
                                                .foregroundColor(.primary)
                                        }
                                        .padding(.horizontal, 24)
                                    }
                                    
                                    // Clear all summaries button
                                    if summaryManager.enhancedSummaries.count > 0 || summaryManager.summaries.count > 0 {
                                        Button(action: {
                                            showingClearSummariesAlert = true
                                        }) {
                                            HStack {
                                                Image(systemName: "trash")
                                                Text("Clear All Summaries")
                                            }
                                            .padding(.horizontal, 24)
                                            .padding(.vertical, 12)
                                            .background(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .fill(Color.red.opacity(0.1))
                                            )
                                            .foregroundColor(.red)
                                        }
                                        .padding(.horizontal, 24)
                                    }
                                }
                            }

                            
                            // Transcription Settings
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    Text("Transcription Settings")
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Spacer()
                                }
                                .padding(.top, 40)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 16)
                                
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Image(systemName: "waveform")
                                            .foregroundColor(.purple)
                                        Text("Configure transcription engines, chunking, and processing options")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 24)
                                    
                                    // Show current transcription engine
                                    HStack {
                                        Text("Engine:")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Text(recorderVM.selectedTranscriptionEngine.rawValue)
                                            .font(.caption)
                                            .fontWeight(.medium)
                                            .foregroundColor(.primary)
                                        
                                        if !recorderVM.selectedTranscriptionEngine.isAvailable {
                                            Text("(Coming Soon)")
                                                .font(.caption)
                                                .foregroundColor(.orange)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Color.orange.opacity(0.2))
                                                .cornerRadius(3)
                                        }
                                    }
                                    .padding(.horizontal, 24)
                                    

                                    
                                    Button(action: {
                                        showingTranscriptionSettings = true
                                    }) {
                                        HStack {
                                            Text("Configure Transcription")
                                            Spacer()
                                            Image(systemName: "arrow.right")
                                        }
                                        .padding(.horizontal, 24)
                                        .padding(.vertical, 12)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color.purple.opacity(0.1))
                                        )
                                        .foregroundColor(.purple)
                                    }
                                    .padding(.horizontal, 24)
                                }
                            }
                            
                            
                        }
                        
                        Spacer(minLength: 20)
                    }
                    .background(Color(.systemBackground))
                }
                .navigationTitle("Settings")
                .onAppear {
                    // Configure the managers with the selected AI engine
                    summaryManager.setEngine(recorderVM.selectedAIEngine)
                    regenerationManager.setEngine(recorderVM.selectedAIEngine)
                }
            }
            .alert("Engine Change", isPresented: $showingEngineChangePrompt) {
                Button("Skip") {
                    // Do nothing, just dismiss
                }
                Button("Regenerate") {
                    Task {
                        await regenerationManager.regenerateAllSummaries()
                    }
                }
            } message: {
                Text("You've switched from \(previousEngine) to \(recorderVM.selectedAIEngine). Would you like to regenerate your \(summaryManager.enhancedSummaries.count) existing summaries with the new AI engine?")
            }
            .alert("Regeneration Complete", isPresented: $regenerationManager.showingRegenerationAlert) {
                Button("OK") {
                    regenerationManager.regenerationResults = nil
                }
            } message: {
                if let results = regenerationManager.regenerationResults {
                    Text(results.summary)
                }
            }
            .alert("Clear All Summaries", isPresented: $showingClearSummariesAlert) {
                Button("Cancel", role: .cancel) {
                    // Do nothing, just dismiss
                }
                Button("Clear All", role: .destructive) {
                    clearAllSummaries()
                }
            } message: {
                let totalSummaries = summaryManager.enhancedSummaries.count + summaryManager.summaries.count
                Text("This will permanently delete all \(totalSummaries) summaries, transcripts, and extracted tasks/reminders. This action cannot be undone.")
            }
            .sheet(isPresented: $showingTranscriptionSettings) {
                TranscriptionSettingsView()
                    .environmentObject(recorderVM)
            }
            .sheet(isPresented: $showingAISettings) {
                AISettingsView()
                    .environmentObject(recorderVM)
            }
        }
        
        private func clearAllSummaries() {
            print("🧹 Clearing all summaries and related data...")
            
            // Clear all summaries
            summaryManager.clearAllSummaries()
            
            // Clear all transcripts
            transcriptManager.clearAllTranscripts()
            
            print("✅ All summaries, transcripts, and related data cleared")
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
        @StateObject private var transcriptManager = TranscriptManager.shared
        @StateObject private var enhancedTranscriptionManager = EnhancedTranscriptionManager()
        @State private var recordings: [RecordingFile] = []
        @State private var selectedRecording: RecordingFile?
        @State private var isGeneratingTranscript = false
        @State private var selectedLocationData: LocationData?
        @State private var locationAddresses: [URL: String] = [:]
        @State private var showingTranscriptionCompletionAlert = false
        @State private var completedTranscriptionText = ""
        @State private var isCheckingForCompletions = false
        
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
                                        if transcriptManager.hasTranscript(for: recording.url) {
                                            // Show existing transcript for editing
                                            // This will be handled by the sheet
                                        } else {
                                            // Generate new transcript
                                            generateTranscript(for: recording)
                                        }
                                    }) {
                                        HStack {
                                            if isGeneratingTranscript && selectedRecording?.url == recording.url {
                                                ProgressView()
                                                    .scaleEffect(0.8)
                                                if let progress = enhancedTranscriptionManager.progress {
                                                    Text(progress.formattedProgress)
                                                        .font(.caption2)
                                                }
                                            } else {
                                                Image(systemName: transcriptManager.hasTranscript(for: recording.url) ? "text.bubble.fill" : "text.bubble")
                                                Text(transcriptManager.hasTranscript(for: recording.url) ? "Edit Transcript" : "Generate Transcript")
                                            }
                                        }
                                        .font(.caption)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(transcriptManager.hasTranscript(for: recording.url) ? Color.green : Color.accentColor)
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
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: {
                            Task {
                                isCheckingForCompletions = true
                                await enhancedTranscriptionManager.checkForCompletedTranscriptions()
                                isCheckingForCompletions = false
                            }
                        }) {
                            HStack {
                                if isCheckingForCompletions {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text("Check Status")
                            }
                        }
                        .disabled(isCheckingForCompletions)
                    }
                    
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Add Test Job") {
                            // Add your specific job for testing
                            if let recording = recordings.first {
                                enhancedTranscriptionManager.addJobForTracking(
                                    jobName: "transcription-7AF86DD3-083E-404C-9C4C-532A5C5213DC",
                                    recordingURL: recording.url,
                                    recordingName: recording.name
                                )
                            }
                        }
                        .font(.caption)
                    }
                }
                .onAppear {
                    loadRecordings()
                    setupTranscriptionCompletionCallback()
                }

            }
            .sheet(item: $selectedRecording) { recording in
                if let transcript = transcriptManager.getTranscript(for: recording.url) {
                    EditableTranscriptView(recording: recording, transcript: transcript, transcriptManager: transcriptManager)
                } else {
                    TranscriptDetailView(recording: recording, transcriptText: "")
                }
            }
            .sheet(item: $selectedLocationData) { locationData in
                LocationDetailView(locationData: locationData)
            }
            .alert("Transcription Complete", isPresented: $showingTranscriptionCompletionAlert) {
                Button("OK") {
                    showingTranscriptionCompletionAlert = false
                }
            } message: {
                Text(completedTranscriptionText.isEmpty ? "A background transcription has completed. The transcript is now available for editing." : completedTranscriptionText)
            }
            .alert("Whisper Fallback", isPresented: $enhancedTranscriptionManager.showingWhisperFallbackAlert) {
                Button("OK") {
                    enhancedTranscriptionManager.showingWhisperFallbackAlert = false
                }
            } message: {
                Text(enhancedTranscriptionManager.whisperFallbackMessage)
            }
            
        }
        
        private func loadRecordings() {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            do {
                let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: [.creationDateKey], options: [])
                recordings = fileURLs
                    .filter { ["m4a", "mp3", "wav"].contains($0.pathExtension.lowercased()) }
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
            
            // First request speech recognition permission
            SFSpeechRecognizer.requestAuthorization { authStatus in
                DispatchQueue.main.async {
                    switch authStatus {
                    case .authorized:
                        self.performEnhancedTranscription(for: recording)
                    case .denied, .restricted:
                        self.isGeneratingTranscript = false
                    case .notDetermined:
                        self.isGeneratingTranscript = false
                    @unknown default:
                        self.isGeneratingTranscript = false
                    }
                }
            }
        }
        
        private func performEnhancedTranscription(for recording: RecordingFile) {
            print("🚀 Starting enhanced transcription for: \(recording.name)")
            Task {
                do {
                    let result = try await enhancedTranscriptionManager.transcribeAudioFile(at: recording.url, using: recorderVM.selectedTranscriptionEngine)
                    
                    print("📊 Transcription result: success=\(result.success), textLength=\(result.fullText.count)")
                    
                    if result.success && !result.fullText.isEmpty {
                        print("✅ Creating transcript data...")
                        // Create transcript data
                        let transcriptData = TranscriptData(
                            recordingURL: recording.url,
                            recordingName: recording.name,
                            recordingDate: recording.date,
                            segments: result.segments
                        )
                        
                        // Save the transcript
                        self.transcriptManager.saveTranscript(transcriptData)
                        print("💾 Transcript saved successfully")
                        
                        // Update the selected recording to show the editable view
                        self.selectedRecording = recording
                    } else {
                        print("❌ Transcription failed or returned empty result")
                    }
                } catch {
                    print("❌ Enhanced transcription error: \(error)")
                }
                
                await MainActor.run {
                    self.isGeneratingTranscript = false
                    print("🏁 Transcription process completed")
                }
            }
        }
        
        private func setupTranscriptionCompletionCallback() {
            // Capture the transcription manager for the notification handler
            let transcriptionManager = enhancedTranscriptionManager
            
            // Set up notification listener for updating pending jobs when recordings are renamed
            NotificationCenter.default.addObserver(
                forName: NSNotification.Name("UpdatePendingTranscriptionJobs"),
                object: nil,
                queue: .main
            ) { notification in
                guard let userInfo = notification.userInfo,
                      let oldURL = userInfo["oldURL"] as? URL,
                      let newURL = userInfo["newURL"] as? URL,
                      let newName = userInfo["newName"] as? String else {
                    return
                }
                
                Task { @MainActor in
                    transcriptionManager.updatePendingJobsForRenamedRecording(
                        from: oldURL,
                        to: newURL,
                        newName: newName
                    )
                }
            }
            
            enhancedTranscriptionManager.onTranscriptionCompleted = { result, jobInfo in
                Task { @MainActor in
                    
                    print("🎉 Background transcription completed for: \(jobInfo.recordingName)")
                    print("🔍 Looking for recording with URL: \(jobInfo.recordingURL)")
                    print("📋 Available recordings: \(recordings.count)")
                    for (index, recording) in recordings.enumerated() {
                        print("📋 Recording \(index): \(recording.name) - \(recording.url)")
                    }
                    
                    // Find the recording that matches this transcription
                    if let recording = recordings.first(where: { recording in
                        return recording.url == jobInfo.recordingURL
                    }) {
                        // Create transcript data and save it
                        let transcriptData = TranscriptData(
                            recordingURL: recording.url,
                            recordingName: recording.name,
                            recordingDate: recording.date,
                            segments: result.segments
                        )
                        
                        self.transcriptManager.saveTranscript(transcriptData)
                        print("💾 Background transcript saved for: \(recording.name)")
                        
                        // Show completion alert
                        self.completedTranscriptionText = "Transcription completed for: \(recording.name)"
                        self.showingTranscriptionCompletionAlert = true
                    } else {
                        print("❌ No matching recording found for job: \(jobInfo.recordingName)")
                        print("❌ Job URL: \(jobInfo.recordingURL)")
                        print("❌ Available recording URLs:")
                        for recording in self.recordings {
                            print("❌   - \(recording.url)")
                        }
                    }
                }
            }
        }
        

    }
    
    struct EditableTranscriptView: View {
        let recording: RecordingFile
        let transcript: TranscriptData
        let transcriptManager: TranscriptManager
        @Environment(\.dismiss) private var dismiss
        @State private var locationAddress: String?
        @State private var editedSegments: [TranscriptSegment]
        @State private var speakerMappings: [String: String]
        @State private var showingSpeakerEditor = false
        
        init(recording: RecordingFile, transcript: TranscriptData, transcriptManager: TranscriptManager) {
            self.recording = recording
            self.transcript = transcript
            self.transcriptManager = transcriptManager
            self._editedSegments = State(initialValue: transcript.segments)
            self._speakerMappings = State(initialValue: transcript.speakerMappings)
        }
        
        var body: some View {
            NavigationView {
                VStack(spacing: 0) {
                    // Speaker Management Section - Compact
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Speakers")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                            
                            // Show speaker count
                            Text("(\(speakerMappings.keys.count))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            Button("Edit") {
                                showingSpeakerEditor = true
                            }
                            .font(.caption)
                            .foregroundColor(.accentColor)
                        }
                        
                        // Compact speaker display
                        if !speakerMappings.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(Array(speakerMappings.keys.sorted()), id: \.self) { speakerKey in
                                        Text(speakerMappings[speakerKey] ?? speakerKey)
                                            .font(.caption)
                                            .foregroundColor(.primary)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.accentColor.opacity(0.2))
                                            .cornerRadius(6)
                                    }
                                }
                                .padding(.horizontal, 1)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color(.systemGray6).opacity(0.5))
                    
                    // Transcript Content
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(editedSegments.indices, id: \.self) { index in
                                TranscriptSegmentView(
                                    segment: $editedSegments[index],
                                    speakerName: speakerMappings[editedSegments[index].speaker] ?? editedSegments[index].speaker
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Edit Transcript")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Save") {
                            saveTranscript()
                            dismiss()
                        }
                        .fontWeight(.semibold)
                    }
                }
                .sheet(isPresented: $showingSpeakerEditor) {
                    SpeakerEditorView(speakerMappings: $speakerMappings)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        
        private func saveTranscript() {
            let updatedTranscript = transcript.updatedTranscript(
                segments: editedSegments,
                speakerMappings: speakerMappings
            )
            transcriptManager.updateTranscript(updatedTranscript)
        }
    }
    
    struct TranscriptSegmentView: View {
        @Binding var segment: TranscriptSegment
        let speakerName: String
        
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(speakerName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.accentColor)
                        .cornerRadius(8)
                    
                    Spacer()
                    
                    Text(formatTime(segment.startTime))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.systemGray5))
                        .cornerRadius(6)
                }
                
                TextEditor(text: Binding(
                    get: { segment.text },
                    set: { segment = TranscriptSegment(speaker: segment.speaker, text: $0, startTime: segment.startTime, endTime: segment.endTime) }
                ))
                .font(.body)
                .frame(minHeight: max(120, calculateTextHeight(for: segment.text)))
                .padding(12)
                .background(Color(.systemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(.systemGray4), lineWidth: 1)
                )
                .cornerRadius(10)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background(Color(.systemGray6).opacity(0.3))
            .cornerRadius(12)
        }
        
        private func formatTime(_ time: TimeInterval) -> String {
            let minutes = Int(time) / 60
            let seconds = Int(time) % 60
            return String(format: "%d:%02d", minutes, seconds)
        }
        
        private func calculateTextHeight(for text: String) -> CGFloat {
            // More accurate height calculation
            let lineHeight: CGFloat = 22 // Body font line height
            let charactersPerLine: CGFloat = 60 // Characters per line (adjusted for wider view)
            
            // Count explicit line breaks
            let explicitLines = CGFloat(text.components(separatedBy: "\n").count)
            
            // Estimate wrapped lines
            let wrappedLines = max(1, ceil(CGFloat(text.count) / charactersPerLine))
            
            // Use the larger of the two estimates
            let totalLines = max(explicitLines, wrappedLines)
            
            // Calculate height with padding
            let calculatedHeight = totalLines * lineHeight + 24 // 24pt for padding
            
            // Ensure reasonable bounds
            return max(120, min(calculatedHeight, 400))
        }
    }
    
    struct SpeakerEditorView: View {
        @Binding var speakerMappings: [String: String]
        @Environment(\.dismiss) private var dismiss
        @State private var tempMappings: [String: String] = [:]
        
        var body: some View {
            NavigationView {
                VStack {
                    List {
                        ForEach(Array(speakerMappings.keys.sorted()), id: \.self) { speakerKey in
                            HStack {
                                Text(speakerKey)
                                    .font(.body)
                                    .foregroundColor(.primary)
                                
                                Spacer()
                                
                                TextField("Enter name", text: Binding(
                                    get: { tempMappings[speakerKey] ?? "" },
                                    set: { tempMappings[speakerKey] = $0 }
                                ))
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .frame(width: 150)
                            }
                        }
                    }
                }
                .navigationTitle("Edit Speakers")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Save") {
                            speakerMappings = tempMappings
                            dismiss()
                        }
                        .fontWeight(.semibold)
                    }
                }
                .onAppear {
                    tempMappings = speakerMappings
                }
            }
        }
    }
    
    struct TranscriptDetailView: View {
        let recording: RecordingFile
        let transcriptText: String
        @Environment(\.dismiss) private var dismiss
        @State private var locationAddress: String?
        
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
                                        Text(locationAddress ?? locationData.coordinateString)
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
                .onAppear {
                    if let locationData = recording.locationData {
                        let location = CLLocation(latitude: locationData.latitude, longitude: locationData.longitude)
                        let tempLocationManager = LocationManager()
                        tempLocationManager.reverseGeocodeLocation(location) { address in
                            if let address = address {
                                locationAddress = address
                            }
                        }
                    }
                }
            }
        }
    }
