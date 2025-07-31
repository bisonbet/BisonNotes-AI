import SwiftUI
import AVFoundation
import Speech
import CoreLocation
import NaturalLanguage

struct SummariesView: View {
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @StateObject private var summaryManager = SummaryManager.shared
    @StateObject private var transcriptManager = TranscriptManager.shared
    @StateObject private var enhancedTranscriptionManager = EnhancedTranscriptionManager()
    @StateObject private var enhancedFileManager = EnhancedFileManager.shared
    @State private var recordings: [RecordingFile] = []
    @State private var selectedRecording: RecordingFile?
    @State private var isGeneratingSummary = false
    @State private var selectedLocationData: LocationData?
    @State private var locationAddresses: [URL: String] = [:]
    @State private var showSummary = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var refreshTrigger = false
    @State private var showOrphanedSummaries = false

    // MARK: - Body
    
    var body: some View {
        NavigationView {
            mainContentView
                .navigationTitle("Summaries")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: {
                            showOrphanedSummaries = true
                        }) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .foregroundColor(.orange)
                        }
                        .help("View orphaned summaries")
                    }
                }
                .onAppear {
                    loadRecordings()
                    // Configure the summary manager with the selected AI engine
                    // Set the AI engine for summarization
                    let defaultEngine = UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? "Enhanced Apple Intelligence"
                    summaryManager.setEngine(defaultEngine) // Use proper default instead of hardcoded "openai"
                    
                    // Configure the transcription manager with the selected engine
                    let selectedEngine = TranscriptionEngine(rawValue: UserDefaults.standard.string(forKey: "selectedTranscriptionEngine") ?? TranscriptionEngine.appleIntelligence.rawValue) ?? .appleIntelligence
                    enhancedTranscriptionManager.updateTranscriptionEngine(selectedEngine)
                    
                    // Refresh file relationships
                    enhancedFileManager.refreshAllRelationships()
                }
                .onReceive(summaryManager.objectWillChange) { _ in
                    // Refresh the view when summary manager changes
                    // Only log if verbose logging is enabled
                    if PerformanceOptimizer.shouldLogEngineInitialization() {
                        AppLogger.shared.verbose("Received summary manager change notification", category: "SummariesView")
                    }
                    DispatchQueue.main.async {
                        self.refreshTrigger.toggle()
                        // Only log if verbose logging is enabled
                        if PerformanceOptimizer.shouldLogEngineInitialization() {
                            AppLogger.shared.verbose("Toggled refresh trigger to \(self.refreshTrigger)", category: "SummariesView")
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                    // Refresh when app comes to foreground
                    loadRecordings()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RecordingRenamed"))) { _ in
                    // Refresh recordings list when a recording is renamed
                    // Only log if verbose logging is enabled
                    if PerformanceOptimizer.shouldLogEngineInitialization() {
                        AppLogger.shared.verbose("Received recording renamed notification, refreshing list", category: "SummariesView")
                    }
                    loadRecordings()
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
        .onChange(of: showSummary) { _, newValue in
            if !newValue {
                // Sheet was dismissed, refresh the view
                // Only log if verbose logging is enabled
                if PerformanceOptimizer.shouldLogEngineInitialization() {
                    AppLogger.shared.verbose("Summary sheet dismissed, refreshing UI", category: "SummariesView")
                }
                
                // Force a UI refresh to update button states
                DispatchQueue.main.async {
                    // Additional check to ensure summary state is updated
                    if let recording = self.selectedRecording {
                        let hasSummary = self.summaryManager.hasSummary(for: recording.url)
                        // Only log if verbose logging is enabled
                        if PerformanceOptimizer.shouldLogEngineInitialization() {
                            AppLogger.shared.verbose("After sheet dismissal - hasSummary for \(recording.name): \(hasSummary)", category: "SummariesView")
                        }
                    }
                    
                    // Force complete UI refresh
                    self.forceRefreshUI()
                }
            }
        }
        .sheet(item: $selectedLocationData) { locationData in
            LocationDetailView(locationData: locationData)
        }
        .sheet(isPresented: $showOrphanedSummaries) {
            OrphanedSummariesView()
        }
        .alert("Summary Generation Error", isPresented: $showErrorAlert) {
            Button("OK") {
                showErrorAlert = false
            }
        } message: {
            Text(errorMessage)
        }
        .alert("Whisper Fallback", isPresented: $enhancedTranscriptionManager.showingWhisperFallbackAlert) {
            Button("OK") {
                enhancedTranscriptionManager.showingWhisperFallbackAlert = false
            }
        } message: {
            Text(enhancedTranscriptionManager.whisperFallbackMessage)
        }
    }

    // MARK: - View Components

    @ViewBuilder
    private var mainContentView: some View {
        VStack {
            if recordings.isEmpty {
                emptyStateView
            } else {
                recordingsListView
            }
        }
    }
    
    @ViewBuilder
    private var emptyStateView: some View {
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
    }
    
    @ViewBuilder
    private var recordingsListView: some View {
        List(recordings, id: \.url) { recording in
            recordingRow(for: recording)
        }
    }
    
    @ViewBuilder
    private func recordingRow(for recording: RecordingFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(recording.name)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(recording.dateString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    // File availability indicator
                    if let relationships = enhancedFileManager.getFileRelationships(for: recording.url) {
                        FileAvailabilityIndicator(
                            status: relationships.availabilityStatus,
                            showLabel: true,
                            size: .small
                        )
                        
                        // Show warning if audio source is no longer available
                        if relationships.isOrphaned {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                                Text("Audio source no longer available")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                    
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
                summaryButton(for: recording)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func summaryButton(for recording: RecordingFile) -> some View {
        // Check both enhanced and legacy summaries for more reliable detection
        let hasEnhancedSummary = summaryManager.hasEnhancedSummary(for: recording.url)
        let hasLegacySummary = summaryManager.getSummary(for: recording.url) != nil
        let hasSummary = hasEnhancedSummary || hasLegacySummary
        let isGenerating = isGeneratingSummary && selectedRecording?.url == recording.url
        
        Button(action: {
            // Debug logging to help identify the issue
            if PerformanceOptimizer.shouldLogEngineInitialization() {
                AppLogger.shared.verbose("Summary button state for \(recording.name): enhanced=\(hasEnhancedSummary), legacy=\(hasLegacySummary), total=\(hasSummary)", category: "SummariesView")
            }
            
            selectedRecording = recording
            
            if hasSummary {
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
                if isGenerating {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: hasSummary ? "eye" : "doc.text.magnifyingglass")
                }
                Text(hasSummary ? "View Summary" : "Generate Summary")
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(hasSummary ? Color.green : Color.accentColor)
            .foregroundColor(.white)
            .cornerRadius(8)
        }
        .disabled(isGeneratingSummary)
        .id("\(recording.url.absoluteString)-\(hasSummary)-\(refreshTrigger)") // Force re-evaluation when state changes
    }

    // MARK: - Data Handling
    
    private func forceRefreshUI() {
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineInitialization() {
            AppLogger.shared.verbose("Forcing UI refresh", category: "SummariesView")
        }
        DispatchQueue.main.async {
            // Trigger multiple refresh mechanisms
            self.refreshTrigger.toggle()
            
            // Reload recordings to ensure fresh data
            self.loadRecordings()
            
            // Force summary manager to refresh its state
            self.summaryManager.objectWillChange.send()
            
            // Additional refresh after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.refreshTrigger.toggle()
            }
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
                loadLocationAddress(for: recording)
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
    
    private func loadLocationAddress(for recording: RecordingFile) {
        guard let locationData = recording.locationData else { return }
        
        let location = CLLocation(latitude: locationData.latitude, longitude: locationData.longitude)
        // Use a default location manager since AudioRecorderViewModel doesn't have one
        let locationManager = LocationManager()
        locationManager.reverseGeocodeLocation(location) { address in
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
            AppLogger.shared.error("Error getting duration: \(error)", category: "SummariesView")
            return 0
        }
    }
    
    private func generateTranscriptAndSummary(for recording: RecordingFile) async {
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineInitialization() {
            AppLogger.shared.verbose("Starting generateTranscriptAndSummary for: \(recording.name)", category: "SummariesView")
            AppLogger.shared.verbose("Looking for transcript with URL: \(recording.url)", category: "SummariesView")
            AppLogger.shared.verbose("Total transcripts in manager: \(transcriptManager.transcripts.count)", category: "SummariesView")
            
            // Debug: Print all stored transcript URLs
            for (index, transcript) in transcriptManager.transcripts.enumerated() {
                AppLogger.shared.verbose("Transcript \(index): \(transcript.recordingName) - \(transcript.recordingURL)", category: "SummariesView")
            }
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
                        let transcriptData = TranscriptData(
                            recordingURL: recording.url,
                            recordingName: recording.name,
                            recordingDate: recording.date,
                            segments: result.segments
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
        print("🔧 Using transcription engine: Apple Intelligence")
        
        Task {
            do {
                // Add timeout to prevent infinite CPU usage
                let result = try await withTimeout(seconds: 1800) { // 30 minute timeout
                    try await enhancedTranscriptionManager.transcribeAudioFile(at: recording.url, using: .appleIntelligence)
                }
                
                print("📊 Transcription completed - Success: \(result.success), Text length: \(result.fullText.count)")
                
                if result.success && !result.fullText.isEmpty {
                    // Validate transcript quality before proceeding
                    let transcriptText = result.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    // Check if this is a pending AWS transcription
                    if isPendingAWSTranscription(transcriptText) {
                        print("⏳ Detected pending AWS transcription, waiting for completion...")
                        
                        // Save the placeholder transcript so we can track it
                        let transcriptData = TranscriptData(
                            recordingURL: recording.url,
                            recordingName: recording.name,
                            recordingDate: recording.date,
                            segments: result.segments
                        )
                        
                        self.transcriptManager.saveTranscript(transcriptData)
                        print("💾 Placeholder transcript saved for tracking")
                        
                        // Wait for the actual transcription to complete
                        await waitForTranscriptionCompletion(for: recording)
                    } else if isValidTranscriptForSummarization(transcriptText) {
                        print("✅ Transcript validation passed, saving and generating summary...")
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
    
    // MARK: - Summary Generation
    
    private func isValidTranscriptForSummarization(_ transcriptText: String) -> Bool {
        // Count words in the transcript
        let words = transcriptText.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty && $0.count > 1 }
        
        print("📝 Transcript word count: \(words.count) words")
        
        // If transcript has 50 words or less, it's valid for summarization (will be shown as-is)
        if words.count <= 50 {
            print("📝 Transcript has 50 words or less (\(words.count) words) - will be shown as-is")
            return true
        }
        
        // For transcripts with more than 50 words, check for placeholder text patterns
        let lowercased = transcriptText.lowercased()
        let placeholderPatterns = [
            "transcription in progress",
            "processing audio",
            "please wait",
            "transcribing",
            "loading",
            "failed to transcribe",
            "no audio detected",
            "silence detected",
            "aws transcription coming soon",
            "openai api compatible summaries coming soon",
            "transcription job started:",
            "job is running in background",
            "check status later to retrieve results",
            "transcription job",
            "is running in background"
        ]
        
        // Check for pure error messages (transcript consists mostly of error text)
        let errorPatterns = [
            "error",
            "failed",
            "exception",
            "timeout"
        ]
        
        // Count how many error words appear in the text
        var errorWordCount = 0
        
        for word in words {
            let lowercasedWord = word.lowercased()
            for pattern in errorPatterns {
                if lowercasedWord.contains(pattern) {
                    errorWordCount += 1
                    break
                }
            }
        }
        
        // If more than 30% of words are error-related, it's likely an error message
        let errorRatio = Double(errorWordCount) / Double(words.count)
        if errorRatio > 0.3 {
            print("📝 Transcript contains too many error words: \(errorWordCount)/\(words.count) (\(Int(errorRatio * 100))%)")
            return false
        }
        
        // Check for pure placeholder patterns - be more intelligent about it
        for pattern in placeholderPatterns {
            if lowercased.contains(pattern) {
                // For single words like "loading", check if it's part of a larger placeholder phrase
                if pattern == "loading" {
                    // Check if "loading" appears in a context that suggests it's placeholder text
                    let loadingContexts = [
                        "loading transcription",
                        "loading audio",
                        "loading file",
                        "loading please wait",
                        "loading...",
                        "loading -",
                        "loading:"
                    ]
                    
                    let isPlaceholderLoading = loadingContexts.contains { context in
                        lowercased.contains(context)
                    }
                    
                    if !isPlaceholderLoading {
                        print("📝 Transcript contains 'loading' but appears to be legitimate content, allowing summarization")
                        continue // Skip this pattern, it's likely legitimate content
                    }
                }
                
                print("📝 Transcript contains placeholder text: \(pattern)")
                return false
            }
        }
        
        // Check for meaningful word count (at least 10 actual words for longer transcripts)
        guard words.count >= 10 else {
            print("📝 Transcript has insufficient word count: \(words.count) words")
            return false
        }
        
        // Check for repetitive content (might indicate transcription errors)
        let uniqueWords = Set(words.map { $0.lowercased() })
        let uniqueRatio = Double(uniqueWords.count) / Double(words.count)
        
        // Lower threshold for repetitive content to allow song lyrics, poetry, etc.
        // Also check if content appears to be song lyrics or artistic content
        let transcriptLowercased = transcriptText.lowercased()
        let isLikelySongLyrics = transcriptLowercased.contains("looking good") ||
                                transcriptLowercased.contains("you know") ||
                                transcriptLowercased.contains("all right") ||
                                transcriptLowercased.contains("what was i thinking") ||
                                transcriptLowercased.contains("um") ||
                                transcriptLowercased.contains("uh")
        
        let minimumRatio = isLikelySongLyrics ? 0.15 : 0.3 // Lower threshold for song-like content
        
        guard uniqueRatio > minimumRatio else {
            print("📝 Transcript appears too repetitive: \(String(format: "%.1f", uniqueRatio * 100))% unique words (threshold: \(String(format: "%.1f", minimumRatio * 100))%)")
            if isLikelySongLyrics {
                print("🎵 Content appears to be song lyrics or artistic content - allowing summarization")
                return true
            }
            return false
        }
        
        print("✅ Transcript validated for summarization: \(words.count) words, \(String(format: "%.1f", uniqueRatio * 100))% unique, error ratio: \(Int(errorRatio * 100))%")
        return true
    }
    
    private func generateSummaryFromTranscript(for recording: RecordingFile, transcriptText: String) {
        print("📋 Starting summary generation for: \(recording.name)")
        print("📝 Transcript length: \(transcriptText.count) characters")
        print("🤖 Selected AI engine: \(UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? "Enhanced Apple Intelligence")") // Use proper default instead of hardcoded "openai"
        
        Task {
            do {
                // Ensure the correct AI engine is set before generating summary
                await MainActor.run {
                    let defaultEngine = UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? "Enhanced Apple Intelligence"
                    summaryManager.setEngine(defaultEngine) // Use proper default instead of hardcoded "openai"
                    print("🔧 AI engine set to: \(defaultEngine)")
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
                    
                    // Check if summary was saved properly
                    let hasSummary = summaryManager.hasSummary(for: recording.url)
                    let hasEnhanced = summaryManager.hasEnhancedSummary(for: recording.url)
                    print("🔍 Summary saved check: hasSummary=\(hasSummary), hasEnhanced=\(hasEnhanced)")
                    
                    // Force UI refresh by triggering state changes
                    self.isGeneratingSummary = false
                    
                    // Trigger multiple refresh mechanisms to ensure UI updates
                    self.refreshTrigger.toggle()
                    
                    // Force a complete UI refresh
                    self.forceRefreshUI()
                    
                    // Small delay to ensure UI updates, then show summary
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        // Double-check that summary is available before showing
                        if self.summaryManager.hasSummary(for: recording.url) {
                            self.showSummary = true
                        } else {
                            print("⚠️ Summary not found after generation, forcing another refresh")
                            self.forceRefreshUI()
                        }
                    }
                }
            } catch {
                print("❌ Enhanced summary generation failed: \(error)")
                
                await MainActor.run {
                    self.isGeneratingSummary = false
                    self.forceRefreshUI()
                    self.showErrorAlert = true
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
