//
//  TranscriptViews.swift
//  Audio Journal
//
//  Created by Tim Champ on 7/28/25.
//

import SwiftUI
import AVFoundation
import Speech
import CoreLocation

struct TranscriptsView: View {
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @EnvironmentObject var appCoordinator: AppDataCoordinator
    @StateObject private var enhancedTranscriptionManager = EnhancedTranscriptionManager()
    @StateObject private var backgroundProcessingManager = BackgroundProcessingManager.shared
    @State private var recordings: [(recording: RegistryRecordingEntry, transcript: TranscriptData?)] = []
    @State private var selectedRecording: RegistryRecordingEntry?
    @State private var isGeneratingTranscript = false
    @State private var selectedLocationData: LocationData?
    @State private var locationAddresses: [URL: String] = [:]
    @State private var showingTranscriptionCompletionAlert = false
    @State private var completedTranscriptionText = ""
    @State private var isCheckingForCompletions = false
    @State private var refreshTrigger = false
    @State private var showingTranscriptionProgress = false
    @AppStorage("showTranscriptionProgress") private var showTranscriptionProgress: Bool = true
    @State private var refreshTimer: Timer?
    @State private var isShowingAlert = false
    
    var body: some View {
        NavigationView {
            mainContentView
        }
        .sheet(item: $selectedRecording) { recording in
            if let transcript = TranscriptManager.shared.getTranscript(for: recording.recordingURL) {
                EditableTranscriptView(recording: recording, transcript: transcript, transcriptManager: TranscriptManager.shared)
            } else {
                TranscriptDetailView(recording: recording, transcriptText: "")
            }
        }
        .sheet(item: $selectedLocationData) { locationData in
            LocationDetailView(locationData: locationData)
        }
        .sheet(isPresented: $showingTranscriptionProgress) {
            if let progress = enhancedTranscriptionManager.progress {
                TranscriptionProgressView(
                    progress: progress,
                    status: enhancedTranscriptionManager.currentStatus,
                    onCancel: {
                        enhancedTranscriptionManager.cancelTranscription()
                        showingTranscriptionProgress = false
                        isGeneratingTranscript = false
                    },
                    onDone: {
                        showingTranscriptionProgress = false
                        // Transcription continues in background
                    }
                )
            }
        }
        .onDisappear {
            // Ensure transcription progress sheet is dismissed when view disappears
            if showingTranscriptionProgress {
                showingTranscriptionProgress = false
            }
        }
        .alert("Transcription Complete", isPresented: $showingTranscriptionCompletionAlert) {
            Button("OK") {
                showingTranscriptionCompletionAlert = false
                isShowingAlert = false
            }
        } message: {
            Text(completedTranscriptionText.isEmpty ? "A background transcription has completed. The transcript is now available for editing." : completedTranscriptionText)
        }
        .onChange(of: showingTranscriptionCompletionAlert) { _, newValue in
            isShowingAlert = newValue
        }
        .alert("Whisper Fallback", isPresented: $enhancedTranscriptionManager.showingWhisperFallbackAlert) {
            Button("OK") {
                enhancedTranscriptionManager.showingWhisperFallbackAlert = false
            }
        } message: {
            Text(enhancedTranscriptionManager.whisperFallbackMessage)
        }
    }
    
