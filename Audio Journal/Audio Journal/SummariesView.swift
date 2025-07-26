import SwiftUI
import AVFoundation
import Speech
import CoreLocation
import NaturalLanguage

struct SummariesView: View {
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @StateObject private var summaryManager = SummaryManager()
    @StateObject private var transcriptManager = TranscriptManager()
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
            }
        }
        .sheet(isPresented: $showSummary) {
            if let recording = selectedRecording,
               let summaryData = summaryManager.getSummary(for: recording.url) {
                SummaryDetailView(recording: recording, summaryData: summaryData)
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
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            isGeneratingSummary = false
            return
        }
        
        // Ensure the file is accessible
        guard FileManager.default.fileExists(atPath: recording.url.path) else {
            isGeneratingSummary = false
            return
        }
        
        let request = SFSpeechURLRecognitionRequest(url: recording.url)
        request.shouldReportPartialResults = false
        
        recognizer.recognitionTask(with: request) { result, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("Speech recognition error: \(error)")
                    self.isGeneratingSummary = false
                } else if let result = result {
                    if result.isFinal {
                        let transcriptText = result.bestTranscription.formattedString
                        if !transcriptText.isEmpty {
                            // Create diarized transcript segments
                            let segments = self.createDiarizedSegments(from: result.bestTranscription)
                            let transcriptData = TranscriptData(
                                recordingURL: recording.url,
                                recordingName: recording.name,
                                recordingDate: recording.date,
                                segments: segments
                            )
                            
                            // Save the transcript
                            self.transcriptManager.saveTranscript(transcriptData)
                            
                            // Generate summary from transcript
                            self.generateSummaryFromTranscript(for: recording, transcriptText: transcriptText)
                        } else {
                            self.isGeneratingSummary = false
                        }
                    }
                }
            }
        }
    }
    
    private func createDiarizedSegments(from transcription: SFTranscription) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var currentSpeaker = "Speaker 1"
        var currentText = ""
        var currentStartTime: TimeInterval = 0
        var speakerCount = 1
        
        for segment in transcription.segments {
            // Simple diarization logic - change speaker when there's a significant pause
            let shouldChangeSpeaker = segment.timestamp - currentStartTime > 2.0 && !currentText.isEmpty
            
            if shouldChangeSpeaker {
                // Save current segment
                if !currentText.isEmpty {
                    segments.append(TranscriptSegment(
                        speaker: currentSpeaker,
                        text: currentText.trimmingCharacters(in: .whitespacesAndNewlines),
                        startTime: currentStartTime,
                        endTime: segment.timestamp
                    ))
                }
                
                // Start new speaker
                speakerCount += 1
                currentSpeaker = "Speaker \(speakerCount)"
                currentText = segment.substring
                currentStartTime = segment.timestamp
            } else {
                // Continue with current speaker
                if currentText.isEmpty {
                    currentStartTime = segment.timestamp
                }
                currentText += " " + segment.substring
            }
        }
        
        // Add the last segment
        if !currentText.isEmpty {
            segments.append(TranscriptSegment(
                speaker: currentSpeaker,
                text: currentText.trimmingCharacters(in: .whitespacesAndNewlines),
                startTime: currentStartTime,
                endTime: transcription.segments.last?.timestamp ?? 0
            ))
        }
        
        return segments
    }
    
    private func generateSummaryFromTranscript(for recording: RecordingFile, transcriptText: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let summaryResult = generateSummaryFromText(transcriptText)
            let tasksResult = extractTasksFromText(transcriptText)
            let remindersResult = extractRemindersFromText(transcriptText)
            
            DispatchQueue.main.async {
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
                
                self.isGeneratingSummary = false
                self.showSummary = true
            }
        }
    }
    
    // Summary generation functions (same as in SummaryView)
    private func generateSummaryFromText(_ text: String) -> String {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        tagger.string = text
        
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?")).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        
        guard !sentences.isEmpty else { return "No content to summarize." }
        
        var sentenceScores: [(String, Double)] = []
        
        for sentence in sentences {
            let cleanSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanSentence.isEmpty else { continue }
            
            var score: Double = 0
            
            let wordCount = cleanSentence.components(separatedBy: CharacterSet.whitespaces).count
            if wordCount >= 5 && wordCount <= 20 {
                score += 2.0
            } else if wordCount > 20 {
                score += 1.0
            }
            
            let lowercased = cleanSentence.lowercased()
            let keyTerms = ["important", "need", "must", "should", "remember", "remind", "call", "meet", "buy", "get", "do", "make", "see", "visit", "go", "come", "take", "bring"]
            
            for term in keyTerms {
                if lowercased.contains(term) {
                    score += 1.0
                }
            }
            
            let timePatterns = ["today", "tomorrow", "next", "later", "tonight", "morning", "afternoon", "evening", "week", "month", "year"]
            for pattern in timePatterns {
                if lowercased.contains(pattern) {
                    score += 1.5
                }
            }
            
            sentenceScores.append((cleanSentence, score))
        }
        
        let sortedSentences = sentenceScores.sorted { $0.1 > $1.1 }
        let topSentences = Array(sortedSentences.prefix(min(3, sortedSentences.count)))
        
        if topSentences.isEmpty {
            return "Summary: " + sentences.prefix(2).joined(separator: ". ") + "."
        }
        
        let summaryText = topSentences.map { $0.0 }.joined(separator: ". ") + "."
        return "Summary: " + summaryText
    }
    
    private func extractTasksFromText(_ text: String) -> [String] {
        var tasks: [String] = []
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
        
        let taskKeywords = [
            "need to", "have to", "must", "should", "want to", "going to", "plan to",
            "call", "meet", "buy", "get", "do", "make", "see", "visit", "go", "come",
            "take", "bring", "send", "email", "text", "message", "schedule", "book",
            "order", "pick up", "drop off", "return", "check", "review", "update"
        ]
        
        for sentence in sentences {
            let cleanSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = cleanSentence.lowercased()
            
            for keyword in taskKeywords {
                if lowercased.contains(keyword) {
                    if let range = lowercased.range(of: keyword) {
                        let taskStart = cleanSentence.index(cleanSentence.startIndex, offsetBy: range.lowerBound.utf16Offset(in: lowercased))
                        let taskText = String(cleanSentence[taskStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        if !taskText.isEmpty && taskText.count > 5 {
                            tasks.append(taskText.capitalized)
                            break
                        }
                    }
                }
            }
        }
        
        return Array(Set(tasks)).prefix(5).map { $0 }
    }
    
    private func extractRemindersFromText(_ text: String) -> [String] {
        var reminders: [String] = []
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
        
        let reminderKeywords = [
            "remind", "remember", "don't forget", "don't forget to", "make sure to",
            "call", "meet", "appointment", "meeting", "deadline", "due", "by", "at"
        ]
        
        let timePatterns = [
            "today", "tomorrow", "tonight", "morning", "afternoon", "evening",
            "next week", "next month", "next year", "later", "soon", "in an hour",
            "at 7", "at 8", "at 9", "at 10", "at 11", "at 12", "at 1", "at 2", "at 3", "at 4", "at 5", "at 6"
        ]
        
        for sentence in sentences {
            let cleanSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = cleanSentence.lowercased()
            
            var hasReminderKeyword = false
            var hasTimeReference = false
            
            for keyword in reminderKeywords {
                if lowercased.contains(keyword) {
                    hasReminderKeyword = true
                    break
                }
            }
            
            for pattern in timePatterns {
                if lowercased.contains(pattern) {
                    hasTimeReference = true
                    break
                }
            }
            
            if hasReminderKeyword || hasTimeReference {
                if cleanSentence.count > 5 {
                    reminders.append(cleanSentence.capitalized)
                }
            }
        }
        
        return Array(Set(reminders)).prefix(5).map { $0 }
    }
} 