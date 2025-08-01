import SwiftUI
import AVFoundation
import Speech
import CoreLocation
import NaturalLanguage

struct SummariesView: View {
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @EnvironmentObject var appCoordinator: AppDataCoordinator
    @StateObject private var enhancedTranscriptionManager = EnhancedTranscriptionManager()
    @StateObject private var enhancedFileManager = EnhancedFileManager.shared
    @State private var recordings: [(recording: RegistryRecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)] = []
    @State private var selectedRecording: RegistryRecordingEntry?
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
                .onAppear {
                    loadRecordings()
                    // Configure the transcription manager with the selected engine
                    let selectedEngine = TranscriptionEngine(rawValue: UserDefaults.standard.string(forKey: "selectedTranscriptionEngine") ?? TranscriptionEngine.appleIntelligence.rawValue) ?? .appleIntelligence
                    enhancedTranscriptionManager.updateTranscriptionEngine(selectedEngine)
                    // Refresh file relationships
                    enhancedFileManager.refreshAllRelationships()
                }
                .onReceive(appCoordinator.objectWillChange) { _ in
                    // Refresh the view when coordinator changes
                    if PerformanceOptimizer.shouldLogEngineInitialization() {
                        AppLogger.shared.verbose("Received coordinator change notification", category: "SummariesView")
                    }
                    DispatchQueue.main.async {
                        self.refreshTrigger.toggle()
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
                    if PerformanceOptimizer.shouldLogEngineInitialization() {
                        AppLogger.shared.verbose("Received recording renamed notification, refreshing list", category: "SummariesView")
                    }
                    loadRecordings()
                }
        }
        .sheet(isPresented: $showSummary) {
            if let recording = selectedRecording {
                // Try to get enhanced summary first, fallback to legacy
                if let enhancedSummary = appCoordinator.getCompleteRecordingData(id: recording.id)?.summary {
                    EnhancedSummaryDetailView(
                        recording: RecordingFile(
                            url: recording.recordingURL,
                            name: recording.recordingName,
                            date: recording.recordingDate,
                            duration: recording.duration,
                            locationData: nil
                        ),
                        summaryData: enhancedSummary
                    )
                } else {
                    // FIX: Provide a View for the 'else' case to satisfy the ViewBuilder.
                    VStack(spacing: 16) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 50))
                            .foregroundColor(.secondary)
                        Text("Summary Not Available")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("A summary for this recording could not be found.")
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
            }
        }
        .onChange(of: showSummary) { _, newValue in
            if !newValue {
                // Sheet was dismissed, refresh the view
                if PerformanceOptimizer.shouldLogEngineInitialization() {
                    AppLogger.shared.verbose("Summary sheet dismissed, refreshing UI", category: "SummariesView")
                }
                // Force a UI refresh to update button states
                DispatchQueue.main.async {
                    self.refreshTrigger.toggle()
                }
            }
        }
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
        .sheet(isPresented: $showOrphanedSummaries) {
            OrphanedSummariesView()
        }
    }
    
    // MARK: - Main Content View
    
    private var mainContentView: some View {
        VStack {
            // Debug buttons at the top
            debugButtonsView
            
            // Main content
            Group {
                if recordings.isEmpty {
                    emptyStateView
                } else {
                    recordingsListView
                }
            }
        }
    }
    
    private var debugButtonsView: some View {
        HStack {
            Menu("Debug") {
                Button("Remove Duplicates") {
                    appCoordinator.removeDuplicateRecordings()
                    loadRecordings()
                }
                
                Button("Update Durations") {
                    appCoordinator.updateRecordingDurations()
                    loadRecordings()
                }
                
                Button("Debug Transcripts") {
                    appCoordinator.debugTranscriptStatus()
                    appCoordinator.forceReloadTranscripts()
                    loadRecordings()
                }
                
                Button("Debug Linking") {
                    appCoordinator.debugTranscriptLinking()
                }
                
                Button("Cleanup Duplicates") {
                    appCoordinator.cleanupDuplicateSummaries()
                    loadRecordings()
                }
                
                Button("Debug Summaries") {
                    debugSummaries()
                }
                
                Button("Fix Summary Links") {
                    appCoordinator.fixSummariesWithNilRecordingId()
                    loadRecordings()
                }
                
                Button("Link Summaries") {
                    appCoordinator.linkSummariesToRecordings()
                    loadRecordings()
                }
                
                Button("Link to Transcripts") {
                    appCoordinator.linkSummariesToRecordingsWithTranscripts()
                    loadRecordings()
                }
                
                Button("Recover Transcripts") {
                    appCoordinator.debugTranscriptRecovery()
                    loadRecordings()
                }
                
                Button("Recover From Disk") {
                    appCoordinator.recoverTranscriptsFromDisk()
                    loadRecordings()
                }
                
                Button("Refresh Recordings from Disk") {
                    appCoordinator.refreshRecordingsFromDisk()
                    loadRecordings()
                }
            }
            
            Button("Refresh") {
                loadRecordings()
            }
            
            Button("Orphaned") {
                showOrphanedSummaries = true
            }
            
            Spacer()
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("No Summaries Yet")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Record some audio and generate summaries to see them here.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Recordings List View
    
    private var recordingsListView: some View {
        List {
            ForEach(recordings, id: \.recording.id) { recordingData in
                recordingRowView(recordingData)
            }
        }
        .listStyle(PlainListStyle())
        .refreshable {
            loadRecordings()
        }
    }
    
    // MARK: - Recording Row View
    
    private func recordingRowView(_ recordingData: (recording: RegistryRecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)) -> some View {
        let recording = recordingData.recording
        let transcript = recordingData.transcript
        let summary = recordingData.summary
        
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(recording.recordingName)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text(recording.recordingDate, style: .date)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    statusIndicator(for: recording)
                    
                    if summary != nil {
                        Button(action: {
                            selectedRecording = recording
                            showSummary = true
                        }) {
                            HStack {
                                Image(systemName: "doc.text.magnifyingglass.fill")
                                Text("View Summary")
                            }
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                    } else if recording.summaryStatus == .processing {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Processing...")
                                .font(.caption2)
                        }
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    } else {
                        Button(action: {
                            print("🔘 Generate Summary button pressed for: \(recording.recordingName)")
                            generateSummary(for: recording)
                        }) {
                            HStack {
                                Image(systemName: "doc.text.magnifyingglass")
                                Text("Generate Summary")
                            }
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                        .disabled(isGeneratingSummary)
                        .onAppear {
                            print("🔍 Button state - isGeneratingSummary: \(isGeneratingSummary)")
                        }
                        .allowsHitTesting(true)

                    }
                }
            }
            
            if let transcript = transcript {
                Text(transcript.plainText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())

    }
    
    // MARK: - Status Indicator
    
    private func statusIndicator(for recording: RegistryRecordingEntry) -> some View {
        HStack(spacing: 4) {
            Image(systemName: recording.hasTranscript ? "checkmark.circle.fill" : "circle")
                .foregroundColor(recording.hasTranscript ? .green : .gray)
                .font(.caption)
            
            Image(systemName: recording.hasSummary ? "doc.text.magnifyingglass.fill" : "doc.text.magnifyingglass")
                .foregroundColor(recording.hasSummary ? .blue : .gray)
                .font(.caption)
        }
    }
    
    // MARK: - Helper Methods
    
    private func loadRecordings() {
        print("🔄 loadRecordings() called in SummariesView")
        
        let recordingsWithData = appCoordinator.getAllRecordingsWithData()
        print("📊 Total recordings from coordinator: \(recordingsWithData.count)")
        
        // Debug: Print each recording and its transcript status
        for (index, recordingData) in recordingsWithData.enumerated() {
            let recording = recordingData.recording
            let transcript = recordingData.transcript
            let summary = recordingData.summary
            
            print("   \(index): \(recording.recordingName)")
            print("      - Has transcript: \(transcript != nil)")
            print("      - Has summary: \(summary != nil)")
            if let summary = summary {
                print("      - Summary AI Method: \(summary.aiMethod)")
                print("      - Summary Generated At: \(summary.generatedAt)")
            }
            print("      - Recording has transcript flag: \(recording.hasTranscript)")
            print("      - Recording has summary flag: \(recording.hasSummary)")
        }
        
        // Filter to show recordings that have transcripts (so summaries can be generated)
        recordings = recordingsWithData.compactMap { recordingData in
            let recording = recordingData.recording
            let transcript = recordingData.transcript
            let summary = recordingData.summary
            
            // Include recordings that have transcripts (so summaries can be generated)
            if transcript != nil {
                print("✅ Including recording with transcript: \(recording.recordingName)")
                return (recording: recording, transcript: transcript, summary: summary)
            } else {
                print("❌ Excluding recording without transcript: \(recording.recordingName)")
                return nil
            }
        }
        
        print("📊 Final result: \(recordings.count) recordings with transcripts out of \(recordingsWithData.count) total recordings")
    }
    
    private func generateSummary(for recording: RegistryRecordingEntry) {
        print("🚀 generateSummary called for recording: \(recording.recordingName)")
        print("📁 Recording URL: \(recording.recordingURL)")
        print("📅 Recording date: \(recording.recordingDate)")
        
        isGeneratingSummary = true
        
        // Check engine status first
        print("🔧 Checking engine status...")
        appCoordinator.registryManager.checkEngineStatus()
        
        Task {
            do {
                print("🔍 Starting summary generation for recording: \(recording.recordingName)")
                
                // Get the transcript for this recording using the unified system
                print("🔍 Looking for transcript...")
                if let transcript = appCoordinator.getTranscript(for: recording.recordingURL) {
                    print("✅ Found transcript with \(transcript.segments.count) segments")
                    print("📝 Transcript text: \(transcript.plainText.prefix(100))...")
                    
                    // Generate summary using the app coordinator
                    print("🔧 Calling generateEnhancedSummary...")
                    let summary = try await appCoordinator.generateEnhancedSummary(
                        from: transcript.plainText,
                        for: recording.recordingURL,
                        recordingName: recording.recordingName,
                        recordingDate: recording.recordingDate
                    )
                    
                    print("✅ Summary generated successfully")
                    
                    // Add the summary to the coordinator
                    await MainActor.run {
                        print("📝 Adding summary to coordinator...")
                        print("   - Summary AI Method: \(summary.aiMethod)")
                        print("   - Summary Generated At: \(summary.generatedAt)")
                        print("   - Summary Recording ID: \(summary.recordingId?.uuidString ?? "nil")")
                        appCoordinator.addSummary(summary)
                        isGeneratingSummary = false
                        
                        // Force a UI refresh
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            loadRecordings() // Refresh the list
                            print("✅ Summary added to coordinator and UI refreshed")
                        }
                    }
                } else {
                    print("❌ No transcript found for recording: \(recording.recordingName)")
                    print("🔍 Checking if recording exists in coordinator...")
                    let allRecordings = appCoordinator.getAllRecordingsWithData()
                    print("📊 Total recordings in coordinator: \(allRecordings.count)")
                    for (index, recData) in allRecordings.enumerated() {
                        print("   \(index): \(recData.recording.recordingName) - has transcript: \(recData.transcript != nil)")
                    }
                    
                    await MainActor.run {
                        errorMessage = "No transcript available for this recording"
                        showErrorAlert = true
                        isGeneratingSummary = false
                    }
                }
            } catch {
                print("❌ Error generating summary: \(error)")
                print("🔍 Error details: \(error)")
                await MainActor.run {
                    errorMessage = "Failed to generate summary: \(error.localizedDescription)"
                    showErrorAlert = true
                    isGeneratingSummary = false
                }
            }
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private func debugSummaries() {
        print("🔍 Debugging summaries...")
        
        let recordingsWithData = appCoordinator.getAllRecordingsWithData()
        print("📊 Total recordings: \(recordingsWithData.count)")
        
        for (index, recordingData) in recordingsWithData.enumerated() {
            let recording = recordingData.recording
            let summary = recordingData.summary
            
            print("   \(index): \(recording.recordingName)")
            print("      - Recording ID: \(recording.id)")
            print("      - Has summary: \(summary != nil)")
            
            if let summary = summary {
                print("      - Summary AI Method: \(summary.aiMethod)")
                print("      - Summary Generated At: \(summary.generatedAt)")
                print("      - Summary Recording ID: \(summary.recordingId?.uuidString ?? "nil")")
                print("      - Summary ID: \(summary.id)")
            }
        }
        
        // Also check all summaries in the registry
        print("📊 All summaries in registry:")
        let allSummaries = appCoordinator.registryManager.enhancedSummaries
        for (index, summary) in allSummaries.enumerated() {
            print("   \(index): \(summary.recordingName)")
            print("      - AI Method: \(summary.aiMethod)")
            print("      - Generated At: \(summary.generatedAt)")
            print("      - Recording ID: \(summary.recordingId?.uuidString ?? "nil")")
            print("      - Summary ID: \(summary.id)")
        }
    }
}

// MARK: - Preview

#Preview {
    SummariesView()
        .environmentObject(AppDataCoordinator())
        .environmentObject(AudioRecorderViewModel())
}
