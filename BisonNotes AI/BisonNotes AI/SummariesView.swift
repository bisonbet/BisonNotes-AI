import SwiftUI
import AVFoundation
import Speech
import CoreLocation
import NaturalLanguage

struct SummariesView: View {
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @EnvironmentObject var appCoordinator: AppDataCoordinator
    @Environment(\.isEmbeddedInSplitView) private var isEmbeddedInSplitView
    @StateObject private var enhancedTranscriptionManager = EnhancedTranscriptionManager()
    @StateObject private var enhancedFileManager = EnhancedFileManager.shared
    @StateObject private var iCloudManager = iCloudStorageManager()
    @State private var recordings: [(recording: RecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)] = []
    @State private var selectedRecording: RecordingEntry?
    @State private var isGeneratingSummary = false
    @State private var generatingSummaryRecordingId: UUID?
    @State private var selectedLocationData: LocationData?
    @State private var locationAddresses: [URL: String] = [:]
    @State private var showSummary = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var errorRecoverySuggestion = ""
    @State private var refreshTrigger = false
    @State private var showingFirstTimeiCloudPrompt = false
    @State private var showingiCloudDataFoundPrompt = false
    @State private var searchText = ""
    @State private var showDateFilter = false
    @State private var dateFilterStart: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var dateFilterEnd: Date = Date()
    @State private var isDateFilterActive = false

    @AppStorage("hasSeeniCloudPrompt") private var hasSeeniCloudPrompt = false


    // MARK: - Body
    
    var body: some View {
        AdaptiveNavigationWrapper {
            mainContentView
                .navigationTitle("Summaries")
                .searchable(text: $searchText, prompt: "Search summaries, tasks, reminders...")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: { showDateFilter = true }) {
                            Image(systemName: isDateFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        }
                    }
                }
                .onAppear {
                    // First refresh file relationships
                    enhancedFileManager.refreshAllRelationships()
                    
                    // Then load recordings after a brief delay to ensure relationships are established
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        loadRecordings()
                    }
                    
                    // Configure the transcription manager with the selected engine
                    let selectedEngine = TranscriptionEngine(rawValue: UserDefaults.standard.string(forKey: "selectedTranscriptionEngine") ?? TranscriptionEngine.whisperKit.rawValue) ?? .whisperKit
                    enhancedTranscriptionManager.updateTranscriptionEngine(selectedEngine)
                    
