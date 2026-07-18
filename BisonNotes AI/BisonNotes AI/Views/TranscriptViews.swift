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

private enum TranscriptListSource {
    case audio
    case imported
}

private struct TranscriptWithDate {
    let recording: RecordingEntry
    let transcript: TranscriptData?
    let date: Date
    let source: TranscriptListSource
}

struct TranscriptsView: View {
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @EnvironmentObject var appCoordinator: AppDataCoordinator
    @StateObject private var enhancedTranscriptionManager = EnhancedTranscriptionManager()
    @ObservedObject private var backgroundProcessingManager = BackgroundProcessingManager.shared
    @State private var recordings: [(recording: RecordingEntry, transcript: TranscriptData?)] = []
    @State private var importedTranscripts: [(recording: RecordingEntry, transcript: TranscriptData?)] = []
    @State private var selectedRecording: RecordingEntry?
    @State private var showingAudioCleanupPrompt = false
    @State private var recordingPendingTranscription: RecordingEntry?
    @State private var selectedLocationData: LocationData?
    @State private var locationAddresses: [URL: String] = [:]
    @State private var showingTranscriptionCompletionAlert = false
    @State private var completedTranscriptionText = ""
    @State private var isCheckingForCompletions = false
    @State private var refreshTrigger = false
    @State private var refreshTimer: Timer?
    @State private var isShowingAlert = false
    @State private var searchText = ""
    @State private var showDateFilter = false
    @State private var dateFilterStart: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var dateFilterEnd: Date = Date()
    @State private var isDateFilterActive = false
    @State private var expandedTranscriptDateSections: Set<DateSection> = [.today]
    /// Shared service that owns the serial audio-cleanup queue and transcription start.
    @ObservedObject private var transcriptionStarter = TranscriptionStarter.shared
    /// Recordings whose summary generation we kicked off and are still awaiting completion.
    @State private var generatingSummaryRecordingIds: Set<UUID> = []