    private var mainContentView: some View {
        VStack {
            if recordings.isEmpty {
                emptyStateView
            } else {
                recordingsListView
            }
        }
        .navigationTitle("Transcripts")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    isCheckingForCompletions = true
                    Task {
                        await enhancedTranscriptionManager.checkForCompletedTranscriptions()
                        await MainActor.run {
                            isCheckingForCompletions = false
                        }
                    }
                }) {
                    HStack {
                        if isCheckingForCompletions {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                        Text("Check Status")
                    }
                }
                .disabled(isCheckingForCompletions)
            }
        }
        .onAppear {
            loadRecordings()
            setupTranscriptionCompletionCallback()
            // Force UI refresh to ensure transcript states are properly displayed
            DispatchQueue.main.async {
                self.refreshTrigger.toggle()
            }
            
            // Start periodic refresh timer
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
                DispatchQueue.main.async {
                    self.loadRecordings()
                }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RecordingRenamed"))) { _ in
            // Refresh recordings list when a recording is renamed
            print("🔄 TranscriptViews: Received recording renamed notification, refreshing list")
            loadRecordings()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TranscriptionCompleted"))) { _ in
            // Refresh recordings list when transcription completes
            print("🔄 TranscriptViews: Received transcription completed notification, refreshing list")
            DispatchQueue.main.async {
                self.loadRecordings()
                self.refreshTrigger.toggle()
            }
        }
    }
    
    private var emptyStateView: some View {
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
    }
    
    private var recordingsListView: some View {
        List {
            ForEach(recordings, id: \.recording.id) { recordingData in
                recordingRowView(recordingData)
            }
        }
    }
    
    private func recordingRowView(_ recordingData: (recording: RegistryRecordingEntry, transcript: TranscriptData?)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                recordingInfoView(recordingData)
                Spacer()
                transcriptButtonView(recordingData)
            }
        }
        .padding(.vertical, 4)
    }
    
    private func recordingInfoView(_ recordingData: (recording: RegistryRecordingEntry, transcript: TranscriptData?)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recordingData.recording.recordingName)
                .font(.headline)
                .foregroundColor(.primary)
            Text(recordingData.recording.recordingDate, style: .date)
                .font(.caption)
                .foregroundColor(.secondary)
            if let locationData = loadLocationDataForRecording(url: recordingData.recording.recordingURL) {
                locationButtonView(locationData, recordingURL: recordingData.recording.recordingURL)
            }
        }
    }
    
    private func locationButtonView(_ locationData: LocationData, recordingURL: URL) -> some View {
        Button(action: {
            selectedLocationData = locationData
        }) {
            HStack {
                Image(systemName: "location.fill")
                    .font(.caption2)
                    .foregroundColor(.accentColor)
                Text(locationAddresses[recordingURL] ?? locationData.coordinateString)
                    .font(.caption2)
                    .foregroundColor(.accentColor)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private func transcriptButtonView(_ recordingData: (recording: RegistryRecordingEntry, transcript: TranscriptData?)) -> some View {
        Button(action: {
            selectedRecording = recordingData.recording
            if recordingData.transcript != nil {
                // Show existing transcript for editing
                // This will be handled by the sheet
            } else {
                // Generate new transcript
                generateTranscript(for: recordingData.recording)
            }
        }) {
            HStack {
                if isGeneratingTranscript && selectedRecording?.id == recordingData.recording.id {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Processing...")
                        .font(.caption2)
                } else {
                    Image(systemName: recordingData.transcript != nil ? "text.bubble.fill" : "text.bubble")
                    Text(recordingData.transcript != nil ? "Edit Transcript" : "Generate Transcript")
                }
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(recordingData.transcript != nil ? Color.green : Color.accentColor)
            .foregroundColor(.white)
            .cornerRadius(8)
        }
        .disabled(isGeneratingTranscript)
        .id("\(recordingData.recording.id)-\(recordingData.transcript != nil)-\(refreshTrigger)")

    }
    
    private func loadRecordings() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: [.creationDateKey], options: [])
            
            // Step 1: Filter audio files
            let audioFiles = fileURLs.filter { ["m4a", "mp3", "wav"].contains($0.pathExtension.lowercased()) }
            
            // Step 2: Process each file into recording data
            var processedRecordings: [(recording: RegistryRecordingEntry, transcript: TranscriptData?)] = []
            
            for url in audioFiles {
                guard let creationDate = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate else { continue }
                
                let duration = getRecordingDuration(url: url)
                let fileSize = getFileSize(url: url)
                let transcript = TranscriptManager.shared.getTranscript(for: url)
                
                let recording = RegistryRecordingEntry(
                    recordingURL: url,
                    recordingName: url.deletingPathExtension().lastPathComponent,
                    recordingDate: creationDate,
                    fileSize: fileSize,
                    duration: duration,
                    audioQuality: AudioRecorderViewModel.getCurrentAudioQuality()
                )
                
                processedRecordings.append((recording: recording, transcript: transcript))
            }
            
            // Step 3: Sort by date
            recordings = processedRecordings.sorted { $0.recording.recordingDate > $1.recording.recordingDate }
            
            // Geocode locations for all recordings
            for recording in recordings {
                loadLocationAddress(for: recording.recording)
            }
        } catch {
            print("Error loading recordings: \(error)")
        }
    }
    
    func loadLocationDataForRecording(url: URL) -> LocationData? {
        return Self.loadLocationDataForRecording(url: url)
    }
    
    static func loadLocationDataForRecording(url: URL) -> LocationData? {
        let locationURL = url.deletingPathExtension().appendingPathExtension("location")
        guard let data = try? Data(contentsOf: locationURL),
              let locationData = try? JSONDecoder().decode(LocationData.self, from: data) else {
            return nil
        }
        return locationData
    }
    
    private func loadLocationAddress(for recording: RegistryRecordingEntry) {
        // Check if there's a location file for this recording
        let locationURL = recording.recordingURL.deletingPathExtension().appendingPathExtension("location")
        guard let data = try? Data(contentsOf: locationURL),
              let locationData = try? JSONDecoder().decode(LocationData.self, from: data) else {
            return
        }
        
        let location = CLLocation(latitude: locationData.latitude, longitude: locationData.longitude)
        // Use a default location manager since AudioRecorderViewModel doesn't have one
        let locationManager = LocationManager()
        locationManager.reverseGeocodeLocation(location) { address in
            if let address = address {
                locationAddresses[recording.recordingURL] = address
            }
        }
    }
    
    private func forceRefreshUI() {
        print("🔄 TranscriptsView: Forcing UI refresh")
        DispatchQueue.main.async {
            self.refreshTrigger.toggle()
            self.loadRecordings()
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
    
    private func getFileSize(url: URL) -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.size] as? Int64 ?? 0
        } catch {
            print("Error getting file size: \(error)")
            return 0
        }
    }
    
    private func generateTranscript(for recording: RegistryRecordingEntry) {
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
    
    private func performEnhancedTranscription(for recording: RegistryRecordingEntry) {
        print("🚀 Starting enhanced transcription for: \(recording.recordingName)")
        
        // Show progress sheet if enabled
        if showTranscriptionProgress {
            showingTranscriptionProgress = true
        }
        
        Task {
            // Use the selected transcription engine
            let selectedEngine = TranscriptionEngine(rawValue: UserDefaults.standard.string(forKey: "selectedTranscriptionEngine") ?? TranscriptionEngine.appleIntelligence.rawValue) ?? .appleIntelligence
            
            do {
                // Start transcription job through BackgroundProcessingManager
                try await backgroundProcessingManager.startTranscriptionJob(
                    recordingURL: recording.recordingURL,
                    recordingName: recording.recordingName,
                    engine: selectedEngine
                )
                
                print("✅ Transcription job started through BackgroundProcessingManager")
                
                // The job will be processed in the background and the UI will be updated
                // through the BackgroundProcessingManager's published properties
                
            } catch {
                print("❌ Failed to start transcription job: \(error)")
                
                // Fallback to direct transcription if background processing fails
                print("🔄 Falling back to direct transcription...")
                do {
                    let result = try await enhancedTranscriptionManager.transcribeAudioFile(at: recording.recordingURL, using: selectedEngine)
                    
                    print("📊 Transcription result: success=\(result.success), textLength=\(result.fullText.count)")
                    
                    if result.success && !result.fullText.isEmpty {
                        print("✅ Creating transcript data...")
                        // Create transcript data
                        let transcriptData = TranscriptData(
                            recordingURL: recording.recordingURL,
                            recordingName: recording.recordingName,
                            recordingDate: recording.recordingDate,
                            segments: result.segments
                        )
                        
                        // Save the transcript
                        TranscriptManager.shared.saveTranscript(transcriptData)
                        print("💾 Transcript saved successfully")
                        
                                            // Don't automatically open the transcript view - let user choose when to edit
                        
                        // Force UI refresh to update button states
                        self.forceRefreshUI()
                    } else {
                        print("❌ Transcription failed or returned empty result")
                    }
                } catch {
                    print("❌ Fallback transcription also failed: \(error)")
                }
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
        
        // Set up completion handler for BackgroundProcessingManager
        backgroundProcessingManager.onTranscriptionCompleted = { transcriptData, job in
            Task { @MainActor in
                print("🎉 Background processing transcription completed for: \(job.recordingName)")
                
                // Find the recording that matches this transcription
                if let recording = recordings.first(where: { recording in
                    return recording.recording.recordingURL == job.recordingURL
                }) {
                    print("💾 Background transcript already saved by BackgroundProcessingManager")
                    
                    // Don't automatically open the transcript view - let user choose when to edit
                    
                    // Force UI refresh to update button states
                    self.forceRefreshUI()
                    
                    // Send notification for other views to refresh
                    NotificationCenter.default.post(name: NSNotification.Name("TranscriptionCompleted"), object: nil)
                    
                    // Dismiss progress sheet first if it's showing
                    if self.showingTranscriptionProgress {
                        self.showingTranscriptionProgress = false
                        // Add a small delay to ensure the sheet is dismissed before showing the alert
                        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                    }
                    
                    // Only show alert if not already showing one
                    if !self.isShowingAlert {
                        // Show completion alert
                        self.completedTranscriptionText = "Transcription completed for: \(recording.recording.recordingName)"
                        self.showingTranscriptionCompletionAlert = true
                    }
                } else {
                    print("❌ Could not find recording for completed transcription")
                }
            }
        }
        
        enhancedTranscriptionManager.onTranscriptionCompleted = { result, jobInfo in
            Task { @MainActor in
                
                print("🎉 Background transcription completed for: \(jobInfo.recordingName)")
                print("🔍 Looking for recording with URL: \(jobInfo.recordingURL)")
                print("📋 Available recordings: \(recordings.count)")
                for (index, recording) in recordings.enumerated() {
                    print("📋 Recording \(index): \(recording.recording.recordingName) - \(recording.recording.recordingURL)")
                }
                
                // Find the recording that matches this transcription
                if let recording = recordings.first(where: { recording in
                    return recording.recording.recordingURL == jobInfo.recordingURL
                }) {
                    // Create transcript data and save it
                    let transcriptData = TranscriptData(
                        recordingURL: recording.recording.recordingURL,
                        recordingName: recording.recording.recordingName,
                        recordingDate: recording.recording.recordingDate,
                        segments: result.segments
                    )
                    
                    TranscriptManager.shared.saveTranscript(transcriptData)
                    print("💾 Background transcript saved for: \(recording.recording.recordingName)")
                    
                    // Force UI refresh to update button states
                    self.forceRefreshUI()
                    
                    // Send notification for other views to refresh
                    NotificationCenter.default.post(name: NSNotification.Name("TranscriptionCompleted"), object: nil)
                    
                    // Dismiss progress sheet first if it's showing
                    if self.showingTranscriptionProgress {
                        self.showingTranscriptionProgress = false
                        // Add a small delay to ensure the sheet is dismissed before showing the alert
                        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                    }
                    
                    // Only show alert if not already showing one
                    if !self.isShowingAlert {
                        // Show completion alert
                        self.completedTranscriptionText = "Transcription completed for: \(recording.recording.recordingName)"
                        self.showingTranscriptionCompletionAlert = true
                    }
                } else {
                    print("❌ No matching recording found for job: \(jobInfo.recordingName)")
                    print("❌ Job URL: \(jobInfo.recordingURL)")
                    print("❌ Available recording URLs:")
                    for recording in self.recordings {
                        print("❌   - \(recording.recording.recordingURL)")
                    }
                }
            }
        }
    }
}

struct EditableTranscriptView: View {
    let recording: RegistryRecordingEntry
    let transcript: TranscriptData
    let transcriptManager: TranscriptManager
    @Environment(\.dismiss) private var dismiss
    @State private var locationAddress: String?
    @State private var editedSegments: [TranscriptSegment]
    @State private var speakerMappings: [String: String]
    @State private var showingSpeakerEditor = false
    
    init(recording: RegistryRecordingEntry, transcript: TranscriptData, transcriptManager: TranscriptManager) {
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
    let recording: RegistryRecordingEntry
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
                            Text(recording.recordingName)
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.primary)
                            
                            Text(recording.recordingDate, style: .date)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            if let locationData = TranscriptsView.loadLocationDataForRecording(url: recording.recordingURL) {
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
                if let locationData = TranscriptsView.loadLocationDataForRecording(url: recording.recordingURL) {
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

// MARK: - Title Row View

struct TitleRowView: View {
    let title: TitleItem
    let recordingName: String
    @StateObject private var systemIntegration = SystemIntegrationManager()
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Category icon
            Image(systemName: title.category.icon)
                .font(.caption)
                .foregroundColor(.accentColor)
                .frame(width: 16)
            
            VStack(alignment: .leading, spacing: 4) {
                // Title text
                Text(title.text)
                    .font(.body)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                
                // Confidence indicator
                HStack {
                    Text("Confidence: \(Int(title.confidence * 100))%")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    // Copy button
                    Button(action: {
                        UIPasteboard.general.string = title.text
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                    }
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Enhanced Title Row View

struct EnhancedTitleRowView: View {
    let title: TitleItem
    let recordingName: String
    @StateObject private var systemIntegration = SystemIntegrationManager()
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Category icon with background
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 32, height: 32)
                
                Image(systemName: title.category.icon)
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                // Title text
                Text(title.text)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(nil)
                
                // Metadata row
                HStack {
                    // Confidence indicator
                    HStack(spacing: 4) {
                        Image(systemName: "chart.bar.fill")
                            .font(.caption2)
                            .foregroundColor(confidenceColor)
                        Text("\(Int(title.confidence * 100))%")
                            .font(.caption2)
                            .foregroundColor(confidenceColor)
                    }
                    
                    // Category badge
                    Text(title.category.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .foregroundColor(.secondary)
                        .cornerRadius(4)
                    
                    Spacer()
                    
                    // Copy button
                    Button(action: {
                        UIPasteboard.general.string = title.text
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                    }
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }
    
    private var confidenceColor: Color {
        switch title.confidence {
        case 0.8...1.0: return .green
        case 0.6..<0.8: return .blue
        case 0.4..<0.6: return .orange
        default: return .red
        }
    }
}