                    // Show first-time iCloud prompt if not seen before and there are summaries
                    checkForFirstTimeiCloudPrompt()
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
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SummaryDeleted"))) { _ in
                    // Refresh when a summary is deleted
                    print("📱 SummariesView: Received summary deletion notification, refreshing...")
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
                if let recordingId = recording.id,
                   let enhancedSummary = appCoordinator.getCompleteRecordingData(id: recordingId)?.summary {
                    SummaryDetailView(
                        recording: RecordingFile(
                            url: URL(string: recording.recordingURL ?? "") ?? URL(fileURLWithPath: ""),
                            name: recording.recordingName ?? "Unknown",
                            date: recording.recordingDate ?? Date(),
                            duration: recording.duration,
                            locationData: appCoordinator.coreDataManager.getLocationData(for: recording)
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
            if errorRecoverySuggestion.isEmpty {
                Text(errorMessage)
            } else {
                Text("\(errorMessage)\n\n\(errorRecoverySuggestion)")
            }
        }
        .alert("Download Summaries from iCloud?", isPresented: $showingFirstTimeiCloudPrompt) {
            Button("Not Now") {
                hasSeeniCloudPrompt = true
            }
            Button("Download") {
                hasSeeniCloudPrompt = true
                Task {
                    do {
                        let count = try await iCloudManager.downloadSummariesFromCloud(appCoordinator: appCoordinator)
                        print("✅ Downloaded \(count) summaries from iCloud")
                        loadRecordings() // Refresh the view
                    } catch {
                        print("❌ Failed to download summaries: \(error)")
                        await MainActor.run {
                            errorMessage = "Failed to download summaries: \(error.localizedDescription)"
                            errorRecoverySuggestion = ""
                            showErrorAlert = true
                        }
                    }
                }
            }
        } message: {
            Text("We found summaries in your iCloud that aren't on this device. Would you like to download them? This won't affect your existing summaries.")
        }
        .alert("iCloud Data Detected", isPresented: $showingiCloudDataFoundPrompt) {
            Button("Keep Disabled") {
                // User chooses to keep iCloud sync disabled
            }
            Button("Enable iCloud Sync") {
                Task {
                    // Enable iCloud sync
                    await MainActor.run {
                        iCloudManager.isEnabled = true
                    }

                    // Now download the summaries
                    do {
                        let count = try await iCloudManager.downloadSummariesFromCloud(appCoordinator: appCoordinator)
                        print("✅ Downloaded \(count) summaries from iCloud")
                        loadRecordings() // Refresh the view
                    } catch {
                        print("❌ Failed to download summaries: \(error)")
                        await MainActor.run {
                            errorMessage = "Failed to download summaries: \(error.localizedDescription)"
                            errorRecoverySuggestion = ""
                            showErrorAlert = true
                        }
                    }
                }
            }
        } message: {
            Text("We detected summaries in your iCloud account, but iCloud sync is currently disabled. Would you like to enable iCloud sync to download your cloud summaries? This will allow you to access all your data across devices.")
        }
        .sheet(isPresented: $showDateFilter) {
            dateFilterSheet
        }
    } // End of body variable

    // MARK: - Main Content View
    
    private var mainContentView: some View {
        let filtered = filteredRecordings
        return Group {
            if recordings.isEmpty {
                emptyStateView
            } else if filtered.isEmpty {
                noResultsView
            } else {
                VStack(spacing: 0) {
                    if isDateFilterActive {
                        activeDateFilterBanner
                    }
                    recordingsListView(filtered)
                }
            }
        }
    }

    private var activeDateFilterBanner: some View {
        HStack {
            Image(systemName: "calendar")
                .foregroundColor(.blue)
            Text("\(dateFilterStart, format: .dateTime.month().day()) - \(dateFilterEnd, format: .dateTime.month().day())")
                .font(.subheadline)
            Spacer()
            Button(action: {
                isDateFilterActive = false
                refreshTrigger.toggle()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
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

    // MARK: - No Results View

    private var noResultsView: some View {
        VStack(spacing: 16) {
            Image(systemName: isDateFilterActive ? "calendar.badge.exclamationmark" : "magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No Results")
                .font(.title2)
                .fontWeight(.semibold)

            Text(noResultsMessage)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            if isDateFilterActive || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Clear Filters") {
                    searchText = ""
                    isDateFilterActive = false
                    refreshTrigger.toggle()
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsMessage: String {
        let hasSearch = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if hasSearch && isDateFilterActive {
            return "No summaries match \"\(searchText)\" in the selected date range."
        } else if hasSearch {
            return "No summaries match \"\(searchText)\"."
        } else if isDateFilterActive {
            return "No summaries found between \(dateFilterStart.formatted(date: .abbreviated, time: .omitted)) and \(dateFilterEnd.formatted(date: .abbreviated, time: .omitted))."
        } else {
            return "No summaries found."
        }
    }

    // MARK: - Date Filter Sheet

    private var dateFilterSheet: some View {
        NavigationView {
            Form {
                Section {
                    DatePicker("From", selection: $dateFilterStart, in: ...Date(), displayedComponents: .date)
                    DatePicker("To", selection: $dateFilterEnd, in: dateFilterStart...Date(), displayedComponents: .date)
                }

                if isDateFilterActive {
                    Section {
                        Button(role: .destructive) {
                            isDateFilterActive = false
                            showDateFilter = false
                            refreshTrigger.toggle()
                        } label: {
                            HStack {
                                Spacer()
                                Text("Clear Filter")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Filter by Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showDateFilter = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        isDateFilterActive = true
                        showDateFilter = false
                        refreshTrigger.toggle()
                    }
                }
            }
        }
    }

    // MARK: - Recordings List View

    private func recordingsListView(_ filtered: [(recording: RecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)]) -> some View {
        // Filter out recordings with nil dates and create wrapper struct with non-optional dates
        struct RecordingWithDate {
            let recording: RecordingEntry
            let transcript: TranscriptData?
            let summary: EnhancedSummaryData?
            let date: Date
        }

        let recordingsWithDates: [RecordingWithDate] = filtered.compactMap { item in
            guard let date = item.recording.recordingDate else { return nil }
            return RecordingWithDate(
                recording: item.recording,
                transcript: item.transcript,
                summary: item.summary,
                date: date
            )
        }

        // Group by date section
        let sectioned = DateSectionHelper.groupBySection(recordingsWithDates, dateKeyPath: \.date)

        return List {
            ForEach(sectioned, id: \.section) { sectionData in
                Section(header: Text(sectionData.section.title)) {
                    ForEach(sectionData.items, id: \.recording.objectID) { itemWithDate in
                        recordingRowView((recording: itemWithDate.recording, transcript: itemWithDate.transcript, summary: itemWithDate.summary))
                    }
                }
            }
        }
        .listStyle(PlainListStyle())
        .refreshable {
            loadRecordings()
        }
        .id("list-\(isDateFilterActive)-\(dateFilterStart)-\(dateFilterEnd)-\(searchText)")
    }
    
    // MARK: - Recording Row View
    
    private func recordingRowView(_ recordingData: (recording: RecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)) -> some View {
        let recording = recordingData.recording
        let transcript = recordingData.transcript
        let summary = recordingData.summary
        
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(recording.recordingName ?? "Unknown Recording")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text(UserPreferences.shared.formatMediumDateTime(recording.recordingDate ?? Date()))
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
                                Image(systemName: "doc.text.fill")
                                Text("View Summary")
                            }
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                    } else if recording.summaryStatus == ProcessingStatus.processing.rawValue || (isGeneratingSummary && generatingSummaryRecordingId == recording.id) {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Generating...")
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
                            guard !isGeneratingSummary else { return }
                            print("🔘 Generate Summary button pressed for: \(recording.recordingName ?? "Unknown")")
                            generateSummary(for: recording)
                        }) {
                            HStack {
                                Image(systemName: "doc.text.magnifyingglass")
                                Text("Generate Summary")
                            }
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(isGeneratingSummary ? Color.gray : Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                        .disabled(isGeneratingSummary)
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())

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
    
    private func statusIndicator(for recording: RecordingEntry) -> some View {
        HStack(spacing: 4) {
            Image(systemName: (recording.transcript != nil) ? "checkmark.circle.fill" : "circle")
                .foregroundColor((recording.transcript != nil) ? .green : .gray)
                .font(.caption)
            
            Image(systemName: (recording.summary != nil) ? "doc.text.fill" : "doc.text.magnifyingglass")
                .foregroundColor((recording.summary != nil) ? .blue : .gray)
                .font(.caption)
        }
    }
    
    // MARK: - Helper Methods
    
    private func loadRecordings() {
        // URL sync is now only needed on app startup - getAbsoluteURL() handles runtime resolution
        
        let recordingsWithData = appCoordinator.getAllRecordingsWithData()
        
        // Show recordings that either have a transcript (can generate) OR already have a summary
        recordings = recordingsWithData.compactMap { recordingData in
            let recording = recordingData.recording
            let transcript = recordingData.transcript
            let summary = recordingData.summary
            
            if transcript != nil || summary != nil || recording.summary != nil {
                return (recording: recording, transcript: transcript, summary: summary)
            } else {
                return nil
            }
        }
        
        // Debug Core Data state check (logging removed)
        Task { @MainActor in
            // Check what's actually in Core Data
            let allRecordings = appCoordinator.coreDataManager.getAllRecordings()
            let allSummaries = appCoordinator.coreDataManager.getAllSummaries()

            if allSummaries.count > 0 && allRecordings.count < allSummaries.count {
                // Attempt to repair orphaned summaries if needed

                // Try to repair the orphaned summaries using CoreDataManager
                let repairedCount = appCoordinator.coreDataManager.repairOrphanedSummaries()

                if repairedCount > 0 {
                    print("✅ Repaired \(repairedCount) orphaned summaries")
                    // Reload the view after repair
                    DispatchQueue.main.async {
                        self.loadRecordings()
                    }
                }
            }
        }

        // Check if we should show the first-time iCloud prompt
        checkForFirstTimeiCloudPrompt()
    }
    
    private func generateSummary(for recording: RecordingEntry) {
        print("🚀 generateSummary called for recording: \(recording.recordingName ?? "unknown")")
        print("📁 Recording URL: \(recording.recordingURL ?? "unknown")")
        print("📅 Recording date: \(recording.recordingDate ?? Date())")
        
        isGeneratingSummary = true
        generatingSummaryRecordingId = recording.id
        
        // Engine status checking is no longer needed with the simplified system
        print("🔧 Starting summary generation...")
        
        Task {
            var job: ProcessingJob?
            do {
                print("🔍 Starting summary generation for recording: \(recording.recordingName ?? "Unknown")")
                
                // Get the transcript for this recording using the new Core Data system
                print("🔍 Looking for transcript...")
                // TODO: Update to use new Core Data system with UUID
                // For now, find the recording by URL and get its transcript
                
                if let recordingURL = appCoordinator.getAbsoluteURL(for: recording),
                   let coreDataRecording = appCoordinator.getRecording(url: recordingURL),
                   let recordingId = coreDataRecording.id,
                   let transcript = appCoordinator.getTranscriptData(for: recordingId) {
                    print("✅ Found transcript with \(transcript.segments.count) segments")
                    print("📝 Transcript text: \(transcript.plainText.prefix(100))...")
                    
                    // Generate summary using the transcript
                    print("🔧 Generating summary for recording: \(recording.recordingName ?? "Unknown")")
                    
                    // Get the selected AI engine
                    let selectedEngine = UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? "On-Device AI"
                    print("🤖 Using AI engine: \(selectedEngine)")

                    // Prepare for background tracking
                    let transcriptText = transcript.textForSummarization
                    let recordingURL = URL(string: recording.recordingURL ?? "") ?? URL(fileURLWithPath: "")
                    let recordingName = recording.recordingName ?? "Unknown Recording"
                    let recordingDate = recording.recordingDate ?? Date()

                    job = ProcessingJob(
                        type: .summarization(engine: selectedEngine),
                        recordingURL: recordingURL,
                        recordingName: recordingName
                    )
                    if let job = job {
                        await BackgroundProcessingManager.shared.trackExternalJob(job)
                        let processingJob = job.withStatus(.processing)
                        await BackgroundProcessingManager.shared.updateExternalJob(processingJob)
                    }

                    print("📝 Generating enhanced summary for transcript with \(transcriptText.count) characters")

                    // Use the SummaryManager to generate the actual summary
                    let enhancedSummary = try await SummaryManager.shared.generateEnhancedSummary(
                        from: transcriptText,
                        for: recordingURL,
                        recordingName: recordingName,
                        recordingDate: recordingDate,
                        coordinator: appCoordinator,
                        engineName: selectedEngine
                    )

                    if let job = job {
                        let completedJob = job.withStatus(.completed).withProgress(1.0)
                        await BackgroundProcessingManager.shared.updateExternalJob(completedJob)
                    }
                    
                    print("✅ Enhanced summary generated successfully")
                    print("📄 Summary length: \(enhancedSummary.summary.count) characters")
                    print("📋 Tasks: \(enhancedSummary.tasks.count)")
                    print("📋 Reminders: \(enhancedSummary.reminders.count)")
                    print("📋 Titles: \(enhancedSummary.titles.count)")
                    
                    // Create summary entry in Core Data using the workflow manager
                let summaryId = self.appCoordinator.workflowManager.createSummary(
                    for: recordingId,
                    transcriptId: transcript.id,
                    summary: enhancedSummary.summary,
                    tasks: enhancedSummary.tasks,
                    reminders: enhancedSummary.reminders,
                    titles: enhancedSummary.titles,
                    contentType: enhancedSummary.contentType,
                    aiEngine: enhancedSummary.aiEngine,
                    aiModel: enhancedSummary.aiModel,
                    originalLength: enhancedSummary.originalLength,
                    processingTime: enhancedSummary.processingTime
                )
                    
                    if summaryId != nil {
                        print("✅ Summary created with ID: \(summaryId?.uuidString ?? "nil")")
                        await MainActor.run {
                            isGeneratingSummary = false
                            generatingSummaryRecordingId = nil
                            loadRecordings()
                        }
                    } else {
                        throw NSError(domain: "SummaryGeneration", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create summary entry"])
                    }
                } else {
                    print("❌ No transcript found for recording: \(recording.recordingName ?? "Unknown")")
                    
                    // Create a job for tracking even when there's no transcript
                    let selectedEngine = UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? "On-Device AI"
                    let recordingURL = URL(string: recording.recordingURL ?? "") ?? URL(fileURLWithPath: "")
                    let recordingName = recording.recordingName ?? "Unknown Recording"
                    
                    job = ProcessingJob(
                        type: .summarization(engine: selectedEngine),
                        recordingURL: recordingURL,
                        recordingName: recordingName
                    )
                    
                    await MainActor.run {
                        errorMessage = "No transcript available for this recording"
                        errorRecoverySuggestion = ""
                        showErrorAlert = true
                        isGeneratingSummary = false
                        generatingSummaryRecordingId = nil
                    }
                }
            } catch {
                print("❌ Error generating summary: \(error)")
                print("🔍 Error details: \(error)")
                if let currentJob = job {
                    let failedJob = currentJob.withStatus(.failed(error.localizedDescription))
                    await BackgroundProcessingManager.shared.updateExternalJob(failedJob)
                }
                await MainActor.run {
                    if let summarizationError = error as? SummarizationError {
                        errorMessage = summarizationError.localizedDescription
                        errorRecoverySuggestion = summarizationError.recoverySuggestion ?? ""
                    } else {
                        errorMessage = "Failed to generate summary: \(error.localizedDescription)"
                        errorRecoverySuggestion = ""
                    }
                    showErrorAlert = true
                    isGeneratingSummary = false
                    generatingSummaryRecordingId = nil
                }
            }
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Search and Date Filtering

    private var filteredRecordings: [(recording: RecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)] {
        var result = recordings

        // Apply date filter if active
        if isDateFilterActive {
            let startOfDay = Calendar.current.startOfDay(for: dateFilterStart)
            let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: dateFilterEnd) ?? dateFilterEnd

            result = result.filter { recordingData in
                guard let date = recordingData.recording.recordingDate else { return false }
                return date >= startOfDay && date <= endOfDay
            }
        }

        // Apply search filter if not empty
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            let searchTerms = trimmedSearch.lowercased()
            result = result.filter { recordingData in
                matchesSearch(recordingData, searchTerms: searchTerms)
            }
        }

        return result
    }

    private func matchesSearch(_ recordingData: (recording: RecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?), searchTerms: String) -> Bool {
        // Check recording name
        if let name = recordingData.recording.recordingName?.lowercased(),
           name.contains(searchTerms) {
            return true
        }

        // Check summary content
        if let summary = recordingData.summary {
            // Check main summary text
            if summary.summary.lowercased().contains(searchTerms) {
                return true
            }

            // Check tasks
            if summary.tasks.contains(where: { $0.text.lowercased().contains(searchTerms) }) {
                return true
            }

            // Check reminders
            if summary.reminders.contains(where: { $0.text.lowercased().contains(searchTerms) }) {
                return true
            }

            // Check titles
            if summary.titles.contains(where: { $0.text.lowercased().contains(searchTerms) }) {
                return true
            }
        }

        return false
    }
    
    private func checkForFirstTimeiCloudPrompt() {
        // Check if this is a fresh install (first launch after installation)
        let isFreshInstall = !UserDefaults.standard.bool(forKey: "hasCompletedInitialLaunch")

        // Check for legacy iCloud settings and migrate them
        migrateLegacyiCloudSettings()

        Task {
            // Check if there are summaries in iCloud
            do {
                // Try the new method first, fallback to old method if needed
                var cloudSummaries: [EnhancedSummaryData] = []
                do {
                    cloudSummaries = try await iCloudManager.fetchAllSummariesUsingRecordOperation()
                } catch {
                    print("⚠️ Schema-safe fetch failed, trying standard fetch: \(error)")
                    cloudSummaries = try await iCloudManager.fetchAllSummariesFromCloud()
                }

                // Get local summary IDs from Core Data
                let localSummaries = appCoordinator.coreDataManager.getAllSummaries()
                let localSummaryIds = Set(localSummaries.compactMap { $0.id })

                let cloudOnlySummaries = cloudSummaries.filter { !localSummaryIds.contains($0.id) }

                await MainActor.run {
                    if !cloudOnlySummaries.isEmpty {
                        // We found cloud summaries that aren't local
                        if !hasSeeniCloudPrompt {
                            // User hasn't seen the regular prompt, show it
                            showingFirstTimeiCloudPrompt = true
                        } else if !iCloudManager.isEnabled && isFreshInstall {
                            // iCloud sync is disabled and this is a fresh install - prompt to enable it
                            showingiCloudDataFoundPrompt = true
                        }
                    }

                    // Mark that we've completed the initial launch check
                    UserDefaults.standard.set(true, forKey: "hasCompletedInitialLaunch")
                }
            } catch {
                // If we can't check iCloud (offline, no access, etc.), don't show prompt
                print("ℹ️ Could not check iCloud for summaries: \(error)")
                // Still mark initial launch as completed
                UserDefaults.standard.set(true, forKey: "hasCompletedInitialLaunch")
            }
        }
    }

    private func migrateLegacyiCloudSettings() {
        // Check if the legacy iCloud setting exists and current setting doesn't
        let legacyEnabled = UserDefaults.standard.bool(forKey: "iCloudSyncEnabled")
        let currentEnabled = UserDefaults.standard.bool(forKey: "unifiedICloudSyncEnabled")

        if legacyEnabled && !currentEnabled {
            print("🔄 Migrating legacy iCloud sync setting from 'iCloudSyncEnabled' to 'unifiedICloudSyncEnabled'")
            UserDefaults.standard.set(true, forKey: "unifiedICloudSyncEnabled")

            // Also enable the current iCloud manager if it wasn't enabled
            if !iCloudManager.isEnabled {
                Task {
                    await MainActor.run {
                        iCloudManager.isEnabled = true
                    }
                }
            }
        }
    }
    
    private func syncAllSummaries() async {
        do {
            try await iCloudManager.syncAllSummaries()
        } catch {
            print("❌ Sync error: \(error)")
            await MainActor.run {
                errorMessage = "iCloud sync failed: \(error.localizedDescription)"
                errorRecoverySuggestion = ""
                showErrorAlert = true
            }
        }
    }

} // End of SummariesView struct

// MARK: - Preview

#Preview {
    SummariesView()
        .environmentObject(AppDataCoordinator())
        .environmentObject(AudioRecorderViewModel())
}