    var body: some View {
        AdaptiveNavigationWrapper {
            mainContentView
        }
        .sheet(item: $selectedRecording) { recording in
            if let recordingId = recording.id,
               let transcript = appCoordinator.getTranscriptData(for: recordingId) {
                EditableTranscriptView(recording: recording, transcript: transcript, transcriptManager: TranscriptManager.shared)
                    .environmentObject(appCoordinator)
                    .environmentObject(recorderVM)
            } else {
                TranscriptDetailView(recording: recording, transcriptText: "")
                    .environmentObject(appCoordinator)
                    .environmentObject(recorderVM)
            }
        }
        .sheet(item: $selectedLocationData) { locationData in
            LocationDetailView(locationData: locationData)
        }
        .confirmationDialog(
            "Clean Audio Before Transcribing?",
            isPresented: $showingAudioCleanupPrompt,
            titleVisibility: .visible
        ) {
            Button("Clean & Transcribe") {
                if let recording = recordingPendingTranscription {
                    recordingPendingTranscription = nil
                    transcriptionStarter.startTranscription(for: recording, cleanFirst: true, appCoordinator: appCoordinator)
                }
            }
            Button("Transcribe As-Is") {
                if let recording = recordingPendingTranscription {
                    recordingPendingTranscription = nil
                    transcriptionStarter.startTranscription(for: recording, cleanFirst: false, appCoordinator: appCoordinator)
                }
            }
            Button("Cancel", role: .cancel) {
                recordingPendingTranscription = nil
            }
        } message: {
            Text("Cleaning reduces static and normalizes volume, which can improve transcription accuracy. The original audio file is not changed.")
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
    }

    private var mainContentView: some View {
        let filtered = filteredRecordings
        let filteredImported = filteredImportedTranscripts
        return VStack {
            if recordings.isEmpty && importedTranscripts.isEmpty {
                emptyStateView
            } else if filtered.isEmpty && filteredImported.isEmpty {
                noResultsView
            } else {
                VStack(spacing: 0) {
                    if isDateFilterActive {
                        activeDateFilterBanner
                    }
                    transcriptsListView(filtered, filteredImported)
                }
            }
        }
        .navigationTitle("Transcripts")
        .searchable(text: $searchText, prompt: "Search transcripts...")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showDateFilter = true }) {
                    Image(systemName: isDateFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Filter Transcripts")
            }
        }
        .sheet(isPresented: $showDateFilter) {
            dateFilterSheet
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
            AppLog.shared.transcription("Received recording renamed notification, refreshing list", level: .debug)
            loadRecordings()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("iCloudReconcileCompleted"))) { _ in
            loadRecordings()
            refreshTrigger.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TranscriptionCompleted"))) { _ in
            // Refresh recordings list when transcription completes
            AppLog.shared.transcription("Received transcription completed notification, refreshing list", level: .debug)
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
                .foregroundColor(.accentColor)

            Text("No Recordings Found")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.primary)

            Text("Record some audio first to generate transcripts")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

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
            return "No transcripts match \"\(searchText)\" in the selected date range."
        } else if hasSearch {
            return "No transcripts match \"\(searchText)\"."
        } else if isDateFilterActive {
            return "No transcripts found between \(dateFilterStart.formatted(date: .abbreviated, time: .omitted)) and \(dateFilterEnd.formatted(date: .abbreviated, time: .omitted))."
        } else {
            return "No transcripts found."
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

    private var dateFilterSheet: some View {
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
    }

    private func transcriptsListView(_ filtered: [(recording: RecordingEntry, transcript: TranscriptData?)], _ filteredImported: [(recording: RecordingEntry, transcript: TranscriptData?)]) -> some View {
        #if targetEnvironment(macCatalyst)
        // On Mac Catalyst, the preview-+-NavigationLink-to-More pattern wedges the responder chain
        // (destination renders but becomes unresponsive). Render everything inline instead.
        let sectioned = DateSectionHelper.groupBySection(
            transcriptItemsWithDates(filtered, source: .audio) + transcriptItemsWithDates(filteredImported, source: .imported),
            dateKeyPath: \.date
        )

        return List {
            ForEach(sectioned, id: \.section) { sectionData in
                Section(
                    header: CollapsibleDateSectionHeader(
                        title: sectionData.section.title,
                        count: sectionData.items.count,
                        isExpanded: isTranscriptDateSectionExpanded(sectionData.section),
                        isAlwaysExpanded: false,
                        onToggle: { toggleTranscriptDateSection(sectionData.section) }
                    )
                ) {
                    if isTranscriptDateSectionExpanded(sectionData.section) {
                        transcriptDateSectionRows(sectionData.items)
                    }
                }
            }
        }
        .id("list-\(isDateFilterActive)-\(dateFilterStart)-\(dateFilterEnd)-\(searchText)")
        .accessibilityIdentifier(BisonNotesAccessibilityID.transcriptList)
        #else
        // iOS / iPadOS: preview cards with "More" navigation to the full list page.
        let recentRecordings = Array(filtered.prefix(3))
        let recentImportedTranscripts = Array(filteredImported.prefix(3))

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if !filtered.isEmpty {
                    transcriptSectionHeader(
                        title: "Audio Transcripts",
                        count: filtered.count,
                        systemImage: "waveform"
                    )

                    ForEach(recentRecordings, id: \.recording.id) { recordingData in
                        recordingRowView(recordingData)
                    }

                    if filtered.count > recentRecordings.count {
                        NavigationLink {
                            audioRecordingsFullListView
                        } label: {
                            moreRowView(remainingCount: filtered.count - recentRecordings.count)
                        }
                    }
                }

                if !filteredImported.isEmpty {
                    transcriptSectionHeader(
                        title: "Imported Transcripts",
                        count: filteredImported.count,
                        systemImage: "doc.text.fill"
                    )

                    ForEach(recentImportedTranscripts, id: \.recording.id) { recordingData in
                        importedTranscriptRowView(recordingData) {
                            deleteImportedTranscript(recordingData)
                            loadRecordings()
                        }
                    }

                    if filteredImported.count > recentImportedTranscripts.count {
                        NavigationLink {
                            importedTranscriptsFullListView
                        } label: {
                            moreRowView(remainingCount: filteredImported.count - recentImportedTranscripts.count)
                        }
                    }
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
        .accessibilityIdentifier(BisonNotesAccessibilityID.transcriptList)
        #endif
    }

    private var audioRecordingsFullListView: some View {
        struct RecordingWithDate {
            let recording: RecordingEntry
            let transcript: TranscriptData?
            let date: Date
        }

        // Respect the same date/search filters as the main page
        let recordingsWithDates: [RecordingWithDate] = filteredRecordings.compactMap { item in
            guard let date = item.recording.recordingDate else { return nil }
            return RecordingWithDate(recording: item.recording, transcript: item.transcript, date: date)
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
                            isExpanded: isTranscriptDateSectionExpanded(sectionData.section),
                            isAlwaysExpanded: false,
                            onToggle: { toggleTranscriptDateSection(sectionData.section) }
                        )
                    ) {
                        if isTranscriptDateSectionExpanded(sectionData.section) {
                            ForEach(sectionData.items, id: \.recording.id) { itemWithDate in
                                recordingRowView((recording: itemWithDate.recording, transcript: itemWithDate.transcript))
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
        .navigationTitle("Audio Transcripts")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showDateFilter = true }) {
                    Image(systemName: isDateFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Filter Audio Transcripts")
            }
        }
    }

    private var importedTranscriptsFullListView: some View {
        struct ImportedWithDate {
            let recording: RecordingEntry
            let transcript: TranscriptData?
            let date: Date
        }

        // Respect the same date/search filters as the main page
        let importedWithDates: [ImportedWithDate] = filteredImportedTranscripts.compactMap { item in
            guard let date = item.recording.recordingDate else { return nil }
            return ImportedWithDate(recording: item.recording, transcript: item.transcript, date: date)
        }

        let sectioned = DateSectionHelper.groupBySection(importedWithDates, dateKeyPath: \.date)

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
                            isExpanded: isTranscriptDateSectionExpanded(sectionData.section),
                            isAlwaysExpanded: false,
                            onToggle: { toggleTranscriptDateSection(sectionData.section) }
                        )
                    ) {
                        if isTranscriptDateSectionExpanded(sectionData.section) {
                            ForEach(sectionData.items, id: \.recording.id) { itemWithDate in
                                importedTranscriptRowView((recording: itemWithDate.recording, transcript: itemWithDate.transcript))
                                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                            }
                            .onDelete { indexSet in
                                let itemsToDelete = indexSet.map { sectionData.items[$0] }
                                for item in itemsToDelete {
                                    deleteImportedTranscript((recording: item.recording, transcript: item.transcript))
                                }
                                loadRecordings()
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Imported Transcripts")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showDateFilter = true }) {
                    Image(systemName: isDateFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Filter Imported Transcripts")
            }
        }
    }

    private func transcriptItemsWithDates(
        _ items: [(recording: RecordingEntry, transcript: TranscriptData?)],
        source: TranscriptListSource
    ) -> [TranscriptWithDate] {
        items.compactMap { item in
            guard let date = item.recording.recordingDate else { return nil }
            return TranscriptWithDate(
                recording: item.recording,
                transcript: item.transcript,
                date: date,
                source: source
            )
        }
    }

    @ViewBuilder
    private func transcriptDateSectionRows(_ items: [TranscriptWithDate]) -> some View {
        let audioItems = items.filter { $0.source == .audio }
        let importedItems = items.filter { $0.source == .imported }
        let showSourceLabels = !audioItems.isEmpty && !importedItems.isEmpty

        if !audioItems.isEmpty {
            if showSourceLabels {
                transcriptSourceLabel("Audio Transcripts", count: audioItems.count, systemImage: "waveform")
            }

            ForEach(audioItems, id: \.recording.objectID) { item in
                recordingRowView((recording: item.recording, transcript: item.transcript))
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }

        if !importedItems.isEmpty {
            if showSourceLabels {
                transcriptSourceLabel("Imported Transcripts", count: importedItems.count, systemImage: "doc.text.fill")
            }

            ForEach(importedItems, id: \.recording.objectID) { item in
                importedTranscriptRowView((recording: item.recording, transcript: item.transcript))
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .onDelete { indexSet in
                let itemsToDelete = indexSet.map { importedItems[$0] }
                for item in itemsToDelete {
                    deleteImportedTranscript((recording: item.recording, transcript: item.transcript))
                }
                loadRecordings()
            }
        }
    }

    private func transcriptSourceLabel(_ title: String, count: Int, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
            Text(title)
            Text("\(count)")
                .foregroundColor(.primary)
        }
        .font(.caption.weight(.semibold))
        .foregroundColor(.primary)
        .textCase(.uppercase)
        .padding(.top, 4)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func isTranscriptDateSectionExpanded(_ section: DateSection) -> Bool {
        expandedTranscriptDateSections.contains(section)
    }

    private func toggleTranscriptDateSection(_ section: DateSection) {
        if expandedTranscriptDateSections.contains(section) {
            expandedTranscriptDateSections.remove(section)
        } else {
            expandedTranscriptDateSections.insert(section)
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
            label: "Show \(remainingCount) more transcripts",
            hint: "Opens the full transcript list."
        )
    }

    private func recordingRowView(_ recordingData: (recording: RecordingEntry, transcript: TranscriptData?)) -> some View {
        let recordingId = recordingData.recording.id?.uuidString
            ?? recordingData.recording.objectID.uriRepresentation().absoluteString

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                recordingInfoView(recordingData)
                Spacer()
                transcriptStatusIcon(hasTranscript: recordingData.transcript != nil)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    transcriptButtonView(recordingData)
                    summaryButtonView(recordingData)
                }

                VStack(alignment: .leading, spacing: 8) {
                    transcriptButtonView(recordingData)
                    summaryButtonView(recordingData)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .accessibilityIdentifier(BisonNotesAccessibilityID.transcriptRowPrefix + recordingId)
    }

    private func importedTranscriptRowView(
        _ recordingData: (recording: RecordingEntry, transcript: TranscriptData?),
        onDelete: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: {
                selectedRecording = recordingData.recording
            }) {
                importedTranscriptRowContent(recordingData, showsChevron: onDelete == nil)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityCard(
                label: AccessibilitySupport.transcriptRowLabel(
                    name: recordingData.recording.recordingName ?? "Untitled Import",
                    source: "Imported"
                ),
                value: AccessibilitySupport.transcriptRowValue(
                    date: UserPreferences.shared.formatMediumDateTime(recordingData.recording.recordingDate ?? Date()),
                    wordCount: recordingData.transcript.map { transcriptWordCount($0) },
                    hasSummary: recordingData.recording.summary != nil
                        || recordingData.recording.summaryId != nil
                        || recordingData.recording.summaryStatus == ProcessingStatus.completed.rawValue
                ),
                hint: "Opens this imported transcript."
            )

            if let onDelete {
                Divider()
                    .frame(height: 44)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.headline)
                        .foregroundColor(.red)
                        .frame(width: 44, height: 44)
                        .background(Color.red.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "Delete imported transcript \(recordingData.recording.recordingName ?? "Untitled Import")"
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .accessibilityIdentifier(
            BisonNotesAccessibilityID.transcriptRowPrefix
                + (
                    recordingData.recording.id?.uuidString
                        ?? recordingData.recording.objectID.uriRepresentation().absoluteString
                )
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func importedTranscriptRowContent(
        _ recordingData: (recording: RecordingEntry, transcript: TranscriptData?),
        showsChevron: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.purple)
                .frame(width: 38, height: 38)
                .background(Color.purple.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 4) {
                Text(recordingData.recording.recordingName ?? "Untitled Import")
                    .font(.headline)
                    .foregroundColor(.primary)

                Text(UserPreferences.shared.formatMediumDateTime(recordingData.recording.recordingDate ?? Date()))
                    .font(.caption)
                    .foregroundColor(.primary)

                if let transcript = recordingData.transcript {
                    Text("\(transcript.segments.reduce(0) { $0 + $1.text.split(separator: " ").count }) words")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func recordingInfoView(_ recordingData: (recording: RecordingEntry, transcript: TranscriptData?)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                Text(recordingData.recording.recordingName ?? "Unknown Recording")
                    .font(.headline)
                    .foregroundColor(.primary)

                Text(UserPreferences.shared.formatMediumDateTime(recordingData.recording.recordingDate ?? Date()))
                    .font(.caption)
                    .foregroundColor(.primary)
            }
            .accessibilityCard(
                label: AccessibilitySupport.transcriptRowLabel(
                    name: recordingData.recording.recordingName ?? "Unknown Recording",
                    source: "Audio"
                ),
                value: AccessibilitySupport.transcriptRowValue(
                    date: UserPreferences.shared.formatMediumDateTime(
                        recordingData.recording.recordingDate ?? Date()
                    ),
                    wordCount: recordingData.transcript.map { transcriptWordCount($0) },
                    hasSummary: recordingData.recording.summary != nil
                        || recordingData.recording.summaryId != nil
                        || recordingData.recording.summaryStatus == ProcessingStatus.completed.rawValue
                )
            )

            // Cheap attribute reads only — getAbsoluteURL would probe FileManager (and possibly
            // save the Core Data context) per row, which stalled Mac Catalyst on long lists.
            if let locationData = appCoordinator.coreDataManager.getLocationData(for: recordingData.recording),
               let recordingURL = appCoordinator.getStoredURL(for: recordingData.recording) {
                locationButtonView(locationData, recordingURL: recordingURL)
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
        .accessibilityLabel("View recording location")
    }

    private func transcriptButtonView(_ recordingData: (recording: RecordingEntry, transcript: TranscriptData?)) -> some View {
        let hasTranscript = recordingData.transcript != nil
        let hasActiveJob = transcriptionStarter.hasActiveTranscriptionJob(for: recordingData.recording, appCoordinator: appCoordinator)
        let recordingId = recordingData.recording.id ?? UUID()
        let isCleaning = transcriptionStarter.isCleaning(recordingId)
        let isQueuedForCleanup = transcriptionStarter.isQueuedForCleanup(recordingId)
        let jobStatus = transcriptionStarter.activeTranscriptionJobStatus(for: recordingData.recording, appCoordinator: appCoordinator)
        let isProcessing = isCleaning || isQueuedForCleanup || hasActiveJob

        return Button(action: {
            if hasTranscript {
                // Show existing transcript for editing - always allowed
                selectedRecording = recordingData.recording
            } else {
                // Generate new transcript - only if this recording doesn't already have an active job
                if !isProcessing {
                    generateTranscript(for: recordingData.recording)
                }
            }
        }) {
            HStack(spacing: 7) {
                if isProcessing && !hasTranscript {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(.primary)
                    Text(processingButtonLabel(isCleaning: isCleaning, isQueuedForCleanup: isQueuedForCleanup, jobStatus: jobStatus))
                } else {
                    Image(systemName: hasTranscript ? "text.bubble.fill" : "text.bubble")
                    Text(hasTranscript ? "Edit Transcript" : "Generate Transcript")
                }
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background((hasTranscript ? Color.green : isProcessing ? Color.orange : Color.accentColor).opacity(0.14))
            .foregroundColor(.primary)
            .clipShape(Capsule())
        }
        .disabled(isProcessing && !hasTranscript)
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(
            hasTranscript
                ? "Edit Transcript for \(recordingData.recording.recordingName ?? "Unknown Recording")"
                : "Generate Transcript for \(recordingData.recording.recordingName ?? "Unknown Recording")"
        )
        .accessibilityValue(isProcessing && !hasTranscript ? "In progress" : "Ready")
        .id("\(recordingData.recording.id?.uuidString ?? "unknown")-\(hasTranscript)-\(hasActiveJob)-\(isCleaning)-\(isQueuedForCleanup)-\(refreshTrigger)")
    }

    /// Returns the appropriate label for the processing button based on current phase
    private func processingButtonLabel(isCleaning: Bool, isQueuedForCleanup: Bool, jobStatus: JobProcessingStatus?) -> String {
        if isCleaning {
            return "Cleaning Audio..."
        }
        if isQueuedForCleanup {
            return "Queued..."
        }
        switch jobStatus {
        case .queued:
            return "Queued..."
        case .processing:
            return "Transcribing..."
        default:
            return "Processing..."
        }
    }

    private func transcriptWordCount(_ transcript: TranscriptData) -> Int {
        transcript.segments.reduce(0) { partialResult, segment in
            partialResult + segment.text.split(whereSeparator: \.isWhitespace).count
        }
    }

    /// Second button in each row: visible only when a transcript exists and no summary does.
    /// Once a summary is created, the button disappears — the user regenerates from inside
    /// the existing summary detail view.
    @ViewBuilder
    private func summaryButtonView(_ recordingData: (recording: RecordingEntry, transcript: TranscriptData?)) -> some View {
        let recording = recordingData.recording
        let hasTranscript = recordingData.transcript != nil
        // Read the cheap status attribute rather than faulting recording.summary on every row.
        let status = recording.summaryStatus
        let hasSummary = status == ProcessingStatus.completed.rawValue

        if let recordingId = recording.id, hasTranscript, !hasSummary {
            let isGenerating = generatingSummaryRecordingIds.contains(recordingId)
                || status == ProcessingStatus.processing.rawValue

            Button(action: {
                if !isGenerating {
                    generateSummary(for: recording)
                }
            }) {
                HStack(spacing: 7) {
                    if isGenerating {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(.purple)
                        Text("Generating…")
                    } else {
                        Image(systemName: "doc.text.magnifyingglass")
                        Text("Generate Summary")
                    }
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background((isGenerating ? Color.orange : Color.purple).opacity(0.14))
                .foregroundColor(isGenerating ? .orange : .purple)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isGenerating)
            .accessibilityLabel("Generate Summary for \(recording.recordingName ?? "Unknown Recording")")
            .accessibilityValue(isGenerating ? "In progress" : "Ready")
        }
    }

    private func transcriptSectionHeader(title: String, count: Int, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
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

    private func transcriptStatusIcon(hasTranscript: Bool) -> some View {
        Image(systemName: hasTranscript ? "checkmark.circle.fill" : "clock")
            .font(.title3)
            .foregroundColor(hasTranscript ? .green : .secondary)
            .accessibilityLabel(hasTranscript ? "Transcript available" : "Transcript not generated")
    }

    private func generateSummary(for recording: RecordingEntry) {
        guard let recordingId = recording.id else { return }
        AppLog.shared.summarization("generateSummary called from TranscriptsView row", level: .debug)
        generatingSummaryRecordingIds.insert(recordingId)

        let selectedEngine = UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? AIEngineType.mlxSwift.rawValue
        let selectedModel = UserDefaults.standard.string(forKey: "SelectedAIModel")
        let recordingURL: URL
        if let absoluteURL = appCoordinator.getAbsoluteURL(for: recording) {
            recordingURL = absoluteURL
        } else {
            recordingURL = URL(fileURLWithPath: recording.recordingURL ?? "")
        }
        let recordingName = recording.recordingName ?? "Unknown Recording"

        Task {
            do {
                try await BackgroundProcessingManager.shared.startSummarizationJob(
                    recordingURL: recordingURL,
                    recordingName: recordingName,
                    engine: selectedEngine,
                    modelName: selectedModel
                )
                AppLog.shared.summarization("Summary job queued from TranscriptsView row")
            } catch {
                AppLog.shared.summarization("Failed to queue summary job from TranscriptsView row: \(error)", level: .error)
                await MainActor.run {
                    _ = generatingSummaryRecordingIds.remove(recordingId)
                }
            }
        }
    }

    // MARK: - Search and Date Filtering

    private var filteredRecordings: [(recording: RecordingEntry, transcript: TranscriptData?)] {
        applyFilters(to: recordings)
    }

    private var filteredImportedTranscripts: [(recording: RecordingEntry, transcript: TranscriptData?)] {
        applyFilters(to: importedTranscripts)
    }

    private func applyFilters(to items: [(recording: RecordingEntry, transcript: TranscriptData?)]) -> [(recording: RecordingEntry, transcript: TranscriptData?)] {
        var result = items

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

    private func matchesSearch(_ recordingData: (recording: RecordingEntry, transcript: TranscriptData?), searchTerms: String) -> Bool {
        // Check recording name
        if let name = recordingData.recording.recordingName?.lowercased(),
           name.contains(searchTerms) {
            return true
        }

        // Check transcript text
        if let transcript = recordingData.transcript {
            if transcript.plainText.lowercased().contains(searchTerms) {
                return true
            }
        }

        return false
    }

    private func loadRecordings() {
        // Use Core Data to get recordings
		let recordingsWithData = appCoordinator.getAllRecordingsWithData()

		// Deduplicate by resolved filename; prefer items with transcript and non-generic titles
		var bestByFilename: [String: (recording: RecordingEntry, transcript: TranscriptData?)] = [:]

		func isGenericName(_ name: String) -> Bool {
			if name.hasPrefix("recording_") { return true }
			if name.hasPrefix("V20210426-") || name.hasPrefix("V20210427-") { return true }
			if name.hasPrefix("apprecording-") { return true }
			if name.hasPrefix("importedfile-recording_") { return true }
			if name.count > 20 && (name.contains("1754") || name.contains("2025") || name.contains("2024")) { return true }
			return false
		}

		func score(_ entry: (recording: RecordingEntry, transcript: TranscriptData?)) -> Int {
			var s = 0
			if entry.transcript != nil { s += 3 }
			if let name = entry.recording.recordingName, !isGenericName(name) { s += 2 }
			if entry.recording.summary != nil { s += 1 }
			if entry.recording.duration > 0 { s += 1 }
			return s
		}

		for rd in recordingsWithData {
			let resolvedURL: URL?
			if rd.recording.isArchived {
				resolvedURL = appCoordinator.getAbsoluteURL(for: rd.recording)
					?? appCoordinator.getStoredURL(for: rd.recording)
			} else {
				resolvedURL = appCoordinator.getAbsoluteURL(for: rd.recording)
			}
			guard let url = resolvedURL else { continue }
			let key = url.lastPathComponent
			let candidate = (recording: rd.recording, transcript: rd.transcript)
			if let existing = bestByFilename[key] {
				bestByFilename[key] = score(existing) >= score(candidate) ? existing : candidate
			} else {
				bestByFilename[key] = candidate
			}
		}

		let deduped = Array(bestByFilename.values)

		// Separate imported transcripts from regular recordings
		let (imported, regular) = deduped.reduce(into: (imported: [(RecordingEntry, TranscriptData?)](), regular: [(RecordingEntry, TranscriptData?)]())) { result, item in
			// Check if this is an imported transcript (identified by audioQuality = "imported")
			if item.recording.audioQuality == "imported" {
				result.imported.append(item)
			} else {
				result.regular.append(item)
			}
		}

		// Sort by date (accessing tuple elements as $0.0 for RecordingEntry, $0.1 for TranscriptData)
		recordings = regular.sorted { $0.0.recordingDate ?? Date() > $1.0.recordingDate ?? Date() }
		importedTranscripts = imported.sorted { $0.0.recordingDate ?? Date() > $1.0.recordingDate ?? Date() }

		// Geocode locations for all recordings (with rate limiting)
		loadLocationAddressesBatch(for: recordings.map { $0.recording })
    }

    private func deleteImportedTranscripts(
        at offsets: IndexSet,
        in list: [(recording: RecordingEntry, transcript: TranscriptData?)]
    ) {
        let itemsToDelete = offsets.map { list[$0] }
        for importedTranscript in itemsToDelete {
            deleteImportedTranscript(importedTranscript)
        }

        // Reload the list
        loadRecordings()
    }

    private func deleteImportedTranscript(
        _ importedTranscript: (recording: RecordingEntry, transcript: TranscriptData?)
    ) {
        guard let recordingId = importedTranscript.recording.id else {
            AppLog.shared.transcription("Cannot delete imported transcript: missing recording ID", level: .error)
            return
        }

        // Delete the associated dummy audio file if it exists
        if let recordingURL = appCoordinator.getAbsoluteURL(for: importedTranscript.recording) {
            try? FileManager.default.removeItem(at: recordingURL)
            // Delete associated sidecar files if present
            for ext in ["location", "recordingmeta"] {
                let sidecarURL = recordingURL.deletingPathExtension().appendingPathExtension(ext)
                try? FileManager.default.removeItem(at: sidecarURL)
            }
            AppLog.shared.transcription("Deleted dummy audio file: \(recordingURL.lastPathComponent)", level: .debug)
        }

        // Check if there's an associated summary to preserve
        let hasSummary = appCoordinator.coreDataManager.getSummary(for: recordingId) != nil

        if hasSummary {
            // Preserve the summary - only delete the transcript and clear the audio URL
            if let transcript = appCoordinator.coreDataManager.getTranscript(for: recordingId) {
                appCoordinator.coreDataManager.deleteTranscript(id: transcript.id)
            }

            // Clear the recording URL to mark as "summary only" mode
            importedTranscript.recording.recordingURL = nil
            importedTranscript.recording.lastModified = Date()

            // Save the context
            try? appCoordinator.coreDataManager.saveContext()
            AppLog.shared.transcription("Deleted imported transcript, preserved summary")
        } else {
            // No summary to preserve - delete everything
            appCoordinator.coreDataManager.deleteRecording(id: recordingId)
            AppLog.shared.transcription("Deleted imported transcript")
        }
    }

    func loadLocationDataForRecording(url: URL) -> LocationData? {
        // Find the recording entry by URL
        guard let recording = appCoordinator.getRecording(url: url) else {
            return nil
        }

        // Use the proper location loading system
        return appCoordinator.loadLocationData(for: recording)
    }

    static func loadLocationDataForRecording(url: URL) -> LocationData? {
        // Legacy static method - try direct file access as fallback
        let locationURL = url.deletingPathExtension().appendingPathExtension("location")
        guard let data = try? Data(contentsOf: locationURL),
              let locationData = try? JSONDecoder().decode(LocationData.self, from: data) else {
            return nil
        }
        return locationData
    }

    private func loadLocationAddressesBatch(for recordings: [RecordingEntry]) {
        // Filter recordings that have location data and don't already have cached addresses
        let recordingsNeedingGeocode = recordings.filter { recording in
            guard let recordingURL = appCoordinator.getAbsoluteURL(for: recording),
                  let _ = appCoordinator.loadLocationData(for: recording) else { return false }
            return locationAddresses[recordingURL] == nil
        }

        // Process recordings one by one to respect rate limiting
        for recording in recordingsNeedingGeocode {
            loadLocationAddress(for: recording)
        }
    }

    private func loadLocationAddress(for recording: RecordingEntry) {
        // Use async dispatch to avoid blocking main thread
        Task {
            // Use the proper location loading system
            guard let locationData = appCoordinator.loadLocationData(for: recording),
                  let recordingURL = appCoordinator.getAbsoluteURL(for: recording) else {
                return
            }

            // Skip if we already have an address for this recording
            if locationAddresses[recordingURL] != nil {
                return
            }

            await MainActor.run {
                let location = CLLocation(latitude: locationData.latitude, longitude: locationData.longitude)
                // Use a default location manager since AudioRecorderViewModel doesn't have one
                let locationManager = LocationManager()
                locationManager.reverseGeocodeLocation(location) { address in
                    if let address = address {
                        self.locationAddresses[recordingURL] = address
                    }
                }
            }
        }
    }

    private func forceRefreshUI() {
        DispatchQueue.main.async {
            self.refreshTrigger.toggle()
            self.loadRecordings()
        }
    }

    private func generateTranscript(for recording: RecordingEntry) {
        // Skip if this recording already has a queued or processing transcription job.
        guard !transcriptionStarter.hasActiveTranscriptionJob(for: recording, appCoordinator: appCoordinator) else { return }

        // Ask the user whether to clean audio first; the dialog buttons route to TranscriptionStarter.
        recordingPendingTranscription = recording
        showingAudioCleanupPrompt = true
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
        backgroundProcessingManager.onTranscriptionCompleted = { _, job in
            Task { @MainActor in
                AppLog.shared.transcription("Background processing transcription completed for job")

                // Find the recording that matches this transcription
                if let recording = recordings.first(where: { recording in
                    guard let recordingURL = appCoordinator.getAbsoluteURL(for: recording.recording) else {
                        return false
                    }
                    return recordingURL == job.recordingURL
                }) {
                    AppLog.shared.transcription("Background transcript already saved by BackgroundProcessingManager", level: .debug)

                    // Don't automatically open the transcript view - let user choose when to edit

                    // Force UI refresh to update button states
                    self.forceRefreshUI()

                    // Send notification for other views to refresh
                    NotificationCenter.default.post(name: NSNotification.Name("TranscriptionCompleted"), object: nil)

                    // Show completion alert to notify user transcription finished in background
                    if !self.isShowingAlert {
                        self.completedTranscriptionText = "Transcription completed for: \(recording.recording.recordingName ?? "Unknown Recording")"
                        self.showingTranscriptionCompletionAlert = true
                    }
                } else {
                    AppLog.shared.transcription("Could not find recording for completed transcription", level: .error)
                }
            }
        }

        enhancedTranscriptionManager.onTranscriptionCompleted = { result, jobInfo in
            Task { @MainActor in

                AppLog.shared.transcription("Background transcription completed, available recordings: \(recordings.count)", level: .debug)

                // Find the recording that matches this transcription
                if let recording = recordings.first(where: { recording in
                    guard let recordingURL = appCoordinator.getAbsoluteURL(for: recording.recording) else {
                        return false
                    }
                    return recordingURL == jobInfo.recordingURL
                }) {
                    // Create transcript data and save it
                    guard let recordingURL = appCoordinator.getAbsoluteURL(for: recording.recording) else {
                        AppLog.shared.transcription("Invalid recording URL in completion handler", level: .error)
                        return
                    }

                    let transcriptData = TranscriptData(
                        recordingURL: recordingURL,
                        recordingName: recording.recording.recordingName ?? "Unknown Recording",
                        recordingDate: recording.recording.recordingDate ?? Date(),
                        segments: result.segments
                    )

                    // Save transcript using Core Data
                    let appCoordinator = appCoordinator
                    guard let recordingId = transcriptData.recordingId else {
                        AppLog.shared.transcription("Background transcript data missing recording ID", level: .error)
                        return
                    }
                    let transcriptId = appCoordinator.addTranscript(
                        for: recordingId,
                        segments: transcriptData.segments,
                        speakerMappings: transcriptData.speakerMappings,
                        engine: transcriptData.engine,
                        processingTime: transcriptData.processingTime,
                        confidence: transcriptData.confidence
                    )
                    if transcriptId != nil {
                        AppLog.shared.transcription("Background transcript saved to Core Data with ID: \(transcriptId!)")
                    } else {
                        AppLog.shared.transcription("Failed to save background transcript to Core Data", level: .error)
                    }

                    // Force UI refresh to update button states
                    self.forceRefreshUI()

                    // Send notification for other views to refresh
                    NotificationCenter.default.post(name: NSNotification.Name("TranscriptionCompleted"), object: nil)

                    // Show completion alert to notify user transcription finished in background
                    if !self.isShowingAlert {
                        self.completedTranscriptionText = "Transcription completed for: \(recording.recording.recordingName ?? "Unknown Recording")"
                        self.showingTranscriptionCompletionAlert = true
                    }
                } else {
                    AppLog.shared.transcription("No matching recording found for completed job", level: .error)
                }
            }
        }
    }
}

struct EditableTranscriptView: View {
    let recording: RecordingEntry
    let transcript: TranscriptData
    let transcriptManager: TranscriptManager
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appCoordinator: AppDataCoordinator
    @State private var locationAddress: String?
    @State private var editedSegments: [TranscriptSegment]
    @State private var speakerMappings: [String: String]
    @State private var isRerunningTranscription = false
    @State private var editableRecordingName: String
    @State private var savedRecordingName: String
    @State private var isUpdatingRecordingName = false
    @State private var recordingRenameError: String?
    @State private var showingRerunAlert = false
    @State private var showingSaveSuccessAlert = false
    @State private var showingSaveErrorAlert = false
    @State private var showingSpeakerEditor = false
    @State private var saveErrorMessage = ""
    @State private var isGeneratingSummary = false
    @State private var showSummarySheet = false
    @State private var summaryGenerationError: String?
    @State private var summaryStateRefresh = false
    @StateObject private var enhancedTranscriptionManager = EnhancedTranscriptionManager()
    @ObservedObject private var backgroundProcessingManager = BackgroundProcessingManager.shared

    private var uniqueSpeakers: [String] {
        var seen = Set<String>()
        return editedSegments.compactMap { seg in
            let s = seg.speaker
            guard !s.isEmpty, s != "Speaker", s != "Unknown", seen.insert(s).inserted else { return nil }
            return s
        }
    }

    init(recording: RecordingEntry, transcript: TranscriptData, transcriptManager: TranscriptManager) {
        self.recording = recording
        self.transcript = transcript
        self.transcriptManager = transcriptManager
        self._editedSegments = State(initialValue: transcript.segments)
        self._speakerMappings = State(initialValue: transcript.speakerMappings)
        let initialName = recording.recordingName ?? transcript.recordingName
        self._editableRecordingName = State(initialValue: initialName)
        self._savedRecordingName = State(initialValue: initialName)
    }

    var body: some View {
        // NavigationStack { Form } is the only sheet pattern that scrolls reliably
        // on Mac Catalyst. See feedback_mac_catalyst_scrollview.md.
        NavigationStack {
            Form {
                Section {
                    recordingTitleEditor
                }

                if editedSegments.isEmpty {
                    Section {
                        VStack(spacing: 16) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 48))
                                .foregroundColor(.accentColor)
                            Text("No transcript content available")
                                .font(.title3)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                            Text("Transcript segments: \(editedSegments.count)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                } else {
                    if !uniqueSpeakers.isEmpty {
                        Section {
                            Button {
                                showingSpeakerEditor = true
                            } label: {
                                HStack {
                                    Image(systemName: "person.2.fill")
                                        .foregroundColor(.purple)
                                    Text("Edit Speakers (\(uniqueSpeakers.count))")
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Edit Speakers")
                            .accessibilityValue(
                                AccessibilitySupport.itemCount(uniqueSpeakers.count, singular: "speaker")
                            )
                        }
                    }

                    Section("Segments") {
                        ForEach(Array(editedSegments.enumerated()), id: \.offset) { index, _ in
                            TranscriptSegmentView(segment: $editedSegments[index], speakerMappings: speakerMappings)
                        }
                    }
                    .id("transcript-\(editedSegments.count)-\(editedSegments.first?.text.prefix(10).hashValue ?? 0)")
                }

                summarySection

                Section {
                    Button {
                        showingRerunAlert = true
                    } label: {
                        HStack {
                            if isRerunningTranscription {
                                ProgressView().scaleEffect(0.8)
                                Text("Rerunning Transcription...")
                            } else {
                                Image(systemName: "arrow.clockwise")
                                Text("Rerun Transcription")
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isRerunningTranscription)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Edit Transcript")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier(BisonNotesAccessibilityID.transcriptDetail)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        if saveTranscript() {
                            showingSaveSuccessAlert = true
                        } else {
                            showingSaveErrorAlert = true
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .alert("Rerun Transcription", isPresented: $showingRerunAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Rerun", role: .destructive) {
                rerunTranscription()
            }
        } message: {
            Text("This will replace the current transcript with a new transcription using the currently configured transcription service. This action cannot be undone.")
        }
        .alert("Transcript Saved", isPresented: $showingSaveSuccessAlert) {
            Button("OK") {
                showingSaveSuccessAlert = false
                dismiss()
            }
        } message: {
            Text("Your transcript changes have been saved.")
        }
        .alert("Save Failed", isPresented: $showingSaveErrorAlert) {
            Button("OK", role: .cancel) {
                showingSaveErrorAlert = false
            }
        } message: {
            Text(saveErrorMessage)
        }
        .alert("Rename Failed", isPresented: Binding(
            get: { recordingRenameError != nil },
            set: { if !$0 { recordingRenameError = nil } }
        )) {
            Button("OK", role: .cancel) {
                recordingRenameError = nil
            }
        } message: {
            Text(recordingRenameError ?? "Unknown error")
        }
        .sheet(isPresented: $showingSpeakerEditor) {
            SpeakerEditingView(
                speakerIds: uniqueSpeakers,
                speakerMappings: $speakerMappings
            )
        }
        .sheet(isPresented: $showSummarySheet) {
            summarySheetContent
        }
        .alert("Unable to Generate Summary", isPresented: Binding(
            get: { summaryGenerationError != nil },
            set: { if !$0 { summaryGenerationError = nil } }
        )) {
            Button("OK", role: .cancel) { summaryGenerationError = nil }
        } message: {
            Text(summaryGenerationError ?? "Unknown error")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SummaryCreated"))) { _ in
            isGeneratingSummary = false
            summaryStateRefresh.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SummaryDeleted"))) { _ in
            summaryStateRefresh.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TranscriptionRerunCompleted"))) { notification in
            if let userInfo = notification.userInfo,
               let notificationURL = userInfo["recordingURL"] as? URL,
               let segments = userInfo["segments"] as? [TranscriptSegment],
               let recordingURL = appCoordinator.getAbsoluteURL(for: recording),
               notificationURL == recordingURL {

                AppLog.shared.transcription("Received transcription rerun completion notification", level: .debug)
                saveNewTranscriptToCoreData(segments: segments)
                isRerunningTranscription = false
                AppLog.shared.transcription("Transcript UI updated with rerun results from notification")
                NotificationCenter.default.post(name: NSNotification.Name("TranscriptReplacementCompleted"), object: nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TranscriptionCompleted"))) { _ in
            refreshTranscriptFromCoreData()
        }
        .onAppear {
            refreshTranscriptFromCoreData()
        }
    }

    private var recordingTitleEditor: some View {
        RecordingTitleEditorView(
            title: $editableRecordingName,
            savedTitle: savedRecordingName,
            isSaving: isUpdatingRecordingName,
            onSave: renameRecordingFromTranscript
        )
    }

    @ViewBuilder
    private var summarySection: some View {
        if let recordingId = recording.id {
            let hasSummary = appCoordinator.getSummary(for: recordingId) != nil
            let isProcessing = isGeneratingSummary
                || recording.summaryStatus == ProcessingStatus.processing.rawValue

            Section {
                Button {
                    if hasSummary {
                        showSummarySheet = true
                    } else if !isProcessing {
                        generateSummary()
                    }
                } label: {
                    HStack {
                        if isProcessing {
                            ProgressView().scaleEffect(0.8)
                            Text("Generating Summary…")
                        } else if hasSummary {
                            Image(systemName: "doc.text.fill")
                                .foregroundColor(.blue)
                            Text("View Summary")
                        } else {
                            Image(systemName: "doc.text.magnifyingglass")
                            Text("Generate Summary")
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
            .buttonStyle(.plain)
            .disabled(isProcessing)
            .accessibilityLabel(
                hasSummary
                    ? "View Summary for \(savedRecordingName)"
                    : "Generate Summary for \(savedRecordingName)"
            )
            .accessibilityValue(isProcessing ? "In progress" : "Ready")
        }
            .id("summary-section-\(recordingId)-\(hasSummary)-\(isProcessing)-\(summaryStateRefresh)")
        }
    }

    @ViewBuilder
    private var summarySheetContent: some View {
        if let recordingId = recording.id,
           let enhancedSummary = appCoordinator.getCompleteRecordingData(id: recordingId)?.summary {
            SummaryDetailView(
                recording: RecordingFile(
                    url: appCoordinator.getAbsoluteURL(for: recording) ?? URL(fileURLWithPath: ""),
                    name: recording.recordingName ?? "Unknown",
                    date: recording.recordingDate ?? Date(),
                    duration: recording.duration,
                    locationData: appCoordinator.coreDataManager.getLocationData(for: recording)
                ),
                summaryData: enhancedSummary
            )
            .environmentObject(appCoordinator)
        } else {
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

    private func generateSummary() {
        AppLog.shared.summarization("generateSummary called from EditableTranscriptView", level: .debug)
        isGeneratingSummary = true

        let selectedEngine = UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? AIEngineType.mlxSwift.rawValue
        let selectedModel = UserDefaults.standard.string(forKey: "SelectedAIModel")
        let recordingURL: URL
        if let absoluteURL = appCoordinator.getAbsoluteURL(for: recording) {
            recordingURL = absoluteURL
        } else {
            recordingURL = URL(fileURLWithPath: recording.recordingURL ?? "")
        }
        let recordingName = recording.recordingName ?? "Unknown Recording"

        Task {
            do {
                try await BackgroundProcessingManager.shared.startSummarizationJob(
                    recordingURL: recordingURL,
                    recordingName: recordingName,
                    engine: selectedEngine,
                    modelName: selectedModel
                )
                AppLog.shared.summarization("Summary job queued from EditableTranscriptView")
            } catch {
                AppLog.shared.summarization("Failed to queue summary job from EditableTranscriptView: \(error)", level: .error)
                await MainActor.run {
                    if let summarizationError = error as? SummarizationError {
                        summaryGenerationError = summarizationError.localizedDescription
                    } else {
                        summaryGenerationError = "Failed to start summary: \(error.localizedDescription)"
                    }
                    isGeneratingSummary = false
                }
            }
        }
    }

    private func saveTranscript() -> Bool {
        guard let recordingId = recording.id else {
            AppLog.shared.transcription("Cannot save transcript: missing recording ID", level: .error)
            saveErrorMessage = "Unable to save transcript because the recording is missing an identifier."
            return false
        }

        let transcriptId = appCoordinator.addTranscript(
            for: recordingId,
            segments: editedSegments,
            speakerMappings: speakerMappings,
            engine: transcript.engine,
            processingTime: transcript.processingTime,
            confidence: transcript.confidence
        )

        if let transcriptId {
            AppLog.shared.transcription("Saved edited transcript with ID: \(transcriptId)")
            NotificationCenter.default.post(name: NSNotification.Name("TranscriptionCompleted"), object: nil)
            return true
        } else {
            AppLog.shared.transcription("Failed to save edited transcript", level: .error)
            saveErrorMessage = "We couldn't save your transcript changes. Please try again."
            return false
        }
    }

    private func renameRecordingFromTranscript() {
        let trimmedName = editableRecordingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isUpdatingRecordingName,
              !trimmedName.isEmpty,
              trimmedName != savedRecordingName,
              let recordingId = recording.id else {
            return
        }

        isUpdatingRecordingName = true

        Task {
            do {
                // Updates the display name only (recordingName field in Core Data).
                // Physical audio file renaming is not performed here, consistent with SummaryDetailView.
                try appCoordinator.coreDataManager.updateRecordingName(for: recordingId, newName: trimmedName)

                await MainActor.run {
                    isUpdatingRecordingName = false
                    savedRecordingName = trimmedName
                    editableRecordingName = trimmedName
                    NotificationCenter.default.post(
                        name: NSNotification.Name("RecordingRenamed"),
                        object: nil,
                        userInfo: ["recordingId": recordingId, "newName": trimmedName]
                    )
                    AppLog.shared.transcription("Updated recording title from transcript editor to: \(trimmedName)")
                }
            } catch {
                await MainActor.run {
                    isUpdatingRecordingName = false
                    recordingRenameError = error.localizedDescription
                }
                AppLog.shared.transcription("Failed to update recording title from transcript editor: \(error)", level: .error)
            }
        }
    }

    private func rerunTranscription() {
        AppLog.shared.transcription("Starting transcription rerun", level: .debug)

        isRerunningTranscription = true

        Task {
            do {
                // Get the currently configured transcription engine
                let selectedEngine = TranscriptionEngine(rawValue: UserDefaults.standard.string(forKey: "selectedTranscriptionEngine") ?? TranscriptionEngine.fluidAudio.rawValue) ?? .fluidAudio

                AppLog.shared.transcription("Using transcription engine: \(selectedEngine.rawValue)", level: .debug)

                // Get the absolute URL using the coordinator
                guard let recordingURL = appCoordinator.getAbsoluteURL(for: recording) else {
                    AppLog.shared.transcription("Invalid recording URL for rerun", level: .error)
                    await MainActor.run {
                        isRerunningTranscription = false
                    }
                    return
                }

                AppLog.shared.transcription("Rerunning transcription for file: \(recordingURL.lastPathComponent)", level: .debug)

                // Start transcription job through BackgroundProcessingManager
                try await backgroundProcessingManager.startTranscriptionJob(
                    recordingURL: recordingURL,
                    recordingName: recording.recordingName ?? "Unknown Recording",
                    engine: selectedEngine
                )

                AppLog.shared.transcription("Transcription rerun job started through BackgroundProcessingManager")

                // Set up a one-time completion handler for this specific rerun
                setupRerunCompletionHandler(for: recordingURL)

            } catch {
                AppLog.shared.transcription("Failed to start transcription rerun job: \(error)", level: .error)

                // Fallback to direct transcription if background processing fails
                AppLog.shared.transcription("Falling back to direct transcription for rerun...", level: .debug)
                do {
                    guard let recordingURL = appCoordinator.getAbsoluteURL(for: recording) else {
                        AppLog.shared.transcription("Invalid recording URL for fallback transcription rerun", level: .error)
                        await MainActor.run {
                            isRerunningTranscription = false
                        }
                        return
                    }

                    // Get the currently configured transcription engine
                    let selectedEngine = TranscriptionEngine(rawValue: UserDefaults.standard.string(forKey: "selectedTranscriptionEngine") ?? TranscriptionEngine.fluidAudio.rawValue) ?? .fluidAudio

                    let result = try await enhancedTranscriptionManager.transcribeAudioFile(at: recordingURL, using: selectedEngine)

                    AppLog.shared.transcription("Transcription rerun result: success=\(result.success), textLength=\(result.fullText.count)", level: .debug)

                    if result.success && !result.fullText.isEmpty {
                        await MainActor.run {
                            // Save the new transcript to Core Data first (this will replace the existing transcript)
                            saveNewTranscriptToCoreData(segments: result.segments)

                            AppLog.shared.transcription("Transcript UI updated with rerun results")

                            // Force the parent view to refresh by posting a notification
                            NotificationCenter.default.post(name: NSNotification.Name("TranscriptReplacementCompleted"), object: nil)
                        }
                    } else {
                        AppLog.shared.transcription("Transcription rerun failed or returned empty result", level: .error)
                    }
                } catch {
                    AppLog.shared.transcription("Fallback transcription rerun also failed: \(error)", level: .error)
                }

                await MainActor.run {
                    isRerunningTranscription = false
                }
            }
        }
    }

    private func setupRerunCompletionHandler(for recordingURL: URL) {
        // Set up a temporary completion handler for the background processing manager
        let originalHandler = backgroundProcessingManager.onTranscriptionCompleted

        backgroundProcessingManager.onTranscriptionCompleted = { transcriptData, job in
            // Only handle completion for our specific recording
            if job.recordingURL == recordingURL {
                Task { @MainActor in
                    AppLog.shared.transcription("Background processing transcription rerun completed")

                    // Save the new transcript to Core Data and post notification
                    AppLog.shared.transcription("Saving rerun transcript to Core Data...", level: .debug)

                    // Post notification with the new segments
                    NotificationCenter.default.post(
                        name: NSNotification.Name("TranscriptionRerunCompleted"),
                        object: nil,
                        userInfo: [
                            "recordingURL": recordingURL,
                            "segments": transcriptData.segments
                        ]
                    )

                    AppLog.shared.transcription("Posted transcription rerun completion notification", level: .debug)

                    // Restore the original handler
                    BackgroundProcessingManager.shared.onTranscriptionCompleted = originalHandler
                }
            } else {
                // If it's not our recording, call the original handler
                originalHandler?(transcriptData, job)
            }
        }
    }

    private func saveNewTranscriptToCoreData(segments: [TranscriptSegment]) {
        AppLog.shared.transcription("Saving new transcript to Core Data...", level: .debug)

        // We need to find and update the existing transcript in Core Data
        guard let recordingURL = appCoordinator.getAbsoluteURL(for: recording) else {
            AppLog.shared.transcription("Invalid recording URL for Core Data save", level: .error)
            return
        }

        // Use the app coordinator from environment
        let coordinator = appCoordinator

        // Find the recording entry
        if let recordingEntry = coordinator.getRecording(url: recordingURL),
           let recordingId = recordingEntry.id {

            // For rerun transcriptions, we'll replace the existing transcript
            // The Core Data system will update the existing transcript instead of creating a new one
            AppLog.shared.transcription("Replacing transcript for recording ID: \(recordingId)", level: .debug)

            // Get the selected transcription engine
            let engineString = UserDefaults.standard.string(forKey: "selectedTranscriptionEngine") ?? TranscriptionEngine.fluidAudio.rawValue
            let engine = TranscriptionEngine(rawValue: engineString) ?? .fluidAudio

            // Add the new transcript
            let transcriptId = coordinator.addTranscript(
                for: recordingId,
                segments: segments,
                speakerMappings: [:], // No speaker mappings needed
                engine: engine,
                processingTime: 0.0, // We don't track this in reruns
                confidence: 1.0
            )

            if transcriptId != nil {
                AppLog.shared.transcription("Transcript replaced in Core Data with ID: \(transcriptId!)")

                // Immediately refresh the UI with the updated transcript data
                refreshTranscriptFromCoreData()

                // Post notification to refresh the main transcripts view
                NotificationCenter.default.post(name: NSNotification.Name("TranscriptionCompleted"), object: nil)
            } else {
                AppLog.shared.transcription("Failed to replace transcript in Core Data", level: .error)
            }
        } else {
            AppLog.shared.transcription("Could not find recording entry in Core Data for transcript save", level: .error)
        }
    }

    private func refreshTranscriptFromCoreData() {
        guard let recordingURL = appCoordinator.getAbsoluteURL(for: recording) else {
            return
        }

        // Force Core Data context to refresh its cache
        appCoordinator.coreDataManager.refreshContext()

        // Get the updated transcript data from Core Data
        if let recordingEntry = appCoordinator.getRecording(url: recordingURL),
           let recordingId = recordingEntry.id,
           let updatedTranscript = appCoordinator.getTranscriptData(for: recordingId) {

            // Only update if we have segments with actual content
            let hasValidContent = updatedTranscript.segments.contains { !$0.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty }

            guard hasValidContent else { return }

            // Force SwiftUI to detect the change by clearing first, then setting
            editedSegments = []
            speakerMappings = updatedTranscript.speakerMappings

            // Small delay to ensure UI updates
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.editedSegments = updatedTranscript.segments
            }
        }
    }
}

struct TranscriptSegmentView: View {
    @Binding var segment: TranscriptSegment
    var speakerMappings: [String: String] = [:]

    private var hasSpeakerLabel: Bool {
        let s = segment.speaker
        return !s.isEmpty && s != "Speaker" && s != "Unknown"
    }

    private var displaySpeaker: String {
        // Check mappings first (user-assigned names), then format raw ID
        if let mapped = speakerMappings[segment.speaker], !mapped.isEmpty {
            return mapped
        }
        let s = segment.speaker
        if s.hasPrefix("speaker_") {
            let num = s.dropFirst("speaker_".count)
            return "Speaker \(num)"
        }
        return s
    }

    private static let speakerColors: [Color] = [
        .blue, .purple, .orange, .teal, .pink, .indigo, .mint, .cyan, .brown, .green
    ]

    private var speakerColor: Color {
        // Use original speaker ID for consistent color even after renaming
        let hash = abs(segment.speaker.hashValue)
        return Self.speakerColors[hash % Self.speakerColors.count]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(formatTime(segment.startTime))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.tertiarySystemGroupedBackground), in: Capsule())

                if hasSpeakerLabel {
                    Text(displaySpeaker)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(speakerColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(speakerColor.opacity(0.12), in: Capsule())
                }

                Spacer()
            }

            TextEditor(text: Binding(
                get: { segment.text },
                set: { segment = TranscriptSegment(speaker: segment.speaker, text: $0, startTime: segment.startTime, endTime: segment.endTime) }
            ))
            .font(.body)
            .frame(minHeight: max(120, calculateTextHeight(for: segment.text)))
            .padding(12)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(.separator).opacity(0.35), lineWidth: 1)
            )
            .accessibilityLabel(
                hasSpeakerLabel
                    ? "\(displaySpeaker), starts at \(formatTime(segment.startTime))"
                    : "Transcript segment starting at \(formatTime(segment.startTime))"
            )
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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

// MARK: - Speaker Editing View

struct SpeakerEditingView: View {
    let speakerIds: [String]
    @Binding var speakerMappings: [String: String]
    @Environment(\.dismiss) private var dismiss
    @State private var editingNames: [String: String] = [:]

    private static let speakerColors: [Color] = [
        .blue, .purple, .orange, .teal, .pink, .indigo, .mint, .cyan, .brown, .green
    ]

    init(speakerIds: [String], speakerMappings: Binding<[String: String]>) {
        self.speakerIds = speakerIds
        self._speakerMappings = speakerMappings

        // Initialize editing state from existing mappings
        var initial: [String: String] = [:]
        for id in speakerIds {
            initial[id] = speakerMappings.wrappedValue[id] ?? ""
        }
        self._editingNames = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            speakerForm
                .navigationTitle("Edit Speakers")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Apply") { applyNames() }
                            .fontWeight(.semibold)
                    }
                }
        }
    }

    private var speakerForm: some View {
        Form {
            Section(header: Text("Rename Speakers"), footer: Text("Enter a name for each speaker. Changes apply to the entire transcript and are used in AI summaries.")) {
                ForEach(speakerIds, id: \.self) { speakerId in
                    HStack(spacing: 12) {
                        let hash = abs(speakerId.hashValue)
                        let color = Self.speakerColors[hash % Self.speakerColors.count]

                        Circle()
                            .fill(color)
                            .frame(width: 10, height: 10)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(defaultName(for: speakerId))
                                .font(.caption2)
                                .foregroundColor(.secondary)

                            TextField(defaultName(for: speakerId), text: binding(for: speakerId))
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .autocapitalization(.words)
                        }
                    }
                }
            }

            if speakerMappings.values.contains(where: { !$0.isEmpty }) {
                Section {
                    Button("Clear All Names", role: .destructive) {
                        for id in speakerIds {
                            editingNames[id] = ""
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
    }

    private func applyNames() {
        var newMappings: [String: String] = [:]
        for (id, name) in editingNames {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                newMappings[id] = trimmed
            }
        }
        speakerMappings = newMappings
        dismiss()
    }

    private func defaultName(for speakerId: String) -> String {
        if speakerId.hasPrefix("speaker_") {
            let num = speakerId.dropFirst("speaker_".count)
            return "Speaker \(num)"
        }
        return speakerId
    }

    private func binding(for speakerId: String) -> Binding<String> {
        Binding(
            get: { editingNames[speakerId] ?? "" },
            set: { editingNames[speakerId] = $0 }
        )
    }
}

struct TranscriptDetailView: View {
    let recording: RecordingEntry
    let transcriptText: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appCoordinator: AppDataCoordinator
    @State private var locationAddress: String?

    var body: some View {
        // NavigationStack { Form } is the only sheet pattern that scrolls reliably
        // on Mac Catalyst. See feedback_mac_catalyst_scrollview.md.
        NavigationStack {
            Form {
                if transcriptText.isEmpty {
                    Section {
                        HStack {
                            Spacer()
                            VStack(spacing: 16) {
                                ProgressView().scaleEffect(1.5)
                                Text("Generating transcript...")
                                    .font(.headline)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 40)
                    }
                } else {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(recording.recordingName ?? "Unknown Recording")
                                .font(.title3)
                                .fontWeight(.bold)
                            Text(UserPreferences.shared.formatMediumDateTime(recording.recordingDate ?? Date()))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if let recordingURL = appCoordinator.getAbsoluteURL(for: recording),
                               let locationData = TranscriptsView.loadLocationDataForRecording(url: recordingURL) {
                                HStack(spacing: 4) {
                                    Image(systemName: "location.fill")
                                        .font(.caption)
                                        .foregroundColor(.accentColor)
                                    Text(locationAddress ?? locationData.coordinateString)
                                        .font(.caption)
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Section {
                        Text(transcriptText)
                            .font(.body)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Transcript")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier(BisonNotesAccessibilityID.transcriptDetail)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if let recordingURL = appCoordinator.getAbsoluteURL(for: recording),
                   let locationData = TranscriptsView.loadLocationDataForRecording(url: recordingURL) {
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
                    Text("Confidence: \(safeConfidencePercent(title.confidence))%")
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
                        Text("\(safeConfidencePercent(title.confidence))%")
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
        guard title.confidence.isFinite else { return .gray }
        switch title.confidence {
        case 0.8...1.0: return .green
        case 0.6..<0.8: return .blue
        case 0.4..<0.6: return .orange
        default: return .red
        }
    }
}

// MARK: - Helper Functions

private func safeConfidencePercent(_ confidence: Double) -> Int {
    guard confidence.isFinite else { return 0 }
    return Int(confidence * 100)
}
