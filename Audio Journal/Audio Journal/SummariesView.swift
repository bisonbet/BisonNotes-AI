import SwiftUI
import AVFoundation
import Speech
import CoreLocation
import NaturalLanguage

struct SummariesView: View {
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @StateObject private var summaryManager = SummaryManager()
    @StateObject private var transcriptManager = TranscriptManager()
    @StateObject private var enhancedTranscriptionManager = EnhancedTranscriptionManager()
    @State private var recordings: [RecordingFile] = []
    @State private var selectedRecording: RecordingFile?
    @State private var isGeneratingSummary = false
    @State private var selectedLocationData: LocationData?
    @State private var locationAddresses: [URL: String] = [:]
    @State private var showSummary = false
    
    var body: some View {
        NavigationView {
            VStack {
                if recordings.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)
                        
                        Text("No Recordings Found")
                            .font(.title2)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        
                        Text("Record some audio first to generate summaries")
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
                                
                                // Summary button
                                Button(action: {
                                    selectedRecording = recording
                                    if summaryManager.hasSummary(for: recording.url) {
                                        // Show existing summary
                                        showSummary = true
                                    } else {
                                        // Generate new summary
                                        generateTranscriptAndSummary(for: recording)
                                    }
                                }) {
                                    HStack {
                                        if isGeneratingSummary && selectedRecording?.url == recording.url {
                                            ProgressView()
                                                .scaleEffect(0.8)
                                        } else {
                                            Image(systemName: summaryManager.hasSummary(for: recording.url) ? "doc.text.magnifyingglass.fill" : "doc.text.magnifyingglass")
                                        }
                                        Text(summaryManager.hasSummary(for: recording.url) ? "View Summary" : "Generate Summary")
                                    }
                                    .font(.caption)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(summaryManager.hasSummary(for: recording.url) ? Color.green : Color.accentColor)
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                                }
                                .disabled(isGeneratingSummary)
                                
                                // Regenerate button (only show if summary exists)
                                if summaryManager.hasSummary(for: recording.url) {
                                    Button(action: {
                                        selectedRecording = recording
                                        generateTranscriptAndSummary(for: recording)
                                    }) {
                                        HStack {
                                            Image(systemName: "arrow.clockwise")
                                            Text("Regenerate")
                                        }
                                        .font(.caption)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color.orange)
                                        .foregroundColor(.white)
                                        .cornerRadius(8)
                                    }
                                    .disabled(isGeneratingSummary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                    }
        .navigationTitle("Summaries")
        .onAppear {
            loadRecordings()
            // Configure the summary manager with the selected AI engine
            summaryManager.setEngine(recorderVM.selectedAIEngine)
        }
        }
        .sheet(isPresented: $showSummary) {
            if let recording = selectedRecording {
                // Try to get enhanced summary first, fallback to legacy
                if let enhancedSummary = summaryManager.getBestAvailableSummary(for: recording.url) {
                    EnhancedSummaryDetailView(recording: recording, summaryData: enhancedSummary)
                } else if let summaryData = summaryManager.getSummary(for: recording.url) {
                    SummaryDetailView(recording: recording, summaryData: summaryData)
                }
            }
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
    
    private func generateTranscriptAndSummary(for recording: RecordingFile) {
        isGeneratingSummary = true
        
        // Check if transcript already exists
        if let existingTranscript = transcriptManager.getTranscript(for: recording.url) {
            // Use existing transcript for summary
            generateSummaryFromTranscript(for: recording, transcriptText: existingTranscript.plainText)
        } else {
            // Generate new transcript first
            SFSpeechRecognizer.requestAuthorization { authStatus in
                DispatchQueue.main.async {
                    switch authStatus {
                    case .authorized:
                        self.performSpeechRecognition(for: recording)
                    case .denied, .restricted:
                        self.isGeneratingSummary = false
                    case .notDetermined:
                        self.isGeneratingSummary = false
                    @unknown default:
                        self.isGeneratingSummary = false
                    }
                }
            }
        }
    }
    
    private func performSpeechRecognition(for recording: RecordingFile) {
        Task {
            do {
                let result = try await enhancedTranscriptionManager.transcribeAudioFile(at: recording.url)
                
                if result.success && !result.fullText.isEmpty {
                    // Create diarized transcript segments
                    let segments = self.createDiarizedSegments(from: result.segments)
                    let transcriptData = TranscriptData(
                        recordingURL: recording.url,
                        recordingName: recording.name,
                        recordingDate: recording.date,
                        segments: segments
                    )
                    
                    // Save the transcript
                    self.transcriptManager.saveTranscript(transcriptData)
                    
                    // Generate summary from transcript
                    self.generateSummaryFromTranscript(for: recording, transcriptText: result.fullText)
                } else {
                    await MainActor.run {
                        self.isGeneratingSummary = false
                    }
                }
            } catch {
                print("Enhanced transcription error: \(error)")
                await MainActor.run {
                    self.isGeneratingSummary = false
                }
            }
        }
    }
    
    private func createDiarizedSegments(from segments: [TranscriptSegment]) -> [TranscriptSegment] {
        if segments.isEmpty {
            return []
        }
        
        // Check if diarization is enabled
        guard recorderVM.isDiarizationEnabled else {
            // Return segments as-is for single speaker
            return segments
        }
        
        // Apply diarization based on selected method
        switch recorderVM.selectedDiarizationMethod {
        case .basicPause:
            return createBasicPauseDiarization(from: segments)
        case .awsTranscription:
            // Placeholder for future AWS implementation
            return segments.map { segment in
                TranscriptSegment(
                    speaker: segment.speaker,
                    text: segment.text + "\n\n[AWS Transcription coming soon]",
                    startTime: segment.startTime,
                    endTime: segment.endTime
                )
            }
        case .whisperBased:
            // Placeholder for future Whisper implementation
            return segments.map { segment in
                TranscriptSegment(
                    speaker: segment.speaker,
                    text: segment.text + "\n\n[Whisper-based diarization coming soon]",
                    startTime: segment.startTime,
                    endTime: segment.endTime
                )
            }
        }
    }
    
    private func createBasicPauseDiarization(from segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var diarizedSegments: [TranscriptSegment] = []
        var currentSpeaker = "Speaker 1"
        var currentText = ""
        var currentStartTime: TimeInterval = 0
        var speakerCount = 1
        var lastSegmentEndTime: TimeInterval = 0
        
        for segment in segments {
            let pauseDuration = segment.startTime - lastSegmentEndTime
            
            // Conservative diarization logic - only change speaker on very long pauses
            let shouldChangeSpeaker = pauseDuration > 8.0 && // Very long pause threshold
                                    !currentText.isEmpty && 
                                    currentText.count > 100 && // Substantial text before switching
                                    speakerCount < 3 // Limit to maximum 3 speakers
            
            if shouldChangeSpeaker {
                diarizedSegments.append(TranscriptSegment(
                    speaker: currentSpeaker,
                    text: currentText.trimmingCharacters(in: .whitespacesAndNewlines),
                    startTime: currentStartTime,
                    endTime: segment.startTime
                ))
                
                speakerCount += 1
                currentSpeaker = "Speaker \(speakerCount)"
                currentText = segment.text
                currentStartTime = segment.startTime
            } else {
                if currentText.isEmpty {
                    currentStartTime = segment.startTime
                }
                currentText += " " + segment.text
            }
            
            lastSegmentEndTime = segment.endTime
        }
        
        if !currentText.isEmpty {
            diarizedSegments.append(TranscriptSegment(
                speaker: currentSpeaker,
                text: currentText.trimmingCharacters(in: .whitespacesAndNewlines),
                startTime: currentStartTime,
                endTime: segments.last?.endTime ?? 0
            ))
        }
        
        return diarizedSegments
    }
    
    private func generateSummaryFromTranscript(for recording: RecordingFile, transcriptText: String) {
        Task {
            do {
                // Ensure the correct AI engine is set before generating summary
                await MainActor.run {
                    summaryManager.setEngine(recorderVM.selectedAIEngine)
                }
                
                // Use the enhanced AI engine for better summarization
                _ = try await summaryManager.generateEnhancedSummary(
                    from: transcriptText,
                    for: recording.url,
                    recordingName: recording.name,
                    recordingDate: recording.date
                )
                
                await MainActor.run {
                    // Reload recordings to reflect any name changes
                    self.loadRecordings()
                    self.isGeneratingSummary = false
                    self.showSummary = true
                }
            } catch {
                print("Enhanced summary generation failed: \(error)")
                
                // Fallback to basic summarization
                await MainActor.run {
                    let summaryResult = generateSummaryFromText(transcriptText)
                    let tasksResult = extractTasksFromText(transcriptText)
                    let remindersResult = extractRemindersFromText(transcriptText)
                    
                    // Create and save summary data
                    let summaryData = SummaryData(
                        recordingURL: recording.url,
                        recordingName: recording.name,
                        recordingDate: recording.date,
                        summary: summaryResult,
                        tasks: tasksResult,
                        reminders: remindersResult
                    )
                    
                    // Update or save the summary
                    if self.summaryManager.hasSummary(for: recording.url) {
                        self.summaryManager.updateSummary(summaryData)
                    } else {
                        self.summaryManager.saveSummary(summaryData)
                    }
                    
                    // Reload recordings to reflect any name changes
                    self.loadRecordings()
                    self.isGeneratingSummary = false
                    self.showSummary = true
                }
            }
        }
    }
    
    // Summary generation functions (same as in SummaryView)
    private func generateSummaryFromText(_ text: String) -> String {
        // Use the ContentAnalyzer for better summarization
        let preprocessedText = ContentAnalyzer.preprocessText(text)
        let sentences = ContentAnalyzer.extractSentences(from: preprocessedText)
        
        guard !sentences.isEmpty else { return "No content to summarize." }
        
        // Score sentences based on importance
        let scoredSentences = sentences.map { sentence in
            (sentence: sentence, score: ContentAnalyzer.calculateSentenceImportance(sentence, in: preprocessedText))
        }
        
        // Cluster related sentences to avoid redundancy
        let clusters = ContentAnalyzer.clusterRelatedSentences(sentences)
        
        // Select best sentences from each cluster
        var selectedSentences: [String] = []
        let targetSentenceCount = min(max(sentences.count / 4, 2), 4) // 25% of sentences, min 2, max 4
        
        for cluster in clusters {
            if selectedSentences.count >= targetSentenceCount { break }
            
            // Find the best sentence in this cluster
            let clusterScores = cluster.map { sentence in
                (sentence: sentence, score: ContentAnalyzer.calculateSentenceImportance(sentence, in: preprocessedText))
            }
            
            if let bestInCluster = clusterScores.max(by: { $0.score < $1.score }) {
                selectedSentences.append(bestInCluster.sentence)
            }
        }
        
        // If we don't have enough sentences, add more from the highest scored
        if selectedSentences.count < targetSentenceCount {
            let remainingNeeded = targetSentenceCount - selectedSentences.count
            let additionalSentences = scoredSentences
                .filter { !selectedSentences.contains($0.sentence) }
                .sorted { $0.score > $1.score }
                .prefix(remainingNeeded)
                .map { $0.sentence }
            
            selectedSentences.append(contentsOf: additionalSentences)
        }
        
        // Create a coherent summary
        let summaryText = selectedSentences.joined(separator: " ")
        
        // Add key phrases if available
        let keyPhrases = ContentAnalyzer.extractKeyPhrases(from: text, maxPhrases: 3)
        if !keyPhrases.isEmpty {
            return "Summary: \(summaryText). Key topics: \(keyPhrases.joined(separator: ", "))."
        }
        
        return "Summary: \(summaryText)."
    }
    
    private func extractTasksFromText(_ text: String) -> [String] {
        // Use the TaskExtractor for better task extraction
        let taskExtractor = TaskExtractor()
        let taskItems = taskExtractor.extractTasks(from: text)
        return taskItems.map { $0.text }
    }
    
    private func extractRemindersFromText(_ text: String) -> [String] {
        // Use the ReminderExtractor for better reminder extraction
        let reminderExtractor = ReminderExtractor()
        let reminderItems = reminderExtractor.extractReminders(from: text)
        return reminderItems.map { $0.text }
    }
} 