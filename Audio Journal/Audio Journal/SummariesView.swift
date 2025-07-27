import SwiftUI
import AVFoundation
import Speech
import CoreLocation
import NaturalLanguage

struct SummariesView: View {
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @StateObject private var summaryManager = SummaryManager()
    @StateObject private var transcriptManager = TranscriptManager.shared
    @StateObject private var enhancedTranscriptionManager = EnhancedTranscriptionManager()
    @State private var recordings: [RecordingFile] = []
    @State private var selectedRecording: RecordingFile?
    @State private var isGeneratingSummary = false
    @State private var selectedLocationData: LocationData?
    @State private var locationAddresses: [URL: String] = [:]
    @State private var showSummary = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    
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
                                        Task {
                                            await generateTranscriptAndSummary(for: recording)
                                        }
                                    }
                                }) {
                                    HStack {
                                        if isGeneratingSummary && selectedRecording?.url == recording.url {
                                            ProgressView()
                                                .scaleEffect(0.8)
                                        } else {
                                            Image(systemName: summaryManager.hasSummary(for: recording.url) ? "doc.text.magnifyingglass" : "doc.text.magnifyingglass")
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
                                        Task {
                                            await generateTranscriptAndSummary(for: recording)
                                        }
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
            
            // Ensure transcription manager is using the correct engine and stop unnecessary AWS checks
            enhancedTranscriptionManager.updateTranscriptionEngine(recorderVM.selectedTranscriptionEngine)
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
        .alert("Summary Generation Error", isPresented: $showErrorAlert) {
            Button("OK") {
                showErrorAlert = false
            }
        } message: {
            Text(errorMessage)
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
    
    private func generateTranscriptAndSummary(for recording: RecordingFile) async {
        print("🎬 Starting generateTranscriptAndSummary for: \(recording.name)")
        print("🔍 Looking for transcript with URL: \(recording.url)")
        print("📋 Total transcripts in manager: \(transcriptManager.transcripts.count)")
        
        // Debug: Print all stored transcript URLs
        for (index, transcript) in transcriptManager.transcripts.enumerated() {
            print("📄 Transcript \(index): \(transcript.recordingName) - \(transcript.recordingURL)")
        }
        
        isGeneratingSummary = true
        
        // Check if transcript already exists
        if let existingTranscript = transcriptManager.getTranscript(for: recording.url) {
            print("📄 Found existing transcript, checking validity...")
            print("📄 Existing transcript name: \(existingTranscript.recordingName)")
            print("📄 Existing transcript URL: \(existingTranscript.recordingURL)")
            // Validate that we have actual transcript content, not a placeholder
            let transcriptText = existingTranscript.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Check for placeholder text or insufficient content
            if isValidTranscriptForSummarization(transcriptText) {
                print("✅ Transcript is valid, generating summary...")
                generateSummaryFromTranscript(for: recording, transcriptText: transcriptText)
            } else {
                print("⚠️ Transcript exists but is not suitable for summarization: \(transcriptText.prefix(100))")
                
                // Check if this is a pending AWS transcription
                if isPendingAWSTranscription(transcriptText) {
                    print("⏳ Detected pending AWS transcription, waiting for completion...")
                    await waitForTranscriptionCompletion(for: recording)
                } else {
                    await MainActor.run {
                        self.isGeneratingSummary = false
                        self.showErrorAlert = true
                        self.errorMessage = "No valid transcript found. Please generate a transcript first by clicking 'Generate Transcript' in the Recordings tab."
                    }
                }
            }
        } else {
            print("📄 No existing transcript found, starting transcription...")
            performSpeechRecognition(for: recording)
        }
    }
    
    // MARK: - Pending Transcription Handling
    
    private func isPendingAWSTranscription(_ transcriptText: String) -> Bool {
        let lowercased = transcriptText.lowercased()
        let pendingPatterns = [
            "transcription job started:",
            "job is running in background",
            "check status later to retrieve results",
            "transcription job",
            "is running in background"
        ]
        
        for pattern in pendingPatterns {
            if lowercased.contains(pattern) {
                print("🔍 Detected pending AWS transcription pattern: \(pattern)")
                return true
            }
        }
        return false
    }
    
    private func waitForTranscriptionCompletion(for recording: RecordingFile) async {
        print("⏳ Waiting for transcription completion for: \(recording.name)")
        
        // Set up a completion handler for when transcription finishes
        enhancedTranscriptionManager.onTranscriptionCompleted = { result, jobInfo in
            Task { @MainActor in
                
                print("🎉 Transcription completed for: \(jobInfo.recordingName)")
                print("🔍 Checking if this matches our recording: \(recording.name)")
                
                // Check if this completed transcription matches our recording
                if jobInfo.recordingURL == recording.url {
                    print("✅ Matched transcription completion with our recording")
                    
                    // Validate the completed transcript
                    let transcriptText = result.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if self.isValidTranscriptForSummarization(transcriptText) {
                        print("✅ Completed transcript is valid, generating summary...")
                        
                        // Create transcript data and save it
                        let segments = self.createDiarizedSegments(from: result.segments)
                        let transcriptData = TranscriptData(
                            recordingURL: recording.url,
                            recordingName: recording.name,
                            recordingDate: recording.date,
                            segments: segments
                        )
                        
                        self.transcriptManager.saveTranscript(transcriptData)
                        print("💾 Completed transcript saved successfully")
                        
                        // Generate summary from the completed transcript
                        self.generateSummaryFromTranscript(for: recording, transcriptText: transcriptText)
                    } else {
                        print("❌ Completed transcript is not valid for summarization")
                        self.isGeneratingSummary = false
                        self.showErrorAlert = true
                        self.errorMessage = "Transcription completed but the content is not suitable for summarization. Please try again or check your audio quality."
                    }
                } else {
                    print("❌ Completed transcription doesn't match our recording")
                    print("❌ Expected: \(recording.url)")
                    print("❌ Got: \(jobInfo.recordingURL)")
                }
            }
        }
        
        // Start background checking for completed transcriptions
        print("🔍 Starting background check for completed transcriptions...")
        await enhancedTranscriptionManager.checkForCompletedTranscriptions()
        
        // Set up a timer to periodically check for completion
        let maxWaitTime: TimeInterval = 3600 // 1 hour max wait
        let checkInterval: TimeInterval = 10 // Check every 10 seconds
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < maxWaitTime {
            // Check if we now have a valid transcript
            if let updatedTranscript = transcriptManager.getTranscript(for: recording.url) {
                let transcriptText = updatedTranscript.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                
                if isValidTranscriptForSummarization(transcriptText) && !isPendingAWSTranscription(transcriptText) {
                    print("✅ Found valid completed transcript, generating summary...")
                    generateSummaryFromTranscript(for: recording, transcriptText: transcriptText)
                    return
                }
            }
            
            // Wait before checking again
            try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
            
            // Also trigger a manual check for completed transcriptions
            await enhancedTranscriptionManager.checkForCompletedTranscriptions()
        }
        
        // If we reach here, the transcription timed out
        print("⏰ Transcription wait timed out")
        await MainActor.run {
            self.isGeneratingSummary = false
            self.showErrorAlert = true
            self.errorMessage = "Transcription is taking longer than expected. Please check the status in the Transcripts tab or try again later."
        }
    }
    
    private func performSpeechRecognition(for recording: RecordingFile) {
        print("🎙️ Starting speech recognition for: \(recording.name)")
        print("🔧 Using transcription engine: \(recorderVM.selectedTranscriptionEngine.rawValue)")
        
        Task {
            do {
                // Add timeout to prevent infinite CPU usage
                let result = try await withTimeout(seconds: 300) { // 5 minute timeout
                    try await enhancedTranscriptionManager.transcribeAudioFile(at: recording.url, using: recorderVM.selectedTranscriptionEngine)
                }
                
                print("📊 Transcription completed - Success: \(result.success), Text length: \(result.fullText.count)")
                
                if result.success && !result.fullText.isEmpty {
                    // Validate transcript quality before proceeding
                    let transcriptText = result.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    // Check if this is a pending AWS transcription
                    if isPendingAWSTranscription(transcriptText) {
                        print("⏳ Detected pending AWS transcription, waiting for completion...")
                        
                        // Save the placeholder transcript so we can track it
                        let segments = self.createDiarizedSegments(from: result.segments)
                        let transcriptData = TranscriptData(
                            recordingURL: recording.url,
                            recordingName: recording.name,
                            recordingDate: recording.date,
                            segments: segments
                        )
                        
                        self.transcriptManager.saveTranscript(transcriptData)
                        print("💾 Placeholder transcript saved for tracking")
                        
                        // Wait for the actual transcription to complete
                        await waitForTranscriptionCompletion(for: recording)
                    } else if isValidTranscriptForSummarization(transcriptText) {
                        print("✅ Transcript validation passed, saving and generating summary...")
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
                        print("💾 Transcript saved successfully")
                        
                        // Generate summary from validated transcript
                        self.generateSummaryFromTranscript(for: recording, transcriptText: transcriptText)
                    } else {
                        print("⚠️ Transcription completed but content is not suitable for summarization")
                        await MainActor.run {
                            self.isGeneratingSummary = false
                            self.showErrorAlert = true
                            self.errorMessage = "No valid transcript could be generated. Please try generating a transcript first in the Recordings tab, or check that your audio contains clear speech."
                        }
                    }
                } else {
                    print("⚠️ Transcription failed or returned empty content - Success: \(result.success), Error: \(result.error?.localizedDescription ?? "None")")
                    await MainActor.run {
                        self.isGeneratingSummary = false
                        self.showErrorAlert = true
                        self.errorMessage = "Transcription failed. Please try generating a transcript first in the Recordings tab, or check that your audio contains clear speech."
                    }
                }
            } catch {
                print("❌ Enhanced transcription error: \(error)")
                await MainActor.run {
                    self.isGeneratingSummary = false
                    self.showErrorAlert = true
                    self.errorMessage = "Transcription error: \(error.localizedDescription). Please try generating a transcript first in the Recordings tab."
                }
            }
        }
    }
    
    // Helper function to add timeout to async operations
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            
            guard let result = try await group.next() else {
                throw TimeoutError()
            }
            
            group.cancelAll()
            return result
        }
    }
    
    struct TimeoutError: Error {
        var localizedDescription: String {
            return "Operation timed out"
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
    
    private func isValidTranscriptForSummarization(_ transcriptText: String) -> Bool {
        // Check minimum length (at least 50 characters of meaningful content)
        guard transcriptText.count >= 50 else {
            print("📝 Transcript too short for summarization: \(transcriptText.count) characters")
            return false
        }
        
        // Check for placeholder text patterns (including AWS transcription placeholders)
        let lowercased = transcriptText.lowercased()
        let placeholderPatterns = [
            "transcription in progress",
            "processing audio",
            "please wait",
            "transcribing",
            "loading",
            "error",
            "failed to transcribe",
            "no audio detected",
            "silence detected",
            "aws transcription coming soon",
            "whisper-based diarization coming soon",
            "transcription job started:",
            "job is running in background",
            "check status later to retrieve results",
            "transcription job",
            "is running in background"
        ]
        
        for pattern in placeholderPatterns {
            if lowercased.contains(pattern) {
                print("📝 Transcript contains placeholder text: \(pattern)")
                return false
            }
        }
        
        // Check for meaningful word count (at least 10 actual words)
        let words = transcriptText.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty && $0.count > 1 }
        
        guard words.count >= 10 else {
            print("📝 Transcript has insufficient word count: \(words.count) words")
            return false
        }
        
        // Check for repetitive content (might indicate transcription errors)
        let uniqueWords = Set(words.map { $0.lowercased() })
        let uniqueRatio = Double(uniqueWords.count) / Double(words.count)
        
        guard uniqueRatio > 0.3 else {
            print("📝 Transcript appears too repetitive: \(String(format: "%.1f", uniqueRatio * 100))% unique words")
            return false
        }
        
        print("✅ Transcript validated for summarization: \(words.count) words, \(String(format: "%.1f", uniqueRatio * 100))% unique")
        return true
    }
    
    private func generateSummaryFromTranscript(for recording: RecordingFile, transcriptText: String) {
        print("📋 Starting summary generation for: \(recording.name)")
        print("📝 Transcript length: \(transcriptText.count) characters")
        print("🤖 Selected AI engine: \(recorderVM.selectedAIEngine)")
        
        Task {
            do {
                // Ensure the correct AI engine is set before generating summary
                await MainActor.run {
                    summaryManager.setEngine(recorderVM.selectedAIEngine)
                    print("🔧 AI engine set to: \(recorderVM.selectedAIEngine)")
                }
                
                print("🤖 Starting enhanced summarization...")
                
                // Use the enhanced AI engine for better summarization
                let enhancedSummary = try await summaryManager.generateEnhancedSummary(
                    from: transcriptText,
                    for: recording.url,
                    recordingName: recording.name,
                    recordingDate: recording.date
                )
                
                await MainActor.run {
                    print("✅ Enhanced summarization completed successfully")
                    print("📄 Summary length: \(enhancedSummary.summary.count) characters")
                    print("📋 Tasks found: \(enhancedSummary.tasks.count)")
                    print("🔔 Reminders found: \(enhancedSummary.reminders.count)")
                    
                    // Reload recordings to reflect any name changes
                    self.loadRecordings()
                    self.isGeneratingSummary = false
                    self.showSummary = true
                }
            } catch {
                print("❌ Enhanced summary generation failed: \(error)")
                
                await MainActor.run {
                    // Show error to user instead of falling back
                    self.isGeneratingSummary = false
                    
                    // Create an alert to show the error
                    if let summarizationError = error as? SummarizationError {
                        self.showErrorAlert = true
                        self.errorMessage = summarizationError.localizedDescription
                    } else {
                        self.showErrorAlert = true
                        self.errorMessage = error.localizedDescription
                    }
                }
                
                // Fallback to basic summarization if enhanced summary fails
                print("🔄 Falling back to basic summarization")
                
                // Generate summary first with full context
                let summaryResult = generateImprovedSummaryFromText(transcriptText)
                print("📄 Basic summary generated: \(summaryResult.count) characters")
                
                // Then extract tasks and reminders from the full transcript
                let tasksResult = extractTasksFromText(transcriptText)
                let remindersResult = extractRemindersFromText(transcriptText)
                
                print("📋 Basic extraction - Tasks: \(tasksResult.count), Reminders: \(remindersResult.count)")
                
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
                    print("🔄 Updated existing summary")
                } else {
                    self.summaryManager.saveSummary(summaryData)
                    print("💾 Saved new summary")
                }
                
                print("✅ Basic summarization completed successfully")
                // Reload recordings to reflect any name changes
                self.loadRecordings()
                self.isGeneratingSummary = false
                self.showSummary = true
                }
            }
        }
    }
    
    // Improved summary generation with full context analysis
    private func generateImprovedSummaryFromText(_ text: String) -> String {
        print("📊 Starting improved summary generation...")
        
        // Preprocess and validate the text
        let preprocessedText = ContentAnalyzer.preprocessText(text)
        let sentences = ContentAnalyzer.extractSentences(from: preprocessedText)
        
        guard !sentences.isEmpty else { 
            print("⚠️ No sentences found for summarization")
            return "No content to summarize." 
        }
        
        print("📝 Processing \(sentences.count) sentences")
        
        // Classify content type for context-aware summarization
        let contentType = ContentAnalyzer.classifyContent(preprocessedText)
        print("🏷️ Content classified as: \(contentType.rawValue)")
        
        // Extract key themes and topics from the full text
        let keyPhrases = ContentAnalyzer.extractKeyPhrases(from: preprocessedText, maxPhrases: 8)
        print("🔑 Key phrases identified: \(keyPhrases.joined(separator: ", "))")
        
        // Score sentences with enhanced importance calculation
        let scoredSentences = sentences.map { sentence in
            let baseScore = ContentAnalyzer.calculateSentenceImportance(sentence, in: preprocessedText)
            let contextScore = calculateContextualImportance(sentence, contentType: contentType, keyPhrases: keyPhrases)
            let finalScore = (baseScore * 0.7) + (contextScore * 0.3) // Weighted combination
            
            return (sentence: sentence, score: finalScore, baseScore: baseScore, contextScore: contextScore)
        }
        
        // Sort by final score
        let sortedSentences = scoredSentences.sorted { $0.score > $1.score }
        
        // Determine optimal summary length based on content
        let targetSentenceCount = calculateOptimalSummaryLength(
            totalSentences: sentences.count,
            contentType: contentType,
            averageSentenceLength: sentences.map { $0.count }.reduce(0, +) / sentences.count
        )
        
        print("🎯 Target summary length: \(targetSentenceCount) sentences")
        
        // Select sentences ensuring diversity and coherence
        let selectedSentences = selectDiverseSentences(
            from: sortedSentences,
            targetCount: targetSentenceCount,
            originalText: preprocessedText
        )
        
        // Create context-aware summary based on content type
        let summary = createContextualSummary(
            sentences: selectedSentences.map { $0.sentence },
            contentType: contentType,
            keyPhrases: keyPhrases,
            originalText: preprocessedText
        )
        
        print("✅ Summary generated: \(summary.count) characters")
        return summary
    }
    
    private func calculateContextualImportance(_ sentence: String, contentType: ContentType, keyPhrases: [String]) -> Double {
        var score: Double = 0.0
        let lowercased = sentence.lowercased()
        
        // Boost sentences containing key phrases
        for phrase in keyPhrases {
            if lowercased.contains(phrase.lowercased()) {
                score += 1.0
            }
        }
        
        // Content-type specific scoring
        switch contentType {
        case .meeting:
            let meetingKeywords = ["decided", "agreed", "action", "next step", "follow up", "deadline", "assigned", "responsible"]
            for keyword in meetingKeywords {
                if lowercased.contains(keyword) {
                    score += 1.5
                }
            }
            
        case .personalJournal:
            let journalKeywords = ["feel", "think", "realize", "learn", "discover", "grateful", "important", "significant"]
            for keyword in journalKeywords {
                if lowercased.contains(keyword) {
                    score += 1.2
                }
            }
            
        case .technical:
            let techKeywords = ["problem", "solution", "implement", "system", "process", "result", "conclusion", "recommend"]
            for keyword in techKeywords {
                if lowercased.contains(keyword) {
                    score += 1.3
                }
            }
            
        case .general:
            let generalKeywords = ["important", "main", "key", "significant", "conclusion", "summary", "overall"]
            for keyword in generalKeywords {
                if lowercased.contains(keyword) {
                    score += 1.0
                }
            }
        }
        
        return score
    }
    
    private func calculateOptimalSummaryLength(totalSentences: Int, contentType: ContentType, averageSentenceLength: Int) -> Int {
        let baseRatio: Double
        
        switch contentType {
        case .meeting:
            baseRatio = 0.3 // Meetings need more detail for action items
        case .technical:
            baseRatio = 0.35 // Technical content needs precision
        case .personalJournal:
            baseRatio = 0.25 // Personal content can be more concise
        case .general:
            baseRatio = 0.25 // General content standard ratio
        }
        
        let calculatedCount = Int(Double(totalSentences) * baseRatio)
        
        // Ensure reasonable bounds
        let minSentences = 2
        let maxSentences = min(8, totalSentences)
        
        return max(minSentences, min(maxSentences, calculatedCount))
    }
    
    private func selectDiverseSentences(from scoredSentences: [(sentence: String, score: Double, baseScore: Double, contextScore: Double)], targetCount: Int, originalText: String) -> [(sentence: String, score: Double, baseScore: Double, contextScore: Double)] {
        var selectedSentences: [(sentence: String, score: Double, baseScore: Double, contextScore: Double)] = []
        var remainingCandidates = scoredSentences
        
        // Always include the highest scoring sentence
        if let topSentence = remainingCandidates.first {
            selectedSentences.append(topSentence)
            remainingCandidates.removeFirst()
        }
        
        // Select remaining sentences ensuring diversity
        while selectedSentences.count < targetCount && !remainingCandidates.isEmpty {
            var bestCandidate: (sentence: String, score: Double, baseScore: Double, contextScore: Double)?
            var bestDiversityScore: Double = -1
            var bestIndex: Int = 0
            
            for (index, candidate) in remainingCandidates.enumerated() {
                // Calculate diversity score (how different this sentence is from already selected ones)
                let diversityScore = calculateDiversityScore(
                    candidate: candidate.sentence,
                    selected: selectedSentences.map { $0.sentence }
                )
                
                // Combine importance and diversity
                let combinedScore = (candidate.score * 0.7) + (diversityScore * 0.3)
                
                if combinedScore > bestDiversityScore {
                    bestDiversityScore = combinedScore
                    bestCandidate = candidate
                    bestIndex = index
                }
            }
            
            if let best = bestCandidate {
                selectedSentences.append(best)
                remainingCandidates.remove(at: bestIndex)
            } else {
                break
            }
        }
        
        return selectedSentences
    }
    
    private func calculateDiversityScore(candidate: String, selected: [String]) -> Double {
        guard !selected.isEmpty else { return 1.0 }
        
        let candidateWords = Set(candidate.lowercased().components(separatedBy: .whitespacesAndNewlines))
        
        var totalSimilarity: Double = 0
        for selectedSentence in selected {
            let selectedWords = Set(selectedSentence.lowercased().components(separatedBy: .whitespacesAndNewlines))
            let intersection = candidateWords.intersection(selectedWords)
            let union = candidateWords.union(selectedWords)
            let similarity = union.isEmpty ? 0 : Double(intersection.count) / Double(union.count)
            totalSimilarity += similarity
        }
        
        let averageSimilarity = totalSimilarity / Double(selected.count)
        return 1.0 - averageSimilarity // Higher score for more diverse content
    }
    
    private func createContextualSummary(sentences: [String], contentType: ContentType, keyPhrases: [String], originalText: String) -> String {
        let summaryPrefix: String
        
        switch contentType {
        case .meeting:
            summaryPrefix = "Meeting Summary: "
        case .personalJournal:
            summaryPrefix = "Personal Reflection: "
        case .technical:
            summaryPrefix = "Technical Discussion: "
        case .general:
            summaryPrefix = "Summary: "
        }
        
        // Join sentences with proper flow
        let mainSummary = sentences.joined(separator: " ")
        
        // Add key topics if they provide additional value
        let topKeyPhrases = Array(keyPhrases.prefix(3))
        let keyTopicsText = topKeyPhrases.isEmpty ? "" : " Key topics discussed: \(topKeyPhrases.joined(separator: ", "))."
        
        let fullSummary = summaryPrefix + mainSummary + keyTopicsText
        
        // Ensure summary doesn't exceed reasonable length
        if fullSummary.count > 500 {
            let truncated = String(fullSummary.prefix(500))
            if let lastSentenceEnd = truncated.lastIndex(of: ".") {
                return String(truncated[...lastSentenceEnd])
            } else {
                return truncated + "..."
            }
        }
        
        return fullSummary
    }
    
    private func extractTasksFromText(_ text: String) -> [String] {
        print("📋 Extracting tasks from full transcript context...")
        
        // Use the TaskExtractor with full transcript context
        let taskExtractor = TaskExtractor()
        let taskItems = taskExtractor.extractTasks(from: text)
        
        print("📋 Found \(taskItems.count) tasks")
        for (index, task) in taskItems.enumerated() {
            print("📋 Task \(index + 1): \(task.text) (Priority: \(task.priority.rawValue), Confidence: \(String(format: "%.2f", task.confidence)))")
        }
        
        return taskItems.map { $0.text }
    }
    
    private func extractRemindersFromText(_ text: String) -> [String] {
        print("🔔 Extracting reminders from full transcript context...")
        
        // Use the ReminderExtractor with full transcript context
        let reminderExtractor = ReminderExtractor()
        let reminderItems = reminderExtractor.extractReminders(from: text)
        
        print("🔔 Found \(reminderItems.count) reminders")
        for (index, reminder) in reminderItems.enumerated() {
            print("🔔 Reminder \(index + 1): \(reminder.text) (Urgency: \(reminder.urgency.rawValue), Confidence: \(String(format: "%.2f", reminder.confidence)))")
        }
        
        return reminderItems.map { $0.text }
}
