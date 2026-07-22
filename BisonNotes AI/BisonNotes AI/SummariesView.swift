import SwiftUI
import AVFoundation
import Speech
import CoreLocation
import NaturalLanguage

private struct SummaryWithDate {
    let recording: RecordingEntry
    let transcript: TranscriptData?
    let summary: EnhancedSummaryData?
    let date: Date
}

struct SummariesView: View {
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @EnvironmentObject var appCoordinator: AppDataCoordinator
    @Environment(\.isEmbeddedInSplitView) private var isEmbeddedInSplitView
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @StateObject private var enhancedTranscriptionManager = EnhancedTranscriptionManager()
    @StateObject private var enhancedFileManager = EnhancedFileManager.shared
    @ObservedObject private var iCloudManager = iCloudStorageManager.shared
    @ObservedObject private var processingManager = BackgroundProcessingManager.shared
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
    @State private var expandedSummaryDateSections: Set<DateSection> = [.today]
    @State private var isSummaryCandidatesExpanded = false
    @State private var isSummaryArchiveExpanded = false

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
                        .accessibilityLabel("Filter Summaries")
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
                    let selectedEngine = TranscriptionEngine(rawValue: UserDefaults.standard.string(forKey: "selectedTranscriptionEngine") ?? TranscriptionEngine.fluidAudio.rawValue) ?? .fluidAudio
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
                .onReceive(NotificationCenter.default.publisher(for: PlatformLifecycle.willEnterForegroundNotification)) { _ in
                    // Refresh when app comes to foreground
                    loadRecordings()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("iCloudReconcileCompleted"))) { _ in
                    loadRecordings()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SummaryDeleted"))) { _ in
                    // Refresh when a summary is deleted
                    AppLog.shared.summarization("Received summary deletion notification, refreshing...", level: .debug)
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
        .onChange(of: processingManager.activeJobs.map { "\($0.id)-\($0.status.displayName)" }) { _, _ in
            // Check if our summary job completed, failed, or was cancelled
            if isGeneratingSummary {
                let hasPendingSummaryJob = processingManager.activeJobs.contains { job in
                    if case .summarization = job.type {
                        return job.status == .queued || job.status == .processing
                    }
                    return false
                }
                if !hasPendingSummaryJob {
                    isGeneratingSummary = false
                    generatingSummaryRecordingId = nil
                    loadRecordings()
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
                        AppLog.shared.summarization("Downloaded \(count) summaries from iCloud")
                        loadRecordings() // Refresh the view
                    } catch {
                        AppLog.shared.summarization("Failed to download summaries: \(error)", level: .error)
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
                        AppLog.shared.summarization("Downloaded \(count) summaries from iCloud")
                        loadRecordings() // Refresh the view
                    } catch {
                        AppLog.shared.summarization("Failed to download summaries: \(error)", level: .error)
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
                .nativeMacModalSizing(width: 520, height: 440)
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
        .background(Color(.secondarySystemGroupedBackground))
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            Text("No Summaries Yet")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Record some audio and generate summaries to see them here.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - No Results View

    private var noResultsView: some View {
        VStack(spacing: 16) {
            Image(systemName: isDateFilterActive ? "calendar.badge.exclamationmark" : "magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

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
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
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
        #if targetEnvironment(macCatalyst)
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { showDateFilter = false }
                Spacer()
                Text("Filter by Date").font(.headline)
                Spacer()
                Button("Apply") {
                    isDateFilterActive = true
                    showDateFilter = false
                    refreshTrigger.toggle()
                }
                .fontWeight(.semibold)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
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
                            HStack { Spacer(); Text("Clear Filter"); Spacer() }
                        }
                    }
                }
            }
        }
        #else
        NavigationStack {
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
        #endif
    }

    // MARK: - Recordings List View

    private func recordingsListView(_ filtered: [(recording: RecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)]) -> some View {
        #if os(macOS) || targetEnvironment(macCatalyst)
        // A NavigationLink to a List with interactive section headers can wedge the
        // responder chain on both Mac implementations. Keep the complete archive inline.
        return summariesSectionedScroll(filtered)
        #else
        // iOS / iPadOS: preview cards with "More" navigation to the full list page.
        let recentRecordings = Array(filtered.prefix(3))

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                summarySectionHeader(
                    title: "Summaries",
                    count: filtered.count
                )

                ForEach(recentRecordings, id: \.recording.objectID) { recordingData in
                    recordingRowView(recordingData)
                }

                if filtered.count > recentRecordings.count {
                    NavigationLink {
                        summariesFullListView
                    } label: {
                        moreRowView(remainingCount: filtered.count - recentRecordings.count)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 96)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable {
            loadRecordings()
        }
        .id("list-\(isDateFilterActive)-\(dateFilterStart)-\(dateFilterEnd)-\(searchText)")
        .accessibilityIdentifier(BisonNotesAccessibilityID.summaryList)
        #endif
    }

    /// Full date-sectioned scroll used by both Mac implementations.
    private func summariesSectionedScroll(_ filtered: [(recording: RecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)]) -> some View {
        let availableSummaries = filtered
            .filter { $0.summary != nil }
            .sorted { ($0.recording.recordingDate ?? .distantPast) > ($1.recording.recordingDate ?? .distantPast) }
        let recentSummaries = Array(availableSummaries.prefix(3))
        let archivedSummaries = Array(availableSummaries.dropFirst(recentSummaries.count))
        let summaryCandidates = filtered.filter { $0.summary == nil && $0.transcript != nil }

        let recordingsWithDates: [SummaryWithDate] = archivedSummaries.compactMap { item in
            guard let date = item.recording.recordingDate else { return nil }
            return SummaryWithDate(
                recording: item.recording,
                transcript: item.transcript,
                summary: item.summary,
                date: date
            )
        }

        // Group by date section
        let sectioned = DateSectionHelper.groupBySection(recordingsWithDates, dateKeyPath: \.date)

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if !recentSummaries.isEmpty {
                    summarySectionHeader(title: "Recent Summaries", count: availableSummaries.count)

                    ForEach(recentSummaries, id: \.recording.objectID) { item in
                        recordingRowView(item)
                    }
                }

                if !archivedSummaries.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSummaryArchiveExpanded.toggle()
                        }
                    } label: {
                        inlineArchiveRow(
                            title: isSummaryArchiveExpanded ? "Hide older summaries" : "Browse older summaries",
                            count: archivedSummaries.count,
                            isExpanded: isSummaryArchiveExpanded
                        )
                    }
                    .buttonStyle(.plain)

                    if isSummaryArchiveExpanded {
                        summaryArchiveSections(sectioned, candidates: [])
                    }
                }

                summaryCandidatesSection(summaryCandidates)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 96)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable {
            loadRecordings()
        }
        .id("list-\(isDateFilterActive)-\(dateFilterStart)-\(dateFilterEnd)-\(searchText)")
        .accessibilityIdentifier(BisonNotesAccessibilityID.summaryList)
    }

    @ViewBuilder
    private func summaryArchiveSections(
        _ sectioned: [(section: DateSection, items: [SummaryWithDate])],
        candidates: [(recording: RecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)]
    ) -> some View {
        ForEach(sectioned, id: \.section) { sectionData in
            CollapsibleDateSectionHeader(
                title: sectionData.section.title,
                count: sectionData.items.count,
                isExpanded: isSummaryDateSectionExpanded(sectionData.section),
                isAlwaysExpanded: false,
                onToggle: { toggleSummaryDateSection(sectionData.section) }
            )

            if isSummaryDateSectionExpanded(sectionData.section) {
                ForEach(sectionData.items, id: \.recording.objectID) { item in
                    recordingRowView(
                        (recording: item.recording, transcript: item.transcript, summary: item.summary)
                    )
                }
            }
        }

        summaryCandidatesSection(candidates)
    }

    @ViewBuilder
    private func summaryCandidatesSection(
        _ candidates: [(recording: RecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)]
    ) -> some View {
        if !candidates.isEmpty {
            CollapsibleDateSectionHeader(
                title: "Ready to Summarize",
                count: candidates.count,
                isExpanded: isSummaryCandidatesExpanded,
                isAlwaysExpanded: false,
                onToggle: { isSummaryCandidatesExpanded.toggle() }
            )

            if isSummaryCandidatesExpanded {
                ForEach(candidates, id: \.recording.objectID) { item in
                    recordingRowView(item)
                }
            }
        }
    }

    private func inlineArchiveRow(title: String, count: Int, isExpanded: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "archivebox")
                .font(.title3)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text("\(count) older \(count == 1 ? "summary" : "summaries")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(isExpanded ? "Collapses the summary archive." : "Expands the summary archive inline.")
    }

    /// Full list page reached via the "More" row (matches TranscriptViews' full list pages).
    /// Respects the same date/search filters as the main page.
    private var summariesFullListView: some View {
        let availableSummaries = filteredRecordings.filter { $0.summary != nil }
        let summaryCandidates = filteredRecordings.filter { $0.summary == nil && $0.transcript != nil }

        let recordingsWithDates: [SummaryWithDate] = availableSummaries.compactMap { item in
            guard let date = item.recording.recordingDate else { return nil }
            return SummaryWithDate(
                recording: item.recording,
                transcript: item.transcript,
                summary: item.summary,
                date: date
            )
        }

        let sectioned = DateSectionHelper.groupBySection(recordingsWithDates, dateKeyPath: \.date)

        return VStack(spacing: 0) {
            if isDateFilterActive {
                activeDateFilterBanner
            }

            List {
                ForEach(sectioned, id: \.section) { sectionData in
                    Section(
                        header: CollapsibleDateSectionHeader(
                            title: sectionData.section.title,
                            count: sectionData.items.count,
                            isExpanded: isSummaryDateSectionExpanded(sectionData.section),
                            isAlwaysExpanded: false,
                            onToggle: { toggleSummaryDateSection(sectionData.section) }
                        )
                    ) {
                        if isSummaryDateSectionExpanded(sectionData.section) {
                            ForEach(sectionData.items, id: \.recording.objectID) { itemWithDate in
                                recordingRowView((recording: itemWithDate.recording, transcript: itemWithDate.transcript, summary: itemWithDate.summary))
                                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                            }
                        }
                    }
                }

                if !summaryCandidates.isEmpty {
                    Section(
                        header: CollapsibleDateSectionHeader(
                            title: "Ready to Summarize",
                            count: summaryCandidates.count,
                            isExpanded: isSummaryCandidatesExpanded,
                            isAlwaysExpanded: false,
                            onToggle: { isSummaryCandidatesExpanded.toggle() }
                        )
                    ) {
                        if isSummaryCandidatesExpanded {
                            ForEach(summaryCandidates, id: \.recording.objectID) { item in
                                recordingRowView(item)
                                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Summaries")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showDateFilter = true }) {
                    Image(systemName: isDateFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Filter Summaries")
            }
        }
    }

    private func moreRowView(remainingCount: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundColor(.accentColor)
            Text("Show \(remainingCount) more")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .accessibilityCard(
            label: "Show \(remainingCount) more summaries",
            hint: "Opens the full summary list."
        )
    }

    // MARK: - Recording Row View

    private func recordingRowView(_ recordingData: (recording: RecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)) -> some View {
        let recording = recordingData.recording
        let summary = recordingData.summary

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: summary == nil ? "doc.text.magnifyingglass" : "doc.text.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(summary == nil ? .accentColor : .blue)
                    .frame(width: 38, height: 38)
                    .background((summary == nil ? Color.accentColor : Color.blue).opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 6) {
                    Text(recording.recordingName ?? "Unknown Recording")
                        .font(.headline)
                        .foregroundColor(.primary)

                    Text(UserPreferences.shared.formatMediumDateTime(recording.recordingDate ?? Date()))
                        .font(.caption)
                        .foregroundColor(.primary)
                }

                Spacer()

                statusIndicator(for: recording)
            }

            if let summary {
                VStack(alignment: .leading, spacing: 8) {
                    Text(summaryPreviewText(summary.summary))
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .lineLimit(3)

                    HStack(spacing: 8) {
                        summaryMetric("Tasks", count: summary.tasks.count, tint: .green)
                        summaryMetric("Reminders", count: summary.reminders.count, tint: .orange)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            summaryActionView(recording: recording, summary: summary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            BisonNotesAccessibilityID.summaryRowPrefix
                + (recording.id?.uuidString ?? recording.objectID.uriRepresentation().absoluteString)
        )
        .accessibilityLabel(
            AccessibilitySupport.summaryRowLabel(name: recording.recordingName ?? "Unknown Recording")
        )
        .accessibilityValue(
            AccessibilitySupport.summaryRowValue(
                date: UserPreferences.shared.formatMediumDateTime(recording.recordingDate ?? Date()),
                taskCount: summary?.tasks.count ?? 0,
                reminderCount: summary?.reminders.count ?? 0,
                hasSummary: summary != nil
            )
        )

    }

    /// Compact plain-text preview of a markdown summary: header lines are
    /// dropped entirely (they're section labels, not content), remaining
    /// markdown syntax is stripped, and whitespace is collapsed.
    private func summaryPreviewText(_ markdown: String) -> String {
        // A preview only renders a few lines. Bound the work so expanding an old
        // month never runs markdown cleanup over dozens of complete summaries.
        let previewSource = String(markdown.prefix(2_000))
        let withoutHeaderLines = previewSource
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: " ")

        return withoutHeaderLines
            .strippingMarkdown()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Status Indicator

    private func statusIndicator(for recording: RecordingEntry) -> some View {
        HStack(spacing: 5) {
            Image(systemName: (recording.transcript != nil) ? "checkmark.circle.fill" : "circle")
                .foregroundColor((recording.transcript != nil) ? .green : .gray)
                .font(.caption)

            Image(systemName: (recording.summary != nil) ? "doc.text.fill" : "doc.text.magnifyingglass")
                .foregroundColor((recording.summary != nil) ? .blue : .gray)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(Capsule())
        .accessibilityLabel("Transcript and summary status")
        .accessibilityValue(
            [
                recording.transcript != nil ? "Transcript available" : "No transcript",
                recording.summary != nil ? "Summary available" : "No summary"
            ].joined(separator: ", ")
        )
    }

    @ViewBuilder
    private func summaryActionView(recording: RecordingEntry, summary: EnhancedSummaryData?) -> some View {
        if summary != nil {
            Button(action: {
                #if os(macOS)
                if let recordingID = recording.id {
                    openWindow(id: NativeWindowID.summary, value: recordingID)
                }
                #else
                selectedRecording = recording
                showSummary = true
                #endif
            }) {
                Label("View Summary", systemImage: "doc.text.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Color.blue.opacity(0.14))
                    .foregroundColor(.primary)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View Summary for \(recording.recordingName ?? "Unknown Recording")")
        } else if recording.summaryStatus == ProcessingStatus.processing.rawValue || (isGeneratingSummary && generatingSummaryRecordingId == recording.id) {
            HStack(spacing: 7) {
                ProgressView()
                    .scaleEffect(0.75)
                    .tint(.orange)
                Text("Generating...")
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Color.orange.opacity(0.14))
            .foregroundColor(.orange)
            .clipShape(Capsule())
            .accessibilityLabel("Generating Summary for \(recording.recordingName ?? "Unknown Recording")")
            .accessibilityValue("In progress")
        } else {
            Button(action: {
                guard !isGeneratingSummary else { return }
                AppLog.shared.summarization("Generate Summary button pressed", level: .debug)
                generateSummary(for: recording)
            }) {
                Label("Generate Summary", systemImage: "doc.text.magnifyingglass")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background((isGeneratingSummary ? Color.gray : Color.accentColor).opacity(0.14))
                    .foregroundColor(isGeneratingSummary ? .gray : .accentColor)
                    .clipShape(Capsule())
            }
            .disabled(isGeneratingSummary)
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel("Generate Summary for \(recording.recordingName ?? "Unknown Recording")")
            .accessibilityValue(isGeneratingSummary ? "In progress" : "Ready")
        }
    }

    private func summarySectionHeader(title: String, count: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.caption.weight(.semibold))
                .foregroundColor(.accentColor)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(title)
                .font(.headline)

            Spacer()

            Text("\(count)")
                .font(.caption.weight(.semibold))
                .foregroundColor(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(Capsule())
        }
    }

    private func isSummaryDateSectionExpanded(_ section: DateSection) -> Bool {
        expandedSummaryDateSections.contains(section)
    }

    private func toggleSummaryDateSection(_ section: DateSection) {
        if expandedSummaryDateSections.contains(section) {
            expandedSummaryDateSections.remove(section)
        } else {
            expandedSummaryDateSections.insert(section)
        }
    }

    private func summaryMetric(_ label: String, count: Int, tint: Color) -> some View {
        Text("\(count) \(label)")
            .font(.caption2.weight(.semibold))
            .foregroundColor(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
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
                    AppLog.shared.summarization("Repaired \(repairedCount) orphaned summaries")
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
        AppLog.shared.summarization("generateSummary called", level: .debug)

        isGeneratingSummary = true
        generatingSummaryRecordingId = recording.id

        let selectedEngine = UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? AIEngineType.mlxSwift.rawValue
        let selectedModel = UserDefaults.standard.string(forKey: "SelectedAIModel")
        let recordingURL: URL
        if let absoluteURL = appCoordinator.getAbsoluteURL(for: recording) {
            recordingURL = absoluteURL
        } else {
            recordingURL = URL(fileURLWithPath: recording.recordingURL ?? "")
        }
        let recordingName = recording.recordingName ?? "Unknown Recording"

        AppLog.shared.summarization("Queueing summary job via BackgroundProcessingManager...", level: .debug)

        Task {
            do {
                try await BackgroundProcessingManager.shared.startSummarizationJob(
                    recordingURL: recordingURL,
                    recordingName: recordingName,
                    engine: selectedEngine,
                    modelName: selectedModel
                )
                AppLog.shared.summarization("Summary job queued successfully")
            } catch {
                AppLog.shared.summarization("Failed to queue summary job: \(error)", level: .error)
                await MainActor.run {
                    if let summarizationError = error as? SummarizationError {
                        errorMessage = summarizationError.localizedDescription
                        errorRecoverySuggestion = summarizationError.recoverySuggestion ?? ""
                    } else {
                        errorMessage = "Failed to start summary: \(error.localizedDescription)"
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
                    AppLog.shared.summarization("Schema-safe fetch failed, trying standard fetch: \(error)", level: .error)
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
                AppLog.shared.summarization("Could not check iCloud for summaries: \(error)", level: .debug)
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
            AppLog.shared.summarization("Migrating legacy iCloud sync setting to unifiedICloudSyncEnabled")
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
            AppLog.shared.summarization("Sync error: \(error)", level: .error)
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
