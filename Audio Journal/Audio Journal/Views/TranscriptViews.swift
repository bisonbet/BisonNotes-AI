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
    @State private var refreshTrigger = false
    
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
                                .id("\(recording.url.absoluteString)-\(transcriptManager.hasTranscript(for: recording.url))-\(refreshTrigger)")
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
                // Force UI refresh to ensure transcript states are properly displayed
                DispatchQueue.main.async {
                    self.refreshTrigger.toggle()
                }
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
                    
                    // Force UI refresh to update button states
                    self.forceRefreshUI()
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
                    
                    // Force UI refresh to update button states
                    self.forceRefreshUI()
                    
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