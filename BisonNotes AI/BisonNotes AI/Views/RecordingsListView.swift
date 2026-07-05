//
//  RecordingsListView.swift
//  Audio Journal
//
//  Created by Tim Champ on 7/28/25.
//

import SwiftUI
import CoreLocation
import AVFoundation

typealias AudioRecordingFile = RecordingFile

class DeletionData: ObservableObject {
    @Published var recordingToDelete: AudioRecordingFile?
    @Published var fileRelationships: FileRelationships?
}

struct RecordingsListView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @EnvironmentObject var appCoordinator: AppDataCoordinator
    @StateObject private var enhancedFileManager = EnhancedFileManager.shared
    @StateObject private var deletionData = DeletionData()
    @State private var recordings: [AudioRecordingFile] = []
    @State private var selectedLocationData: LocationData?
    @State private var locationAddresses: [URL: String] = [:]
    @State private var preserveSummaryOnDelete = false
    @State private var showingEnhancedDeleteDialog = false
    @State private var selectedRecordingForPlayer: AudioRecordingFile?
    enum SelectionAction {
        case combine
        case archive
        case export

        var instruction: String {
            switch self {
            case .combine: return "Select 2 recordings to combine"
            case .archive: return "Select recordings to archive"
            case .export: return "Select recordings to export"
            }
        }

        var maxSelection: Int? {
            switch self {
            case .combine: return 2
            case .archive, .export: return nil
            }
        }
    }

    @State private var isSelectionMode = false
    @State private var selectionAction: SelectionAction = .combine
    @State private var selectedRecordings: Set<URL> = []
    @State private var showingCombineView = false
    @State private var recordingsToCombine: (first: AudioRecordingFile, second: AudioRecordingFile)?
    @State private var showSelectionWarning = false
    @State private var searchText = ""
    @State private var showingArchiveConfirmation = false
    @State private var showingArchiveExportPicker = false
    @State private var showingArchiveOlderThan = false
    @State private var archiveOlderThanDays = 30
    @State private var removeLocalAfterArchive = false
    @State private var recordingsToArchive: [RecordingEntry] = []
    @State private var archiveExportURLs: [URL] = []
    @State private var showingAudioExportPicker = false
    @State private var audioExportURLs: [URL] = []
    @State private var audioExportSkippedCount = 0
    @State private var archiveInfoRecording: AudioRecordingFile?
    @State private var archiveRestoreError: String?
    @State private var restoringArchiveRecordingId: UUID?
    @State private var showDateFilter = false
    @State private var dateFilterStart: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var dateFilterEnd: Date = Date()
    @State private var isDateFilterActive = false

    // Transcript-from-recording flow
    @ObservedObject private var transcriptionStarter = TranscriptionStarter.shared
    @ObservedObject private var backgroundProcessingManager = BackgroundProcessingManager.shared
    @State private var showingAudioCleanupPrompt = false
    @State private var recordingPendingTranscription: RecordingEntry?
    @State private var selectedRecordingForTranscript: RecordingEntry?
    @State private var transcriptStateRefresh = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerView

                if isSelectionMode {
                    selectionBanner
                }

                recordingsContent
            }
            .background(Color(.systemGroupedBackground))
            .searchable(text: $searchText, prompt: "Search recordings...")
            .sheet(isPresented: $showDateFilter) {
                dateFilterSheet
            }
            .sheet(isPresented: $showingEnhancedDeleteDialog) {
                if let recording = deletionData.recordingToDelete, let relationships = deletionData.fileRelationships {
                    EnhancedDeleteDialog(
                        recording: recording,
                        relationships: relationships,
                        preserveSummary: $preserveSummaryOnDelete,
                        onConfirm: {
                            Task {
                                await deleteRecordingWithRelationships(recording, preserveSummary: preserveSummaryOnDelete)
                            }
                            showingEnhancedDeleteDialog = false
                        },
                        onCancel: {
                            showingEnhancedDeleteDialog = false
                        }
                    )
                } else {
                    // Loading or error state
                    VStack(spacing: 20) {
                        if deletionData.recordingToDelete != nil {
                            // Loading state
                            VStack(spacing: 16) {
                                ProgressView()
                                    .scaleEffect(1.2)
                                Text("Preparing deletion options...")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            // Error state
                            VStack(spacing: 16) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 40))
                                    .foregroundColor(.orange)
                                Text("Unable to prepare deletion")
                                    .font(.title2)
                                    .fontWeight(.medium)
                                Text("Please try again")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Button("Cancel") {
                            showingEnhancedDeleteDialog = false
                            deletionData.recordingToDelete = nil
                            deletionData.fileRelationships = nil
                        }
                        .padding()
                    }
                    .padding()
                }
            }
            .sheet(item: $selectedLocationData) { locationData in
                LocationDetailView(locationData: locationData)
            }
            .sheet(item: $selectedRecordingForPlayer) { recording in
                AudioPlayerView(recording: recording)
                    .environmentObject(recorderVM)
                    .environmentObject(appCoordinator)
            }
            .sheet(isPresented: $showingCombineView) {
                if let recordings = recordingsToCombine {
                    let combiner = RecordingCombiner.shared
                    let recommended = combiner.determineFirstRecording(
                        firstURL: recordings.first.url,
                        secondURL: recordings.second.url
                    ).first
                    let recommendedRecording = recommended == recordings.first.url ? recordings.first : recordings.second

                    CombineRecordingsView(
                        firstRecording: recordings.first,
                        secondRecording: recordings.second,
                        recommendedFirst: recommendedRecording
                    )
                    .environmentObject(appCoordinator)
                }
            }
            .sheet(isPresented: $showingArchiveConfirmation) {
                ArchiveConfirmationView(
                    recordingCount: recordingsToArchive.count,
                    totalSize: RecordingArchiveService.shared.totalFileSize(for: recordingsToArchive),
                    recordingNames: recordingsToArchive.compactMap { $0.recordingName },
                    removeLocal: $removeLocalAfterArchive,
                    onConfirm: {
                        showingArchiveConfirmation = false
                        archiveExportURLs = RecordingArchiveService.shared.prepareArchiveExportURLs(for: recordingsToArchive)
                        if !archiveExportURLs.isEmpty {
                            showingArchiveExportPicker = true
                        } else {
                            RecordingArchiveService.shared.cleanupArchiveStaging()
                        }
                    },
                    onCancel: {
                        showingArchiveConfirmation = false
                        recordingsToArchive = []
                    }
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingArchiveExportPicker) {
                DocumentExportPicker(urls: archiveExportURLs) { success, exportedURLs in
                    showingArchiveExportPicker = false
                    if success {
                        let archivedCount = RecordingArchiveService.shared.archiveRecordings(
                            recordingsToArchive,
                            removeLocal: removeLocalAfterArchive,
                            exportedURLs: exportedURLs
                        )
                        if archivedCount == 0 {
                            archiveRestoreError = "The export completed, but the selected destination was not iCloud Drive or was not trackable. The audio was left local so you can archive it again to iCloud Drive."
                        }
                        isSelectionMode = false
                        selectedRecordings.removeAll()
                        loadRecordings()
                    }
                    recordingsToArchive = []
                    archiveExportURLs = []
                    RecordingArchiveService.shared.cleanupArchiveStaging()
                }
            }
            .sheet(isPresented: $showingAudioExportPicker) {
                DocumentExportPicker(urls: audioExportURLs) { success, _ in
                    showingAudioExportPicker = false
                    if success {
                        if audioExportSkippedCount > 0 {
                            let skippedText = audioExportSkippedCount == 1 ? "1 selected recording was" : "\(audioExportSkippedCount) selected recordings were"
                            archiveRestoreError = "\(skippedText) not exported because the audio is not stored locally. Restore archived audio before exporting it."
                        }
                        isSelectionMode = false
                        selectedRecordings.removeAll()
                    }
                    audioExportURLs = []
                    audioExportSkippedCount = 0
                    RecordingArchiveService.shared.cleanupAudioExportStaging()
                }
            }
            .sheet(isPresented: $showingArchiveOlderThan) {
                archiveOlderThanSheet
            }
            .alert("Audio Archived", isPresented: Binding(
                get: { archiveInfoRecording != nil },
                set: { if !$0 { archiveInfoRecording = nil } }
            )) {
                Button("OK", role: .cancel) { archiveInfoRecording = nil }
            } message: {
                if let rec = archiveInfoRecording {
                    let note = rec.archiveNote ?? "Exported to iCloud Drive"
                    let dateStr = rec.archivedAtString ?? ""
                    let location = RecordingArchiveService.shared.primaryArchiveLocation(for: rec.recordingId)
                    let locationText = location.map { "\nSaved location: \($0.providerDisplayName) / \($0.displayName)" } ?? ""
                    Text("\(note)\(dateStr.isEmpty ? "" : " on \(dateStr)")\(locationText)\n\nThe audio file is no longer stored locally. Use the download button to restore it, or use \"Import Audio Files\" if the file was moved.")
                }
            }
            .alert("Audio File Error", isPresented: Binding(
                get: { archiveRestoreError != nil },
                set: { if !$0 { archiveRestoreError = nil } }
            )) {
                Button("OK", role: .cancel) { archiveRestoreError = nil }
            } message: {
                Text(archiveRestoreError ?? "Unknown error")
            }
            .sheet(item: $selectedRecordingForTranscript) { entry in
                if let recordingId = entry.id,
                   let transcript = appCoordinator.getTranscriptData(for: recordingId) {
                    EditableTranscriptView(recording: entry, transcript: transcript, transcriptManager: TranscriptManager.shared)
                        .environmentObject(appCoordinator)
                } else {
                    TranscriptDetailView(recording: entry, transcriptText: "")
                        .environmentObject(appCoordinator)
                }
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
        }
        .onAppear {
            refreshFileRelationships()
            loadRecordings()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SummaryCreated"))) { _ in
            loadRecordings()
            refreshFileRelationships()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SummaryDeleted"))) { _ in
            loadRecordings()
            refreshFileRelationships()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RecordingRenamed"))) { _ in
            loadRecordings()
            refreshFileRelationships()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RecordingCloudSyncPreferenceChanged"))) { _ in
            loadRecordings()
            refreshFileRelationships()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("iCloudReconcileCompleted"))) { _ in
            loadRecordings()
            refreshFileRelationships()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RecordingAdded"))) { _ in
            loadRecordings()
            refreshFileRelationships()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TranscriptionCompleted"))) { _ in
            transcriptStateRefresh.toggle()
            loadRecordings()
        }
    }

    private var headerView: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recordings")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)

                Text(recordingsHeaderSubtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isSelectionMode {
                selectionHeaderActions
            } else {
                standardHeaderActions
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .background(Color(.systemGroupedBackground))
    }

    private var recordingsHeaderSubtitle: String {
        if recordings.isEmpty {
            return "Manage audio files"
        }

        let count = recordings.count
        return "\(count) recording\(count == 1 ? "" : "s")"
    }

    private var selectionHeaderActions: some View {
        HStack(spacing: 8) {
            if selectionAction == .combine && selectedRecordings.count >= 2 {
                Button(action: handleCombineSelected) {
                    Label("Combine", systemImage: "link")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if selectionAction == .archive && !selectedRecordings.isEmpty {
                Button(action: prepareArchiveFromSelection) {
                    Label("Archive", systemImage: "archivebox")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if selectionAction == .export && !selectedRecordings.isEmpty {
                Button(action: prepareExportFromSelection) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Button("Cancel") {
                isSelectionMode = false
                selectedRecordings.removeAll()
                showSelectionWarning = false
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var standardHeaderActions: some View {
        HStack(spacing: 10) {
            Button(action: { showDateFilter = true }) {
                Image(systemName: isDateFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.headline)
                    .frame(width: 36, height: 36)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .accessibilityLabel("Filter Recordings")

            Menu {
                if recordings.count >= 2 {
                    Button(action: {
                        selectionAction = .combine
                        isSelectionMode = true
                        selectedRecordings.removeAll()
                        showSelectionWarning = false
                    }) {
                        Label("Combine Recordings", systemImage: "link")
                    }
                }

                Button(action: {
                    selectionAction = .archive
                    isSelectionMode = true
                    selectedRecordings.removeAll()
                    showSelectionWarning = false
                }) {
                    Label("Archive Selected", systemImage: "archivebox")
                }

                Button(action: {
                    selectionAction = .export
                    isSelectionMode = true
                    selectedRecordings.removeAll()
                    showSelectionWarning = false
                }) {
                    Label("Export Selected", systemImage: "square.and.arrow.up")
                }

                Button(action: {
                    showingArchiveOlderThan = true
                }) {
                    Label("Archive Older Than...", systemImage: "calendar.badge.clock")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .frame(width: 36, height: 36)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .accessibilityLabel("Recording Actions")

            Button(action: {
                dismiss()
            }) {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 36, height: 36)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .accessibilityLabel("Done")
        }
    }

    private var recordingsContent: some View {
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

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            Text("No Recordings")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.primary)

            Text("Start recording or import audio files to see them here")
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
            return "No recordings match \"\(searchText)\" in the selected date range."
        } else if hasSearch {
            return "No recordings match \"\(searchText)\"."
        } else if isDateFilterActive {
            return "No recordings found between \(dateFilterStart.formatted(date: .abbreviated, time: .omitted)) and \(dateFilterEnd.formatted(date: .abbreviated, time: .omitted))."
        } else {
            return "No recordings found."
        }
    }

    private var activeDateFilterBanner: some View {
        HStack {
            Image(systemName: "calendar")
                .foregroundColor(.blue)
            Text("\(dateFilterStart, format: .dateTime.month().day()) - \(dateFilterEnd, format: .dateTime.month().day())")
                .font(.subheadline)
                .fontWeight(.medium)
            Spacer()
            Button(action: {
                isDateFilterActive = false
            }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private var dateFilterSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    VStack(spacing: 10) {
                        DatePicker("From", selection: $dateFilterStart, in: ...Date(), displayedComponents: .date)
                        Divider()
                        DatePicker("To", selection: $dateFilterEnd, in: dateFilterStart...Date(), displayedComponents: .date)
                    }
                    .padding(16)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 20)
                    .padding(.top, 18)

                    if isDateFilterActive {
                        Button(role: .destructive) {
                            isDateFilterActive = false
                            showDateFilter = false
                        } label: {
                            Label("Clear Filter", systemImage: "xmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .padding(.horizontal, 20)
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
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
                    }
                }
            }
        }
    }

    private func recordingsListView(_ filtered: [AudioRecordingFile]) -> some View {
        let sectioned = DateSectionHelper.groupBySection(filtered, dateKeyPath: \.date)

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(sectioned, id: \.section) { sectionData in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(sectionData.section.title)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                            .padding(.horizontal, 4)

                        VStack(spacing: 10) {
                            ForEach(sectionData.items) { recording in
                                recordingRow(for: recording)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .id("list-\(isDateFilterActive)-\(dateFilterStart)-\(dateFilterEnd)-\(searchText)")
        .accessibilityIdentifier(BisonNotesAccessibilityID.recordingsList)
    }

    private func recordingRow(for recording: AudioRecordingFile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                if isSelectionMode {
                    Button(action: {
                        toggleSelection(for: recording)
                    }) {
                        Image(systemName: selectedRecordings.contains(recording.url) ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundColor(selectedRecordings.contains(recording.url) ? .accentColor : .secondary)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: {
                    if isSelectionMode {
                        toggleSelection(for: recording)
                    } else if recording.isArchived && !recording.hasLocalAudio {
                        selectedRecordingForPlayer = nil
                        archiveInfoRecording = recording
                    } else {
                        selectedRecordingForPlayer = recording
                    }
                }) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(recording.name)
                            .font(.headline)
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                recordingMetaLabel(systemImage: "calendar", text: recording.dateString)
                                recordingMetaLabel(systemImage: "timer", text: recording.durationString)
                                recordingMetaLabel(systemImage: "externaldrive", text: recording.fileSizeString)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                recordingMetaLabel(systemImage: "calendar", text: recording.dateString)
                                recordingMetaLabel(systemImage: "timer", text: recording.durationString)
                                recordingMetaLabel(systemImage: "externaldrive", text: recording.fileSizeString)
                            }
                        }

                        recordingStatusView(for: recording)

                        if recording.isCloudSyncDisabled {
                            Label("Keep on This Device", systemImage: "iphone")
                                .font(.caption.weight(.medium))
                                .foregroundColor(.indigo)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.indigo.opacity(0.12), in: Capsule())
                        }

                        if let locationData = recording.locationData {
                            Button(action: {
                                showLocationDetails(locationData)
                            }) {
                                Label("View Location", systemImage: "location.fill")
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.accentColor)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    recordingActionButtons(for: recording)
                    Spacer()
                    transcriptActionButton(for: recording)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        recordingActionButtons(for: recording)
                    }
                    transcriptActionButton(for: recording)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier(BisonNotesAccessibilityID.recordingRowPrefix + (recording.recordingId?.uuidString ?? recording.url.lastPathComponent))
    }

    private func recordingMetaLabel(systemImage: String, text: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
    }

    @ViewBuilder
    private func recordingStatusView(for recording: AudioRecordingFile) -> some View {
        if recording.isArchived {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "archivebox.fill")
                        .font(.caption)
                    Text(recording.archivedAtString.map { "Archived \($0)" } ?? "Archived")
                        .font(.caption)
                        .fontWeight(.medium)
                    Text(recording.hasLocalAudio ? "Local audio present" : "Audio offloaded")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .foregroundColor(.orange)

                if let location = RecordingArchiveService.shared.primaryArchiveLocation(for: recording.recordingId) {
                    Label("\(location.providerDisplayName) / \(location.displayName)", systemImage: "externaldrive.badge.checkmark")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        } else if let relationships = enhancedFileManager.getFileRelationships(for: recording.url) {
            FileAvailabilityIndicator(
                status: relationships.availabilityStatus,
                showLabel: true,
                size: .small
            )
        }
    }

    @ViewBuilder
    private func recordingActionButtons(for recording: AudioRecordingFile) -> some View {
        if recording.hasLocalAudio {
            recordingIconButton("Export Audio", systemImage: "square.and.arrow.up", tint: .accentColor) {
                prepareExport(for: recording)
            }
        }

        if recording.isArchived && !recording.hasLocalAudio {
            Button(action: {
                restoreArchivedAudio(recording)
            }) {
                if restoringArchiveRecordingId != nil && restoringArchiveRecordingId == recording.recordingId {
                    ProgressView()
                        .frame(width: 34, height: 34)
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.headline)
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .buttonStyle(.plain)
            .disabled(restoringArchiveRecordingId != nil && restoringArchiveRecordingId == recording.recordingId)
            .accessibilityLabel("Restore Audio")
        } else if recording.isArchived && recording.hasLocalAudio {
            recordingIconButton("Mark Local Archive State Clear", systemImage: "checkmark.circle.fill", tint: .green) {
                clearLocalArchiveState(recording)
            }
        } else {
            recordingIconButton("Play Audio", systemImage: "play.fill", tint: .accentColor) {
                selectedRecordingForPlayer = recording
            }
        }

        cloudSyncPreferenceButton(for: recording)

        recordingIconButton("Delete Recording", systemImage: "trash", tint: .red) {
            deletionData.recordingToDelete = recording
            deleteRecording(recording)
        }
    }

    @ViewBuilder
    private func cloudSyncPreferenceButton(for recording: AudioRecordingFile) -> some View {
        if recording.recordingId != nil {
            recordingIconButton(
                recording.isCloudSyncDisabled ? "Allow iCloud Sync" : "Keep on This Device",
                systemImage: recording.isCloudSyncDisabled ? "iphone" : "icloud",
                tint: recording.isCloudSyncDisabled ? .indigo : .blue,
                recordingId: recording.recordingId
            ) {
                toggleCloudSyncPreference(for: recording)
            }
        }
    }

    private func recordingIconButton(_ label: String,
                                     systemImage: String,
                                     tint: Color,
                                     recordingId: UUID? = nil,
                                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundColor(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier(forRecordingIconLabel: label, recordingId: recordingId))
    }

    /// Labeled "Generate Transcript" action shown beneath each recording row.
    /// Hidden for archived recordings with no local audio. Hidden once a transcript exists —
    /// users edit the transcript from the Transcripts tab.
    /// - In progress → orange pill with spinner + phase label.
    /// - Otherwise → accent "Generate Transcript" pill that opens the cleanup confirmation dialog.
    @ViewBuilder
    private func transcriptActionButton(for recording: AudioRecordingFile) -> some View {
        if recording.hasLocalAudio,
           let entry = appCoordinator.getRecording(url: recording.url),
           entry.transcript == nil {
            let recordingId = entry.id ?? UUID()
            let isCleaning = transcriptionStarter.isCleaning(recordingId)
            let isQueuedForCleanup = transcriptionStarter.isQueuedForCleanup(recordingId)
            let jobStatus = transcriptionStarter.activeTranscriptionJobStatus(for: entry, appCoordinator: appCoordinator)
            let hasActiveJob = jobStatus != nil
            let isProcessing = isCleaning || isQueuedForCleanup || hasActiveJob

            Button(action: {
                if !isProcessing {
                    recordingPendingTranscription = entry
                    showingAudioCleanupPrompt = true
                }
            }) {
                HStack(spacing: 8) {
                    if isProcessing {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(.orange)
                        Text(transcriptProcessingLabel(isCleaning: isCleaning,
                                                      isQueuedForCleanup: isQueuedForCleanup,
                                                      jobStatus: jobStatus))
                    } else {
                        Image(systemName: "text.bubble")
                        Text("Generate Transcript")
                    }
                }
                .font(.subheadline)
                .fontWeight(.medium)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    (isProcessing ? Color.orange : Color.accentColor).opacity(0.12),
                    in: Capsule()
                )
                .foregroundColor(isProcessing ? .orange : .accentColor)
            }
            .buttonStyle(.plain)
            .disabled(isProcessing)
            .accessibilityLabel("Generate Transcript")
            .accessibilityIdentifier(BisonNotesAccessibilityID.generateTranscriptPrefix + recordingId.uuidString)
            .id("transcript-\(recordingId)-\(isProcessing)-\(transcriptStateRefresh)")
        }
    }

    private func identifier(forRecordingIconLabel label: String, recordingId: UUID? = nil) -> String {
        switch label {
        case "Keep on This Device", "Allow iCloud Sync":
            return BisonNotesAccessibilityID.keepOnThisDevicePrefix + (recordingId?.uuidString ?? "unknown")
        default:
            return "bisonnotes.recording.action." + label
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
        }
    }

    private func transcriptProcessingLabel(isCleaning: Bool,
                                           isQueuedForCleanup: Bool,
                                           jobStatus: JobProcessingStatus?) -> String {
        if isCleaning { return "Cleaning Audio…" }
        if isQueuedForCleanup { return "Queued…" }
        switch jobStatus {
        case .queued: return "Queued…"
        case .processing: return "Transcribing…"
        default: return "Processing…"
        }
    }

    // MARK: - Search and Date Filtering

    private var filteredRecordings: [AudioRecordingFile] {
        var result = recordings

        // Apply date filter if active
        if isDateFilterActive {
            let startOfDay = Calendar.current.startOfDay(for: dateFilterStart)
            let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: dateFilterEnd) ?? dateFilterEnd

            result = result.filter { recording in
                return recording.date >= startOfDay && recording.date <= endOfDay
            }
        }

        // Apply search filter if not empty
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            let searchTerms = trimmedSearch.lowercased()
            result = result.filter { recording in
                recording.name.lowercased().contains(searchTerms)
            }
        }

        return result
    }

    private func loadRecordings() {
        // Use the app coordinator to get recordings with proper database names
        let recordingsWithData = appCoordinator.getAllRecordingsWithData()

        // Deduplicate by resolved filename; prefer entries with content and non-generic titles
        var bestByFilename: [String: (recording: RecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)] = [:]

        func score(_ e: (recording: RecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)) -> Int {
            var s = 0
            if e.summary != nil { s += 3 }
            if e.transcript != nil { s += 2 }
            if let name = e.recording.recordingName, !isGenericName(name) { s += 1 }
            if e.recording.duration > 0 { s += 1 }
            return s
        }

        for entry in recordingsWithData {
            // Skip imported transcripts - they appear in the Transcripts tab only
            if entry.recording.audioQuality == "imported" {
                continue
            }

            // For archived recordings, use stored URL even if file is missing
            let url: URL?
            if entry.recording.isArchived {
                url = appCoordinator.getAbsoluteURL(for: entry.recording)
                    ?? appCoordinator.getStoredURL(for: entry.recording)
            } else {
                url = appCoordinator.getAbsoluteURL(for: entry.recording)
            }

            guard let resolvedURL = url else { continue }
            let key = resolvedURL.lastPathComponent
            if let existing = bestByFilename[key] {
                bestByFilename[key] = score(existing) >= score(entry) ? existing : entry
            } else {
                bestByFilename[key] = entry
            }
        }

        let deduped = Array(bestByFilename.values)

        recordings = deduped.compactMap { recordingData -> AudioRecordingFile? in
            let recording = recordingData.recording
            guard let recordingName = recording.recordingName else {
                return nil
            }

            let isArchived = recording.isArchived
            let recordingURL: URL?

            if isArchived {
                recordingURL = appCoordinator.getAbsoluteURL(for: recording)
                    ?? appCoordinator.getStoredURL(for: recording)
            } else {
                recordingURL = appCoordinator.getAbsoluteURL(for: recording)
            }

            guard let url = recordingURL else {
                AppLog.shared.recording("Skipping recording with missing data", level: .debug)
                return nil
            }

            // Non-archived recordings must have a local file
            if !isArchived && !FileManager.default.fileExists(atPath: url.path) {
                AppLog.shared.recording("Skipping recording with missing file", level: .debug)
                return nil
            }

            let date = recording.recordingDate ?? recording.createdAt ?? Date()
            let duration = recording.duration > 0 ? recording.duration : getRecordingDuration(url: url)
            let locationData = appCoordinator.loadLocationData(for: recording)

            return AudioRecordingFile(
                url: url,
                name: recordingName,
                date: date,
                duration: duration,
                locationData: locationData,
                isArchived: isArchived,
                archivedAt: recording.archivedAt,
                archiveNote: recording.archiveNote,
                recordingId: recording.id,
                storedFileSize: recording.fileSize,
                isCloudSyncDisabled: recording.isCloudSyncDisabled
            )
        }
        .sorted { $0.date > $1.date }

        // Geocode locations for all recordings (with rate limiting)
        loadLocationAddressesBatch(for: recordings)
    }

    private func isGenericName(_ name: String) -> Bool {
        if name.hasPrefix("recording_") { return true }
        if name.hasPrefix("V20210426-") || name.hasPrefix("V20210427-") { return true }
        if name.hasPrefix("apprecording-") { return true }
        if name.hasPrefix("importedfile-recording_") { return true }
        if name.count > 20 && (name.contains("1754") || name.contains("2025") || name.contains("2024")) { return true }
        return false
    }

    private func loadLocationDataForRecording(url: URL) -> LocationData? {
        // First try to find the recording in Core Data and use proper URL resolution
        if let recording = appCoordinator.getRecording(url: url) {
            // loadLocationData now checks Core Data fields first, then file
            return appCoordinator.loadLocationData(for: recording)
        }

        // Fallback: try direct file access for recordings not yet in Core Data
        let locationURL = url.deletingPathExtension().appendingPathExtension("location")
        guard let data = try? Data(contentsOf: locationURL),
              let locationData = try? JSONDecoder().decode(LocationData.self, from: data) else {
            return nil
        }
        return locationData
    }

    private func showLocationDetails(_ locationData: LocationData) {
        selectedLocationData = locationData
    }

    private func toggleCloudSyncPreference(for recording: AudioRecordingFile) {
        guard let recordingId = recording.recordingId else { return }

        Task {
            do {
                try await appCoordinator.setCloudSyncDisabled(
                    for: recordingId,
                    disabled: !recording.isCloudSyncDisabled
                )
                await MainActor.run {
                    loadRecordings()
                    refreshFileRelationships()
                }
            } catch {
                await MainActor.run {
                    archiveRestoreError = "Could not update iCloud sync preference: \(error.localizedDescription)"
                }
            }
        }
    }

    private func loadLocationAddressesBatch(for recordings: [AudioRecordingFile]) {
        // Filter recordings that have location data and don't already have cached addresses
        let recordingsNeedingGeocode = recordings.filter { recording in
            guard let _ = recording.locationData else { return false }
            return locationAddresses[recording.url] == nil
        }

        // Process recordings one by one to respect rate limiting
        for recording in recordingsNeedingGeocode {
            loadLocationAddress(for: recording)
        }
    }

    private func loadLocationAddress(for recording: AudioRecordingFile) {
        guard let locationData = recording.locationData else { return }

        // Skip if we already have an address for this recording
        if locationAddresses[recording.url] != nil {
            return
        }

        let location = CLLocation(latitude: locationData.latitude, longitude: locationData.longitude)
        // Use a default location manager since AudioRecorderViewModel doesn't have one
        let locationManager = LocationManager()
        locationManager.reverseGeocodeLocation(location) { address in
            if let address = address {
                self.locationAddresses[recording.url] = address
            }
        }
    }

    private func deleteRecording(_ recording: AudioRecordingFile) {
        // Set the recording to delete immediately
        deletionData.recordingToDelete = recording

        // Set up relationships for enhanced deletion
        Task {
            // First try to get existing relationships
            var relationships = enhancedFileManager.getFileRelationships(for: recording.url)

            // If no relationships exist, create them on demand
            if relationships == nil {
                await enhancedFileManager.refreshRelationships(for: recording.url)
                relationships = enhancedFileManager.getFileRelationships(for: recording.url)
            }

            await MainActor.run {
                if let relationships = relationships {
                    // Use enhanced deletion with relationships
                    self.deletionData.fileRelationships = relationships
                    self.showingEnhancedDeleteDialog = true
                } else {
                    // Fallback to simple deletion if we still can't get relationships
                    do {
                        try FileManager.default.removeItem(at: recording.url)
                        loadRecordings() // Reload the list
                    } catch {
                        AppLog.shared.recording("Failed to delete recording: \(error)", level: .error)
                    }
                }
            }
        }
    }

    private func deleteRecordingWithRelationships(_ recording: AudioRecordingFile, preserveSummary: Bool) async {
        do {
            try await enhancedFileManager.deleteRecording(recording.url, preserveSummary: preserveSummary)
            await MainActor.run {
                loadRecordings() // Reload the list
            }
        } catch {
            AppLog.shared.recording("Failed to delete recording with relationships: \(error)", level: .error)
        }
    }

    private func getRecordingDuration(url: URL) -> TimeInterval {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            return player.duration
        } catch {
            AppLog.shared.recording("Error getting duration: \(error)", level: .error)
            return 0.0
        }
    }

    private func refreshFileRelationships() {
        Task {
            // Refresh relationships for all recordings in the background
            for recording in recordings {
                await enhancedFileManager.refreshRelationships(for: recording.url)
            }

            await MainActor.run {
                // Force a UI refresh by updating the published object
                enhancedFileManager.objectWillChange.send()
            }
        }
    }

    // MARK: - Selection Banner

    private var selectionBanner: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
                Text(selectionAction.instruction)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                if let max = selectionAction.maxSelection {
                    Text("\(selectedRecordings.count) of \(max) selected")
                        .font(.subheadline)
                        .foregroundColor(selectedRecordings.count > max ? .orange : .secondary)
                } else {
                    Text("\(selectedRecordings.count) selected")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            if showSelectionWarning, let max = selectionAction.maxSelection {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text("Only the first \(max) selected will be combined. Deselect extras or tap Combine to continue.")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
        .animation(.easeInOut(duration: 0.2), value: showSelectionWarning)
        .animation(.easeInOut(duration: 0.2), value: selectedRecordings.count)
    }

    // MARK: - Helper Methods

    private func toggleSelection(for recording: AudioRecordingFile) {
        if selectedRecordings.contains(recording.url) {
            selectedRecordings.remove(recording.url)
            // Clear warning if we drop back to the max or below
            if let max = selectionAction.maxSelection, selectedRecordings.count <= max {
                showSelectionWarning = false
            }
        } else {
            selectedRecordings.insert(recording.url)
            // Show warning if over the max for this action
            if let max = selectionAction.maxSelection, selectedRecordings.count > max {
                showSelectionWarning = true
            }
        }
    }

    private func handleCombineSelected() {
        guard selectedRecordings.count >= 2 else { return }

        // Use the first 2 selected recordings (in the order they appear in the list)
        let selectedURLs = recordings.filter { selectedRecordings.contains($0.url) }.prefix(2).map { $0.url }
        guard let firstRecording = recordings.first(where: { $0.url == selectedURLs[0] }),
              let secondRecording = recordings.first(where: { $0.url == selectedURLs[1] }) else {
            return
        }

        // Check if either recording has transcripts or summaries
        var issues: [String] = []

        if let firstEntry = appCoordinator.getRecording(url: firstRecording.url),
           let firstId = firstEntry.id {
            if appCoordinator.getTranscript(for: firstId) != nil {
                issues.append("'\(firstRecording.name)' has a transcript")
            }
            if appCoordinator.getSummary(for: firstId) != nil {
                issues.append("'\(firstRecording.name)' has a summary")
            }
        }

        if let secondEntry = appCoordinator.getRecording(url: secondRecording.url),
           let secondId = secondEntry.id {
            if appCoordinator.getTranscript(for: secondId) != nil {
                issues.append("'\(secondRecording.name)' has a transcript")
            }
            if appCoordinator.getSummary(for: secondId) != nil {
                issues.append("'\(secondRecording.name)' has a summary")
            }
        }

        if !issues.isEmpty {
            // Show alert explaining why they can't combine
            let alert = UIAlertController(
                title: "Cannot Combine Recordings",
                message: "These recordings cannot be combined because:\n\n\(issues.joined(separator: "\n"))\n\nPlease delete the transcripts and/or summaries from both recordings before combining them.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))

            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootViewController = windowScene.windows.first?.rootViewController {
                rootViewController.present(alert, animated: true)
            }

            // Exit selection mode
            isSelectionMode = false
            selectedRecordings.removeAll()
            showSelectionWarning = false
            return
        }

        recordingsToCombine = (first: firstRecording, second: secondRecording)
        showingCombineView = true

        // Exit selection mode
        isSelectionMode = false
        selectedRecordings.removeAll()
        showSelectionWarning = false
    }

    // MARK: - Archive Helpers

    private func restoreArchivedAudio(_ recording: AudioRecordingFile) {
        guard restoringArchiveRecordingId == nil else { return }
        guard let recordingId = recording.recordingId,
              let recordingEntry = appCoordinator.getRecording(id: recordingId) else {
            archiveRestoreError = "Could not find this recording in storage."
            return
        }

        restoringArchiveRecordingId = recordingId

        Task { @MainActor in
            do {
                _ = try RecordingArchiveService.shared.restoreArchivedRecording(recordingEntry)
                loadRecordings()
                refreshFileRelationships()
                selectedRecordingForPlayer = recordings.first { $0.recordingId == recordingId }
            } catch {
                archiveRestoreError = error.localizedDescription
            }
            restoringArchiveRecordingId = nil
        }
    }

    private func clearLocalArchiveState(_ recording: AudioRecordingFile) {
        guard let recordingId = recording.recordingId,
              let recordingEntry = appCoordinator.getRecording(id: recordingId) else {
            archiveRestoreError = "Could not find this recording in storage."
            return
        }

        RecordingArchiveService.shared.clearArchiveFlags(for: recordingEntry)
        loadRecordings()
        refreshFileRelationships()
    }

    private func prepareArchiveFromSelection() {
        let selectedURLs = selectedRecordings
        let allRecordings = appCoordinator.getAllRecordingsWithData()
        recordingsToArchive = allRecordings.compactMap { entry -> RecordingEntry? in
            guard let url = appCoordinator.getAbsoluteURL(for: entry.recording),
                  selectedURLs.contains(url) else { return nil }
            return entry.recording
        }
        if !recordingsToArchive.isEmpty {
            removeLocalAfterArchive = false
            showingArchiveConfirmation = true
        }
    }

    private func prepareExportFromSelection() {
        let selectedURLs = selectedRecordings
        let selected = recordings.filter { selectedURLs.contains($0.url) }
        let exportableRecordings = selected.filter { $0.hasLocalAudio }

        audioExportSkippedCount = selected.count - exportableRecordings.count
        audioExportURLs = RecordingArchiveService.shared.prepareAudioExportURLs(for: exportableRecordings)

        guard !audioExportURLs.isEmpty else {
            audioExportSkippedCount = 0
            archiveRestoreError = "No local audio files are available to export. Restore archived audio before exporting it."
            return
        }

        showingAudioExportPicker = true
    }

    private func prepareExport(for recording: AudioRecordingFile) {
        guard recording.hasLocalAudio else {
            archiveRestoreError = "This audio file is not stored locally. Restore archived audio before exporting it."
            return
        }

        audioExportSkippedCount = 0
        audioExportURLs = RecordingArchiveService.shared.prepareAudioExportURLs(for: [recording])
        guard !audioExportURLs.isEmpty else {
            archiveRestoreError = "The audio file could not be prepared for export."
            return
        }

        showingAudioExportPicker = true
    }

    private var archiveOlderThanSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 40))
                    .foregroundColor(.accentColor)
                    .padding(.top, 20)

                Text("Archive Older Than")
                    .font(.title2)
                    .fontWeight(.bold)

                Picker("Days", selection: $archiveOlderThanDays) {
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                    Text("60 days").tag(60)
                    Text("90 days").tag(90)
                }
                .pickerStyle(.wheel)
                .frame(height: 120)

                let matchCount = RecordingArchiveService.shared.recordingsOlderThan(days: archiveOlderThanDays).count
                Text("\(matchCount) recording\(matchCount == 1 ? "" : "s") match")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: {
                    showingArchiveOlderThan = false
                    recordingsToArchive = RecordingArchiveService.shared.recordingsOlderThan(days: archiveOlderThanDays)
                    if !recordingsToArchive.isEmpty {
                        removeLocalAfterArchive = false
                        showingArchiveConfirmation = true
                    }
                }) {
                    Text("Continue")
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(matchCount > 0 ? Color.accentColor : Color.gray)
                        )
                }
                .disabled(matchCount == 0)
                .padding(.horizontal)

                Button("Cancel") {
                    showingArchiveOlderThan = false
                }
                .foregroundColor(.secondary)
                .padding(.bottom, 20)
            }
            .navigationBarHidden(true)
        }
        .presentationDetents([.medium])
    }
}
